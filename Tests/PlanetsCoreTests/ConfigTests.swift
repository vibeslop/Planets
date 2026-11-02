import Foundation
import Testing
@testable import PlanetsCore

@Suite struct TOMLTests {
    @Test func parsesTablesArraysAndInlineTables() throws {
        let doc = try TOML.parse("""
            # comment
            title = "Planets" # trailing
            [tiling]
            gaps = 8
            ratio = 0.5
            names = [
              "1", "2",  # comment inside
              'three',
            ]
            point = { x = 1, y = -2 }
            [[rule]]
            app = "a"
            [[rule]]
            app = "b"
            float = true
            [deep.er]
            "quoted key" = "\\u00e9t\\u00e9"
            """)
        #expect(doc["title"] == .string("Planets"))
        #expect(doc["tiling"]?.table?["gaps"] == .integer(8))
        #expect(doc["tiling"]?.table?["ratio"] == .float(0.5))
        #expect(doc["tiling"]?.table?["names"]?.strings == ["1", "2", "three"])
        #expect(doc["tiling"]?.table?["point"]?.table?["y"] == .integer(-2))
        #expect(doc["rule"]?.array?.count == 2)
        #expect(doc["rule"]?.array?[1].table?["float"] == .bool(true))
        #expect(doc["deep"]?.table?["er"]?.table?["quoted key"] == .string("été"))
    }

    @Test func reportsTheLineOfAnError() {
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1\nb = \n") }
        do {
            _ = try TOML.parse("a = 1\n\nb = [1, 2\nc = 3")
            Issue.record("expected an error")
        } catch let error as TOMLError {
            #expect(error.line == 4)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func rejectsDuplicateKeys() {
        #expect(throws: TOMLError.self) { try TOML.parse("a = 1\na = 2") }
    }

    @Test func editorReplacesValuesAndKeepsComments() throws {
        let text = """
            [tiling]
            # gap between windows
            inner_gap = 10  # points
            outer_gap = 10

            [menubar]
            hidden = []
            """
        var edited = TOMLEditor.setting(.integer(14), table: "tiling", key: "inner_gap", in: text)
        #expect(edited.contains("inner_gap = 14  # points"))
        #expect(edited.contains("# gap between windows"))
        edited = TOMLEditor.setting(.array([.string("com.example.app")]), table: "menubar", key: "hidden", in: edited)
        #expect(edited.contains("hidden = [\"com.example.app\"]"))
        edited = TOMLEditor.setting(.bool(true), table: "tiling", key: "smart_gaps", in: edited)
        edited = TOMLEditor.setting(.bool(false), table: "appearance", key: "focus_glow", in: edited)
        let doc = try TOML.parse(edited)
        #expect(doc["tiling"]?.table?["smart_gaps"] == .bool(true))
        #expect(doc["tiling"]?.table?["outer_gap"] == .integer(10))
        #expect(doc["appearance"]?.table?["focus_glow"] == .bool(false))
    }
}

@Suite struct ConfigTests {
    @Test func defaultFileParsesCleanly() throws {
        let (config, warnings) = try Config.parse(Config.defaultFileContents)
        #expect(warnings.isEmpty)
        #expect(config == Config())
    }

    @Test func modChangesEveryDefaultBinding() throws {
        let (config, _) = try Config.parse("[general]\nmod = \"control+option\"")
        let focusLeft = config.bindings.first { $0.command == .focus(.left) }
        #expect(focusLeft?.chord == KeyChord(key: "h", modifiers: [.control, .option]))
    }

    @Test func keysOverrideAddAndUnbind() throws {
        let (config, _) = try Config.parse("""
            [keys]
            "mod+h" = "focus right"
            "mod+return" = "exec open -na Terminal"
            "mod+b" = "none"
            """)
        #expect(config.bindings.first { $0.chord == KeyChord(key: "h", modifiers: .option) }?.command == .focus(.right))
        #expect(config.bindings.contains { $0.command == .exec("open -na Terminal") })
        #expect(!config.bindings.contains { $0.chord == KeyChord(key: "b", modifiers: .option) })
    }

    @Test func rulesMatchByBundleOrName() throws {
        let (config, _) = try Config.parse("""
            [[rule]]
            app = "Mail"
            workspace = 3
            """)
        let rule = config.rule(bundleID: "com.apple.mail", appName: "Mail", title: "Inbox")
        #expect(rule?.workspace == "3")
        #expect(config.rule(bundleID: "com.apple.systempreferences", appName: "System Settings", title: "")?.float == true)
    }

