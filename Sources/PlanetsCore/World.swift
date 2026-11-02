import CoreGraphics
import Foundation

public struct Monitor: Equatable, Sendable {
    public let id: MonitorID
    public var name: String
    /// The whole display, in the global top-left coordinate space.
    public var frame: CGRect
    /// The display minus the menu bar and the Dock.
    public var visibleFrame: CGRect
    public var isMain: Bool

    public init(id: MonitorID, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}

/// A window as discovered by the app layer, before Planets decides where it belongs.
public struct WindowCandidate: Equatable, Sendable {
    public var id: WindowID
    public var pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var frame: CGRect
    /// Dialogs, panels and fixed-size windows float instead of tiling.
    public var prefersFloating: Bool

    public init(id: WindowID, pid: Int32, bundleID: String?, appName: String, title: String, frame: CGRect, prefersFloating: Bool) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.prefersFloating = prefersFloating
    }
}

public struct ManagedWindow: Equatable, Sendable {
    public let id: WindowID
    public let pid: Int32
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var workspace: String
    public var isFloating: Bool
    /// The frame the app last reported.
    public var frame: CGRect
    /// Where a floating window returns when its workspace is shown.
    public var floatingFrame: CGRect?
}

/// The whole window-manager state, as plain values. Every command and every event from
/// macOS becomes a mutation here; the app layer then asks for `placements()` and moves
/// only the windows whose spot changed. Keeping this free of side effects is what lets
/// the tests drive the window manager without a screen.
public struct World: Sendable {
    public internal(set) var monitors: [Monitor] = []
    public internal(set) var workspaces: [String: Workspace] = [:]
    /// Configured workspaces. They exist even when empty and keep this order.
    public internal(set) var persistentNames: [String]
    public internal(set) var visible: [MonitorID: String] = [:]
    public internal(set) var windows: [WindowID: ManagedWindow] = [:]
    public internal(set) var focusedMonitor: MonitorID?
    public internal(set) var previousWorkspace: String?
    /// The monitor the scratchpad is showing on, or nil while it's tucked away.
    public internal(set) var scratchpadMonitor: MonitorID?
    /// The largest size each window will take, for apps that cap their window size. A
    /// capped window sits centred in its tile instead of in the tile's top-left corner.
    public internal(set) var maxSizes: [WindowID: CGSize] = [:]
    /// The smallest size each window accepts, learned when it refused a smaller tile.
    /// Layouts make room for these.
    public internal(set) var minSizes: [WindowID: CGSize] = [:]
    /// Windows floated only because their workspace had no room for them. They tile again
    /// as soon as there is room; a window the user floated is left alone.
    public internal(set) var autoFloated: Set<WindowID> = []
    /// When each window joined the tiles of its workspace, to tell newcomers from residents.
    var joined: [WindowID: Int] = [:]
    var joinCount = 0
    private var holdRetiling = false
    public var settings: LayoutSettings
    /// Workspaces pinned to a display. Values name the display: "main", "secondary", its
    /// position from the left ("1", "2"), or part of its name. A pin to a display that isn't
    /// connected is ignored.
    public var pinnedMonitors: [String: String] = [:]

    /// The scratchpad is a hidden workspace of floating windows that you summon over
    /// whatever you're doing and dismiss again, like Hyprland's special workspace.
    public static let scratchpad = "scratchpad"

    public init(workspaceNames: [String], settings: LayoutSettings = LayoutSettings()) {
        self.persistentNames = workspaceNames.isEmpty ? ["1"] : workspaceNames
        self.settings = settings
        for name in persistentNames { workspaces[name] = Workspace(name: name) }
    }

    // MARK: Queries

    public var focusedWorkspaceName: String? { focusedMonitor.flatMap { visible[$0] } }
    public var focusedWorkspace: Workspace? { focusedWorkspaceName.flatMap { workspaces[$0] } }
    public var focusedWindow: WindowID? {
        // A shown scratchpad always has focus: focusing anything else tucks it away.
        if scratchpadMonitor != nil, let id = workspaces[Self.scratchpad]?.focused { return id }
        return focusedWorkspace?.focused
    }

    /// Persistent workspaces first, in configured order, then any others by name. The
    /// scratchpad isn't a place you go, so it's left out.
    public var workspaceOrder: [String] {
        let extra = workspaces.keys.filter { !persistentNames.contains($0) && $0 != Self.scratchpad }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return persistentNames + extra
    }

