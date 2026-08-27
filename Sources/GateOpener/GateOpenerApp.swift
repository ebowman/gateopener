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
    private var notificationPresenter: NotificationPresenter!
    private var hasAutoOpenedSettings = false
    /// Set only under `GATEOPENER_MOCK=1`, so the self-test path can read
    /// call counts directly without `GateController` needing to expose its
    /// private `gateClient` dependency.
    private var mockGateOpeningForSelfTest: MockGateOpening?
    /// The app's shared `EventLog` (bead gateopener-4ub.10). Kept as a
    /// property (not just a local in `applicationDidFinishLaunching`) so
    /// `runSelfTestAndExit()` can assert real entries were recorded by a
    /// simulated open attempt.
    private var eventLog: EventLog!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must happen before any window is shown (the Settings window can
        // auto-open below on `.needsSetup`) so the Edit menu exists the
        // first time a text field becomes first responder. See
        // MainMenu.swift for the root-cause explanation (bead
        // gateopener-iif.1): without this, Cmd-V/C/X/A/Z are unbound in
        // every text field because AppKit never installs a main menu for
        // an `.accessory`/`LSUIElement` app on its own.
        MainMenu.install()

        let controller = Self.makeGateController(mockOut: &mockGateOpeningForSelfTest)
        let observable = GateControllerObservable(controller: controller)
        self.observable = observable
        GateControllerObservable.appShared = observable

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
        let notificationPresenter = NotificationPresenter { [weak controller] in
            Task { await controller?.openGate() }
        }
        self.notificationPresenter = notificationPresenter

        // The app's single `EventLog` instance (bead gateopener-4ub.10).
        // Reachable by the Settings UI via `GateControllerObservable.eventLog`
        // (set once, immediately below) so `SettingsView`'s log section can
        // render real entries instead of the placeholder left by bead .9.
        let eventLog = EventLog()
        self.eventLog = eventLog
        observable.eventLog = eventLog

        // Records `.opening` -> `.succeeded`/`.failed` transitions. This is
        // the seam available from the app layer: `GateState` itself only
        // carries a short human-readable failure `message`, not a
        // per-attempt count or HTTP status code (those live inside
        // `GateClient.open`'s internal retry loop in `GateOpenerCore`,
        // which this bead does not restructure) — so every open here is
        // logged as a single attempt (1 of 1), and every failure is logged
        // via the closed `OpenFailureReason.unknown` case rather than a
        // real HTTP status, since no status is observable from here. See
        // the bead .10 report for the full list of event kinds this does
        // and does not cover.
        var lastLoggedStateWasOpening = false
        controller.onStateChange = { [weak self] state in
            observableStateChange?(state)
            self?.statusItemController.render(for: state)
            notificationPresenter.handle(state)

            switch state {
            case .opening:
                lastLoggedStateWasOpening = true
                eventLog.logOpenAttempt(attempt: 1, of: 1)
            case .succeeded:
                if lastLoggedStateWasOpening {
                    eventLog.logOpenSucceeded()
                }
                lastLoggedStateWasOpening = false
            case .failed:
                if lastLoggedStateWasOpening {
                    eventLog.logOpenFailed(attempt: 1, of: 1, reason: .unknown)
                }
                lastLoggedStateWasOpening = false
            case .needsSetup, .idle:
                lastLoggedStateWasOpening = false
            }
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

        // Bead gateopener-iif.1: prove `MainMenu.install()` actually
        // produced a usable Edit menu, since AppKit does not install one
        // automatically for an `.accessory`/`LSUIElement` app. Checked
        // directly against `NSApp.mainMenu` (the real production object),
        // not a re-built copy.
        let mainMenu = NSApp.mainMenu
        let mainMenuPresent = mainMenu != nil
        let editMenu = mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        let editMenuPresent = editMenu != nil
        func editMenuHasItem(keyEquivalent: String, action: Selector) -> Bool {
            editMenu?.items.contains { $0.keyEquivalent == keyEquivalent && $0.action == action } ?? false
        }
        let hasPasteItem = editMenuHasItem(keyEquivalent: "v", action: #selector(NSText.paste(_:)))
        let hasCopyItem = editMenuHasItem(keyEquivalent: "c", action: #selector(NSText.copy(_:)))
        let hasSelectAllItem = editMenuHasItem(keyEquivalent: "a", action: #selector(NSText.selectAll(_:)))

        print("SELFTEST mainMenu present: \(mainMenuPresent)")
        print("SELFTEST edit menu present: \(editMenuPresent)")
        print("SELFTEST edit menu paste item: \(hasPasteItem)")
        print("SELFTEST edit menu copy item: \(hasCopyItem)")
        print("SELFTEST edit menu select all item: \(hasSelectAllItem)")

        Task { @MainActor in
            statusItemController.simulateClickForSelfTest(rightClick: true)
            try? await Task.sleep(for: .milliseconds(200))
            let afterRightClick = await mock.openCallCount

            statusItemController.simulateClickForSelfTest(rightClick: false)
            try? await Task.sleep(for: .milliseconds(700))
            let afterLeftClick = await mock.openCallCount

            // Prove EventLog actually records real events (bead
            // gateopener-4ub.10 defect 1): the left click above drove a
            // real `.opening` -> `.succeeded` transition through
            // `controller.onStateChange`, which must have appended a
            // "open attempted" entry and an "open succeeded" entry to the
            // app's shared EventLog.
            let logText = self.eventLog.formattedText()
            let logEntryCount = self.eventLog.snapshot().count
            let logRecordedAttempt = logText.contains("open attempted")
            let logRecordedSuccess = logText.contains("open succeeded")

            print("SELFTEST menu-shown count after right-click: \(menuRequestedCount)")
            print("SELFTEST openCallCount after right-click: \(afterRightClick)")
            print("SELFTEST openCallCount after left-click: \(afterLeftClick)")
            print("SELFTEST eventLog entry count: \(logEntryCount)")
            print("SELFTEST eventLog recorded open attempt: \(logRecordedAttempt)")
            print("SELFTEST eventLog recorded open success: \(logRecordedSuccess)")
            if menuRequestedCount == 1 && afterRightClick == 0 && afterLeftClick == 1
                && logRecordedAttempt && logRecordedSuccess
                && mainMenuPresent && editMenuPresent
                && hasPasteItem && hasCopyItem && hasSelectAllItem {
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

        if isMock {
            // Mock mode MUST NOT construct `AppSettings()` (i.e.
            // `UserDefaults.standard`) here. `.standard`'s resolved domain
            // depends on how the binary is launched:
            //   - No bundle identifier (plain SwiftPM executable, as under
            //     `swift run` / `.build/debug/GateOpener`): `.standard`
            //     falls back to the EXECUTABLE-NAME domain `GateOpener`.
            //   - Once packaged as a real .app with
            //     `CFBundleIdentifier = ie.boboco.GateOpener` (see bead
            //     .11), `.standard` resolves to the OPERATOR'S REAL
            //     `ie.boboco.GateOpener` domain.
            // Either way this branch is about to WRITE a fake mock
            // endpoint id/name into whatever `.standard` resolves to. If
            // that were the real domain, a mock/self-test run would
            // silently overwrite the operator's live gate selection and
            // the app would look configured while the gate never opens.
            // So mock mode always gets its own throwaway suite, wiped at
            // startup so runs don't accumulate stale state, and NEVER
            // falls back to `.standard` on failure — a silent fallback
            // here would reintroduce exactly the bug this guards against.
            let mockSuiteName = "ie.boboco.GateOpener.mock"
            guard let mockDefaults = UserDefaults(suiteName: mockSuiteName) else {
                fatalError("GateOpener mock mode could not create throwaway UserDefaults suite '\(mockSuiteName)'; refusing to fall back to .standard, which could pollute real settings.")
            }
            mockDefaults.removePersistentDomain(forName: mockSuiteName)
            let appSettings = AppSettings(defaults: mockDefaults)

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

        let appSettings = AppSettings()
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
