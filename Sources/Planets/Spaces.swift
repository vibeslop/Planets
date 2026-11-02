import AppKit
import PlanetsCore
import PlanetsPrivate

/// macOS Spaces, as far as Planets has to deal with them: Planets's own workspaces
/// all live on one desktop Space per display, and a full-screen window has a Space of its
/// own beside it. Moving between those is macOS's job.
///
/// Nothing addressed to an app reliably brings one of its full-screen windows forward:
/// macOS changes Space when an app comes to the front only if the Space in front has none
/// of that app's windows, so a browser with one video full screen and another window on
/// the desktop stays on the desktop. Raising the window, making it main, or focusing it
/// through the window server don't change Space either. What does is what a swipe does, so
/// Planets swipes: a synthetic trackpad swipe, flung so hard that the Dock lands on the
/// Space without its slide (see planets_swipe_spaces). Mission Control's "Move left/right a
/// space" shortcuts are the fallback, if a swipe ever goes unheeded.
enum Spaces {
    /// The Spaces of one display, in Mission Control's order.
    struct Display {
        var ids: [UInt64]
        var fullScreen: [Bool]
        var current: UInt64

        var currentIndex: Int? { ids.firstIndex(of: current) }
        var currentIsFullScreen: Bool { currentIndex.map { fullScreen[$0] } ?? false }
    }

    /// Marks the key presses Planets makes itself, so its own key handling lets them by.
    static let syntheticMarker: Int64 = 0x7465_7272_61

    /// The display with `space`, or with 0, the display whose Space is in front.
    static func display(of space: UInt64 = 0) -> Display? {
        var ids = [UInt64](repeating: 0, count: 64)
        var fullScreen = [Bool](repeating: false, count: 64)
        var current: UInt64 = 0
        let count = Int(planets_display_spaces(space, &ids, &fullScreen, 64, &current))
        guard count > 0 else { return nil }
        return Display(ids: Array(ids.prefix(count)), fullScreen: Array(fullScreen.prefix(count)), current: current)
    }

    static func space(of window: WindowID) -> UInt64? {
        let space = planets_window_space(window)
        return space == 0 ? nil : space
    }

    /// Whether a window is on a full-screen Space, wherever that Space is.
    static func isOnFullScreenSpace(_ window: WindowID) -> Bool {
        guard let space = space(of: window), let display = display(of: space), let index = display.ids.firstIndex(of: space) else { return false }
        return display.fullScreen[index]
    }

    /// Whether the Space in front of the active display is a full-screen one.
    static var fullScreenInFront: Bool {
        display()?.currentIsFullScreen ?? false
    }

    /// Brings `space` to the front of its display, at once, and returns how many Spaces that
    /// moves across: 0 when it's in front already, nil when it can't (the Space is on a
    /// display other than the active one, which a swipe doesn't act on).
    /// `arrived` runs once the Space is in front (at once if it already is), not if the
    /// trip is given up.
    @MainActor @discardableResult
    static func show(_ space: UInt64, arrived: (@MainActor () -> Void)? = nil) -> Int? {
        guard let display = display(of: space), let active = self.display(), active.ids == display.ids,
              let from = display.currentIndex, let to = display.ids.firstIndex(of: space) else { return nil }
        if from == to {
            navigator.cancel()
            arrived?()
            return 0
        }
        navigator.go(to: space, from: from, to: to, current: display.current, arrived: arrived)
        return abs(to - from)
    }

    /// Whether a trip between Spaces is under way.
    @MainActor static var isMoving: Bool { navigator.isMoving }

    @MainActor private static let navigator = Navigator()

    /// Swipes across the Spaces in between at once, then watches for the target to come to
    /// the front, every 10 ms: with no slide, the arrival is the whole wait, and focus and
    /// layout wait on hearing about it. The watching asks only which Space is in front;
    /// copying the whole layout of Spaces each time took about 10 ms in the VM, as long as the
    /// interval, and kept the window server busy while it was changing Space. A swipe left unheeded for 250 ms falls back to the
    /// shortcut, pressed once per Space, 70 ms apart, as someone flicking through Spaces
    /// would: macOS follows that pace and lands exactly. Settled anywhere but the target (a
    /// lost press, or a Space opened meanwhile), it presses the difference again.
    @MainActor private final class Navigator {
        private var target: UInt64?
        private var arrived: (@MainActor () -> Void)?
        private var deadline: ContinuousClock.Instant = .now
        private var swipedAt: ContinuousClock.Instant = .now
        private var usingKeys = false
        private var pressesDone: ContinuousClock.Instant = .now
        private var lastCurrent: UInt64?
        private var lastChange: ContinuousClock.Instant = .now
        private var generation = 0
        private var timer: Timer?

