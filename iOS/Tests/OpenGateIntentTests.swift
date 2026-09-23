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

    // MARK: - Press journal (bead gateopener-41m.23)
    //
    // `OpenGateIntent.runFlow` opens its OWN direct `OpenAttemptJournal`
    // (via `journalURLOverride`, a DEBUG-only test seam -- see that
    // property's doc comment) BEFORE `AppEnvironment.make()`, independent
    // of whatever `AppEnvironment.make(openAttemptJournalURL:)` itself
    // wires. Every test below points `journalURLOverride` at the SAME temp
    // URL passed to `AppEnvironment.make(openAttemptJournalURL:)`, so both
    // instances write to (and this test reads back from) one file -- never
    // the real App Group container.

    private func makeTempJournalURL(function: String = #function) -> (url: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGateIntentTests-\(function)-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("open-attempts.jsonl")
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Successful/failure full-sequence coverage, per the SAME "IMPORTANT
    /// GAP" documented at the top of this file: `OpenGateIntent.runFlow`'s
    /// `.opening -> .succeeded`/`.failed` ordering cannot be driven end to
    /// end through the real intent without an `AppEnvironment` whose
    /// controller starts `.idle`, which requires seeding the real Keychain
    /// (not permitted in this test bundle). Instead, this drives
    /// `OpenGateFlow.run` DIRECTLY with the exact same
    /// `pressId`/`pressStartedAt`/`journal`/`pressSource`/`pressProcess`/
    /// `pressAppVersion` arguments `OpenGateIntent.runFlow` itself passes
    /// (see that method's implementation), preceded by the two press lines
    /// (`started`, `environmentReady`) the intent writes directly BEFORE
    /// calling `run` -- i.e. this manually replays the intent's own
    /// pre-`run` sequence against a real `AppEnvironment`-constructed
    /// `snapshotStore`, exactly mirroring what `runFlow` does, so the
    /// resulting on-disk press sequence is provably identical to what a real
    /// `.idle`-starting run would produce. The full `.opening -> .succeeded`
    /// snapshot-ordering assertion itself is separately covered by test (a)
    /// above and by `OpenGateFlowTests.reachableSuccessWritesOpeningThenSucceeded`.
    ///
    /// MUTATION CHECK: removing `OpenGateFlow.run`'s `emit(.openStarted)`
    /// or its terminal `emit(.finished(...))` call collapses `phases` below,
    /// failing the `phases ==` assertion; passing a different `pressId`
    /// into `run` than the two lines written directly above it would fail
    /// `Set(pressIds).count == 1`.
    @Test func successfulOpenWritesFullPressSequenceWithOnePressId() async throws {
        let (defaults, cleanupDefaults) = makeInMemoryDefaults()
        defer { cleanupDefaults() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            gateClient: FakeGateOpening(),
            tokenResolver: FakeTokenResolving(),
            openAttemptJournalURL: journalURL
        )

        let journal = OpenAttemptJournal(fileURL: journalURL, capacity: 1000)
        let pressId = UUID()
        let pressStartedAt = Date()
        let process = Bundle.main.bundleIdentifier ?? "?"
        let appVersion = AppVersion.current

        // Replays the intent's own pre-`AppEnvironment.make()`/pre-`run`
        // writes (see `OpenGateIntent.runFlow`).
        journal.record(OpenPressRecord(
            pressId: pressId, timestamp: pressStartedAt, source: "intent",
            process: process, appVersion: appVersion, phase: .started, elapsedMilliseconds: 0
        ))
        journal.record(OpenPressRecord(
            pressId: pressId, timestamp: Date(), source: "intent",
            process: process, appVersion: appVersion, phase: .environmentReady, elapsedMilliseconds: 0
        ))

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: environment.snapshotStore,
            reloadTimelines: {},
            journal: { journal.record($0) },
            pressId: pressId,
            pressStartedAt: pressStartedAt,
            reachabilityDetail: "",
            pressSource: "intent",
            pressProcess: process,
            pressAppVersion: appVersion
        )
        #expect(outcome == .opened)

        let entries = journal.journalEntries()
        let pressRecords: [OpenPressRecord] = entries.compactMap {
            if case .press(let record) = $0 { return record }
            return nil
        }
        let phases = pressRecords.map(\.phase)
        #expect(phases == [
            .started,
            .environmentReady,
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .finished(outcome: "Gate opened"),
        ])
        #expect(Set(pressRecords.map(\.pressId)).count == 1)
        #expect(pressRecords.allSatisfy { $0.source == "intent" })
        #expect(pressRecords.allSatisfy { $0.process == process })
        // No attempt lines at all: the `open` closure here never touches a
        // real `GateClient`/`attemptObserver`.
        #expect(entries.allSatisfy { if case .press = $0 { return true } else { return false } })
    }

    /// Failure variant of the test above: `open` returns `.failed(message:)`
    /// directly, so the press sequence still runs start-to-finish, ending in
    /// `.finished(outcome: <the failure message>)` rather than "Gate opened".
    @Test func failedOpenWritesFinishedWithFailureMessage() async throws {
        let (defaults, cleanupDefaults) = makeInMemoryDefaults()
        defer { cleanupDefaults() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            gateClient: FakeGateOpening(),
            tokenResolver: FakeTokenResolving(),
            openAttemptJournalURL: journalURL
        )

        let journal = OpenAttemptJournal(fileURL: journalURL, capacity: 1000)
        let pressId = UUID()
        let pressStartedAt = Date()
        let process = Bundle.main.bundleIdentifier ?? "?"
        let appVersion = AppVersion.current

        journal.record(OpenPressRecord(
            pressId: pressId, timestamp: pressStartedAt, source: "intent",
            process: process, appVersion: appVersion, phase: .started, elapsedMilliseconds: 0
        ))
        journal.record(OpenPressRecord(
            pressId: pressId, timestamp: Date(), source: "intent",
            process: process, appVersion: appVersion, phase: .environmentReady, elapsedMilliseconds: 0
        ))

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .failed(message: "Server error") },
            snapshot: environment.snapshotStore,
            reloadTimelines: {},
            journal: { journal.record($0) },
            pressId: pressId,
            pressStartedAt: pressStartedAt,
            reachabilityDetail: "",
            pressSource: "intent",
            pressProcess: process,
            pressAppVersion: appVersion
        )
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }

        let pressRecords: [OpenPressRecord] = journal.journalEntries().compactMap {
            if case .press(let record) = $0 { return record }
            return nil
        }
        let phases = pressRecords.map(\.phase)
        #expect(phases == [
            .started,
            .environmentReady,
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .finished(outcome: message),
        ])
        #expect(Set(pressRecords.map(\.pressId)).count == 1)
    }

    /// `needsSetup` variant: `OpenGateFlow.run` emits `.reachability` BEFORE
    /// its `currentState == .needsSetup` check (read directly from
    /// `OpenGateFlow.run`'s implementation -- the reachability phase is
    /// unconditional), so the sequence is `started` -> `environmentReady` ->
    /// `reachability` -> `finished("Sign in to GateOpener first")`, with NO
    /// `openStarted` (the flow short-circuits before ever calling `open()`).
    @Test func needsSetupRunWritesReachabilityThenFinishedWithNoOpenStarted() async throws {
        let (defaults, cleanupDefaults) = makeInMemoryDefaults()
        defer { cleanupDefaults() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        OpenGateIntent.journalURLOverride = .some(journalURL)
        defer { OpenGateIntent.journalURLOverride = nil }

        let fakeGateClient = FakeGateOpening()
        let environment = AppEnvironment.make(
            defaults: defaults,
            reachability: FakeReachabilityProviding(isReachable: true),
            timelineReloader: {},
            gateClient: fakeGateClient,
            tokenResolver: FakeTokenResolving(),
            openAttemptJournalURL: journalURL
        )
        #expect(environment.controller.state == .needsSetup)

        let outcome = await OpenGateIntent.runFlow(environment: environment)
        #expect(outcome == .needsSetup)
        #expect(outcome.dialog == "Sign in to GateOpener first")
        #expect(fakeGateClient.openCallCount == 0)

        let journal = OpenAttemptJournal(fileURL: journalURL)
        let pressRecords: [OpenPressRecord] = journal.journalEntries().compactMap {
            if case .press(let record) = $0 { return record }
            return nil
        }
        let phases = pressRecords.map(\.phase)
        // `runFlow` constructs its own `NWPathMonitorReachability()` inline
        // (see that method's implementation). Usually a fresh instance has
        // not yet received any path update when `pathDescription` is read,
        // so it reports its documented placeholder ("unknown (monitor just
        // started)") rather than a real path summary (see
        // `NWPathMonitorReachabilityTests
        // .pathDescriptionIsUnknownBeforeAnyPathUpdate`). But `NWPathMonitor`
        // can occasionally deliver its first path update before `runFlow`
        // reads `pathDescription`, in which case the detail is a real path
        // summary like "satisfied wifi expensive=false constrained=false"
        // instead. Assert the phase case and `isReachable`, and that
        // `detail` is non-empty, rather than pinning the exact string.
        #expect(phases.count == 4)
        #expect(phases[0] == .started)
        #expect(phases[1] == .environmentReady)
        if case .reachability(let isReachable, let detail) = phases[2] {
            #expect(isReachable == true)
            #expect(!detail.isEmpty)
        } else {
            Issue.record("expected .reachability phase at index 2, got \(phases[2])")
        }
        #expect(phases[3] == .finished(outcome: "Sign in to GateOpener first"))
        #expect(Set(pressRecords.map(\.pressId)).count == 1)
    }
}
