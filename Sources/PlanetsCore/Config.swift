import CoreGraphics
import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)

    public static let hyper: Modifiers = [.command, .option, .control, .shift]
    public static let meh: Modifiers = [.option, .control, .shift]

    /// Parses a single modifier word. `mod` is resolved by the caller.
    public static func named(_ word: String) -> Modifiers? {
        switch word.lowercased() {
        case "cmd", "command", "super", "⌘": .command
        case "alt", "opt", "option", "⌥": .option
        case "ctrl", "control", "⌃": .control
        case "shift", "⇧": .shift
        case "hyper": .hyper
        case "meh": .meh
        default: nil
        }
    }

    /// Symbols in the order macOS menus print them.
    public var symbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A key plus modifiers. Keys are stored by name ("h", "1", "left", "return") and turned
/// into key codes by the app using the current keyboard layout, so bindings follow the
/// letters printed on the keys even on Dvorak or AZERTY.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func parse(_ text: String, mod: Modifiers) throws -> KeyChord {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // "mod+shift++" binds the plus key; an empty last part means the key was "+".
        var key = parts.last ?? ""
        var modifierParts = parts.dropLast()
        if key.isEmpty, parts.count >= 2, parts[parts.count - 2].isEmpty {
            key = "plus"
            modifierParts = modifierParts.dropLast()
        }
        var modifiers: Modifiers = []
        for word in modifierParts where !word.isEmpty {
            if word.lowercased() == "mod" {
                modifiers.formUnion(mod)
            } else if let modifier = Modifiers.named(word) {
                modifiers.formUnion(modifier)
            } else {
                throw ConfigError("unknown modifier '\(word)' in '\(text)'")
            }
        }
        let normalized = KeyNames.normalize(key)
        guard KeyNames.isKnown(normalized) else { throw ConfigError("unknown key '\(key)' in '\(text)'") }
        return KeyChord(key: normalized, modifiers: modifiers)
    }

    public var description: String { modifiers.symbols + KeyNames.symbol(for: key) }
}

public enum KeyNames {
    static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "del": "delete", "backspace": "delete",
        "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash", ";": "semicolon",
        "'": "quote", "`": "grave", "[": "leftbracket", "]": "rightbracket", "\\": "backslash",
        "bracketleft": "leftbracket", "bracketright": "rightbracket", "backtick": "grave",
        "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
    ]

    public static let special: [String] = [
        "return", "tab", "space", "delete", "escape", "left", "right", "up", "down",
        "minus", "equal", "comma", "period", "slash", "semicolon", "quote", "grave",
        "leftbracket", "rightbracket", "backslash", "home", "end", "pageup", "pagedown", "plus",
    ] + (1...20).map { "f\($0)" }

    public static func normalize(_ key: String) -> String {
        let lower = key.lowercased()
        return aliases[lower] ?? lower
    }

    public static func isKnown(_ key: String) -> Bool {
        if key.count == 1, let c = key.unicodeScalars.first, CharacterSet.alphanumerics.contains(c) { return true }
        return special.contains(key)
    }

    public static func symbol(for key: String) -> String {
        switch key {
        case "return": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "delete": "⌫"
        case "escape": "⎋"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "minus": "-"
        case "equal": "="
        case "plus": "+"
        case "comma": ","
        case "period": "."
        case "slash": "/"
        case "semicolon": ";"
        case "quote": "'"
        case "grave": "`"
        case "leftbracket": "["
        case "rightbracket": "]"
        case "backslash": "\\"
        default: key.uppercased()
        }
    }
}

public struct KeyBinding: Equatable, Sendable {
    public var chord: KeyChord
    public var command: Command
}

/// Decides how a matching window is handled. Matches on bundle identifier or app name,
/// and optionally on a substring of the window title.
public struct WindowRule: Equatable, Sendable {
    public var app: String?
    public var title: String?
    public var float: Bool?
    public var workspace: String?
    /// Leaves the window completely alone: never tiled, moved or hidden.
    public var ignore: Bool

    public init(app: String? = nil, title: String? = nil, float: Bool? = nil, workspace: String? = nil, ignore: Bool = false) {
        self.app = app
        self.title = title
        self.float = float
        self.workspace = workspace
        self.ignore = ignore
    }

