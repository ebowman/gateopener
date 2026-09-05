#if DEBUG
import Foundation
import GateOpenerCore
import os

/// Debug-only launch-argument handling for `MainView` verification (bead
/// gateopener-672.9) on the simulator, without any UI automation.
///
/// Compiled out of Release/App Store builds entirely (the whole file is
/// under `#if DEBUG`), matching the existing pattern in `SignInView`'s
/// `--signin-debug-attempt` hook.
///
/// Recognized launch arguments:
///   - `--mock-gate [ok|fail]`: injects a fake `GateOpening` into
///     `AppEnvironment.make(gateClient:)` that, after a 2s delay, either
///     succeeds (`ok`, the default if the mode word is omitted) or throws
///     (`fail`). Also pre-seeds `AppSettings` with a fake selected gate
///     (`selectedEndpointId "mock"` / `selectedEndpointName "Mock Gate"`)
///     and saves dummy credentials into the REAL credential store — safe
///     only because this whole file is DEBUG-only and this branch only
///     runs when the launch argument is explicitly passed — so the
///     controller starts in `.idle` rather than `.needsSetup` (both
///     AppSettings.isConfigured and stored credentials are required for
///     that). The simulator run must be uninstalled afterwards so these
///     dummy credentials do not linger in the Keychain.
///   - `--auto-open-after <seconds>`: schedules a single `requestOpen()`
///     call after the given delay, invoked from `MainView.onAppear`, so
///     `.opening`/`.succeeded`/`.failed` states can be screenshotted
///     without a human or UI-automation tap.
///   - `--open-settings`: presents the Settings sheet immediately from
///     `MainView.onAppear`, so it can be screenshotted without a human or
///     UI-automation tap (bead gateopener-672.10 verification).
enum DebugLaunchOptions {
    /// The fake `GateOpening` mode requested by `--mock-gate`, or `nil` if
    /// that argument was not passed (production `GateClient` is used).
    enum MockGateMode: String {
        case ok
        case fail
    }

    /// Parses `--mock-gate [ok|fail]` from the process's launch arguments.
    /// A bare `--mock-gate` (no following word, or a following word that is
    /// not `ok`/`fail`) defaults to `.ok`.
    static var mockGateMode: MockGateMode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--mock-gate") else { return nil }
        let nextIndex = flagIndex + 1
        guard nextIndex < arguments.count, let mode = MockGateMode(rawValue: arguments[nextIndex]) else {
            return .ok
        }
        return mode
    }

    /// Parses `--auto-open-after <seconds>` from the process's launch
    /// arguments. Returns `nil` if the argument is absent or malformed.
    static var autoOpenAfterSeconds: Double? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--auto-open-after"),
              arguments.count > flagIndex + 1,
              let seconds = Double(arguments[flagIndex + 1]) else { return nil }
        return seconds
    }

    /// True if `--open-settings` was passed on the launch command line.
    static var openSettingsOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--open-settings")
    }

    /// Pre-seeds `appSettings` and the credential store so a `--mock-gate`
    /// run starts in `.idle` (a selected gate + stored credentials) rather
    /// than `.needsSetup`. No-op unless `mockGateMode` is non-nil.
    ///
    /// Must be called BEFORE `AppEnvironment.make(...)` constructs
    /// `GateController`, since that constructor reads both
    /// `appSettings.isConfigured` and `credentialStore.loadCredentials()`
    /// synchronously to pick the controller's initial state.
    static func seedMockAccountIfNeeded(appSettings: AppSettings, credentialStore: any CredentialStoring) {
        guard mockGateMode != nil else { return }
        appSettings.selectedEndpointId = "mock"
        appSettings.selectedEndpointName = "Mock Gate"
        // Also seed a two-entry `cachedGates` list (bead gateopener-672.10
        // verification) so the Settings gate picker has a real list to
        // show on a `--mock-gate` run, rather than an empty "Refresh
        // gates" call-to-action row. "Mock Gate" matches
        // `selectedEndpointId`/`selectedEndpointName` above so the picker
        // shows it pre-selected; "Side door" is a second, unselected
        // candidate so the picker has something to switch between.
        appSettings.cachedGates = [
            Endpoint(
                endpointId: "mock",
                friendlyName: "Mock Gate",
                capabilities: ["PowerController"],
                displayCategories: ["LOCK_GENERIC"]
            ),
            Endpoint(
                endpointId: "mock-side-door",
                friendlyName: "Side door",
                capabilities: ["PowerController"],
                displayCategories: ["LOCK_GENERIC"]
            ),
        ]
        // Dummy, throwaway credentials — never real. Safe only because
        // this whole file is `#if DEBUG` and this branch only executes
        // when `--mock-gate` was explicitly passed on the launch command
        // line. The simulator run must be uninstalled afterwards (see
        // this type's doc comment) so these do not linger in the Keychain.
        do {
            try credentialStore.saveCredentials(username: "mock-user@example.com", password: "mock-password")
        } catch {
            Logger(subsystem: "ie.boboco.GateOpener", category: "DebugLaunchOptions")
                .fault("--mock-gate: saveCredentials failed: \(String(describing: error), privacy: .public). GateController will start in .needsSetup instead of .idle.")
        }
    }

    /// Builds the fake `GateOpening` for `--mock-gate`, or `nil` if that
    /// argument was not passed (in which case `AppEnvironment.make` falls
    /// back to a real `GateClient`).
    static func makeGateClientIfNeeded() -> (any GateOpening)? {
        guard let mode = mockGateMode else { return nil }
        return DebugMockGateOpening(mode: mode)
    }

    /// Builds the fake `TokenResolving` for `--mock-gate`, or `nil` if that
    /// argument was not passed. Required alongside `makeGateClientIfNeeded()`
    /// because `GateController.performOpen()` calls
    /// `tokenManager.accessToken()` before `gateClient.open(endpointId:)` —
    /// injecting only a fake `GateOpening` would still leave the real
    /// `TokenManager` attempting a real network login with the debug seam's
    /// dummy credentials. See `AppEnvironment.make(tokenResolver:)`.
    static func makeTokenResolverIfNeeded() -> (any TokenResolving)? {
        guard mockGateMode != nil else { return nil }
        return DebugMockTokenResolving()
    }
}

