import AppKit

/// Minimal placeholder Settings window.
///
/// TODO(gateopener-4ub.9): replace this placeholder with the real sign-in /
/// change-password / gate-picker / sign-out UI. This controller only exists
/// so bead .8 has somewhere to route "Settings…" (from the menu, and from
/// the auto-open-on-`.needsSetup` path) — it deliberately does not build any
/// form.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    /// Shows the (singleton) Settings window, creating it on first use.
    static func showShared() {
        let controller: SettingsWindowController
        if let existing = shared {
            controller = existing
        } else {
            controller = SettingsWindowController()
            shared = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GateOpener Settings"
        window.isReleasedWhenClosed = false
        window.center()

        let label = NSTextField(labelWithString: "Settings UI is not built yet (see gateopener-4ub.9).")
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: window.contentLayoutRect)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20)
        ])
        window.contentView = container

        self.init(window: window)
    }
}
