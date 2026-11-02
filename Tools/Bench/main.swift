import AppKit
import CoreMedia
import ScreenCaptureKit

// Measures what a person sees: the time from a key press to the screen changing.
//
// Internal timers only cover the part of the work Planets does itself. The part that
// matters is from the key going down to new pixels on the display, which also includes the
// other app, the window server and the next display refresh. This presses the real key
// through the HID event stream, records the screen with ScreenCaptureKit, and finds the
// first frame that differs from the one before the press (first response) and the last
// frame that changed before the screen went still (settled).
//
// Usage: bench <input> [--region x,y,w,h] [--trials N] [--gap seconds] [--label text]
//   input: modifiers and a key joined by "+", e.g. "cmd+grave", "alt+2", "down"; several
//          separated by "|" are pressed in turn, e.g. "down|up". "click:x,y" clicks a point
//          (global top-left points); "click:x,y;x,y" clicks each in turn.
//   region: global top-left points to watch; defaults to the main display.

struct Options {
    var chord = "cmd+grave"
    var region: CGRect?
    var trials = 12
    var gap = 0.7
    var label = ""
}

func parse() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else {
        print("usage: bench <chord> [--region x,y,w,h] [--trials N] [--gap s] [--label text]")
        exit(2)
    }
    options.chord = args.removeFirst()
    while !args.isEmpty {
        let flag = args.removeFirst()
        let value = args.isEmpty ? "" : args.removeFirst()
        switch flag {
        case "--region":
            let n = value.split(separator: ",").compactMap { Double($0) }
            if n.count == 4 { options.region = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        case "--trials": options.trials = Int(value) ?? options.trials
        case "--gap": options.gap = Double(value) ?? options.gap
        case "--label": options.label = value
        default: break
        }
    }
    return options
}

let keyCodes: [String: CGKeyCode] = [
    "grave": 50, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    "tab": 48, "space": 49, "h": 4, "j": 38, "k": 40, "l": 37, "o": 31, "b": 11,
    "down": 125, "up": 126, "left": 123, "right": 124, "w": 13, "q": 12,
]

func chord(_ text: String) -> (CGKeyCode, CGEventFlags) {
    var flags: CGEventFlags = []
    var key: CGKeyCode = 50
    for part in text.lowercased().split(separator: "+") {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        default: key = keyCodes[String(part)] ?? key
        }
    }
    return (key, flags)
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func ms(_ from: UInt64, _ to: UInt64) -> Double {
    Double(Int64(to) - Int64(from)) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

/// Frames as they arrive: when each was displayed, and whether it differed from the last.
final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [UInt8] = []
    private(set) var changes: [UInt64] = []
    private(set) var frames = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let shown = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        // Every other pixel on every other row is plenty to see a title bar or a rim change.
        var sample = [UInt8]()
        sample.reserveCapacity(width * height)
        for y in Swift.stride(from: 0, to: height, by: 2) {
            let row = base + y * stride
            for x in Swift.stride(from: 0, to: width, by: 2) {
                let p = row + x * 4
                sample.append(UInt8((Int(p[0]) + Int(p[1]) * 2 + Int(p[2])) / 4))
            }
        }
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        if previous.count == sample.count {
            var differing = 0
            for i in 0..<sample.count where abs(Int(sample[i]) - Int(previous[i])) > 10 {
                differing += 1
                if differing > 12 { break }
            }
            if differing > 12 { changes.append(shown) }
        }
        previous = sample
    }

    func changes(after start: UInt64) -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return changes.filter { $0 > start }
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

func run() async throws {
    let options = parse()
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        print("no display"); exit(1)
    }
    let region = options.region ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
    let config = SCStreamConfiguration()
    config.sourceRect = region
    // Half the points is enough to see the change and keeps each frame cheap to compare.
    config.width = max(64, Int(region.width / 2))
    config.height = max(64, Int(region.height / 2))
    config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    config.queueDepth = 8
    config.showsCursor = false
    config.pixelFormat = kCVPixelFormatType_32BGRA
    let recorder = Recorder()
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "bench.frames", qos: .userInteractive))
    try await stream.startCapture()
    try await Task.sleep(for: .milliseconds(500))

    enum Input { case key(CGKeyCode, CGEventFlags), click(CGPoint) }
    let inputs: [Input]
    if options.chord.hasPrefix("click:") {
        inputs = options.chord.dropFirst(6).split(separator: ";").compactMap { pair in
            let n = pair.split(separator: ",").compactMap { Double($0) }
            return n.count == 2 ? .click(CGPoint(x: n[0], y: n[1])) : nil
        }
    } else {
        inputs = options.chord.split(separator: "|").map { let (k, f) = chord(String($0)); return .key(k, f) }
    }
    var first: [Double] = [], settled: [Double] = []
    var missed = 0
    for trial in 0..<options.trials {
        let start: UInt64
        switch inputs[trial % inputs.count] {
        case .key(let key, let flags):
            let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)!
            down.flags = flags
            up.flags = flags
            start = mach_absolute_time()
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        case .click(let point):
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(60))
            // Timed from the button coming up: that's when a click takes effect.
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(30))
            start = mach_absolute_time()
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .seconds(options.gap))
        let changes = recorder.changes(after: start)
        guard let firstChange = changes.first else { missed += 1; continue }
        // Settled: the last change in a run of changes no more than 150 ms apart.
        var last = firstChange
        for change in changes.dropFirst() where ms(last, change) < 150 { last = change }
        first.append(ms(start, firstChange))
        settled.append(ms(start, last))
    }
    try await stream.stopCapture()
    let label = options.label.isEmpty ? options.chord : options.label
    func fmt(_ v: Double) -> String { String(format: "%6.1f", v) }
    print("\(label): \(first.count) trials, \(missed) without a visible change, \(recorder.frames) frames compared")
    print("  first response ms  p50 \(fmt(percentile(first, 0.5)))  p95 \(fmt(percentile(first, 0.95)))  min \(fmt(first.min() ?? .nan))  max \(fmt(first.max() ?? .nan))")
    print("  settled ms         p50 \(fmt(percentile(settled, 0.5)))  p95 \(fmt(percentile(settled, 0.95)))  min \(fmt(settled.min() ?? .nan))  max \(fmt(settled.max() ?? .nan))")
    print("  raw first: \(first.map { String(format: "%.0f", $0) }.joined(separator: " "))")
}

let done = DispatchSemaphore(value: 0)
Task {
    do { try await run() } catch { print("bench failed: \(error)") }
    done.signal()
}
done.wait()
