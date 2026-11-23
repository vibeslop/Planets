import CoreGraphics

public struct LayoutSettings: Equatable, Sendable {
    public var innerGap: CGFloat = 10
    public var outerGap: CGFloat = 10
    public var smartGaps: Bool = false

    public init() {}
}

public enum Placement: Equatable, Sendable {
    case frame(CGRect)
    case hidden
}

public struct Workspace: Equatable, Sendable {
    public let name: String
    public internal(set) var tiled: [WindowID] = []
    public internal(set) var tree: DwindleNode?
    public internal(set) var floating: [WindowID] = []
    public internal(set) var recent: [WindowID] = []
    public var zoomed: WindowID?
    public var lastMonitor: MonitorID?

    public init(name: String) {
        self.name = name
    }

    public var windows: [WindowID] { tiled + floating }
    public var isEmpty: Bool { tiled.isEmpty && floating.isEmpty }
    public var focused: WindowID? { recent.first }

    public func contains(_ id: WindowID) -> Bool { tiled.contains(id) || floating.contains(id) }

    public mutating func addTiled(_ id: WindowID, after anchor: WindowID? = nil) {
        guard !contains(id) else { return }
        let anchor = anchor.flatMap { tiled.contains($0) ? $0 : nil } ?? focused.flatMap { tiled.contains($0) ? $0 : nil }
        let previousLast = tiled.last
        if let anchor, let index = tiled.firstIndex(of: anchor) {
            tiled.insert(id, at: index + 1)
        } else {
            tiled.append(id)
        }
        if let tree {
            self.tree = tree.inserting(id, splitting: anchor ?? previousLast)
        } else {
            tree = DwindleNode(windows: tiled)
        }
        syncTreeOrder()
    }

    public mutating func addFloating(_ id: WindowID) {
        guard !contains(id) else { return }
        floating.append(id)
    }

    mutating func addTiled(_ id: WindowID, into slot: TileSlot) {
        guard !contains(id) else { return }
        if let tree, !slot.sibling.isEmpty {
            if let restored = tree.restoring(id, beside: slot.sibling, axis: slot.axis, ratio: slot.ratio, first: slot.first) {
                self.tree = restored
            } else if let neighbour = slot.sibling.first(where: { tiled.contains($0) }),
                      let restored = tree.restoring(id, beside: [neighbour], axis: slot.axis, ratio: slot.ratio, first: slot.first) {
                self.tree = restored
            } else {
                addTiled(id)
                return
            }
            tiled.append(id)
            syncTreeOrder()
        } else {
            addTiled(id)
        }
    }

    public struct Arrangement: Codable, Equatable, Sendable {
        public var tree: DwindleNode?

        public init(tree: DwindleNode?) { self.tree = tree }

        public func slot(of id: WindowID, among present: [WindowID], workspace name: String) -> TileSlot? {
            guard let tree, tree.contains(id) else { return nil }
            let place = tree.keeping(Set(present).union([id]))?.slot(of: id)
            return TileSlot(workspace: name, sibling: place?.sibling ?? [], axis: place?.axis, ratio: place?.ratio ?? 0.5, first: place?.first ?? false)
        }

        public func slot(of id: WindowID, among present: [WindowID], workspace name: String, renumbered numbers: [WindowID: WindowID]) -> TileSlot? {
            let old = Dictionary(numbers.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            guard var slot = slot(of: id, among: present.map { old[$0] ?? $0 }, workspace: name) else { return nil }
            slot.sibling = slot.sibling.map { numbers[$0] ?? $0 }
            return slot
        }
    }

    public var arrangement: Arrangement {
        Arrangement(tree: tree)
    }

    func slot(of id: WindowID, workspace name: String) -> TileSlot? {
        guard tiled.contains(id) else { return nil }
        let place = (tree ?? DwindleNode(windows: tiled)).slot(of: id)
        return TileSlot(workspace: name, sibling: place?.sibling ?? [], axis: place?.axis, ratio: place?.ratio ?? 0.5, first: place?.first ?? false)
    }

    mutating func move(_ id: WindowID, toFloating floats: Bool, after anchor: WindowID? = nil) {
        guard contains(id) else { return }
        let history = recent
        remove(id)
        if floats { addFloating(id) } else { addTiled(id, after: anchor) }
        recent = history
    }

    public mutating func remove(_ id: WindowID) {
        if let index = tiled.firstIndex(of: id) {
            tiled.remove(at: index)
            tree = tree?.removing(id)
        }
        floating.removeAll { $0 == id }
        recent.removeAll { $0 == id }
        if zoomed == id { zoomed = nil }
    }

    public mutating func noteFocus(_ id: WindowID) {
        guard contains(id) else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
    }

    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard contains(old), !contains(new) else { return }
        tiled = tiled.map { $0 == old ? new : $0 }
        floating = floating.map { $0 == old ? new : $0 }
        recent = recent.map { $0 == old ? new : $0 }
        tree = tree?.replacing(old, with: new)
        if zoomed == old { zoomed = new }
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let i = tiled.firstIndex(of: a), let j = tiled.firstIndex(of: b) else { return }
        tiled.swapAt(i, j)
        tree = tree?.swapping(a, b)
    }

    public mutating func balance() {
        tree = tree?.balanced
    }

    mutating func syncTreeOrder() {
        if let tree { tiled = tree.leaves }
    }
}

extension Workspace {
    public func placements(in area: CGRect, settings: LayoutSettings, minimums: [WindowID: CGSize] = [:]) -> [WindowID: Placement] {
        var result: [WindowID: Placement] = [:]
        let single = tiled.count == 1 && settings.smartGaps
        let outer = single ? 0 : settings.outerGap
        let usable = area.inset(by: Insets(all: outer)).integralized
        if let zoomed, tiled.contains(zoomed) {
            result[zoomed] = .frame(usable)
        }
        let node = tree ?? (tiled.isEmpty ? nil : DwindleNode(windows: tiled))
        for (id, rect) in node?.frames(in: usable, gap: settings.innerGap, minimums: minimums) ?? [:] where result[id] == nil {
            result[id] = .frame(rect.integralized)
        }
        return result
    }
}

public struct TileSlot: Equatable, Sendable, Codable {
    public var workspace: String
    var sibling: [WindowID]
    var axis: Axis?
    var ratio: Double
    var first: Bool
    var joined: Int?

    private enum CodingKeys: String, CodingKey {
        case workspace, sibling, axis, ratio, first
    }
}
