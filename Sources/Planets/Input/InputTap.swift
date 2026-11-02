import AppKit
import CoreGraphics
import os
import PlanetsCore
import PlanetsPrivate

/// One event tap for every keyboard shortcut and for modifier-dragging windows.
///
/// The tap sees each key press before any app does, so its callback must be fast: it runs
/// on its own thread and only does a dictionary lookup, then hands the command to the
/// main thread. If the callback ever stalls, macOS disables the tap and typing lags, so
/// nothing here waits on the window manager.
final class InputTap: @unchecked Sendable {
    enum Event: Sendable {
        case command(Command)
        case dragBegan(WindowID, CGPoint)
        case dragMoved(WindowID, CGPoint)
        case dragEnded(WindowID, CGPoint)
        /// ⌘` focused this window straight from the keyboard thread.
        case cycledTo(WindowID)
        /// ⌘` steps to this window across Spaces, to or from a full-screen window.
        case cycleAcrossSpaces(WindowID)
        /// A plain click, which may turn into the user dragging a window by its title bar.
        case pointerDown(CGPoint)
        /// The pointer while the user drags a window, so the rim can keep pace with it.
        case pointerMoved(CGPoint)
        case pointerUp(CGPoint)
    }

    /// The windows of the frontmost app on the focused workspace, in the order ⌘` visits
    /// them, and which one has focus. The keyboard thread steps through these itself, so
    /// presses in quick succession each move on without waiting for the main thread.
    /// An empty or one-window list still claims ⌘`: the app has windows on other
    /// workspaces, and macOS would cycle to one of those and drag the user there.
    struct Cycle: Sendable, Equatable {
        var pid: pid_t
        var windows: [WindowID]
        var index: Int
        /// The ones in full screen, each on a Space of its own: a step to or from one of
        /// them crosses Spaces, which is for the main thread.
        var fullScreen: Set<WindowID> = []
    }

    struct Snapshot: Sendable {
        var bindings: [UInt32: Command] = [:]
        /// The key that types ` in the current layout, for ⌘`.
        var graveCode: CGKeyCode = 50
        /// The frontmost app's windows that ⌘` and ⌘⇧` step through, worked out ahead of
        /// time. Nil means macOS handles ⌘` as usual.
        var cycle: Cycle?
        var dragModifiers: CGEventFlags = []
        /// Visible windows, floating ones first, for hit-testing drags off the main thread.
        var windows: [(WindowID, CGRect)] = []
        var enabled = true
        /// Set while the user drags a window by its title bar: pointer moves are passed on.
        var followPointer = false
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let thread = RunLoopThread(name: "planets.input")
    private var tap: CFMachPort?
    private let deliver: @Sendable (Event) -> Void
    /// Drag in progress; touched only on the tap thread.
    private var drag: (id: WindowID, start: CGPoint)?
    /// When ⌘` last moved; read under the state lock.
    private nonisolated(unsafe) var lastCycle: ContinuousClock.Instant?

    static let relevantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    init(deliver: @escaping @Sendable (Event) -> Void) {
        self.deliver = deliver
    }

    static func key(code: CGKeyCode, flags: CGEventFlags) -> UInt32 {
        UInt32(code) << 8 | UInt32(truncatingIfNeeded: flags.intersection(relevantFlags).rawValue >> 16)
    }

