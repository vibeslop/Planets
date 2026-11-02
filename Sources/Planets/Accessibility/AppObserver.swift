import AppKit
import ApplicationServices
import PlanetsCore
import PlanetsPrivate
import Synchronization

enum AppEvent: Sendable {
    /// The full window list, after setup or a rescan.
    case discovered([WindowSnapshot])
    case created(WindowSnapshot)
    case destroyed(WindowID)
    case focused(WindowID?)
    case frameChanged(WindowID, CGRect)
    case titleChanged(WindowID, String)
    case minimized(WindowID)
    /// Gone full screen, onto a Space of its own. Coming back arrives as `restored`.
    case fullScreen(WindowID)
    case restored(WindowSnapshot)
    case hidden
    case shown
    /// The app never answered Accessibility requests; it is left unmanaged.
    case unavailable
}

struct FrameOp: Sendable {
    var id: WindowID
    var frame: CGRect
    /// Parking only moves the window; its size is kept for when it comes back.
    var park: Bool
}

/// Watches one app through the Accessibility API on that app's own thread.
///
/// Everything mutable here is touched only on `thread`. The main thread talks to it by
/// queueing blocks and hears back through `send`, so no AX call ever blocks the UI.
final class AppObserver: @unchecked Sendable {
    let pid: pid_t
    let bundleID: String?
    let appName: String

    private let thread: RunLoopThread
    private let app: AXUIElement
    private let send: @Sendable (AppEvent) -> Void
    private var observer: AXObserver?
    private var windows: [WindowID: AXUIElement] = [:]
    private var ids: [AXUIElement: WindowID] = [:]
    /// Last frame we know each window has, so unchanged parts of a frame are never re-sent.
    private var known: [WindowID: CGRect] = [:]
    private var fullScreen: Set<WindowID> = []
    /// The focused window as last reported, so a main-window change can tell if it's news.
    private var reportedFocus: WindowID?
    /// Whether the app has enhanced UI on, as last read, and when. See `apply`.
    private var enhanced = false
    private var enhancedReadAt: ContinuousClock.Instant?
    private var stopped = false