    public func monitor(_ id: MonitorID?) -> Monitor? { monitors.first { $0.id == id } }

    public func pinnedMonitor(for workspace: String) -> MonitorID? {
        guard let pattern = pinnedMonitors[workspace]?.lowercased(), !pattern.isEmpty else { return nil }
        switch pattern {
        case "main", "primary": return monitors.first(where: \.isMain)?.id
        case "secondary": return monitors.first { !$0.isMain }?.id
        default:
            if let index = Int(pattern), monitors.indices.contains(index - 1) { return monitors[index - 1].id }
            return monitors.first { $0.name.lowercased().contains(pattern) }?.id
        }
    }
    public func monitorShowing(_ workspace: String) -> MonitorID? {
        if workspace == Self.scratchpad { return scratchpadMonitor }
        return visible.first { $0.value == workspace }?.key
    }
    public func isVisible(_ workspace: String) -> Bool {
        workspace == Self.scratchpad ? scratchpadMonitor != nil : visible.values.contains(workspace)
    }
    public func workspace(of window: WindowID) -> String? { windows[window]?.workspace }

    // MARK: Monitors

    public mutating func setMonitors(_ newMonitors: [Monitor]) {
        monitors = newMonitors.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let ids = Set(monitors.map(\.id))
        for id in visible.keys where !ids.contains(id) { visible[id] = nil }
        for monitor in monitors where visible[monitor.id] == nil {
            let shown = Set(visible.values)
            let free = workspaceOrder.filter { !shown.contains($0) }
            // Pinned here first, then whatever was here last time, then the first workspace
            // that isn't pinned to some other connected display.
            let pinned = free.first { pinnedMonitor(for: $0) == monitor.id }
            let remembered = free.first { workspaces[$0]?.lastMonitor == monitor.id && (pinnedMonitor(for: $0) ?? monitor.id) == monitor.id }
            let unpinned = free.first { pinnedMonitor(for: $0) == nil }
            let name = pinned ?? remembered ?? unpinned ?? free.first ?? nextFreeName()
            show(name, on: monitor.id)
        }
        if focusedMonitor == nil || !ids.contains(focusedMonitor!) {
            focusedMonitor = (monitors.first { $0.isMain } ?? monitors.first)?.id
        }
    }

    private func nextFreeName() -> String {
        var index = persistentNames.count + 1
        while workspaces["\(index)"] != nil { index += 1 }
        return "\(index)"
    }

    // MARK: Windows

    /// Adds a newly discovered window. Lands on `workspace` when a rule names one,
    /// otherwise on the focused workspace, the one the user is looking at.
    /// Where a tiled window sits right now, for `addWindow(_:workspace:floating:slot:)`.
    public func slot(of id: WindowID) -> TileSlot? {
        guard let window = windows[id], !window.isFloating, var slot = workspaces[window.workspace]?.slot(of: id, workspace: window.workspace) else { return nil }
        slot.joined = joined[id]
        return slot
    }

    @discardableResult
    public mutating func addWindow(_ candidate: WindowCandidate, workspace requested: String? = nil, floating: Bool? = nil, slot: TileSlot? = nil) -> String {
        if let existing = windows[candidate.id] { return existing.workspace }
        let name = requested ?? focusedWorkspaceName ?? workspaceOrder[0]
        ensureWorkspace(name)
        // The scratchpad only places floating windows; a tiled one there would never show.
        let isFloating = name == Self.scratchpad || (floating ?? candidate.prefersFloating)
        windows[candidate.id] = ManagedWindow(
            id: candidate.id, pid: candidate.pid, bundleID: candidate.bundleID, appName: candidate.appName,
            title: candidate.title, workspace: name, isFloating: isFloating, frame: candidate.frame,
            floatingFrame: isFloating ? candidate.frame : nil
        )
        if isFloating {
            workspaces[name]!.addFloating(candidate.id)
        } else if let slot, slot.workspace == name {
            workspaces[name]!.addTiled(candidate.id, into: slot)
            if let order = slot.joined { joined[candidate.id] = order } else { noteJoined(candidate.id) }
        } else {
            workspaces[name]!.addTiled(candidate.id, after: workspaces[name]!.focused)
            noteJoined(candidate.id)
        }
        return name
    }

    mutating func noteJoined(_ id: WindowID) {
        joinCount += 1
        joined[id] = joinCount
    }

