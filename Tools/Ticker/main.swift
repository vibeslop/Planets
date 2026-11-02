import CoreGraphics
import Foundation

// Measures when a window takes input again: runs a command, then presses F13 every few
// milliseconds for a while, the way someone hammering a key would. The app under test logs
// each press it receives (Fixture's FIXTURE_INPUT_LOG); the presses it never got, or got
// late, show how long it wasn't listening.
//
//   ticker [--every 0.05] [--for 3] -- command args...
//   ticker [--every 0.05] [--for 3] -- ctrl-right
//
// ctrl-left and ctrl-right press Mission Control's "Move left/right a space" instead of
// running a command, as a swipe would: the trip without Planets, for comparison.
//
// Prints the uptime when the command started and when each press was made, on the clock
// Fixture logs with.
var every = 0.05, duration = 3.0
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first, flag != "--" {
    arguments.removeFirst()
    let value = Double(arguments.removeFirst()) ?? 0
    if flag == "--every" { every = value } else if flag == "--for" { duration = value }
}
if arguments.first == "--" { arguments.removeFirst() }

print(String(format: "start %.3f", ProcessInfo.processInfo.systemUptime))
if let direction = ["ctrl-left": CGKeyCode(123), "ctrl-right": 124][arguments.first ?? ""] {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: direction, keyDown: down)
        // Arrow keys carry the function and keypad flags, which the shortcut is matched against.
        event?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
    }
} else if !arguments.isEmpty {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try? process.run()
}
let end = ProcessInfo.processInfo.systemUptime + duration
while ProcessInfo.processInfo.systemUptime < end {
    for down in [true, false] {
        // F13: bound to nothing, typed into nothing.
        CGEvent(keyboardEventSource: nil, virtualKey: 105, keyDown: down)?.post(tap: .cghidEventTap)
    }
    print(String(format: "press %.3f", ProcessInfo.processInfo.systemUptime))
    Thread.sleep(forTimeInterval: every)
}
