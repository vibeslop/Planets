import AppKit

@MainActor
final class PermissionGuide {
    private var panel: NSPanel?
    private var follow: Timer?

    func show() {
        if let url = SetupCheck.privacyAccessibility { NSWorkspace.shared.open(url) }
        if panel == nil { panel = Self.makePanel() }
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    func hide() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func update() {
        guard !AXIsProcessTrusted() else { return hide() }
        guard let panel, let settings = Self.settingsWindow() else {
            panel?.orderOut(nil)
            return
        }
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, beside: settings))
        panel.orderFrontRegardless()
    }

    private static func origin(for size: CGSize, beside settings: CGRect) -> NSPoint {
        let center = CGPoint(x: settings.midX, y: settings.midY)
        let screen = NSScreen.screens.first { Displays.toGlobal($0.frame).contains(center) } ?? NSScreen.main
        let area = screen.map { Displays.toGlobal($0.visibleFrame) } ?? settings
        let gap: CGFloat = 12
        let listMidX = settings.minX + 215 + (settings.width - 215) / 2
        var topLeft: CGPoint
        if settings.maxY + gap + size.height <= area.maxY {
            topLeft = CGPoint(x: listMidX - size.width / 2, y: settings.maxY + gap)
        } else if settings.maxX + gap + size.width <= area.maxX {
            topLeft = CGPoint(x: settings.maxX + gap, y: settings.maxY - size.height - 40)
        } else if settings.minX - gap - size.width >= area.minX {
            topLeft = CGPoint(x: settings.minX - gap - size.width, y: settings.maxY - size.height - 40)
        } else {
            topLeft = CGPoint(x: settings.maxX - size.width - 20, y: settings.maxY - size.height - 20)
        }
        topLeft.x = min(max(topLeft.x, area.minX + 8), area.maxX - size.width - 8)
        return Displays.toAppKit(CGPoint(x: topLeft.x, y: topLeft.y + size.height))
    }

    private static func settingsWindow() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.lazy
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .first { $0.width > 300 && $0.height > 200 }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 84), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let icon = DraggableApp(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let title = NSTextField(labelWithString: "Drag Planets into the list above")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "It’s switched on as it lands. Already listed? Switch it on there.")
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 18)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        text.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.contentView = row
        panel.contentView = glass
        panel.setContentSize(row.fittingSize)
        return panel
    }
}

private final class DraggableApp: NSView, NSDraggingSource {
    private let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
