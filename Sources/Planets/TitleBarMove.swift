import AppKit
import PlanetsCore
import PlanetsPrivate

@MainActor
struct TitleBarMove {
    let id: WindowID
    let grab: CGPoint
    let start: CGRect
    private(set) var pointer: CGPoint
    private var sample: (frame: CGRect, at: ContinuousClock.Instant)?
    private var velocity = CGVector.zero
    private let lead: Double

    init(id: WindowID, grab: CGPoint, start: CGRect, pointer: CGPoint) {
        self.id = id
        self.grab = grab
        self.start = start
        self.pointer = pointer
        let screen = NSScreen.screens.first { Displays.toGlobal($0.frame).contains(start.center) } ?? NSScreen.main
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
                velocity = CGVector(dx: velocity.dx * 0.4 + dx * 0.6, dy: velocity.dy * 0.4 + dy * 0.6)
            }
        }
        sample = (bounds, now)
    }

    mutating func settle() {
        velocity = .zero
        if let bounds = Self.serverFrame(id) { sample = (bounds, .now) }
    }

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
