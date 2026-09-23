import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `GateControllerObservable`'s in-app press journaling (bead
/// gateopener-41m.23), using the `testController:` seam (see that
/// initializer's doc comment for why: `AppEnvironment.make()` has no
/// `credentialStore:` injection, so there is no way to get an
/// `AppEnvironment`-backed controller to start `.idle` without touching the
/// real Keychain access group).
@MainActor
struct GateControllerObservableTests {
    private func makeTempJournalURL(function: String = #function) -> (url: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GateControllerObservableTests-\(function)-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("open-attempts.jsonl")
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Builds a `GateController` that starts `.idle` (a selected gate +
    /// stored credentials in an in-memory, never-real-Keychain store),
    /// mirroring `BackgroundOpenRunnerTests.makeIdleController`.
    private func makeIdleController(
        defaults: UserDefaults,
        gateClient: FakeGateOpening,
        reachability: any ReachabilityProviding = AlwaysReachable()
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
            reachability: reachability
        )
    }

    private func pressRecords(at url: URL) -> [OpenPressRecord] {
        OpenAttemptJournal(fileURL: url).journalEntries().compactMap {
            if case .press(let record) = $0 { return record }
            return nil
        }
    }

    /// Polls `condition` against a 2s wall-clock deadline (mirroring
    /// `DoorVideoCoordinatorTests.swift:112-114` /
    /// `DoorVideoCoordinatorPinTests.swift:15-17`) rather than a fixed
    /// `Task.yield()` iteration count -- `observable.state`'s path to a
    /// terminal value crosses two unstructured `Task` hops
    /// (`GateController.requestOpen()` -> `Task { openGate() }` -> `Task {
    /// performOpen() }`) that need the global executor, so a fixed count of
    /// main-actor-only yields can drain before the result lands, making a
    /// count-based loop flaky.
    private func waitUntilDeadline(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    /// `requestOpen()` while reachable writes `started` (source "app"),
    /// followed by `finished("Gate opened")` once the underlying
    /// `GateController` reaches `.succeeded` — both sharing one `pressId`.
    ///
    /// MUTATION CHECK: removing the `emit(.started, ...)` call in
    /// `GateControllerObservable.requestOpen()` collapses `phases` to just
    /// `[finished(...)]`, failing the `phases ==` assertion.
    @Test func requestOpenSuccessWritesStartedThenFinishedGateOpened() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let gateClient = FakeGateOpening()
        let controller = makeIdleController(defaults: defaults, gateClient: gateClient)
        let host = FakeBackgroundTaskHost()
        let runner = BackgroundOpenRunner(controller: controller, host: host)
        let journal = OpenAttemptJournal(fileURL: journalURL, capacity: 1000)

        let observable = GateControllerObservable(testController: controller, backgroundOpenRunner: runner, journal: journal)

        observable.requestOpen()

        // Latch on the journal itself reaching a terminal `.finished` record
        // (not a re-read of `observable.state`, which can bounce back to
        // `.idle` via the controller's injected no-op-sleep auto-reset before
        // a late poll observes it).
        await waitUntilDeadline {
            pressRecords(at: journalURL).contains { if case .finished = $0.phase { return true }; return false }
        }

        let records = pressRecords(at: journalURL)
        let phases = records.map(\.phase)
        #expect(phases == [.started, .finished(outcome: "Gate opened")])
        #expect(Set(records.map(\.pressId)).count == 1)
        #expect(records.allSatisfy { $0.source == "app" })
    }

    /// Failure variant: `FakeGateOpening.shouldSucceed = false` makes the
    /// controller reach `.failed(message:)` instead, so the press ends in
    /// `.finished(outcome: <that message>)`.
    @Test func requestOpenFailureWritesStartedThenFinishedWithMessage() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let gateClient = FakeGateOpening()
        gateClient.shouldSucceed = false
        let controller = makeIdleController(defaults: defaults, gateClient: gateClient)
        let host = FakeBackgroundTaskHost()
        let runner = BackgroundOpenRunner(controller: controller, host: host)
        let journal = OpenAttemptJournal(fileURL: journalURL, capacity: 1000)

        let observable = GateControllerObservable(testController: controller, backgroundOpenRunner: runner, journal: journal)

        observable.requestOpen()

        // Latch on the journal reaching a terminal `.finished` record (see
        // `waitUntilDeadline`'s doc comment for why re-reading
        // `observable.state` is unreliable here).
        await waitUntilDeadline {
            pressRecords(at: journalURL).contains { if case .finished = $0.phase { return true }; return false }
        }

        let records = pressRecords(at: journalURL)
        let phases = records.map(\.phase)
        guard case .finished(let outcome) = phases.last else {
            Issue.record("expected a finished phase, got \(phases)")
            return
        }
        #expect(phases.first == .started)
        #expect(outcome != "Gate opened")
        #expect(Set(records.map(\.pressId)).count == 1)
    }