    init(app: NSRunningApplication, send: @escaping @Sendable (AppEvent) -> Void) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        appName = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        self.send = send
        self.app = AXUIElementCreateApplication(pid)
        thread = RunLoopThread(name: "planets.ax.\(appName)")
        // The default timeout is six seconds. A second is plenty for a healthy app and
        // bounds how long a hung one can hold a batch.
        AXUIElementSetMessagingTimeout(self.app, 1.0)
    }

    func start() {
        thread.perform { [self] in setUp(attempt: 0) }
    }

    func stop() {
        thread.perform { [self] in
            stopped = true
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            windows = [:]
            ids = [:]
        }
        thread.stop()
    }

    // MARK: Setup

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]

    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func setUp(attempt: Int) {
        guard !stopped else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let created else {
            retry(after: attempt)
            return
        }
        var ready = true
        for name in Self.appNotifications {
            let error = AXObserverAddNotification(created, app, name as CFString, refcon)
            // Freshly launched apps answer "cannot complete" until their AX server is up.
            if error == .cannotComplete || error == .notImplemented { ready = false; break }
        }
        guard ready else {
            for name in Self.appNotifications { AXObserverRemoveNotification(created, app, name as CFString) }
            retry(after: attempt)
            return
        }
        // Outside the readiness check: an app that can't post it is still worth managing.
        AXObserverAddNotification(created, app, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        scan()
    }

    private func retry(after attempt: Int) {
        let delays: [Double] = [0.1, 0.25, 0.5, 1, 2, 4]
        guard attempt < delays.count else {
            send(.unavailable)
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delays[attempt]) { [self] in
            thread.perform { [self] in setUp(attempt: attempt + 1) }
        }
    }

    // MARK: Windows

    func rescan() {
        thread.perform { [self] in
            guard observer != nil else { return }
            scan()
        }
    }

    private func scan() {
        let start = ContinuousClock.now
        defer { trace("ax \(appName): scan took \(Self.milliseconds(since: start))") }
        var snapshots: [WindowSnapshot] = []
        var seen = Set<WindowID>()
        // No answer means no information; the next scan will try again.
        guard let elements = app.elementsIfAvailable(kAXWindowsAttribute) else { return }
        for element in elements {
            guard let id = element.windowID else { continue }
            seen.insert(id)
            if windows[id] == nil { track(element, id: id) }
            snapshots.append(snapshot(element, id: id))
        }
        for id in windows.keys where !seen.contains(id) { untrack(id) }
        send(.discovered(snapshots))
        // So the first batch already knows (see apply).
        readEnhancedUI()
    }

    private func track(_ element: AXUIElement, id: WindowID) {
        windows[id] = element
        ids[element] = id
        // The timeout set on the app element covers only that element; windows need their own.
        AXUIElementSetMessagingTimeout(element, 1.0)
        if let observer {
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, element, name as CFString, refcon)
            }
        }
    }

    private func untrack(_ id: WindowID) {
        guard let element = windows.removeValue(forKey: id) else { return }
        ids[element] = nil
        known[id] = nil
        if let observer {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer, element, name as CFString)
            }
        }
    }

    private func snapshot(_ element: AXUIElement, id: WindowID) -> WindowSnapshot {
        let (kind, subrole, isFullScreen, isMinimized) = WindowClassifier.classify(element)
        let frame = element.frame ?? .zero
        known[id] = frame
        if isFullScreen { fullScreen.insert(id) } else { fullScreen.remove(id) }
        return WindowSnapshot(id: id, title: element.string(kAXTitleAttribute) ?? "", frame: frame, kind: kind, subrole: subrole, isFullScreen: isFullScreen, isMinimized: isMinimized)
    }

    fileprivate func handle(_ element: AXUIElement, _ notification: String) {
        guard !stopped else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            guard let id = element.windowID else { return }
            if windows[id] == nil { track(element, id: id) }
            send(.created(snapshot(element, id: id)))
        case kAXUIElementDestroyedNotification:
            // The element is already dead, so it can't be asked for its ID; look it up instead.
            guard let id = ids[element] else { return }
            untrack(id)
            send(.destroyed(id))
        case kAXFocusedWindowChangedNotification:
            reportFocus(element.windowID ?? app.element(kAXFocusedWindowAttribute)?.windowID)
        case kAXMainWindowChangedNotification:
            // Switching native tabs from the keyboard (⌘1 in a terminal) brings another tab's
            // window forward but posts only this. Any other focus change was reported just
            // before it, so only a window not reported yet is news.
            guard element.windowID != reportedFocus else { return }
            let id = app.element(kAXFocusedWindowAttribute)?.windowID
            if id != reportedFocus { reportFocus(id) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let id = ids[element] ?? element.windowID, windows[id] != nil, let frame = element.frame else { return }
            known[id] = frame
            // Going full screen and coming back have no notifications of their own, but both
            // resize the window, so only a resize asks; a drag moves without the extra call.
            if notification == kAXWindowResizedNotification || fullScreen.contains(id) {
                let isFullScreen = element.bool("AXFullScreen") == true
                if isFullScreen != fullScreen.contains(id) {
                    if isFullScreen {
                        fullScreen.insert(id)
                        send(.fullScreen(id))
                    } else {
                        fullScreen.remove(id)
                        send(.restored(snapshot(element, id: id)))
                    }
                    return
                }
                // A full-screen window's frame says nothing about its tile.
                if isFullScreen { return }
            }
            send(.frameChanged(id, frame))
        case kAXTitleChangedNotification:
            guard let id = ids[element] else { return }
            send(.titleChanged(id, element.string(kAXTitleAttribute) ?? ""))
        case kAXWindowMiniaturizedNotification:
            guard let id = ids[element] else { return }
            send(.minimized(id))
        case kAXWindowDeminiaturizedNotification:
            guard let id = ids[element] else { return }
            send(.restored(snapshot(element, id: id)))
        case kAXApplicationHiddenNotification:
            send(.hidden)
        case kAXApplicationShownNotification:
            send(.shown)
        default:
            break
        }
    }

    // MARK: Actions

    /// Moves a batch of this app's windows. Reports how long the app took, which is the
    /// number that matters for how fast a workspace switch feels.
    ///
    /// Batches wait in a mailbox rather than a queue: a frame for a window replaces any that
    /// window still has waiting, so an app busy with one change goes straight to the latest
    /// next. Queued one after another, a held ⌥= had a slow app work through every
    /// out-of-date frame in turn, and its window kept resizing for half a second after the
    /// key came up. Every batch's `done` still runs, once what it asked for, or something
    /// newer, is in place.
    func apply(_ ops: [FrameOp], done: @escaping @Sendable (Duration) -> Void) {
        let ids = Set(ops.map(\.id))
        let schedule = mailbox.withLock { box in
            box.ops.removeAll { ids.contains($0.id) }
            box.ops += ops
            box.waiting.append(done)
            defer { box.scheduled = true }
            return !box.scheduled
        }
        if schedule { thread.perform { [self] in drain() } }
    }

    private struct Mailbox {
        var ops: [FrameOp] = []
        var waiting: [@Sendable (Duration) -> Void] = []
        var scheduled = false
    }
    private let mailbox = Mutex(Mailbox())

    private func drain() {
        let (ops, waiting) = mailbox.withLock { box in
            defer { box = Mailbox() }
            return (box.ops, box.waiting)
        }
        let start = ContinuousClock.now
        // With enhanced UI on (some apps turn it on for assistive tools), every frame
        // change animates and a batch takes seconds, so it's off for the batch. Whether
        // it's on is read after a batch rather than before: the read is a round trip to
        // the app, as long as a move itself, and most switches move one window per app.
        // An app that turned it on since then animates one batch, and is read again.
        if enhanced { app.set("AXEnhancedUserInterface", false) }
        for op in ops {
            guard let element = windows[op.id] else { continue }
            let current = known[op.id]
            if op.park {
                // Always sent: a cached position can be wrong when an app moved its window
                // without telling anyone, and a skipped park leaves a window in plain view.
                if element.setPosition(op.frame.origin) != .success { element.setPosition(op.frame.origin) }
                known[op.id] = CGRect(origin: op.frame.origin, size: current?.size ?? op.frame.size)
                continue
            }
            // A resize makes the app lay the window out and draw it again, the costly part
            // of any layout change, so each window is resized once. macOS clamps a resize
            // that would reach past the screen edge from where the window is now: a window
            // that grows moves first and then grows where its new size fits; one that only
            // shrinks does so first, where it already fits, and then moves. Sending the
            // size twice, before and after the move, had every app lay out twice per pass.
            // Position is always sent, for the same reason parking is.
            let resize = current?.size != op.frame.size
            let grows = current.map { op.frame.width > $0.width + 0.5 || op.frame.height > $0.height + 0.5 } ?? true
            if resize, !grows { element.setSize(op.frame.size) }
            element.setPosition(op.frame.origin)
            if resize, grows { element.setSize(op.frame.size) }
            known[op.id] = op.frame
        }
        if enhanced { app.set("AXEnhancedUserInterface", true) }
        trace("ax \(appName): \(ops.count) op(s) for \(waiting.count) batch(es) took \(Self.milliseconds(since: start))")
        let duration = ContinuousClock.now - start
        for done in waiting { done(duration) }
        readEnhancedUI()
    }

    /// At most every two seconds: a burst of batches, such as a mouse resize, reads it once.
    private func readEnhancedUI() {
        if let at = enhancedReadAt, ContinuousClock.now - at < .seconds(2) { return }
        enhancedReadAt = .now
        enhanced = app.bool("AXEnhancedUserInterface") == true
    }

    /// The Accessibility half of focusing: raising the window. Making it key already
    /// happened through the window server, so this can wait its turn on the app's thread.
    /// When the window server call wasn't available, Accessibility does the whole job.
    func finishFocus(_ id: WindowID, raise: Bool, keyAlreadySet: Bool) {
        thread.perform { [self] in
            guard let element = windows[id] else { return }
            let start = ContinuousClock.now
            defer { trace("ax \(appName): focusing \(id) took \(Self.milliseconds(since: start))") }
            if !keyAlreadySet {
                element.set(kAXMainAttribute, true)
                let pid = self.pid
                DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
            }
            if raise { element.perform(kAXRaiseAction) }
        }
    }

    /// Brings a minimised window back from the Dock, as clicking it there does.
    func unminimize(_ id: WindowID) {
        thread.perform { [self] in windows[id]?.set(kAXMinimizedAttribute, false) }
    }

    func raise(_ id: WindowID) {
        thread.perform { [self] in windows[id]?.perform(kAXRaiseAction) }
    }

    func close(_ id: WindowID) {
        thread.perform { [self] in
            windows[id]?.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
        }
    }

    /// Sends a fresh snapshot of one window as `.created`, for a window that became
    /// interesting later: a native tab coming to the front, for one.
    func reportWindow(_ id: WindowID) {
        thread.perform { [self] in
            guard let element = windows[id] else { return }
            let start = ContinuousClock.now
            let snapshot = snapshot(element, id: id)
            trace("ax \(appName): looking at \(id) took \(Self.milliseconds(since: start))")
            send(.created(snapshot))
        }
    }

    func reportFocusedWindow() {
        thread.perform { [self] in
            let start = ContinuousClock.now
            let id = app.element(kAXFocusedWindowAttribute)?.windowID
            trace("ax \(appName): asking for focus took \(Self.milliseconds(since: start))")
            reportFocus(id)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> String {
        (ContinuousClock.now - start).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))
    }

    private func reportFocus(_ id: WindowID?) {
        reportedFocus = id
        send(.focused(id))
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue().handle(element, notification as String)
}