    static func flags(for modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    @MainActor
    func update(bindings: [KeyBinding], dragModifiers: Modifiers) {
        let codes = KeyCodes.currentMap()
        var table: [UInt32: Command] = [:]
        for binding in bindings {
            guard let code = codes[binding.chord.key] else { continue }
            table[Self.key(code: code, flags: Self.flags(for: binding.chord.modifiers))] = binding.command
        }
        let dragFlags = Self.flags(for: dragModifiers)
        let finished = table
        let grave = codes["grave"] ?? 50
        state.withLock {
            $0.bindings = finished
            $0.graveCode = grave
            $0.dragModifiers = dragFlags
        }
    }

    func update(cycle: Cycle?) {
        let now = ContinuousClock.now
        state.withLock {
            // The main thread may answer an earlier press after a later one already moved on;
            // a fresh press keeps its own place in the same list.
            if var current = $0.cycle, let next = cycle, current.pid == next.pid, current.windows == next.windows,
               let at = lastCycle, now - at < .milliseconds(500) {
                current.index = min(current.index, next.windows.count - 1)
                $0.cycle = current
            } else {
                $0.cycle = cycle
            }
        }
    }

    /// Moves the ⌘` list to the window just focused, unless the main thread replaced the list
    /// meanwhile.
    private func advanceCycle(pid: pid_t, to index: Int, at target: WindowID) {
        state.withLock {
            guard var cycle = $0.cycle, cycle.pid == pid, cycle.windows.indices.contains(index), cycle.windows[index] == target else { return }
            cycle.index = index
            $0.cycle = cycle
            lastCycle = .now
        }
    }

    /// Turns the tap off and on. Off, keys and clicks go straight to apps without passing
    /// through Planets at all, as they must once it has lost Accessibility.
    func setTapRunning(_ running: Bool) {
        guard let tap else { return }
        let handoff = Unchecked(tap)
        thread.perform { CGEvent.tapEnable(tap: handoff.value, enable: running) }
    }

    func update(windows: [(WindowID, CGRect)]) {
        state.withLock { $0.windows = windows }
    }

    func setFollowPointer(_ follow: Bool) {
        state.withLock { $0.followPointer = follow }
    }

    func setEnabled(_ enabled: Bool) {
        state.withLock { $0.enabled = enabled }
    }

    /// Starts the tap. Fails when Planets lacks the Accessibility permission.
    func start() -> Bool {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let handoff = Unchecked((tap, CFMachPortCreateRunLoopSource(nil, tap, 0)))
        thread.perform {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), handoff.value.1, .commonModes)
            CGEvent.tapEnable(tap: handoff.value.0, enable: true)
        }
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            // Planets's own presses, such as moving between Spaces, aren't the user's.
            if event.getIntegerValueField(.eventSourceUserData) == Spaces.syntheticMarker { return Unmanaged.passUnretained(event) }
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.intersection(Self.relevantFlags)
            // ⌘` cycles an app's windows. macOS would include windows parked on hidden
            // workspaces and drag you there; with Spaces it stays on the current one, so here
            // it does too.
            // The focus happens right here, on the keyboard thread: no hop to the main thread
            // and no wait on the app, so it's as quick as macOS's own ⌘`.
            if code == state.withLock({ $0.graveCode }), flags == .maskCommand || flags == [.maskCommand, .maskShift] {
                let backward = flags.contains(.maskShift)
                // Right after ⌘-Tab the list may still belong to the app that was in front. The
                // window server knows which app is in front now; if it isn't the list's, macOS
                // handles this press and the list catches up.
                let front = planets_front_process()
                let step: (pid: pid_t, target: WindowID?, index: Int, crossing: Bool)? = state.withLock {
                    guard $0.enabled, let cycle = $0.cycle, front < 0 || front == cycle.pid else { return nil }
                    guard cycle.windows.count > 1 else { return (cycle.pid, nil, cycle.index, false) }
                    let from = cycle.windows[cycle.index]
                    let index = (cycle.index + (backward ? -1 : 1) + cycle.windows.count) % cycle.windows.count
                    let to = cycle.windows[index]
                    return (cycle.pid, to, index, cycle.fullScreen.contains(from) || cycle.fullScreen.contains(to))
                }
                if let step {
                    // Nothing to cycle to here: swallow the key rather than let macOS leave
                    // the workspace.
                    guard let target = step.target else { return nil }
                    // The list moves on only once the window has focus: after a failed focus
                    // macOS handles the press, and the next one starts from where it was.
                    if step.crossing || planets_focus_window(step.pid, target) {
                        advanceCycle(pid: step.pid, to: step.index, at: target)
                        deliver(step.crossing ? .cycleAcrossSpaces(target) : .cycledTo(target))
                        return nil
                    }
                    return Unmanaged.passUnretained(event)
                }
            }
            let key = Self.key(code: code, flags: event.flags)
            let command: Command? = state.withLock { $0.enabled ? $0.bindings[key] : nil }
            guard let command else { return Unmanaged.passUnretained(event) }
            deliver(.command(command))
            return nil
        case .leftMouseDown:
            // A mouse-up lost to another tap must not leave a drag hanging.
            if let stale = drag {
                drag = nil
                deliver(.dragEnded(stale.id, event.location))
            }
            let snapshot = state.withLock { ($0.enabled, $0.dragModifiers, $0.windows) }
            guard snapshot.0 else { return Unmanaged.passUnretained(event) }
            guard !snapshot.1.isEmpty, event.flags.intersection(Self.relevantFlags) == snapshot.1 else {
                deliver(.pointerDown(event.location))
                return Unmanaged.passUnretained(event)
            }
            let point = event.location
            guard let hit = snapshot.2.first(where: { $0.1.contains(point) }) else { return Unmanaged.passUnretained(event) }
            drag = (hit.0, point)
            deliver(.dragBegan(hit.0, point))
            return nil
        case .leftMouseDragged:
            guard let drag else {
                if state.withLock({ $0.followPointer }) { deliver(.pointerMoved(event.location)) }
                return Unmanaged.passUnretained(event)
            }
            deliver(.dragMoved(drag.id, event.location))
            return nil
        case .leftMouseUp:
            guard let drag else {
                if state.withLock({ $0.followPointer }) { deliver(.pointerUp(event.location)) }
                return Unmanaged.passUnretained(event)
            }
            self.drag = nil
            deliver(.dragEnded(drag.id, event.location))
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
