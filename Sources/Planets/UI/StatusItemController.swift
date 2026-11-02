import AppKit
import os
import PlanetsCore

/// The workspace strip in the menu bar, like a Linux bar's workspace module: occupied
/// workspaces as numbers, the current one as a solid circle with its number cut out.
/// Clicking it opens the menu, with the workspaces at the top.
///
/// A click can't go straight to the number under the pointer. On macOS 27 the menu bar
/// draws every item itself and tells the app neither where in the item a click landed (the
/// event always reports the item's centre) nor where the item really is (its window, and
/// Accessibility asked from inside the app, report a stand-in about 50 pt away; asked from
/// another process the answer is right only some of the time). Mapping clicks from any of
/// these went to the wrong workspace, so the strip is an ordinary menu bar item: macOS
/// opens its menu, in the right place.
///
/// The strip is a template image, as Apple asks of menu bar items: macOS colours it like
/// every other icon, with the same vibrancy on any wallpaper. The numbers use the menu
/// bar's own font and sit on the clock's line.
///
/// A workspace with windows minimised or hidden from it has a short bar under its number, so
/// they're never out of mind with the Dock hidden: it says something's there you can't see.
/// Narrower than the digit, so it's not an underline; a bar, as a dot under a 1 reads as "!".
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    struct Model: Equatable {
        struct Chip: Equatable {
            var name: String
            var active: Bool
            /// Windows minimised or hidden from here.
            var away = false
        }
        var chips: [Chip] = []
        /// What's put away and where, as "Hidden on 1: Calculator", by workspace.
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
        // A saved name lets macOS remember where the user ⌘-dragged it.
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
        // Only what's drawn makes a new image; the list put away is only read out.
        let redraw = model.chips != self.model.chips || model.tilingEnabled != self.model.tilingEnabled || model.needsPermission != self.model.needsPermission
        self.model = model
        render(redraw: redraw)
    }

    private func render(redraw: Bool = true) {
        guard let button = item?.button else { return }
        if redraw { button.image = image(model) }
        // What the bars stand for, named for VoiceOver: three at most. Not as a tooltip: macOS 27
        // draws the menu bar's items itself and never shows one.
        let current = model.chips.first(where: \.active).map { "Workspace \($0.name)" }
        let shown = model.away.prefix(3) + (model.away.count > 3 ? ["\(model.away.count - 3) more"] : [])
        button.setAccessibilityValue(([current].compactMap(\.self) + shown).joined(separator: ", "))
    }

    // MARK: Drawing

    /// The strip as an image, for the menu bar.
    func image(_ model: Model) -> NSImage {
        let layout = Self.layout(model)
        let image = NSImage(size: layout.size, flipped: false) { _ in
            Self.draw(model, rects: layout.rects)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// No margins of its own: the status bar spaces items evenly, and a margin baked into
    /// the image would put more air on one side of the strip than its neighbours have.
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
            // Room between slots, so the current circle doesn't crowd the number beside it.
            x += width + 4
        }
        return (NSSize(width: x - 4, height: height), rects)
    }

    /// Drawn in black and clear only: the image is a template, and macOS supplies the colour.
    private static func draw(_ model: Model, rects: [CGRect]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard model.tilingEnabled, !model.needsPermission else {
            // Paused or waiting for permission: a quiet outlined mark instead of workspaces.
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
            // At full strength, like the clock: only workspaces in use are shown, and the circle
            // already says which is current; dimmed, the others read as disabled.
            let middle = WorkspaceMark.draw(chip.name, in: rect, current: chip.active, context: context)
            if chip.away {
                // In a row of its own below every circle, under the number's middle, on whole pixels.
                let scale = max(1, context.userSpaceToDeviceSpaceTransform.a)
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(CGPath(roundedRect: CGRect(x: ((middle - 1.5) * scale).rounded() / scale, y: 0, width: 3, height: 2), cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
                context.fillPath()
            }
        }
    }

    private var menuIsOpen = false
    private var menuClosedAt: ContinuousClock.Instant?
    /// The menu while it's open, for closing it from the keyboard thread (see closeOpenMenu).
    nonisolated private static let openMenu = OSAllocatedUnfairLock<Unchecked<NSMenu>?>(initialState: nil)

    /// The shortcut opens the menu, and closes it again through closeOpenMenu. A press that
    /// reaches the main thread only after the menu has closed was made while it was open,
    /// and is dropped: once, every such press opened the menu again as soon as it closed.
    func toggleMenu(pressedAt: ContinuousClock.Instant = .now) {
        if menuIsOpen {
            item?.menu?.cancelTracking()
        } else if menuClosedAt.map({ pressedAt >= $0 }) ?? true {
            item?.button?.performClick(nil)
        }
    }

    /// Closes the menu if it's open, from any thread, and says whether it was. While a menu
    /// is open the main thread runs only the menu, in a run loop mode of its own, so work
    /// queued for it the usual way waits until the menu has closed. The close is put on the
    /// main run loop in whatever mode it's running right then.
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

    /// The menu is filled in as it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let fresh = menuProvider?() else { return }
        for entry in fresh.items {
            fresh.removeItem(entry)
            menu.addItem(entry)
        }
    }
}

/// A workspace's name as the strip and the menu draw it: the current one a capsule (a circle
/// for one digit) with the name cut out, the HUD's mark; any other the name alone. In black
/// and clear for a template image, which the menu bar or the menu colours.
@MainActor
enum WorkspaceMark {
    /// The menu bar's size, medium weight so a name cut out of the capsule stays legible, with
    /// digits of equal width so the strip doesn't jiggle as workspaces come and go.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
    /// In the 22-point menu bar, centred on the clock's line with room underneath for the bar.
    static let height: CGFloat = 16

    /// A circle for a name that fits in one. A longer name gets a capsule with the room a digit
    /// has in its circle, a quarter of the height a side: the ends curve in only about 1.5
    /// points at the letters' height, so they stay clear.
    static func size(_ name: String) -> CGSize {
        let text = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(width: text + 7 <= height ? height : text + height / 2, height: height)
    }

    /// The name is centred on `rect`'s middle by its ink, so a mark centred there lines up with
    /// it; returns the ink's middle as drawn.
    @discardableResult
    static func draw(_ name: String, in rect: CGRect, current: Bool, context: CGContext) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let width = (name as NSString).size(withAttributes: attributes).width
        let ink = inkOffset(name, font: font)
        let scale = max(1, context.userSpaceToDeviceSpaceTransform.a)
        // Centred on the digits' cap height, the way the clock's numbers sit in the bar, not
        // on the line box, whose room for descenders would lift them.
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

    /// How far a name's visual middle is from the middle of its width: the middle of its ink,
    /// which for most digits is where the eye puts it. Not a 1's: its flag is a thin stroke at
    /// the top, so its ink reaches further left than its weight does, and centred by its ink
    /// a 1 looked right of its circle's middle, its stem a point past it. A name of 1s is
    /// centred on the weight of its ink instead. Centred by weight, the 3, 4 and 7 looked left.
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

    /// The middle of the ink's weight, across: the name drawn eight times over into a mask,
    /// then weighed column by column.
    private static func weightMiddle(_ name: String, font: NSFont, bounds: CGRect) -> CGFloat? {
        let scale: CGFloat = 8
        let width = Int(ceil(bounds.width * scale)) + 2, height = Int(ceil(bounds.height * scale)) + 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // White ink, its left edge a pixel in.
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
