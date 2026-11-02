import CoreGraphics
import Foundation

/// Every action Planets can take. Hotkeys, the menu, and the `planet` CLI all speak this
/// one language, so anything bound to a key can also be scripted.
public enum Command: Equatable, Sendable {
    public enum WorkspaceTarget: Equatable, Sendable {
        case named(String)
        case next, previous
        /// The workspace shown before the current one (i3's back_and_forth).
        case back
    }

    public enum MonitorTarget: Equatable, Sendable {
        case next, previous
        case direction(Direction)
    }

    public enum ResizeAxis: String, Equatable, Sendable {
        case width, height
    }

    public enum Toggle: String, Equatable, Sendable {
        case on, off, toggle
    }

    public enum Query: String, Equatable, Sendable, CaseIterable {
        case windows, workspaces, monitors, focused, performance, apps
    }

    case focus(Direction)
    case focusCycle(forward: Bool)
    case move(Direction)
    case workspace(WorkspaceTarget)
    case moveToWorkspace(WorkspaceTarget, follow: Bool)
    case float(Toggle)
    case zoom(Toggle)
    case toggleSplit
    case resize(ResizeAxis, CGFloat)
    case balance
    case focusMonitor(MonitorTarget)
    case moveToMonitor(MonitorTarget)
    case close
    /// Brings back a minimised or hidden window, onto its workspace: the one named, or else
    /// the one put away last, on the current workspace first.
    case restore(WindowID?)
    case retile
    case reload
    case tiling(Toggle)
    case menuBar(Toggle)
    case scratchpad(Toggle)
    case moveToScratchpad
    case exec(String)
    case query(Query, json: Bool)
    /// Opens Planets when you log in, or stops it.
    case loginItem(Toggle)
}

public struct CommandParseError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

extension Command {
    public static let usage = """
        focus left|right|up|down|next|prev
        move left|right|up|down
        workspace <name>|next|prev|back
        move-to-workspace <name>|next|prev|back [--follow]
        float [on|off|toggle]
        zoom [on|off|toggle]
        toggle-split
        resize width|height <+/-points>
        balance
        focus-monitor next|prev|left|right|up|down
        move-to-monitor next|prev|left|right|up|down
        close
        restore [<window id>]
        retile
        reload
        tiling [on|off|toggle]
        menubar
        scratchpad [on|off|toggle]
        move-to-scratchpad
        exec <shell command>
        login-item [on|off|toggle]
        query windows|workspaces|monitors|focused|apps|performance [--json]
        """

