import Foundation
import PlanetsCore

// `planet`: drives Planets from the shell. Every hotkey command works here too, so
// window management can be scripted, bound in other tools, or tested.

let arguments = Array(CommandLine.arguments.dropFirst())

// Started by Planets itself, not a command for people: see Lifecycle in the app.
if arguments.count == 2, arguments[0] == "_watch" {
    let started = ContinuousClock.now
    var byte: UInt8 = 0
    guard read(0, &byte, 1) == 1 else { exit(0) }
    let ranFor = ContinuousClock.now - started
    // Planets is still going, in its crash handler or on its way out; it's gone, and its
    // lock with it, once the pipe ends.
    var rest: UInt8 = 0
    while read(0, &rest, 1) > 0 {}
    let crashedEarly = byte == UInt8(ascii: "c") && ranFor < .seconds(15)
    guard byte == UInt8(ascii: "r") || (byte == UInt8(ascii: "c") && !crashedEarly) else { exit(0) }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [arguments[1]]
    try? open.run()
    open.waitUntilExit()
    exit(0)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("planet: \(message)\n".utf8))
    exit(code)
}

if arguments.isEmpty || ["help", "-h", "--help"].contains(arguments[0]) {
    print("""
        planet: control Planets from the command line

        usage: planet <command> [arguments]

        \(Command.usage.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
          config path|reload|check [<file>]
          doctor            checks macOS settings that fight tiling
          version

        Examples:
          planet workspace 3
          planet move-to-workspace 2 --follow
          planet query windows --json | jq
        """)
    exit(0)
}

if arguments == ["config", "path"] {
    print(IPC.configURL.path)
    exit(0)
}

if arguments.count >= 2, arguments[0] == "config", arguments[1] == "check" {
    // Checks the file without the app, so a config can be validated before saving.
    let url = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : IPC.configURL
    do {
        let (_, warnings) = try Config.parse(try String(contentsOf: url, encoding: .utf8))
        for warning in warnings { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }
        print("\(url.path): ok")
        exit(0)
    } catch {
        fail("\(url.path): \(error)")
    }
}

// Commands are checked here first, so a typo fails with a useful message even when the
// app isn't running.
if !["config", "version", "doctor"].contains(arguments[0]) {
    do { _ = try Command.parse(arguments: arguments) } catch {
        fail("\(error)\nRun `planet help` for the list of commands.", code: 2)
    }
}

guard let response = IPC.request(arguments) else {
    fail("Planets isn't running. Start it with `open -a Planets`.")
}
if !response.output.isEmpty {
    if response.ok { print(response.output) } else { fail(response.output) }
}
exit(response.ok ? 0 : 1)
