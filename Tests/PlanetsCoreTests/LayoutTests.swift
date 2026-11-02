import CoreGraphics
import Testing
@testable import PlanetsCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

@Suite struct DwindleTests {
    @Test func firstSplitIsSideBySideOnWideArea() {
        let tree = DwindleNode(windows: [1, 2])
        let frames = tree.frames(in: screen, gap: 0)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(frames[2] == CGRect(x: 500, y: 0, width: 500, height: 600))
    }

    @Test func thirdWindowSplitsTheSecondVertically() {
        let tree = DwindleNode(windows: [1, 2, 3])
        let frames = tree.frames(in: screen, gap: 10)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 495, height: 600))
        #expect(frames[2] == CGRect(x: 505, y: 0, width: 495, height: 295))
        #expect(frames[3] == CGRect(x: 505, y: 305, width: 495, height: 295))
    }

    @Test func insertingSplitsTheTarget() {
        let tree = DwindleNode(windows: [1, 2, 3]).inserting(4, splitting: 1)
        #expect(tree.leaves == [1, 4, 2, 3])
        let frames = tree.frames(in: screen, gap: 0)
        // Window 1's half is now shared with 4, stacked because the half is taller than wide.
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(frames[4] == CGRect(x: 0, y: 300, width: 500, height: 300))
    }

    @Test func removingPromotesSibling() {
        let tree = DwindleNode(windows: [1, 2, 3]).removing(2)
        #expect(tree?.leaves == [1, 3])
        #expect(tree?.frames(in: screen, gap: 0)[3] == CGRect(x: 500, y: 0, width: 500, height: 600))
        #expect(DwindleNode.leaf(1).removing(1) == nil)
    }

    @Test func resizeMovesTheAdjacentLine() {
        let tree = DwindleNode(windows: [1, 2]).resizing(1, along: .horizontal, by: 100, in: screen, gap: 0)
        let frames = tree.frames(in: screen, gap: 0)
        #expect(frames[1]?.width == 600)
        #expect(frames[2]?.width == 400)
        // The second window grows by pulling the same line left.
        let back = tree.resizing(2, along: .horizontal, by: 100, in: screen, gap: 0)
        #expect(back.frames(in: screen, gap: 0)[2]?.width == 500)
    }

    @Test func resizeByEdgePicksTheLineOnThatSide() {
        // 1 | (2 / 3): window 2's left edge is the root line; its bottom edge is the inner line.
        let tree = DwindleNode(windows: [1, 2, 3])
        let wider = tree.resizing(2, along: .horizontal, by: 100, edge: .left, in: screen, gap: 0)
        #expect(wider.frames(in: screen, gap: 0)[2]?.minX == 400)
        // No line on the right of window 2, so asking for that edge changes nothing.
        #expect(tree.resizing(2, along: .horizontal, by: 100, edge: .right, in: screen, gap: 0) == tree)
    }

    @Test func toggleSplitFlipsOnlyTheParent() {
        let tree = DwindleNode(windows: [1, 2, 3]).togglingSplit(containing: 3, in: screen, gap: 0)
        let frames = tree.frames(in: screen, gap: 0)
        #expect(frames[2] == CGRect(x: 500, y: 0, width: 250, height: 600))
        #expect(frames[3] == CGRect(x: 750, y: 0, width: 250, height: 600))
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
    }
}

@Suite struct WorkspaceLayoutTests {
    var settings: LayoutSettings {
        var s = LayoutSettings()
        s.innerGap = 0
        s.outerGap = 0
        return s
    }

    func workspace(_ ids: [WindowID]) -> Workspace {
        var ws = Workspace(name: "1")
        for id in ids { ws.addTiled(id); ws.noteFocus(id) }
        return ws
    }

    @Test func tiledOrderMatchesTreeAfterInserts() {
        var ws = Workspace(name: "1")
        ws.addTiled(1); ws.noteFocus(1)
        ws.addTiled(2); ws.noteFocus(2)
        ws.addTiled(3); ws.noteFocus(1)
        ws.addTiled(4)
        #expect(ws.tiled == ws.tree?.leaves)
        #expect(ws.tiled == [1, 4, 2, 3])
    }

    @Test func zoomCoversTheLayout() {
        var ws = workspace([1, 2])
        ws.zoomed = 2
        let placed = ws.placements(in: screen, settings: settings)
        #expect(placed[2] == .frame(screen))
        #expect(placed[1] == .frame(CGRect(x: 0, y: 0, width: 500, height: 600)))
    }

    @Test func gapsAndSmartGaps() {
        var s = LayoutSettings()
        s.innerGap = 10
        s.outerGap = 20
        let one = workspace([1])
        #expect(one.placements(in: screen, settings: s)[1] == .frame(CGRect(x: 20, y: 20, width: 960, height: 560)))
        s.smartGaps = true
        #expect(one.placements(in: screen, settings: s)[1] == .frame(screen))
    }
}

@Suite struct NeighborTests {
    @Test func picksAlignedNearestCandidate() {
        let origin = CGRect(x: 0, y: 0, width: 500, height: 600)
        let candidates: [(WindowID, CGRect)] = [
            (2, CGRect(x: 500, y: 0, width: 500, height: 300)),
            (3, CGRect(x: 500, y: 300, width: 500, height: 300)),
            (4, CGRect(x: 1200, y: 0, width: 500, height: 600)),
        ]
        #expect(neighbor(of: origin, in: .right, among: candidates) == 2)
        #expect(neighbor(of: origin, in: .left, among: candidates) == nil)
        #expect(neighbor(of: candidates[0].1, in: .down, among: candidates) == 3)
        #expect(neighbor(of: candidates[2].1, in: .left, among: candidates) == 2)
    }
}
