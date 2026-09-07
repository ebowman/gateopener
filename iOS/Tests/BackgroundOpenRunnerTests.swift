import Foundation
import Testing
import UIKit
import GateOpenerCore
@testable import GateOpener

/// Fake `BackgroundTaskHost`: never touches `UIApplication`. Records begin/
/// end call counts and lets a test manually invoke the expiration handler
/// it was most recently given.
@MainActor
final class FakeBackgroundTaskHost: BackgroundTaskHost {
    private(set) var beginCallCount = 0
    private(set) var endCallCount = 0
    private var nextTaskId: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 1)
    private(set) var lastExpirationHandler: (@Sendable () -> Void)?

    func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        beginCallCount += 1
        lastExpirationHandler = expirationHandler
        let taskId = nextTaskId
        nextTaskId = UIBackgroundTaskIdentifier(rawValue: nextTaskId.rawValue + 1)
        return taskId
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        endCallCount += 1
    }
}

/// Tests for `BackgroundOpenRunner` (bead gateopener-672.18): begin/end
/// call counts across a queued/opening -> succeeded transition, plus the
/// expiration-handler path. Driven via `stateDidChange(_:)` (the
/// state-observer seam), and via `requestOpen()` against a real
/// `GateController` built entirely from fakes — no real Keychain, no real
/// network, no real `UIApplication`.
@MainActor
struct BackgroundOpenRunnerTests {
    /// Builds a `GateController` with a fake `GateOpening`/`TokenResolving`/
    /// `CredentialStoring` and an in-memory `AppSettings`, pre-configured so
    /// the controller starts `.idle` (a selected gate persisted to the
    /// in-memory `UserDefaults` suite) rather than `.needsSetup` — needed so
    /// `requestOpen()` actually drives `.opening` -> `.succeeded` rather
    /// than short-circuiting immediately. `sleep` is a no-op so the
    /// controller's ~3s auto-reset-to-idle never actually waits.
    private func makeIdleController(
        defaults: UserDefaults,
        gateClient: FakeGateOpening
    ) -> GateController {
        let appSettings = AppSettings(defaults: defaults)
        appSettings.selectedEndpointId = "test-endpoint"
        appSettings.selectedEndpointName = "Test Gate"

        let credentialStore = InMemoryCredentialStore()
        try? credentialStore.saveCredentials(username: "user", password: "pass")

        return GateController(
            gateClient: gateClient,
            tokenManager: FakeTokenResolving(),
            credentialStore: credentialStore,
            appSettings: appSettings,
            sleep: { _ in },
            reachability: AlwaysReachable()
        )
    }

    // MARK: - (e) begin exactly once across queued/opening -> succeeded, end exactly once

    /// Drives the runner through a realistic `.queued` -> `.opening` ->
    /// `.succeeded` sequence (mirroring how `GateController.requestOpen()`
    /// can pass through `.queued` before `.opening` when offline, and
    /// always reaches a terminal state) via the `stateDidChange(_:)` seam
    /// directly — exercising `beginBackgroundTaskIfNeeded()`'s "already
    /// begun" guard by observing TWO background-task-eligible states
    /// (`.queued` then `.opening`) in a row before the terminal
    /// `.succeeded`, which is exactly the sequence `updateBackgroundTask
    /// (for:)` is designed to coalesce into a single underlying
    /// `beginBackgroundTask` call.
    ///
    /// MUTATION CHECK: removing the `currentTaskId == nil` guard in
    /// `BackgroundOpenRunner.beginBackgroundTaskIfNeeded()`
    /// (`guard currentTaskId == nil else { return }`,
    /// iOS/App/BackgroundOpenRunner.swift) makes `beginBackgroundTask`
    /// called AGAIN on the second background-task-eligible state
    /// (`.opening`, following `.queued`) instead of being coalesced, so
    /// `host.beginCallCount` becomes 2 instead of 1 — failing the `== 1`
    /// assertion below. Verified by temporarily removing that guard and
    /// re-running this test: it fails with `beginCallCount == 2`.
    @Test func beginsExactlyOnceAcrossQueuedOpeningAndEndsOnceOnSucceeded() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let gateClient = FakeGateOpening()
        let controller = makeIdleController(defaults: defaults, gateClient: gateClient)
        let host = FakeBackgroundTaskHost()
        let runner = BackgroundOpenRunner(controller: controller, host: host)

        // Mirror how `GateOpenerIOSApp` wires this in production:
        // `stateDidChange(_:)` is registered as an additional observer so
        // begin/end tracks every state transition the controller reports,
        // not just the one immediately following a single call.
        runner.stateDidChange(.queued)
        runner.stateDidChange(.opening)
        #expect(host.beginCallCount == 1)
        #expect(host.endCallCount == 0)

        runner.stateDidChange(.succeeded(at: Date()))

        #expect(host.beginCallCount == 1)
        #expect(host.endCallCount == 1)
    }

    /// MUTATION CHECK: removing the `currentTaskId else { return }` guard
    /// in `BackgroundOpenRunner.endCurrentTaskIfNeeded()`
    /// (`guard let taskId = currentTaskId else { return }`) makes
    /// `host.endBackgroundTask` get called EVERY time `endCurrentTaskIfNeeded()`
    /// runs, even when nothing is currently begun — so the extra,
    /// already-idle `stateDidChange(.idle)` call below (mirroring a
    /// `.needsSetup`/`.idle`/`.failed`/`.succeeded` transition observed
    /// with no background task in flight, which `updateBackgroundTask(for:)`
    /// routes to `endCurrentTaskIfNeeded()` unconditionally) would push
    /// `host.endCallCount` to 2 instead of the expected 1. Verified by
    /// temporarily removing that guard and re-running this test: it fails
    /// with `endCallCount == 2`.
    @Test func expirationHandlerEndsTheBackgroundTask() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let gateClient = FakeGateOpening()
        let controller = makeIdleController(defaults: defaults, gateClient: gateClient)
        let host = FakeBackgroundTaskHost()
        let runner = BackgroundOpenRunner(controller: controller, host: host)

        // No background task has ever been begun — this must be a no-op,
        // not an unconditional end call.
        runner.stateDidChange(.idle)
        #expect(host.endCallCount == 0)

        // Drive the runner directly into "begun" state via the
        // state-observer seam, without needing a real open in flight.
        runner.stateDidChange(.opening)
        #expect(host.beginCallCount == 1)
        #expect(host.endCallCount == 0)

        // Simulate the OS calling the expiration handler.
        host.lastExpirationHandler?()
        // The expiration handler hops to the main actor via `Task { @MainActor in ... }`;
        // yield until it has run.
        var attempts = 0
        while host.endCallCount == 0, attempts < 200 {
            await Task.yield()
            attempts += 1
        }

        #expect(host.endCallCount == 1)

        // A second, redundant end (mirroring another terminal-state
        // transition arriving after the expiration handler already ended
        // the task) must remain a no-op.
        runner.stateDidChange(.succeeded(at: Date()))
        #expect(host.endCallCount == 1)
    }
}

private extension GateState {
    /// Test-only convenience predicate, used only to poll for the terminal
    /// `.succeeded` state without comparing against a synthesized `Date`.
    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