    public func matches(bundleID: String?, appName: String, title windowTitle: String) -> Bool {
        if let app {
            let lower = app.lowercased()
            guard bundleID?.lowercased() == lower || appName.lowercased() == lower else { return false }
        }
        if let title, !windowTitle.localizedCaseInsensitiveContains(title) { return false }
        return app != nil || title != nil
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct Config: Equatable, Sendable {
    public var workspaces: [String] = (1...9).map(String.init)
    /// Workspace name to display: "main", "secondary", a position ("2"), or part of a name.
    public var workspaceMonitors: [String: String] = [:]
    public var layout = LayoutSettings()
    public var mod: Modifiers = .option
    public var bindings: [KeyBinding] = []
    public var rules: [WindowRule] = Config.defaultRules
    /// Apps never managed, by bundle identifier or name.
    public var ignoredApps: [String] = []
    /// When set, only these apps are managed. Meant for trying Planets out on a few apps.
    public var onlyApps: [String]? = nil

    public var focusGlow = true
    public var glowIntensity: Double = 0.7
    public var glowColor: GlowColor = .gold
    /// Off by default: the strip in the menu bar already says where you are, and a switch
    /// should change the windows and nothing else.
    public var workspaceHUD = false
    public var dragToSwap = true
    /// Holding these modifiers lets you drag any window from anywhere inside it. Not plain
    /// Option: Option-drag is column selection in code editors and terminals.
    public var mouseModifier: Modifiers = [.control, .option]
    public var focusFollowsMouse = false

    public init() {
        bindings = Config.defaultBindings(mod: mod)
    }

    public static let defaultRules: [WindowRule] = [
        WindowRule(app: "com.apple.systempreferences", float: true),
        WindowRule(app: "com.apple.calculator", float: true),
        WindowRule(app: "com.apple.archiveutility", float: true),
        WindowRule(app: "com.apple.ActivityMonitor", title: "CPU Load", float: true),
        WindowRule(app: "com.raycast.macos", ignore: true),
    ]

    /// Default keys. Option is the modifier, as in AeroSpace, but the letters macOS uses
    /// for accent dead keys on the US layout (e, i, u, n and `) are left free, so typing
    /// é or ñ keeps working.
    public static let defaultBindingTable: [(String, String)] = {
        var table: [(String, String)] = [
            ("mod+h", "focus left"), ("mod+j", "focus down"), ("mod+k", "focus up"), ("mod+l", "focus right"),
            ("mod+shift+h", "move left"), ("mod+shift+j", "move down"), ("mod+shift+k", "move up"), ("mod+shift+l", "move right"),
        ]
        for n in 1...9 {
            table.append(("mod+\(n)", "workspace \(n)"))
            table.append(("mod+shift+\(n)", "move-to-workspace \(n)"))
        }
        table += [
            ("mod+tab", "workspace back"),
            ("mod+leftbracket", "workspace prev"), ("mod+rightbracket", "workspace next"),
            ("mod+f", "zoom toggle"),
            ("mod+shift+space", "float toggle"),
            ("mod+t", "toggle-split"),
            ("mod+minus", "resize width -60"), ("mod+equal", "resize width +60"),
            ("mod+shift+minus", "resize height -60"), ("mod+shift+equal", "resize height +60"),
            ("mod+0", "balance"),
            ("mod+comma", "focus-monitor prev"), ("mod+period", "focus-monitor next"),
            ("mod+shift+comma", "move-to-monitor prev"), ("mod+shift+period", "move-to-monitor next"),
            ("mod+shift+q", "close"),
            ("mod+shift+m", "restore"),  // the window minimised or hidden last, with no Dock to click
            ("mod+shift+c", "reload"),
            ("mod+b", "menubar"),  // opens the workspace menu
            ("mod+x", "scratchpad toggle"), ("mod+shift+x", "move-to-scratchpad"),
        ]
        return table
    }()

    /// The arrows do what H J K L do, but only when the modifier is a combination such as
    /// Control–Option or Hyper. Option, Command or Control alone with an arrow is how
    /// macOS moves the cursor by word, by line or between Spaces, and a binding would take
    /// that away in every app.
    public static let arrowBindingTable: [(String, String)] = [
        ("mod+left", "focus left"), ("mod+down", "focus down"), ("mod+up", "focus up"), ("mod+right", "focus right"),
        ("mod+shift+left", "move left"), ("mod+shift+down", "move down"), ("mod+shift+up", "move up"), ("mod+shift+right", "move right"),
    ]

    public static func defaultBindings(mod: Modifiers) -> [KeyBinding] {
        let modifierCount = [Modifiers.command, .option, .control, .shift].filter { mod.contains($0) }.count
        let table = defaultBindingTable + (modifierCount > 1 ? arrowBindingTable : [])
        return table.compactMap { chord, command in
            guard let chord = try? KeyChord.parse(chord, mod: mod), let command = try? Command.parse(command) else { return nil }
            return KeyBinding(chord: chord, command: command)
        }
    }

    public func rule(bundleID: String?, appName: String, title: String) -> WindowRule? {
        // Later rules win, so a user's rule overrides a built-in one for the same app.
        rules.last { $0.matches(bundleID: bundleID, appName: appName, title: title) }
    }

    public func manages(bundleID: String?, appName: String) -> Bool {
        let names = [bundleID?.lowercased(), appName.lowercased()].compactMap { $0 }
        if ignoredApps.contains(where: { names.contains($0.lowercased()) }) { return false }
        if let onlyApps { return onlyApps.contains { names.contains($0.lowercased()) } }
        return true
    }
}

extension Config {
    /// Why a list of workspace names can't be used, if it can't. The config file and the
    /// names field in Settings check the same.
    public static func workspaceNamesProblem(_ names: [String]) -> String? {
        if names.isEmpty { return "there has to be at least one name" }
        // The scratchpad's workspace is hidden; one named so would vanish with it.
        if names.contains(World.scratchpad) { return "“\(World.scratchpad)” is the scratchpad’s own name" }
        return Set(names).count == names.count ? nil : "each name can be used only once"
    }

    /// Reads a config file. Unknown keys are reported as warnings rather than errors so an
    /// older Planets can still start with a newer file.
    public static func parse(_ text: String) throws -> (config: Config, warnings: [String]) {
        let root = try TOML.parse(text)
        var config = Config()
        var warnings: [String] = []

        func check(_ table: [String: TOMLValue], _ name: String, known: Set<String>) {
            for key in table.keys.sorted() where !known.contains(key) {
                warnings.append("[\(name)] has an unknown key '\(key)'")
            }
        }

        for key in root.keys.sorted() where !["general", "tiling", "workspaces", "appearance", "mouse", "keys", "rule"].contains(key) {
            warnings.append("unknown section '\(key)'")
        }

        if let general = root["general"]?.table {
            check(general, "general", known: ["mod", "ignore", "only"])
            if let mod = general["mod"]?.string {
                var modifiers: Modifiers = []
                for word in mod.split(separator: "+") {
                    guard let modifier = Modifiers.named(String(word)) else { throw ConfigError("[general] mod: unknown modifier '\(word)'") }
                    modifiers.formUnion(modifier)
                }
                config.mod = modifiers
            }
            if let ignore = general["ignore"]?.strings { config.ignoredApps = ignore }
            if let only = general["only"]?.strings { config.onlyApps = only.isEmpty ? nil : only }
        }

        if let tiling = root["tiling"]?.table {
            check(tiling, "tiling", known: ["gaps", "inner_gap", "outer_gap", "smart_gaps"])
            if let gaps = tiling["gaps"]?.double { config.layout.innerGap = CGFloat(max(0, gaps)); config.layout.outerGap = CGFloat(max(0, gaps)) }
            if let inner = tiling["inner_gap"]?.double { config.layout.innerGap = CGFloat(max(0, inner)) }
            if let outer = tiling["outer_gap"]?.double { config.layout.outerGap = CGFloat(max(0, outer)) }
            if let smart = tiling["smart_gaps"]?.bool { config.layout.smartGaps = smart }
        }

        if let workspaces = root["workspaces"]?.table {
            check(workspaces, "workspaces", known: ["names", "monitors"])
            if let pins = workspaces["monitors"]?.table {
                config.workspaceMonitors = pins.compactMapValues { $0.string ?? $0.int.map(String.init) }
            }
            if let names = workspaces["names"]?.array {
                let parsed = names.compactMap { $0.string ?? $0.int.map(String.init) }
                if let problem = Config.workspaceNamesProblem(parsed) { throw ConfigError("[workspaces] names: \(problem)") }
                config.workspaces = parsed
            }
        }

        if let appearance = root["appearance"]?.table {
            check(appearance, "appearance", known: ["focus_glow", "glow_intensity", "glow_color", "workspace_hud"])
            if let raw = appearance["glow_color"]?.string {
                if let color = GlowColor(rawValue: raw.lowercased()) { config.glowColor = color } else {
                    warnings.append("[appearance] glow_color: expected gold, accent or neutral, got \"\(raw)\"")
                }
            }
            if let glow = appearance["focus_glow"]?.bool { config.focusGlow = glow }
            if let intensity = appearance["glow_intensity"]?.double { config.glowIntensity = intensity.clamped(to: 0...1) }
            if let hud = appearance["workspace_hud"]?.bool { config.workspaceHUD = hud }
        }

        if let mouse = root["mouse"]?.table {
            check(mouse, "mouse", known: ["drag_to_swap", "modifier", "focus_follows_mouse"])
            if let drag = mouse["drag_to_swap"]?.bool { config.dragToSwap = drag }
            if let follows = mouse["focus_follows_mouse"]?.bool { config.focusFollowsMouse = follows }
            if let modifier = mouse["modifier"]?.string {
                var modifiers: Modifiers = []
                for word in modifier.split(separator: "+") {
                    if word.lowercased() == "mod" { modifiers.formUnion(config.mod); continue }
                    guard let parsed = Modifiers.named(String(word)) else { throw ConfigError("[mouse] modifier: unknown modifier '\(word)'") }
                    modifiers.formUnion(parsed)
                }
                config.mouseModifier = modifiers
            }
        }

        // Keys are resolved after [general] so "mod" means the configured modifier.
        config.bindings = Config.defaultBindings(mod: config.mod)
        if let keys = root["keys"]?.table {
            var byChord: [KeyChord: Int] = [:]
            for (index, binding) in config.bindings.enumerated() { byChord[binding.chord] = index }
            var removed = Set<Int>()
            for (chordText, value) in keys.sorted(by: { $0.key < $1.key }) {
                let chord = try KeyChord.parse(chordText, mod: config.mod)
                guard let commandText = value.string else { throw ConfigError("[keys] \(chordText): expected a command in quotes") }
                if commandText.isEmpty || commandText == "none" {
                    // An empty command unbinds a default key.
                    if let index = byChord[chord] { removed.insert(index) }
                    continue
                }
                let command: Command
                do { command = try Command.parse(commandText) } catch { throw ConfigError("[keys] \(chordText): \(error)") }
                if let index = byChord[chord] {
                    config.bindings[index].command = command
                    removed.remove(index)
                } else {
                    byChord[chord] = config.bindings.count
                    config.bindings.append(KeyBinding(chord: chord, command: command))
                }
            }
            config.bindings = config.bindings.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }

        if let rules = root["rule"]?.array {
            for (index, value) in rules.enumerated() {
                guard let table = value.table else { continue }
                check(table, "rule \(index + 1)", known: ["app", "title", "float", "workspace", "ignore"])
                let rule = WindowRule(
                    app: table["app"]?.string,
                    title: table["title"]?.string,
                    float: table["float"]?.bool,
                    workspace: table["workspace"]?.string ?? table["workspace"]?.int.map(String.init),
                    ignore: table["ignore"]?.bool ?? false
                )
                guard rule.app != nil || rule.title != nil else {
                    warnings.append("rule \(index + 1) matches nothing: give it an app or a title")
                    continue
                }
                config.rules.append(rule)
            }
        }
        return (config, warnings)
    }

    /// The file written on first launch. Every setting is present and commented so the
    /// file doubles as documentation.
    public static let defaultFileContents = """
        # Planets configuration
        # Saved changes apply immediately. A mistake keeps the last working version running
        # and shows the error in the menu.

        [general]
        # The modifier that "mod" stands for in [keys]: option, command, control, shift,
        # or a combination like "control+option". "hyper" is all four.
        mod = "option"
        # Apps Planets never touches, by bundle identifier or name.
        ignore = []
        # Manage only these apps. Handy for a first try; leave empty to manage everything.
        only = []

        [tiling]
        # Every new window splits the focused one along its longer side (dwindle).
        inner_gap = 10
        outer_gap = 10
        # Drop the gaps when a workspace holds one window.
        smart_gaps = false

        [workspaces]
        names = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        # Pin workspaces to displays: "main", "secondary", a position from the left ("2"),
        # or part of the display's name. Example: { "6" = "secondary", "9" = "Studio Display" }
        monitors = {}

        [appearance]
        # A thin line of light just outside the focused window, with a soft haze around it.
        focus_glow = true
        glow_intensity = 0.7
        # Its colour: "gold", "accent" (your macOS accent colour) or "neutral" (white on a
        # dark Mac, graphite on a light one).
        glow_color = "gold"
        # A small overlay that shows where you are when you switch workspaces.
        workspace_hud = false

        [mouse]
        # Drop a tiled window onto another to swap them.
        drag_to_swap = true
        # Hold this and drag anywhere in a window to move it. Option alone would take over
        # column selection in editors, so the default adds Control.
        modifier = "control+option"
        focus_follows_mouse = false

        [keys]
        # Override or add bindings: "chord" = "command". Set a chord to "none" to unbind it.
        # Run `planet help` for every command.
        # "mod+return" = "exec open -na Terminal"

        # Rules match an app by bundle identifier or name, and optionally a window title.
        # [[rule]]
        # app = "com.apple.finder"
        # float = true
        #
        # [[rule]]
        # app = "Mail"
        # workspace = "3"

        """
}

/// The colour of the light around the focused window.
public enum GlowColor: String, CaseIterable, Sendable {
    /// The brand's gold.
    case gold
    /// The accent colour chosen in macOS's settings.
    case accent
    /// No colour: white light on a dark Mac, graphite on a light one, so it shows on both.
    case neutral
}