    /// Queued path: an unreachable controller queues the request instead of
    /// opening immediately, so the observable sees `.queued` before any
    /// terminal state — writing `started` -> `reachability(false, detail)`,
    /// using the injected `reachabilityDetail` closure verbatim.
    ///
    /// MUTATION CHECK: removing the `.queued` case's `emit(.reachability...)`
    /// call in `GateControllerObservable.handleStateChange(_:)` collapses
    /// `phases` to `[started]` at the point this test samples it (before the
    /// TTL fires), failing the `phases ==` assertion.
    @Test func requestOpenWhenUnreachableWritesStartedThenReachabilityFalseWithDetail() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }
        let (journalURL, cleanupJournal) = makeTempJournalURL()
        defer { cleanupJournal() }

        let gateClient = FakeGateOpening()
        let unreachable = FakeReachabilityProviding(isReachable: false)
        let controller = makeIdleController(defaults: defaults, gateClient: gateClient, reachability: unreachable)
        let host = FakeBackgroundTaskHost()
        let runner = BackgroundOpenRunner(controller: controller, host: host)
        let journal = OpenAttemptJournal(fileURL: journalURL, capacity: 1000)

        let observable = GateControllerObservable(
            testController: controller,
            backgroundOpenRunner: runner,
            journal: journal,
            reachabilityDetail: { "unsatisfied none expensive=false constrained=false" }
        )

        observable.requestOpen()

        // Latch on the journal reaching the `.reachability` record (see
        // `waitUntilDeadline`'s doc comment) rather than re-reading
        // `observable.state`.
        await waitUntilDeadline {
            pressRecords(at: journalURL).contains { if case .reachability = $0.phase { return true }; return false }
        }
        #expect(observable.state == .queued)

        let records = pressRecords(at: journalURL)
        let phases = records.map(\.phase)
        #expect(phases == [
            .started,
            .reachability(isReachable: false, detail: "unsatisfied none expensive=false constrained=false"),
        ])
        #expect(Set(records.map(\.pressId)).count == 1)
    }

    /// A `nil` journal (mirrors `environment.openAttemptJournal == nil`,
    /// e.g. no App Group container) must make every write a silent no-op —
    /// `requestOpen()` and the resulting state transitions must not crash or
    /// write anything.
    @Test func nilJournalWritesNothingAndNeverCrashes() async {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let gateClient = FakeGateOpening()
        let controller = makeIdleController(defaults: defaults, gateClient: gateClient)
        let host = FakeBackgroundTaskHost()
        let runner = BackgroundOpenRunner(controller: controller, host: host)

        let observable = GateControllerObservable(testController: controller, backgroundOpenRunner: runner, journal: nil)

        // No journal exists here to latch on, so capture the first terminal
        // state directly via a chained `controller.onStateChange` observer
        // (see `waitUntilDeadline`'s doc comment for why re-reading
        // `observable.state` at the end of a fixed-count poll loop is
        // unreliable: the controller's injected no-op-sleep auto-reset can
        // bounce a late-observed `.succeeded` back to `.idle`). This chains
        // onto -- rather than replaces -- the handler `GateControllerObservable
        // .init(testController:...)` already installed, since `onStateChange`
        // is a single-slot closure property.
        var capturedTerminalState: GateState?
        let previousHandler = controller.onStateChange
        controller.onStateChange = { newState in
            previousHandler?(newState)
            if capturedTerminalState == nil {
                switch newState {
                case .succeeded, .failed:
                    capturedTerminalState = newState
                default:
                    break
                }
            }
        }

        observable.requestOpen()

        await waitUntilDeadline { capturedTerminalState != nil }

        guard let capturedTerminalState else {
            Issue.record("expected a terminal state to be observed within the deadline")
            return
        }
        #expect(capturedTerminalState.isSucceeded)
    }
}

private extension GateState {
    var succeededDate: Date? {
        if case .succeeded(let date) = self { return date }
        return nil
    }

    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
