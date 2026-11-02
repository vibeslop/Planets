import CoreGraphics

/// A window's CGWindowID. Stable for the window's lifetime, shared by the
/// Accessibility API and the window server, so it is the one key every layer agrees on.
public typealias WindowID = UInt32

/// A display's CGDirectDisplayID.
public typealias MonitorID = UInt32

public enum Direction: String, CaseIterable, Sendable, Codable {
    case left, right, up, down

    public var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    /// True when moving in this direction increases the coordinate (right, down).
    public var isForward: Bool { self == .right || self == .down }
}

/// `horizontal` places children side by side; `vertical` stacks them.
public enum Axis: String, Sendable, Codable {
    case horizontal, vertical

    public var flipped: Axis { self == .horizontal ? .vertical : .horizontal }
}

public struct Insets: Equatable, Sendable, Codable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(all value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }

    public static let zero = Insets(all: 0)
}

// All geometry in PlanetsCore uses the global top-left coordinate space shared by the
// Accessibility API and CGWindowList: the primary display's top-left corner is (0, 0)
// and y grows downward. AppKit's bottom-left space is converted at the app boundary.
extension CGRect {
    public func inset(by insets: Insets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: max(0, width - insets.left - insets.right),
            height: max(0, height - insets.top - insets.bottom)
        )
    }

    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Splits the rect along `axis`, giving `ratio` of the space (minus the gap) to the first part.
    public func split(_ axis: Axis, ratio: Double, gap: CGFloat) -> (CGRect, CGRect) {
        let ratio = CGFloat(ratio.clamped(to: 0.05...0.95))
        switch axis {
        case .horizontal:
            let usable = max(0, width - gap)
            let first = (usable * ratio).rounded()
            return (
                CGRect(x: minX, y: minY, width: first, height: height),
                CGRect(x: minX + first + gap, y: minY, width: usable - first, height: height)
            )
        case .vertical:
            let usable = max(0, height - gap)
            let first = (usable * ratio).rounded()
            return (
                CGRect(x: minX, y: minY, width: width, height: first),
                CGRect(x: minX, y: minY + first + gap, width: width, height: usable - first)
            )
        }
    }

    /// Rounds to whole points. Apps report frames in whole points, so comparing
    /// unrounded layout output with what the app reports would never match.
    public var integralized: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }

    public func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var area: CGFloat { isNull ? 0 : width * height }
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Picks the rect that sits next to `origin` in `direction`, the way a person would
/// point: candidates must lie beyond the origin's edge. Rects that share a span with the
/// origin on the cross axis beat ones that don't; then the nearest wins; then the one
/// sharing the most span; then the top-most or left-most, so ties are deterministic.
public func neighbor<ID>(
    of origin: CGRect,
    in direction: Direction,
    among candidates: [(ID, CGRect)]
) -> ID? {
    typealias Score = (aligned: Bool, distance: CGFloat, overlap: CGFloat, order: CGFloat)
    func better(_ a: Score, than b: Score) -> Bool {
        if a.aligned != b.aligned { return a.aligned }
        if abs(a.distance - b.distance) > 1 { return a.distance < b.distance }
        if abs(a.overlap - b.overlap) > 1 { return a.overlap > b.overlap }
        return a.order < b.order
    }
    var best: (id: ID, score: Score)?
    for (id, rect) in candidates {
        let distance: CGFloat
        let overlap: CGFloat
        let order: CGFloat
        switch direction {
        case .left:
            guard rect.midX < origin.midX, rect.minX < origin.minX - 1 else { continue }
            distance = max(0, origin.minX - rect.maxX)
            overlap = min(origin.maxY, rect.maxY) - max(origin.minY, rect.minY)
            order = rect.minY
        case .right:
            guard rect.midX > origin.midX, rect.maxX > origin.maxX + 1 else { continue }
            distance = max(0, rect.minX - origin.maxX)
            overlap = min(origin.maxY, rect.maxY) - max(origin.minY, rect.minY)
            order = rect.minY
        case .up:
            guard rect.midY < origin.midY, rect.minY < origin.minY - 1 else { continue }
            distance = max(0, origin.minY - rect.maxY)
            overlap = min(origin.maxX, rect.maxX) - max(origin.minX, rect.minX)
            order = rect.minX
        case .down:
            guard rect.midY > origin.midY, rect.maxY > origin.maxY + 1 else { continue }
            distance = max(0, rect.minY - origin.maxY)
            overlap = min(origin.maxX, rect.maxX) - max(origin.minX, rect.minX)
            order = rect.minX
        }
        let score: Score = (overlap > 0, distance, overlap, order)
        if let current = best, !better(score, than: current.score) { continue }
        best = (id, score)
    }
    return best?.id
}

extension CGSize {
    public func isClose(to other: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
