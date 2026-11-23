import AppKit
import ApplicationServices

struct SetupCheck: Identifiable, Equatable, Codable {
    enum Status: String, Equatable, Codable, Comparable {
        case needed
        case recommended
        case optional
        case good

        static func < (a: Status, b: Status) -> Bool {
            allCasesInOrder.firstIndex(of: a)! < allCasesInOrder.firstIndex(of: b)!
        }

        private static let allCasesInOrder: [Status] = [.needed, .recommended, .optional, .good]
    }

    var id: String
    var title: String
    var detail: String
    var status: Status
    var settingsURL: URL?
    var place: String?

    private static func preference(_ key: String, _ domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    private static func bool(_ key: String, _ domain: String, default value: Bool) -> Bool {
        (preference(key, domain) as? NSNumber)?.boolValue ?? value
    }

    static let desktopAndDock = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
    static let privacyAccessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    static let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    static func run() -> [SetupCheck] {
        var checks: [SetupCheck] = []
        let trusted = AXIsProcessTrusted()
        checks.append(SetupCheck(
            id: "accessibility",
            title: trusted ? "Accessibility access is on" : "Turn on Accessibility access",
            detail: trusted ? "Planets can arrange windows." : "Planets can’t move windows without it.",
            status: trusted ? .good : .needed,
            settingsURL: trusted ? nil : privacyAccessibility,
            place: trusted ? nil : "Privacy & Security"
        ))

        if bool("GloballyEnabled", "com.apple.WindowManager", default: false) {
            checks.append(SetupCheck(
                id: "stage-manager",
                title: "Turn off Stage Manager",
                detail: "It moves and shrinks windows itself, which fights the layout.",
                status: .recommended,
                settingsURL: desktopAndDock,
                place: "Desktop & Dock"
            ))
        }

        if bool("EnableTilingByEdgeDrag", "com.apple.WindowManager", default: true) || bool("EnableTopTilingByEdgeDrag", "com.apple.WindowManager", default: true) {
            checks.append(SetupCheck(
                id: "edge-tiling",
                title: "Turn off macOS edge tiling",
                detail: "Switch off both “Drag windows to…” options in the Windows section, or a dragged window jumps twice.",
                status: .recommended,
                settingsURL: desktopAndDock,
                place: "Desktop & Dock"
            ))
        }

        if spaceCounts().contains(where: { $0 > 1 }) {
            checks.append(SetupCheck(
                id: "spaces",
                title: "Remove the extra Spaces",
                detail: "One Space per display works best; workspaces replace them. Remove the rest in Mission Control.",
                status: .recommended,
                settingsURL: missionControl,
                place: "Mission Control"
            ))
        }

        if Spaces.Shortcut(rightward: false) == nil || Spaces.Shortcut(rightward: true) == nil {
            checks.append(SetupCheck(
                id: "space-shortcuts",
                title: "Turn on the Space shortcuts",
                detail: "“Move left a space” and “Move right a space”, under Keyboard Shortcuts › Mission Control. Planets swipes between Spaces itself; these are its fallback if a swipe goes unheeded.",
                status: .optional,
                settingsURL: keyboard,
                place: "Keyboard"
            ))
        }

        if (preference("AppleWindowTabbingMode", "NSGlobalDomain") as? String) == "always" {
            checks.append(SetupCheck(
                id: "tabs",
                title: "New windows open as tabs",
                detail: "That’s fine: a tab group keeps one tile, and the tab in front holds it.",
                status: .good,
                settingsURL: nil
            ))
        }
        return checks.sorted { $0.status < $1.status }
    }

    private static func spaceCounts() -> [Int] {
        guard let configuration = preference("SpacesDisplayConfiguration", "com.apple.spaces") as? [String: Any],
              let management = configuration["Management Data"] as? [String: Any],
              let monitors = management["Monitors"] as? [[String: Any]] else { return [] }
        return monitors.compactMap { ($0["Spaces"] as? [[String: Any]])?.filter { ($0["type"] as? Int ?? 0) == 0 }.count }
    }

    static func report() -> String {
        run().map { check in
            let mark = switch check.status {
            case .needed: "need"
            case .recommended: "rec "
            case .optional: "opt "
            case .good: "ok  "
            }
            return "\(mark) \(check.title)\n     \(check.detail)"
        }.joined(separator: "\n")
    }
}
