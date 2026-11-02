import AppKit

// A test app for Planets: opens numbered, colored windows and takes orders over
// distributed notifications, so the window manager can be exercised without touching
// anyone's real windows.
//
//   dev.levelorbit.fixture.open    opens another window
//   dev.levelorbit.fixture.close   closes the newest window
//   dev.levelorbit.fixture.dialog  opens a small fixed-size panel (should float)
//   dev.levelorbit.fixture.tab     adds a native tab to the newest window
//   dev.levelorbit.fixture.hide    hides the newest window without closing it, as chat
//                                  apps do when closed to the menu bar
//   dev.levelorbit.fixture.show    shows it again
//   dev.levelorbit.fixture.quit    closes every window, then quits half a second later, the
//                                  way Electron apps quit; userInfo "pid" picks one process
//   dev.levelorbit.fixture.stall   stops answering for three seconds, like a busy app that
//                                  is slow to list its windows; userInfo "pid" picks one process
//   dev.levelorbit.fixture.minimize    minimises a window to the Dock, as ⌘M does
//   dev.levelorbit.fixture.unminimize  brings it back, as a click on it in the Dock does
//   dev.levelorbit.fixture.hideapp     hides the app, as ⌘H does
//   dev.levelorbit.fixture.unhideapp   shows it again without making it active
//   dev.levelorbit.fixture.fullscreen  toggles full screen, which gives the window a Space of its own
//   dev.levelorbit.fixture.firsttab    selects the first window in its tab group, as an app does by itself
// Every order takes userInfo "pid" to pick one process; without it, every Fixture obeys.
// fullscreen, minimize and unminimize also take "window", a window's number, and do nothing
// when no window has it; without it, they act on the newest window.
//
// FIXTURE_WINDOWS sets how many windows open at launch, FIXTURE_DELAY=2.5 how many seconds
// after it they do, as an app slow to open shows its first window late.
// FIXTURE_MAX="800x600" caps every window's size, as some apps do.
// FIXTURE_MIN="1100x700" sets a minimum size, like most chat and editor apps have.
// FIXTURE_RESTORE="1880x1010" puts that size back, keeping the window's top-left corner,
// whenever it's resized in its first 1.5 seconds, as an app restoring the size it saved does
// while it opens.
// FIXTURE_STEP="9x17" resizes in steps of that size, like a terminal snapping to its
// character grid.
// FIXTURE_COLOR_OFFSET=2 starts the colours further along the palette.
// FIXTURE_BLACK=1 paints every window black, to see an overlay over a dark window.
// FIXTURE_RESIZE_LAG=900 makes a size asked for through Accessibility land that many
// milliseconds later, as Chromium and Electron apps resize from their own loop; a move lands
// at once, and its report still carries the old size.
// FIXTURE_EVENT_LOG=/path logs every mouse event the app receives, and every click that
// reaches a window's content, to find clicks nobody made.
// FIXTURE_FULLSCREEN_LEVEL=1000 raises a window to that level while it's full screen, as
// some full-screen apps do (1000 is the screen saver's).
// FIXTURE_BUSY=8 keeps the main thread busy that many milliseconds of every 60 Hz frame, as
// a full-screen game or video player decoding on it does; requests from other processes,
// Accessibility's included, wait their turn behind it.
// FIXTURE_AX_DELAY=30 makes every Accessibility question about the app or its windows take
// that many milliseconds of the main thread, as some apps take to build their answers.
// FIXTURE_INPUT_LOG=/path logs every key press and click the app receives, with how long it
// took to arrive and the window it went to, to measure when a window takes input again.