    /// Forgets a window. Returns the window that should take focus when the closed one
    /// had it, so the app layer can hand focus over before macOS picks a window on some
    /// hidden workspace and drags the user there.
    @discardableResult
    public mutating func removeWindow(_ id: WindowID) -> WindowID? {
        maxSizes[id] = nil
        minSizes[id] = nil
        autoFloated.remove(id)
        joined[id] = nil
        guard let window = windows.removeValue(forKey: id), var workspace = workspaces[window.workspace] else { return nil }
        let hadFocus = workspace.focused == id
        workspace.remove(id)
        workspaces[window.workspace] = workspace
        if !window.isFloating { retileWhereRoom(on: window.workspace) }
        let successor = hadFocus && window.workspace == focusedWorkspaceName ? (workspace.focused ?? workspace.tiled.first ?? workspace.floating.first) : nil
        pruneWorkspace(window.workspace)
        return successor
    }

    /// A native tab took over from its sibling: macOS shows each tab as its own window, but
    /// a tab group is one thing on screen, so the new tab inherits the old one's tile.
    /// The old tab is forgotten until it's selected again, when the same swap runs back.
    public mutating func replaceWindow(_ old: WindowID, with candidate: WindowCandidate) {
        guard let window = windows[old], windows[candidate.id] == nil else { return }
        workspaces[window.workspace]?.replace(old, with: candidate.id)
        windows[old] = nil
        maxSizes[candidate.id] = maxSizes.removeValue(forKey: old)
        minSizes[candidate.id] = minSizes.removeValue(forKey: old)
        joined[candidate.id] = joined.removeValue(forKey: old)
        if autoFloated.remove(old) != nil { autoFloated.insert(candidate.id) }
        windows[candidate.id] = ManagedWindow(
            id: candidate.id, pid: candidate.pid, bundleID: candidate.bundleID, appName: candidate.appName,
            title: candidate.title, workspace: window.workspace, isFloating: window.isFloating,
            frame: candidate.frame, floatingFrame: window.floatingFrame
        )
    }

    public mutating func updateWindow(_ id: WindowID, title: String) {
        windows[id]?.title = title
    }

    /// Records a frame the app reported. Floating windows remember it as their home.
    public mutating func noteFrame(_ id: WindowID, _ frame: CGRect) {
        guard windows[id] != nil else { return }
        windows[id]!.frame = frame
        if windows[id]!.isFloating, let workspace = windows[id].map({ $0.workspace }), isVisible(workspace) {
            windows[id]!.floatingFrame = frame
        }
    }

    public enum FocusOutcome: Equatable, Sendable {
        case unmanaged
        case unchanged
        /// The window lived on a hidden workspace, so that workspace is now shown.
        case revealedWorkspace(String)
        /// The window lives in the scratchpad, which is now shown.
        case revealedScratchpad
        /// Focus left the scratchpad, which tucked itself away.
        case hidScratchpad
    }

    /// macOS reports that a window took focus: from a click, Cmd-Tab, the Dock, or an app
    /// opening a window. Focus wins, so a window on a hidden workspace pulls it into view.
    @discardableResult
    public mutating func noteFocus(_ id: WindowID) -> FocusOutcome {
        guard let window = windows[id] else { return .unmanaged }
        let name = window.workspace
        if name == Self.scratchpad {
            let wasHidden = scratchpadMonitor == nil
            if wasHidden { scratchpadMonitor = focusedMonitor }
            workspaces[name]?.noteFocus(id)
            return wasHidden ? .revealedScratchpad : .unchanged
        }
        var outcome = FocusOutcome.unchanged
        if scratchpadMonitor != nil {
            scratchpadMonitor = nil
            outcome = .hidScratchpad
        }
        if let monitor = monitorShowing(name) {
            focusedMonitor = monitor
        } else {
            let target = pinnedMonitor(for: name) ?? workspaces[name]?.lastMonitor.flatMap { id in monitors.contains { $0.id == id } ? id : nil } ?? focusedMonitor
            if let target {
                focusedMonitor = target
                switchTo(name)
                outcome = .revealedWorkspace(name)
            }
        }
        workspaces[name]?.noteFocus(id)
        return outcome
    }

    // MARK: Workspaces

    mutating func ensureWorkspace(_ name: String) {
        if workspaces[name] == nil {
            workspaces[name] = Workspace(name: name)
        }
    }

