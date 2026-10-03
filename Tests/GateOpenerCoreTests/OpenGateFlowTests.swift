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

        // "x" is a retryable failure, so the loop keeps trying until the
        // deadline; a fake clock + instant sleep makes that instantaneous.
        let clock = FakeClock()
        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .failed(message: "x") },
            snapshot: store,
            reloadTimelines: {},
            sleep: clock.sleep,
            now: clock.now,
            pressStartedAt: clock.start
        )

        #expect(outcome == .failed(message: "x"))
        #expect(outcome.dialog == "x")
        #expect(store.read()?.phase == .failed)
        #expect(store.read()?.message == "x")
    }

    // MARK: - Unreachable and never recovering: "No network" without any open() call
    // (Behaviour note: the loop calls `waitForReachability`, whose default
    // `{ _ in false }` means the network never comes back, so it gives up
    // with "No network". A .waitingForNetwork phase is additionally journaled.)

    /// Zero `open()` calls when the network never recovers — the extension
    /// must not queue an open or wait out the full deadline.
    ///
    /// MUTATION CHECK: if the loop skipped the reachability wait/give-up and
    /// fell through to the `open()` call anyway, `openCallCount` would go from
    /// 0 to 1 and the outcome would flip from `.failed("No network")` to
    /// `.opened` (the injected `open` here returns `.succeeded`), so both
    /// assertions would fail — not vacuous.
    @Test func unreachableNeverRecoveringFailsWithZeroOpenCalls() async {
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
        // The loop publishes `.opening` once at start, then the terminal
        // `.failed` (asserted above) once the reachability wait gives up.
    }

    // MARK: - Timeout

    /// `open()` never returns (awaits a `Task.sleep` far longer than the
    /// test's timeout, with cancellation handled so the Task doesn't leak
    /// past the test). With a 50ms deadline, the flow must
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
            deadline: .milliseconds(50),
            minimumAttemptWindow: .zero
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
            .waitingForNetwork,
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
            .attempt(number: 1),
            .finished(outcome: "Gate opened"),
        ])
    }

    @Test func failedEmitsReachabilityOpenStartedThenFinishedWithMessage() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let recorder = PressRecorder()
        // Non-retryable message => exactly one attempt phase.
        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: { .failed(message: "Wrong username or password") },
            snapshot: store,
            reloadTimelines: {},
            journal: { recorder.record($0) }
        )

        #expect(outcome == .failed(message: "Wrong username or password"))
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .attempt(number: 1),
            .finished(outcome: "Wrong username or password"),
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
            deadline: .milliseconds(50),
            minimumAttemptWindow: .zero,
            journal: { recorder.record($0) }
        )

        #expect(outcome == .timedOut)
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .attempt(number: 1),
            .timedOut,
        ])
    }


    // MARK: - Persistent retry loop (gateopener-6qa.1)

    /// Fake clock: `now` reads a locked date, `sleep` advances it instantly.
    private final class FakeClock: @unchecked Sendable {
        let start = Date(timeIntervalSince1970: 1_000_000)
        private let lock = NSLock()
        private var offset: TimeInterval = 0

        var now: @Sendable () -> Date {
            { [self] in
                lock.lock(); defer { lock.unlock() }
                return start.addingTimeInterval(offset)
            }
        }
        var sleep: @Sendable (Duration) async throws -> Void {
            { [self] duration in advance(duration.timeInterval) }
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); offset += seconds; lock.unlock()
        }
        var elapsed: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return offset
        }
    }

    /// Records, per open() call, how much time remained before the 27s deadline.
    private final class AttemptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _remaining: [TimeInterval] = []
        func record(_ r: TimeInterval) { lock.lock(); _remaining.append(r); lock.unlock() }
        var remaining: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _remaining }
        var count: Int { remaining.count }
    }

    private func attemptNumbers(_ recorder: PressRecorder) -> [Int] {
        recorder.records.compactMap {
            if case .attempt(let n) = $0.phase { return n }
            return nil
        }
    }

    @Test func succeedsOnFirstAttempt() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let clock = FakeClock()
        let recorder = PressRecorder()
        let log = AttemptLog()

        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: true,
            open: { log.record(0); return .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            sleep: clock.sleep, now: clock.now,
            journal: { recorder.record($0) }, pressStartedAt: clock.start
        )
        #expect(outcome == .opened)
        #expect(log.count == 1)
        #expect(attemptNumbers(recorder) == [1])
    }

    @Test func failFailSucceedOpensWithThreeAttemptPhases() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let clock = FakeClock()
        let recorder = PressRecorder()
        let calls = LockedCounter()
        let reloads = LockedCounter()

        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: true,
            open: {
                calls.increment()
                clock.advance(3)
                return calls.value < 3 ? .failed(message: "Network too slow - try again") : .succeeded(at: Date())
            },
            snapshot: store, reloadTimelines: { reloads.increment() },
            sleep: clock.sleep, now: clock.now,
            journal: { recorder.record($0) }, pressStartedAt: clock.start
        )
        #expect(outcome == .opened)
        #expect(calls.value == 3)
        #expect(attemptNumbers(recorder) == [1, 2, 3])
        // Snapshot writes: .opening once + terminal once, no per-attempt spam.
        #expect(reloads.value == 2)
        #expect(store.read()?.phase == .succeeded)
    }

    @Test func alwaysFailStopsBeforeDeadlineAndNeverStartsLateAttempt() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let clock = FakeClock()
        let log = AttemptLog()
        let deadline: TimeInterval = 27

        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: true,
            open: {
                log.record(deadline - clock.elapsed)
                clock.advance(4)
                return .failed(message: "Gate service error (503)")
            },
            snapshot: store, reloadTimelines: {},
            sleep: clock.sleep, now: clock.now, pressStartedAt: clock.start
        )
        #expect(outcome == .failed(message: "Gate service error (503)"))
        #expect(log.count > 1)
        // MUTATION CHECK: dropping the minimumAttemptWindow check makes an
        // attempt start with < 3.5s remaining and this assertion fail.
        #expect(log.remaining.allSatisfy { $0 >= 3.5 })
        #expect(clock.elapsed <= deadline)
        #expect(store.read()?.message == "Gate service error (503)")
    }

    @Test func nonRetryableFailuresMakeExactlyOneAttempt() async {
        for message in [
            "Wrong username or password", "No gate found", "Unlock iPhone to open the gate",
        ] {
            let (defaults, cleanup) = makeSuite()
            defer { cleanup() }
            let store = WidgetSnapshotStore(defaults: defaults)
            let clock = FakeClock()
            let log = AttemptLog()
            let outcome = await OpenGateFlow().run(
                currentState: .idle, gateName: nil, isReachable: true,
                open: { log.record(0); return .failed(message: message) },
                snapshot: store, reloadTimelines: {},
                sleep: clock.sleep, now: clock.now, pressStartedAt: clock.start
            )
            #expect(outcome == .failed(message: message))
            #expect(log.count == 1)
        }
    }

    @Test func retryabilityClassifier() {
        #expect(!OpenGateFlow.isRetryable(message: "Wrong username or password"))
        #expect(!OpenGateFlow.isRetryable(message: "No gate found"))
        #expect(!OpenGateFlow.isRetryable(message: "Unlock iPhone to open the gate"))
        #expect(OpenGateFlow.isRetryable(message: "Could not reach the gate"))
        #expect(OpenGateFlow.isRetryable(message: "Network too slow - try again"))
        #expect(OpenGateFlow.isRetryable(message: "No internet connection"))
        #expect(OpenGateFlow.isRetryable(message: "Gate service busy - try again"))
        #expect(OpenGateFlow.isRetryable(message: "Gate service error (500)"))
        #expect(OpenGateFlow.isRetryable(message: "Could not open the gate"))
    }

    @Test func needsSetupStateMidLoopStopsWithNeedsSetup() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let clock = FakeClock()
        let calls = LockedCounter()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: true,
            open: {
                calls.increment()
                return calls.value == 1 ? .failed(message: "Could not reach the gate") : .needsSetup
            },
            snapshot: store, reloadTimelines: {},
            sleep: clock.sleep, now: clock.now, pressStartedAt: clock.start
        )
        #expect(outcome == .needsSetup)
        #expect(calls.value == 2)
        #expect(store.read()?.phase == .needsSetup)
    }

    @Test func offlineThenReachabilityReturnsSucceeds() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let clock = FakeClock()
        let recorder = PressRecorder()
        let calls = LockedCounter()
        let waits = LockedCounter()

        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: false,
            open: { calls.increment(); return .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            waitForReachability: { _ in
                waits.increment()
                clock.advance(5)
                return true
            },
            now: clock.now, journal: { recorder.record($0) }, pressStartedAt: clock.start
        )
        #expect(outcome == .opened)
        #expect(waits.value == 1)
        #expect(calls.value == 1)
        let phases = recorder.records.map(\.phase)
        #expect(phases == [
            .reachability(isReachable: false, detail: ""),
            .waitingForNetwork,
            .openStarted,
            .attempt(number: 1),
            .finished(outcome: "Gate opened"),
        ])
    }

    @Test func offlineAndNeverReturnsFailsNoNetworkWithoutOpenCall() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let clock = FakeClock()
        let calls = LockedCounter()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: false,
            open: { calls.increment(); return .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            waitForReachability: { _ in false },
            now: clock.now, pressStartedAt: clock.start
        )
        #expect(outcome == .failed(message: "No network"))
        #expect(calls.value == 0)
        #expect(store.read()?.message == "No network")
    }

    @Test func connectivityLostBetweenAttemptsWaitsThenRetries() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let clock = FakeClock()
        let calls = LockedCounter()
        let waits = LockedCounter()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: true,
            open: {
                calls.increment()
                clock.advance(2)
                return calls.value == 1 ? .failed(message: "No internet connection") : .succeeded(at: Date())
            },
            snapshot: store, reloadTimelines: {},
            sleep: clock.sleep,
            isReachableNow: { false },
            waitForReachability: { _ in waits.increment(); clock.advance(3); return true },
            now: clock.now, pressStartedAt: clock.start
        )
        #expect(outcome == .opened)
        #expect(waits.value == 1)
        #expect(calls.value == 2)
    }

    @Test func hangingAttemptIsCutAtDeadlineAsTimedOut() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let calls = LockedCounter()
        let started = Date()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: true,
            open: {
                calls.increment()
                try? await Task.sleep(for: .seconds(60))
                return .succeeded(at: Date())
            },
            snapshot: store, reloadTimelines: {},
            deadline: .milliseconds(100), minimumAttemptWindow: .zero,
            pressStartedAt: started
        )
        #expect(outcome == .timedOut)
        #expect(calls.value == 1)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(store.read()?.message == "Timed out")
    }

    /// `open()` that IGNORES cancellation (like production `GateController
    /// .openGate()`): run() must still return at the deadline, not when the
    /// open finishes, and must not start a second open().
    @Test func cancellationIgnoringOpenDoesNotDelayRunPastDeadline() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)
        let calls = LockedCounter()
        let release = DispatchSemaphore(value: 0)
        let started = Date()

        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: nil, isReachable: true,
            open: {
                calls.increment()
                // Non-cancellable wait: blocks on a semaphore for up to 10s.
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        _ = release.wait(timeout: .now() + 10)
                        c.resume()
                    }
                }
                return .succeeded(at: Date())
            },
            snapshot: store, reloadTimelines: {},
            deadline: .milliseconds(500), minimumAttemptWindow: .zero,
            pressStartedAt: started
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(outcome == .timedOut)
        #expect(elapsed < 5.0)
        #expect(elapsed >= 0.4)
        // No second open() while the first may still be in flight.
        #expect(calls.value == 1)
        release.signal()
    }

    @Test func legacyJournalLinesStillDecodeAndNewPhasesRoundTrip() throws {
        let legacy = #"{"kind":"openStarted"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(OpenPressPhase.self, from: legacy) == .openStarted)
        let legacyReach = #"{"kind":"reachability","isReachable":true,"detail":"satisfied"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(OpenPressPhase.self, from: legacyReach) == .reachability(isReachable: true, detail: "satisfied"))
        for phase in [OpenPressPhase.attempt(number: 4), .waitingForNetwork] {
            let data = try JSONEncoder().encode(phase)
            #expect(try JSONDecoder().decode(OpenPressPhase.self, from: data) == phase)
        }
        let attempt = #"{"kind":"attempt","number":2}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(OpenPressPhase.self, from: attempt) == .attempt(number: 2))
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

    /// `OpenGateFlow.run` binds `OpenPressContext.$pressStartedAt` around the
    /// same scope as `$pressId` (see `run`'s implementation) -- this proves
    /// `pressStartedAt` is likewise visible from inside the `open` closure,
    /// exactly like `pressId` above, so hooks that run during `open()` (e.g.
    /// `TokenManager.onResolved`/`onFailed`, wired by `AppEnvironment.make()`)
    /// can compute an elapsed time relative to the press's true start.
    ///
    /// MUTATION CHECK: if `run` only bound `$pressId` and not
    /// `$pressStartedAt` around `raceAgainstTimeout`'s `addTask` scope,
    /// `observedPressStartedAt` would capture `nil` here, failing the final
    /// `#expect`.
    @Test func openClosureObservesTaskLocalPressStartedAtSetByRun() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let holder = PressStartedAtHolder()
        let explicitPressStartedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: {
                holder.record(OpenPressContext.pressStartedAt)
                return .succeeded(at: Date())
            },
            snapshot: store,
            reloadTimelines: {},
            // Frozen clock at the press start: the deadline is measured from
            // `pressStartedAt` via `now`, so a real clock would put this 2023
            // date far past the deadline.
            now: { explicitPressStartedAt },
            pressStartedAt: explicitPressStartedAt
        )

        #expect(outcome == .opened)
        #expect(holder.value == explicitPressStartedAt)
    }

    /// Mirrors `openClosureObservesTaskLocalPressStartedAtSetByRun` for
    /// `OpenPressContext.pressSource`: `OpenGateFlow.run` must bind
    /// `pressSource` (alongside `pressId`/`pressStartedAt`) around its
    /// `open()` invocation, so code running inside `open()` (e.g.
    /// `AppEnvironment.make()`'s `TokenManager.onResolved`/`onFailed` hooks)
    /// can read the current press's source without it being threaded through
    /// as an explicit parameter.
    @Test func openClosureObservesTaskLocalPressSourceSetByRun() async {
        let (defaults, cleanup) = makeSuite()
        defer { cleanup() }
        let store = WidgetSnapshotStore(defaults: defaults)

        let holder = PressSourceHolder()

        let outcome = await OpenGateFlow().run(
            currentState: .idle,
            gateName: "Front Gate",
            isReachable: true,
            open: {
                holder.record(OpenPressContext.pressSource)
                return .succeeded(at: Date())
            },
            snapshot: store,
            reloadTimelines: {},
            pressSource: "queued"
        )

        #expect(outcome == .opened)
        #expect(holder.value == "queued")
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

private final class PressStartedAtHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date?

    func record(_ value: Date?) {
        lock.lock()
        _value = value
        lock.unlock()
    }

    var value: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

private final class PressSourceHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?

    func record(_ value: String?) {
        lock.lock()
        _value = value
        lock.unlock()
    }

    var value: String? {
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
