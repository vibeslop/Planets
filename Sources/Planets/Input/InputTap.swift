import AppKit
import CoreGraphics
import os
import PlanetsCore
import PlanetsPrivate

// SAFETY: Snapshot and lastCycle are guarded by state lock; drag is confined to the tap thread.
final class InputTap: @unchecked Sendable {
    enum Event: Sendable {
        case command(Command)
        case dragBegan(WindowID, CGPoint)
        case dragMoved(WindowID, CGPoint)
        case dragEnded(WindowID, CGPoint)
        case cycledTo(WindowID)
        case cycleAcrossSpaces(WindowID)
        case pointerDown(CGPoint)
        case pointerMoved(CGPoint)
        case pointerUp(CGPoint)
    }

    struct Cycle: Sendable, Equatable {
        var pid: pid_t
        var windows: [WindowID]
        var index: Int
        var fullScreen: Set<WindowID> = []
    }

    struct Snapshot: Sendable {
        var bindings: [UInt32: Command] = [:]
        var graveCode: CGKeyCode = 50
        var cycle: Cycle?
        var dragModifiers: CGEventFlags = []
        var windows: [(WindowID, CGRect)] = []
        var enabled = true
        var followPointer = false
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    private let thread = RunLoopThread(name: "planets.input")
    private var tap: CFMachPort?
    private let deliver: @Sendable (Event) -> Void
    private var drag: (id: WindowID, start: CGPoint)?
    // SAFETY: Accessed only under state.withLock.
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
            if var current = $0.cycle, let next = cycle, current.pid == next.pid, current.windows == next.windows,
               let at = lastCycle, now - at < .milliseconds(500) {
                current.index = min(current.index, next.windows.count - 1)
                $0.cycle = current
            } else {
                $0.cycle = cycle
            }
        }
    }

    private func advanceCycle(pid: pid_t, to index: Int, at target: WindowID) {
        state.withLock {
            guard var cycle = $0.cycle, cycle.pid == pid, cycle.windows.indices.contains(index), cycle.windows[index] == target else { return }
            cycle.index = index
            $0.cycle = cycle
            lastCycle = .now
        }
    }

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
            if event.getIntegerValueField(.eventSourceUserData) == Spaces.syntheticMarker { return Unmanaged.passUnretained(event) }
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.intersection(Self.relevantFlags)
            if code == state.withLock({ $0.graveCode }), flags == .maskCommand || flags == [.maskCommand, .maskShift] {
                let backward = flags.contains(.maskShift)
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
                    guard let target = step.target else { return nil }
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

// SAFETY: InputTap outlives its event tap for the lifetime of the process.
private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