    @Test func badValuesExplainThemselves() {
        #expect(throws: ConfigError.self) { try Config.parse("[general]\nmod = \"banana\"") }
        #expect(throws: ConfigError.self) { try Config.parse("[keys]\n\"mod+h\" = \"fly away\"") }
        #expect(throws: ConfigError.self) { try Config.parse("[keys]\n\"mod+banana\" = \"balance\"") }
        // The scratchpad's workspace is hidden; one named so would vanish with it.
        #expect(throws: ConfigError.self) { try Config.parse("[workspaces]\nnames = [\"1\", \"scratchpad\"]") }
    }

    @Test func unknownKeysWarn() throws {
        let (_, warnings) = try Config.parse("[tiling]\ngapz = 3\n[colors]\nx = 1")
        #expect(warnings.count == 2)
    }

    @Test func onlyAndIgnore() throws {
        let (config, _) = try Config.parse("[general]\nonly = [\"dev.levelorbit.fixture\"]\nignore = [\"Finder\"]")
        #expect(config.manages(bundleID: "dev.levelorbit.fixture", appName: "Fixture"))
        #expect(!config.manages(bundleID: "com.apple.Safari", appName: "Safari"))
        #expect(!config.manages(bundleID: "com.apple.finder", appName: "Finder"))
    }
}

@Suite struct CommandTests {
    @Test func roundTrips() throws {
        let lines = [
            "focus left", "focus next", "move down", "workspace 3", "workspace back", "move-to-workspace web --follow",
            "float toggle", "zoom on", "toggle-split", "resize width +60",
            "resize height -40", "balance", "focus-monitor next", "move-to-monitor left", "close",
            "restore", "restore 4182", "retile", "reload", "tiling off", "menubar toggle", "scratchpad toggle", "move-to-scratchpad", "query windows --json",
        ]
        for line in lines {
            let command = try Command.parse(line)
            #expect(command.description == line)
            #expect(try Command.parse(command.description) == command)
        }
    }

    @Test func execKeepsTheRestVerbatim() throws {
        #expect(try Command.parse("exec open -na 'Some App' --args --incognito") == .exec("open -na 'Some App' --args --incognito"))
    }

    @Test func execFromTheCommandLineRunsTheWholeCommand() throws {
        #expect(try Command.parse(arguments: ["exec", "touch /tmp/x"]) == .exec("touch /tmp/x"))
        #expect(try Command.parse("exec 'open' -a 'Foo'") == .exec("'open' -a 'Foo'"))
    }

    @Test func optionArrowsStillMoveByWord() {
        for mod: Modifiers in [.option, .command, .control] {
            let keys = Config.defaultBindings(mod: mod).map(\.chord.key)
            #expect(!keys.contains { ["left", "right", "up", "down"].contains($0) })
        }
    }

    @Test func aMinimisedWindowComesBackWithoutTheDock() {
        let binding = Config.defaultBindings(mod: .option).first { $0.command == .restore(nil) }
        #expect(binding?.chord == (try? KeyChord.parse("mod+shift+m", mod: .option)))
    }

    @Test func errorsAreReadable() {
        #expect(throws: CommandParseError("unknown command 'jump'")) { try Command.parse("jump") }
        #expect(throws: CommandParseError.self) { try Command.parse("focus sideways") }
        #expect(throws: CommandParseError.self) { try Command.parse("restore Safari") }
    }
}

@Suite struct ShortcutSummaryTests {
    @Test func collapsesFamilies() {
        let rows = ShortcutSummary.rows(for: Config.defaultBindings(mod: .option))
        let workspaces = rows.first { $0.title == "Go to workspace" }
        #expect(workspaces?.chords == ["⌥ 1–9"])
        let send = rows.first { $0.title == "Send window to workspace" }
        #expect(send?.chords == ["⌥⇧ 1–9"])
        let focus = rows.first { $0.title == "Focus neighbouring window" }
        #expect(focus?.chords == ["⌥ H J K L"])
        #expect(rows.first?.category == "Workspaces")
    }

    @Test func arrowsJoinTheLettersUnderACombinedModifier() {
        let rows = ShortcutSummary.rows(for: Config.defaultBindings(mod: [.control, .option]))
        let focus = rows.first { $0.title == "Focus neighbouring window" }
        #expect(focus?.chords == ["⌃⌥ H J K L", "⌃⌥ ← ↓ ↑ →"])
    }

