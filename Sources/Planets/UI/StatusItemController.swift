import AppKit
import os
import PlanetsCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Model: Equatable {
        struct Chip: Equatable {
            var name: String
            var active: Bool
            var away = false
        }
        var chips: [Chip] = []
        var away: [String] = []
        var tilingEnabled = true
        var needsPermission = false
    }

    var menuProvider: (() -> NSMenu)?

    private var item: NSStatusItem?
    private var model = Model()

    private static let height: CGFloat = 22
    private static let accessibilityLabel = "Planets workspaces"

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "PlanetsWorkspaces"
        item.behavior = []
        if let button = item.button {
            button.setAccessibilityLabel(Self.accessibilityLabel)
            button.imagePosition = .imageOnly
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        render()
    }

    func update(_ model: Model) {
        guard model != self.model else { return }
        let redraw = model.chips != self.model.chips || model.tilingEnabled != self.model.tilingEnabled || model.needsPermission != self.model.needsPermission
        self.model = model
        render(redraw: redraw)
    }

    private func render(redraw: Bool = true) {
        guard let button = item?.button else { return }
        if redraw { button.image = image(model) }
        let current = model.chips.first(where: \.active).map { "Workspace \($0.name)" }
        let shown = model.away.prefix(3) + (model.away.count > 3 ? ["\(model.away.count - 3) more"] : [])
        button.setAccessibilityValue(([current].compactMap(\.self) + shown).joined(separator: ", "))
    }

    func image(_ model: Model) -> NSImage {
        let layout = Self.layout(model)
        let image = NSImage(size: layout.size, flipped: false) { _ in
            Self.draw(model, rects: layout.rects)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func layout(_ model: Model) -> (size: NSSize, rects: [CGRect]) {
        guard model.tilingEnabled, !model.needsPermission, !model.chips.isEmpty else {
            return (NSSize(width: 18, height: height), [])
        }
        let y = ((height - WorkspaceMark.height) / 2).rounded(.up)
        var x: CGFloat = 0
        var rects: [CGRect] = []
        for chip in model.chips {
            let width = WorkspaceMark.size(chip.name).width
            rects.append(CGRect(x: x, y: y, width: width, height: WorkspaceMark.height))
            x += width + 4
        }
        return (NSSize(width: x - 4, height: height), rects)
    }

    private static func draw(_ model: Model, rects: [CGRect]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard model.tilingEnabled, !model.needsPermission else {
            let rect = CGRect(x: 2, y: 5, width: 14, height: 12)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
            NSColor.black.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1.4
            path.stroke()
            let split = NSBezierPath()
            split.move(to: CGPoint(x: rect.midX, y: rect.minY + 2.5))
            split.line(to: CGPoint(x: rect.midX, y: rect.maxY - 2.5))
            split.lineWidth = 1.4
            split.stroke()
            return
        }
        for (chip, rect) in zip(model.chips, rects) {
            let middle = WorkspaceMark.draw(chip.name, in: rect, current: chip.active, context: context)
            if chip.away {
                let scale = max(1, context.userSpaceToDeviceSpaceTransform.a)
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(CGPath(roundedRect: CGRect(x: ((middle - 1.5) * scale).rounded() / scale, y: 0, width: 3, height: 2), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
                context.fillPath()
            }
        }
    }

    private var menuIsOpen = false
    private var menuClosedAt: ContinuousClock.Instant?
    nonisolated private static let openMenu = OSAllocatedUnfairLock<Unchecked<NSMenu>?>(initialState: nil)

    func toggleMenu(pressedAt: ContinuousClock.Instant = .now) {
        if menuIsOpen {
            item?.menu?.cancelTracking()
        } else if menuClosedAt.map({ pressedAt >= $0 }) ?? true {
            item?.button?.performClick(nil)
        }
    }

    nonisolated static func closeOpenMenu() -> Bool {
        guard let menu = openMenu.withLock({ $0 }) else { return false }
        let main = CFRunLoopGetMain()
        let mode = CFRunLoopCopyCurrentMode(main)?.rawValue ?? CFRunLoopMode.commonModes.rawValue
        CFRunLoopPerformBlock(main, mode) {
            MainActor.assumeIsolated { menu.value.cancelTracking() }
        }
        CFRunLoopWakeUp(main)
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        let entry = Unchecked(menu)
        Self.openMenu.withLock { $0 = entry }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        menuClosedAt = .now
        Self.openMenu.withLock { $0 = nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let fresh = menuProvider?() else { return }
        for entry in fresh.items {
            fresh.removeItem(entry)
            menu.addItem(entry)
        }
    }
}

@MainActor
enum WorkspaceMark {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
    static let height: CGFloat = 16

    static func size(_ name: String) -> CGSize {
        let text = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(width: text + 7 <= height ? height : text + height / 2, height: height)
    }

    @discardableResult
    static func draw(_ name: String, in rect: CGRect, current: Bool, context: CGContext) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let width = (name as NSString).size(withAttributes: attributes).width
        let ink = inkOffset(name, font: font)
        let scale = max(1, context.userSpaceToDeviceSpaceTransform.a)
        let baseline = (rect.midY - font.capHeight / 2).rounded()
        let origin = CGPoint(x: ((rect.midX - width / 2 - ink) * scale).rounded() / scale, y: baseline + font.descender)
        let middle = origin.x + width / 2 + ink
        guard current else {
            (name as NSString).draw(at: origin, withAttributes: attributes)
            return middle
        }
        context.saveGState()
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        context.fillPath()
        context.setBlendMode(.destinationOut)
        (name as NSString).draw(at: origin, withAttributes: attributes)
        context.restoreGState()
        return middle
    }

    static func inkOffset(_ name: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize) \(name)"
        if let known = offsets[key] { return known }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let offset = (name.allSatisfy { $0 == "1" } ? weightMiddle(name, font: font, bounds: bounds) : nil).map { $0 - width / 2 } ?? bounds.midX - width / 2
        offsets[key] = offset
        return offset
    }

    private static var offsets: [String: CGFloat] = [:]

    private static func weightMiddle(_ name: String, font: NSFont, bounds: CGRect) -> CGFloat? {
        let scale: CGFloat = 8
        let width = Int(ceil(bounds.width * scale)) + 2, height = Int(ceil(bounds.height * scale)) + 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
        context.setFillColor(gray: 1, alpha: 1)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: 1 / scale - bounds.minX, y: 1 / scale - bounds.minY)
        CTLineDraw(line, context)
        var total = 0.0, moment = 0.0
        for row in 0..<height {
            for column in 0..<width {
                let ink = Double(data[row * width + column])
                total += ink
                moment += ink * (Double(column) + 0.5)
            }
        }
        guard total > 0 else { return nil }
        return bounds.minX - 1 / scale + CGFloat(moment / total) / scale
    }
}
