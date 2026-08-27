import AppKit
import GateOpenerCore

/// `@main` entry point. Deliberately an `NSApplicationDelegate`-driven
/// AppKit app (not a SwiftUI `App`/`MenuBarExtra` scene) because
/// `MenuBarExtra` cannot cleanly express left-click-fires / right-click-menu
/// — see `StatusItemController`'s doc comment.
@main
struct GateOpenerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `.accessory`: no Dock icon, no menu bar app-switcher entry, no
        // main-menu window — the app lives entirely in its status item.
        // Equivalent in effect to setting `LSUIElement` in Info.plist, done
        // in code so no Info.plist/bundle resources are required for a
        // plain SwiftPM executable target.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observable: GateControllerObservable!
    private var statusItemController: StatusItemController!
    private var hasAutoOpenedSettings = false
    /// Set only under `GATEOPENER_MOCK=1`, so the self-test path can read
    /// call counts directly without `GateController` needing to expose its
    /// private `gateClient` dependency.
    private var mockGateOpeningForSelfTest: MockGateOpening?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = Self.makeGateController(mockOut: &mockGateOpeningForSelfTest)
        let observable = GateControllerObservable(controller: controller)
        self.observable = observable

        let statusItemController = StatusItemController(observable: observable)
        self.statusItemController = statusItemController

        guard statusItemController.install() else {
            presentStatusItemUnavailableAlertAndExit()
            return
        }

        // `GateControllerObservable`'s own `onStateChange` subscription
        // (installed in its initializer) already keeps `observable.state`
        // current; chain a second hook onto the SAME `onStateChange`
        // property so the status item also repaints on every transition.
        // `GateControllerObservable` is created first, so its subscription
        // is already installed — wrap it rather than clobber it.
        let observableStateChange = controller.onStateChange
        controller.onStateChange = { [weak self] state in
            observableStateChange?(state)
            self?.statusItemController.render(for: state)
        }

        if case .needsSetup = controller.state, !hasAutoOpenedSettings {
            hasAutoOpenedSettings = true
            SettingsWindowController.showShared()
        }

        if ProcessInfo.processInfo.environment["GATEOPENER_MOCK_SELFTEST"] == "1" {
            runSelfTestAndExit()
        }
    }

    /// Verification path for the bead .8 done-criteria: proves, via the
    /// REAL production click-handling code path (`StatusItemController`'s
    /// `statusItemClicked(_:)`), that a left click calls `openGate()`
    /// exactly once and a right click calls it zero times — all against
    /// `MockGateOpening`, never the real gate. Prints a machine-checkable
    /// summary line and exits. Only runs when both `GATEOPENER_MOCK=1` and
    /// `GATEOPENER_MOCK_SELFTEST=1` are set.
    private func runSelfTestAndExit() {
        guard let mock = mockGateOpeningForSelfTest else {
            print("SELFTEST FAIL: not running against MockGateOpening")
            exit(1)
        }
        // The real `showMenu()` calls the BLOCKING/modal `NSMenu.popUp`,
        // which never returns in a headless process with no one to dismiss
        // it. Swap in a non-blocking recorder so the self-test can still
        // prove a right-click was routed to "show the menu" (and NOT to
        // `handleLeftClick()`) without hanging.
        var menuRequestedCount = 0
        statusItemController.onMenuRequestedForSelfTest = { menuRequestedCount += 1 }

        Task { @MainActor in
            statusItemController.simulateClickForSelfTest(rightClick: true)
            try? await Task.sleep(for: .milliseconds(200))
            let afterRightClick = await mock.openCallCount

            statusItemController.simulateClickForSelfTest(rightClick: false)
            try? await Task.sleep(for: .milliseconds(700))
            let afterLeftClick = await mock.openCallCount

            print("SELFTEST menu-shown count after right-click: \(menuRequestedCount)")
            print("SELFTEST openCallCount after right-click: \(afterRightClick)")
            print("SELFTEST openCallCount after left-click: \(afterLeftClick)")
            if menuRequestedCount == 1 && afterRightClick == 0 && afterLeftClick == 1 {
                print("SELFTEST PASS")
                exit(0)
            } else {
                print("SELFTEST FAIL")
                exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the Settings window (the only window this app ever
        // shows) must never quit the app — it lives in the status item.
        false
    }

    private func presentStatusItemUnavailableAlertAndExit() {
        let alert = NSAlert()
        alert.messageText = "GateOpener could not start"
        alert.informativeText = "macOS could not create a menu bar item for GateOpener (the menu bar may be full). Free up space in the menu bar and relaunch GateOpener."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Dependency graph construction

    /// Builds the real (or, under `GATEOPENER_MOCK=1`, mock) dependency
    /// graph and returns a fully-constructed `GateController`.
    ///
    /// - Parameter mockOut: written with the `MockGateOpening` instance iff
    ///   mock mode is active, so the self-test path can read its call
    ///   counts directly. Left `nil` in real (non-mock) mode.
    private static func makeGateController(mockOut: inout MockGateOpening?) -> GateController {
        let isMock = ProcessInfo.processInfo.environment["GATEOPENER_MOCK"] == "1"
        let appSettings = AppSettings()

        if isMock {
            // See MockGateOpening.swift: records calls instead of hitting
            // the network, so left/right-click discrimination can be
            // verified without ever opening the real gate.
            appSettings.selectedEndpointId = MockGateOpening.mockEndpoint.endpointId
            appSettings.selectedEndpointName = MockGateOpening.mockEndpoint.friendlyName
            let mock = MockGateOpening()
            mockOut = mock
            return GateController(
                gateClient: mock,
                tokenManager: MockTokenResolving(),
                credentialStore: MockCredentialStore(),
                appSettings: appSettings
            )
        }

        let credentialStore = KeychainCredentialStore()
        let api = ComelitAPI()
        let tokenManager = TokenManager(api: api, credentialStore: credentialStore)
        let gateClient = GateClient(tokenManager: tokenManager)

        return GateController(
            gateClient: gateClient,
            tokenManager: tokenManager,
            credentialStore: credentialStore,
            appSettings: appSettings
        )
    }
}