    public static func parse(_ line: String) throws -> Command {
        let words = tokenize(line)
        guard let verb = words.first?.lowercased() else { throw CommandParseError("empty command") }
        let args = Array(words.dropFirst())
        func arg(_ index: Int) -> String? { index < args.count ? args[index] : nil }
        func direction(_ word: String?) throws -> Direction {
            guard let word, let direction = Direction(rawValue: word.lowercased()) else {
                throw CommandParseError("expected left, right, up or down, got \(word.map { "'\($0)'" } ?? "nothing")")
            }
            return direction
        }
        func toggle(_ word: String?) throws -> Toggle {
            guard let word else { return .toggle }
            guard let toggle = Toggle(rawValue: word.lowercased()) else {
                throw CommandParseError("expected on, off or toggle, got '\(word)'")
            }
            return toggle
        }
        func workspaceTarget(_ word: String?) throws -> WorkspaceTarget {
            guard let word else { throw CommandParseError("expected a workspace name") }
            switch word.lowercased() {
            case "next": return .next
            case "prev", "previous": return .previous
            case "back", "back-and-forth": return .back
            default: return .named(word)
            }
        }
        func monitorTarget(_ word: String?) throws -> MonitorTarget {
            switch word?.lowercased() {
            case "next": return .next
            case "prev", "previous": return .previous
            default: return .direction(try direction(word))
            }
        }

        switch verb {
        case "focus":
            switch arg(0)?.lowercased() {
            case "next": return .focusCycle(forward: true)
            case "prev", "previous": return .focusCycle(forward: false)
            default: return .focus(try direction(arg(0)))
            }
        case "move":
            return .move(try direction(arg(0)))
        case "workspace":
            return .workspace(try workspaceTarget(arg(0)))
        case "move-to-workspace", "move-node-to-workspace":
            let follow = args.contains("--follow")
            let target = args.first { $0 != "--follow" }
            return .moveToWorkspace(try workspaceTarget(target), follow: follow)
        case "float", "floating":
            return .float(try toggle(arg(0)))
        case "zoom", "fullscreen":
            return .zoom(try toggle(arg(0)))
        case "toggle-split":
            return .toggleSplit
        case "resize":
            guard let axisWord = arg(0), let axis = ResizeAxis(rawValue: axisWord.lowercased()) else {
                throw CommandParseError("expected width or height")
            }
            // No screen is 10,000 points across; the bound keeps the amount an Int when
            // it's shown.
            guard let amountWord = arg(1), let amount = Double(amountWord), abs(amount) <= 10_000 else {
                throw CommandParseError("expected an amount in points between -10000 and +10000, like +60 or -60")
            }
            return .resize(axis, CGFloat(amount))
        case "balance":
            return .balance
        case "focus-monitor":
            return .focusMonitor(try monitorTarget(arg(0)))
        case "move-to-monitor":
            return .moveToMonitor(try monitorTarget(arg(0)))
        case "close":
            return .close
        case "restore", "unminimize", "unminimise":
            guard let word = arg(0) else { return .restore(nil) }
            guard let id = WindowID(word) else { throw CommandParseError("expected a window id, as `planet query windows` lists them, got '\(word)'") }
            return .restore(id)
        case "retile":
            return .retile
        case "reload":
            return .reload
        case "tiling":
            return .tiling(try toggle(arg(0)))
        case "menubar", "menu-bar":
            return .menuBar(try toggle(arg(0)))
        case "scratchpad":
            return .scratchpad(try toggle(arg(0)))
        case "move-to-scratchpad":
            return .moveToScratchpad
        case "exec":
            // Keep the rest of the line verbatim: quoting belongs to the shell that runs it.
            guard let range = line.range(of: "exec") else { throw CommandParseError("expected a command to run") }
            var rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // `planet exec "open -a Terminal"` arrives quoted as one word; the shell would look for
            // a program named the whole phrase.
            if rest.count >= 2, let first = rest.first, first == "\"" || first == "'", rest.last == first,
               !rest.dropFirst().dropLast().contains(first) {
                rest = String(rest.dropFirst().dropLast())
            }
            guard !rest.isEmpty else { throw CommandParseError("expected a command to run") }
            return .exec(rest)
        case "login-item":
            return .loginItem(try toggle(arg(0)))
        case "query":
            guard let word = arg(0), let query = Query(rawValue: word.lowercased()) else {
                throw CommandParseError("expected one of: \(Query.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .query(query, json: args.contains("--json"))
        default:
            throw CommandParseError("unknown command '\(verb)'")
        }
    }

    /// Parses shell arguments, as the CLI receives them, quoting any that hold spaces.
    public static func parse(arguments: [String]) throws -> Command {
        try parse(arguments.map { $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }.joined(separator: " "))
    }

    /// Splits on whitespace, keeping "quoted strings" together.
    static func tokenize(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for char in line {
            if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

extension Command: CustomStringConvertible {
    public var description: String {
        func target(_ t: WorkspaceTarget) -> String {
            switch t {
            case .named(let name): name
            case .next: "next"
            case .previous: "prev"
            case .back: "back"
            }
        }
        func monitor(_ t: MonitorTarget) -> String {
            switch t {
            case .next: "next"
            case .previous: "prev"
            case .direction(let d): d.rawValue
            }
        }
        switch self {
        case .focus(let d): return "focus \(d.rawValue)"
        case .focusCycle(let forward): return "focus \(forward ? "next" : "prev")"
        case .move(let d): return "move \(d.rawValue)"
        case .workspace(let t): return "workspace \(target(t))"
        case .moveToWorkspace(let t, let follow): return "move-to-workspace \(target(t))\(follow ? " --follow" : "")"
        case .float(let t): return "float \(t.rawValue)"
        case .zoom(let t): return "zoom \(t.rawValue)"
        case .toggleSplit: return "toggle-split"
        case .resize(let axis, let amount): return "resize \(axis.rawValue) \(amount >= 0 ? "+" : "")\(Int(amount))"
        case .balance: return "balance"
        case .focusMonitor(let t): return "focus-monitor \(monitor(t))"
        case .moveToMonitor(let t): return "move-to-monitor \(monitor(t))"
        case .close: return "close"
        case .restore(let id): return "restore" + (id.map { " \($0)" } ?? "")
        case .retile: return "retile"
        case .reload: return "reload"
        case .tiling(let t): return "tiling \(t.rawValue)"
        case .menuBar(let t): return "menubar \(t.rawValue)"
        case .scratchpad(let t): return "scratchpad \(t.rawValue)"
        case .moveToScratchpad: return "move-to-scratchpad"
        case .exec(let command): return "exec \(command)"
        case .query(let q, let json): return "query \(q.rawValue)\(json ? " --json" : "")"
        case .loginItem(let t): return "login-item \(t.rawValue)"
        }
    }
}
