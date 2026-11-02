import Foundation

/// Carries a non-Sendable value across a thread hop that is known to be safe, such as
/// handing a CoreFoundation object to the one thread that will use it from then on.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Prints a trace line when PLANETS_DEBUG is set. For diagnosing ordering and focus
/// problems live; silent otherwise.
let debugTracing = ProcessInfo.processInfo.environment["PLANETS_DEBUG"] != nil

func trace(_ message: @autoclosure () -> String) {
    guard debugTracing else { return }
    FileHandle.standardError.write(Data("[\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(message())\n".utf8))
}

/// Runs `work` on the main thread after `delay`, on time. `asyncAfter` lets the system move a
/// timer to the next time the process wakes anyway, and that wake is usually the very thing
/// the timer was there not to wait for: a switch's 50 ms limit on a slow app fired when the
/// slow app finished, 76 ms in, every time.
func onTime(after delay: DispatchTimeInterval, _ work: @escaping @MainActor () -> Void) {
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    timer.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
    timer.setEventHandler {
        MainActor.assumeIsolated(work)
        timer.cancel()
    }
    timer.resume()
}