    /// ⌥0 for workspace 10 puts 0 after 9; that list isn't a run, and once crashed the menu.
    @Test func numbersOutOfOrderStayListed() throws {
        let (config, _) = try Config.parse("""
            [keys]
            "mod+0" = "workspace 10"
            """)
        let workspaces = ShortcutSummary.rows(for: config.bindings).first { $0.title == "Go to workspace" }
        #expect(workspaces?.chords == ["⌥ 1 2 3 4 5 6 7 8 9 0"])
        #expect(ShortcutSummary.compact(["9", "8", "7"]) == "9 8 7")
        #expect(ShortcutSummary.compact(["\(Int.max)", "1", "2"]) == "\(Int.max) 1 2")
    }
}

/// Numbers a config can hold but Swift can't turn into what Planets needs once crashed it,
/// at launch, in `planet config check`, or when the menu opened.
@Suite struct OutOfRangeTests {
    @Test func aNumberTooLargeToStoreIsAnError() {
        #expect(throws: TOMLError.self) { try TOML.parse("gaps = 1e400") }
        #expect(throws: TOMLError.self) { try TOML.parse("gaps = -1e400") }
        #expect(throws: TOMLError.self) { try Config.parse("[tiling]\ngaps = 1e400") }
    }

    @Test func aWholeFloatTooLargeForAnIntIsNoInt() {
        #expect(TOMLValue.float(1e300).int == nil)
        #expect(TOMLValue.float(3.0).int == 3)
        #expect(TOMLValue.float(3.5).int == nil)
    }

    @Test func workspaceNamesFromHugeNumbersDontCrash() throws {
        _ = try? Config.parse("[workspaces]\nnames = [1e300]\nmonitors = { a = 1e300 }")
    }

    @Test func resizeAmountIsBounded() throws {
        #expect(throws: CommandParseError.self) { try Command.parse("resize width 1e30") }
        #expect(throws: CommandParseError.self) { try Command.parse("resize width nan") }
        #expect(throws: ConfigError.self) { try Config.parse("[keys]\n\"mod+r\" = \"resize width 1e30\"") }
        let command = try Command.parse("resize width -10000")
        #expect(command.title == "Narrower by 10000 points")
        #expect(command.description == "resize width -10000")
    }

    @Test func negativeGapsAreZero() throws {
        let (config, _) = try Config.parse("[tiling]\ngaps = -50")
        #expect(config.layout.innerGap == 0)
        #expect(config.layout.outerGap == 0)
    }
}

@Suite struct ReleaseTests {
    let json = Data("""
        {"tag_name": "v0.2.0", "draft": false, "body": null,
         "assets": [
            {"name": "Planets-0.2.0-macos.zip", "size": 5,
             "browser_download_url": "https://github.com/vibeslop/Planets/releases/download/v0.2.0/Planets-0.2.0-macos.zip"},
            {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"}
         ]}
        """.utf8)

    @Test func versionsCompareNumberByNumber() {
        #expect(Version("0.10.0")! > Version("0.9.0")!)
        #expect(Version("v1.2")! == Version("1.2.0")!)
        #expect(Version("1.2.3")!.description == "1.2.3")
        for bad in ["", "v", "1.2.3.4", "1.2-beta", "1..2", "-1.0", "１.0"] { #expect(Version(bad) == nil) }
    }

    @Test func aNewerReleaseIsAnUpdate() throws {
        let release = try JSONDecoder().decode(Release.self, from: json)
        let update = release.update(after: Version("0.1.0")!)
        #expect(update?.version == Version("0.2.0"))
        #expect(update?.archive.lastPathComponent == "Planets-0.2.0-macos.zip")
    }

    @Test func theSameOrAnOlderReleaseIsNot() throws {
        let release = try JSONDecoder().decode(Release.self, from: json)
        #expect(release.update(after: Version("0.2.0")!) == nil)
        #expect(release.update(after: Version("0.3.0")!) == nil)
    }

    /// The workflow creates the release before it attaches the archive.
    @Test func aReleaseWithoutItsArchiveIsNot() throws {
        let release = try JSONDecoder().decode(Release.self, from: Data(#"{"tag_name": "v9.0.0", "assets": []}"#.utf8))
        #expect(release.update(after: Version("0.1.0")!) == nil)
    }

    @Test func autoUpdateIsOnUnlessTurnedOff() throws {
        #expect(try Config.parse(Config.defaultFileContents).config.autoUpdate)
        #expect(try !Config.parse("[general]\nauto_update = false").config.autoUpdate)
    }
}
