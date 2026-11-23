import AppKit
import QuartzCore
import PlanetsCore
import PlanetsPrivate

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
            colorObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.color == .accent else { return }
                    for panel in self.panels.values { panel.paint(.accent) }
                }
            }
            themeObserver = DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.color == .neutral else { return }
                    DispatchQueue.main.async { for panel in self.panels.values { panel.paint(.neutral) } }
                }
            }
        }
    }

    func update(target: (id: WindowID, frame: CGRect)?, monitors: [Monitor], restack: Bool = false) {
        trace("glow update target=\(String(describing: target)) restack=\(restack)")
        guard enabled, let target, let monitor = monitors.first(where: { $0.frame.contains(target.frame.center) }) else {
            hideAll()
            return
        }
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
    private var shapedSize: CGSize = .zero

    static let windowCornerRadius: CGFloat = 17
    static let rimOffset: CGFloat = 1.75

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .normal
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .transient, .fullScreenNone]
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.masksToBounds = false
        contentView = view

        for light in [rimLight, bloomLight] {
            light.type = .conic
            light.startPoint = CGPoint(x: 0.5, y: 0.5)
            light.endPoint = CGPoint(x: 0, y: 1)
        }
        paint(.gold)

        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1.5
        rim.mask = rimMask
        rim.addSublayer(rimLight)

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
        bloomRadius = max(4, min(14, gap * 0.7 + 3))
        spread = bloomRadius * 2.6 + Self.rimOffset
        bloomMask.shadowRadius = bloomRadius
        bloom.opacity = Float(0.3 + 0.55 * intensity)
        rim.opacity = Float(0.5 + 0.4 * intensity)
        shapedSize = .zero
    }

    func place(on frame: CGRect) {
        monitorFrame = frame
        setFrame(Displays.toAppKit(frame), display: false)
    }

    func show(windowFrame: CGRect, monitorFrame: CGRect) {
        let local = CGRect(
            x: windowFrame.minX - monitorFrame.minX,
            y: monitorFrame.maxY - windowFrame.maxY,
            width: windowFrame.width,
            height: windowFrame.height
        )
        let outer = local.insetBy(dx: -spread, dy: -spread)
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