final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var counter = 0
    let palette: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.95, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.96, green: 0.93, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.92, green: 0.98, blue: 0.96, alpha: 1), NSColor(srgbRed: 1.00, green: 0.95, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1), NSColor(srgbRed: 1.00, green: 0.93, blue: 0.96, alpha: 1),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // "Prefer tabs" in System Settings would merge the windows into one tabbed window.
        NSWindow.allowsAutomaticWindowTabbing = false
        let count = Int(ProcessInfo.processInfo.environment["FIXTURE_WINDOWS"] ?? "3") ?? 3
        if let delay = ProcessInfo.processInfo.environment["FIXTURE_DELAY"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                for _ in 0..<count { self?.openWindow() }
            }
        } else {
            for _ in 0..<count { openWindow() }
        }
        // Every order is for this process only when the notification names one.
        func on(_ order: String, _ run: @escaping (Notification) -> Void) {
            DistributedNotificationCenter.default().addObserver(forName: .init("dev.levelorbit.fixture.\(order)"), object: nil, queue: .main) { note in
                if let pid = note.userInfo?["pid"] as? String, pid != String(getpid()) { return }
                run(note)
            }
        }
        // The window a number names, or the newest when there's no number. A number no window
        // has picks none: acting on another window would pass a test it should fail.
        func window(_ note: Notification) -> NSWindow? {
            guard let number = note.userInfo?["window"] as? String else { return self.windows.last }
            return self.windows.first { $0.title == "Fixture \(number)" }
        }
        on("open") { [weak self] _ in self?.openWindow() }
        on("close") { [weak self] _ in self?.windows.popLast()?.close() }
        on("dialog") { [weak self] _ in self?.openPanel() }
        on("tab") { [weak self] _ in self?.openTab() }
        // Brings the first window to the front of its tab group without activating the app,
        // as a tab an app selects by itself does.
        on("firsttab") { [weak self] _ in
            guard let first = self?.windows.first else { return }
            first.tabGroup?.selectedWindow = first
        }
        on("hide") { [weak self] _ in self?.windows.last?.orderOut(nil) }
        on("quit") { [weak self] _ in
            for window in self?.windows ?? [] { window.close() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        on("stall") { _ in Thread.sleep(forTimeInterval: 3) }
        // Full screen moves the window to a Space of its own, as watching a video full screen does.
        on("fullscreen") { note in
            guard let window = window(note) else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // A window raised above the normal level doesn't leave full screen when asked.
            if window.styleMask.contains(.fullScreen) { window.level = .normal }
            window.toggleFullScreen(nil)
        }
        on("minimize") { note in window(note)?.miniaturize(nil) }
        on("unminimize") { note in window(note)?.deminiaturize(nil) }
        on("hideapp") { _ in NSApp.hide(nil) }
        on("unhideapp") { _ in NSApp.unhideWithoutActivation() }
        on("show") { [weak self] _ in
            NSApp.activate()
            self?.windows.last?.makeKeyAndOrderFront(nil)
        }
        // A window closed from outside (its close button, Planets, Accessibility) is gone too:
        // left in the list, "show" would bring it back.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            self?.windows.removeAll { $0 === note.object as? NSWindow }
        }
        if let level = ProcessInfo.processInfo.environment["FIXTURE_FULLSCREEN_LEVEL"].flatMap(Int.init) {
            NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { note in
                (note.object as? NSWindow)?.level = NSWindow.Level(rawValue: level)
            }
        }
        if let busy = ProcessInfo.processInfo.environment["FIXTURE_BUSY"].flatMap(Double.init) {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
                let until = ProcessInfo.processInfo.systemUptime + busy / 1000
                while ProcessInfo.processInfo.systemUptime < until {}
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        if inputLog != nil {
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in logInput("active") }
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in logInput("inactive") }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                logInput("key window \((note.object as? NSWindow)?.title ?? "?")")
            }
        }
        // FIXTURE_BACKGROUND keeps the app from taking focus, for tests that must not interrupt.
        if ProcessInfo.processInfo.environment["FIXTURE_BACKGROUND"] == nil { NSApp.activate() }
    }

    func openTab() {
        guard let host = windows.last(where: { !($0 is NSPanel) }) else { return }
        let window = makeWindow()
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }

    func openWindow() {
        let window = makeWindow()
        if ProcessInfo.processInfo.environment["FIXTURE_BACKGROUND"] == nil { window.makeKeyAndOrderFront(nil) } else { window.orderBack(nil) }
        windows.append(window)
        if let saved = ProcessInfo.processInfo.environment["FIXTURE_RESTORE"]?.split(separator: "x").compactMap({ Double($0) }), saved.count == 2 {
            let size = NSSize(width: saved[0], height: saved[1])
            let until = Date().addingTimeInterval(1.5)
            // Weak, and the observer gone after the 1.5 seconds: the notification center holds
            // its block for good, and the block would hold a closed window.
            let restore = { [weak window] in
                guard let window, Date() < until, window.frame.size != size else { return }
                let top = window.frame.maxY
                window.setFrame(NSRect(x: window.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: restore)
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: restore)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeWindow() -> NSWindow {
        counter += 1
        let small = ProcessInfo.processInfo.environment["FIXTURE_SMALL"] != nil
        let rect = small ? NSRect(x: 40 + counter * 30, y: 40 + counter * 20, width: 220, height: 140) : NSRect(x: 200 + counter * 40, y: 200 + counter * 30, width: 520, height: 360)
        let window = FixtureWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Fixture \(counter)"
        if let floor = ProcessInfo.processInfo.environment["FIXTURE_MIN"]?.split(separator: "x").compactMap({ Double($0) }), floor.count == 2 {
            window.minSize = NSSize(width: floor[0], height: floor[1])
        }
        if let cap = ProcessInfo.processInfo.environment["FIXTURE_MAX"]?.split(separator: "x").compactMap({ Double($0) }), cap.count == 2 {
            window.maxSize = NSSize(width: cap[0], height: cap[1])
        }
        if let step = ProcessInfo.processInfo.environment["FIXTURE_STEP"]?.split(separator: "x").compactMap({ Double($0) }), step.count == 2 {
            window.contentResizeIncrements = NSSize(width: step[0], height: step[1])
        }
        window.isReleasedWhenClosed = false
        let view = ClickView()
        view.wantsLayer = true
        // FIXTURE_COLOR_OFFSET starts the palette further along, so a second Fixture's
        // windows can be told from the first's in a recording.
        let offset = Int(ProcessInfo.processInfo.environment["FIXTURE_COLOR_OFFSET"] ?? "0") ?? 0
        let black = ProcessInfo.processInfo.environment["FIXTURE_BLACK"] != nil
        view.layer?.backgroundColor = black ? NSColor.black.cgColor : palette[(counter - 1 + offset) % palette.count].cgColor
        let label = NSTextField(labelWithString: "\(counter)")
        label.font = .systemFont(ofSize: 96, weight: .semibold)
        label.textColor = NSColor(white: 0.2, alpha: 0.35)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        window.contentView = view
        return window
    }

    func openPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 400, y: 400, width: 300, height: 160), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Fixture Panel"
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        windows.append(panel)
    }
}

