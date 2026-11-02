import CoreGraphics

/// Hyprland's dwindle layout: a binary tree where every new window splits the focused one.
///
/// A split with no explicit axis picks one when frames are computed, along the longer side
/// of its box. That keeps windows close to square when the screen or the tree changes
/// shape, which is what makes dwindle feel automatic.
public indirect enum DwindleNode: Equatable, Sendable, Codable {
    case leaf(WindowID)
    case split(axis: Axis?, ratio: Double, first: DwindleNode, second: DwindleNode)

    public init(windows: [WindowID]) {
        // Rebuilding from an ordered list reproduces what inserting the windows one by one,
        // each splitting the previous, would have produced.
        precondition(!windows.isEmpty)
        var node = DwindleNode.leaf(windows[0])
        var last = windows[0]
        for id in windows.dropFirst() {
            node = node.inserting(id, splitting: last)
            last = id
        }
        self = node
    }

    public var leaves: [WindowID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, let first, let second): first.leaves + second.leaves
        }
    }

    public func contains(_ id: WindowID) -> Bool {
        switch self {
        case .leaf(let leaf): leaf == id
        case .split(_, _, let first, let second): first.contains(id) || second.contains(id)
        }
    }

    /// Replaces the `target` leaf with a split holding the target and the new window.
    /// The new window takes the second slot, right or below, as in Hyprland's default.
    /// Without a target the new window splits the right-most, bottom-most leaf.
    public func inserting(_ id: WindowID, splitting target: WindowID?, axis: Axis? = nil) -> DwindleNode {
        let target = target.flatMap { contains($0) ? $0 : nil } ?? leaves.last!
        switch self {
        case .leaf(let leaf):
            guard leaf == target else { return self }
            return .split(axis: axis, ratio: 0.5, first: .leaf(leaf), second: .leaf(id))
        case .split(let splitAxis, let ratio, let first, let second):
            if first.contains(target) {
                return .split(axis: splitAxis, ratio: ratio, first: first.inserting(id, splitting: target, axis: axis), second: second)
            }
            return .split(axis: splitAxis, ratio: ratio, first: first, second: second.inserting(id, splitting: target, axis: axis))
        }
    }

    /// Removes a window; its sibling takes the parent's place. Returns nil when the tree empties.
    public func removing(_ id: WindowID) -> DwindleNode? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard contains(id) else { return self }
            let newFirst = first.removing(id)
            let newSecond = second.removing(id)
            switch (newFirst, newSecond) {
            case (nil, let rest?), (let rest?, nil): return rest
            case (let a?, let b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
            case (nil, nil): return nil
            }
        }
    }

    /// The tree with only these windows, every split between them as it was. Nil when none
    /// of them is in it.
    public func keeping(_ ids: Set<WindowID>) -> DwindleNode? {
        switch self {
        case .leaf(let id):
            return ids.contains(id) ? self : nil
        case .split(let axis, let ratio, let first, let second):
            switch (first.keeping(ids), second.keeping(ids)) {
            case (let a?, let b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
            case (let rest?, nil), (nil, let rest?): return rest
            case (nil, nil): return nil
            }
        }
    }

    public func swapping(_ a: WindowID, _ b: WindowID) -> DwindleNode {
        switch self {
        case .leaf(let id):
            if id == a { return .leaf(b) }
            if id == b { return .leaf(a) }
            return self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.swapping(a, b), second: second.swapping(a, b))
        }
    }

    public func replacing(_ old: WindowID, with new: WindowID) -> DwindleNode {
        switch self {
        case .leaf(let id):
            return id == old ? .leaf(new) : self
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.replacing(old, with: new), second: second.replacing(old, with: new))
        }
    }

    public static func resolvedAxis(_ axis: Axis?, for rect: CGRect) -> Axis {
        axis ?? (rect.width >= rect.height ? .horizontal : .vertical)
    }

    /// `minimums` are the smallest sizes some windows accept. Splits move just enough to give
    /// those windows their size, without changing the ratios stored in the tree, so the
    /// layout springs back once the window is gone.
    public func frames(in rect: CGRect, gap: CGFloat, minimums: [WindowID: CGSize] = [:]) -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]
        collectFrames(in: rect, gap: gap, minimums: minimums, into: &result)
        return result
    }

    private func collectFrames(in rect: CGRect, gap: CGFloat, minimums: [WindowID: CGSize], into result: inout [WindowID: CGRect]) {
        switch self {
        case .leaf(let id):
            result[id] = rect
        case .split(let axis, let ratio, let first, let second):
            var resolved = Self.resolvedAxis(axis, for: rect)
            var adjusted = ratio
            if !minimums.isEmpty {
                func room(_ along: Axis) -> (ratio: Double, fits: Bool) {
                    let (a, b) = rect.split(along, ratio: ratio, gap: gap)
                    let length = Double((along == .horizontal ? rect.width : rect.height) - gap)
                    return Self.ratio(ratio, length: length,
                                      first: Double(first.minimum(along: along, in: a, gap: gap, minimums: minimums)),
                                      second: Double(second.minimum(along: along, in: b, gap: gap, minimums: minimums)))
                }
                var choice = room(resolved)
                // An automatic split turns the other way when only that way leaves room for both.
                if axis == nil, !choice.fits, case let other = room(resolved.flipped), other.fits {
                    resolved = resolved.flipped
                    choice = other
                }
                adjusted = choice.ratio
            }
            let (a, b) = rect.split(resolved, ratio: adjusted, gap: gap)
            first.collectFrames(in: a, gap: gap, minimums: minimums, into: &result)
            second.collectFrames(in: b, gap: gap, minimums: minimums, into: &result)
        }
    }

    /// The ratio closest to `ratio` that gives each side its minimum length. When both
    /// can't fit, the length is shared in proportion to what each side needs.
    static func ratio(_ ratio: Double, length: Double, first: Double, second: Double) -> (ratio: Double, fits: Bool) {
        guard length > 0, first > 0 || second > 0 else { return (ratio, true) }
        let low = first / length, high = 1 - second / length
        if low <= high { return (min(max(ratio, low), high), true) }
        return (first / (first + second), false)
    }

    /// The smallest length this part of the tree can take along an axis, given its windows'
    /// minimum sizes. `rect` is where it would sit, which decides automatic split axes.
    func minimum(along axis: Axis, in rect: CGRect, gap: CGFloat, minimums: [WindowID: CGSize]) -> CGFloat {
        switch self {
        case .leaf(let id):
            guard let size = minimums[id] else { return 0 }
            return axis == .horizontal ? size.width : size.height
        case .split(let splitAxis, let ratio, let first, let second):
            let resolved = Self.resolvedAxis(splitAxis, for: rect)
            let (a, b) = rect.split(resolved, ratio: ratio, gap: gap)
            let one = first.minimum(along: axis, in: a, gap: gap, minimums: minimums)
            let two = second.minimum(along: axis, in: b, gap: gap, minimums: minimums)
            guard resolved == axis else { return max(one, two) }
            return one > 0 || two > 0 ? one + gap + two : 0
        }
    }

    /// Grows (positive delta) or shrinks the window along `axis` by moving a split line on
    /// that axis. With an `edge`, only the line on that side of the window moves, which is
    /// what dragging that edge with the mouse means; without one, the nearest line moves.
    /// Delta is in points; `rect` is the area the tree fills, needed to turn points into a ratio.
    public func resizing(_ id: WindowID, along axis: Axis, by delta: CGFloat, edge: Direction? = nil, in rect: CGRect, gap: CGFloat) -> DwindleNode {
        resized(id, axis: axis, delta: delta, edge: edge, rect: rect, gap: gap).node
    }

    private func resized(_ id: WindowID, axis: Axis, delta: CGFloat, edge: Direction?, rect: CGRect, gap: CGFloat) -> (node: DwindleNode, done: Bool) {
        guard case .split(let splitAxis, let ratio, let first, let second) = self, contains(id) else {
            return (self, false)
        }
        let resolved = Self.resolvedAxis(splitAxis, for: rect)
        let (a, b) = rect.split(resolved, ratio: ratio, gap: gap)
        let inFirst = first.contains(id)
        // The deepest matching split is the line right next to the window, so recurse first.
        let child = inFirst
            ? first.resized(id, axis: axis, delta: delta, edge: edge, rect: a, gap: gap)
            : second.resized(id, axis: axis, delta: delta, edge: edge, rect: b, gap: gap)
        if child.done {
            return (inFirst
                ? .split(axis: splitAxis, ratio: ratio, first: child.node, second: second)
                : .split(axis: splitAxis, ratio: ratio, first: first, second: child.node), true)
        }
        guard resolved == axis else { return (self, false) }
        // A window in the first child has this line on its right or bottom edge.
        if let edge, edge.isForward != inFirst { return (self, false) }
        let length = (axis == .horizontal ? rect.width : rect.height) - gap
        guard length > 0 else { return (self, false) }
        let change = Double(delta / length) * (inFirst ? 1 : -1)
        let newRatio = (ratio + change).clamped(to: 0.1...0.9)
        return (.split(axis: splitAxis, ratio: newRatio, first: first, second: second), true)
    }

    /// Flips the split that directly holds the window, keeping the rest of the tree.
    public func togglingSplit(containing id: WindowID, in rect: CGRect, gap: CGFloat) -> DwindleNode {
        switch self {
        case .leaf:
            return self
        case .split(let axis, let ratio, let first, let second):
            let resolved = Self.resolvedAxis(axis, for: rect)
            if first == .leaf(id) || second == .leaf(id) {
                return .split(axis: resolved.flipped, ratio: ratio, first: first, second: second)
            }
            let (a, b) = rect.split(resolved, ratio: ratio, gap: gap)
            if first.contains(id) {
                return .split(axis: axis, ratio: ratio, first: first.togglingSplit(containing: id, in: a, gap: gap), second: second)
            }
            if second.contains(id) {
                return .split(axis: axis, ratio: ratio, first: first, second: second.togglingSplit(containing: id, in: b, gap: gap))
            }
            return self
        }
    }

    /// Resets every split to an even ratio.
    public var balanced: DwindleNode {
        switch self {
        case .leaf: self
        case .split(let axis, _, let first, let second): .split(axis: axis, ratio: 0.5, first: first.balanced, second: second.balanced)
        }
    }

    /// Where a leaf sits: the part of the tree beside it, the split between them, and
    /// which side the leaf is on. Nil for a lone leaf.
    func slot(of id: WindowID) -> (sibling: [WindowID], axis: Axis?, ratio: Double, first: Bool)? {
        guard case .split(let axis, let ratio, let first, let second) = self else { return nil }
        if first == .leaf(id) { return (second.leaves, axis, ratio, true) }
        if second == .leaf(id) { return (first.leaves, axis, ratio, false) }
        return first.slot(of: id) ?? second.slot(of: id)
    }

    /// Puts a leaf back beside the part of the tree it sat next to, with the same split. Nil
    /// when that part no longer exists in the same shape.
    func restoring(_ id: WindowID, beside sibling: [WindowID], axis: Axis?, ratio: Double, first: Bool) -> DwindleNode? {
        if Set(leaves) == Set(sibling) {
            return first
                ? .split(axis: axis, ratio: ratio, first: .leaf(id), second: self)
                : .split(axis: axis, ratio: ratio, first: self, second: .leaf(id))
        }
        guard case .split(let splitAxis, let splitRatio, let one, let two) = self else { return nil }
        if let restored = one.restoring(id, beside: sibling, axis: axis, ratio: ratio, first: first) {
            return .split(axis: splitAxis, ratio: splitRatio, first: restored, second: two)
        }
        if let restored = two.restoring(id, beside: sibling, axis: axis, ratio: ratio, first: first) {
            return .split(axis: splitAxis, ratio: splitRatio, first: one, second: restored)
        }
        return nil
    }
}
