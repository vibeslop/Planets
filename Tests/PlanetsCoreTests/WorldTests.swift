import CoreGraphics
import Foundation
import Testing
@testable import PlanetsCore

private let left = Monitor(id: 1, name: "Left", frame: CGRect(x: 0, y: 0, width: 1000, height: 600), visibleFrame: CGRect(x: 0, y: 30, width: 1000, height: 570), isMain: true)
private let right = Monitor(id: 2, name: "Right", frame: CGRect(x: 1000, y: 0, width: 800, height: 600), visibleFrame: CGRect(x: 1000, y: 0, width: 800, height: 600), isMain: false)

private func candidate(_ id: WindowID, floating: Bool = false) -> WindowCandidate {
    WindowCandidate(id: id, pid: 100 + Int32(id), bundleID: "test.app\(id)", appName: "App \(id)", title: "Window \(id)", frame: CGRect(x: 100, y: 100, width: 400, height: 300), prefersFloating: floating)
}

private func world(monitors: [Monitor] = [left]) -> World {
    var settings = LayoutSettings()
    settings.innerGap = 0
    settings.outerGap = 0
    var world = World(workspaceNames: ["1", "2", "3"], settings: settings)
    world.setMonitors(monitors)
    return world
}

private func placed(_ w: World) -> [WindowID: Placement] {
    var copy = w
    return copy.placements()
}

@Suite struct WorldTests {
    @Test func monitorsGetDistinctWorkspaces() {
        let w = world(monitors: [right, left])
        #expect(w.visible[1] == "1")
        #expect(w.visible[2] == "2")
        #expect(w.focusedMonitor == 1)
    }

