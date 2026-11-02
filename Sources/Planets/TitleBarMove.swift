import AppKit
import PlanetsCore
import PlanetsPrivate

/// A window the user is dragging by its title bar, tracked for the rim to follow.
///
/// macOS moves the window itself and tells the app afterwards, so Accessibility reports
/// trail the window by several frames. The window server knows where the window is now,
/// but whatever the rim does with that reaches the screen up to a frame later, by which
/// time the window has moved on. So the position is carried forward by the window's
/// measured velocity. When the pointer rests, `settle()` drops the velocity and the rim
/// lands on the exact position.
@MainActor
struct TitleBarMove {
    let id: WindowID
    /// Where the pointer grabbed the window, and the window's frame at that moment.
    let grab: CGPoint
    let start: CGRect
    private(set) var pointer: CGPoint
    private var sample: (frame: CGRect, at: ContinuousClock.Instant)?
    private var velocity = CGVector.zero
    /// How far ahead the rim has to aim, in seconds.
    private let lead: Double

    init(id: WindowID, grab: CGPoint, start: CGRect, pointer: CGPoint) {
        self.id = id
        self.grab = grab
        self.start = start
        self.pointer = pointer
        let screen = NSScreen.screens.first { Displays.toGlobal($0.frame).contains(start.center) } ?? NSScreen.main
        // Measured on a 60 Hz display: no lead left the rim up to 3 pt behind a window dragged
        // at 270 pt/s, a full frame put it 2–4 pt ahead, and half a frame was within 1 pt at
        // 270 pt/s but about 3 pt ahead at 480. A little under half splits the difference.
        lead = 0.4 / Double(max(30, screen?.maximumFramesPerSecond ?? 60))
        sample = Self.serverFrame(id).map { ($0, .now) }
    }

    mutating func update(pointer: CGPoint) {
        self.pointer = pointer
        let now = ContinuousClock.now
        guard let bounds = Self.serverFrame(id) else {
            sample = nil
            return
        }
        if let last = sample {
            let elapsed = now - last.at
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if seconds > 0.001 {
                let dx = (bounds.minX - last.frame.minX) / seconds, dy = (bounds.minY - last.frame.minY) / seconds
                // Light smoothing: events arrive unevenly, and one late event shouldn't fling the rim.
                velocity = CGVector(dx: velocity.dx * 0.4 + dx * 0.6, dy: velocity.dy * 0.4 + dy * 0.6)
            }
        }
        sample = (bounds, now)
    }

    /// The pointer has rested: aim at where the window is, not where it was heading.
    mutating func settle() {
        velocity = .zero
        if let bounds = Self.serverFrame(id) { sample = (bounds, .now) }
    }

    /// Where the rim should be. Without the window server it's where the window started plus
    /// how far the pointer went, kept below the menu bar as the window itself is.
    func frame(monitors: [Monitor]) -> CGRect {
        if let sample {
            let reach: CGFloat = 48
            let dx = max(-reach, min(reach, velocity.dx * lead)), dy = max(-reach, min(reach, velocity.dy * lead))
            return sample.frame.offsetBy(dx: dx, dy: dy)
        }
        var origin = CGPoint(x: start.minX + pointer.x - grab.x, y: start.minY + pointer.y - grab.y)
        if let monitor = monitors.first(where: { $0.frame.contains(pointer) }) {
            origin.y = max(origin.y, monitor.visibleFrame.minY)
        }
        return CGRect(origin: origin, size: start.size)
    }

    private static func serverFrame(_ id: WindowID) -> CGRect? {
        var bounds = CGRect.zero
        return planets_window_bounds(CGWindowID(id), &bounds) ? bounds : nil
    }
}
