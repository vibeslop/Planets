import AppKit
import OSLog
import PlanetsCore
import PlanetsPrivate

let log = Logger(subsystem: "dev.levelorbit.planets", category: "wm")

/// Connects PlanetsCore's pure model to macOS.
///
/// The flow is one-directional: an event (a hotkey, a new window, a focus change) mutates
/// `world`; `reconcile()` asks the world where every window should be, compares that with
/// what was last applied, and sends only the differences to each app's thread, all apps
/// in parallel. Nothing here waits on another process.
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

    /// Called after every state change, coalesced to one call per run-loop turn.
    var onChange: ((Change) -> Void)?
    /// Called when the user moves to another workspace, to show the HUD.
    var onWorkspaceSwitch: ((String) -> Void)?

    private var observers: [pid_t: AppObserver] = [:]
    private var lastApplied: [WindowID: CGRect] = [:]
    /// What each window was given by the few passes before its latest. A slow app's report of
    /// one of those, arriving after the latest went out, is an echo, not the app's own move.
    private var appliedBefore: [WindowID: [CGRect]] = [:]
    private var appliedAt: [WindowID: ContinuousClock.Instant] = [:]
    /// Which layout pass last gave each window somewhere to go, so a pass's hiding that
    /// waited for its showing can tell a window a newer pass has brought back.
    private var passOf: [WindowID: Int] = [:]
    private var passes = 0
    private var parked: Set<WindowID> = []
    private var ignored: Set<WindowID> = []
    /// Workspace each minimised or hidden window came from, so it returns to the same place.
    /// Also filled from disk at launch, so a restart keeps every window on its workspace.
    private var remembered: [WindowID: String] = [:]
    private var rememberedFloating: Set<WindowID> = []
    /// The tile each remembered window had, so it comes back to the same spot rather than
    /// beside whichever window has focus.
    private var rememberedSlot: [WindowID: TileSlot] = [:]
    /// Where windows were when Planets last quit, used only while it starts up.
    private var launchMemory: [WindowID: SavedWindow] = [:]
    /// How each workspace's tiles were arranged when Planets last quit. Windows coming
    /// back during start-up take their spots in it, so none trades places with another.
    private var launchArrangements: [String: Workspace.Arrangement] = [:]
    /// When start-up ends and saved places stop counting. Nil while the screen is locked:
    /// a locked screen shows no windows, so nothing can be found until it's unlocked.
    private var launchMemoryUntil: ContinuousClock.Instant?
    /// Started on a locked screen: saved places wait, however long, for the unlock. A clock
    /// started any earlier ran out while the screen was still locked and lost the layout.
    private var startupWaitsForUnlock = false
    private var launchMemoryActive: Bool {
        !launchMemory.isEmpty && (startupWaitsForUnlock || launchMemoryUntil.map { ContinuousClock.now < $0 } == true)
    }
    private var spaceChangedAt: ContinuousClock.Instant?

    /// A window gone full screen, on a Space of its own. It still belongs to the workspace it
    /// was on: the strip and the menu count it there, and switching to that
    /// workspace brings it back to the front, still full screen.
    struct FullScreenWindow: Equatable {
        var pid: pid_t
        var workspace: String
        var appName: String
        var title: String
        /// When it was noted: a window still on its way into full screen isn't on its Space yet.
        var since: ContinuousClock.Instant = .now
    }
    private(set) var fullScreenWindows: [WindowID: FullScreenWindow] = [:]
    /// Workspaces last seen showing their full-screen window rather than their tiles.
    private(set) var showingFullScreen: [String: WindowID] = [:] {
        didSet { if showingFullScreen != oldValue { schedulePersist() } }
    }
    /// A window put away: minimised to the Dock, or hidden with its app (⌘H). Like a full-
    /// screen window, it still belongs to the workspace it was on: the menu
    /// list it there, and however it's brought back, it returns to its tile. With the Dock
    /// hidden, the menu is the only way back to a minimised window.
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
    /// A window being brought back by Planets, which takes focus once it's back. Until
    /// then nothing else on its workspace is focused, so the glow doesn't flash on another
    /// window first.
    private var restoring: (id: WindowID, until: ContinuousClock.Instant)?

    /// The window each app was last used in, so going to an app goes to that window.
    private var lastUsed: [pid_t: WindowID] = [:]

    /// Until when a Space change is Planets's own doing, not the user's.
    private var ownSpaceChangeUntil: ContinuousClock.Instant?
    private var fullScreenWatch: Timer?
    /// When the display last woke or the screen was unlocked. For a few seconds after, apps
    /// can leave windows that are still open out of their lists.
    private var wokeAt: ContinuousClock.Instant?
    private var persistScheduled = false
    /// What was last written, so an unchanged state isn't written again.
    private var persisted: Data?
    /// Windows a scan found but left out because they weren't on screen. Mostly these are
    /// background tabs of a native tab group, waiting to be selected; remembering their
    /// frame lets a tab that comes forward inherit its sibling's tile.
    private var offscreen: [WindowID: (pid: pid_t, frame: CGRect)] = [:]
    /// Offscreen windows seen behind a tile of their group. A background tab keeps the frame
    /// it had when it was last in front, so after a resize this is how it's still known.
    private var backgroundTabs: Set<WindowID> = []
    /// When each window last reported its frame, to tell settled frames from requested ones.
    private var reportedAt: [WindowID: ContinuousClock.Instant] = [:]
    /// Windows the user is dragging or resizing with the mouse, with the frame they started from.
    private var adjusting: [WindowID: CGRect] = [:]
    /// The frame of a window being resized by its edge, as far as the layout has followed it.
    private var liveFrames: [WindowID: CGRect] = [:]
    /// A tile being dragged, and where every tile of its workspace was when the drag began.
    private var moveOrigin: (id: WindowID, frames: [WindowID: CGRect])?
    /// The tile the dragged one has traded places with for now.
    private var liveSwapTarget: WindowID?
    private var liveInFlight = false
    private var livePending = false
    /// While an edge is dragged: each other tile's frame when the drag began, and the frame
    /// it has been given since, which slides more than it resizes (see liveResizePass).
    private var liveStart: [WindowID: CGRect] = [:]
    private var liveShown: [WindowID: CGRect] = [:]
    private var adjustTimer: Timer?
    private var snapBack: Set<WindowID> = []
    private var snapBackScheduled = false
    private var reparkCounts: [WindowID: (count: Int, since: ContinuousClock.Instant)] = [:]
    private var parkingCheck: DispatchWorkItem?
    /// How many times in a row each parked window was found back in view.
    private var escapeCounts: [WindowID: Int] = [:]
    /// A window being moved with the modifier held: where the pointer grabbed it and where it started.
    private var dragging: (id: WindowID, grab: CGPoint, origin: CGPoint)?
    private var dragInFlight = false
    private var dragPending: CGPoint?
    /// Where the left button last went down, for telling a title-bar drag from a click.
    private var press: CGPoint?
    /// A window the user is moving by its title bar, which the rim follows.
    private var userMove: TitleBarMove?
    private var settleMove: DispatchWorkItem?
    private var gestureWatch: Timer?
    /// A window the user is resizing by an edge. Its frame can't be predicted, so the rim
    /// steps aside until the button comes up rather than trailing behind.
    private var userResize: WindowID?
    /// Tells the input tap whether to pass pointer moves on.
    var onFollowPointer: ((Bool) -> Void)?
    /// Sizes windows stopped at once; a second stop at the same size makes it a cap.
    private var capCandidates: [WindowID: CGSize] = [:]
    /// Sizes windows grew to once; a second time at the same size makes it a minimum.
    private var minCandidates: [WindowID: CGSize] = [:]
    /// Counts each window's asks after a refusal, so a check knows whether it's still current.
    /// It only goes up while the window lives: fitting bumps it too, cancelling a check on its
    /// way, and a count that started over let an old check pass for a new one.
    private var refusalAsks: [WindowID: Int] = [:]
    /// What the tiled windows of apps that quit left behind, by app, for when they start again.
    private var vacated: [String: Vacancy] = [:]
    /// The same for windows that just closed, by process, in case the app is quitting.
    private var closing: [pid_t: Vacancy] = [:]

    private struct Vacancy {
        /// With when each left: a closed window counts for ten seconds after its own close,
        /// in case its app is quitting.
        var windows: [(id: WindowID, slot: TileSlot, title: String, at: ContinuousClock.Instant)] = []
        /// Each workspace's tiles as the app's first window there left. Windows that come
        /// back together rebuild it, ratios and all, as after a restart of Planets; their
        /// spots alone name neighbours that are gone too.
        var arrangements: [String: Workspace.Arrangement] = [:]
        /// The windows back already: the number each had, to the one it has now.
        var returned: [WindowID: WindowID] = [:]
        /// When the app quit.
        var at = ContinuousClock.now
        var firstBack: ContinuousClock.Instant?

        mutating func note(_ id: WindowID, in world: World) {
            guard let slot = world.slot(of: id) else { return }
            windows.append((id, slot, world.windows[id]?.title ?? "", .now))
            if arrangements[slot.workspace] == nil { arrangements[slot.workspace] = world.workspaces[slot.workspace]?.arrangement }
        }
    }
    /// Windows put on a workspace out of view as their app opened or restarted, with when.
    /// The app comes forward as it starts, and that alone doesn't take the user there.
    private var placedAway: [WindowID: ContinuousClock.Instant] = [:]
    /// The workspace each app was opened from, as its process appeared, and when its first
    /// window showed. An app slow to open puts its first windows there, not on a workspace
    /// the user went on to meanwhile.
    private var openedFrom: [pid_t: Opening] = [:]
    private struct Opening {
        var workspace: String
        var at = ContinuousClock.now
        var shown: ContinuousClock.Instant?
    }
    private var launchWatch: NSKeyValueObservation?
    /// When each window joined the layout. In its first seconds an app may put back the size
    /// it saved, after it's been tiled and more than once; that's no refusal of its tile.
    private var joinedAt: [WindowID: ContinuousClock.Instant] = [:]
    private var settling: Set<WindowID> = []
    private static let opening: Duration = .seconds(2)

    /// After Planets focuses a window, macOS may still report focus on the window that
    /// just got hidden. Such stale reports would yank the user back, so they are ignored
    /// until the intended window reports in or the deadline passes.
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

    // MARK: Lifecycle

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
            // Windows can't be found while the screen is locked; look again once it isn't.
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
        // The earliest sign of an app opening: its process appears, well before its windows
        // (didLaunch comes about when they do).
        // Each change is an insertion carrying only the apps that just opened (checked on
        // macOS 27), or a removal carrying none.
        launchWatch = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, change in
            let pids = (change.newValue ?? []).map(\.processIdentifier)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.appsOpening(pids) }
            }
        }
        notify(.all)
    }

    /// Puts every hidden window back on screen before quitting, so nothing is left parked
    /// in a corner. Waits briefly for the apps to finish moving.
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
        // Only changes that move windows re-place them. A menu bar toggle or a key binding
        // shouldn't make every window jump.
        let layoutChanged = workspacesChanged || newConfig.layout != config.layout || newConfig.rules != config.rules
            || newConfig.onlyApps != config.onlyApps || newConfig.ignoredApps != config.ignoredApps || newConfig.workspaceMonitors != config.workspaceMonitors
        config = newConfig
        world.settings = newConfig.layout
        world.pinnedMonitors = newConfig.workspaceMonitors
        if workspacesChanged {
            // Rebuild the model with the new names but keep every window where it can stay.
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
        // Apps that are now excluded or newly included get re-evaluated.
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
        // A quitting app may be restarting, for an update or after a crash. Its windows come
        // back with new numbers, so their spots are kept under the app's name for a while:
        // windows still open now, and ones it closed in the seconds before it exited.
        var vacancy = recentlyClosed(pid)
        closing[pid] = nil
        for id in ids { vacancy.note(id, in: world) }
        if !vacancy.windows.isEmpty {
            vacancy.at = .now
            vacated[observer.bundleID ?? observer.appName] = vacancy
        }
        removeWindows(ids, refocus: refocus)
    }

    /// What the app's windows closed in the last ten seconds left, kept in case it's quitting.
    private func recentlyClosed(_ pid: pid_t) -> Vacancy {
        var vacancy = closing[pid] ?? Vacancy()
        vacancy.windows.removeAll { ContinuousClock.now - $0.at > .seconds(10) }
        // A workspace's tiles are kept from when the first window there left; with it gone,
        // the next to leave there notes them afresh.
        let workspaces = Set(vacancy.windows.map(\.slot.workspace))
        vacancy.arrangements = vacancy.arrangements.filter { workspaces.contains($0.key) }
        return vacancy
    }

    private func appsOpening(_ pids: [pid_t]) {
        guard isEnabled, let workspace = world.focusedWorkspaceName else { return }
        // Helpers and agents never show a window; what's a minute old is no help to anyone.
        let now = ContinuousClock.now
        openedFrom = openedFrom.filter { now - $0.value.at < .seconds(60) }
        for pid in pids where openedFrom[pid] == nil { openedFrom[pid] = Opening(workspace: workspace) }
    }

    /// The workspace an app was opened from, for its first windows: those showing within a
    /// minute of it opening and two seconds of the first. Later ones open where you are.
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

    /// The spot a window of this app left when the app quit, if it quit in the last two
    /// minutes: a restarted app gets its tiles back, side and size included, on the
    /// workspaces they were on, wherever the user went while it restarted. A window takes
    /// the spot of the one with its title, as a browser's do when it restores them, else
    /// one on the workspace in front, else the next. Only a restart reaches other
    /// workspaces: windows showing within half a minute of the quit and ten seconds of the
    /// first back, as an app restoring many windows can take that long. Later ones, a new
    /// window or the app opened again by hand, take a spot on the workspace in front only;
    /// elsewhere they'd open out of view.
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

    /// The app whose full-screen window is in front is left out. Nothing about its windows
    /// changes as Spaces do, and an app answers Accessibility on its main thread: a
    /// full-screen app in front stopped taking input while it answered, for seconds in an
    /// app slow to answer. Leaving full screen brings the desktop forward, and the next look
    /// includes it again.
    private func rescanAll() {
        let front = frontFullScreenWindow().flatMap { fullScreenWindows[$0]?.pid }
        for observer in observers.values where observer.pid != front { observer.rescan() }
    }

    /// Right after an unlock the window server doesn't list every window as on screen yet,
    /// so a window can be missed; looking twice more over the next few seconds finds them.
    private func screenUnlocked() {
        // Started on a locked screen: start-up really begins now, and lasts past the last look.
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

    /// Looks again as the Space changes, and twice more as it settles: a window leaving full
    /// screen still says it's full screen until its animation ends, and only a later look
    /// finds it back and returns it to its tile.
    private func spaceChanged() {
        spaceChangedAt = .now
        // Started while a full-screen Space was in front: the desktop's windows can be found now.
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
        // Moves sent while the Space was changing may have been dropped. Checked soon, so a
        // switch out of full screen settles at once, and again once the change is surely over.
        // macOS also pulls a parked window partly back into view as Spaces change; the check
        // for escaped windows runs too, before the desktop is in view for long.
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

    /// Once a Space change has settled, asks the window server where every tile really is and
    /// puts back any that isn't in its place. A resize macOS drops mid-change sends no report
    /// at all, because nothing about the window changed, so without this a window could stay
    /// the wrong size, over its neighbour, while Planets believed it placed.
    private func checkTiledFrames() {
        let tiles = lastApplied.filter { id, _ in !parked.contains(id) && adjusting[id] == nil && world.windows[id]?.isFloating == false }
        guard !tiles.isEmpty else { return }
        let real = Self.windowBounds(Set(tiles.keys))
        var misplaced = false
        for (id, placed) in tiles {
            guard let frame = real[id] else { continue }
            // The same slack as for an app's own adjustments, such as a terminal's character grid.
            if abs(frame.minX - placed.minX) > 24 || abs(frame.minY - placed.minY) > 24 || abs(frame.width - placed.width) > 24 || abs(frame.height - placed.height) > 24 {
                lastApplied[id] = nil
                misplaced = true
            }
        }
        if misplaced { reconcile(label: "space settled") }
    }

    /// A display waking on a locked screen shows the lock screen; the unlock looks again.
    private func screensWoke() {
        guard !Self.screenLocked else { return }
        lookAgainAfterWaking()
    }

    /// The last look comes after the grace period in which windows missing from a scan are
    /// kept, so a window that really went away while the screen was off is let go then.
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

    /// Whether this desktop is out of sight: a full-screen app or another desktop Space is in
    /// front. On this desktop every known window keeps at least a sliver on screen, parked
    /// ones included; in a full-screen Space none does but the full-screen window itself,
    /// which covers a whole display.
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

    /// macOS posts screen-change notifications for many reasons that move nothing (display
    /// utilities poke them, the Dock does). Only a real change re-places windows, and then
    /// only the ones whose spot changed: the usual comparison against what was last applied
    /// takes care of that. Parked windows move only if a display's frame moved.
    private func screensChanged() {
        let monitors = Displays.monitors()
        guard monitors != world.monitors else { return }
        let framesMoved = Set(monitors.map(\.frame)) != Set(world.monitors.map(\.frame))
        world.setMonitors(monitors)
        if framesMoved { parked.removeAll() }
        reconcile(label: "displays")
        notify(.all)
    }

    // MARK: Events from apps

    private func handle(_ event: AppEvent, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        switch event {
        case .discovered(let snapshots):
            // On a locked screen apps list few of their windows, or none. Taking that as
            // windows closing sent every window to the current workspace once the screen
            // was unlocked and they were found again. The unlock looks again.
            guard !Self.screenLocked else { return }
            // New windows join only if they're on screen in the current macOS Space. Known
            // windows stay through a Space change (visiting a full-screen app would otherwise
            // reshuffle every layout) and leave only when closed, minimised or full screen.
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
            // The first scan that finds windows means the screen is in use; if the unlock
            // went unannounced, start-up ends from here.
            if startupWaitsForUnlock, !usable.isEmpty, !Self.screenLocked, !Spaces.fullScreenInFront {
                startupWaitsForUnlock = false
                launchMemoryUntil = .now + .seconds(15)
            }
            let present = Set(usable.map(\.id))
            // A window missing from the list is still open, and keeps its place, while
            // Accessibility can't see it: just after the display wakes, during a Space change,
            // and while a full-screen app or another desktop Space is in front. Removed and
            // found again, every window came back beside the focused one, on the current
            // workspace, and the layouts were shuffled.
            let waking = wokeAt.map { ContinuousClock.now - $0 < .seconds(Self.wakeGrace) } ?? false
            let spaceChanging = spaceChangedAt.map { ContinuousClock.now - $0 < .seconds(2) } ?? false
            let unseen = waking || spaceChanging || desktopOutOfSight(onScreen: onScreen)
            let listed = Set(snapshots.map(\.id))
            let leaving = world.windows.values.filter { $0.pid == pid && !present.contains($0.id) && !(unseen && !listed.contains($0.id)) }.map(\.id)
            if !leaving.isEmpty {
                log.notice("scan of \(observer.appName, privacy: .public): \(leaving.count) window(s) left, \(snapshots.count) listed")
            }
            // Windows gone full screen come back to their workspace and tile, as do windows
            // leaving during a Space change. Any other window that leaves while it still
            // exists was hidden by its app, as chat apps do when closed to the menu bar;
            // opening it again is a fresh start where the user is.
            // Minimised without a word: put away, as if it had said so.
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
            // Full screen before Planets started, or before it knew the window: it belongs
            // to the workspace it was saved on, or else to the one in front.
            for snapshot in snapshots where snapshot.isFullScreen && fullScreenWindows[snapshot.id] == nil && world.windows[snapshot.id] == nil {
                let workspace = remembered[snapshot.id] ?? launchMemory[snapshot.id]?.workspace ?? world.focusedWorkspaceName ?? world.workspaceOrder[0]
                remembered[snapshot.id] = workspace
                fullScreenWindows[snapshot.id] = FullScreenWindow(pid: pid, workspace: workspace, appName: observer.appName, title: snapshot.title)
                watchFullScreenWindows()
                notify(.workspaces)
            }
            for snapshot in usable {
                // A tab now in front of its group takes the place of the tab that was, which is
                // out of sight now, wherever its group is.
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
                // An app quitting closes its windows first and exits a moment later, so by the
                // time the quit is known the windows are gone. Their spots are noted here, and
                // kept only if the app does quit (see forget).
                var vacancy = recentlyClosed(pid)
                vacancy.note(id, in: world)
                if !vacancy.windows.isEmpty { closing[pid] = vacancy }
                removeWindows([id], refocus: true)
            }
        case .focused(let id):
            // Background apps report their own focus changes too; only the frontmost app's
            // focus is the user's. App switches arrive through didActivate, which asks anew.
            guard let id, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            // A full-screen window is known already. Looking at it again told nothing new and
            // held up its app, which answers on the main thread its input needs.
            if fullScreenWindows[id] != nil { return }
            if world.windows[id] == nil, !ignored.contains(id) {
                // A window Planets left out just took focus, most likely a background
                // tab the user selected. Look at it again.
                observer.reportWindow(id)
                return
            }
            osFocused(id)
        case .frameChanged(let id, let frame):
            frameReported(id, frame)
        case .titleChanged(let id, let title):
            world.updateWindow(id, title: title)
            // Not notified: the menu reads titles as it opens, and the strip's VoiceOver value
            // catches up at the next change. A minimised terminal's title can tick every second.
            if awayWindows[id] != nil, !title.isEmpty { awayWindows[id]?.title = title }
        case .minimized(let id):
            putAway([id], reason: .minimized)
        case .fullScreen(let id):
            // On a Space of its own until it comes back, to the same tile. Focus stays with it.
            noteFullScreen(id)
            remember(id)
            removeWindows([id], refocus: false)
        case .restored(let snapshot):
            let fromDock = awayWindows[snapshot.id]?.reason == .minimized
            let asked = restoring?.id == snapshot.id
            // A restore Planets asked for finishes as the window joins.
            consider(snapshot, from: observer)
            if fromDock, !asked, world.windows[snapshot.id] != nil {
                // Back from the Dock or the app's Window menu: it's the window the user wants
                // to see, in its tile, on its own workspace.
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
            // Dropped so a later launch notification or reload can try again.
            observers[pid] = nil
            observer.stop()
        }
    }

    // MARK: Native tabs

    /// macOS shows each native tab as its own window stacked exactly on its siblings, with
    /// only the selected one on screen. Planets tiles the group once: whichever tab is
    /// in front holds the tile.
    private func handleCreated(_ snapshot: WindowSnapshot, from observer: AppObserver, retry: Bool = true, attempt: Int = 0) {
        if world.windows[snapshot.id] == nil, snapshot.kind != .ignore, let sibling = tabSibling(of: snapshot, pid: observer.pid) {
            let onScreen = Self.onScreenWindowIDs()
            if onScreen.contains(snapshot.id) && !onScreen.contains(sibling) {
                adoptTab(snapshot, replacing: sibling, from: observer)
                return
            }
            if retry {
                // The window server may not have swapped the two yet; look once more shortly.
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
        // Not on screen: still being ordered in, a tab in the background, or on another Space.
        // Joining now would put it on the workspace in front, where it isn't; it's looked at
        // again shortly, and after that it joins when it shows (its focus report, or a scan).
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
        // Only a window that joined needs a layout pass and a fresh look at focus. A focused
        // window that stays out (full screen, a popover) answered the focus report by being
        // looked at again, which asked for the focus report again: thousands of times a
        // second, enough to make the app stop taking keystrokes.
        guard !wasKnown, world.windows[snapshot.id] != nil else { return }
        reconcile(label: "new window")
        // The focus report for a new window can arrive before the window was known.
        observer.reportFocusedWindow()
    }

    /// The known window a tab shares its group with: the tabs of a group are windows of
    /// their own with one frame between them. A group on a hidden workspace is parked, so
    /// there the window server's frame tells, not the tile's; left out, a tab coming forward
    /// in a parked group joined the workspace in front as a window of its own.
    private func tabSibling(of snapshot: WindowSnapshot, pid: pid_t) -> WindowID? {
        world.windows.values.first { window in
            guard window.pid == pid, window.id != snapshot.id else { return false }
            if !parked.contains(window.id) { return window.frame.isClose(to: snapshot.frame, tolerance: 3) }
            var bounds = CGRect.zero
            return planets_window_bounds(window.id, &bounds) && bounds.isClose(to: snapshot.frame, tolerance: 3)
        }?.id
    }

    /// One tab group, one tile. A known window now in the background while another window of
    /// the same app is on screen with exactly its frame is a tab of that window's group: the
    /// tab in front takes its place, workspace and tile, and gives up any tile of its own.
    /// That mends a group split over two workspaces, however it happened.
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

    /// `focusing` is for a tab the user brought forward; a scan that finds one doesn't move focus.
    private func adoptTab(_ snapshot: WindowSnapshot, replacing old: WindowID, from observer: AppObserver, focusing: Bool = true) {
        guard let previous = world.windows[old] else { return }
        let candidate = WindowCandidate(id: snapshot.id, pid: observer.pid, bundleID: observer.bundleID, appName: observer.appName, title: snapshot.title, frame: snapshot.frame, prefersFloating: snapshot.kind == .float)
        world.replaceWindow(old, with: candidate)
        offscreen[old] = (previous.pid, previous.frame)
        offscreen[snapshot.id] = nil
        backgroundTabs.insert(old)
        backgroundTabs.remove(snapshot.id)
        // A group on a hidden workspace stays parked under its new front tab.
        if parked.remove(old) != nil { parked.insert(snapshot.id) }
        lastApplied[snapshot.id] = lastApplied.removeValue(forKey: old)
        appliedAt[snapshot.id] = appliedAt.removeValue(forKey: old)
        // The new tab's frame came from the app, so it counts as the app's answer. Without
        // it the glow wraps the frame Planets asked for, which a terminal snapping to its
        // character grid never takes, and no report corrects it: the tab never resizes.
        reportedAt[snapshot.id] = .now
        reportedAt[old] = nil
        if focusing { world.noteFocus(snapshot.id) }
        reconcile(label: "tab")
        notify(.all)
    }

    /// The background tab about to come forward as a tab closes: the app's one already on
    /// screen, else a guess, a tab stacked exactly under the closing one or one known to be
    /// behind a tile. macOS shows the next tab around the time the close is reported, a few
    /// milliseconds either side, so the guess only holds the tile until it does (closeTab).
    private func tabUnderneath(_ id: WindowID) -> WindowID? {
        guard let window = world.windows[id] else { return nil }
        let tabs = offscreen.filter { $0.value.pid == window.pid && world.windows[$0.key] == nil }
        guard !tabs.isEmpty else { return nil }
        let onScreen = Self.onScreenWindowIDs()
        return tabs.keys.first(where: onScreen.contains)
            ?? tabs.first { $0.value.frame.isClose(to: window.frame, tolerance: 3) }?.key
            ?? tabs.keys.first(where: backgroundTabs.contains)
    }

    /// The stand-in gets the closing tab's frame, the group's, which the tab coming forward
    /// takes. With its own, from when it was last in front, the tab macOS did show didn't
    /// match it and joined as a new window, splitting the tile in half.
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

    /// Until a tab shows, the stand-in holds the tile; whichever of the app's background
    /// windows shows takes it. If none does, the stand-in leaves and the layout reflows. A
    /// stand-in that doesn't show was a guess, perhaps a tab of another of the app's groups:
    /// it goes back to waiting as it was, or closing its own group's front tab later would
    /// find nothing to hold that group's tile.
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

    /// Only a window that still exists: one that closed meanwhile, kept, would be guessed
    /// again for every window of its app that closes, in place of being remembered.
    private func restoreTab(_ tab: WindowID, behind: (pid: pid_t, frame: CGRect), wasBackground: Bool) {
        var frame = CGRect.zero
        guard planets_window_bounds(tab, &frame) else { return }
        offscreen[tab] = behind
        if wasBackground { backgroundTabs.insert(tab) } else { backgroundTabs.remove(tab) }
    }

    /// Notes where a window lived and whether it floated, for when it comes back.
    private func remember(_ id: WindowID) {
        guard let window = world.windows[id] else { return }
        remembered[id] = window.workspace
        rememberedSlot[id] = world.slot(of: id)
        if floatsByChoice(id) { rememberedFloating.insert(id) } else { rememberedFloating.remove(id) }
    }

    /// Floating that should outlive the window leaving: floated by the user or a rule, not
    /// floated for lack of room, which would otherwise come back floating for good.
    private func floatsByChoice(_ id: WindowID) -> Bool {
        world.windows[id]?.isFloating == true && !world.autoFloated.contains(id)
    }

    private func forgetPlace(_ id: WindowID) {
        remembered[id] = nil
        rememberedFloating.remove(id)
        rememberedSlot[id] = nil
        launchMemory[id] = nil
    }

    // MARK: Windows put away

    /// Minimised or hidden: out of the layout, but still on its workspace, with its tile kept
    /// for its return.
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

    /// Windows a scan finds away that Planets didn't see go: minimised or hidden before
    /// it started, or before it knew them. Each belongs to the workspace it was saved on, or
    /// else to the one in front. A hidden app's windows count only if they had a workspace:
    /// its background tabs are off screen too, and were never tiles. Away windows the app no
    /// longer lists have closed.
    private func noteAwayWindows(_ snapshots: [WindowSnapshot], of pid: pid_t, appName: String, onScreen: Set<WindowID>, unseen: Bool) {
        let hidden = NSRunningApplication(processIdentifier: pid)?.isHidden == true
        let bundleID = observers[pid]?.bundleID
        for snapshot in snapshots where awayWindows[snapshot.id] == nil && world.windows[snapshot.id] == nil && !ignored.contains(snapshot.id) {
            // A window a rule leaves alone has no workspace to be listed on.
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

    /// Away windows of a workspace, most recently put away first.
    func awayWindows(on workspace: String) -> [(id: WindowID, window: AwayWindow)] {
        awayWindows.filter { $0.value.workspace == workspace }.sorted { $0.value.since > $1.value.since }.map { ($0.key, $0.value) }
    }

    /// Brings a minimised or hidden window back to its tile, shows its workspace, and focuses
    /// it once it's there. Its workspace's desktop is what's wanted, not a full-screen window
    /// the workspace may be showing.
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
        // An app that doesn't answer leaves the user where they asked to go, with focus there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.restoring?.id == id else { return }
                self.restoring = nil
                self.focusAfterSwitch()
            }
        }
    }

    /// The window `restore` asked for is back: it takes focus.
    private func finishRestoring() {
        guard let id = restoring?.id, world.windows[id] != nil else { return }
        restoring = nil
        activate(id)
    }

    /// Which window each app was last used in. A full-screen window counts as it comes to
    /// the front (see followSpace).
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
        // Saved places from before a restart only count while Planets is starting up:
        // later, the same window number appearing means the app showed it again.
        let restored = launchMemoryActive ? launchMemory.removeValue(forKey: snapshot.id) : nil
        let returning = remembered.removeValue(forKey: snapshot.id)
        let returningSlot = rememberedSlot.removeValue(forKey: snapshot.id)
        let floating = rule?.float ?? (rememberedFloating.remove(snapshot.id) != nil || restored?.floating == true ? true : nil)
        let known = rule?.workspace ?? returning ?? restored?.workspace
        let vacated = known == nil && floating != true && snapshot.kind == .tile ? takeVacatedSlot(for: observer, id: snapshot.id, title: snapshot.title) : nil
        // Asked whatever places it, as it notes the app's first window: a restart's windows,
        // put back where they were, also end the time a fresh one goes where it was opened.
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
                // Where the app put it is fine; leave it there.
                lastApplied[snapshot.id] = snapshot.frame
            } else {
                // Off screen or straddling two displays: centre it on the display in use.
                world.centerFloating(snapshot.id)
            }
        }
        if restoring?.id == snapshot.id { finishRestoring() }
        notify(.workspaces)
    }

    /// `refocus` hands focus to a sensible window when the user closed or hid the focused
    /// one. Windows leaving because of a Space change must not touch focus: taking it would
    /// pull the user out of a full-screen app.
    private func removeWindows(_ ids: [WindowID], refocus: Bool) {
        guard !ids.isEmpty else { return }
        if let pending = pendingReveal, let previous = pending.previous, ids.contains(previous) {
            // The focus jump to a hidden workspace was macOS handing focus on after a close.
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
        // Choose who gets focus before macOS does: left alone, it may pick a window on a
        // hidden workspace and drag the user there.
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
            // The user left while the app opened or restarted. Its windows are on their
            // workspace, and the keyboard goes back to the window in front rather than one out
            // of view.
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
            // The same app moved focus to its window on a hidden workspace. macOS does exactly
            // that just before reporting the focused window closed or minimised, so wait a
            // moment: a close cancels this, anything else (⌘` between windows) goes ahead.
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

    /// A window bigger than its tile, twice: its minimum is noted and the layout moves its
    /// splits to make room. If the workspace can't fit everyone, the newest arrival floats.
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

    /// A window short of its tile, twice: it has a size cap. Only the side that fell short is
    /// capped; the other keeps following its tile.
    private func acceptCap(_ id: WindowID, frame: CGRect, target: CGRect) {
        guard let window = world.windows[id] else { return }
        log.info("\(window.appName, privacy: .public) caps its window at \(Int(frame.width))×\(Int(frame.height)); centring it")
        let unlimited = CGFloat.greatestFiniteMagnitude
        world.limitSize(id, to: CGSize(width: frame.width < target.width - 24 ? frame.width : unlimited,
                                       height: frame.height < target.height - 24 ? frame.height : unlimited))
    }

    /// A refusal counts once the window refuses the same tile a second time, as the window
    /// server sees it once the app has had time to answer. Not by the app's own reports: one
    /// still resizing reports its old size again and again, which looked like refusing twice
    /// and gave Chromium windows minimums and caps they don't have. A second and a half, as
    /// Electron apps take most of one to resize.
    private func confirmRefusal(of id: WindowID, round: Int = 1) {
        let ask = (refusalAsks[id] ?? 0) + 1
        refusalAsks[id] = ask
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                // Only for the latest ask: one for an earlier tile, firing after the window
                // took a narrower one, would see it wider still and give it a minimum.
                // Asked once: whatever the answer, a later refusal starts over.
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
                    // Still refusing, at a size of its own now: an app that first reported
                    // its old size settled at its minimum without a word. That size is the
                    // one asked about again; three rounds at most, for an app that won't settle.
                    if wider { self.minCandidates[id] = frame.size } else { self.capCandidates[id] = frame.size }
                    self.lastApplied[id] = nil
                    self.reconcile(label: "fit")
                    self.confirmRefusal(of: id, round: round + 1)
                }
            }
        }
    }

    /// An app that rounds the frame it's given, as a terminal snapping to its character grid
    /// does, says nothing when the rounded frame is the one it already had: asked for its
    /// tile again, or for one a point narrower, it doesn't move. Without a report the glow
    /// wraps the tile instead of the window, so a moment after the pass the window server
    /// is asked about any window that stayed silent. Only a frame that looks like the app's
    /// rounding of its tile counts: the same corner, within 24 points of the size. Anything
    /// else may be an app that hasn't moved yet, and its own report is still to come.
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
            // A parked window that wanders back into view belongs to an app that fights
            // being hidden. Park it again, but give up after a few rounds.
            if onScreen { repark(id) }
            return
        }
        // Reports from a window on its way to or from parking say nothing about where the
        // user wants it; recording them is how floating windows get lost in the corner.
        guard onScreen else { return }
        world.noteFrame(id, frame)
        reportedAt[id] = .now
        if window.isFloating {
            lastApplied[id] = frame
            // A floating window dragged onto another display joins that display's workspace;
            // otherwise the next layout pass would pull it back.
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
        // Grown past its cap: the app lifted it, so the window gets its whole tile again.
        if let limit = world.maxSizes[id], frame.width > limit.width + 2 || frame.height > limit.height + 2,
           appliedAt[id].map({ ContinuousClock.now - $0 > .milliseconds(500) }) ?? true {
            world.limitSize(id, to: nil)
            lastApplied[id] = nil
            reconcile(label: "uncap")
        }
        guard let target = lastApplied[id] else { return }
        // Right after Planets moved it, a different frame means the app adjusted ours
        // (a minimum size, a terminal snapping to its character grid). Accept it.
        // A second for the app to answer: Electron apps take most of one to resize.
        let justPlaced = appliedAt[id].map { ContinuousClock.now - $0 < .seconds(1) } ?? false
        // A frame from a pass before, read by a slow app before it got to the latest one.
        // Taken for the app moving its window, it was put back, or given a minimum it doesn't
        // have and asked again: each one more resize the slow app had to make.
        if justPlaced, !frame.isClose(to: target), appliedBefore[id]?.contains(where: { frame.isClose(to: $0) }) == true { return }
        if frame.isClose(to: target) {
            // It fits after all: a refusal noted earlier was the app still on its way.
            minCandidates[id] = nil
            capCandidates[id] = nil
            refusalAsks[id, default: 0] += 1
            if id == world.focusedWindow { notify(.frames) }
            return
        }
        // The user is dragging or resizing this window with the mouse. Checked first: an edge
        // drag that starts right after a layout pass mustn't be taken for the app's own rules.
        // It counts only if the press was in this window; a late report from some other app
        // while the button happens to be down is that app's doing. So is a neighbour the live
        // layout is sliding along: dragged leftward or up, it slides under the press, and taken
        // for the window being dragged, it stopped following and left a gap beside the edge.
        if NSEvent.pressedMouseButtons & 1 != 0, let press, liveShown[id] == nil, target.insetBy(dx: -8, dy: -8).contains(press) {
            if adjusting[id] == nil { adjusting[id] = target }
            startAdjustTimer()
            followResize(id, to: frame)
            if id == world.focusedWindow { notify(.frames) }
            return
        }
        let sameCorner = abs(frame.minX - target.minX) <= 2 && abs(frame.minY - target.minY) <= 2
        // Mid-gesture, a neighbour that hasn't caught up with the live layout yet isn't
        // refusing its tile; the pass after the button comes up settles everyone.
        if justPlaced, !adjusting.isEmpty || dragging != nil { return }
        if justPlaced, spaceSettling {
            // While a Space change animates, macOS can drop a resize. That's no refusal: taken
            // for one, a window that came back from full screen left its neighbour with a
            // minimum as tall as the screen. The tile is asked for again once things settle.
            lastApplied[id] = nil
            reconcileWhenSpaceSettles()
            return
        }
        let wider = frame.width > target.width + 24, taller = frame.height > target.height + 24
        let narrower = frame.width < target.width - 24, shorter = frame.height < target.height - 24
        if justPlaced, wider || taller || narrower || shorter, let joined = joinedAt[id], ContinuousClock.now - joined < Self.opening {
            // Still opening: an app may put back the size it saved, more than once, after it's
            // tiled. That's no refusal; it's asked once more when it has settled.
            retileWhenSettled(id, joined: joined)
            return
        }
        if justPlaced {
            // A window that insists on being bigger than its tile would cover its neighbours.
            // Its minimum is noted and the layout moves its splits to make room. If the
            // workspace can't fit everyone, the newest arrival floats, not this window.
            // Like a cap, a minimum counts only when the window refuses the same tile twice:
            // an app still animating to its new size would otherwise leave a minimum forever.
            // The corner needn't match as long as the window covers its whole tile: one too
            // tall for a tile at the bottom of the screen is pushed up by macOS to stay on
            // screen. Taken for the app moving its window, it was put back again and again
            // and its minimum never noted.
            if wider || taller, sameCorner || frame.insetBy(dx: -2, dy: -2).contains(target) {
                // Asked for its tile again, and the window server decides (see confirmRefusal).
                // The same refusal again changes nothing; at a new size, as when an app's old
                // size comes before its minimum, it's a new candidate, checked afresh.
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
            // A window that stops short of its tile has a size cap. Left as it is, it hugs the
            // tile's top-left corner; centred, it looks placed. The tile is asked for once more
            // first, so a slow resize isn't mistaken for a cap.
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
        // The app moved its own tiled window. Put it back once it settles.
        trace("frame \(id): \(Queries.describe(frame)), placed \(Queries.describe(target)), just placed \(justPlaced): snap back")
        snapBack.insert(id)
        scheduleSnapBack()
    }

    /// Asks a window that was still opening for its tile once it has settled. If it still
    /// won't take it then, that's a real minimum or cap, and counts as one.
    private func retileWhenSettled(_ id: WindowID, joined: ContinuousClock.Instant) {
        guard settling.insert(id).inserted else { return }
        let wait = joined + Self.opening - .now
        DispatchQueue.main.asyncAfter(deadline: .now() + PerformanceLog.milliseconds(wait) / 1000) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settling.remove(id) != nil, self.world.windows[id] != nil else { return }
                // A window that can't take its tile stays as it is and says nothing, so the
                // size it has now is the one to compare with, as after any first refusal.
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

    // MARK: Parking check

    /// Accessibility only says where an app *was asked* to put a window. Some apps refuse a
    /// move, or move a window back, without posting any notification, so a window can sit
    /// in plain view while Planets believes it's parked. After each layout pass the
    /// window server, which knows where every window really is, is asked; any parked window
    /// that has escaped is parked again, with growing pauses, for as long as its workspace
    /// stays hidden.
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
            // A parked window keeps a sliver on screen by design; anything bigger has escaped.
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
        // Apps that keep fighting get re-parked less and less often, but never left in view.
        let delays: [Double] = [0.3, 1, 3, 6]
        scheduleParkingCheck(after: delays[min(attempt - 1, delays.count - 1)])
    }

    /// Real on-screen frames from the window server, in the same top-left space as everything else.
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
                // Only a window the window server still has off its tile: a later report may
                // have been the app catching up, and an echo of an earlier frame looks the same
                // as the app moving its own window.
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

    /// When the mouse button comes up after the user dragged or resized a tiled window,
    /// turn that gesture into a layout change: a drop swaps, an edge drag resizes the split.
    private func checkAdjustEnded() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        adjustTimer?.invalidate()
        adjustTimer = nil
        let drop = Displays.toGlobal(NSEvent.mouseLocation)
        let gestures = adjusting, followedFrames = liveFrames
        adjusting.removeAll()
        // Every neighbour gets its exact tile now, resized once. Cleared even if the dragged
        // window closed or floated meanwhile: a neighbour left marked has its own drags taken
        // for its app moving it.
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
                // The layout has followed the edge most of the way already; this is the rest.
                applyEdges(id, from: followed ?? start, to: end, threshold: followed == nil ? 2 : 0.5)
            }
            lastApplied[id] = nil
        }
        reconcile(label: "mouse")
        notify(.all)
    }

    // MARK: Live gestures

    /// An edge drag moves the split as it happens: the neighbours resize with the window,
    /// rather than all at once when the button comes up.
    private func followResize(_ id: WindowID, to frame: CGRect) {
        guard let start = adjusting[id], let window = world.windows[id], !window.isFloating else { return }
        let last = liveFrames[id] ?? start
        // A drag by the title bar keeps the size; that's a move, which follows the pointer.
        guard abs(frame.width - last.width) > 1 || abs(frame.height - last.height) > 1 else { return }
        applyEdges(id, from: last, to: frame, threshold: 0.5)
        liveFrames[id] = frame
        requestLivePass()
    }

    /// Turns the edges a window's frame moved into split changes, the larger edge per axis.
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

    /// A dragged tile trades places with the tile under the pointer as soon as it gets there,
    /// so the layout shows where it will land; back over its own spot, the swap is undone.
    /// Tiles are found where they were when the drag began, so the trade doesn't chase
    /// itself, and a margin inside each keeps a pointer on a border from flipping it.
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
        // In a gap or a margin the current trade stands; only its own spot undoes it.
        if target == nil, origin.frames[id]?.contains(pointer) != true { return }
        if let current = liveSwapTarget { world.swapWindows(id, current) }
        if let target { world.swapWindows(id, target) }
        liveSwapTarget = target
        requestLivePass()
    }

    /// Where a dragged tile lands: in the spot the live trade already gave it, or, dropped on
    /// another display, on that display's workspace.
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

    /// Live layout passes go no faster than the apps can follow: a new one starts when the
    /// last has been applied, from the layout as it is by then, so a slow app skips frames
    /// rather than falling further and further behind.
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

    /// The layout following an edge drag without the neighbours redrawing at every step.
    /// Resizing a window makes its app lay it out and draw it again, which shows: a terminal
    /// reflows its text, a web app re-renders. Moving one costs the app nothing; the window
    /// server moves the picture it already has. So a neighbour keeps its size and slides,
    /// the edge beside the dragged one following the pointer, and the part that no longer
    /// fits goes past the edge of the screen. When it has to grow, it's resized once with
    /// 200 points to spare, off screen, so it redraws about once per 200 points dragged. A
    /// window whose spare part would show (on another tile, or above the screen, where
    /// macOS won't put a window) is resized as before. The pass when the button comes up
    /// gives everyone their exact tile.
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
                // macOS clamps a resize that would reach past the screen edge, though it lets a
                // move go there: resized where the new size fits (under the window being
                // dragged, which is in front), then moved into place in the same breath.
                batches[window.pid, default: []].append(FrameOp(id: id, frame: fitted, park: false))
                batches[window.pid, default: []].append(FrameOp(id: id, frame: frame, park: true))
            } else {
                // A move alone keeps the size, as parking does.
                batches[window.pid, default: []].append(FrameOp(id: id, frame: frame, park: !resized))
            }
            liveShown[id] = frame
            // What the window was given, so its reports aren't taken for the app moving it.
            lastApplied[id] = frame
            appliedAt[id] = start
        }
        apply(batches, done: done)
    }

    /// Where a neighbour of a dragged edge goes for now, keeping its size wherever it can.
    /// After or below the dragged edge, it slides with the edge, and what no longer fits goes
    /// past the far edge of the screen. Before or above it, it stays put, its far edge where
    /// it was, and the extra tucks under the window being dragged, which is in front: its
    /// traffic lights and corners don't move at all, and a window can't go above the menu
    /// bar anyway. With the frame, where the window fits on screen at that size, to resize
    /// it there first when it grows. Nil leaves it as it is.
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
                // Untouched along this axis: its tile.
                if horizontal { size.width = target.width } else { size.height = target.height }
                continue
            }
            // Both edges moving, as inside a split that's being resized as a whole: resized.
            if lowMoved && highMoved { return (target, nil) }
            var current = horizontal ? size.width : size.height
            // Room to grow into, never more than fits on screen at once.
            if current < length - 0.5 { current = min(length + 200, horizontal ? area.width : area.height) }
            let spare = current - length
            var start: CGFloat
            if lowMoved {
                // Slides with the edge; the extra goes past the right or bottom of the screen.
                if spare > 0.5, high(target) < (horizontal ? area.maxX : area.maxY) - 1 { return (target, nil) }
                start = low(target)
            } else {
                // Stays put; the extra goes under the dragged window, all of it.
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

    // MARK: Title-bar drags

    func pointerDown(at point: CGPoint) {
        if userMove != nil || userResize != nil { endUserGesture() }
        press = point
    }

    /// The first report of a window changing while the button is down tells a drag from a
    /// resize. Frames Planets itself just requested don't count.
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
        // The button coming up normally ends the gesture through the input tap; should that
        // event go missing, the gesture still ends once the button is seen to be up.
        gestureWatch?.invalidate()
        gestureWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.pointerUp(at: Displays.toGlobal(NSEvent.mouseLocation))
            }
        }
    }

    /// Returns whether the rim should move.
    func pointerMoved(to point: CGPoint) -> Bool {
        guard userMove != nil else { return false }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            endUserGesture()
            return true
        }
        userMove?.update(pointer: point)
        if let id = userMove?.id { followMove(id, pointer: point) }
        // No pointer event for a few frames means the pointer is resting.
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
            // The app's last report may still be on its way, and the rim shouldn't step back
            // to an older frame in the meantime.
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

    // MARK: Modifier drag

    /// Holding the drag modifier and pressing anywhere in a window picks it up, as on Linux.
    func dragBegan(_ id: WindowID, at point: CGPoint) {
        // A modifier drag isn't a title-bar drag; an older click's position mustn't make it one.
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

    /// Mouse events arrive faster than an app can move its window. Only one move is in
    /// flight at a time and newer positions replace older ones, so the window tracks the
    /// pointer instead of trailing behind a queue.
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
                    // The app has moved the window by now; the rim needn't wait for its report.
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
            // Land exactly where the pointer let go, not at the last frame the app reported.
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

    // MARK: Applying the layout

    /// Sends every window whose spot changed to its app's thread. Apps run in parallel; the
    /// whole pass is timed from here until the slowest app finishes.
    func reconcile(label: String, applied: (@MainActor () -> Void)? = nil) {
        guard isEnabled else { applied?(); return }
        let start = ContinuousClock.now
        passes += 1
        let pass = passes
        let placements = world.placements()
        var shows: [pid_t: [FrameOp]] = [:]
        var parks: [FrameOp] = []
        /// Where each window leaving the screen is now, to know which arrivals cover it.
        var leavingFrom: [WindowID: CGRect] = [:]
        for (id, placement) in placements {
            guard let window = world.windows[id] else { continue }
            switch placement {
            case .frame(let rect):
                guard lastApplied[id] != rect || parked.contains(id) else { continue }
                // A window mid-drag belongs to the user until they let go.
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

        // Windows come on screen before the ones under them leave: with each app moving its
        // windows on its own thread, a window could otherwise leave a frame or two before the
        // one replacing it arrived, and the desktop flashed through. Each leaving window waits
        // only for the apps whose windows land on it, not for the slowest app of the switch,
        // so the old workspace is gone as soon as each part of it is covered. A hung app
        // holds nothing up for long: whatever is left goes after 50 ms.
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
            // A newer pass may have brought a window back meanwhile; it stays.
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

    /// Hands each app its operations, on the app's own thread. Calls `each` as each app
    /// finishes, and `done` once every app has.
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
                        // The grace period for app adjustments starts when the app is done.
                        let finished = ContinuousClock.now
                        for id in ids where self?.appliedAt[id] != nil { self?.appliedAt[id] = finished }
                        each(pid)
                        if pending.finish() { done() }
                    }
                }
            }
        }
    }

    private final class PendingBatch: @unchecked Sendable {
        private var remaining: Int
        init(count: Int) { remaining = count }
        /// Returns true for the call that completes the batch.
        @discardableResult
        func finish() -> Bool {
            remaining -= 1
            return remaining == 0
        }
    }

    // MARK: Focus

    /// Focus goes straight to the window server, which takes a fraction of a millisecond
    /// and never waits on the app. Going through the app's Accessibility thread instead
    /// would queue it behind whatever the app is busy reporting (a browser loading pages
    /// reports a lot), which is how a focus key ends up feeling slow.
    func focus(_ id: WindowID, raise: Bool = true) {
        guard let window = world.windows[id], let observer = observers[window.pid] else { return }
        focusIntent = (id, .now + .milliseconds(600))
        let keySet = planets_focus_window(window.pid, id)
        observer.finishFocus(id, raise: raise, keyAlreadySet: keySet)
    }

    /// ⌘` already focused this window from the keyboard thread; bring the model up to date.
    func noteCycled(to id: WindowID) {
        guard world.windows[id] != nil else { return }
        focusIntent = (id, .now + .milliseconds(600))
        world.noteFocus(id)
        if let window = world.windows[id] { observers[window.pid]?.finishFocus(id, raise: true, keyAlreadySet: true) }
        reconcile(label: "focus")
        notify(.focus)
    }

    /// What ⌘` steps through for the frontmost app, for the input tap to use without asking
    /// the main thread. Nil, leaving ⌘` to macOS, only when every window the app has is
    /// right here and there's at most one: then macOS's own handling can't leave the
    /// workspace, and it still reaches panels Planets doesn't manage.
    func cycleTargets() -> InputTap.Cycle? {
        guard isEnabled, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        // The app's full-screen windows on this workspace are among its windows here too.
        let fullScreen = world.focusedWorkspaceName.map { name in fullScreenWindows(on: name).filter { $0.window.pid == pid }.map(\.id) } ?? []
        let here = windowsOnFocusedWorkspace(of: pid) + fullScreen
        let elsewhere = world.windows.values.contains { $0.pid == pid && !here.contains($0.id) }
            || fullScreenWindows.contains { $0.value.pid == pid && !here.contains($0.key) }
        guard here.count > 1 || elsewhere else { return nil }
        let current = frontFullScreenWindow() ?? world.focusedWindow
        let index = current.flatMap { here.firstIndex(of: $0) } ?? 0
        return InputTap.Cycle(pid: pid, windows: here, index: index, fullScreen: Set(fullScreen))
    }

    /// Focus follows the mouse: the window under the pointer becomes key without being
    /// raised, so a floating window under it isn't buried.
    func focusFromMouse(_ id: WindowID) {
        guard world.windows[id] != nil, id != world.focusedWindow else { return }
        world.noteFocus(id)
        focus(id, raise: false)
        notify(.focus)
    }

    /// With nothing to focus on an empty workspace, Planets takes focus itself so
    /// keystrokes don't land in a window that is parked out of sight.
    private func focusNothing() {
        focusIntent = (nil, .now + .milliseconds(600))
        // Cooperative activation can be refused after a swallowed hotkey; the window server
        // call makes Planets frontmost the same way a click would.
        if !planets_activate_process(ProcessInfo.processInfo.processIdentifier) { NSApp.activate() }
    }

    private func apply(_ result: World.NavigationResult) {
        switch result {
        case .window(let id): focus(id)
        case .emptyMonitor: focusNothing()
        case .none: break
        }
    }

    /// Frame of the focused window as it is about to be, for overlays that follow it.
    /// Uses the requested frame right after a move, so overlays move with the window, and
    /// the reported one once the app has answered, so they match a frame the app adjusted.
    var focusedFrame: (id: WindowID, frame: CGRect)? {
        guard let id = world.focusedWindow, let window = world.windows[id], !parked.contains(id) else { return nil }
        if let move = userMove, move.id == id { return (id, move.frame(monitors: world.monitors)) }
        if userResize == id { return nil }
        if adjusting[id] != nil || dragging?.id == id || window.isFloating { return (id, window.frame) }
        if let reported = reportedAt[id], let applied = appliedAt[id], reported > applied { return (id, window.frame) }
        return (id, lastApplied[id] ?? window.frame)
    }

    /// Visible windows with their frames, front to back as far as Planets knows.
    var visibleFrames: [(WindowID, CGRect)] {
        world.windows.values.compactMap { window in
            guard world.isVisible(window.workspace), !parked.contains(window.id) else { return nil }
            return (window.id, lastApplied[window.id] ?? window.frame)
        }
    }

    // MARK: Commands

    struct Result {
        var output: String = ""
        var ok = true
    }

    /// The focused window, but only while its app is frontmost. After the user switches to
    /// an app Planets leaves alone, or to the desktop, a window command must not reach
    /// back and act on the last managed window they used.
    /// None while a full-screen window is in front either: the focused tile is out of sight.
    var targetWindow: WindowID? {
        guard frontFullScreenWindow() == nil, let id = world.focusedWindow, let pid = world.windows[id]?.pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return id
    }

    private static let noTarget = Result(output: "no focused window", ok: false)

    @discardableResult
    func perform(_ command: Command) -> Result {
        if !isEnabled {
            // Paused tiling keeps the keys bound, so everything that would move a window waits.
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
            // Leaving a zoomed window or full screen can move tiles, right away rather than
            // once the app confirms focus.
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
            // Handled by the app controller, which owns the config file and the menu bar.
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

    /// Windows of an app on the focused workspace, in layout order.
    func windowsOnFocusedWorkspace(of pid: pid_t) -> [WindowID] {
        (world.focusedWorkspace?.windows ?? []).filter { world.windows[$0]?.pid == pid }
    }

    /// Focuses a specific window, showing its workspace first if it's hidden.
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

    /// Closes a window by asking its app, as its close button would.
    func close(_ id: WindowID) {
        let pid = world.windows[id]?.pid ?? fullScreenWindows[id]?.pid
        if let pid { observers[pid]?.close(id) }
    }

    /// Moves a specific window to a workspace without following it.
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

    /// Floating windows stay above tiled ones, as in Hyprland: with tiles covering the whole
    /// screen, a dialog or a small utility window that slipped behind them would be lost.
    /// Raising doesn't move keyboard focus. The focused app's own windows are left alone,
    /// since raising one of them could make it the app's key window.
    func keepFloatingOnTop() {
        guard let workspace = world.focusedWorkspace, !workspace.floating.isEmpty,
              let focused = world.focusedWindow, let focusedWindow = world.windows[focused], !focusedWindow.isFloating else { return }
        let floating = workspace.floating.compactMap { world.windows[$0] }.filter { $0.pid != focusedWindow.pid && !parked.contains($0.id) }
        guard !floating.isEmpty else { return }
        // After the focused window's own raise, which runs on its app's thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for window in floating { self.observers[window.pid]?.raise(window.id) }
            }
        }
    }

    /// Gives focus back to the focused workspace's window, after a Planets window closes.
    /// After a Planets window closes, focus goes where the user is: the workspace's
    /// window, or Planets itself on an empty workspace. Left to macOS, the next app in
    /// line takes over even when its window is parked on another workspace, and the next
    /// keystroke lands in a window the user can't see.
    func refocus() {
        guard isEnabled else { return }
        focusAfterSwitch()
    }

    // MARK: Full screen

    private func noteFullScreen(_ id: WindowID) {
        trace("full screen: \(id)")
        guard let window = world.windows[id] else { return }
        fullScreenWindows[id] = FullScreenWindow(pid: window.pid, workspace: window.workspace, appName: window.appName, title: window.title)
        // It's in front as it goes full screen.
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

    /// A window can leave full screen, or close, without anything saying so: leaving it
    /// with the desktop in front changes no Space, and a window found on another Space has
    /// no Accessibility element to report its moves. So while any window is full screen,
    /// each is checked once a second, a single call to the window server; one that's back
    /// on the desktop, or gone, has its app looked at again, which tiles it or lets it go.
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

    /// The full-screen window in front right now, if the user is looking at one.
    func frontFullScreenWindow() -> WindowID? {
        guard !fullScreenWindows.isEmpty, let display = Spaces.display(), display.currentIsFullScreen else { return nil }
        return fullScreenWindows.keys.first { Spaces.space(of: $0) == display.current }
    }

    /// Full-screen windows of an app that Accessibility can't see, being on Spaces not in
    /// front, found through the window server: after a restart, they're known before the
    /// user visits them. Ones gone since are let go.
    /// Windows at every level count: some full-screen apps raise their window to the screen saver's
    /// level while it's full screen. Looking at normal windows only, the
    /// first scan after a switch away found it gone and dropped it from its workspace.
    private func noteFullScreenWindowsOnOtherSpaces(of pid: pid_t, appName: String) {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var present = Set<WindowID>()
        let displays = world.monitors.map(\.frame)
        for info in list where (info[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            present.insert(id)
            // The window itself covers its display. A full-screen window also has a title-bar
            // window of its own on the same Space, which isn't one to count or go back to.
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  displays.contains(where: { $0.isClose(to: bounds, tolerance: 2) }) else { continue }
            guard world.windows[id] == nil, fullScreenWindows[id] == nil, Spaces.isOnFullScreenSpace(id) else { continue }
            let workspace = remembered[id] ?? launchMemory[id]?.workspace ?? world.focusedWorkspaceName ?? world.workspaceOrder[0]
            remembered[id] = workspace
            fullScreenWindows[id] = FullScreenWindow(pid: pid, workspace: workspace, appName: appName, title: info[kCGWindowName as String] as? String ?? "")
            watchFullScreenWindows()
            notify(.workspaces)
        }
        // Gone, or back from full screen on the desktop, where Accessibility will find it.
        for (id, entry) in fullScreenWindows where entry.pid == pid
            && (!present.contains(id) || (ContinuousClock.now - entry.since > .seconds(3) && !Spaces.isOnFullScreenSpace(id))) {
            forgetFullScreen(id)
        }
    }

    /// The rest of a workspace switch, once the model has switched. Three cases: the new
    /// workspace was last showing a full-screen window, which comes back to the front; the
    /// switch leaves full screen for the desktop; or neither, the usual switch.
    private func switchArrived(leavingFullScreen: Bool) {
        let name = world.focusedWorkspaceName
        trace("switch to \(name ?? "-") leaving full screen \(leavingFullScreen), showing \(name.flatMap { showingFullScreen[$0] }.map(String.init) ?? "-"), full screen \(fullScreenWindows.keys.sorted())")
        if let name, let arriving = showingFullScreen[name], fullScreenWindows[arriving] != nil {
            // The desktop is laid out for the new workspace first, while it still can be:
            // once a full-screen Space is in front, moves to desktop windows are dropped. The
            // switch to the window's Space is instant, so it waits for the apps to finish,
            // for 40 ms at most: a quick app is done in under 5. Coming from another full-screen window, the desktop is out
            // of sight already, and it's put right as soon as it's back.
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
            // Out to the desktop: the swipe goes first and the layout follows at once; focus
            // goes where it belongs once the desktop is in front.
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

    /// A focus move from a full-screen window is a move among the tiles: the desktop comes
    /// forward first.
    private func leaveFullScreenForTiles() {
        guard let front = frontFullScreenWindow(), let entry = fullScreenWindows[front] else { return }
        showingFullScreen[entry.workspace] = nil
        leaveFullScreenSpace { [weak self] in
            if let id = self?.world.focusedWindow { self?.focus(id) }
        }
    }

    /// Moves a full-screen window to another workspace, from the keyboard while watching it. Following it keeps it in front; otherwise it goes
    /// out of sight with its workspace, as a moved tile does.
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

    /// Brings a full-screen window's Space to the front, as a swipe would (see Spaces).
    private func bringFullScreenForward(_ id: WindowID) {
        guard let entry = fullScreenWindows[id] else { return }
        lastUsed[entry.pid] = id
        let space = Spaces.space(of: id)
        // Focus reports from the Spaces passed on the way are no one's choice.
        focusIntent = (nil, .now + .seconds(5))
        ownSpaceChangeUntil = .now + .seconds(5)
        let steps = space.flatMap { space in
            Spaces.show(space) { [weak self] in
                guard let self else { return }
                self.ownSpaceChangeUntil = .now + .milliseconds(800)
                self.focusIntent = (nil, .now + .milliseconds(600))
                // macOS gives the Space's window focus as it arrives; asked once more, in case
                // the app had made another of its windows key meanwhile. Accessibility asks,
                // not the window server: its way is a synthetic click, which a full-screen
                // video or game takes for the user's.
                self.observers[entry.pid]?.finishFocus(id, raise: false, keyAlreadySet: false)
            }
        }
        trace("bring \(id) forward: space \(space.map(String.init) ?? "-"), \(steps.map { "\($0) step(s)" } ?? "on another display")")
        if steps != nil { return }
        // On another display, where a swipe doesn't reach: an app with no window on the
        // desktop comes forward to its Space. No swipe means no arrival to shorten the
        // five seconds above, and for that long a choice the user makes meanwhile (⌘-Tab to
        // an app on a hidden workspace) would be ignored.
        ownSpaceChangeUntil = .now + .milliseconds(1500)
        focusIntent = (nil, .now + .milliseconds(1500))
        Self.makeFrontmost(entry.pid)
        _ = planets_front_window(entry.pid, id)
        observers[entry.pid]?.finishFocus(id, raise: false, keyAlreadySet: false)
    }

    /// Brings the desktop Space to the front, as a swipe would (see Spaces): the Space of the
    /// window about to get focus, or of any window Planets manages, all of which live
    /// on the desktop, parked or not.
    /// `arrived` gives focus once the desktop is in front: macOS hands focus to whichever
    /// window was last used there, which may be on another workspace, and that report is
    /// ignored until then.
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
        // On another display, where a swipe doesn't reach. macOS changes Space when an app comes to the front with no
        // window on the Space in front, so the app about to get focus comes forward through
        // Accessibility; that fails only for the full-screen window's own app.
        let fullScreenApps = Set(fullScreenWindows.values.map(\.pid))
        let preferred = (workspace?.focused ?? workspace?.tiled.first ?? workspace?.floating.first).flatMap { world.windows[$0]?.pid }
        guard let pid = preferred.flatMap({ fullScreenApps.contains($0) ? nil : $0 }) ?? world.windows.values.first(where: { !fullScreenApps.contains($0.pid) })?.pid else {
            // Nothing to bring forward, so no Space change to wait for.
            ownSpaceChangeUntil = nil
            focusIntent = nil
            arrived()
            return
        }
        ownSpaceChangeUntil = .now + .milliseconds(1500)
        focusIntent = (workspace?.focused, .now + .milliseconds(1500))
        Self.makeFrontmost(pid)
        // Focus waits for the Space change: taking it sooner can stop the Space from changing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { arrived() }
    }

    /// ⌘` to or from a full-screen window crosses Spaces, which the keyboard thread can't do.
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

    /// Accessibility asks the app to come forward. A hung app holds this up for at most a
    /// quarter of a second.
    private static func makeFrontmost(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// A Space change the user made (a swipe, ⌃→, ⌘-Tab, the Dock) brings the strip along:
    /// into a full-screen window, its workspace becomes the current one; back on the
    /// desktop, the current workspace shows its tiles again.
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
        // ⌘` steps from wherever the user is now.
        notify(.focus)
    }

    /// The windows of the workspace being switched to are raised while still parked, so each
    /// arrives on top of the windows leaving. Raised once in place, a window arrived under them
    /// for a frame, and the switch showed half the old workspace and half the new. Tiles don't
    /// overlap, so their order among themselves doesn't matter; focusAfterSwitch then raises
    /// the focused window and floating ones. A zoomed window is left to it alone: it covers
    /// the rest.
    private func raiseArriving() {
        guard let workspace = world.focusedWorkspace, workspace.zoomed == nil else { return }
        // The focused window's own app is left out: raising another of its windows can make
        // that one the key window, and keystrokes would go there.
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
        // Apps launched from Finder get a bare PATH; add the usual places tools live.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        do { try process.run() } catch { log.error("exec failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Change notification

    func notify(_ change: Change) {
        guard !change.isEmpty else { return }
        if change.contains(.focus) { noteWindowUsed() }
        // Frames too: a resized split or column changes the arrangement. Moves and drags
        // leave the saved state as it was, and an unchanged state isn't written.
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

    // MARK: Persistence

    private struct SavedState: Codable {
        var boot: Int
        var focused: String?
        var windows: [String: SavedWindow]
        /// The full-screen window each workspace was showing, so a switch there after a
        /// restart (an update, say) still goes back to the video rather than the tiles.
        var showingFullScreen: [String: WindowID]?
        var arrangements: [String: Workspace.Arrangement]?
    }

    private struct SavedWindow: Codable {
        var workspace: String
        var floating: Bool
        /// Not on screen when saved: minimised, hidden with its app or on another macOS
        /// Space. Such a window keeps its workspace whenever it returns, not only while
        /// Planets starts.
        var away: Bool?
        /// The tile an away window comes back to. Without it, a window minimised over a
        /// restart came back to its workspace but as a new tile, beside the focused one.
        var slot: TileSlot?
    }

    private static var stateURL: URL { IPC.supportDirectory.appendingPathComponent("state.json") }

    /// Window IDs restart from scratch after a reboot, so saved state from an earlier boot
    /// would put new windows on old workspaces. The boot time tells the two apart.
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

    /// Off once Accessibility is gone: every window then looks closed, and saving that would
    /// lose where each one belongs.
    var savesState = true

    func persist() {
        guard savesState else { return }
        var windows: [String: SavedWindow] = [:]
        // Minimised, hidden and off-Space windows aren't in the world right now but should
        // still come back to their workspace after a restart.
        for (id, workspace) in remembered {
            windows[String(id)] = SavedWindow(workspace: workspace, floating: rememberedFloating.contains(id), away: true, slot: rememberedSlot[id])
        }
        // Still starting up: windows not found yet keep their places for the next start.
        if launchMemoryActive {
            for (id, saved) in launchMemory { windows[String(id)] = saved }
        }
        for window in world.windows.values {
            windows[String(window.id)] = SavedWindow(workspace: window.workspace, floating: floatsByChoice(window.id))
        }
        // Full-screen windows are remembered as away, on their workspace.
        for (id, entry) in fullScreenWindows where windows[String(id)] == nil {
            windows[String(id)] = SavedWindow(workspace: entry.workspace, floating: false, away: true)
        }
        var arrangements = world.workspaces.filter { $0.value.tree != nil }.mapValues(\.arrangement)
        // A workspace whose windows haven't all come back yet keeps the arrangement it had.
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
        // A locked screen, or a full-screen Space in front, hides the desktop's windows; saved
        // places wait for them, however long that takes.
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
        // Counted only once the window is found full screen again; until then switchArrived ignores it.
        showingFullScreen = state.showingFullScreen ?? [:]
        launchArrangements = state.arrangements ?? [:]
        if let focused = state.focused { world.switchWorkspace(.named(focused)) }
    }

    /// Windows that are on screen in the current macOS Space. Parked windows count: they
    /// keep one pixel on screen.
    static func onScreenWindowIDs() -> Set<WindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    // MARK: Queries

    func appName(for pid: pid_t) -> String? { observers[pid]?.appName }
    var observedAppCount: Int { observers.count }
    func isParked(_ id: WindowID) -> Bool { parked.contains(id) }
}

/// The last few hundred layout passes, timed from decision to the last app finishing.
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
