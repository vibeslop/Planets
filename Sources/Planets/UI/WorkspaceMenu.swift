import AppKit
import PlanetsCore

/// The top of the strip's menu: each workspace in use with its apps, so you can see what's
/// where before going there. Windows put away, minimised or hidden with their app, are
/// listed under their workspace, and a click brings one back: with the Dock hidden, this is
/// the way back to a minimised window.
///
/// They're ordinary menu items, so they line up with the rest of the menu, highlight like
/// it, and the arrow keys and Return reach them after ⌥B. The workspace's name sits in the
/// image column, drawn as the strip draws it: the current one a solid circle with its name
/// cut out. A workspace row names its apps without an icon: one icon for several apps reads
/// as the row of the first. A window put away is one app's, so it has its icon, which starts
/// where the names above do.
@MainActor
enum WorkspaceMenu {
    struct Row {
        struct App: Hashable {
            var pid: pid_t
            var name: String
        }
        struct Away {
            var id: WindowID
            var pid: pid_t
            var title: String
            var isMinimized: Bool
        }
        var name: String
        var apps: [App]
        var isCurrent: Bool
        var away: [Away] = []
    }

    static func items(_ rows: [Row], choose: @escaping (String) -> Void, restore: @escaping (WindowID) -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        // A menu sizes each item's image on its own, so every badge gets the widest one's
        // width: a "web" row's apps would otherwise start further right than a "1" row's.
        let column = rows.map { WorkspaceMark.size($0.name) }.max { $0.width < $1.width } ?? WorkspaceMark.size("")
        for row in rows {
            let text = summary(row)
            // Typing in the open menu finds rows by what they show, so an app's name selects its
            // workspace. Not its number: a number in front of every title didn't reliably select
            // the row.
            let item = MenuTarget.item(text) { choose(row.name) }
            item.image = badge(row.name, current: row.isCurrent, in: column)
            item.attributedTitle = title(text, icon: nil)
            item.setAccessibilityLabel("Workspace \(row.name), \(text)\(row.isCurrent ? ", current" : "")")
            // Every app, where the title had to leave some out.
            let all = row.apps.map(\.name).joined(separator: ", ")
            if !row.apps.isEmpty, text != all { item.toolTip = all }
            items.append(item)
            // Up to four put away show here; from five, the three last, and the rest in a submenu.
            let shown = row.away.count > 4 ? 3 : row.away.count
            for away in row.away.prefix(shown) { items.append(awayItem(away, on: row.name, column: column, restore: restore)) }
            if row.away.count > shown {
                let more = NSMenuItem(title: "\(row.away.count - shown) More Windows", action: nil, keyEquivalent: "")
                more.image = NSImage(size: column)
                // Under the windows' titles, past their icons.
                more.attributedTitle = title(more.title, icon: NSImage(size: NSSize(width: iconSize, height: iconSize)))
                more.setAccessibilityLabel("\(row.away.count - shown) more windows put away on workspace \(row.name)")
                more.submenu = NSMenu()
                for away in row.away.dropFirst(shown) { more.submenu?.addItem(awayItem(away, on: row.name, column: nil, restore: restore)) }
                items.append(more)
            }
        }
        return items
    }

    /// A window put away, under its workspace, its icon under the workspace's app names, with
    /// how it was put away beside it. Not faded: a dimmed row in a menu reads as one you can't
    /// click. `column` is the workspace badges' width, left blank; a submenu has nothing to
    /// line up with.
    private static func awayItem(_ away: Row.Away, on workspace: String, column: NSSize?, restore: @escaping (WindowID) -> Void) -> NSMenuItem {
        let text = fitted(away.title)
        let item = MenuTarget.item(away.title) { restore(away.id) }
        if let column { item.image = NSImage(size: column) }
        item.attributedTitle = title(text, icon: AppIcons.icon(for: away.pid))
        item.setAccessibilityLabel("\(away.title), \(away.isMinimized ? "minimised" : "hidden") on workspace \(workspace)")
        item.setAccessibilityHelp("Brings it back")
        item.badge = NSMenuItemBadge(string: away.isMinimized ? "Minimised" : "Hidden")
        if text != away.title { item.toolTip = away.title }
        return item
    }

    /// The apps' names, cut to fit before the count of the rest goes on, so a long name can't
    /// push the count out.
    private static func summary(_ row: Row) -> String {
        // Its windows are all put away, listed just below.
        guard !row.apps.isEmpty else { return row.away.isEmpty ? "Empty" : "All put away" }
        let names = row.apps.map(\.name)
        guard names.count > 3 else { return fitted(names.joined(separator: ", ")) }
        let more = " +\(names.count - 3)"
        return fitted(names.prefix(3).joined(separator: ", "), width: 200 - (more as NSString).size(withAttributes: [.font: font]).width) + more
    }

    private static let font = NSFont.menuFont(ofSize: 0)
    private static let iconSize: CGFloat = 16

    /// An icon, then the text. No colour is set,
    /// so the menu draws the text in its own, white under the highlight.
    private static func title(_ text: String, icon: NSImage?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if let icon {
            // An app icon's art sits about a tenth inside its square. Drawn that far left, with
            // the empty edge trimmed, the art starts where the names above it start.
            let inset: CGFloat = 1.5
            let attachment = NSTextAttachment()
            attachment.image = NSImage(size: NSSize(width: iconSize - inset, height: iconSize), flipped: false) { _ in
                // On whole pixels, or a 1x display draws the icon soft.
                let scale = max(1, NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2)
                icon.draw(in: CGRect(x: -(inset * scale).rounded() / scale, y: 0, width: iconSize, height: iconSize))
                return true
            }
            // Centred on the text's capitals, as an icon beside a label is.
            attachment.bounds = CGRect(x: 0, y: ((font.capHeight - iconSize) / 2).rounded(), width: iconSize - inset, height: iconSize)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: "  "))
        }
        title.append(NSAttributedString(string: text))
        title.addAttribute(.font, value: font, range: NSRange(location: 0, length: title.length))
        return title
    }

    /// A menu is as wide as its longest title, and window titles run long. A title cut short
    /// ends at a word, without a dangling bracket or dash before the ellipsis; the full one
    /// is in the item's tooltip.
    private static func fitted(_ text: String, width: CGFloat = 200) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measure = { (string: String) in (string as NSString).size(withAttributes: attributes).width }
        let full = measure(text)
        guard full > width else { return text }
        // Measured once, then trimmed to fit: characters are near enough the same width.
        var cut = String(text.prefix(Int(Double(text.count) * Double(width / full))))
        while !cut.isEmpty, measure(cut + "…") > width { cut.removeLast() }
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > cut.count / 2 { cut = String(cut[..<space]) }
        // Only from the end: "[Draft] Q3 plan" keeps its bracket.
        while let last = cut.last, last.isWhitespace || last.isPunctuation || last.isSymbol { cut.removeLast() }
        return cut + "…"
    }

    /// The workspace's name as the strip shows it, at the right of `column`, which can be
    /// wider than the name needs: next to its names, as a numbered list lines up. A template,
    /// so the menu colours it like its text and turns it white under the highlight.
    private static func badge(_ name: String, current: Bool, in column: NSSize) -> NSImage {
        let image = NSImage(size: column, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let size = WorkspaceMark.size(name)
            WorkspaceMark.draw(name, in: CGRect(origin: CGPoint(x: column.width - size.width, y: 0), size: size), current: current, context: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = current ? "Workspace \(name), current" : "Workspace \(name)"
        return image
    }
}