    private mutating func show(_ name: String, on monitor: MonitorID) {
        ensureWorkspace(name)
        let replaced = visible[monitor]
        visible[monitor] = name
        workspaces[name]!.lastMonitor = monitor
        if let replaced, replaced != name { pruneWorkspace(replaced) }
    }

    /// Ad-hoc workspaces disappear once empty and out of view, like Hyprland's.
    private mutating func pruneWorkspace(_ name: String) {
        guard !persistentNames.contains(name), name != Self.scratchpad, let workspace = workspaces[name], workspace.isEmpty, !isVisible(name) else { return }
        workspaces[name] = nil
        if previousWorkspace == name { previousWorkspace = nil }
    }

    public func resolve(_ target: Command.WorkspaceTarget) -> String? {
        switch target {
        case .named(let name):
            return name
        case .back:
            return previousWorkspace
        case .next, .previous:
            // Cycle through persistent workspaces and any others that hold windows.
            let order = workspaceOrder.filter { persistentNames.contains($0) || !(workspaces[$0]?.isEmpty ?? true) }
            guard let current = focusedWorkspaceName, let index = order.firstIndex(of: current), !order.isEmpty else { return order.first }
            let step = target == .next ? 1 : -1
            return order[(index + step + order.count) % order.count]
        }
    }

    /// Shows a workspace. When another monitor already shows it, focus moves to that
    /// monitor instead of stealing the workspace, which is what i3 and AeroSpace do.
    @discardableResult
    public mutating func switchWorkspace(_ target: Command.WorkspaceTarget) -> Bool {
        guard let name = resolve(target), name != focusedWorkspaceName else { return false }
        switchTo(name)
        return true
    }

    private mutating func switchTo(_ name: String) {
        let current = focusedWorkspaceName
        if let monitor = monitorShowing(name) {
            focusedMonitor = monitor
        } else if let monitor = pinnedMonitor(for: name) ?? focusedMonitor {
            focusedMonitor = monitor
            show(name, on: monitor)
        } else {
            return
        }
        if let current, current != name {
            previousWorkspace = current
            pruneWorkspace(current)
        }
    }

    /// Moves a window to another workspace. Returns the window that should hold focus next.
    @discardableResult
    public mutating func moveWindow(_ id: WindowID, to target: Command.WorkspaceTarget, follow: Bool) -> WindowID? {
        guard let window = windows[id], let name = resolve(target), name != window.workspace else { return nil }
        ensureWorkspace(name)
        let source = window.workspace
        workspaces[source]!.remove(id)
        if window.isFloating {
            workspaces[name]!.addFloating(id)
            if let monitor = monitorShowing(name).flatMap(monitor(_:)), let frame = window.floatingFrame {
                windows[id]!.floatingFrame = Self.translate(frame, into: monitor)
            }
        } else {
            workspaces[name]!.addTiled(id, after: workspaces[name]!.focused)
            noteJoined(id)
        }
        windows[id]!.workspace = name
        if !window.isFloating { retileWhereRoom(on: source) }
        if follow {
            switchTo(name)
            workspaces[name]!.noteFocus(id)
            return id
        }
        workspaces[name]!.noteFocus(id)
        let next = workspaces[source]?.focused ?? workspaces[source]?.tiled.first
        pruneWorkspace(source)
        return next
    }

    // MARK: Scratchpad

    /// Shows or tucks away the scratchpad on the focused monitor. Returns the window that
    /// should take focus: the scratchpad's when it opens, the workspace's when it closes.
    public mutating func setScratchpad(_ toggle: Command.Toggle) -> WindowID? {
        let show = toggle == .toggle ? scratchpadMonitor == nil : toggle == .on
        if show {
            guard let monitor = focusedMonitor, let pad = workspaces[Self.scratchpad], !pad.isEmpty else { return nil }
            scratchpadMonitor = monitor
            return pad.focused ?? pad.floating.first
        }
        guard scratchpadMonitor != nil else { return nil }
        scratchpadMonitor = nil
        return focusedWorkspace.flatMap { $0.focused ?? $0.tiled.first ?? $0.floating.first }
    }

    /// Sends a window to the scratchpad, floating, and returns who should take focus next.
    public mutating func moveToScratchpad(_ id: WindowID) -> WindowID? {
        guard let window = windows[id], window.workspace != Self.scratchpad else { return nil }
        if !window.isFloating { setFloating(id, .on) }
        let source = window.workspace
        moveWindow(id, to: .named(Self.scratchpad), follow: false)
        if scratchpadMonitor != nil { return id }
        return workspaces[source].flatMap { $0.focused ?? $0.tiled.first ?? $0.floating.first }
    }