        var isMoving: Bool { target != nil }

        func go(to space: UInt64, from: Int, to: Int, current: UInt64, arrived: (@MainActor () -> Void)?) {
            target = space
            self.arrived = arrived
            deadline = .now + .seconds(5)
            usingKeys = false
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            trace("spaces: from \(current) (\(from)) to \(space) (\(to)), \(abs(to - from)) swipe(s)")
            swipedAt = .now
            lastCurrent = current
            lastChange = .now
            if !planets_swipe_spaces(to > from, Int32(abs(to - from))) { usingKeys = true; press() }
        }

        func cancel() {
            if target != nil { trace("spaces: stopped") }
            target = nil
            arrived = nil
            generation += 1
            timer?.invalidate()
            timer = nil
        }

        private func press() {
            guard let target, let display = Spaces.display(of: target), let from = display.currentIndex,
                  let to = display.ids.firstIndex(of: target), from != to, let key = Shortcut(rightward: to > from) else { return }
            generation += 1
            let current = generation
            let count = abs(to - from)
            trace("spaces: from \(display.current) (\(from)) to \(target) (\(to)), \(count) press(es)")
            for index in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(index)) { [weak self] in
                    MainActor.assumeIsolated {
                        guard self?.generation == current else { return }
                        trace("spaces: press \(index + 1)")
                        key.press()
                    }
                }
            }
            pressesDone = .now + .milliseconds(70 * count)
            lastCurrent = display.current
            lastChange = .now
        }

        private func check() {
            guard let target, ContinuousClock.now < deadline else { return cancel() }
            var current = planets_active_space()
            if current == 0 { current = Spaces.display(of: target)?.current ?? 0 }
            if current == target {
                trace("spaces: arrived \((ContinuousClock.now - swipedAt).formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))) after the swipe")
                let done = arrived
                cancel()
                done?()
                return
            }
            let now = ContinuousClock.now
            if current != lastCurrent {
                trace("spaces: now on \(current)")
                lastCurrent = current
                lastChange = now
                return
            }
            if !usingKeys {
                if now - swipedAt > .milliseconds(250), now - lastChange > .milliseconds(150) {
                    trace("spaces: the swipe went unheeded; using the shortcut")
                    usingKeys = true
                    press()
                }
                return
            }
            // Settled short of the target, with every press long out: press the difference,
            // unless the target is gone meanwhile.
            guard Spaces.display(of: target) != nil else { return cancel() }
            if now - pressesDone > .milliseconds(900), now - lastChange > .milliseconds(600) { press() }
        }
    }

    /// Mission Control's "Move left a space" and "Move right a space", as set in Keyboard
    /// Shortcuts: ⌃← and ⌃→ unless changed. Nil when turned off. Only the fallback now.
    struct Shortcut {
        var key: CGKeyCode
        var flags: CGEventFlags

        init?(rightward: Bool) {
            let id = rightward ? "81" : "79"
            let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
            let entry = all?[id] as? [String: Any]
            // Turned off in Keyboard Shortcuts.
            if let enabled = entry?["enabled"] as? NSNumber, !enabled.boolValue { return nil }
            // Changed to other keys: those. Never changed, or only switched on and off, which
            // stores no keys: the arrow keys with ⌃.
            if let parameters = (entry?["value"] as? [String: Any])?["parameters"] as? [NSNumber], parameters.count == 3 {
                key = CGKeyCode(parameters[1].intValue)
                flags = CGEventFlags(rawValue: parameters[2].uint64Value)
            } else {
                key = rightward ? 124 : 123
                flags = .maskControl
            }
            // Arrow keys carry the function and keypad flags, which the shortcut is matched against.
            if key == 123 || key == 124 { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        }

        /// Down, then up a moment later, as a finger does: a press with no time between the
        /// two goes unseen when several follow each other.
        @MainActor func press() {
            post(down: true)
            let up = self
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { up.post(down: false) }
        }

        private func post(down: Bool) {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Spaces.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