/// A `TokenResolving` conformer used only by `--mock-gate`: returns a fixed,
/// obviously-fake token with no network call, so `GateController
/// .performOpen()`'s `tokenManager.accessToken()` step never touches the
/// real Comelit cloud.
private actor DebugMockTokenResolving: TokenResolving {
    func accessToken() async throws -> String {
        "debug-mock-access-token"
    }
}

/// A `GateOpening` conformer used only by `--mock-gate`: after a fixed 2s
/// delay (long enough for `.opening`'s animated progress ring to be
/// visibly alive in a screenshot, short enough to keep manual verification
/// fast), `open(endpointId:)` either returns (`.ok`) or throws
/// `DebugMockGateOpeningError.injectedFailure` (`.fail`) so `GateController`
/// maps it to `.failed(message:)`.
///
/// Deliberately separate from `Sources/GateOpener/MockGateOpening.swift`
/// (the macOS menu-bar app's `GATEOPENER_MOCK=1` fake): that file lives in
/// the `GateOpener` (macOS) target, which this `GateOpenerIOS` target does
/// not depend on, and its `open(endpointId:)` never fails — this type
/// additionally needs the `.fail` mode bead 672.9's verification step asks
/// for.
private actor DebugMockGateOpening: GateOpening {
    private let mode: DebugLaunchOptions.MockGateMode

    init(mode: DebugLaunchOptions.MockGateMode) {
        self.mode = mode
    }

    func discover(aptId: String?) async throws -> [Endpoint] {
        [Endpoint(
            endpointId: "mock",
            friendlyName: "Mock Gate",
            capabilities: ["PowerController"],
            displayCategories: ["LOCK_GENERIC"]
        )]
    }

    func open(endpointId: String) async throws {
        try? await Task.sleep(for: .seconds(2))
        switch mode {
        case .ok:
            return
        case .fail:
            throw DebugMockGateOpeningError.injectedFailure
        }
    }
}

private enum DebugMockGateOpeningError: Error {
    case injectedFailure
}
#endif