    // MARK: Focus and movement

    /// Frames of every window on screen right now, for geometric navigation.
    func visibleTiledFrames() -> [(WindowID, CGRect)] {
        var result: [(WindowID, CGRect)] = []
        for (monitorID, name) in visible {
            guard let monitor = monitor(monitorID), let workspace = workspaces[name] else { continue }
            let placed = workspace.placements(in: monitor.visibleFrame, settings: settings, minimums: minSizes)
            for id in workspace.tiled {
                if case .frame(let rect)? = placed[id] { result.append((id, rect)) }
            }
        }
        return result
    }

    public enum NavigationResult: Equatable, Sendable {
        case window(WindowID)
        /// Focus moved to a monitor whose workspace is empty.
        case emptyMonitor(MonitorID)
        case none
    }

    public mutating func focus(_ direction: Direction) -> NavigationResult {
        guard let name = focusedWorkspaceName, let workspace = workspaces[name] else { return .none }
        if let current = workspace.focused, workspace.tiled.contains(current) {
            do {
                let frames = visibleTiledFrames()
                if let origin = frames.first(where: { $0.0 == current })?.1 {
                    let local = frames.filter { workspace.tiled.contains($0.0) && $0.0 != current }
                    if let id = neighbor(of: origin, in: direction, among: local) {
                        workspaces[name]!.noteFocus(id)
                        return .window(id)
                    }
                }
            }
        }
        return focusMonitor(.direction(direction))
    }

    public mutating func focusCycle(forward: Bool) -> NavigationResult {
        guard let name = focusedWorkspaceName, let workspace = workspaces[name], !workspace.windows.isEmpty else { return .none }
        let all = workspace.windows
        let index = workspace.focused.flatMap { all.firstIndex(of: $0) } ?? (forward ? -1 : 0)
        let id = all[(index + (forward ? 1 : -1) + all.count) % all.count]
        workspaces[name]!.noteFocus(id)
        return .window(id)
    }

    public func monitor(_ target: Command.MonitorTarget, from origin: MonitorID?) -> Monitor? {
        guard let origin = monitor(origin) ?? monitors.first, monitors.count > 1 else { return nil }
        switch target {
        case .next, .previous:
            let index = monitors.firstIndex { $0.id == origin.id }!
            let step = target == .next ? 1 : -1
            return monitors[(index + step + monitors.count) % monitors.count]
        case .direction(let direction):
            let others = monitors.filter { $0.id != origin.id }.map { ($0.id, $0.frame) }
            return neighbor(of: origin.frame, in: direction, among: others).flatMap(monitor(_:))
        }
    }

    public mutating func focusMonitor(_ target: Command.MonitorTarget) -> NavigationResult {
        guard let destination = monitor(target, from: focusedMonitor), let name = visible[destination.id] else { return .none }
        let current = focusedWorkspaceName
        focusedMonitor = destination.id
        if let current, current != name { previousWorkspace = current }
        if let workspace = workspaces[name], let id = workspace.focused ?? workspace.tiled.first ?? workspace.floating.first {
            workspaces[name]!.noteFocus(id)
            return .window(id)
        }
        return .emptyMonitor(destination.id)
    }

    /// Swaps the focused window with its neighbour, or carries it to the next monitor
    /// when it already sits at the edge. Floating windows nudge instead.
    public mutating func move(_ direction: Direction) -> NavigationResult {
        guard let name = focusedWorkspaceName, let workspace = workspaces[name], let current = workspace.focused else { return .none }
        if workspace.floating.contains(current) {
            guard var frame = windows[current]?.floatingFrame ?? windows[current]?.frame else { return .none }
            let step: CGFloat = 60
            switch direction {
            case .left: frame.origin.x -= step
            case .right: frame.origin.x += step
            case .up: frame.origin.y -= step
            case .down: frame.origin.y += step
            }
            windows[current]!.floatingFrame = frame
            return .window(current)
        }
        let frames = visibleTiledFrames()
        if let origin = frames.first(where: { $0.0 == current })?.1 {
            let local = frames.filter { workspace.tiled.contains($0.0) && $0.0 != current }
            if let other = neighbor(of: origin, in: direction, among: local) {
                workspaces[name]!.swap(current, other)
                return .window(current)
            }
        }
        guard let destination = monitor(.direction(direction), from: focusedMonitor), let target = visible[destination.id] else { return .none }
        moveWindow(current, to: .named(target), follow: true)
        return .window(current)
    }

