import AppKit
import SwiftUI

@MainActor
final class WorkspaceHUD {
    struct Chip: Equatable, Identifiable {
        var name: String
        var occupied: Bool
        var away = false
        var id: String { name }
    }

    struct Model: Equatable {
        var chips: [Chip] = []
        var active: String = ""
    }

    private let state = HUDState()
    private lazy var panel: NSPanel = makePanel()
    private var hideWork: DispatchWorkItem?
    private var shown = 0

    private static let hold = 0.45
    private static let exit = (duration: 0.16, curve: (0.25, 1.0, 0.5, 1.0))
    func show(model: Model, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        state.model = model
        state.leaving = false
        shown += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        let visible = screen.visibleFrame
        let frame = NSRect(x: (visible.midX - Self.canvas.width / 2).rounded(), y: visible.minY + 40, width: Self.canvas.width, height: Self.canvas.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: work)
    }

    private static let canvas = CGSize(width: 1100, height: 120)

    private func hide() {
        let showing = shown
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let (x1, y1, x2, y2) = Self.exit.curve
        withAnimation(reduce ? nil : .timingCurve(x1, y1, x2, y2, duration: Self.exit.duration)) { state.leaving = true }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduce ? 0 : Self.exit.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown == showing else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.canvas), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: HUDView(state: state).frame(width: Self.canvas.width, height: Self.canvas.height))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

@MainActor
@Observable
final class HUDState {
    var model = WorkspaceHUD.Model()
    var leaving = false
}

private struct HUDView: View {
    let state: HUDState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(state.model.chips) { chip in
                ChipView(chip: chip, active: chip.name == state.model.active)
            }
        }
        .opacity(state.leaving ? 0 : 1)
        .padding(6)
        .background {
            Capsule().fill(colorScheme == .dark ? .black.opacity(0.35) : .white.opacity(0.35))
                .overlay { Capsule().strokeBorder(colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08), lineWidth: 0.5) }
        }
        .glassEffect(.regular, in: .capsule)
        .padding(14)
        .fixedSize()
    }
}

private struct ChipView: View {
    let chip: WorkspaceHUD.Chip
    let active: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        let width = (chip.name as NSString).size(withAttributes: [.font: Self.font]).width
        let offset = WorkspaceMark.inkOffset(chip.name, font: Self.font)
        let chipWidth = max(32, chip.name.count > 1 ? ceil(width) + 20 : 0)
        let left = pixels(chipWidth / 2 - width / 2 - offset)
        ZStack(alignment: .leading) {
            Text(chip.name)
                .font(Font(Self.font as CTFont))
                .foregroundStyle(active ? ink : fill.opacity(chip.occupied ? 1 : colorScheme == .dark ? 0.3 : 0.4))
                .fixedSize()
                .offset(x: left)
            if chip.away {
                RoundedRectangle(cornerRadius: 0.5).fill(active ? ink : fill).frame(width: 3, height: 2)
                    .offset(x: pixels(left + width / 2 + offset - 1.5), y: 12)
            }
        }
        .frame(width: chipWidth, height: 32, alignment: .leading)
        .background {
            if active { Capsule().fill(fill) }
        }
    }

    private func pixels(_ x: CGFloat) -> CGFloat { (x * scale).rounded() / scale }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    private var fill: Color { colorScheme == .dark ? .white : Color(white: 0.12) }
    private var ink: Color { colorScheme == .dark ? Color(white: 0.12) : .white }
}
