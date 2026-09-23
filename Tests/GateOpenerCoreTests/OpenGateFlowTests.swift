import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `OpenGateFlow`. Each test uses a UNIQUE `UserDefaults
/// (suiteName:)` (via a UUID) and removes the suite in teardown, matching
/// `WidgetSnapshotTests`'s pattern, so tests never pollute the real app
/// domain, the shared app-group domain, or each other.
///
/// Per the `gateopener-vacuous-assertion-failure-mode` memory, every
/// assertion here is mutation-checked at least once (see the inline notes
/// below) rather than trusted on the strength of "the test passes".
struct OpenGateFlowTests {
    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "ie.boboco.GateOpener.test.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for testing")
        }
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    // MARK: - needsSetup short-circuit

    /// Zero `open()` calls, snapshot phase `needsSetup`, exactly one reload.
    ///
    /// MUTATION CHECK: removing the `currentState == .needsSetup` guard in
    /// `OpenGateFlow.run` (so this path falls through to the reachable/open
    /// branch) makes `openCallCount` go from 0 to 1 and the outcome flip
    /// from `.needsSetup` to `.opened`/`.failed` — this test would then
    /// fail on both the outcome assertion and the call-count assertion, so
    /// it is not vacuous.
    @Test func needsSetupShortCircuitsWithZeroOpenCalls() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let openCallCount = Counter()
        let reloadCount = LockedCounter()

        let outcome = await OpenGateFlow().run(
            currentState: .needsSetup,
            gateName: "Front Gate",
            isReachable: true,
            open: {
                await openCallCount.increment()
                return .succeeded(at: Date())
            },
            snapshot: store,
            reloadTimelines: { reloadCount.increment() }
        )

        #expect(outcome == .needsSetup)
        #expect(outcome.dialog == "Sign in to GateOpener first")
        let calls = await openCallCount.value
        #expect(calls == 0)
        #expect(reloadCount.value == 1)
        #expect(store.read()?.phase == .needsSetup)
        #expect(store.read()?.message == nil)
    }

    // MARK: - Reachable success

    /// Snapshots are written in order [opening, succeeded], captured via a
    /// recording reload closure that reads the store on each invocation
    /// (rather than only inspecting the final value), so this actually
    /// exercises ordering, not just the end state.
    @Test func reachableSuccessWritesOpeningThenSucceeded() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let recorder = PhaseRecorder()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store,
            reloadTimelines: {
                let phase = store.read()?.phase
                recorder.record(phase)
            }
        )

        #expect(outcome == .opened)
        #expect(outcome.dialog == "Gate opened")
        #expect(recorder.phases == [.opening, .succeeded])
        #expect(store.read()?.phase == .succeeded)
    }

    // MARK: - Underlying failure

    @Test func openFailureMapsToFailedOutcomeCarryingMessage() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .failed(message: "x") },
            snapshot: store,
            reloadTimelines: {}
        )

        #expect(outcome == .failed(message: "x"))
        #expect(outcome.dialog == "x")
        #expect(store.read()?.phase == .failed)
        #expect(store.read()?.message == "x")
    }

    // MARK: - Unreachable fail-fast

    /// Zero `open()` calls when unreachable — the extension must not queue
    /// or wait 45s.
    ///
    /// MUTATION CHECK: removing the `guard isReachable else { ... }`
    /// short-circuit (so this always falls through to the `open()` call)
    /// makes `openCallCount` go from 0 to 1 and the outcome flip from
    /// `.failed("No network")` to `.opened` (the injected `open` here
    /// returns `.succeeded`), so both assertions would fail — not vacuous.
    @Test func unreachableFailsFastWithZeroOpenCalls() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let openCallCount = Counter()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: false,
            open: {
                await openCallCount.increment()
                return .succeeded(at: Date())
            },
            snapshot: store,
            reloadTimelines: {}
        )

        #expect(outcome == .failed(message: "No network"))
        #expect(outcome.dialog == "No network")
        let calls = await openCallCount.value
        #expect(calls == 0)
        #expect(store.read()?.phase == .failed)
        #expect(store.read()?.message == "No network")
        // No `.opening` snapshot should ever have been written on this path.
    }

    // MARK: - Timeout

    /// `open()` never returns (awaits a `Task.sleep` far longer than the
    /// test's timeout, with cancellation handled so the Task doesn't leak
    /// past the test). With `timeout: .milliseconds(50)`, the flow must
    /// give up and report `.timedOut`.
    ///
    /// MUTATION CHECK: removing the timeout race in `raceAgainstTimeout`
    /// (e.g. by only awaiting `open()` directly with no competing timeout
    /// task) makes this test hang/fail (never completes within the test
    /// runner's patience), so the assertion is not vacuous — there is no
    /// way for `.timedOut` to be produced without the race actually firing.
    @Test func openNeverReturningTimesOut() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    // Cancelled by the losing side of the race; fall through
                    // to a value that would count as "opened" if somehow
                    // still observed, so a broken race couldn't accidentally
                    // masquerade as a correct timeout via this catch path.
                }
                return .succeeded(at: Date())
            },
            snapshot: store,
            reloadTimelines: {},
            timeout: .milliseconds(50)
        )

        #expect(outcome == .timedOut)
        #expect(outcome.dialog == "Timed out")
        #expect(store.read()?.phase == .failed)
        #expect(store.read()?.message == "Timed out")
    }

    // MARK: - Press-level journal phases (gateopener-41m.22)

    /// Thread-safe recorder for `OpenPressRecord`s emitted via the `journal`
    /// closure, same `NSLock` + `@unchecked Sendable` idiom used elsewhere in
    /// this file.
    private final class PressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _records: [OpenPressRecord] = []

        func record(_ record: OpenPressRecord) {
            lock.lock()
            _records.append(record)
            lock.unlock()
        }

        var records: [OpenPressRecord] {
            lock.lock()
            defer { lock.unlock() }
            return _records
        }
    }

    @Test func needsSetupEmitsReachabilityThenFinished() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let recorder = PressRecorder()

        let outcome = await OpenGateFlow().run(
            currentState: .needsSetup,
            gateName: "Front Gate",
            isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store,
            reloadTimelines: {},
            journal: { recorder.record($0) }
        )

        #expect(outcome == .needsSetup)
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: true, detail: ""),
            .finished(outcome: "Sign in to GateOpener first"),
        ])
    }

    @Test func unreachableEmitsReachabilityThenFinishedWithNoNetwork() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let recorder = PressRecorder()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: false,
            open: { .succeeded(at: Date()) },
            snapshot: store,
            reloadTimelines: {},
            journal: { recorder.record($0) }
        )

        #expect(outcome == .failed(message: "No network"))
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: false, detail: ""),
            .finished(outcome: "No network"),
        ])
    }

    @Test func openedEmitsReachabilityOpenStartedThenFinished() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let recorder = PressRecorder()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store,
            reloadTimelines: {},
            journal: { recorder.record($0) }
        )

        #expect(outcome == .opened)
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .finished(outcome: "Gate opened"),
        ])
    }

    @Test func failedEmitsReachabilityOpenStartedThenFinishedWithMessage() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let recorder = PressRecorder()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .failed(message: "x") },
            snapshot: store,
            reloadTimelines: {},
            journal: { recorder.record($0) }
        )

        #expect(outcome == .failed(message: "x"))
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .finished(outcome: "x"),
        ])
    }

    @Test func timedOutEmitsReachabilityOpenStartedThenTimedOut() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let recorder = PressRecorder()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    // Cancelled by the losing side of the race.
                }
                return .succeeded(at: Date())
            },
            snapshot: store,
            reloadTimelines: {},
            timeout: .milliseconds(50),
            journal: { recorder.record($0) }
        )

        #expect(outcome == .timedOut)
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .timedOut,
        ])
    }

    // MARK: - TaskLocal pressId propagation into open() (gateopener-41m.22)

    /// `OpenGateFlow.run` wraps `open()` in
    /// `OpenPressContext.$pressId.withValue(pressId)`, and `open()` itself
    /// runs inside a `TaskGroup` child task (`raceAgainstTimeout`) -- this
    /// proves the `@TaskLocal` value set on the parent task before
    /// `group.addTask` IS inherited by that child task, by reading
    /// `OpenPressContext.pressId` from inside the `open` closure itself.
    ///
    /// MUTATION CHECK: if `run` bound the TaskLocal around a scope that did
    /// NOT actually enclose `raceAgainstTimeout`'s `addTask` call (e.g. bound
    /// it only around a no-op), `observedPressId` would capture `nil`
    /// instead of the real `pressId`, and the final `#expect` would fail.
    @Test func openClosureObservesTaskLocalPressIdSetByRun() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let holder = PressIdHolder()
        let explicitPressId = UUID()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: {
                holder.record(OpenPressContext.pressId)
                return .succeeded(at: Date())
            },
            snapshot: store,
            reloadTimelines: {},
            pressId: explicitPressId
        )

        #expect(outcome == .opened)
        #expect(holder.value == explicitPressId)
    }

    /// End-to-end: `open` wraps a real `GateClient.open` (wired with an
    /// `attemptObserver`), and `OpenGateFlow.run` is given an explicit
    /// `pressId`. Every `OpenAttemptRecord` the `GateClient` call produces
    /// must carry that same `pressId`, proving the TaskLocal set by `run`
    /// really does reach `GateClient.report(...)` through the `open` closure
    /// and the `raceAgainstTimeout` child task in between.
    @Test func attemptRecordsProducedInsideOpenCarryTheFlowsPressId() async throws {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let script = RequestScript(statuses: [500, 202])
        let session = makeSequencedSession(script: script)
        let credentialStore = MockCredentialStore()
        let issuing = MockTokenIssuing()
        try? credentialStore.saveCredentials(username: "alice", password: "s3cret")
        issuing.loginResult = .success(
            TokenSet(accessToken: "the-access-token", refreshToken: "rt", expiresIn: 3600, tokenType: "bearer")
        )
        let tokenManager = TokenManager(api: issuing, credentialStore: credentialStore)
        let observer = RecordingAttemptObserver()
        let client = GateClient(
            session: session,
            tokenManager: tokenManager,
            retryPolicy: .noDelay(),
            attemptObserver: observer
        )

        let explicitPressId = UUID()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: {
                do {
                    try await client.open(endpointId: "VIP#OD#SB100001.1")
                    return .succeeded(at: Date())
                } catch {
                    return .failed(message: "x")
                }
            },
            snapshot: store,
            reloadTimelines: {},
            pressId: explicitPressId
        )

        #expect(outcome == .opened)
        let records = observer.records
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.pressId == explicitPressId })
    }
}

/// Thread-safe single-slot holder for a `UUID?` observed from inside an
/// `open` closure, same `NSLock` + `@unchecked Sendable` idiom used
/// elsewhere in this file.
private final class PressIdHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: UUID?

    func record(_ value: UUID?) {
        lock.lock()
        _value = value
        lock.unlock()
    }

    var value: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

/// Actor-backed counter so `open` closures (which must be `@Sendable`) can
/// record call counts without a data race.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Lock-backed synchronous counter for `@Sendable` closures (like
/// `reloadTimelines`) that are not `async`, so an `actor` is not usable
/// directly from inside them.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

/// Records the sequence of `WidgetSnapshot.Phase` values observed each time
/// `reloadTimelines` fires, so `reachableSuccessWritesOpeningThenSucceeded`
/// can assert ORDER, not just the final snapshot.
private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [WidgetSnapshot.Phase?] = []

    func record(_ phase: WidgetSnapshot.Phase?) {
        lock.lock()
        _phases.append(phase)
        lock.unlock()
    }

    var phases: [WidgetSnapshot.Phase?] {
        lock.lock()
        defer { lock.unlock() }
        return _phases
    }
}
