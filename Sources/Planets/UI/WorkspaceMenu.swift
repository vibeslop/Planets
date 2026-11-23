import AppKit
import PlanetsCore

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
        let column = rows.map { WorkspaceMark.size($0.name) }.max { $0.width < $1.width } ?? WorkspaceMark.size("")
        for row in rows {
            let text = summary(row)
            let item = MenuTarget.item(text) { choose(row.name) }
            item.image = badge(row.name, current: row.isCurrent, in: column)
            item.attributedTitle = title(text, icon: nil)
            item.setAccessibilityLabel("Workspace \(row.name), \(text)\(row.isCurrent ? ", current" : "")")
            let all = row.apps.map(\.name).joined(separator: ", ")
            if !row.apps.isEmpty, text != all { item.toolTip = all }
            items.append(item)
            let shown = row.away.count > 4 ? 3 : row.away.count
            for away in row.away.prefix(shown) { items.append(awayItem(away, on: row.name, column: column, restore: restore)) }
            if row.away.count > shown {
                let more = NSMenuItem(title: "\(row.away.count - shown) More Windows", action: nil, keyEquivalent: "")
                more.image = NSImage(size: column)
                more.attributedTitle = title(more.title, icon: NSImage(size: NSSize(width: iconSize, height: iconSize)))
                more.setAccessibilityLabel("\(row.away.count - shown) more windows put away on workspace \(row.name)")
                more.submenu = NSMenu()
                for away in row.away.dropFirst(shown) { more.submenu?.addItem(awayItem(away, on: row.name, column: nil, restore: restore)) }
                items.append(more)
            }
        }
        return items
    }

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

    private static func summary(_ row: Row) -> String {
        guard !row.apps.isEmpty else { return row.away.isEmpty ? "Empty" : "All put away" }
        let names = row.apps.map(\.name)
        guard names.count > 3 else { return fitted(names.joined(separator: ", ")) }
        let more = " +\(names.count - 3)"
        return fitted(names.prefix(3).joined(separator: ", "), width: 200 - (more as NSString).size(withAttributes: [.font: font]).width) + more
    }

    private static let font = NSFont.menuFont(ofSize: 0)
    private static let iconSize: CGFloat = 16

    private static func title(_ text: String, icon: NSImage?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if let icon {
            let inset: CGFloat = 1.5
            let attachment = NSTextAttachment()
            attachment.image = NSImage(size: NSSize(width: iconSize - inset, height: iconSize), flipped: false) { _ in
                let scale = max(1, NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2)
                icon.draw(in: CGRect(x: -(inset * scale).rounded() / scale, y: 0, width: iconSize, height: iconSize))
                return true
            }
            attachment.bounds = CGRect(x: 0, y: ((font.capHeight - iconSize) / 2).rounded(), width: iconSize - inset, height: iconSize)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: "  "))
        }
        title.append(NSAttributedString(string: text))
        title.addAttribute(.font, value: font, range: NSRange(location: 0, length: title.length))
        return title
    }

    private static func fitted(_ text: String, width: CGFloat = 200) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measure = { (string: String) in (string as NSString).size(withAttributes: attributes).width }
        let full = measure(text)
        guard full > width else { return text }
        var cut = String(text.prefix(Int(Double(text.count) * Double(width / full))))
        while !cut.isEmpty, measure(cut + "…") > width { cut.removeLast() }
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > cut.count / 2 { cut = String(cut[..<space]) }
        while let last = cut.last, last.isWhitespace || last.isPunctuation || last.isSymbol { cut.removeLast() }
        return cut + "…"
    }

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
