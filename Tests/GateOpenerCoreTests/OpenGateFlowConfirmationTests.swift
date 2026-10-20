import Foundation
import Testing
@testable import GateOpenerCore

/// gateopener-pi0.5: `OpenGateFlow.run`'s `awaitConfirmation` hook.
struct OpenGateFlowConfirmationTests {
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [T] = []
        func add(_ item: T) { lock.lock(); _items.append(item); lock.unlock() }
        var items: [T] { lock.lock(); defer { lock.unlock() }; return _items }
    }

    private final class Phases: @unchecked Sendable {
        private let lock = NSLock()
        private var _p: [OpenPressPhase] = []
        func add(_ r: OpenPressRecord) { lock.lock(); _p.append(r.phase); lock.unlock() }
        var phases: [OpenPressPhase] { lock.lock(); defer { lock.unlock() }; return _p }
    }

    private func makeStore() -> (WidgetSnapshotStore, () -> Void) {
        let name = "ie.boboco.GateOpener.test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        return (WidgetSnapshotStore(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// Breaks if the hook is not called after `.opened`, or the bound is
    /// not min(3.4s, remaining) -- plenty of time left case (27s remaining).
    @Test func awaitConfirmationCalledWithThreePointFourSecondsAfterOpenedWhenPlentyOfTime() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let calls = Box<Duration>()
        let phases = Phases()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            now: { fixedNow },
            journal: { phases.add($0) },
            pressStartedAt: fixedNow,
            awaitConfirmation: { calls.add($0) }
        )
        #expect(outcome == .opened)
        #expect(calls.items == [.seconds(3.4)])
        // No new journal phase for the confirmation wait.
        #expect(phases.phases == [
            .reachability(isReachable: true, detail: ""),
            .openStarted,
            .attempt(number: 1),
            .finished(outcome: OpenGateFlow.Outcome.acceptedDialog),
        ])
    }

    /// Breaks if the bound ignores the remaining deadline (2s left -> 2s).
    @Test func awaitConfirmationBoundIsRemainingDeadlineWhenLessThanThreePointFourSeconds() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let calls = Box<Duration>()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            deadline: .seconds(27), minimumAttemptWindow: .zero,
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            now: { fixedNow },
            pressStartedAt: fixedNow.addingTimeInterval(-25),
            awaitConfirmation: { calls.add($0) }
        )
        #expect(outcome == .opened)
        #expect(calls.items == [.seconds(2)])
    }

    /// Breaks if the hook runs after a failure.
    @Test func awaitConfirmationNotCalledAfterFailed() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let calls = Box<Duration>()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .failed(message: "Wrong username or password") },
            snapshot: store, reloadTimelines: {},
            awaitConfirmation: { calls.add($0) }
        )
        #expect(outcome == .failed(message: "Wrong username or password"))
        #expect(calls.items.isEmpty)
    }

    /// Breaks if the hook runs after a timeout.
    @Test func awaitConfirmationNotCalledAfterTimedOut() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let calls = Box<Duration>()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { try? await Task.sleep(for: .seconds(60)); return .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            deadline: .milliseconds(50), minimumAttemptWindow: .zero,
            awaitConfirmation: { calls.add($0) }
        )
        #expect(outcome == .timedOut)
        #expect(calls.items.isEmpty)
    }

    /// Breaks if the hook runs for needsSetup.
    @Test func awaitConfirmationNotCalledAfterNeedsSetup() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let calls = Box<Duration>()
        let outcome = await OpenGateFlow().run(
            currentState: .needsSetup, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            awaitConfirmation: { calls.add($0) }
        )
        #expect(outcome == .needsSetup)
        #expect(calls.items.isEmpty)
    }

    /// A hook that never returns must not delay the outcome beyond the bound:
    /// the injected `sleep` (immediate here) is the bound. Breaks if the flow
    /// awaits the closure directly (would take ~30s, failing the 5s check).
    @Test func neverReturningAwaitConfirmationDoesNotDelayOutcomeBeyondBound() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let sleeps = Box<Duration>()
        let started = ContinuousClock.now
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            sleep: { sleeps.add($0) },
            now: { fixedNow },
            pressStartedAt: fixedNow,
            awaitConfirmation: { _ in try? await Task.sleep(for: .seconds(30)) }
        )
        #expect(outcome == .opened)
        #expect(sleeps.items == [.seconds(3.4)])
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    // MARK: - gateopener-pi0.9: onFinished runs before the confirmation wait

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: Double) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
    }

    /// Order for `.opened`: terminal snapshot write -> `.finished` journal ->
    /// onFinished -> awaitConfirmation. Breaks if onFinished is moved after
    /// the confirmation wait (the pre-pi0.9 behaviour), if the snapshot is
    /// written after it, or if it is dropped.
    @Test func onFinishedRunsAfterSnapshotAndJournalBeforeConfirmation() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let events = Box<String>()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store,
            reloadTimelines: { events.add("snapshot:\(store.read()?.phase.rawValue ?? "nil")") },
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            now: { fixedNow },
            journal: { record in
                if case .finished = record.phase { events.add("finished") }
            },
            pressStartedAt: fixedNow,
            awaitConfirmation: { _ in events.add("confirm") },
            onFinished: { outcome in events.add("onFinished:\(outcome.dialog)") }
        )
        #expect(outcome == .opened)
        #expect(events.items == [
            "snapshot:opening", "snapshot:succeeded", "finished", "onFinished:Open command accepted", "confirm",
        ])
    }

    /// onFinished sees `.failed` and `.timedOut`. Breaks if the call is
    /// limited to `.opened` or the outcome is not passed through.
    @Test func onFinishedCalledForFailedAndTimedOut() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let seen = Box<OpenGateFlow.Outcome>()
        let failed = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .failed(message: "Wrong username or password") },
            snapshot: store, reloadTimelines: {},
            onFinished: { seen.add($0) }
        )
        let timedOut = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { try? await Task.sleep(for: .seconds(60)); return .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            deadline: .milliseconds(50), minimumAttemptWindow: .zero,
            onFinished: { seen.add($0) }
        )
        #expect(failed == .failed(message: "Wrong username or password"))
        #expect(timedOut == .timedOut)
        #expect(seen.items == [failed, timedOut])
    }

    /// onFinished IS called with `.needsSetup` on both the entry-guard path and
    /// the `open()`-returns-needsSetup path. Breaks if either call (or the
    /// outcome pass-through) is removed.
    @Test func onFinishedCalledForNeedsSetupOnBothPaths() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let seen = Box<OpenGateFlow.Outcome>()
        let early = await OpenGateFlow().run(
            currentState: .needsSetup, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            onFinished: { seen.add($0) }
        )
        let late = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .needsSetup },
            snapshot: store, reloadTimelines: {},
            onFinished: { seen.add($0) }
        )
        #expect(early == .needsSetup)
        #expect(late == .needsSetup)
        #expect(seen.items == [.needsSetup, .needsSetup])
    }

    /// A hung onFinished on either needsSetup path is cut off at the 2s
    /// notification bound via the injected sleep. Breaks if either call is
    /// unbounded (the test would take 30s) or uses a different bound.
    @Test func hungOnFinishedOnNeedsSetupPathsIsBounded() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let sleeps = Box<Duration>()
        let started = ContinuousClock.now
        let early = await OpenGateFlow().run(
            currentState: .needsSetup, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            sleep: { sleeps.add($0) },
            onFinished: { _ in try? await Task.sleep(for: .seconds(30)) }
        )
        let late = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .needsSetup },
            snapshot: store, reloadTimelines: {},
            sleep: { sleeps.add($0) },
            now: { fixedNow },
            pressStartedAt: fixedNow,
            awaitConfirmation: { _ in },
            onFinished: { _ in try? await Task.sleep(for: .seconds(30)) }
        )
        #expect(early == .needsSetup && late == .needsSetup)
        #expect(sleeps.items.filter { $0 == .seconds(2) }.count == 2)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A never-returning onFinished is cut off by the injected sleep at the
    /// notification bound (2s default) and the outcome is unchanged. Breaks
    /// if onFinished is awaited unbounded (test would hang/exceed 5s) or the
    /// bound differs from `notificationBound`.
    @Test func neverReturningOnFinishedIsBoundedByNotificationBound() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let sleeps = Box<Duration>()
        let started = ContinuousClock.now
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            sleep: { sleeps.add($0) },
            now: { fixedNow },
            pressStartedAt: fixedNow,
            awaitConfirmation: { _ in },
            onFinished: { _ in try? await Task.sleep(for: .seconds(30)) }
        )
        #expect(outcome == .opened)
        #expect(sleeps.items.first == .seconds(2))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// With 5s remaining and the 2s notification bound consumed (the fake
    /// sleep advances the injected clock), the confirmation bound is
    /// min(3.4, 3) = 3s. Breaks if remaining is computed before onFinished
    /// (would give 3.4s) or the notification wait is not charged to the clock.
    @Test func confirmationBoundReflectsTimeConsumedByOnFinished() async {
        let (store, cleanup) = makeStore(); defer { cleanup() }
        let clock = Clock(fixedNow)
        let sleepCalls = Box<Duration>()
        let confirmBounds = Box<Duration>()
        let outcome = await OpenGateFlow().run(
            currentState: .idle, gateName: "G", isReachable: true,
            open: { .succeeded(at: Date()) },
            snapshot: store, reloadTimelines: {},
            deadline: .seconds(27), minimumAttemptWindow: .zero,
            sleep: { d in
                sleepCalls.add(d)
                if sleepCalls.items.count == 1 {
                    clock.advance(2)   // the notification bound elapses
                } else {
                    try await Task.sleep(for: .seconds(30))
                }
            },
            now: { clock.now },
            pressStartedAt: fixedNow.addingTimeInterval(-22),
            awaitConfirmation: { confirmBounds.add($0) },
            onFinished: { _ in try? await Task.sleep(for: .seconds(30)) }
        )
        #expect(outcome == .opened)
        #expect(sleepCalls.items.first == .seconds(2))
        #expect(confirmBounds.items == [.seconds(3)])
    }
}
