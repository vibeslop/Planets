import CoreGraphics
import Foundation

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
        CGEvent(keyboardEventSource: nil, virtualKey: 105, keyDown: down)?.post(tap: .cghidEventTap)
    }
    print(String(format: "press %.3f", ProcessInfo.processInfo.systemUptime))
    Thread.sleep(forTimeInterval: every)
}
