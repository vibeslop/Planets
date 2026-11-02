import Foundation

// Posts one of the Fixture app's distributed notifications: open, close, dialog, tab,
// firsttab, hide, show, fullscreen, stall, quit, minimize, unminimize, hideapp or unhideapp.
let action = CommandLine.arguments.dropFirst().first ?? "open"
// An optional second argument names the one process that should act, by pid, and a third
// the window, by its number.
var target: [String: String]? = CommandLine.arguments.dropFirst(2).first.map { ["pid": $0] }
if let window = CommandLine.arguments.dropFirst(3).first { target?["window"] = window }
DistributedNotificationCenter.default().postNotificationName(.init("dev.levelorbit.fixture.\(action)"), object: nil, userInfo: target, deliverImmediately: true)
