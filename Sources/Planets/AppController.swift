import AppKit
import ServiceManagement
import ApplicationServices
import PlanetsCore

/// Owns every part of the app and wires them together. Parts don't know about each
/// other: the window manager reports changes, and this class decides who needs to hear.
@MainActor
final class AppController {
    let store = ConfigStore()
    let wm: WindowManager
    let statusItem = StatusItemController()
    let glow = FocusGlowController()
    let hud = WorkspaceHUD()
    private var input: InputTap!
    private var ipc: IPCServer?
    private var onboarding: OnboardingWindowController?
    private let permissionGuide = PermissionGuide()
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var mouseFocusMonitor: Any?
    private var lastMouseFocusCheck = ContinuousClock.now
    private var lastMouseHit: WindowID?
    private(set) var coreStarted = false
    private(set) var inputTapRunning = false
    /// Accessibility was turned off while Planets ran.
    private(set) var accessibilityLost = false
    private var accessibilityTimer: Timer?

    init() {
        wm = WindowManager(config: store.config)
        input = InputTap { [weak self] event in
            if case .command(.menuBar) = event, StatusItemController.closeOpenMenu() { return }
            // When the key went down, which can be well before the main thread gets to it.
            let at = ContinuousClock.now
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, at: at) }
            }
        }
    }

    var config: Config { store.config }

    func start() {
        statusItem.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        statusItem.install()
        store.onChange = { [weak self] in self?.configChanged($0) }
        startIPC()
        installSignalHandlers()
        if AXIsProcessTrusted() {
            startCore()
        } else {
            showOnboarding()
        }
        refreshStatusItem()
    }

    func shutdown() {
        // Without Accessibility, windows can't be put back, and asking only waits.
        if coreStarted, !accessibilityLost {
            // Save first: restoring puts every window back on screen, and the next launch
            // needs to know which workspace each one belongs to.
            wm.persist()
            wm.restoreAllWindows()
        }
        ipc?.stop()
    }

    // MARK: Permission

    private func showOnboarding() {
        let onboarding = OnboardingWindowController(controller: self)
        self.onboarding = onboarding
        onboarding.show()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.startCore()
                self.permissionGuide.hide()
                self.onboarding?.permissionGranted()
            }
        }
    }

    /// Opens Accessibility in System Settings with Planets beside it to drag into the list.
    /// Not macOS's own prompt: its alert only leads to the same pane, one dialog later.
    func requestAccessibility() {
        permissionGuide.show()
    }

    func onboardingClosed() {
        onboarding = nil
    }

    // MARK: Core

    private func startCore() {
        guard !coreStarted else { return }
        coreStarted = true
        wm.onChange = { [weak self] change in self?.stateChanged(change) }
        wm.onFollowPointer = { [weak self] follow in self?.input.setFollowPointer(follow) }
        wm.onWorkspaceSwitch = { [weak self] name in self?.workspaceSwitched(to: name) }
        wm.start()
        input.update(bindings: config.bindings, dragModifiers: config.mouseModifier)
        inputTapRunning = input.start()
        if !inputTapRunning { log.error("could not start the event tap; shortcuts are unavailable") }
        glow.configure(enabled: config.focusGlow, intensity: config.glowIntensity, gap: config.layout.innerGap, color: config.glowColor)
        updateFocusFollowsMouse()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWindowCycling() }
        }
        // Keyboard layouts change which key types which letter; rebuild the key table.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.input.update(bindings: self.config.bindings, dragModifiers: self.config.mouseModifier)
            }
        }
        watchAccessibility()
        refreshStatusItem()
    }

    /// Accessibility can be turned off in System Settings while Planets runs. From then on
    /// every window looks closed, so Planets stops listening and saving, and keys and clicks
    /// bypass it. Turned back on, Planets starts over from the state it saved before.
    /// macOS posts a notification when the list changes, and the answer changes a moment
    /// after it; the timer is for the change the notification misses.
    private func watchAccessibility() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.checkAccessibility() }
            }
        }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    private func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        if !trusted, !accessibilityLost {
            accessibilityLost = true
            log.error("Accessibility was turned off; Planets has stopped until it's back")
            wm.savesState = false
            input.setTapRunning(false)
            refreshStatusItem()
        } else if trusted, accessibilityLost, Lifecycle.canRelaunch {
            Lifecycle.relaunch()
        }
    }

    private func configChanged(_ config: Config) {
        if coreStarted {
            wm.reload(config)
            input.update(bindings: config.bindings, dragModifiers: config.mouseModifier)
            glow.configure(enabled: config.focusGlow, intensity: config.glowIntensity, gap: config.layout.innerGap, color: config.glowColor)
            updateFocusFollowsMouse()
        }
        refreshStatusItem()
    }

    private func stateChanged(_ change: WindowManager.Change) {
        if change.contains(.workspaces) || change.contains(.focus) { refreshStatusItem() }
        if change.contains(.focus) || change.contains(.frames) {
            glow.update(target: wm.focusedFrame, monitors: wm.world.monitors, restack: change.contains(.focus))
            input.update(windows: hitTestOrder())
        }
        if change.contains(.focus) || change.contains(.workspaces) { updateWindowCycling() }
    }

    /// Set while a switch is made from the strip's menu, where
    /// the HUD would only repeat what was just chosen.
    private var switchingQuietly = false

    private func workspaceSwitched(to name: String) {
        guard config.workspaceHUD, !switchingQuietly else { return }
        hud.show(model: hudModel(highlighting: name), on: Displays.screen(for: wm.world.monitorShowing(name)))
    }

    /// Floating windows sit above tiled ones, so they win the hit test for modifier drags.
    private func hitTestOrder() -> [(WindowID, CGRect)] {
        let frames = wm.visibleFrames
        let floating = frames.filter { wm.world.windows[$0.0]?.isFloating == true }
        let focused = frames.filter { $0.0 == wm.world.focusedWindow }
        return focused + floating + frames.filter { wm.world.windows[$0.0]?.isFloating != true }
    }

    /// Tells the input tap whether ⌘` should stay on this workspace for the frontmost app.
    func updateWindowCycling() {
        input.update(cycle: wm.cycleTargets())
    }

    // MARK: Focus follows mouse

    private func updateFocusFollowsMouse() {
        if config.focusFollowsMouse, mouseFocusMonitor == nil {
            mouseFocusMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMovedForFocus() }
            }
        } else if !config.focusFollowsMouse, let monitor = mouseFocusMonitor {
            NSEvent.removeMonitor(monitor)
            mouseFocusMonitor = nil
        }
    }

    /// Runs at most every 40 ms, and does real work only when the pointer crosses into a
    /// different window. Skips while a button is held or a menu is open, so dragging and
    /// menus behave as usual.
    private func mouseMovedForFocus() {
        let now = ContinuousClock.now
        guard now - lastMouseFocusCheck > .milliseconds(40), NSEvent.pressedMouseButtons == 0 else { return }
        lastMouseFocusCheck = now
        let point = Displays.toGlobal(NSEvent.mouseLocation)
        let hit = hitTestOrder().first { $0.1.contains(point) }?.0
        guard hit != lastMouseHit else { return }
        lastMouseHit = hit
        guard let hit, hit != wm.world.focusedWindow, !Self.menuIsOpen(), Self.topWindow(at: point) == hit else { return }
        wm.focusFromMouse(hit)
    }

    /// While any app's menu is open, the pointer passing over a window mustn't take focus.
    private static func menuIsOpen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    /// The frontmost normal window under a point, so a window covered by another app's
    /// unmanaged window (a dialog, a panel) isn't focused through it.
    private static func topWindow(at point: CGPoint) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        // Planets's own glow panel sits right under the focused window and covers the
        // screen; it must not count as the window under the pointer.
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowOwnerPID as String] as? Int) != ownPID {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: Command) -> IPCResponse {
        switch command {
        case .reload:
            store.load()
            return IPCResponse(ok: store.error == nil, output: store.error ?? "reloaded \(store.url.path)")
        case .menuBar:
            // An open menu runs the main thread until it closes. Opened from a block of the
            // run loop's own, not of the main queue, it leaves the main queue free: `planet
            // menubar` returns at once, and the next one, queued there, closes it again.
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                MainActor.assumeIsolated { self?.statusItem.toggleMenu() }
            }
            CFRunLoopWakeUp(main)
            return IPCResponse(ok: true, output: "")
        case .query(let query, let json):
            return IPCResponse(ok: true, output: Queries.run(query, json: json, controller: self))
        case .loginItem(let toggle):
            let enabled = SMAppService.mainApp.status == .enabled
            let enable = toggle == .toggle ? !enabled : toggle == .on
            do {
                if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                return IPCResponse(ok: false, output: "couldn't change the login item: \(error.localizedDescription)")
            }
            return IPCResponse(ok: true, output: enable ? "opens at login" : "doesn't open at login")
        default:
            guard coreStarted else { return IPCResponse(ok: false, output: "Planets needs the Accessibility permission first") }
            let result = wm.perform(command)
            return IPCResponse(ok: result.ok, output: result.output)
        }
    }

    private func handle(_ event: InputTap.Event, at pressed: ContinuousClock.Instant) {
        switch event {
        case .command(.menuBar): statusItem.toggleMenu(pressedAt: pressed)
        case .command(let command): perform(command)
        case .dragBegan(let id, let point): wm.dragBegan(id, at: point)
        case .dragMoved(let id, let point): wm.dragMoved(id, to: point)
        case .dragEnded(let id, let point): wm.dragEnded(id, at: point)
        case .cycledTo(let id): wm.noteCycled(to: id)
        case .cycleAcrossSpaces(let id): wm.cycleAcrossSpaces(to: id)
        case .pointerDown(let point): wm.pointerDown(at: point)
        case .pointerMoved(let point):
            // Straight to the rim, skipping the coalesced change notification: a frame of
            // delay is visible when the window itself moves with the pointer.
            if wm.pointerMoved(to: point) { glow.update(target: wm.focusedFrame, monitors: wm.world.monitors) }
        case .pointerUp(let point): wm.pointerUp(at: point)
        }
    }

    private func startIPC() {
        let server = IPCServer { [weak self] args in
            guard let self else { return IPCResponse(ok: false, output: "shutting down") }
            return self.handleIPC(args)
        }
        do {
            try server.start()
            ipc = server
        } catch {
            log.error("IPC socket failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleIPC(_ args: [String]) -> IPCResponse {
        switch args.first {
        case "version":
            return IPCResponse(ok: true, output: "Planets \(Bundle.main.shortVersion)")
        case "doctor":
            return IPCResponse(ok: true, output: SetupCheck.report())
        case "config":
            if args.dropFirst().first == "reload" { return perform(.reload) }
            return IPCResponse(ok: true, output: store.url.path)
        default:
            do {
                return perform(try Command.parse(arguments: args))
            } catch {
                return IPCResponse(ok: false, output: "\(error)")
            }
        }
    }

    private func installSignalHandlers() {
        // Quitting from a terminal must still bring parked windows back.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Status item and HUD models

    func refreshStatusItem() {
        var model = StatusItemController.Model()
        model.needsPermission = !coreStarted || accessibilityLost
        model.tilingEnabled = wm.isEnabled
        let focused = wm.world.focusedWorkspaceName
        for name in workspaceNames() {
            let away = putAway(on: name)
            guard hasWindows(name) || !away.isEmpty || name == focused else { continue }
            model.chips.append(.init(name: name, active: name == focused, away: !away.isEmpty))
            // The state first: a title can be anything.
            model.away += away.map { "\($0.window.reason == .minimized ? "Minimised" : "Hidden") on \(name): \($0.title)" }
        }
        statusItem.update(model)
    }

    func hudModel(highlighting name: String) -> WorkspaceHUD.Model {
        let chips = workspaceNames().compactMap { workspaceName -> WorkspaceHUD.Chip? in
            let onScreen = hasWindows(workspaceName), away = !wm.awayWindows(on: workspaceName).isEmpty
            // Persistent workspaces always show so their positions never shift; others only when used.
            guard wm.world.persistentNames.contains(workspaceName) || onScreen || away || workspaceName == name else { return nil }
            return WorkspaceHUD.Chip(name: workspaceName, occupied: onScreen || away, away: away)
        }
        return WorkspaceHUD.Model(chips: chips, active: name)
    }

    // MARK: Menu

    /// What needs fixing first, then the workspaces, then the rest of Planets, and Quit on
    /// its own. Settings are the config file, as in Hyprland: one place, diffable, and
    /// applied on save.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let error = store.error {
            let item = MenuTarget.item("Config error: \(error.prefix(60))") { [weak self] in self?.openConfig() }
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        // Accessibility is the one setting Planets can't work without, and it can be
        // turned off while it runs.
        if !coreStarted || !AXIsProcessTrusted() {
            let item = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(MenuTarget.grantAccess), keyEquivalent: "")
            item.target = MenuTarget.shared
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        // Settings on this Mac that fight tiling. Planets only reads them; each item opens
        // the pane where it's changed.
        for check in SetupCheck.run() where check.status == .recommended {
            let item = MenuTarget.item(check.title) { if let url = check.settingsURL { NSWorkspace.shared.open(url) } }
            item.toolTip = check.detail
            item.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        // Paused, workspaces and the scratchpad do nothing, so they're left out.
        if coreStarted, wm.isEnabled {
            for item in workspaceItems() { menu.addItem(item) }
            menu.addItem(.separator())
            if wm.world.workspaces[World.scratchpad]?.isEmpty == false {
                let pad = MenuTarget.item(wm.world.scratchpadMonitor == nil ? "Show Scratchpad" : "Hide Scratchpad") { [weak self] in self?.perform(.scratchpad(.toggle)) }
                showShortcut(for: .scratchpad(.toggle), on: pad)
                menu.addItem(pad)
            }
            menu.addItem(.separator())
        }
        // A state of the whole app, so with the app's own items rather than among the ones
        // that move you around.
        if coreStarted {
            let on = wm.isEnabled
            let tiling = MenuTarget.item(on ? "Pause Tiling" : "Resume Tiling") { [weak self] in self?.perform(.tiling(on ? .off : .on)) }
            showShortcut(for: .tiling(.toggle), on: tiling)
            menu.addItem(tiling)
        }
        let configItem = MenuTarget.item("Open Config") { [weak self] in self?.openConfig() }
        configItem.keyEquivalent = ","
        menu.addItem(configItem)
        menu.addItem(shortcutsItem())
        let login = MenuTarget.item("Open at Login") { [weak self] in self?.perform(.loginItem(.toggle)) }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = MenuTarget.item("Quit Planets") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    func quietly(_ action: (AppController) -> Void) {
        switchingQuietly = true
        defer { switchingQuietly = false }
        action(self)
    }

    /// Shows a command's shortcut beside its item, when it's one key the menu can draw.
    private func showShortcut(for command: Command, on item: NSMenuItem) {
        guard let binding = config.bindings.first(where: { $0.command == command }), binding.chord.key.count == 1 else { return }
        item.keyEquivalent = binding.chord.key
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(binding.chord.modifiers)
    }

    /// The workspaces at the top of the strip's menu, each with the apps on it and the
    /// windows put away from it. Empty ones are left out, except the one you're on.
    private func workspaceItems() -> [NSMenuItem] {
        let world = wm.world
        var rows: [WorkspaceMenu.Row] = []
        for name in workspaceNames() {
            let windows = world.workspaces[name]?.windows ?? []
            let fullScreen = wm.fullScreenWindows(on: name)
            let away = putAway(on: name)
            let current = name == world.focusedWorkspaceName
            guard !windows.isEmpty || !fullScreen.isEmpty || !away.isEmpty || current else { continue }
            var seen = Set<pid_t>()
            // A full-screen window is part of its workspace, first: it's what that workspace shows.
            let apps = (fullScreen.map { WorkspaceMenu.Row.App(pid: $0.window.pid, name: $0.window.appName) }
                + windows.compactMap { id in world.windows[id].map { WorkspaceMenu.Row.App(pid: $0.pid, name: $0.appName) } })
                .filter { seen.insert($0.pid).inserted }
            let rowsAway = away.map { entry in
                let minimized = entry.window.reason == .minimized
                return WorkspaceMenu.Row.Away(id: entry.id, pid: entry.window.pid, title: entry.title, isMinimized: minimized)
            }
            rows.append(.init(
                name: name, apps: apps, isCurrent: current, away: rowsAway
            ))
        }
        return WorkspaceMenu.items(rows, choose: { [weak self] name in
            self?.quietly { $0.perform(.workspace(.named(name))) }
        }, restore: { [weak self] id in
            self?.quietly { $0.wm.restore(id) }
        })
    }

    /// What's put away from a workspace, most recent first, as the menu and the strip list it:
    /// a minimised window on its own, by its title; a hidden app once, by its name, as it
    /// comes back whole.
    private func putAway(on name: String) -> [(id: WindowID, window: WindowManager.AwayWindow, title: String)] {
        var hiddenApps = Set<pid_t>()
        return wm.awayWindows(on: name).compactMap { id, window in
            let minimized = window.reason == .minimized
            guard minimized || hiddenApps.insert(window.pid).inserted else { return nil }
            return (id, window, minimized && !window.title.isEmpty ? window.title : window.appName)
        }
    }

    /// Windows on screen there, full-screen ones included.
    private func hasWindows(_ name: String) -> Bool {
        !(wm.world.workspaces[name]?.isEmpty ?? true) || !wm.fullScreenWindows(on: name).isEmpty
    }

    /// The workspaces in their order, and any other a minimised or full-screen window still
    /// belongs to: a workspace of its own that went away once nothing was left on screen.
    private func workspaceNames() -> [String] {
        let order = wm.world.workspaceOrder
        let extra = Set(wm.awayWindows.values.map(\.workspace) + wm.fullScreenWindows.values.map(\.workspace))
            .subtracting(order).subtracting([World.scratchpad])
        return order + extra.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func openConfig() {
        NSWorkspace.shared.open(store.url)
    }

    /// Every key, grouped as the config groups them, so they can be learnt without a
    /// settings window.
    private func shortcutsItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        var category: String?
        for row in ShortcutSummary.rows(for: config.bindings) {
            if row.category != category {
                if category != nil { submenu.addItem(.separator()) }
                submenu.addItem(.sectionHeader(title: row.category))
                category = row.category
            }
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            item.badge = NSMenuItemBadge(string: row.chords.joined(separator: "  "))
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Keyboard Shortcuts", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

}

/// Lets menu items run closures: the shared target, which an item holds weakly, runs the
/// action the item carries.
@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()

    /// Each item carries its own action, and it goes with the item when the menu is rebuilt.
    private final class Action {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    static func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = Action(action)
        return item
    }

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }

    @objc func grantAccess() {
        (NSApp.delegate as? AppDelegate)?.controller.requestAccessibility()
    }
}

extension NSEvent.ModifierFlags {
    init(_ modifiers: Modifiers) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        self = flags
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}
