import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
window.ignoresMouseEvents = true
window.isReleasedWhenClosed = false
window.collectionBehavior = [.stationary]
window.orderFrontRegardless()
app.run()
