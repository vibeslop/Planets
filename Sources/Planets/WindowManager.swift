import AppKit
import OSLog
import PlanetsCore
import PlanetsPrivate

let log = Logger(subsystem: "dev.levelorbit.planets", category: "wm")

@MainActor
final class WindowManager {
    struct Change: OptionSet {
        let rawValue: Int
        static let workspaces = Change(rawValue: 1)
        static let focus = Change(rawValue: 2)
        static let frames = Change(rawValue: 4)
        static let all: Change = [.workspaces, .focus, .frames]
    }

    private(set) var world: World
    private(set) var config: Config
    private(set) var isEnabled = true
    let performance = PerformanceLog()

    var onChange: ((Change) -> Void)?
    var onWorkspaceSwitch: ((String) -> Void)?

    private var observers: [pid_t: AppObserver] = [:]
    private var lastApplied: [WindowID: CGRect] = [:]
    private var appliedBefore: [WindowID: [CGRect]] = [:]
    private var appliedAt: [WindowID: ContinuousClock.Instant] = [:]
    private var passOf: [WindowID: Int] = [:]
    private var passes = 0
    private var parked: Set<WindowID> = []
    private var ignored: Set<WindowID> = []
    private var remembered: [WindowID: String] = [:]
    private var rememberedFloating: Set<WindowID> = []
    private var rememberedSlot: [WindowID: TileSlot] = [:]
    private var launchMemory: [WindowID: SavedWindow] = [:]
    private var launchArrangements: [String: Workspace.Arrangement] = [:]
    private var launchMemoryUntil: ContinuousClock.Instant?
    private var startupWaitsForUnlock = false
    private var launchMemoryActive: Bool {
        !launchMemory.isEmpty && (startupWaitsForUnlock || launchMemoryUntil.map { ContinuousClock.now < $0 } == true)
    }
    private var spaceChangedAt: ContinuousClock.Instant?

    struct FullScreenWindow: Equatable {
        var pid: pid_t
        var workspace: String
        var appName: String
        var title: String
        var since: ContinuousClock.Instant = .now
    }
    private(set) var fullScreenWindows: [WindowID: FullScreenWindow] = [:]
    private(set) var showingFullScreen: [String: WindowID] = [:] {
        didSet { if showingFullScreen != oldValue { schedulePersist() } }
    }
    struct AwayWindow: Equatable {
        enum Reason: Equatable { case minimized, hidden }
        var pid: pid_t
        var workspace: String
        var appName: String
        var title: String
        var reason: Reason
        var since: ContinuousClock.Instant = .now
    }
    private(set) var awayWindows: [WindowID: AwayWindow] = [:]
    private var restoring: (id: WindowID, until: ContinuousClock.Instant)?

    private var lastUsed: [pid_t: WindowID] = [:]

    private var ownSpaceChangeUntil: ContinuousClock.Instant?
    private var fullScreenWatch: Timer?
    private var wokeAt: ContinuousClock.Instant?
    private var persistScheduled = false
    private var persisted: Data?
    private var offscreen: [WindowID: (pid: pid_t, frame: CGRect)] = [:]
    private var backgroundTabs: Set<WindowID> = []
    private var reportedAt: [WindowID: ContinuousClock.Instant] = [:]
    private var adjusting: [WindowID: CGRect] = [:]
    private var liveFrames: [WindowID: CGRect] = [:]
    private var moveOrigin: (id: WindowID, frames: [WindowID: CGRect])?
    private var liveSwapTarget: WindowID?
    private var liveInFlight = false
    private var livePending = false
    private var liveStart: [WindowID: CGRect] = [:]
    private var liveShown: [WindowID: CGRect] = [:]
    private var adjustTimer: Timer?
    private var snapBack: Set<WindowID> = []
    private var snapBackScheduled = false
    private var reparkCounts: [WindowID: (count: Int, since: ContinuousClock.Instant)] = [:]
    private var parkingCheck: DispatchWorkItem?
    private var escapeCounts: [WindowID: Int] = [:]
    private var dragging: (id: WindowID, grab: CGPoint, origin: CGPoint)?
    private var dragInFlight = false
    private var dragPending: CGPoint?
    private var press: CGPoint?
    private var userMove: TitleBarMove?
    private var settleMove: DispatchWorkItem?
    private var gestureWatch: Timer?
    private var userResize: WindowID?
    var onFollowPointer: ((Bool) -> Void)?
    private var capCandidates: [WindowID: CGSize] = [:]
    private var minCandidates: [WindowID: CGSize] = [:]
    private var refusalAsks: [WindowID: Int] = [:]
    private var vacated: [String: Vacancy] = [:]
    private var closing: [pid_t: Vacancy] = [:]

    private struct Vacancy {
        var windows: [(id: WindowID, slot: TileSlot, title: String, at: ContinuousClock.Instant)] = []
        var arrangements: [String: Workspace.Arrangement] = [:]
        var returned: [WindowID: WindowID] = [:]
        var at = ContinuousClock.now
        var firstBack: ContinuousClock.Instant?

        mutating func note(_ id: WindowID, in world: World) {
            guard let slot = world.slot(of: id) else { return }
            windows.append((id, slot, world.windows[id]?.title ?? "", .now))
            if arrangements[slot.workspace] == nil { arrangements[slot.workspace] = world.workspaces[slot.workspace]?.arrangement }
        }
    }
    private var placedAway: [WindowID: ContinuousClock.Instant] = [:]
    private var openedFrom: [pid_t: Opening] = [:]
    private struct Opening {
        var workspace: String
        var at = ContinuousClock.now
        var shown: ContinuousClock.Instant?
    }
    private var launchWatch: NSKeyValueObservation?
    private var joinedAt: [WindowID: ContinuousClock.Instant] = [:]
    private var settling: Set<WindowID> = []
    private static let opening: Duration = .seconds(2)

    private var focusIntent: (id: WindowID?, deadline: ContinuousClock.Instant)?
    private var pendingReveal: (id: WindowID, previous: WindowID?, work: DispatchWorkItem)?

    private var pendingChange: Change = []
    private var notifyScheduled = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init(config: Config) {
        self.config = config
        world = World(workspaceNames: config.workspaces, settings: config.layout)
        world.pinnedMonitors = config.workspaceMonitors
    }

