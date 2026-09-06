import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `OpenGateIntent.runFlow(environment:)` (bead gateopener-672.18).
///
/// IMPORTANT GAP, called out explicitly per this bead's brief:
/// `AppEnvironment.make(...)` has NO `credentialStore:` injection
/// parameter — it always constructs a real `KeychainCredentialStore`
/// scoped to `SharedContainer.keychainAccessGroup` internally (see
/// `AppEnvironment.swift`). This test bundle must never touch that real
/// Keychain access group (this bead's own EDGE CASES), so there is no way
/// to seed credentials that would make a freshly-built `AppEnvironment`'s
/// `GateController` start in `.idle` rather than `.needsSetup`. As a
/// result:
///   - The `needsSetup` path (test b) is fully exercisable end to end
///     through `OpenGateIntent.runFlow(environment:)`, because a fresh
///     `AppEnvironment.make()` with no stored credentials always starts
///     `.needsSetup` — this is exactly the scenario this bead needs.
///   - The `.opening` -> `.succeeded` ordering (test a) can NOT be driven
///     through `OpenGateIntent.runFlow(environment:)` without an
///     `AppEnvironment` whose controller starts `.idle`, which is not
///     achievable without seeding the real Keychain. Instead, test (a)
///     exercises `OpenGateFlow.run` directly (the same call
///     `OpenGateIntent.runFlow` makes) through the REAL, injected
///     `environment.snapshotStore` and `environment.appSettings` built by
///     `AppEnvironment.make(defaults: <in-memory>)`, with a fake `open`
///     closure standing in for `environment.controller.openGate()` —  this
///     is "AppEnvironment's observable behaviour as far as possible",
///     using the actual composition-root-built snapshot store/settings
///     rather than a bare `WidgetSnapshotStore` built by hand. The
///     ordering assertion itself is ALSO covered, with a real
///     `GateController`-driven `open` closure, by
///     `Tests/GateOpenerCoreTests/OpenGateFlowTests
///     .reachableSuccessWritesOpeningThenSucceeded` in the SwiftPM
///     package — this iOS-bundle test complements that by routing through
///     the real `AppEnvironment`-constructed `snapshotStore`/`appSettings`
///     instead of a hand-built `WidgetSnapshotStore`.
@MainActor
struct OpenGateIntentTests {
    // MARK: - (a) opening -> succeeded ordering, through AppEnvironment's real snapshotStore/appSettings

    /// MUTATION CHECK: removing `write(.opening, ...)` in
    /// `OpenGateFlow.run` (Sources/GateOpenerCore/OpenGateFlow.swift)
    /// collapses `recorder.phases` to `[.succeeded]` — this test fails on
    /// the `recorder.phases == [.opening, .succeeded]` assertion. Removing
    /// the final `write(terminalState, ...)` call collapses it to
    /// `[.opening]` and also fails.
    @Test func openingThenSucceededOrderingThroughAppEnvironmentSnapshotStore() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let reloadCounter = LockedCounter()
        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: { reloadCounter.increment() },
            gateClient: FakeGateOpening(),
            tokenResolver: FakeTokenResolving()
        )

        let recorder = PhaseRecorder()
        // `WidgetSnapshotStore` is `Sendable` (backed only by
        // `UserDefaults`), so capturing it directly (rather than the
        // `@MainActor`-isolated `environment`) into this `@Sendable`
        // `reloadTimelines` closure is safe.
        let snapshotStore = environment.snapshotStore

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: snapshotStore,
            reloadTimelines: {
                recorder.record(snapshotStore.read()?.phase)
            }
        )

        #expect(outcome == .opened)
        #expect(recorder.phases == [.opening, .succeeded])
        #expect(snapshotStore.read()?.phase == .succeeded)
        #expect(recorder.phases.count >= 2)
    }

    // MARK: - (b) needsSetup -> zero gateClient.open calls, driven through the real intent

    /// A freshly-constructed `AppEnvironment.make()` with an in-memory
    /// defaults suite and no stored credentials starts `.needsSetup` (see
    /// `GateController.init`'s credential/selected-gate check) — this
    /// drives `OpenGateIntent.runFlow(environment:)` itself, not a
    /// hand-rolled substitute, and asserts zero calls reached the fake
    /// `GateOpening`.
    ///
    /// MUTATION CHECK (verified by temporarily commenting out the guard
    /// and re-running): removing the `if currentState == .needsSetup`
    /// short-circuit in `OpenGateFlow.run` (Sources/GateOpenerCore/
    /// OpenGateFlow.swift) makes this fall through to the reachable/open
    /// branch. With no gate ever selected in this environment,
    /// `GateController.performOpen()`'s `requireSelectedEndpointId()`
    /// throws `.notConfigured` before ever calling `gateClient.open`, which
    /// `OpenGateFlow`'s race-and-map logic (having skipped the needsSetup
    /// short-circuit) reports as `.failed(message: "Unknown result")`
    /// rather than `.needsSetup` — flipping both the `outcome ==
    /// .needsSetup` and `outcome.dialog` assertions below to failing. (The
    /// `gateClient.openCallCount == 0` assertion alone would NOT catch this
    /// particular mutation, since `.notConfigured` is thrown before
    /// `gateClient.open` either way; the outcome/dialog assertions are what
    /// make this test non-vacuous against this specific production line.)
    @Test func needsSetupStateMakesZeroOpenCalls() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let fakeGateClient = FakeGateOpening()
        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            gateClient: fakeGateClient,
            tokenResolver: FakeTokenResolving()
        )

        #expect(environment.controller.state == .needsSetup)

        let outcome = await OpenGateIntent.runFlow(environment: environment)

        #expect(outcome == .needsSetup)
        #expect(outcome.dialog == "Sign in to GateOpener first")
        #expect(fakeGateClient.openCallCount == 0)
    }
}
