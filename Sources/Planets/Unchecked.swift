import Foundation

// SAFETY: Caller guarantees exclusive thread ownership transfer for the wrapped value.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

let debugTracing = ProcessInfo.processInfo.environment["PLANETS_DEBUG"] != nil

func trace(_ message: @autoclosure () -> String) {
    guard debugTracing else { return }
    FileHandle.standardError.write(Data("[\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(message())\n".utf8))
}

func onTime(after delay: DispatchTimeInterval, _ work: @escaping @MainActor () -> Void) {
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    timer.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
    timer.setEventHandler {
        MainActor.assumeIsolated(work)
        timer.cancel()
    }
    timer.resume()
}
