import CoreGraphics
import Foundation
import Testing
@testable import PlanetsCore

@Suite struct PerformanceTests {
    /// The model's share of a workspace switch: switching and computing every window's
    /// spot for 60 windows over nine workspaces. Everything else in a switch is waiting on
    /// apps, so this number should stay far below a millisecond.
    @Test func switchAndPlaceIsSubMillisecond() {
        let monitor = Monitor(id: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1410), isMain: true)
        var world = World(workspaceNames: (1...9).map(String.init))
        world.setMonitors([monitor])
        for id in WindowID(1)...60 {
            world.switchWorkspace(.named(String((Int(id) % 9) + 1)))
            world.addWindow(WindowCandidate(id: id, pid: 1, bundleID: nil, appName: "A", title: "", frame: .zero, prefersFloating: false))
            world.noteFocus(id)
        }
        let rounds = 2_000
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for round in 0..<rounds {
                world.switchWorkspace(.named(String(round % 9 + 1)))
                _ = world.placements()
            }
        }
        let perSwitch = Double(elapsed.components.attoseconds) / 1e12 / Double(rounds) + Double(elapsed.components.seconds) * 1e6 / Double(rounds)
        print("model cost per workspace switch: \(String(format: "%.1f", perSwitch)) µs")
        #expect(perSwitch < 1000)
    }
}
