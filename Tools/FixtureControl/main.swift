import Foundation

let action = CommandLine.arguments.dropFirst().first ?? "open"
var target: [String: String]? = CommandLine.arguments.dropFirst(2).first.map { ["pid": $0] }
if let window = CommandLine.arguments.dropFirst(3).first { target?["window"] = window }
DistributedNotificationCenter.default().postNotificationName(.init("dev.levelorbit.fixture.\(action)"), object: nil, userInfo: target, deliverImmediately: true)
