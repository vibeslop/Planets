import AppKit
import QuartzCore
import PlanetsCore
import PlanetsPrivate

/// The rim around the focused window: a thin line of light just outside its edge, with a
/// soft haze around it, in the colour picked in Settings (gold unless changed).
///
/// Each monitor gets one transparent, click-through panel ordered directly below the
/// focused window, so the window covers the inner half of the sheen and only the light in
/// the gaps shows. The rim follows the measured window corner radius so the gap stays even
/// at the corners. It never animates between windows: focus mostly moves by keyboard,
/// hundreds of times a day, and light that arrives late makes the whole app feel slow.
@MainActor
final class FocusGlowController {
    private var panels: [MonitorID: GlowPanel] = [:]
    private var enabled = true
    private var intensity = 0.7
    private var gap: CGFloat = 10
    private var color: GlowColor = .gold
    private var colorObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var shown: (id: WindowID, frame: CGRect, monitor: MonitorID)?
    private var restackWork: DispatchWorkItem?

    func configure(enabled: Bool, intensity: Double, gap: CGFloat, color: GlowColor = .gold) {
        self.enabled = enabled
        self.intensity = intensity
        self.gap = gap
        self.color = color
        for panel in panels.values {
            panel.style(intensity: intensity, gap: gap)
            panel.paint(color)
        }
        if !enabled { hideAll() }
        if colorObserver == nil {
            // The accent colour can change in System Settings while Planets runs.
            colorObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.color == .accent else { return }
                    for panel in self.panels.values { panel.paint(.accent) }
                }
            }
            // Neutral light follows light and dark mode.
            themeObserver = DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.color == .neutral else { return }
                    // The app's appearance updates just after the notification.
                    DispatchQueue.main.async { for panel in self.panels.values { panel.paint(.neutral) } }
                }
            }
        }
    }

    /// `restack` re-orders the glow under the window, needed whenever focus changes: the
    /// focused window has just been raised, and the glow must follow it up the stack.
    func update(target: (id: WindowID, frame: CGRect)?, monitors: [Monitor], restack: Bool = false) {
        trace("glow update target=\(String(describing: target)) restack=\(restack)")
        guard enabled, let target, let monitor = monitors.first(where: { $0.frame.contains(target.frame.center) }) else {
            hideAll()
            return
        }
        // Drop panels for monitors that went away.
        for id in panels.keys where !monitors.contains(where: { $0.id == id }) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        if let shown, shown.id == target.id, shown.frame == target.frame, shown.monitor == monitor.id {
            if restack { self.restack(target.id, monitor: monitor.id) }
            return
        }
        let panel = panel(for: monitor)
        let switchingWindow = shown?.id != target.id
        if let previous = shown, previous.monitor != monitor.id { panels[previous.monitor]?.fadeOut() }
        panel.show(windowFrame: target.frame, monitorFrame: monitor.frame)
        shown = (target.id, target.frame, monitor.id)
        if switchingWindow || restack || !panel.isVisible { self.restack(target.id, monitor: monitor.id) }
    }

    /// Orders the glow under the window now, and again a moment later: the app raises its
    /// window on its own thread, and a raise that lands after the first ordering would leave
    /// the glow behind.
    private func restack(_ id: WindowID, monitor: MonitorID) {
        panels[monitor]?.orderBelow(id)
        restackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let shown = self.shown, shown.id == id else { return }
                self.panels[shown.monitor]?.orderBelow(id)
            }
        }
        restackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func hideAll() {
        for panel in panels.values { panel.fadeOut() }
        shown = nil
    }

    private func panel(for monitor: Monitor) -> GlowPanel {
        if let panel = panels[monitor.id] {
            if panel.monitorFrame != monitor.frame { panel.place(on: monitor.frame) }
            return panel
        }
        let panel = GlowPanel()
        panel.style(intensity: intensity, gap: gap)
        panel.paint(color)
        panel.place(on: monitor.frame)
        panels[monitor.id] = panel
        return panel
    }
}

final class GlowPanel: NSPanel {
    /// Everything moves together inside this layer, sized to the window plus the bloom.
    private let container = CALayer()
    private let rim = CALayer()
    private let rimMask = CAShapeLayer()
    private let rimLight = CAGradientLayer()
    private let bloom = CALayer()
    private let bloomMask = CALayer()
    private let bloomLight = CAGradientLayer()
    private(set) var monitorFrame: CGRect = .zero
    private var bloomRadius: CGFloat = 9
    private var spread: CGFloat = 26
    private var intensity: Double = 0.7
    private var visibleGlow = false
    /// The size the rim and bloom paths were last built for.
    private var shapedSize: CGSize = .zero

    /// Window corner radius, measured from window captures on macOS 27: windows with and
    /// without toolbars all come out at about 17 pt. The rim sits just outside the window
    /// edge, so its own corners are this plus the offset, which keeps the gap even all round.
    static let windowCornerRadius: CGFloat = 17
    /// How far outside the window edge the rim's centre line runs.
    static let rimOffset: CGFloat = 1.75

    init() {
        // Not deferred: the panel needs its window number before it is first shown, to be
        // ordered relative to another app's window.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .normal
        // Transient: Mission Control hides it instead of showing a stray glowing rectangle.
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .transient, .fullScreenNone]
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.masksToBounds = false
        contentView = view

