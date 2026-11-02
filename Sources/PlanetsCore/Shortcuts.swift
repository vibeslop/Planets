import Foundation

extension Command {
    /// A sentence-case description for menus and the shortcuts list.
    public var title: String {
        func workspace(_ target: WorkspaceTarget) -> String {
            switch target {
            case .named(let name): "workspace \(name)"
            case .next: "next workspace"
            case .previous: "previous workspace"
            case .back: "last workspace"
            }
        }
        func monitor(_ target: MonitorTarget) -> String {
            switch target {
            case .next: "next monitor"
            case .previous: "previous monitor"
            case .direction(let d): "monitor \(d == .left ? "to the left" : d == .right ? "to the right" : d == .up ? "above" : "below")"
            }
        }
        switch self {
        case .focus: return "Focus neighbouring window"
        case .focusCycle(let forward): return forward ? "Focus next window" : "Focus previous window"
        case .move: return "Swap with neighbouring window"
        case .workspace(let target): return "Go to \(workspace(target))"
        case .moveToWorkspace(let target, let follow): return "Send window to \(workspace(target))\(follow ? " and follow" : "")"
        case .float: return "Float or tile window"
        case .zoom: return "Zoom window"
        case .toggleSplit: return "Flip split direction"
        case .resize(let axis, let amount): return "\(amount < 0 ? (axis == .width ? "Narrower" : "Shorter") : (axis == .width ? "Wider" : "Taller")) by \(Int(abs(amount))) points"
        case .balance: return "Even out sizes"
        case .focusMonitor(let target): return "Focus \(monitor(target))"
        case .moveToMonitor(let target): return "Send window to \(monitor(target))"
        case .close: return "Close window"
        case .restore: return "Bring back a minimised window"
        case .retile: return "Re-tile everything"
        case .reload: return "Reload config"
        case .tiling: return "Turn tiling on or off"
        case .menuBar: return "Open the workspace menu"
        case .scratchpad: return "Show or hide the scratchpad"
        case .moveToScratchpad: return "Send window to the scratchpad"
        case .exec(let line): return "Run \(line)"
        case .query(let query, _): return "Query \(query.rawValue)"
        case .loginItem: return "Open at login on or off"
        }
    }

    public var category: String {
        switch self {
        case .focus, .focusCycle: "Focus"
        case .move, .float, .zoom, .close, .restore: "Windows"
        case .workspace, .moveToWorkspace, .scratchpad, .moveToScratchpad: "Workspaces"
        case .toggleSplit, .resize, .balance: "Layout"
        case .focusMonitor, .moveToMonitor: "Monitors"
        default: "Other"
        }
    }
}

/// A line in the shortcuts list. Families of bindings that differ only by direction or
/// number collapse into one line, so nine workspace keys read as "⌥ 1–9".
public struct ShortcutRow: Equatable, Sendable, Identifiable {
    public var title: String
    public var category: String
    /// Each entry is a modifier group followed by its keys, like "⌥ H J K L".
    public var chords: [String]
    public var id: String { category + title }
}

public enum ShortcutSummary {
    public static let categoryOrder = ["Workspaces", "Focus", "Windows", "Layout", "Monitors", "Other"]

    public static func rows(for bindings: [KeyBinding]) -> [ShortcutRow] {
        var families: [String: (title: String, category: String, members: [(KeyBinding, Int)])] = [:]
        var order: [String] = []
        for binding in bindings {
            let (key, title, rank) = family(of: binding.command)
            if families[key] == nil {
                families[key] = (title, binding.command.category, [])
                order.append(key)
            }
            families[key]!.members.append((binding, rank))
        }
        let rows = order.map { key -> ShortcutRow in
            let family = families[key]!
            var groups: [Modifiers: [(String, Int)]] = [:]
            var groupOrder: [Modifiers] = []
            for (binding, rank) in family.members {
                if groups[binding.chord.modifiers] == nil { groupOrder.append(binding.chord.modifiers) }
                groups[binding.chord.modifiers, default: []].append((KeyNames.symbol(for: binding.chord.key), rank))
            }
            let chords = groupOrder.flatMap { modifiers -> [String] in
                let keys = groups[modifiers]!.sorted { $0.1 < $1.1 }.map(\.0)
                return split(keys).map { "\(modifiers.symbols) \(compact($0))" }
            }
            return ShortcutRow(title: family.title, category: family.category, chords: chords)
        }
        return rows.sorted { (categoryOrder.firstIndex(of: $0.category) ?? 99) < (categoryOrder.firstIndex(of: $1.category) ?? 99) }
    }

    /// Groups commands that belong on one line, with a rank that orders their keys.
    static func family(of command: Command) -> (key: String, title: String, rank: Int) {
        let directionRank: [Direction: Int] = [.left: 0, .down: 1, .up: 2, .right: 3]
        switch command {
        case .focus(let d): return ("focus", "Focus neighbouring window", directionRank[d]!)
        case .move(let d): return ("move", "Swap with neighbouring window", directionRank[d]!)
        case .workspace(.named(let name)) where Int(name) != nil:
            return ("workspace#", "Go to workspace", Int(name)!)
        case .moveToWorkspace(.named(let name), let follow) where Int(name) != nil:
            return ("send#\(follow)", follow ? "Send window to workspace and follow" : "Send window to workspace", Int(name)!)
        default:
            return (command.description, command.title, 0)
        }
    }

    /// Letters and arrows read best as separate groups: "H J K L" and "← ↓ ↑ →".
    static func split(_ keys: [String]) -> [[String]] {
        let arrows = keys.filter { ["←", "↓", "↑", "→"].contains($0) }
        let rest = keys.filter { !arrows.contains($0) }
        return [rest, arrows].filter { !$0.isEmpty }
    }

    /// Runs of consecutive digits become ranges: 1 2 3 … 9 is "1–9".
    static func compact(_ keys: [String]) -> String {
        let numbers = keys.compactMap(Int.init)
        let consecutive = zip(numbers, numbers.dropFirst()).allSatisfy { $0 < Int.max && $1 == $0 + 1 }
        if numbers.count == keys.count, numbers.count > 2, consecutive {
            return "\(numbers.first!)–\(numbers.last!)"
        }
        return keys.joined(separator: " ")
    }
}
