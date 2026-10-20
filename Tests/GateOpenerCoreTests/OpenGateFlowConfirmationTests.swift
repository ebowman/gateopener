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
            .finished(outcome: "Gate opened"),
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
}