    public mutating func moveToMonitor(_ target: Command.MonitorTarget) -> NavigationResult {
        guard let current = focusedWindow, let destination = monitor(target, from: focusedMonitor), let name = visible[destination.id] else { return .none }
        moveWindow(current, to: .named(name), follow: true)
        return .window(current)
    }

    // MARK: Layout changes

    /// Centres a floating window on the monitor showing its workspace, keeping its size but
    /// never letting it exceed the usable area.
    public mutating func centerFloating(_ id: WindowID) {
        guard let window = windows[id], window.isFloating,
              let monitor = monitor(monitorShowing(window.workspace) ?? focusedMonitor) else { return }
        let area = monitor.visibleFrame
        let size = window.floatingFrame?.size ?? window.frame.size
        let width = min(size.width, area.width - 40), height = min(size.height, area.height - 40)
        windows[id]!.floatingFrame = CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }

    public mutating func setFloating(_ id: WindowID, _ toggle: Command.Toggle, frame: CGRect? = nil) {
        if let frame, windows[id] != nil { windows[id]!.floatingFrame = frame }
        guard let window = windows[id], var workspace = workspaces[window.workspace] else { return }
        let shouldFloat = toggle == .toggle ? !window.isFloating : toggle == .on
        guard shouldFloat != window.isFloating else { return }
        // The scratchpad only places floating windows; a tiled one there would never show.
        guard shouldFloat || window.workspace != Self.scratchpad else { return }
        // Floating or tiling by hand is the user's call, and outranks any automatic float.
        autoFloated.remove(id)
        workspace.remove(id)
        if shouldFloat {
            workspace.addFloating(id)
            if windows[id]!.floatingFrame == nil, let monitor = monitorShowing(window.workspace).flatMap(monitor(_:)) {
                // A window leaving the grid gets a comfortable centred size, as in Hyprland.
                let area = monitor.visibleFrame
                let size = CGSize(width: (area.width * 0.6).rounded(), height: (area.height * 0.7).rounded())
                windows[id]!.floatingFrame = CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
            }
        } else {
            workspace.addTiled(id, after: workspace.focused)
            noteJoined(id)
        }
        workspace.noteFocus(id)
        windows[id]!.isFloating = shouldFloat
        workspaces[window.workspace] = workspace
        if shouldFloat { retileWhereRoom(on: window.workspace) }
    }

    // MARK: Minimum sizes

    /// Records that a window refused a smaller size. Each side keeps the largest it has seen.
    public mutating func noteMinimumSize(_ id: WindowID, _ size: CGSize) {
        guard windows[id] != nil else { return }
        let known = minSizes[id] ?? .zero
        minSizes[id] = CGSize(width: max(known.width, size.width), height: max(known.height, size.height))
    }

    /// Tiled windows on a workspace whose tile is still smaller than they accept.
    public func cramped(on name: String) -> [WindowID] {
        guard let workspace = workspaces[name], !workspace.tiled.isEmpty,
              let monitor = monitor(monitorShowing(name) ?? workspace.lastMonitor ?? focusedMonitor) ?? monitors.first else { return [] }
        let placed = workspace.placements(in: monitor.visibleFrame, settings: settings, minimums: minSizes)
        return workspace.tiled.filter { id in
            guard let minimum = minSizes[id], case .frame(let rect)? = placed[id] else { return false }
            return rect.width < minimum.width - 2 || rect.height < minimum.height - 2
        }
    }

    /// When a workspace can't give every window the room it needs, the newest arrival
    /// floats, centred, rather than one the user already arranged. Repeats until the rest
    /// fit, then tiles again any of those that fit after all (a later float may have freed
    /// their room). Returns the windows left floating.
    ///
    /// A window that couldn't fit even alone floats itself: moving others out wouldn't help.
    /// None of this changes which window has focus.
    @discardableResult
    public mutating func makeRoom(on name: String) -> [WindowID] {
        var floated: [WindowID] = []
        holdRetiling = true
        let area = usableArea(ofWorkspace: name)
        while case let cramped = cramped(on: name), !cramped.isEmpty {
            let hopeless = cramped.first { id in
                guard let area, let minimum = minSizes[id] else { return false }
                return minimum.width > area.width + 2 || minimum.height > area.height + 2
            }
            guard let victim = hopeless ?? workspaces[name]?.tiled.max(by: { (joined[$0] ?? 0) < (joined[$1] ?? 0) }) else { break }
            floatForRoom(victim, on: name)
            floated.append(victim)
        }
        holdRetiling = false
        retileWhereRoom(on: name)
        return floated.filter { windows[$0]?.isFloating == true }
    }

