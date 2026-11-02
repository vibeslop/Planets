import AppKit
import SwiftUI

/// The overlay that appears for a moment when you change workspace: a glass capsule with
/// every workspace, the current one lit. It never takes focus or clicks, and it is built
/// once and reused so showing it costs one SwiftUI update.
@MainActor
final class WorkspaceHUD {
    struct Chip: Equatable, Identifiable {
        var name: String
        var occupied: Bool
        /// Windows minimised or hidden from here, marked as in the strip.
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
    /// Counts showings, so a fade that ends after the HUD was shown again leaves it up.
    private var shown = 0

    /// Long enough to see where you landed; it sits over your work while it shows.
    private static let hold = 0.45
    /// An ease-out long enough to read as a fade: at 0.1 s most of it went in the first frame.
    private static let exit = (duration: 0.16, curve: (0.25, 1.0, 0.5, 1.0))
    /// Shows the HUD and lets it go a moment later. Switching is a keyboard action, done many
    /// times a day, and the windows change at once, so nothing here moves either: the HUD is
    /// simply there, at full strength even if it was on its way out.
    func show(model: Model, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        state.model = model
        state.leaving = false
        shown += 1
        // Back at full strength now, stopping a fade on its way.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        // The window is larger than any capsule will be and the capsule is centred inside,
        // so a capsule that grows (more workspaces) is never clipped.
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

    /// The window fades, and the numbers fade on it as well: glass thins out faster than the
    /// window's alpha says, and on its own the dark circle outlasted light glass over a white
    /// window by several frames.
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
                // Shown again meanwhile, it stays.
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

/// Every size here nests: the capsule is 44 tall, a 6-point inset around 32-point chips,
/// so the current workspace's circle follows the capsule's curve exactly. Numbers only: the
/// apps of the workspace you've switched to are on screen behind it.
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
            // Dark glass over a white window turns mid-grey, and white numbers on it barely
            // stand apart from faint ones; a shade of its own under them keeps the glass its
            // colour. Light, the same over a dark window.
            Capsule().fill(colorScheme == .dark ? .black.opacity(0.35) : .white.opacity(0.35))
                // Glass takes the colour of what's under it, so it loses its edge over its
                // own colour: light over a white window, dark over a black one. A hairline
                // keeps the edge, on the capsule alone.
                .overlay { Capsule().strokeBorder(colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08), lineWidth: 0.5) }
        }
        .glassEffect(.regular, in: .capsule)
        .padding(14)
        .fixedSize()
    }
}

/// A workspace's number, bright where there are windows and faint where there are none, with
/// the strip's bar under it for windows minimised or hidden there: inside the current
/// workspace's circle, in the number's colour.
private struct ChipView: View {
    let chip: WorkspaceHUD.Chip
    let active: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        let width = (chip.name as NSString).size(withAttributes: [.font: Self.font]).width
        let offset = WorkspaceMark.inkOffset(chip.name, font: Self.font)
        let chipWidth = max(32, chip.name.count > 1 ? ceil(width) + 20 : 0)
        // Centred by its ink rather than its width, as the strip's numbers are, and placed on
        // pixels worked out here: layout rounded the number and its bar to pixels apart, a pixel
        // apart under a 1. The number, its bar and the circle share one line down the middle.
        let left = pixels(chipWidth / 2 - width / 2 - offset)
        ZStack(alignment: .leading) {
            Text(chip.name)
                .font(Font(Self.font as CTFont))
                // Plain colours: vibrant ones on glass left an occupied number barely brighter
                // than an empty one. Empty ones fainter on dark glass, where 40% stood half as
                // far apart as on light.
                .foregroundStyle(active ? ink : fill.opacity(chip.occupied ? 1 : colorScheme == .dark ? 0.3 : 0.4))
                .fixedSize()
                // Centred as a line, the digits already sit on the circle's middle.
                .offset(x: left)
            // One row for every bar, under the digits and inside the circle.
            if chip.away {
                RoundedRectangle(cornerRadius: 0.5).fill(active ? ink : fill).frame(width: 3, height: 2)
                    .offset(x: pixels(left + width / 2 + offset - 1.5), y: 12)
            }
        }
        .frame(width: chipWidth, height: 32, alignment: .leading)
        .background {
            // The mark the menu bar uses. Not .primary: on glass it's vibrant, a grey number on a
            // see-through grey.
            if active { Capsule().fill(fill) }
        }
    }

    private func pixels(_ x: CGFloat) -> CGFloat { (x * scale).rounded() / scale }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    private var fill: Color { colorScheme == .dark ? .white : Color(white: 0.12) }
    private var ink: Color { colorScheme == .dark ? Color(white: 0.12) : .white }
}