        for light in [rimLight, bloomLight] {
            light.type = .conic
            light.startPoint = CGPoint(x: 0.5, y: 0.5)
            // In this y-up layer, pointing the end at the top-left corner starts the light there.
            light.endPoint = CGPoint(x: 0, y: 1)
        }
        paint(.gold)

        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1.5
        rim.mask = rimMask
        rim.addSublayer(rimLight)

        // The bloom's mask is nothing but a blurred shadow of the rim, so the light shows
        // through softly on both sides of it; the window covers the inner side.
        bloomMask.shadowColor = NSColor.black.cgColor
        bloomMask.shadowOpacity = 1
        bloomMask.shadowOffset = .zero
        bloom.mask = bloomMask
        bloom.addSublayer(bloomLight)

        container.addSublayer(bloom)
        container.addSublayer(rim)
        container.opacity = 0
        view.layer?.addSublayer(container)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Core Animation walks conic gradients counter-clockwise, SwiftUI clockwise; the
    /// mirrored stops make the haze drift across the top here as it does in the app.
    func paint(_ color: GlowColor) {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = Theme.palette(color, dark: dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (light, stops) in [(rimLight, palette.rim), (bloomLight, palette.bloom)] {
            let mirrored = stops.reversed()
            light.colors = mirrored.map { $0.color.usingColorSpace(.displayP3)?.cgColor ?? $0.color.cgColor }
            light.locations = mirrored.map { NSNumber(value: Double(1 - $0.location)) }
        }
        CATransaction.commit()
    }

    func style(intensity: Double, gap: CGFloat) {
        self.intensity = intensity
        // The bloom reaches about as far as the gap between windows: it lights the gutter
        // without washing over the neighbours.
        bloomRadius = max(4, min(14, gap * 0.7 + 3))
        spread = bloomRadius * 2.6 + Self.rimOffset
        bloomMask.shadowRadius = bloomRadius
        // Vapor stays faint: it should be felt at the edge of vision, not looked at.
        bloom.opacity = Float(0.3 + 0.55 * intensity)
        rim.opacity = Float(0.5 + 0.4 * intensity)
        shapedSize = .zero
    }

    func place(on frame: CGRect) {
        monitorFrame = frame
        setFrame(Displays.toAppKit(frame), display: false)
    }

    /// Positions the glow around a window, in global top-left coordinates. It snaps there:
    /// the only motion is a short fade when the glow first appears.
    func show(windowFrame: CGRect, monitorFrame: CGRect) {
        // The view isn't flipped: convert to its bottom-left space relative to the panel.
        let local = CGRect(
            x: windowFrame.minX - monitorFrame.minX,
            y: monitorFrame.maxY - windowFrame.maxY,
            width: windowFrame.width,
            height: windowFrame.height
        )
        let outer = local.insetBy(dx: -spread, dy: -spread)
        // A window being dragged keeps its size, and then only the container moves: no new
        // paths, no restroked bloom, one layer position per pointer event.
        if outer.size == shapedSize {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.frame = outer
            CATransaction.commit()
            revealIfNeeded()
            return
        }
        shapedSize = outer.size
        let bounds = CGRect(origin: .zero, size: outer.size)
        let rimRect = CGRect(x: spread, y: spread, width: local.width, height: local.height).insetBy(dx: -Self.rimOffset, dy: -Self.rimOffset)
        let radius = Self.windowCornerRadius + Self.rimOffset
        let rimPath = CGPath(roundedRect: rimRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let bloomPath = rimPath.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 1)
        // The light layers are squares centred on the rim, so the conic sheen spreads evenly.
        let side = hypot(outer.width, outer.height)
        let lightFrame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = outer
        for layer in [rim, bloom, rimMask, bloomMask] { layer.frame = bounds }
        rimMask.path = rimPath
        bloomMask.shadowPath = bloomPath
        for light in [rimLight, bloomLight] {
            light.bounds = CGRect(origin: .zero, size: lightFrame.size)
            light.position = CGPoint(x: lightFrame.midX, y: lightFrame.midY)
        }
        CATransaction.commit()
        revealIfNeeded()
    }

    private func revealIfNeeded() {
        if !visibleGlow || !isVisible {
            visibleGlow = true
            CATransaction.begin()
            CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1))
            container.opacity = 1
            CATransaction.commit()
        }
    }

    func orderBelow(_ windowID: WindowID) {
        guard windowNumber > 0 else { return }
        order(.below, relativeTo: Int(windowID))
        if debugTracing {
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            let ours = list.firstIndex { ($0[kCGWindowNumber as String] as? Int) == windowNumber } ?? -1
            let target = list.firstIndex { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) } ?? -1
            trace("glow orderBelow \(windowID) ours=\(windowNumber) visible=\(isVisible) z ours=\(ours) target=\(target)")
        }
    }

    func fadeOut() {
        guard isVisible else { return }
        visibleGlow = false
        CATransaction.begin()
        CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visibleGlow else { return }
                self.orderOut(nil)
            }
        }
        container.opacity = 0
        CATransaction.commit()
    }
}