    private mutating func floatForRoom(_ id: WindowID, on name: String) {
        guard let window = windows[id] else { return }
        let minimum = minSizes[id] ?? .zero
        let size = CGSize(width: max(window.frame.width, minimum.width), height: max(window.frame.height, minimum.height))
        workspaces[name]?.move(id, toFloating: true)
        windows[id]!.isFloating = true
        windows[id]!.floatingFrame = CGRect(origin: window.frame.origin, size: size)
        centerFloating(id)
        autoFloated.insert(id)
    }

    /// The area a workspace's tiles fill, on the display showing it (or last showing it).
    func usableArea(ofWorkspace name: String) -> CGRect? {
        guard let workspace = workspaces[name],
              let monitor = monitor(monitorShowing(name) ?? workspace.lastMonitor ?? focusedMonitor) ?? monitors.first else { return nil }
        let outer = (workspace.tiled.count <= 1 && settings.smartGaps) ? 0 : settings.outerGap
        return monitor.visibleFrame.inset(by: Insets(all: outer))
    }

    /// Tiles windows that floated for lack of room again, oldest first, as long as they fit.
    mutating func retileWhereRoom(on name: String) {
        guard !holdRetiling, let candidates = workspaces[name]?.floating.filter({ autoFloated.contains($0) }), !candidates.isEmpty else { return }
        guard name != Self.scratchpad else { return }
        for id in candidates.sorted(by: { (joined[$0] ?? 0) < (joined[$1] ?? 0) }) {
            guard let saved = workspaces[name] else { return }
            workspaces[name]!.move(id, toFloating: false)
            windows[id]!.isFloating = false
            if cramped(on: name).isEmpty {
                autoFloated.remove(id)
            } else {
                workspaces[name] = saved
                windows[id]!.isFloating = true
            }
        }
    }

    public mutating func setZoom(_ toggle: Command.Toggle) {
        guard let name = focusedWorkspaceName, let current = workspaces[name]?.focused, workspaces[name]!.tiled.contains(current) else { return }
        let zoomed = workspaces[name]!.zoomed == current
        let shouldZoom = toggle == .toggle ? !zoomed : toggle == .on
        workspaces[name]!.zoomed = shouldZoom ? current : nil
    }

    public mutating func toggleSplit() {
        guard let name = focusedWorkspaceName, let current = workspaces[name]?.focused,
              let area = usableArea(for: name), let tree = workspaces[name]?.tree else { return }
        workspaces[name]!.tree = tree.togglingSplit(containing: current, in: area, gap: settings.innerGap)
    }

    public mutating func balance() {
        guard let name = focusedWorkspaceName else { return }
        workspaces[name]!.balance()
    }

    /// Resizes a tiled window by moving the split next to it, or a floating window in place.
    /// `edge` names the side being dragged when the user resizes with the mouse.
    public mutating func resize(_ id: WindowID, _ axis: Command.ResizeAxis, by delta: CGFloat, edge: Direction? = nil) {
        guard let window = windows[id], var workspace = workspaces[window.workspace] else { return }
        if window.isFloating {
            guard var frame = window.floatingFrame ?? Optional(window.frame) else { return }
            if axis == .width { frame = frame.insetBy(dx: -delta / 2, dy: 0) } else { frame = frame.insetBy(dx: 0, dy: -delta / 2) }
            windows[id]!.floatingFrame = frame.integralized
            return
        }
        guard let area = usableArea(for: window.workspace) else { return }
        let splitAxis: Axis = axis == .width ? .horizontal : .vertical
        workspace.tree = workspace.tree?.resizing(id, along: splitAxis, by: delta, edge: edge, in: area, gap: settings.innerGap)
        workspaces[window.workspace] = workspace
    }

    /// The window was dragged by its title bar and dropped. Dropping it onto another tiled
    /// window swaps the two; dropping it on another monitor moves it there.
    /// Two tiled windows on the same workspace trade places.
    public mutating func swapWindows(_ a: WindowID, _ b: WindowID) {
        guard a != b, let first = windows[a], let second = windows[b], first.workspace == second.workspace,
              !first.isFloating, !second.isFloating else { return }
        workspaces[first.workspace]!.swap(a, b)
    }