private let accessibilityDelay = ProcessInfo.processInfo.environment["FIXTURE_AX_DELAY"].flatMap(Double.init).map { $0 / 1000 }

/// Spends FIXTURE_AX_DELAY on the main thread, the thread every Accessibility question is
/// answered on.
func answerSlowly() {
    guard let accessibilityDelay else { return }
    let until = ProcessInfo.processInfo.systemUptime + accessibilityDelay
    while ProcessInfo.processInfo.systemUptime < until {}
}

private let resizeLag = ProcessInfo.processInfo.environment["FIXTURE_RESIZE_LAG"].flatMap(Double.init).map { $0 / 1000 }

final class FixtureWindow: NSWindow {
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        answerSlowly()
        return super.accessibilityAttributeValue(attribute)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard attribute == .size, let resizeLag, let size = (value as? NSValue)?.sizeValue else {
            return super.accessibilitySetValue(value, forAttribute: attribute)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeLag) { [weak self] in
            guard let self else { return }
            // Within its own limits, as an Accessibility resize is (setFrame alone ignores
            // them), keeping the top-left corner where it is by then.
            let width = min(max(size.width, self.minSize.width), self.maxSize.width)
            let height = min(max(size.height, self.minSize.height), self.maxSize.height)
            self.setFrame(NSRect(x: self.frame.minX, y: self.frame.maxY - height, width: width, height: height), display: true)
        }
    }
}

/// Logs mouse events as the app receives them, before AppKit decides what they are.
final class FixtureApplication: NSApplication {
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        answerSlowly()
        return super.accessibilityAttributeValue(attribute)
    }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event.type) {
            logEvent("app \(event.type == .leftMouseDown ? "leftMouseDown" : event.type == .leftMouseUp ? "leftMouseUp" : "right") window \(event.windowNumber) at \(event.locationInWindow) subtype \(event.subtype.rawValue)")
        }
        if event.type == .keyDown || event.type == .leftMouseDown {
            // The event's timestamp is when it was made, on the same clock as systemUptime.
            let late = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
            logInput("\(event.type == .keyDown ? "key \(event.keyCode)" : "click") made \(String(format: "%.3f", event.timestamp)) late \(String(format: "%.0f", late)) ms to \(event.window?.title ?? "no window") key \(keyWindow?.title ?? "none")")
        }
        super.sendEvent(event)
    }
}

/// Takes clicks the way a video player or a game does: even the click that activates it.
final class ClickView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { logEvent("content click in \(window?.title ?? "?") at \(event.locationInWindow)") }
}

private let eventLog = ProcessInfo.processInfo.environment["FIXTURE_EVENT_LOG"].flatMap { FileHandle(forWritingAtPath: $0) ?? (FileManager.default.createFile(atPath: $0, contents: nil) ? FileHandle(forWritingAtPath: $0) : nil) }

func logEvent(_ line: String) {
    guard let eventLog else { return }
    eventLog.seekToEndOfFile()
    eventLog.write(Data((String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + line + "\n").utf8))
}

private let inputLog = ProcessInfo.processInfo.environment["FIXTURE_INPUT_LOG"].flatMap { FileHandle(forWritingAtPath: $0) ?? (FileManager.default.createFile(atPath: $0, contents: nil) ? FileHandle(forWritingAtPath: $0) : nil) }

/// Stamped with the uptime clock, which the test's own key presses are stamped with too.
func logInput(_ line: String) {
    guard let inputLog else { return }
    inputLog.seekToEndOfFile()
    inputLog.write(Data((String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line + "\n").utf8))
}

let app = FixtureApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
