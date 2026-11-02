import AppKit
import CoreMedia
import ScreenCaptureKit

// Records the main display frame by frame while workspaces switch, to catch flashes too short
// to see reliably: frames where the desktop shows through, or parts of two workspaces at once.
//
// Usage: flicker <seconds> <outdir> [--frames]
// Writes frames.txt, one line per frame: the time, then the share of the screen below the
// menu bar that is magenta backdrop (Tools/Backdrop), Fixture's first, second and third
// palette colours, and the focus rim's gold. --frames also saves every frame as a PNG.
let arguments = CommandLine.arguments
guard arguments.count >= 3, let seconds = Double(arguments[1]) else {
    print("usage: flicker <seconds> <outdir> [--frames]")
    exit(2)
}
let out = URL(fileURLWithPath: arguments[2])
let savesFrames = arguments.contains("--frames")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
    var lines: [String] = []
    var start: CMTime?
    var index = 0
    let context = CIContext()
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        if start == nil { start = time }
        let t = CMTimeGetSeconds(CMTimeSubtract(time, start!))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var counts = [0, 0, 0, 0, 0], total = 0
        let top = h * 36 / 1080
        for y in stride(from: top, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let p = base + y * row + x * 4
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                total += 1
                if r > 200 && b > 200 && g < 80 { counts[0] += 1 }                        // backdrop
                else if r > 200 && g > 200 && b > 200 {
                    if b > g + 4 && g > r + 4 { counts[1] += 1 }                          // window tinted blue
                    else if b > g + 4 && r > g + 4 { counts[2] += 1 }                     // violet
                    else if g > b + 2 && g > r + 8 { counts[3] += 1 }                     // green
                }
                else if r > 190 && g > 120 && g < 215 && b < 140 { counts[4] += 1 }       // gold rim
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let f = counts.map { String(format: "%.3f", Double($0) / Double(max(1, total))) }
        lines.append(String(format: "%.4f", t) + " " + f.joined(separator: " "))
        guard savesFrames else { index += 1; return }
        let image = CIImage(cvPixelBuffer: buffer)
        if let cg = context.createCGImage(image, from: image.extent) {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(String(format: "f%04d.png", index)))
        }
        index += 1
    }
}

let sink = Sink()
Task {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    // A display asleep lists no displays at all.
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        print("no display to record; is it asleep?")
        exit(3)
    }
    let config = SCStreamConfiguration()
    config.width = 640; config.height = 360
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = false
    config.queueDepth = 8
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
    try await stream.startCapture()
    print("recording"); fflush(stdout)
    try await Task.sleep(for: .seconds(seconds))
    try await stream.stopCapture()
    try sink.lines.joined(separator: "\n").write(to: out.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
    // Workspace 1 holds the first two colours, workspace 2 the third.
    let rows = sink.lines.map { $0.split(separator: " ").compactMap { Double($0) } }
    let desktop = rows.filter { $0[1] > 0.05 }.count
    let mixed = rows.filter { ($0[2] > 0.05 || $0[3] > 0.05) && $0[4] > 0.05 }.count
    print("frames \(rows.count), desktop showing \(desktop), parts of both workspaces \(mixed)")
    exit(0)
}
RunLoop.main.run()
