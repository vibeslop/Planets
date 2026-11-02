import Foundation

/// A thread running its own run loop. Each app gets one for its Accessibility work:
/// AX calls block until the other app answers, so a frozen app stalls only its own thread
/// instead of the whole window manager, and calls to different apps run in parallel.
final class RunLoopThread: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        var runLoop: CFRunLoop?
        var stopped = false
    }

    private let state = State()
    let name: String

    init(name: String, qos: QualityOfService = .userInteractive) {
        self.name = name
        let ready = DispatchSemaphore(value: 0)
        let state = self.state
        let thread = Thread {
            state.runLoop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once; an idle source keeps it parked.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            while !state.stopped {
                CFRunLoopRunInMode(.defaultMode, 3600, false)
            }
        }
        thread.name = name
        thread.qualityOfService = qos
        // AX callbacks and frame batches are shallow; a small stack keeps dozens of these cheap.
        thread.stackSize = 256 * 1024
        thread.start()
        ready.wait()
    }

    var runLoop: CFRunLoop { state.runLoop! }

    func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(state.runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(state.runLoop)
    }

    func stop() {
        let state = self.state
        perform {
            state.stopped = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}
