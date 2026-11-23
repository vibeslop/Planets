import AppKit

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for pid: pid_t) -> NSImage {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return generic }
        let key = app.bundleURL?.path ?? "pid \(pid)"
        if let icon = cache[key] { return icon }
        let icon = app.bundleURL.flatMap(artwork(in:)) ?? app.icon ?? app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        guard let icon else { return generic }
        cache[key] = icon
        return icon
    }

    nonisolated static func artwork(in url: URL) -> NSImage? {
        guard let bundle = Bundle(url: url) else { return nil }
        if let file = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let name = (file as NSString).deletingPathExtension
            if let path = bundle.path(forResource: name, ofType: "icns"), let image = NSImage(contentsOfFile: path), !isBlank(image) { return image }
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, let image = bundle.image(forResource: name), !isBlank(image) {
            return image
        }
        return nil
    }

    private nonisolated static func isBlank(_ image: NSImage) -> Bool {
        let side = 16
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return !(0..<side * side).contains { pixels[$0 * 4 + 3] > 0 }
    }

    private static var generic: NSImage { NSWorkspace.shared.icon(for: .application) }
}
