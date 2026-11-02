import AppKit
import PlanetsCore

/// First launch: one step (Accessibility access), then the keys that matter. The window
/// watches the permission itself, so granting it in System Settings moves things along
/// without a restart or an extra click.
///
/// Plain AppKit on purpose: SwiftUI keeps its caches for the life of the process, and this
/// process is the window manager, which runs all day for a window shown once.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private unowned let controller: AppController
    private var window: NSWindow?

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 10), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        render(granted: false)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func permissionGranted() {
        render(granted: true)
        // Access is given in System Settings, which is in front then. Asking to be activated
        // is only a request, and macOS turns it down for an app in the background: the next
        // step stayed hidden behind Settings. Ordering the window front doesn't ask.
        window?.orderFrontRegardless()
        NSApp.activate()
        window?.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        controller.onboardingClosed()
    }

    private func render(granted: Bool) {
        guard let window else { return }
        let icon = NSImageView(image: AppIcons.artwork(in: Bundle.main.bundleURL) ?? NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let title = label("Planets", size: 24, weight: .semibold)
        let subtitle = label(granted ? "You’re set. These keys move you around:" : "Tiling and instant workspaces, from the keyboard.", size: 13, color: .secondaryLabelColor)

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: icon)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 32, bottom: 28, right: 32)

        let body: [NSView] = granted ? keysStep() : permissionStep()
        if let first = body.first { stack.addArrangedSubview(first); stack.setCustomSpacing(22, after: subtitle) }
        for view in body.dropFirst() { stack.addArrangedSubview(view) }
        for view in body { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true }

        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 440),
        ])
        window.contentView = content
    }

    private func permissionStep() -> [NSView] {
        let text = label("macOS lets apps move other apps’ windows only through Accessibility. Planets uses it for exactly that and never reads what’s inside your windows. Drag Planets into the list that opens; this window carries on by itself.", size: 13, color: .secondaryLabelColor, wraps: true)
        let button = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(grant))
        button.bezelStyle = .push
        button.controlSize = .large
        button.keyEquivalent = "\r"
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let waiting = NSStackView(views: [spinner, label("Waiting for access", size: 12, color: .secondaryLabelColor)])
        waiting.spacing = 6
        let row = NSStackView(views: [button, NSView(), waiting])
        row.distribution = .fill
        return [text, row]
    }

    private func keysStep() -> [NSView] {
        let rows = ShortcutSummary.rows(for: controller.config.bindings)
        let wanted = ["Go to workspace", "Send window to workspace", "Focus neighbouring window", "Swap with neighbouring window", "Zoom window", "Open the workspace menu"]
        let grid = NSGridView(views: wanted.compactMap { title -> [NSView]? in
            guard let row = rows.first(where: { $0.title == title }), let chord = row.chords.first else { return nil }
            return [label(row.title, size: 13), label(chord, size: 13, color: .secondaryLabelColor, monospaced: true)]
        })
        grid.rowSpacing = 9
        grid.column(at: 1).xPlacement = .trailing
        var views: [NSView] = [grid]
        // Settings that fight tiling, each with where to change it. Planets never changes them.
        for check in SetupCheck.run() where check.status == .recommended {
            let text = label("\(check.title). \(check.detail)", size: 11.5, color: .secondaryLabelColor, wraps: true)
            views.append(text)
        }
        let start = NSButton(title: "Start Tiling", target: self, action: #selector(finish))
        start.bezelStyle = .push
        start.controlSize = .large
        start.keyEquivalent = "\r"
        views.append(start)
        return views
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, wraps: Bool = false, monospaced: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = wraps ? .left : .natural
        return field
    }

    @objc private func grant() { controller.requestAccessibility() }
    @objc private func finish() { window?.close() }
}