    public mutating func dropWindow(_ id: WindowID, at point: CGPoint) {
        guard let window = windows[id], !window.isFloating else { return }
        let frames = visibleTiledFrames()
        if let target = frames.first(where: { $0.0 != id && $0.1.contains(point) })?.0, let targetWorkspace = windows[target]?.workspace {
            if targetWorkspace == window.workspace {
                workspaces[targetWorkspace]!.swap(id, target)
            } else {
                moveWindow(id, to: .named(targetWorkspace), follow: true)
                workspaces[targetWorkspace]!.swap(id, target)
            }
            return
        }
        if let monitor = monitors.first(where: { $0.frame.contains(point) }), let name = visible[monitor.id], name != window.workspace {
            moveWindow(id, to: .named(name), follow: true)
        }
    }

    // MARK: Placement

    public func usableArea(for workspace: String) -> CGRect? {
        guard let monitor = monitorShowing(workspace).flatMap(monitor(_:)) else { return nil }
        let outer = (workspaces[workspace]?.tiled.count == 1 && settings.smartGaps) ? 0 : settings.outerGap
        return monitor.visibleFrame.inset(by: Insets(all: outer)).integralized
    }

    /// Where every managed window should be right now.
    public mutating func placements() -> [WindowID: Placement] {
        var result: [WindowID: Placement] = [:]
        for (id, window) in windows where !isVisible(window.workspace) {
            result[id] = .hidden
        }
        if let monitorID = scratchpadMonitor, let monitor = monitor(monitorID), let pad = workspaces[Self.scratchpad] {
            for id in pad.floating {
                guard let frame = windows[id]?.floatingFrame ?? windows[id]?.frame else { continue }
                result[id] = .frame(Self.translate(frame, into: monitor))
            }
        }
        for (monitorID, name) in visible {
            guard let monitor = monitor(monitorID), let workspace = workspaces[name] else { continue }
            for (id, placement) in workspace.placements(in: monitor.visibleFrame, settings: settings, minimums: minSizes) {
                if case .frame(let rect) = placement, let limit = maxSizes[id] {
                    result[id] = .frame(Self.fit(rect, within: limit))
                } else {
                    result[id] = placement
                }
            }
            for id in workspace.floating {
                guard let frame = windows[id]?.floatingFrame ?? windows[id]?.frame else { continue }
                result[id] = .frame(Self.translate(frame, into: monitor))
            }
        }
        return result
    }

    /// Records the largest size a window will take. Nil forgets it, for a window that has
    /// shown it can grow after all.
    public mutating func limitSize(_ id: WindowID, to size: CGSize?) {
        guard windows[id] != nil || size == nil else { return }
        maxSizes[id] = size
    }

    /// A tile shrunk to a size cap, centred where the full tile was.
    public static func fit(_ rect: CGRect, within limit: CGSize) -> CGRect {
        let width = min(rect.width, limit.width), height = min(rect.height, limit.height)
        return CGRect(x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(), width: width, height: height)
    }

    /// Keeps a floating frame on the given monitor: frames already there stay put, others
    /// move over keeping their position relative to the monitor they came from.
    static func translate(_ frame: CGRect, into monitor: Monitor) -> CGRect {
        if monitor.frame.contains(frame.center) { return frame }
        let area = monitor.visibleFrame
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }

    /// Where to park a window of a hidden workspace. macOS won't let a window leave the
    /// screen entirely, so it goes to a bottom corner with one pixel left on screen, on the
    /// side where it can't spill onto a neighbouring display. The bottom edge of the full
    /// display (not the visible area) tucks that pixel behind the Dock when it's there.
    public func parkingOrigin(for size: CGSize, on monitorID: MonitorID?) -> CGPoint {
        guard let monitor = monitor(monitorID) ?? monitors.first(where: \.isMain) ?? monitors.first else { return .zero }
        let frame = monitor.frame
        let right = CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
        let left = CGPoint(x: frame.minX - size.width + 1, y: frame.maxY - 1)
        func spill(_ origin: CGPoint) -> CGFloat {
            let rect = CGRect(origin: origin, size: size)
            return monitors.filter { $0.id != monitor.id }.reduce(0) { $0 + rect.intersection($1.frame).area }
        }
        return spill(right) <= spill(left) ? right : left
    }
}
