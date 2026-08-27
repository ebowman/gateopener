import AppKit
import SwiftUI

/// Hosts the real Settings UI (`SettingsView`, bead gateopener-4ub.9) via
/// `NSHostingController`.
///
/// Singleton, preserved from the original placeholder: repeated calls to
/// `showShared()` (from `StatusItemController`'s right-click menu, or the
/// auto-open-on-`.needsSetup` path in `GateOpenerApp.swift`) reuse the same
/// window rather than creating a new one each time. Both existing call
/// sites call `showShared()` with NO arguments (see `StatusItemController.swift`,
/// which is off-limits to this bead), so this controller resolves the
/// app's single `GateControllerObservable` via `GateControllerObservable.appShared`
/// instead of taking it as a parameter — `AppDelegate` sets that one static
/// property immediately after constructing its observable (see the doc
/// comment on `GateControllerObservable.appShared`).
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    /// Shows the (singleton) Settings window, creating it on first use.
    ///
    /// If `GateControllerObservable.appShared` has not been set yet (should
    /// be unreachable in practice — `AppDelegate` sets it before either
    /// call site can be reached — but guarded defensively rather than
    /// force-unwrapped), this shows nothing and returns rather than
    /// crashing.
    static func showShared() {
        guard let observable = GateControllerObservable.appShared else {
            assertionFailure("SettingsWindowController.showShared() called before GateControllerObservable.appShared was set")
            return
        }

        let controller: SettingsWindowController
        if let existing = shared {
            controller = existing
        } else {
            controller = SettingsWindowController(observable: observable)
            shared = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private convenience init(observable: GateControllerObservable) {
        let hostingController = NSHostingController(rootView: SettingsView(observable: observable))

        let window = NSWindow(contentViewController: hostingController)
        window.title = "GateOpener Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
    }
}
