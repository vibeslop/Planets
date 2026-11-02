import AppKit
import PlanetsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controller: AppController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again from Finder or Spotlight opens the workspace menu, the one
        // place Planets has to show.
        controller?.perform(.menuBar(.on))
        return false
    }
}

// A second copy shows the first one's menu instead, as opening it from Finder does.
guard Lifecycle.claimSingleInstance() else {
    FileHandle.standardError.write(Data("Planets is already running.\n".utf8))
    _ = IPC.request(["menubar"], timeout: 1)
    exit(0)
}
Lifecycle.watch()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// PLANETS_APPEARANCE=dark or light draws Planets so whatever the Mac's setting, for
// checking both in the VM, whose settings stay at macOS's defaults.
if let name = ProcessInfo.processInfo.environment["PLANETS_APPEARANCE"] {
    app.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
}
app.run()