    @Test func swapWindowsTradesTiles() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        w.addWindow(candidate(3, floating: true))
        w.addWindow(candidate(4), workspace: "2")
        w.swapWindows(1, 2)
        #expect(placed(w)[2] == .frame(CGRect(x: 0, y: 30, width: 500, height: 570)))
        #expect(placed(w)[1] == .frame(CGRect(x: 500, y: 30, width: 500, height: 570)))
        // A floating window, or one on another workspace, has no tile to trade.
        let before = w.workspaces["1"]!.tiled
        w.swapWindows(1, 3)
        w.swapWindows(1, 4)
        #expect(w.workspaces["1"]!.tiled == before)
        #expect(w.windows[4]?.workspace == "2")
    }

    @Test func newWindowsTileOnFocusedWorkspace() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        let placed = placed(w)
        #expect(placed[1] == .frame(CGRect(x: 0, y: 30, width: 500, height: 570)))
        #expect(placed[2] == .frame(CGRect(x: 500, y: 30, width: 500, height: 570)))
    }

    @Test func switchingHidesTheOldWorkspace() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        let r1 = w.switchWorkspace(.named("2"))
        #expect(r1)
        #expect(placed(w)[1] == .hidden)
        #expect(w.previousWorkspace == "1")
        let r2 = w.switchWorkspace(.back)
        #expect(r2)
        #expect(w.focusedWorkspaceName == "1")
        let r3 = w.switchWorkspace(.named("1"))
        #expect(!r3)
    }

    @Test func switchingToAWorkspaceOnAnotherMonitorMovesFocusThere() {
        var w = world(monitors: [left, right])
        w.switchWorkspace(.named("2"))
        #expect(w.focusedMonitor == 2)
        #expect(w.visible[1] == "1")
    }

    @Test func focusOnHiddenWindowRevealsItsWorkspace() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.switchWorkspace(.named("2"))
        // Cmd-Tab to the app whose window lives on workspace 1.
        let r4 = w.noteFocus(1)
        #expect(r4 == .revealedWorkspace("1"))
        #expect(w.focusedWorkspaceName == "1")
    }

    @Test func movingAWindowAwayHandsFocusToTheNextOne() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        let next = w.moveWindow(2, to: .named("3"), follow: false)
        #expect(next == 1)
        #expect(w.windows[2]?.workspace == "3")
        #expect(placed(w)[2] == .hidden)
        #expect(placed(w)[1] == .frame(CGRect(x: 0, y: 30, width: 1000, height: 570)))
    }

    @Test func closingTheFocusedWindowNamesASuccessor() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        let r5 = w.removeWindow(2)
        #expect(r5 == 1)
        let r6 = w.removeWindow(1)
        #expect(r6 == nil)
    }

    @Test func directionalFocusAndSwap() {
        var w = world()
        for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
        // Layout: 1 | (2 / 3), focus on 3.
        let r7 = w.focus(.up)
        #expect(r7 == .window(2))
        let r8 = w.focus(.left)
        #expect(r8 == .window(1))
        let r9 = w.focus(.right)
        #expect(r9 == .window(2))
        let r10 = w.move(.left)
        #expect(r10 == .window(2))
        #expect(w.workspaces["1"]?.tiled == [2, 1, 3])
    }

    @Test func focusCrossesMonitorsAtTheEdge() {
        var w = world(monitors: [left, right])
        w.addWindow(candidate(1)); w.noteFocus(1)
        let r11 = w.focus(.right)
        #expect(r11 == .emptyMonitor(2))
        #expect(w.focusedWorkspaceName == "2")
        w.addWindow(candidate(2)); w.noteFocus(2)
        let r12 = w.focus(.left)
        #expect(r12 == .window(1))
    }

    @Test func movingAtTheEdgeCarriesTheWindowToTheNextMonitor() {
        var w = world(monitors: [left, right])
        w.addWindow(candidate(1)); w.noteFocus(1)
        let r13 = w.move(.right)
        #expect(r13 == .window(1))
        #expect(w.windows[1]?.workspace == "2")
        #expect(w.focusedMonitor == 2)
    }

    @Test func floatingWindowsKeepTheirFrame() {
        var w = world()
        w.addWindow(candidate(1, floating: true)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        let placed = placed(w)
        #expect(placed[1] == .frame(CGRect(x: 100, y: 100, width: 400, height: 300)))
        #expect(placed[2] == .frame(CGRect(x: 0, y: 30, width: 1000, height: 570)))
    }

    @Test func toggleFloatingRoundTrip() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        w.setFloating(2, .toggle)
        #expect(w.windows[2]?.isFloating == true)
        #expect(w.workspaces["1"]?.tiled == [1])
        w.setFloating(2, .toggle)
        #expect(w.workspaces["1"]?.tiled == [1, 2])
    }

    @Test func adHocWorkspacesDisappearWhenLeftEmpty() {
        var w = world()
        w.switchWorkspace(.named("scratch"))
        #expect(w.workspaces["scratch"] != nil)
        w.switchWorkspace(.named("1"))
        #expect(w.workspaces["scratch"] == nil)
    }

    @Test func nextAndPreviousCycle() {
        var w = world()
        w.switchWorkspace(.next)
        #expect(w.focusedWorkspaceName == "2")
        w.switchWorkspace(.previous)
        w.switchWorkspace(.previous)
        #expect(w.focusedWorkspaceName == "3")
    }

    @Test func droppingOntoAnotherWindowSwaps() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        w.dropWindow(1, at: CGPoint(x: 800, y: 300))
        #expect(w.workspaces["1"]?.tiled == [2, 1])
    }

    @Test func unpluggingAMonitorKeepsItsWorkspace() {
        var w = world(monitors: [left, right])
        w.switchWorkspace(.named("2"))
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.setMonitors([left])
        #expect(w.focusedMonitor == 1)
        #expect(placed(w)[1] == .hidden)
        // Plugging it back in shows the same workspace there again.
        w.setMonitors([left, right])
        #expect(w.visible[2] == "2")
    }

    @Test func parkingAvoidsNeighbouringDisplays() {
        let w = world(monitors: [left, right])
        // Left monitor has a neighbour on its right, so windows park bottom-left.
        let origin = w.parkingOrigin(for: CGSize(width: 400, height: 300), on: 1)
        #expect(origin == CGPoint(x: -399, y: 599))
        let other = w.parkingOrigin(for: CGSize(width: 400, height: 300), on: 2)
        #expect(other == CGPoint(x: 1799, y: 599))
    }

    @Test func scratchpadSummonsAndTucksAway() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        let next = w.moveToScratchpad(2)
        #expect(next == 1)
        #expect(w.windows[2]?.isFloating == true)
        #expect(placed(w)[2] == .hidden)
        #expect(!w.workspaceOrder.contains(World.scratchpad))
        // Summon it: the window floats over the workspace and holds focus.
        let shown = w.setScratchpad(.toggle)
        #expect(shown == 2)
        #expect(w.focusedWindow == 2)
        guard case .frame? = placed(w)[2] else { Issue.record("scratchpad window should be on screen"); return }
        // Clicking a window underneath tucks it away again.
        let outcome = w.noteFocus(1)
        #expect(outcome == .hidScratchpad)
        #expect(placed(w)[2] == .hidden)
        #expect(w.focusedWindow == 1)
    }

    @Test func focusingAScratchpadWindowShowsIt() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        _ = w.moveToScratchpad(1)
        let outcome = w.noteFocus(1)
        #expect(outcome == .revealedScratchpad)
        #expect(w.scratchpadMonitor == 1)
        let hidden = w.setScratchpad(.off)
        #expect(hidden == nil)
        #expect(w.scratchpadMonitor == nil)
    }

    @Test func pinnedWorkspacesOpenOnTheirDisplay() {
        var settings = LayoutSettings()
        settings.innerGap = 0
        var w = World(workspaceNames: ["1", "2", "3", "4"], settings: settings)
        w.pinnedMonitors = ["2": "secondary", "4": "Right"]
        w.setMonitors([left, right])
        // The right display starts on its pinned workspace, not on the next free one.
        #expect(w.visible[2] == "2")
        #expect(w.visible[1] == "1")
        // Switching to a workspace pinned to the other display shows it there and moves focus.
        w.switchWorkspace(.named("4"))
        #expect(w.visible[2] == "4")
        #expect(w.focusedMonitor == 2)
        #expect(w.visible[1] == "1")
        // An unpinned workspace opens on the focused display.
        w.switchWorkspace(.named("3"))
        #expect(w.visible[2] == "3")
    }

    @Test func pinsToMissingDisplaysAreIgnored() {
        var w = World(workspaceNames: ["1", "2"])
        w.pinnedMonitors = ["2": "secondary"]
        w.setMonitors([left])
        w.switchWorkspace(.named("2"))
        #expect(w.visible[1] == "2")
    }

    @Test func aTabTakesOverItsSiblingsTile() {
        var w = world()
        for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
        let before = placed(w)
        var tab = candidate(9)
        tab.pid = w.windows[2]!.pid
        w.replaceWindow(2, with: tab)
        let after = placed(w)
        #expect(after[9] == before[2])
        #expect(after[2] == nil)
        #expect(w.workspaces["1"]?.tiled == [1, 9, 3])
        #expect(w.workspaces["1"]?.tree?.leaves == [1, 9, 3])
    }

    @Test func windowsRestoredIntoTheScratchpadFloat() {
        var w = world()
        w.addWindow(candidate(1), workspace: World.scratchpad, floating: false)
        #expect(w.windows[1]?.isFloating == true)
        #expect(w.workspaces[World.scratchpad]?.floating == [1])
    }

    @Test func sizeCappedWindowsSitCentredInTheirTile() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.limitSize(1, to: CGSize(width: 600, height: 400))
        // The full tile is the whole visible frame: 1000 × 570 at y 30.
        #expect(placed(w)[1] == .frame(CGRect(x: 200, y: 115, width: 600, height: 400)))
        w.limitSize(1, to: nil)
        #expect(placed(w)[1] == .frame(CGRect(x: 0, y: 30, width: 1000, height: 570)))
        w.limitSize(1, to: CGSize(width: 300, height: 300))
        w.removeWindow(1)
        #expect(w.maxSizes[1] == nil)
    }

    @Test func anAutomaticSplitTurnsWhenOnlyTheOtherWayFits() {
        var w = world()
        for id: WindowID in [1, 2] { w.addWindow(candidate(id)); w.noteFocus(id) }
        w.noteMinimumSize(1, CGSize(width: 600, height: 0))
        w.noteMinimumSize(2, CGSize(width: 600, height: 0))
        #expect(placed(w)[1] == .frame(CGRect(x: 0, y: 30, width: 1000, height: 285)))
        #expect(w.cramped(on: "1").isEmpty)
    }

    @Test func splitsMoveToGiveAWindowItsMinimum() {
        var w = world()
        w.addWindow(candidate(1)); w.noteFocus(1)
        w.addWindow(candidate(2)); w.noteFocus(2)
        w.noteMinimumSize(1, CGSize(width: 700, height: 0))
        #expect(placed(w)[1] == .frame(CGRect(x: 0, y: 30, width: 700, height: 570)))
        #expect(placed(w)[2] == .frame(CGRect(x: 700, y: 30, width: 300, height: 570)))
        #expect(w.cramped(on: "1").isEmpty)
    }

    @Test func severalMinimumsShareTheScreenWithoutOverlapping() {
        var w = world()
        for id: WindowID in [1, 2, 3, 4] { w.addWindow(candidate(id)); w.noteFocus(id) }
        // Dwindle on the 1000 × 570 screen: 1 on the left, then 2 above 3 and 4 side by side.
        w.noteMinimumSize(1, CGSize(width: 450, height: 0))
        w.noteMinimumSize(3, CGSize(width: 0, height: 380))
        w.noteMinimumSize(4, CGSize(width: 300, height: 0))
        #expect(w.makeRoom(on: "1").isEmpty)
        #expect(w.cramped(on: "1").isEmpty)
        let frames = placed(w).compactMapValues { placement -> CGRect? in
            if case .frame(let rect) = placement { return rect } else { return nil }
        }
        #expect(frames.count == 4)
        for (id, frame) in frames {
            let minimum = w.minSizes[id] ?? .zero
            #expect(frame.width >= minimum.width && frame.height >= minimum.height)
        }
        // No two overlap, and together they fill the screen: nothing covered, nothing empty.
        let rects = Array(frames.values)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height == 0)
            }
        }
        #expect(abs(rects.reduce(0) { $0 + $1.width * $1.height } - 1000 * 570) < 1)
    }

    @Test func theNewestArrivalFloatsWhenThereIsNoRoom() {
        var w = world()
        for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
        // 1 and 2 each need 600 × 400 of the 1000 × 570 screen: they fit neither side by
        // side nor stacked, so only one of them can tile.
        w.noteMinimumSize(1, CGSize(width: 600, height: 400))
        w.noteMinimumSize(2, CGSize(width: 600, height: 400))
        // 3 floats first, then 2; with 2 gone 3 fits beside 1 after all, so only 2 stays out.
        let floated = w.makeRoom(on: "1")
        #expect(floated == [2])
        #expect(w.windows[1]?.isFloating == false)
        #expect(w.windows[3]?.isFloating == false)
        #expect(w.autoFloated == [2])
    }

    @Test func autoFloatedWindowsTileAgainWhenRoomFreesUp() {
        var w = world()
        for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
        w.noteMinimumSize(3, CGSize(width: 600, height: 400))
        w.noteMinimumSize(1, CGSize(width: 600, height: 400))
        w.makeRoom(on: "1")
        #expect(w.windows[3]?.isFloating == true)
        w.removeWindow(1)
        #expect(w.windows[3]?.isFloating == false)
        #expect(w.autoFloated.isEmpty)
        #expect(w.cramped(on: "1").isEmpty)
    }

    @Test func floatingByHandIsNeverUndone() {
        var w = world()
        for id: WindowID in [1, 2] { w.addWindow(candidate(id)); w.noteFocus(id) }
        w.setFloating(2, .on)
        w.removeWindow(1)
        #expect(w.windows[2]?.isFloating == true)
    }

    @Test func makingRoomLeavesFocusAlone() {
        var w = world()
        for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
        w.noteFocus(1)
        w.noteMinimumSize(1, CGSize(width: 600, height: 400))
        w.noteMinimumSize(2, CGSize(width: 600, height: 400))
        w.makeRoom(on: "1")
        #expect(w.focusedWindow == 1)
        w.removeWindow(3)
        #expect(w.focusedWindow == 1)
    }

    @Test func aWindowTooBigForTheScreenFloatsItself() {
        var w = world()
        for id: WindowID in [1, 2] { w.addWindow(candidate(id)); w.noteFocus(id) }
        // Wider than the 1000-point screen: floating window 2 couldn't make it fit.
        w.noteMinimumSize(1, CGSize(width: 1200, height: 0))
        #expect(w.makeRoom(on: "1") == [1])
        #expect(w.windows[2]?.isFloating == false)
    }

    @Test func scratchpadWindowsNeverTile() {
        var w = world()
        w.addWindow(candidate(1), workspace: World.scratchpad, floating: true)
        w.setFloating(1, .off)
        #expect(w.windows[1]?.isFloating == true)
    }

    @Test func aWindowPutBackTakesTheSameSideAndSize() {
        var w = world()
        for id: WindowID in [1, 2] { w.addWindow(candidate(id)); w.noteFocus(id) }
        w.resize(1, .width, by: 180, edge: .right)
        let before = placed(w)[1]
        let slot = w.slot(of: 1)
        w.removeWindow(1)
        w.noteFocus(2)
        // A relaunched app's window has a new number.
        w.addWindow(candidate(3), slot: slot)
        #expect(placed(w)[3] == before)
        #expect(w.workspaces["1"]?.tiled == [3, 2])
    }

    @Test func aSavedSlotPutsAWindowBackAfterARestart() throws {
        var w = world()
        for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
        w.resize(3, .height, by: 120, edge: .up)
        let before = placed(w)[3]
        let saved = try JSONDecoder().decode(TileSlot.self, from: JSONEncoder().encode(w.slot(of: 3)))
        w.removeWindow(3)
        // Minimised over a restart: the same window, with the same number, returns.
        w.addWindow(candidate(3), workspace: "1", slot: saved)
        #expect(placed(w)[3] == before)
    }

    @Test func aSlotWhoseNeighboursChangedFallsBackToANeighbour() {
        var w = world()
        for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
        // 1 on the left, 2 and 3 stacked on the right.
        let slot = w.slot(of: 1)
        w.removeWindow(1)
        w.removeWindow(3)
        w.addWindow(candidate(4), slot: slot)
        // Its old neighbourhood was 2 and 3; with 3 gone it still lands to the left of 2.
        #expect(w.workspaces["1"]?.tiled == [4, 2])
    }

    @Test func restartRebuildsTheArrangementWhateverOrderWindowsReturnIn() throws {
        // The split between the two pairs belongs to no single window; it must come back too.
        let tree = DwindleNode.split(axis: nil, ratio: 0.35,
                                     first: .split(axis: .vertical, ratio: 0.6, first: .leaf(4), second: .leaf(1)),
                                     second: .split(axis: nil, ratio: 0.7, first: .leaf(2), second: .leaf(3)))
        let arrangement = Workspace.Arrangement(tree: tree)
        let saved = try JSONDecoder().decode(Workspace.Arrangement.self, from: JSONEncoder().encode(arrangement))
        for order in permutations([1, 2, 3, 4]) {
            var w = world()
            for id in order {
                w.addWindow(candidate(id), workspace: "1", slot: saved.slot(of: id, among: w.workspaces["1"]?.tiled ?? [], workspace: "1"))
            }
            #expect(w.workspaces["1"]?.tree == tree, "returning in the order \(order)")
        }
    }

    @Test func aRestartedAppGetsItsTilesBackUnderNewNumbers() {
        // Two windows of one app beside one of another; the app restarts and its windows
        // come back as 11 and 12, in either order.
        for order: [WindowID] in [[11, 12], [12, 11]] {
            var w = world()
            for id: WindowID in [1, 2, 3] { w.addWindow(candidate(id)); w.noteFocus(id) }
            w.resize(1, .width, by: 150, edge: .right)
            w.resize(3, .height, by: -80, edge: .up)
            let before = placed(w)
            let saved = w.workspaces["1"]!.arrangement
            w.removeWindow(1)
            w.removeWindow(3)
            var numbers: [WindowID: WindowID] = [:]
            for id in order {
                let old: WindowID = id == 11 ? 1 : 3
                w.addWindow(candidate(id), workspace: "1", slot: saved.slot(of: old, among: w.workspaces["1"]?.tiled ?? [], workspace: "1", renumbered: numbers))
                numbers[old] = id
            }
            #expect(placed(w)[11] == before[1], "returning in the order \(order)")
            #expect(placed(w)[12] == before[3], "returning in the order \(order)")
            #expect(placed(w)[2] == before[2], "returning in the order \(order)")
        }
    }
}

private func permutations(_ ids: [WindowID]) -> [[WindowID]] {
    guard ids.count > 1 else { return [ids] }
    return ids.indices.flatMap { i in
        permutations(Array(ids[..<i] + ids[(i + 1)...])).map { [ids[i]] + $0 }
    }
}