    func start() {
        world.setMonitors(Displays.monitors())
        restoreSavedState()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.observe(app) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.forget(pid: pid) }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.observers[pid]?.reportFocusedWindow() }
            },
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenUnlocked() }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensWoke() }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceChanged() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            },
        ]
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        launchWatch = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let pids = (change.newValue ?? []).map(\.processIdentifier)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.appsOpening(pids) }
            }
        }
        notify(.all)
    }

    func restoreAllWindows() {
        let group = DispatchGroup()
        var batches: [pid_t: [FrameOp]] = [:]
        let monitor = world.monitor(world.focusedMonitor) ?? world.monitors.first
        var offset: CGFloat = 0
        for id in parked {
            guard let window = world.windows[id], let monitor else { continue }
            let area = monitor.visibleFrame
            let size = CGSize(width: min(window.frame.width, area.width * 0.8), height: min(window.frame.height, area.height * 0.8))
            let origin = CGPoint(x: area.midX - size.width / 2 + offset, y: area.midY - size.height / 2 + offset)
            offset = (offset + 28).truncatingRemainder(dividingBy: 280)
            batches[window.pid, default: []].append(FrameOp(id: id, frame: CGRect(origin: origin, size: size).integralized, park: false))
        }
        for (pid, ops) in batches {
            guard let observer = observers[pid] else { continue }
            group.enter()
            observer.apply(ops) { _ in group.leave() }
        }
        _ = group.wait(timeout: .now() + 1.5)
        parked.removeAll()
    }

    func reload(_ newConfig: Config) {
        let workspacesChanged = newConfig.workspaces != config.workspaces
        let layoutChanged = workspacesChanged || newConfig.layout != config.layout || newConfig.rules != config.rules
            || newConfig.onlyApps != config.onlyApps || newConfig.ignoredApps != config.ignoredApps || newConfig.workspaceMonitors != config.workspaceMonitors
        config = newConfig
        world.settings = newConfig.layout
        world.pinnedMonitors = newConfig.workspaceMonitors
        if workspacesChanged {
            let old = world
            world = World(workspaceNames: newConfig.workspaces, settings: newConfig.layout)
            world.pinnedMonitors = newConfig.workspaceMonitors
            world.setMonitors(Displays.monitors())
            for window in old.windows.values {
                let candidate = WindowCandidate(id: window.id, pid: window.pid, bundleID: window.bundleID, appName: window.appName, title: window.title, frame: window.frame, prefersFloating: window.isFloating)
                let target = newConfig.workspaces.contains(window.workspace) ? window.workspace : nil
                world.addWindow(candidate, workspace: target, floating: window.isFloating)
            }
        }
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        for (pid, observer) in observers where !config.manages(bundleID: observer.bundleID, appName: observer.appName) {
            forget(pid: pid)
        }
        if layoutChanged {
            lastApplied.removeAll()
            reconcile(label: "reload")
        }
        notify(.all)
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, isEnabled, pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              config.manages(bundleID: app.bundleIdentifier, appName: app.localizedName ?? "") else { return }
        let observer = AppObserver(app: app) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, pid: pid) }
            }
        }
        observers[pid] = observer
        observer.start()
    }

    private func forget(pid: pid_t, refocus: Bool = true) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        observer.stop()
        for (id, entry) in fullScreenWindows where entry.pid == pid { forgetFullScreen(id) }
        for (id, entry) in awayWindows where entry.pid == pid { forgetAway(id) }
        backgroundTabs = backgroundTabs.filter { offscreen[$0]?.pid != pid }
        lastUsed[pid] = nil
        openedFrom[pid] = nil
        let ids = world.windows.values.filter { $0.pid == pid }.map(\.id)
        var vacancy = recentlyClosed(pid)
        closing[pid] = nil
        for id in ids { vacancy.note(id, in: world) }
        if !vacancy.windows.isEmpty {
            vacancy.at = .now
            vacated[observer.bundleID ?? observer.appName] = vacancy
        }
        removeWindows(ids, refocus: refocus)
    }

    private func recentlyClosed(_ pid: pid_t) -> Vacancy {
        var vacancy = closing[pid] ?? Vacancy()
        vacancy.windows.removeAll { ContinuousClock.now - $0.at > .seconds(10) }
        let workspaces = Set(vacancy.windows.map(\.slot.workspace))
        vacancy.arrangements = vacancy.arrangements.filter { workspaces.contains($0.key) }
        return vacancy
    }

    private func appsOpening(_ pids: [pid_t]) {
        guard isEnabled, let workspace = world.focusedWorkspaceName else { return }
        let now = ContinuousClock.now
        openedFrom = openedFrom.filter { now - $0.value.at < .seconds(60) }
        for pid in pids where openedFrom[pid] == nil { openedFrom[pid] = Opening(workspace: workspace) }
    }

    private func openingWorkspace(of pid: pid_t) -> String? {
        guard var entry = openedFrom[pid] else { return nil }
        let now = ContinuousClock.now
        guard now - entry.at < .seconds(60), entry.shown.map({ now - $0 < .seconds(2) }) ?? true else {
            openedFrom[pid] = nil
            return nil
        }
        if entry.shown == nil {
            entry.shown = now
            openedFrom[pid] = entry
        }
        return entry.workspace
    }

    private func takeVacatedSlot(for observer: AppObserver, id: WindowID, title: String) -> TileSlot? {
        let key = observer.bundleID ?? observer.appName
        let now = ContinuousClock.now
        guard var vacancy = vacated[key], now - vacancy.at < .seconds(120) else {
            vacated[key] = nil
            return nil
        }
        defer { vacated[key] = vacancy.windows.isEmpty ? nil : vacancy }
        let restart = now - vacancy.at < .seconds(30) && vacancy.firstBack.map { now - $0 < .seconds(10) } ?? true
        let front = vacancy.windows.firstIndex(where: { $0.slot.workspace == world.focusedWorkspaceName })
        guard let index = restart ? vacancy.windows.firstIndex(where: { !title.isEmpty && $0.title == title }) ?? front ?? vacancy.windows.indices.first : front else { return nil }
        if vacancy.firstBack == nil { vacancy.firstBack = now }
        let left = vacancy.windows.remove(at: index)
        let name = left.slot.workspace
        let slot = vacancy.arrangements[name]?.slot(of: left.id, among: world.workspaces[name]?.tiled ?? [], workspace: name, renumbered: vacancy.returned)
        vacancy.returned[left.id] = id
        return slot ?? left.slot
    }

    private func rescanAll() {
        let front = frontFullScreenWindow().flatMap { fullScreenWindows[$0]?.pid }
        for observer in observers.values where observer.pid != front { observer.rescan() }
    }

    private func screenUnlocked() {
        if startupWaitsForUnlock {
            startupWaitsForUnlock = false
            launchMemoryUntil = .now + .seconds(18)
        }
        lookAgainAfterWaking()
    }

    private var spaceSettling: Bool {
        spaceChangedAt.map { ContinuousClock.now - $0 < .seconds(2) } ?? false
    }

    private var settledPass: DispatchWorkItem?

    private func reconcileWhenSpaceSettles() {
        guard settledPass == nil, let changed = spaceChangedAt else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.settledPass = nil
                self?.reconcile(label: "space settled")
            }
        }
        settledPass = work
        let wait = max(0.1, 2.1 - (ContinuousClock.now - changed) / .seconds(1))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func spaceChanged() {
        spaceChangedAt = .now
        if startupWaitsForUnlock, !Self.screenLocked, !Spaces.fullScreenInFront {
            startupWaitsForUnlock = false
            launchMemoryUntil = .now + .seconds(15)
        }
        rescanAll()
        for delay in [0.6, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.rescanAll() }
            }
        }
        for delay in [0.1, 0.35, 0.8, 2.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.checkTiledFrames()
                    if delay < 1 { self?.scheduleParkingCheck(after: 0) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.followSpace() }
        }
    }

    private func checkTiledFrames() {
        let tiles = lastApplied.filter { id, _ in !parked.contains(id) && adjusting[id] == nil && world.windows[id]?.isFloating == false }
        guard !tiles.isEmpty else { return }
        let real = Self.windowBounds(Set(tiles.keys))
        var misplaced = false
        for (id, placed) in tiles {
            guard let frame = real[id] else { continue }
            if abs(frame.minX - placed.minX) > 24 || abs(frame.minY - placed.minY) > 24 || abs(frame.width - placed.width) > 24 || abs(frame.height - placed.height) > 24 {
                lastApplied[id] = nil
                misplaced = true
            }
        }
        if misplaced { reconcile(label: "space settled") }
    }

    private func screensWoke() {
        guard !Self.screenLocked else { return }
        lookAgainAfterWaking()
    }

    private func lookAgainAfterWaking() {
        wokeAt = .now
        rescanAll()
        for delay in [1.0, 3.0, Self.wakeGrace + 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.rescanAll() }
            }
        }
    }

    private static let wakeGrace: Double = 6

    private func desktopOutOfSight(onScreen: Set<WindowID>) -> Bool {
        guard !world.windows.isEmpty else { return false }
        let visible = Set(world.windows.keys.filter(onScreen.contains))
        guard !visible.isEmpty else { return true }
        let bounds = Self.windowBounds(visible)
        let displays = world.monitors.map(\.frame)
        return visible.allSatisfy { id in bounds[id].map { frame in displays.contains { $0.isClose(to: frame, tolerance: 2) } } ?? false }
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private func screensChanged() {
        let monitors = Displays.monitors()
        guard monitors != world.monitors else { return }
        let framesMoved = Set(monitors.map(\.frame)) != Set(world.monitors.map(\.frame))
        world.setMonitors(monitors)
        if framesMoved { parked.removeAll() }
        reconcile(label: "displays")
        notify(.all)
    }

    private func handle(_ event: AppEvent, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        switch event {
        case .discovered(let snapshots):
            guard !Self.screenLocked else { return }
            let onScreen = Self.onScreenWindowIDs()
            let usable = snapshots.filter { snapshot in
                switch snapshot.kind {
                case .tile, .float: world.windows[snapshot.id] != nil || onScreen.contains(snapshot.id)
                case .unknown: world.windows[snapshot.id] != nil
                case .ignore: false
                }
            }
            for (id, entry) in offscreen where entry.pid == pid { offscreen[id] = nil }
            for snapshot in snapshots where (snapshot.kind == .tile || snapshot.kind == .float) && !onScreen.contains(snapshot.id) && world.windows[snapshot.id] == nil {
                offscreen[snapshot.id] = (pid, snapshot.frame)
            }
            if startupWaitsForUnlock, !usable.isEmpty, !Self.screenLocked, !Spaces.fullScreenInFront {
                startupWaitsForUnlock = false
                launchMemoryUntil = .now + .seconds(15)
            }
            let present = Set(usable.map(\.id))
            let waking = wokeAt.map { ContinuousClock.now - $0 < .seconds(Self.wakeGrace) } ?? false
            let spaceChanging = spaceChangedAt.map { ContinuousClock.now - $0 < .seconds(2) } ?? false
            let unseen = waking || spaceChanging || desktopOutOfSight(onScreen: onScreen)
            let listed = Set(snapshots.map(\.id))
            let leaving = world.windows.values.filter { $0.pid == pid && !present.contains($0.id) && !(unseen && !listed.contains($0.id)) }.map(\.id)
            if !leaving.isEmpty {
                log.notice("scan of \(observer.appName, privacy: .public): \(leaving.count) window(s) left, \(snapshots.count) listed")
            }
            let minimized = leaving.filter { id in snapshots.first { $0.id == id }?.isMinimized == true }
            for id in leaving where !minimized.contains(id) {
                let fullScreen = snapshots.first { $0.id == id }?.isFullScreen == true
                if fullScreen { noteFullScreen(id) }
                if spaceChanging || fullScreen { remember(id) } else if listed.contains(id) { forgetPlace(id) }
            }
            putAway(minimized, reason: .minimized, refocus: false)
            removeWindows(leaving.filter { !minimized.contains($0) }, refocus: false)
            noteAwayWindows(snapshots, of: pid, appName: observer.appName, onScreen: onScreen, unseen: unseen)
            noteFullScreenWindowsOnOtherSpaces(of: pid, appName: observer.appName)
            for snapshot in snapshots where snapshot.isFullScreen && fullScreenWindows[snapshot.id] == nil && world.windows[snapshot.id] == nil {
                let workspace = remembered[snapshot.id] ?? launchMemory[snapshot.id]?.workspace ?? world.focusedWorkspaceName ?? world.workspaceOrder[0]
                remembered[snapshot.id] = workspace
                fullScreenWindows[snapshot.id] = FullScreenWindow(pid: pid, workspace: workspace, appName: observer.appName, title: snapshot.title)
                watchFullScreenWindows()
                notify(.workspaces)
            }
            for snapshot in usable {
                if world.windows[snapshot.id] == nil, let sibling = tabSibling(of: snapshot, pid: pid), !onScreen.contains(sibling) {
                    adoptTab(snapshot, replacing: sibling, from: observer, focusing: false)
                    continue
                }
                consider(snapshot, from: observer)
            }
            if !unseen { mergeTabGroups(of: pid, onScreen: onScreen) }
            reconcile(label: "discover")
            observer.reportFocusedWindow()
        case .created(let snapshot):
            handleCreated(snapshot, from: observer)
        case .destroyed(let id):
            offscreen[id] = nil
            backgroundTabs.remove(id)
            forgetFullScreen(id)
            if awayWindows[id] != nil {
                forgetAway(id)
                forgetPlace(id)
            }
            if let tab = tabUnderneath(id) {
                closeTab(id, revealing: tab, from: observer)
            } else {
                var vacancy = recentlyClosed(pid)
                vacancy.note(id, in: world)
                if !vacancy.windows.isEmpty { closing[pid] = vacancy }
                removeWindows([id], refocus: true)
            }
        case .focused(let id):
            guard let id, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            if fullScreenWindows[id] != nil { return }
            if world.windows[id] == nil, !ignored.contains(id) {
                observer.reportWindow(id)
                return
            }
            osFocused(id)
        case .frameChanged(let id, let frame):
            frameReported(id, frame)
        case .titleChanged(let id, let title):
            world.updateWindow(id, title: title)
            if awayWindows[id] != nil, !title.isEmpty { awayWindows[id]?.title = title }
        case .minimized(let id):
            putAway([id], reason: .minimized)
        case .fullScreen(let id):
            noteFullScreen(id)
            remember(id)
            removeWindows([id], refocus: false)
        case .restored(let snapshot):
            let fromDock = awayWindows[snapshot.id]?.reason == .minimized
            let asked = restoring?.id == snapshot.id
            consider(snapshot, from: observer)
            if fromDock, !asked, world.windows[snapshot.id] != nil {
                activate(snapshot.id)
            } else {
                reconcile(label: "restore")
            }
        case .hidden:
            putAway(world.windows.values.filter { $0.pid == pid }.map(\.id), reason: .hidden)
        case .shown:
            observer.rescan()
        case .unavailable:
            log.info("\(observer.appName, privacy: .public) never answered Accessibility requests; leaving it alone")
            observers[pid] = nil
            observer.stop()
        }
    }

    private func handleCreated(_ snapshot: WindowSnapshot, from observer: AppObserver, retry: Bool = true, attempt: Int = 0) {
        if world.windows[snapshot.id] == nil, snapshot.kind != .ignore, let sibling = tabSibling(of: snapshot, pid: observer.pid) {
            let onScreen = Self.onScreenWindowIDs()
            if onScreen.contains(snapshot.id) && !onScreen.contains(sibling) {
                adoptTab(snapshot, replacing: sibling, from: observer)
                return
            }
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    MainActor.assumeIsolated { self?.handleCreated(snapshot, from: observer, retry: false) }
                }
                return
            }
            if !onScreen.contains(snapshot.id) {
                offscreen[snapshot.id] = (observer.pid, snapshot.frame)
                backgroundTabs.insert(snapshot.id)
                return
            }
        }
        if world.windows[snapshot.id] == nil, snapshot.kind == .tile || snapshot.kind == .float, !Self.onScreenWindowIDs().contains(snapshot.id) {
            if attempt < 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.15 : 0.6)) { [weak self] in
                    MainActor.assumeIsolated { self?.handleCreated(snapshot, from: observer, retry: false, attempt: attempt + 1) }
                }
            } else {
                offscreen[snapshot.id] = (observer.pid, snapshot.frame)
            }
            return
        }
        offscreen[snapshot.id] = nil
        let wasKnown = world.windows[snapshot.id] != nil
        consider(snapshot, from: observer)
        guard !wasKnown, world.windows[snapshot.id] != nil else { return }
        reconcile(label: "new window")
        observer.reportFocusedWindow()
    }

    private func tabSibling(of snapshot: WindowSnapshot, pid: pid_t) -> WindowID? {
        world.windows.values.first { window in
            guard window.pid == pid, window.id != snapshot.id else { return false }
            if !parked.contains(window.id) { return window.frame.isClose(to: snapshot.frame, tolerance: 3) }
            var bounds = CGRect.zero
            return planets_window_bounds(window.id, &bounds) && bounds.isClose(to: snapshot.frame, tolerance: 3)
        }?.id
    }

    private func mergeTabGroups(of pid: pid_t, onScreen: Set<WindowID>) {
        let windows = world.windows.values.filter { $0.pid == pid }
        guard windows.count > 1 else { return }
        var bounds: [WindowID: CGRect] = [:]
        for window in windows {
            var frame = CGRect.zero
            if planets_window_bounds(window.id, &frame) { bounds[window.id] = frame }
        }
        for hidden in windows where !onScreen.contains(hidden.id) && world.windows[hidden.id] != nil {
            guard let shared = bounds[hidden.id], let front = windows.first(where: { candidate in
                candidate.id != hidden.id && onScreen.contains(candidate.id) && world.windows[candidate.id] != nil
                    && bounds[candidate.id].map { $0.isClose(to: shared, tolerance: 3) } == true
            }) else { continue }
            log.notice("\(front.appName, privacy: .public): a tab was a tile of its own; it takes its group's place")
            let candidate = WindowCandidate(id: front.id, pid: front.pid, bundleID: front.bundleID, appName: front.appName, title: front.title, frame: front.frame, prefersFloating: front.isFloating)
            world.removeWindow(front.id)
            world.replaceWindow(hidden.id, with: candidate)
            offscreen[hidden.id] = (hidden.pid, hidden.frame)
            backgroundTabs.insert(hidden.id)
            backgroundTabs.remove(front.id)
            lastApplied[front.id] = lastApplied.removeValue(forKey: hidden.id)
            appliedAt[front.id] = appliedAt.removeValue(forKey: hidden.id)
            if parked.remove(hidden.id) != nil { parked.insert(front.id) } else { parked.remove(front.id) }
            reportedAt[hidden.id] = nil
            notify(.all)
        }
    }

    private func adoptTab(_ snapshot: WindowSnapshot, replacing old: WindowID, from observer: AppObserver, focusing: Bool = true) {
        guard let previous = world.windows[old] else { return }
        let candidate = WindowCandidate(id: snapshot.id, pid: observer.pid, bundleID: observer.bundleID, appName: observer.appName, title: snapshot.title, frame: snapshot.frame, prefersFloating: snapshot.kind == .float)
        world.replaceWindow(old, with: candidate)
        offscreen[old] = (previous.pid, previous.frame)
        offscreen[snapshot.id] = nil
        backgroundTabs.insert(old)
        backgroundTabs.remove(snapshot.id)
        if parked.remove(old) != nil { parked.insert(snapshot.id) }
        lastApplied[snapshot.id] = lastApplied.removeValue(forKey: old)
        appliedAt[snapshot.id] = appliedAt.removeValue(forKey: old)
        reportedAt[snapshot.id] = .now
        reportedAt[old] = nil
        if focusing { world.noteFocus(snapshot.id) }
        reconcile(label: "tab")
        notify(.all)
    }

    private func tabUnderneath(_ id: WindowID) -> WindowID? {
        guard let window = world.windows[id] else { return nil }
        let tabs = offscreen.filter { $0.value.pid == window.pid && world.windows[$0.key] == nil }
        guard !tabs.isEmpty else { return nil }
        let onScreen = Self.onScreenWindowIDs()
        return tabs.keys.first(where: onScreen.contains)
            ?? tabs.first { $0.value.frame.isClose(to: window.frame, tolerance: 3) }?.key
            ?? tabs.keys.first(where: backgroundTabs.contains)
    }

    private func closeTab(_ id: WindowID, revealing tab: WindowID, from observer: AppObserver) {
        guard let behind = offscreen[tab], let frame = world.windows[id]?.frame else { return }
        let wasBackground = backgroundTabs.contains(tab)
        let snapshot = WindowSnapshot(id: tab, title: "", frame: frame, kind: .tile, subrole: "")
        adoptTab(snapshot, replacing: id, from: observer)
        offscreen[id] = nil
        lastApplied[id] = nil
        appliedAt[id] = nil
        observer.reportWindow(tab)
        confirmTab(tab, from: observer, until: .now + .milliseconds(250), behind: behind, wasBackground: wasBackground)
    }

    private func confirmTab(_ tab: WindowID, from observer: AppObserver, until deadline: ContinuousClock.Instant,
                            behind: (pid: pid_t, frame: CGRect), wasBackground: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let standIn = self.world.windows[tab] else { return }
                let onScreen = Self.onScreenWindowIDs()
                if onScreen.contains(tab) { return }
                if let shown = self.offscreen.first(where: { $0.value.pid == observer.pid && self.world.windows[$0.key] == nil && onScreen.contains($0.key) })?.key {
                    self.adoptTab(WindowSnapshot(id: shown, title: "", frame: standIn.frame, kind: .tile, subrole: ""), replacing: tab, from: observer)
                    self.restoreTab(tab, behind: behind, wasBackground: wasBackground)
                    observer.reportWindow(shown)
                } else if ContinuousClock.now < deadline {
                    self.confirmTab(tab, from: observer, until: deadline, behind: behind, wasBackground: wasBackground)
                } else {
                    self.removeWindows([tab], refocus: true)
                    self.restoreTab(tab, behind: behind, wasBackground: wasBackground)
                }
            }
        }
    }

    private func restoreTab(_ tab: WindowID, behind: (pid: pid_t, frame: CGRect), wasBackground: Bool) {
        var frame = CGRect.zero
        guard planets_window_bounds(tab, &frame) else { return }
        offscreen[tab] = behind
        if wasBackground { backgroundTabs.insert(tab) } else { backgroundTabs.remove(tab) }
    }

    private func remember(_ id: WindowID) {
        guard let window = world.windows[id] else { return }
        remembered[id] = window.workspace
        rememberedSlot[id] = world.slot(of: id)
        if floatsByChoice(id) { rememberedFloating.insert(id) } else { rememberedFloating.remove(id) }
    }

    private func floatsByChoice(_ id: WindowID) -> Bool {
        world.windows[id]?.isFloating == true && !world.autoFloated.contains(id)
    }

    private func forgetPlace(_ id: WindowID) {
        remembered[id] = nil
        rememberedFloating.remove(id)
        rememberedSlot[id] = nil
        launchMemory[id] = nil
    }

    private func putAway(_ ids: [WindowID], reason: AwayWindow.Reason, refocus: Bool = true) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let window = world.windows[id] else { continue }
            remember(id)
            awayWindows[id] = AwayWindow(pid: window.pid, workspace: window.workspace, appName: window.appName, title: window.title, reason: reason)
        }
        removeWindows(ids, refocus: refocus)
    }

    private func forgetAway(_ id: WindowID) {
        guard awayWindows.removeValue(forKey: id) != nil else { return }
        notify(.workspaces)
    }

    private func noteAwayWindows(_ snapshots: [WindowSnapshot], of pid: pid_t, appName: String, onScreen: Set<WindowID>, unseen: Bool) {
        let hidden = NSRunningApplication(processIdentifier: pid)?.isHidden == true
        let bundleID = observers[pid]?.bundleID
        for snapshot in snapshots where awayWindows[snapshot.id] == nil && world.windows[snapshot.id] == nil && !ignored.contains(snapshot.id) {
            if config.rule(bundleID: bundleID, appName: appName, title: snapshot.title)?.ignore == true { continue }
            let saved = remembered[snapshot.id] ?? launchMemory[snapshot.id]?.workspace
            let reason: AwayWindow.Reason
            if snapshot.isMinimized {
                reason = .minimized
            } else if hidden, saved != nil, snapshot.kind == .tile || snapshot.kind == .float, !onScreen.contains(snapshot.id) {
                reason = .hidden
            } else {
                continue
            }
            let workspace = saved ?? world.focusedWorkspaceName ?? world.workspaceOrder[0]
            remembered[snapshot.id] = workspace
            if launchMemory.removeValue(forKey: snapshot.id)?.floating == true { rememberedFloating.insert(snapshot.id) }
            awayWindows[snapshot.id] = AwayWindow(pid: pid, workspace: workspace, appName: appName, title: snapshot.title, reason: reason)
            notify(.workspaces)
        }
        guard !unseen else { return }
        let listed = Set(snapshots.map(\.id))
        for (id, entry) in awayWindows where entry.pid == pid && !listed.contains(id) && (entry.reason == .minimized || !hidden) {
            forgetAway(id)
            forgetPlace(id)
        }
    }

    func awayWindows(on workspace: String) -> [(id: WindowID, window: AwayWindow)] {
        awayWindows.filter { $0.value.workspace == workspace }.sorted { $0.value.since > $1.value.since }.map { ($0.key, $0.value) }
    }

    func restore(_ id: WindowID) {
        guard let entry = awayWindows[id], let observer = observers[entry.pid] else { return }
        let until = ContinuousClock.now + .seconds(1.5)
        restoring = (id, until)
        if entry.workspace == World.scratchpad {
            perform(.scratchpad(.on))
        } else {
            showingFullScreen[entry.workspace] = nil
            perform(.workspace(.named(entry.workspace)))
        }
        switch entry.reason {
        case .minimized: observer.unminimize(id)
        case .hidden: NSRunningApplication(processIdentifier: entry.pid)?.unhide()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.restoring?.id == id else { return }
                self.restoring = nil
                self.focusAfterSwitch()
            }
        }
    }

    private func finishRestoring() {
        guard let id = restoring?.id, world.windows[id] != nil else { return }
        restoring = nil
        activate(id)
    }

    private func noteWindowUsed() {
        if let id = world.focusedWindow, let pid = world.windows[id]?.pid { lastUsed[pid] = id }
    }

    private func consider(_ snapshot: WindowSnapshot, from observer: AppObserver) {
        if snapshot.kind == .tile || snapshot.kind == .float {
            forgetFullScreen(snapshot.id)
            forgetAway(snapshot.id)
        }
        if world.windows[snapshot.id] != nil {
            world.updateWindow(snapshot.id, title: snapshot.title)
            return
        }
        guard snapshot.kind == .tile || snapshot.kind == .float, !ignored.contains(snapshot.id) else { return }
        let rule = config.rule(bundleID: observer.bundleID, appName: observer.appName, title: snapshot.title)
        if rule?.ignore == true {
            ignored.insert(snapshot.id)
            return
        }
        let candidate = WindowCandidate(
            id: snapshot.id, pid: observer.pid, bundleID: observer.bundleID, appName: observer.appName,
            title: snapshot.title, frame: snapshot.frame, prefersFloating: snapshot.kind == .float
        )
        let restored = launchMemoryActive ? launchMemory.removeValue(forKey: snapshot.id) : nil
        let returning = remembered.removeValue(forKey: snapshot.id)
        let returningSlot = rememberedSlot.removeValue(forKey: snapshot.id)
        let floating = rule?.float ?? (rememberedFloating.remove(snapshot.id) != nil || restored?.floating == true ? true : nil)
        let known = rule?.workspace ?? returning ?? restored?.workspace
        let vacated = known == nil && floating != true && snapshot.kind == .tile ? takeVacatedSlot(for: observer, id: snapshot.id, title: snapshot.title) : nil
        let opening = openingWorkspace(of: observer.pid)
        let workspace = known ?? vacated?.workspace ?? opening
        let restoredSlot = restored.flatMap { _ in
            workspace.flatMap { name in launchArrangements[name]?.slot(of: snapshot.id, among: world.workspaces[name]?.tiled ?? [], workspace: name) }
        }
        let slot = floating == true || snapshot.kind != .tile ? nil
            : returningSlot.flatMap { $0.workspace == workspace ? $0 : nil } ?? restoredSlot ?? vacated
        world.addWindow(candidate, workspace: workspace, floating: floating, slot: slot)
        joinedAt[snapshot.id] = .now
        if let workspace, workspace != known, !world.isVisible(workspace) { placedAway[snapshot.id] = .now }
        if world.windows[snapshot.id]?.isFloating == true {
            if world.monitors.contains(where: { $0.visibleFrame.insetBy(dx: -2, dy: -2).contains(snapshot.frame) }) {
                lastApplied[snapshot.id] = snapshot.frame
            } else {
                world.centerFloating(snapshot.id)
            }
        }
        if restoring?.id == snapshot.id { finishRestoring() }
        notify(.workspaces)
    }

    private func removeWindows(_ ids: [WindowID], refocus: Bool) {
        guard !ids.isEmpty else { return }
        if let pending = pendingReveal, let previous = pending.previous, ids.contains(previous) {
            pending.work.cancel()
            pendingReveal = nil
        }
        var successor: WindowID?
        var emptiedFocused = false
        for id in ids {
            let wasOnFocused = world.workspace(of: id) == world.focusedWorkspaceName
            if let next = world.removeWindow(id) { successor = next }
            if wasOnFocused, world.focusedWorkspace?.isEmpty == true { emptiedFocused = true }
            lastApplied[id] = nil
            appliedBefore[id] = nil
            appliedAt[id] = nil
            placedAway[id] = nil
            joinedAt[id] = nil
            refusalAsks[id] = nil
            passOf[id] = nil
            reportedAt[id] = nil
            parked.remove(id)
            adjusting[id] = nil
            ignored.remove(id)
        }
        reconcile(label: "close")
        if refocus, let successor {
            focus(successor)
        } else if refocus, emptiedFocused {
            focusNothing()
        }
        notify(.all)
    }

    private func osFocused(_ id: WindowID) {
        guard let window = world.windows[id] else { return }
        let now = ContinuousClock.now
        if let since = placedAway.removeValue(forKey: id), now - since < .seconds(10), !world.isVisible(window.workspace) {
            trace("\(window.appName) came forward on workspace \(window.workspace) as it opened; staying")
            focusAfterSwitch()
            return
        }
        if let intent = focusIntent, now < intent.deadline {
            if intent.id == id {
                focusIntent = nil
            } else if !world.isVisible(window.workspace) {
                return
            }
        }
        pendingReveal?.work.cancel()
        pendingReveal = nil
        if !world.isVisible(window.workspace), window.workspace != World.scratchpad,
           let current = world.focusedWindow, current != id, world.windows[current]?.pid == window.pid {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingReveal?.id == id else { return }
                    self.pendingReveal = nil
                    self.applyFocus(id)
                }
            }
            pendingReveal = (id, current, work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        applyFocus(id)
    }

    private func applyFocus(_ id: WindowID) {
        guard world.windows[id] != nil else { return }
        defer { keepFloatingOnTop() }
        let outcome = world.noteFocus(id)
        if case .revealedWorkspace(let name) = outcome {
            reconcile(label: "reveal")
            onWorkspaceSwitch?(name)
            notify(.all)
        } else if outcome == .revealedScratchpad || outcome == .hidScratchpad {
            reconcile(label: "scratchpad")
            notify(.all)
        } else {
            reconcile(label: "focus")
            notify(.focus)
        }
    }

    private func acceptMinimum(_ id: WindowID, frame: CGRect, target: CGRect) {
        guard let window = world.windows[id] else { return }
        let wider = frame.width > target.width + 24, taller = frame.height > target.height + 24
        world.noteMinimumSize(id, CGSize(width: wider ? frame.width : 0, height: taller ? frame.height : 0))
        for floated in world.makeRoom(on: window.workspace) {
            log.info("no room on workspace \(window.workspace, privacy: .public) for \(self.world.windows[floated]?.appName ?? "?", privacy: .public); floating it until there is")
            lastApplied[floated] = nil
        }
        lastApplied[id] = nil
        reconcile(label: "make room")
        notify(.all)
    }

    private func acceptCap(_ id: WindowID, frame: CGRect, target: CGRect) {
        guard let window = world.windows[id] else { return }
        log.info("\(window.appName, privacy: .public) caps its window at \(Int(frame.width))×\(Int(frame.height)); centring it")
        let unlimited = CGFloat.greatestFiniteMagnitude
        world.limitSize(id, to: CGSize(width: frame.width < target.width - 24 ? frame.width : unlimited,
                                       height: frame.height < target.height - 24 ? frame.height : unlimited))
    }

    private func confirmRefusal(of id: WindowID, round: Int = 1) {
        let ask = (refusalAsks[id] ?? 0) + 1
        refusalAsks[id] = ask
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.refusalAsks[id] == ask else { return }
                let minimum = self.minCandidates.removeValue(forKey: id), cap = self.capCandidates.removeValue(forKey: id)
                guard let target = self.lastApplied[id], let frame = Self.windowBounds([id])[id] else { return }
                let wider = frame.width > target.width + 24 || frame.height > target.height + 24
                let narrower = frame.width < target.width - 24 || frame.height < target.height - 24
                if let minimum, frame.size.isClose(to: minimum, tolerance: 4), wider {
                    self.acceptMinimum(id, frame: frame, target: target)
                } else if let cap, frame.size.isClose(to: cap, tolerance: 4), narrower {
                    self.acceptCap(id, frame: frame, target: target)
                    self.lastApplied[id] = nil
                    self.reconcile(label: "fit")
                    self.notify(.frames)
                } else if wider || narrower, round < 3 {
                    if wider { self.minCandidates[id] = frame.size } else { self.capCandidates[id] = frame.size }
                    self.lastApplied[id] = nil
                    self.reconcile(label: "fit")
                    self.confirmRefusal(of: id, round: round + 1)
                }
            }
        }
    }

    private func confirmSilentFrames(_ ids: [WindowID], pass: Int) {
        guard !ids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var focusedChanged = false
                for id in ids where self.passOf[id] == pass && self.adjusting[id] == nil && self.dragging?.id != id {
                    guard let target = self.lastApplied[id], let applied = self.appliedAt[id],
                          self.reportedAt[id].map({ $0 < applied }) ?? true else { continue }
                    var frame = CGRect.zero
                    guard planets_window_bounds(id, &frame), !frame.isClose(to: target, tolerance: 0.5),
                          abs(frame.minX - target.minX) <= 2, abs(frame.minY - target.minY) <= 2,
                          abs(frame.width - target.width) <= 24, abs(frame.height - target.height) <= 24 else { continue }
                    self.world.noteFrame(id, frame)
                    self.reportedAt[id] = .now
                    if id == self.world.focusedWindow { focusedChanged = true }
                }
                if focusedChanged { self.notify(.frames) }
            }
        }
    }

    private func frameReported(_ id: WindowID, _ frame: CGRect) {
        guard let window = world.windows[id] else { return }
        if dragging == nil { noticeUserGesture(id, from: window.frame, to: frame) }
        if dragging?.id == id {
            world.noteFrame(id, frame)
            notify(.frames)
            return
        }
        let onScreen = world.monitors.contains { $0.frame.contains(frame.center) }
        if parked.contains(id) {
            if onScreen { repark(id) }
            return
        }
        guard onScreen else { return }
        world.noteFrame(id, frame)
        reportedAt[id] = .now
        if window.isFloating {
            lastApplied[id] = frame
            if window.workspace != World.scratchpad, let monitor = world.monitors.first(where: { $0.frame.contains(frame.center) }),
               let name = world.visible[monitor.id], name != window.workspace {
                world.moveWindow(id, to: .named(name), follow: false)
                world.noteFocus(id)
                notify(.all)
                return
            }
            if id == world.focusedWindow { notify(.frames) }
            return
        }
        if let limit = world.maxSizes[id], frame.width > limit.width + 2 || frame.height > limit.height + 2,
           appliedAt[id].map({ ContinuousClock.now - $0 > .milliseconds(500) }) ?? true {
            world.limitSize(id, to: nil)
            lastApplied[id] = nil
            reconcile(label: "uncap")
        }
        guard let target = lastApplied[id] else { return }
        let justPlaced = appliedAt[id].map { ContinuousClock.now - $0 < .seconds(1) } ?? false
        if justPlaced, !frame.isClose(to: target), appliedBefore[id]?.contains(where: { frame.isClose(to: $0) }) == true { return }
        if frame.isClose(to: target) {
            minCandidates[id] = nil
            capCandidates[id] = nil
            refusalAsks[id, default: 0] += 1
            if id == world.focusedWindow { notify(.frames) }
            return
        }
        if NSEvent.pressedMouseButtons & 1 != 0, let press, liveShown[id] == nil, target.insetBy(dx: -8, dy: -8).contains(press) {
            if adjusting[id] == nil { adjusting[id] = target }
            startAdjustTimer()
            followResize(id, to: frame)
            if id == world.focusedWindow { notify(.frames) }
            return
        }
        let sameCorner = abs(frame.minX - target.minX) <= 2 && abs(frame.minY - target.minY) <= 2
        if justPlaced, !adjusting.isEmpty || dragging != nil { return }
        if justPlaced, spaceSettling {
            lastApplied[id] = nil
            reconcileWhenSpaceSettles()
            return
        }
        let wider = frame.width > target.width + 24, taller = frame.height > target.height + 24
        let narrower = frame.width < target.width - 24, shorter = frame.height < target.height - 24
        if justPlaced, wider || taller || narrower || shorter, let joined = joinedAt[id], ContinuousClock.now - joined < Self.opening {
            retileWhenSettled(id, joined: joined)
            return
        }
        if justPlaced {
            if wider || taller, sameCorner || frame.insetBy(dx: -2, dy: -2).contains(target) {
                if let candidate = minCandidates[id], candidate.isClose(to: frame.size, tolerance: 4) { return }
                trace("frame \(id): \(Queries.describe(frame)), placed \(Queries.describe(target)): minimum candidate")
                minCandidates[id] = frame.size
                lastApplied[id] = nil
                reconcile(label: "fit")
                confirmRefusal(of: id)
                return
            }
        }
        if justPlaced, sameCorner {
            if narrower || shorter {
                if let candidate = capCandidates[id], candidate.isClose(to: frame.size, tolerance: 4) { return }
                trace("frame \(id): \(Queries.describe(frame)), placed \(Queries.describe(target)): cap candidate")
                capCandidates[id] = frame.size
                lastApplied[id] = nil
                reconcile(label: "fit")
                confirmRefusal(of: id)
                notify(.frames)
                return
            }
            capCandidates[id] = nil
            minCandidates[id] = nil
            refusalAsks[id, default: 0] += 1
            if id == world.focusedWindow { notify(.frames) }
            return
        }
        trace("frame \(id): \(Queries.describe(frame)), placed \(Queries.describe(target)), just placed \(justPlaced): snap back")
        snapBack.insert(id)
        scheduleSnapBack()
    }

    private func retileWhenSettled(_ id: WindowID, joined: ContinuousClock.Instant) {
        guard settling.insert(id).inserted else { return }
        let wait = joined + Self.opening - .now
        DispatchQueue.main.asyncAfter(deadline: .now() + PerformanceLog.milliseconds(wait) / 1000) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settling.remove(id) != nil, self.world.windows[id] != nil else { return }
                if let size = Self.windowBounds([id])[id]?.size {
                    self.minCandidates[id] = size
                    self.capCandidates[id] = size
                }
                self.lastApplied[id] = nil
                self.reconcile(label: "fit")
                self.confirmRefusal(of: id)
            }
        }
    }

    private func repark(_ id: WindowID) {
        let now = ContinuousClock.now
        var entry = reparkCounts[id] ?? (0, now)
        if now - entry.since > .seconds(5) { entry = (0, now) }
        entry.count += 1
        reparkCounts[id] = entry
        guard entry.count <= 3 else { return }
        parked.remove(id)
        reconcile(label: "repark")
    }

    private func scheduleParkingCheck(after delay: Double = 0.15) {
        parkingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkParking() }
        }
        parkingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkParking() {
        guard isEnabled, !parked.isEmpty else { return }
        let bounds = Self.windowBounds(parked)
        var escaped: [WindowID] = []
        for id in parked {
            guard let frame = bounds[id] else { continue }
            let visible = world.monitors.reduce(CGFloat(0)) { $0 + frame.intersection($1.frame).area }
            if visible > 600 { escaped.append(id) }
        }
        for id in parked where !escaped.contains(id) { escapeCounts[id] = nil }
        guard !escaped.isEmpty else { return }
        var attempt = 0
        for id in escaped {
            let count = (escapeCounts[id] ?? 0) + 1
            escapeCounts[id] = count
            attempt = max(attempt, count)
            parked.remove(id)
        }
        log.info("re-parking \(escaped.count, privacy: .public) window(s) that came back into view")
        reconcile(label: "repark")
        let delays: [Double] = [0.3, 1, 3, 6]
        scheduleParkingCheck(after: delays[min(attempt - 1, delays.count - 1)])
    }

    static func windowBounds(_ ids: Set<WindowID>) -> [WindowID: CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [WindowID: CGRect] = [:]
        for info in list {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, ids.contains(id),
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { continue }
            result[id] = rect
        }
        return result
    }

    private func scheduleSnapBack() {
        guard !snapBackScheduled else { return }
        snapBackScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapBackScheduled = false
                let real = Self.windowBounds(self.snapBack)
                for id in self.snapBack {
                    guard let placed = self.lastApplied[id], let frame = real[id], !frame.isClose(to: placed) else { continue }
                    self.lastApplied[id] = nil
                }
                self.snapBack.removeAll()
                self.reconcile(label: "snap back")
            }
        }
    }

    private func startAdjustTimer() {
        guard adjustTimer == nil else { return }
        adjustTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAdjustEnded() }
        }
    }

    private func checkAdjustEnded() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        adjustTimer?.invalidate()
        adjustTimer = nil
        let drop = Displays.toGlobal(NSEvent.mouseLocation)
        let gestures = adjusting, followedFrames = liveFrames
        adjusting.removeAll()
        for tile in liveShown.keys { lastApplied[tile] = nil }
        liveShown.removeAll()
        liveStart.removeAll()
        liveFrames.removeAll()
        for (id, start) in gestures {
            guard let window = world.windows[id], !window.isFloating else { continue }
            let end = window.frame
            let followed = followedFrames[id]
            if followed == nil && abs(end.width - start.width) < 4 && abs(end.height - start.height) < 4 {
                finishMove(id, at: drop)
            } else {
                applyEdges(id, from: followed ?? start, to: end, threshold: followed == nil ? 2 : 0.5)
            }
            lastApplied[id] = nil
        }
        reconcile(label: "mouse")
        notify(.all)
    }

    private func followResize(_ id: WindowID, to frame: CGRect) {
        guard let start = adjusting[id], let window = world.windows[id], !window.isFloating else { return }
        let last = liveFrames[id] ?? start
        guard abs(frame.width - last.width) > 1 || abs(frame.height - last.height) > 1 else { return }
        applyEdges(id, from: last, to: frame, threshold: 0.5)
        liveFrames[id] = frame
        requestLivePass()
    }

    private func applyEdges(_ id: WindowID, from start: CGRect, to end: CGRect, threshold: CGFloat) {
        let left = start.minX - end.minX, right = end.maxX - start.maxX
        let top = start.minY - end.minY, bottom = end.maxY - start.maxY
        if abs(left) > threshold || abs(right) > threshold {
            abs(left) > abs(right)
                ? world.resize(id, .width, by: left, edge: .left)
                : world.resize(id, .width, by: right, edge: .right)
        }
        if abs(top) > threshold || abs(bottom) > threshold {
            abs(top) > abs(bottom)
                ? world.resize(id, .height, by: top, edge: .up)
                : world.resize(id, .height, by: bottom, edge: .down)
        }
    }

    private func followMove(_ id: WindowID, pointer: CGPoint) {
        guard config.dragToSwap, let window = world.windows[id], !window.isFloating else { return }
        if moveOrigin?.id != id {
            let tiles = world.workspaces[window.workspace]?.tiled ?? []
            moveOrigin = (id, Dictionary(uniqueKeysWithValues: tiles.compactMap { tile in lastApplied[tile].map { (tile, $0) } }))
            liveSwapTarget = nil
        }
        guard let origin = moveOrigin else { return }
        let target = origin.frames.first { $0.key != id && $0.value.insetBy(dx: 16, dy: 16).contains(pointer) }?.key
        guard target != liveSwapTarget else { return }
        if target == nil, origin.frames[id]?.contains(pointer) != true { return }
        if let current = liveSwapTarget { world.swapWindows(id, current) }
        if let target { world.swapWindows(id, target) }
        liveSwapTarget = target
        requestLivePass()
    }

    private func finishMove(_ id: WindowID, at drop: CGPoint) {
        defer {
            moveOrigin = nil
            liveSwapTarget = nil
        }
        guard config.dragToSwap, let window = world.windows[id] else { return }
        let home = world.monitorShowing(window.workspace)
        let landing = world.monitors.first { $0.frame.contains(drop) }?.id
        if moveOrigin?.id == id, landing == nil || landing == home { return }
        if moveOrigin?.id == id, let target = liveSwapTarget { world.swapWindows(id, target) }
        world.dropWindow(id, at: drop)
    }

    private func requestLivePass() {
        if liveInFlight {
            livePending = true
            return
        }
        liveInFlight = true
        let done: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.liveInFlight = false
            if self.livePending {
                self.livePending = false
                self.requestLivePass()
            }
        }
        if liveFrames.isEmpty { reconcile(label: "live", applied: done) } else { liveResizePass(done: done) }
    }

    private func liveResizePass(done: @escaping @MainActor () -> Void) {
        let placements = world.placements()
        var batches: [pid_t: [FrameOp]] = [:]
        let start = ContinuousClock.now
        for (id, placement) in placements {
            guard case .frame(let target) = placement, adjusting[id] == nil, let window = world.windows[id], !window.isFloating,
                  let before = liveStart[id] ?? lastApplied[id] else { continue }
            if liveStart[id] == nil { liveStart[id] = before }
            let shown = liveShown[id] ?? before
            guard let (frame, fitted) = slidFrame(id, target: target, before: before, shown: shown, workspace: window.workspace),
                  !frame.isClose(to: shown, tolerance: 0.5) else { continue }
            let resized = !frame.size.isClose(to: shown.size, tolerance: 0.5)
            if resized, let fitted {
                batches[window.pid, default: []].append(FrameOp(id: id, frame: fitted, park: false))
                batches[window.pid, default: []].append(FrameOp(id: id, frame: frame, park: true))
            } else {
                batches[window.pid, default: []].append(FrameOp(id: id, frame: frame, park: !resized))
            }
            liveShown[id] = frame
            lastApplied[id] = frame
            appliedAt[id] = start
        }
        apply(batches, done: done)
    }

    private func slidFrame(_ id: WindowID, target: CGRect, before: CGRect, shown: CGRect, workspace: String) -> (CGRect, CGRect?)? {
        guard let area = world.usableArea(for: workspace) else { return (target, nil) }
        let dragged = liveFrames.values.first
        var origin = target.origin
        var size = shown.size
        var fitted = target
        for horizontal in [true, false] {
            let low = { (rect: CGRect) in horizontal ? rect.minX : rect.minY }
            let high = { (rect: CGRect) in horizontal ? rect.maxX : rect.maxY }
            let lowMoved = abs(low(target) - low(before)) > 0.5
            let highMoved = abs(high(target) - high(before)) > 0.5
            let length = high(target) - low(target)
            if !lowMoved && !highMoved {
                if horizontal { size.width = target.width } else { size.height = target.height }
                continue
            }
            if lowMoved && highMoved { return (target, nil) }
            var current = horizontal ? size.width : size.height
            if current < length - 0.5 { current = min(length + 200, horizontal ? area.width : area.height) }
            let spare = current - length
            var start: CGFloat
            if lowMoved {
                if spare > 0.5, high(target) < (horizontal ? area.maxX : area.maxY) - 1 { return (target, nil) }
                start = low(target)
            } else {
                if spare > 0.5 {
                    let under = horizontal
                        ? CGRect(x: target.maxX, y: target.minY, width: spare, height: target.height)
                        : CGRect(x: target.minX, y: target.maxY, width: target.width, height: spare)
                    let slack = world.settings.innerGap + 2
                    guard let dragged, dragged.insetBy(dx: -slack, dy: -slack).contains(under) else { return (target, nil) }
                }
                start = low(target)
            }
            if horizontal {
                size.width = current
                origin.x = start
                fitted.size.width = current
                fitted.origin.x = min(max(start, area.minX), area.maxX - current)
            } else {
                size.height = current
                origin.y = start
                fitted.size.height = current
                fitted.origin.y = min(max(start, area.minY), area.maxY - current)
            }
        }
        if fitted.width == target.width { fitted.origin.x = origin.x }
        if fitted.height == target.height { fitted.origin.y = origin.y }
        return (CGRect(origin: origin, size: size), fitted)
    }

    func pointerDown(at point: CGPoint) {
        if userMove != nil || userResize != nil { endUserGesture() }
        press = point
    }

    private func noticeUserGesture(_ id: WindowID, from old: CGRect, to new: CGRect) {
        guard userMove == nil, userResize == nil, let press, old.contains(press),
              NSEvent.pressedMouseButtons & 1 != 0, !parked.contains(id),
              appliedAt[id].map({ ContinuousClock.now - $0 > .milliseconds(300) }) ?? true else { return }
        if new.size.isClose(to: old.size) {
            guard !new.origin.equalTo(old.origin) else { return }
            userMove = TitleBarMove(id: id, grab: press, start: old, pointer: Displays.toGlobal(NSEvent.mouseLocation))
        } else {
            userResize = id
        }
        onFollowPointer?(true)
        gestureWatch?.invalidate()
        gestureWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.pointerUp(at: Displays.toGlobal(NSEvent.mouseLocation))
            }
        }
    }

    func pointerMoved(to point: CGPoint) -> Bool {
        guard userMove != nil else { return false }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endUserGesture()
            return true
        }
        userMove?.update(pointer: point)
        if let id = userMove?.id { followMove(id, pointer: point) }
        settleMove?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.userMove != nil else { return }
                self.userMove?.settle()
                self.notify(.frames)
            }
        }
        settleMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        return true
    }

    func pointerUp(at point: CGPoint) {
        if var move = userMove {
            move.update(pointer: point)
            move.settle()
            if world.windows[move.id] != nil { world.noteFrame(move.id, move.frame(monitors: world.monitors)) }
        }
        endUserGesture()
    }

    private func endUserGesture() {
        gestureWatch?.invalidate()
        gestureWatch = nil
        settleMove?.cancel()
        userMove = nil
        userResize = nil
        press = nil
        onFollowPointer?(false)
        notify(.frames)
    }

    func dragBegan(_ id: WindowID, at point: CGPoint) {
        press = nil
        guard let window = world.windows[id] else { return }
        let frame = lastApplied[id] ?? window.frame
        dragging = (id, point, frame.origin)
        dragInFlight = false
        dragPending = nil
        world.noteFocus(id)
        focus(id)
        notify(.all)
    }

    func dragMoved(_ id: WindowID, to point: CGPoint) {
        guard let drag = dragging, drag.id == id else { return }
        sendDrag(CGPoint(x: drag.origin.x + point.x - drag.grab.x, y: drag.origin.y + point.y - drag.grab.y))
        followMove(id, pointer: point)
    }

    private func sendDrag(_ origin: CGPoint) {
        guard let drag = dragging, let window = world.windows[drag.id], let observer = observers[window.pid] else { return }
        if dragInFlight {
            dragPending = origin
            return
        }
        dragInFlight = true
        let frame = CGRect(origin: origin, size: window.frame.size)
        observer.apply([FrameOp(id: drag.id, frame: frame, park: true)]) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.dragInFlight = false
                    if self.dragging?.id == drag.id {
                        self.world.noteFrame(drag.id, frame)
                        self.notify(.frames)
                    }
                    if let next = self.dragPending {
                        self.dragPending = nil
                        self.sendDrag(next)
                    }
                }
            }
        }
    }

    func dragEnded(_ id: WindowID, at point: CGPoint) {
        guard let drag = dragging, drag.id == id else { return }
        if world.windows[id]?.isFloating == true, let window = world.windows[id] {
            let origin = CGPoint(x: drag.origin.x + point.x - drag.grab.x, y: drag.origin.y + point.y - drag.grab.y)
            let frame = CGRect(origin: origin, size: window.frame.size)
            world.noteFrame(id, frame)
            observers[window.pid]?.apply([FrameOp(id: id, frame: frame, park: true)]) { _ in }
        }
        dragging = nil
        dragPending = nil
        dragInFlight = false
        if world.windows[id]?.isFloating == false {
            finishMove(id, at: point)
            lastApplied[id] = nil
        }
        reconcile(label: "drag")
        notify(.all)
    }

    func reconcile(label: String, applied: (@MainActor () -> Void)? = nil) {
        guard isEnabled else { applied?(); return }
        let start = ContinuousClock.now
        passes += 1
        let pass = passes
        let placements = world.placements()
        var shows: [pid_t: [FrameOp]] = [:]
        var parks: [FrameOp] = []
        var leavingFrom: [WindowID: CGRect] = [:]
        for (id, placement) in placements {
            guard let window = world.windows[id] else { continue }
            switch placement {
            case .frame(let rect):
                guard lastApplied[id] != rect || parked.contains(id) else { continue }
                guard adjusting[id] == nil, dragging?.id != id else { continue }
                shows[window.pid, default: []].append(FrameOp(id: id, frame: rect, park: false))
                if let previous = lastApplied[id] { appliedBefore[id] = Array(((appliedBefore[id] ?? []) + [previous]).suffix(4)) }
                lastApplied[id] = rect
                appliedAt[id] = start
                parked.remove(id)
                passOf[id] = pass
            case .hidden:
                guard !parked.contains(id) else { continue }
                let monitor = world.workspaces[window.workspace]?.lastMonitor ?? world.focusedMonitor
                let origin = world.parkingOrigin(for: window.frame.size, on: monitor)
                parks.append(FrameOp(id: id, frame: CGRect(origin: origin, size: window.frame.size), park: true))
                leavingFrom[id] = lastApplied[id] ?? window.frame
                parked.insert(id)
                lastApplied[id] = nil
                appliedAt[id] = start
                passOf[id] = pass
            }
        }
        guard !shows.isEmpty || !parks.isEmpty else { applied?(); return }
        trace("pass \(pass) \(label): \(shows.values.reduce(0) { $0 + $1.count }) to show, \(parks.count) to hide")
        let total = shows.values.reduce(0) { $0 + $1.count } + parks.count
        let appCount = Set(shows.keys).union(parks.compactMap { world.windows[$0.id]?.pid }).count

        var waitingOn: [WindowID: Set<pid_t>] = [:]
        for park in parks {
            let from = leavingFrom[park.id]?.insetBy(dx: 1, dy: 1) ?? .null
            waitingOn[park.id] = Set(shows.filter { $0.value.contains { $0.frame.intersects(from) } }.keys)
        }
        var parksLeft = parks.count
        var sent = Set<WindowID>()
        let sendParks: @MainActor (_ all: Bool) -> Void = { [weak self] all in
            guard let self else { return }
            let ready = parks.filter { !sent.contains($0.id) && (all || waitingOn[$0.id]?.isEmpty != false) }
            guard !ready.isEmpty else { return }
            sent.formUnion(ready.map(\.id))
            trace("pass \(pass) \(label): hiding \(ready.count) after \((ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds])))")
            let current = Dictionary(grouping: ready.filter { self.passOf[$0.id] == pass }) { self.world.windows[$0.id]?.pid ?? 0 }
            let count = ready.count
            self.apply(current) { [weak self] in
                parksLeft -= count
                guard parksLeft == 0 else { return }
                self?.performance.record(label: label, windows: total, apps: appCount, duration: ContinuousClock.now - start)
                self?.scheduleParkingCheck()
                applied?()
            }
        }
        let shown = shows.values.flatMap { $0.map(\.id) }
        sendParks(false)
        apply(shows, each: { pid in
            for id in waitingOn.keys { waitingOn[id]?.remove(pid) }
            sendParks(false)
        }) { [weak self] in
            sendParks(true)
            self?.confirmSilentFrames(shown, pass: pass)
            if parks.isEmpty {
                self?.performance.record(label: label, windows: total, apps: appCount, duration: ContinuousClock.now - start)
                applied?()
            }
        }
        if !shows.isEmpty, !parks.isEmpty {
            onTime(after: .milliseconds(50)) { sendParks(true) }
        }
        notify(.frames)
    }

    private func apply(_ batches: [pid_t: [FrameOp]], each: @escaping @MainActor (pid_t) -> Void = { _ in }, done: @escaping @MainActor () -> Void) {
        guard !batches.isEmpty else { return done() }
        let pending = PendingBatch(count: batches.count)
        for (pid, ops) in batches {
            guard let observer = observers[pid] else {
                each(pid)
                if pending.finish() { done() }
                continue
            }
            let ids = ops.map(\.id)
            observer.apply(ops) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let finished = ContinuousClock.now
                        for id in ids where self?.appliedAt[id] != nil { self?.appliedAt[id] = finished }
                        each(pid)
                        if pending.finish() { done() }
                    }
                }
            }
        }
    }

    // SAFETY: finish() is only called on MainActor.
    private final class PendingBatch: @unchecked Sendable {
        private var remaining: Int
        init(count: Int) { remaining = count }
        @discardableResult
        func finish() -> Bool {
            remaining -= 1
            return remaining == 0
        }
    }

    func focus(_ id: WindowID, raise: Bool = true) {
        guard let window = world.windows[id], let observer = observers[window.pid] else { return }
        focusIntent = (id, .now + .milliseconds(600))
        let keySet = planets_focus_window(window.pid, id)
        observer.finishFocus(id, raise: raise, keyAlreadySet: keySet)
    }

    func noteCycled(to id: WindowID) {
        guard world.windows[id] != nil else { return }
        focusIntent = (id, .now + .milliseconds(600))
        world.noteFocus(id)
        if let window = world.windows[id] { observers[window.pid]?.finishFocus(id, raise: true, keyAlreadySet: true) }
        reconcile(label: "focus")
        notify(.focus)
    }

    func cycleTargets() -> InputTap.Cycle? {
        guard isEnabled, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let fullScreen = world.focusedWorkspaceName.map { name in fullScreenWindows(on: name).filter { $0.window.pid == pid }.map(\.id) } ?? []
        let here = windowsOnFocusedWorkspace(of: pid) + fullScreen
        let elsewhere = world.windows.values.contains { $0.pid == pid && !here.contains($0.id) }
            || fullScreenWindows.contains { $0.value.pid == pid && !here.contains($0.key) }
        guard here.count > 1 || elsewhere else { return nil }
        let current = frontFullScreenWindow() ?? world.focusedWindow
        let index = current.flatMap { here.firstIndex(of: $0) } ?? 0
        return InputTap.Cycle(pid: pid, windows: here, index: index, fullScreen: Set(fullScreen))
    }

    func focusFromMouse(_ id: WindowID) {
        guard world.windows[id] != nil, id != world.focusedWindow else { return }
        world.noteFocus(id)
        focus(id, raise: false)
        notify(.focus)
    }

    private func focusNothing() {
        focusIntent = (nil, .now + .milliseconds(600))
        if !planets_activate_process(ProcessInfo.processInfo.processIdentifier) { NSApp.activate() }
    }

    private func apply(_ result: World.NavigationResult) {
        switch result {
        case .window(let id): focus(id)
        case .emptyMonitor: focusNothing()
        case .none: break
        }
    }

    var focusedFrame: (id: WindowID, frame: CGRect)? {
        guard let id = world.focusedWindow, let window = world.windows[id], !parked.contains(id) else { return nil }
        if let move = userMove, move.id == id { return (id, move.frame(monitors: world.monitors)) }
        if userResize == id { return nil }
        if adjusting[id] != nil || dragging?.id == id || window.isFloating { return (id, window.frame) }
        if let reported = reportedAt[id], let applied = appliedAt[id], reported > applied { return (id, window.frame) }
        return (id, lastApplied[id] ?? window.frame)
    }

    var visibleFrames: [(WindowID, CGRect)] {
        world.windows.values.compactMap { window in
            guard world.isVisible(window.workspace), !parked.contains(window.id) else { return nil }
            return (window.id, lastApplied[window.id] ?? window.frame)
        }
    }

    struct Result {
        var output: String = ""
        var ok = true
    }

    var targetWindow: WindowID? {
        guard frontFullScreenWindow() == nil, let id = world.focusedWindow, let pid = world.windows[id]?.pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return id
    }

    private static let noTarget = Result(output: "no focused window", ok: false)

    @discardableResult
    func perform(_ command: Command) -> Result {
        if !isEnabled {
            switch command {
            case .tiling, .exec, .reload, .menuBar, .query: break
            default: return Result(output: "tiling is off", ok: false)
            }
        }
        let before = world.focusedWorkspaceName
        var result = Result()
        let change: Change
        switch command {
        case .focus(let direction):
            leaveFullScreenForTiles()
            apply(world.focus(direction))
            reconcile(label: "focus")
            change = .all
        case .focusCycle(let forward):
            leaveFullScreenForTiles()
            apply(world.focusCycle(forward: forward))
            reconcile(label: "focus")
            change = .focus
        case .move(let direction):
            guard targetWindow != nil else { return Self.noTarget }
            let moved = world.move(direction)
            reconcile(label: "move")
            if case .window(let id) = moved, world.workspace(of: id) != before { focus(id) }
            change = .all
        case .workspace(let target):
            let leavingFullScreen = Spaces.fullScreenInFront
            if world.switchWorkspace(target) {
                switchArrived(leavingFullScreen: leavingFullScreen)
            }
            change = .all
        case .moveToWorkspace(let target, let follow):
            if let front = frontFullScreenWindow(), let name = world.resolve(target) {
                moveFullScreen(front, toWorkspace: name, follow: follow)
                change = .all
                break
            }
            guard let id = targetWindow else { return Self.noTarget }
            let next = world.moveWindow(id, to: target, follow: follow)
            reconcile(label: "move to workspace")
            if let next { focus(next) } else if world.focusedWorkspace?.isEmpty == true { focusNothing() }
            change = .all
        case .float(let toggle):
            guard let id = targetWindow else { return Self.noTarget }
            world.setFloating(id, toggle)
            if world.windows[id]?.isFloating == true { lastApplied[id] = nil }
            reconcile(label: "float")
            observers[world.windows[id]?.pid ?? 0]?.raise(id)
            change = .all
        case .zoom(let toggle):
            guard targetWindow != nil else { return Self.noTarget }
            world.setZoom(toggle)
            reconcile(label: "zoom")
            if let id = world.focusedWindow { observers[world.windows[id]?.pid ?? 0]?.raise(id) }
            change = .frames
        case .toggleSplit:
            world.toggleSplit()
            reconcile(label: "split")
            change = .frames
        case .resize(let axis, let amount):
            guard let id = targetWindow else { return Self.noTarget }
            world.resize(id, axis, by: amount)
            reconcile(label: "resize")
            change = .frames
        case .balance:
            world.balance()
            reconcile(label: "balance")
            change = .frames
        case .focusMonitor(let target):
            apply(world.focusMonitor(target))
            reconcile(label: "focus")
            change = .all
        case .moveToMonitor(let target):
            guard targetWindow != nil else { return Self.noTarget }
            let moved = world.moveToMonitor(target)
            reconcile(label: "move to monitor")
            apply(moved)
            change = .all
        case .close:
            if let front = frontFullScreenWindow(), let entry = fullScreenWindows[front] {
                observers[entry.pid]?.close(front)
                change = []
                break
            }
            guard let id = targetWindow, let window = world.windows[id] else { return Self.noTarget }
            observers[window.pid]?.close(id)
            change = []
        case .restore(let requested):
            let here = world.focusedWorkspaceName.map(awayWindows(on:))?.first?.id
            let latest = awayWindows.max { $0.value.since < $1.value.since }?.key
            guard let id = requested ?? here ?? latest, awayWindows[id] != nil else {
                return Result(output: requested == nil ? "no minimised or hidden window" : "window \(requested!) isn't minimised or hidden", ok: false)
            }
            restore(id)
            change = []
        case .retile:
            lastApplied.removeAll()
            rescanAll()
            reconcile(label: "retile")
            change = .all
        case .scratchpad(let toggle):
            let target = world.setScratchpad(toggle)
            reconcile(label: "scratchpad")
            if let target { focus(target) } else if world.focusedWorkspace?.isEmpty == true { focusNothing() }
            change = .all
        case .moveToScratchpad:
            guard let id = targetWindow else { return Self.noTarget }
            if world.windows[id]?.isFloating == false { lastApplied[id] = nil }
            let next = world.moveToScratchpad(id)
            reconcile(label: "move to scratchpad")
            if let next { focus(next) } else if world.focusedWorkspace?.isEmpty == true { focusNothing() }
            change = .all
        case .reload, .menuBar, .query, .loginItem:
            change = []
        case .tiling(let toggle):
            let enable = toggle == .toggle ? !isEnabled : toggle == .on
            setEnabled(enable)
            result.output = enable ? "tiling on" : "tiling off"
            change = .all
        case .exec(let line):
            Self.run(line)
            change = []
        }
        if let after = world.focusedWorkspaceName, after != before {
            onWorkspaceSwitch?(after)
        }
        notify(change)
        return result
    }

    func windowsOnFocusedWorkspace(of pid: pid_t) -> [WindowID] {
        (world.focusedWorkspace?.windows ?? []).filter { world.windows[$0]?.pid == pid }
    }

    func activate(_ id: WindowID) {
        if let entry = fullScreenWindows[id] {
            showingFullScreen[entry.workspace] = id
            if world.switchWorkspace(.named(entry.workspace)) { reconcile(label: "activate") }
            bringFullScreenForward(id)
            onWorkspaceSwitch?(entry.workspace)
            notify(.all)
            return
        }
        guard world.windows[id] != nil else { return }
        let outcome = world.noteFocus(id)
        reconcile(label: "activate")
        focus(id)
        if case .revealedWorkspace(let name) = outcome { onWorkspaceSwitch?(name) }
        notify(.all)
    }

    func close(_ id: WindowID) {
        let pid = world.windows[id]?.pid ?? fullScreenWindows[id]?.pid
        if let pid { observers[pid]?.close(id) }
    }

    func moveWindow(_ id: WindowID, toWorkspace name: String) {
        if fullScreenWindows[id] != nil {
            moveFullScreen(id, toWorkspace: name, follow: false)
            return
        }
        let wasFocused = id == world.focusedWindow
        let next = world.moveWindow(id, to: .named(name), follow: false)
        reconcile(label: "move to workspace")
        if wasFocused {
            if let next { focus(next) } else if world.focusedWorkspace?.isEmpty == true { focusNothing() }
        }
        notify(.all)
    }

    func keepFloatingOnTop() {
        guard let workspace = world.focusedWorkspace, !workspace.floating.isEmpty,
              let focused = world.focusedWindow, let focusedWindow = world.windows[focused], !focusedWindow.isFloating else { return }
        let floating = workspace.floating.compactMap { world.windows[$0] }.filter { $0.pid != focusedWindow.pid && !parked.contains($0.id) }
        guard !floating.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for window in floating { self.observers[window.pid]?.raise(window.id) }
            }
        }
    }

    func refocus() {
        guard isEnabled else { return }
        focusAfterSwitch()
    }

    private func noteFullScreen(_ id: WindowID) {
        trace("full screen: \(id)")
        guard let window = world.windows[id] else { return }
        fullScreenWindows[id] = FullScreenWindow(pid: window.pid, workspace: window.workspace, appName: window.appName, title: window.title)
        showingFullScreen[window.workspace] = id
        watchFullScreenWindows()
        notify(.workspaces)
    }

    private func forgetFullScreen(_ id: WindowID) {
        guard fullScreenWindows.removeValue(forKey: id) != nil else { return }
        trace("no longer full screen: \(id)")
        showingFullScreen = showingFullScreen.filter { $0.value != id }
        watchFullScreenWindows()
        notify(.workspaces)
    }

    private func watchFullScreenWindows() {
        if fullScreenWindows.isEmpty {
            fullScreenWatch?.invalidate()
            fullScreenWatch = nil
            return
        }
        guard fullScreenWatch == nil else { return }
        fullScreenWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullScreenWindows() }
        }
    }

    private func checkFullScreenWindows() {
        let now = ContinuousClock.now
        var apps = Set<pid_t>()
        for (id, entry) in fullScreenWindows where now - entry.since > .seconds(2) && !Spaces.isOnFullScreenSpace(id) {
            apps.insert(entry.pid)
        }
        for pid in apps { observers[pid]?.rescan() }
    }

    func fullScreenWindows(on workspace: String) -> [(id: WindowID, window: FullScreenWindow)] {
        fullScreenWindows.filter { $0.value.workspace == workspace }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func frontFullScreenWindow() -> WindowID? {
        guard !fullScreenWindows.isEmpty, let display = Spaces.display(), display.currentIsFullScreen else { return nil }
        return fullScreenWindows.keys.first { Spaces.space(of: $0) == display.current }
    }

    private func noteFullScreenWindowsOnOtherSpaces(of pid: pid_t, appName: String) {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var present = Set<WindowID>()
        let displays = world.monitors.map(\.frame)
        for info in list where (info[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            present.insert(id)
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  displays.contains(where: { $0.isClose(to: bounds, tolerance: 2) }) else { continue }
            guard world.windows[id] == nil, fullScreenWindows[id] == nil, Spaces.isOnFullScreenSpace(id) else { continue }
            let workspace = remembered[id] ?? launchMemory[id]?.workspace ?? world.focusedWorkspaceName ?? world.workspaceOrder[0]
            remembered[id] = workspace
            fullScreenWindows[id] = FullScreenWindow(pid: pid, workspace: workspace, appName: appName, title: info[kCGWindowName as String] as? String ?? "")
            watchFullScreenWindows()
            notify(.workspaces)
        }
        for (id, entry) in fullScreenWindows where entry.pid == pid
            && (!present.contains(id) || (ContinuousClock.now - entry.since > .seconds(3) && !Spaces.isOnFullScreenSpace(id))) {
            forgetFullScreen(id)
        }
    }

    private func switchArrived(leavingFullScreen: Bool) {
        let name = world.focusedWorkspaceName
        trace("switch to \(name ?? "-") leaving full screen \(leavingFullScreen), showing \(name.flatMap { showingFullScreen[$0] }.map(String.init) ?? "-"), full screen \(fullScreenWindows.keys.sorted())")
        if let name, let arriving = showingFullScreen[name], fullScreenWindows[arriving] != nil {
            var brought = false
            let switchedAt = ContinuousClock.now
            let bring: @MainActor () -> Void = { [weak self] in
                guard !brought, let self, self.world.focusedWorkspaceName == name else { return }
                brought = true
                trace("bring after \((ContinuousClock.now - switchedAt).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
                self.bringFullScreenForward(arriving)
            }
            if leavingFullScreen {
                reconcile(label: "workspace")
                bring()
            } else {
                raiseArriving()
                reconcile(label: "workspace", applied: bring)
                onTime(after: .milliseconds(40), bring)
            }
            return
        }
        raiseArriving()
        if leavingFullScreen {
            let name = world.focusedWorkspaceName
            leaveFullScreenSpace { [weak self] in
                guard let self, self.world.focusedWorkspaceName == name else { return }
                self.focusAfterSwitch()
            }
            reconcile(label: "workspace")
            return
        }
        focusAfterSwitch()
        reconcile(label: "workspace")
    }

    private func leaveFullScreenForTiles() {
        guard let front = frontFullScreenWindow(), let entry = fullScreenWindows[front] else { return }
        showingFullScreen[entry.workspace] = nil
        leaveFullScreenSpace { [weak self] in
            if let id = self?.world.focusedWindow { self?.focus(id) }
        }
    }

    func moveFullScreen(_ id: WindowID, toWorkspace name: String, follow: Bool) {
        guard var entry = fullScreenWindows[id], entry.workspace != name else { return }
        let inFront = frontFullScreenWindow() == id
        if showingFullScreen[entry.workspace] == id { showingFullScreen[entry.workspace] = nil }
        entry.workspace = name
        fullScreenWindows[id] = entry
        remembered[id] = name
        rememberedSlot[id] = nil
        showingFullScreen[name] = id
        if follow, inFront {
            if world.switchWorkspace(.named(name)) { reconcile(label: "move to workspace") }
        } else if inFront {
            leaveFullScreenSpace { [weak self] in self?.focusAfterSwitch() }
            reconcile(label: "move to workspace")
        }
        notify(.all)
    }

    private func bringFullScreenForward(_ id: WindowID) {
        guard let entry = fullScreenWindows[id] else { return }
        lastUsed[entry.pid] = id
        let space = Spaces.space(of: id)
        focusIntent = (nil, .now + .seconds(5))
        ownSpaceChangeUntil = .now + .seconds(5)
        let steps = space.flatMap { space in
            Spaces.show(space) { [weak self] in
                guard let self else { return }
                self.ownSpaceChangeUntil = .now + .milliseconds(800)
                self.focusIntent = (nil, .now + .milliseconds(600))
                self.observers[entry.pid]?.finishFocus(id, raise: false, keyAlreadySet: false)
            }
        }
        trace("bring \(id) forward: space \(space.map(String.init) ?? "-"), \(steps.map { "\($0) step(s)" } ?? "on another display")")
        if steps != nil { return }
        ownSpaceChangeUntil = .now + .milliseconds(1500)
        focusIntent = (nil, .now + .milliseconds(1500))
        Self.makeFrontmost(entry.pid)
        _ = planets_front_window(entry.pid, id)
        observers[entry.pid]?.finishFocus(id, raise: false, keyAlreadySet: false)
    }

    private func leaveFullScreenSpace(arrived: @escaping @MainActor () -> Void = {}) {
        let workspace = world.focusedWorkspace
        focusIntent = (workspace?.focused, .now + .seconds(5))
        ownSpaceChangeUntil = .now + .seconds(5)
        let anchor = workspace?.focused ?? workspace?.tiled.first ?? workspace?.floating.first ?? world.windows.keys.first
        let desktop = anchor.flatMap(Spaces.space(of:)) ?? Spaces.display().flatMap { display in
            display.ids.indices.first { !display.fullScreen[$0] }.map { display.ids[$0] }
        }
        let steps = desktop.flatMap { desktop in
            Spaces.show(desktop) { [weak self] in
                guard let self else { return }
                self.ownSpaceChangeUntil = .now + .milliseconds(800)
                self.focusIntent = (workspace?.focused, .now + .milliseconds(600))
                arrived()
            }
        }
        trace("to the desktop: \(steps.map { "\($0) step(s)" } ?? "on another display")")
        if steps != nil { return }
        let fullScreenApps = Set(fullScreenWindows.values.map(\.pid))
        let preferred = (workspace?.focused ?? workspace?.tiled.first ?? workspace?.floating.first).flatMap { world.windows[$0]?.pid }
        guard let pid = preferred.flatMap({ fullScreenApps.contains($0) ? nil : $0 }) ?? world.windows.values.first(where: { !fullScreenApps.contains($0.pid) })?.pid else {
            ownSpaceChangeUntil = nil
            focusIntent = nil
            arrived()
            return
        }
        ownSpaceChangeUntil = .now + .milliseconds(1500)
        focusIntent = (workspace?.focused, .now + .milliseconds(1500))
        Self.makeFrontmost(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { arrived() }
    }

    func cycleAcrossSpaces(to id: WindowID) {
        if let entry = fullScreenWindows[id] {
            showingFullScreen[entry.workspace] = id
            bringFullScreenForward(id)
        } else if world.windows[id] != nil {
            if let name = world.focusedWorkspaceName { showingFullScreen[name] = nil }
            world.noteFocus(id)
            leaveFullScreenSpace { [weak self] in self?.focus(id) }
            reconcile(label: "focus")
        }
        notify(.focus)
    }

    private static func makeFrontmost(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func followSpace() {
        if Spaces.isMoving { return }
        if let until = ownSpaceChangeUntil, ContinuousClock.now < until { return }
        trace("follow space: front full screen \(frontFullScreenWindow().map(String.init) ?? "-"), full screen in front \(Spaces.fullScreenInFront)")
        if let front = frontFullScreenWindow(), let entry = fullScreenWindows[front] {
            showingFullScreen[entry.workspace] = front
            lastUsed[entry.pid] = front
            if entry.workspace != world.focusedWorkspaceName, world.switchWorkspace(.named(entry.workspace)) {
                reconcile(label: "follow space")
                notify(.all)
            }
        } else if !Spaces.fullScreenInFront, let name = world.focusedWorkspaceName {
            showingFullScreen[name] = nil
        }
        notify(.focus)
    }

    private func raiseArriving() {
        guard let workspace = world.focusedWorkspace, workspace.zoomed == nil else { return }
        let focusedPID = (workspace.focused ?? workspace.tiled.first).flatMap { world.windows[$0]?.pid }
        for id in workspace.tiled where id != workspace.focused {
            guard let window = world.windows[id], window.pid != focusedPID else { continue }
            observers[window.pid]?.raise(id)
        }
    }

    private func focusAfterSwitch() {
        guard let workspace = world.focusedWorkspace else { return }
        if let restoring, ContinuousClock.now < restoring.until, awayWindows[restoring.id]?.workspace == workspace.name { return }
        if let id = workspace.focused ?? workspace.tiled.first ?? workspace.floating.first {
            focus(id)
            keepFloatingOnTop()
        } else {
            focusNothing()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            isEnabled = true
            lastApplied.removeAll()
            for app in NSWorkspace.shared.runningApplications { observe(app) }
            reconcile(label: "tiling on")
        } else {
            restoreAllWindows()
            isEnabled = false
            for pid in Array(observers.keys) { forget(pid: pid, refocus: false) }
            lastApplied.removeAll()
        }
    }

    static func run(_ line: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", line]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        do { try process.run() } catch { log.error("exec failed: \(error.localizedDescription, privacy: .public)") }
    }

    func notify(_ change: Change) {
        guard !change.isEmpty else { return }
        if change.contains(.focus) { noteWindowUsed() }
        if !change.isDisjoint(with: [.workspaces, .frames]) { schedulePersist() }
        pendingChange.formUnion(change)
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let change = self.pendingChange
                self.pendingChange = []
                self.notifyScheduled = false
                self.onChange?(change)
            }
        }
    }

    private struct SavedState: Codable {
        var boot: Int
        var focused: String?
        var windows: [String: SavedWindow]
        var showingFullScreen: [String: WindowID]?
        var arrangements: [String: Workspace.Arrangement]?
    }

    private struct SavedWindow: Codable {
        var workspace: String
        var floating: Bool
        var away: Bool?
        var slot: TileSlot?
    }

    private static var stateURL: URL { IPC.supportDirectory.appendingPathComponent("state.json") }

    private static var bootTime: Int {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &time, &size, nil, 0)
        return time.tv_sec
    }

    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.persistScheduled = false
                self?.persist()
            }
        }
    }

    var savesState = true

    func persist() {
        guard savesState else { return }
        var windows: [String: SavedWindow] = [:]
        for (id, workspace) in remembered {
            windows[String(id)] = SavedWindow(workspace: workspace, floating: rememberedFloating.contains(id), away: true, slot: rememberedSlot[id])
        }
        if launchMemoryActive {
            for (id, saved) in launchMemory { windows[String(id)] = saved }
        }
        for window in world.windows.values {
            windows[String(window.id)] = SavedWindow(workspace: window.workspace, floating: floatsByChoice(window.id))
        }
        for (id, entry) in fullScreenWindows where windows[String(id)] == nil {
            windows[String(id)] = SavedWindow(workspace: entry.workspace, floating: false, away: true)
        }
        var arrangements = world.workspaces.filter { $0.value.tree != nil }.mapValues(\.arrangement)
        if launchMemoryActive {
            let waiting = Set(launchMemory.values.map(\.workspace))
            for (name, saved) in launchArrangements where waiting.contains(name) { arrangements[name] = saved }
        }
        let state = SavedState(boot: Self.bootTime, focused: world.focusedWorkspaceName, windows: windows, showingFullScreen: showingFullScreen, arrangements: arrangements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(state), data != persisted else { return }
        try? FileManager.default.createDirectory(at: IPC.supportDirectory, withIntermediateDirectories: true)
        if (try? data.write(to: Self.stateURL, options: .atomic)) != nil { persisted = data }
    }

    private func restoreSavedState() {
        if Self.screenLocked || Spaces.fullScreenInFront { startupWaitsForUnlock = true } else { launchMemoryUntil = .now + .seconds(15) }
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data),
              state.boot == Self.bootTime else { return }
        for (key, saved) in state.windows {
            guard let id = WindowID(key) else { continue }
            if saved.away == true {
                remembered[id] = saved.workspace
                rememberedSlot[id] = saved.slot
                if saved.floating { rememberedFloating.insert(id) }
            } else {
                launchMemory[id] = saved
            }
        }
        showingFullScreen = state.showingFullScreen ?? [:]
        launchArrangements = state.arrangements ?? [:]
        if let focused = state.focused { world.switchWorkspace(.named(focused)) }
    }

    static func onScreenWindowIDs() -> Set<WindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    func appName(for pid: pid_t) -> String? { observers[pid]?.appName }
    var observedAppCount: Int { observers.count }
    func isParked(_ id: WindowID) -> Bool { parked.contains(id) }
}

@MainActor
final class PerformanceLog {
    struct Entry {
        var label: String
        var windows: Int
        var apps: Int
        var duration: Duration
        var at: Date
    }

    private(set) var entries: [Entry] = []

    func record(label: String, windows: Int, apps: Int, duration: Duration) {
        entries.append(Entry(label: label, windows: windows, apps: apps, duration: duration, at: Date()))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    func percentile(_ p: Double, label: String? = nil) -> Double? {
        let values = entries.filter { label == nil || $0.label == label }.map { Self.milliseconds($0.duration) }.sorted()
        guard !values.isEmpty else { return nil }
        let index = min(values.count - 1, Int((Double(values.count - 1) * p).rounded()))
        return values[index]
    }
}
