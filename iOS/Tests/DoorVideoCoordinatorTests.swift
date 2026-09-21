import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `DoorVideoCoordinator` (bead gateopener-672.18): the session
/// retention policy across repeat `startForOpen()`/`viewDoor()` calls while
/// a `DoorVideoSession.debugStub` session is still `.connecting`.
@MainActor
struct DoorVideoCoordinatorTests {
    /// Builds a factory returning a fresh `DoorVideoSession.debugStub` on
    /// every invocation, plus a counter of how many times the factory
    /// itself was called (independent of `DoorVideoCoordinator
    /// .sessionStartCount`, so the test can cross-check both).
    private func makeCountingFactory() -> (factory: @MainActor () -> DoorVideoSession, callCount: LockedCounter) {
        let callCount = LockedCounter()
        let factory: @MainActor () -> DoorVideoSession = {
            callCount.increment()
            // Long delays: the session must still be `.connecting` for the
            // whole duration of this test, so a second start/view call
            // definitely lands while the retention policy is live, never
            // racing a debugStub timeline transition.
            return DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
        }
        return (factory, callCount)
    }

    // MARK: - (c) two startForOpen() calls while connecting -> exactly one session start

    /// MUTATION CHECK: removing the retention early-return in
    /// `DoorVideoCoordinator.startOrRetain()` — i.e. deleting
    /// `guard decision == .replace else { return }` in
    /// `iOS/App/Video/DoorVideoCoordinator.swift` — makes the SECOND
    /// `startForOpen()` call also build and start a fresh session, so
    /// `sessionStartCount` becomes 2 and `factoryCallCount.value` becomes
    /// 2, failing both `== 1` assertions below.
    @Test func twoStartForOpenCallsWhileConnectingStartExactlyOneSession() async {
        let (factory, factoryCallCount) = makeCountingFactory()
        let coordinator = DoorVideoCoordinator(makeSession: factory, isEnabled: { true })

        coordinator.startForOpen()
        // Give the first start() Task a chance to actually run and reach
        // `.connecting` before the second call arrives.
        await Task.yield()
        coordinator.startForOpen()
        await Task.yield()

        #expect(coordinator.sessionStartCount == 1)
        #expect(factoryCallCount.value == 1)
    }

    /// `isEnabled: { false }` must make `startForOpen()` a complete no-op:
    /// zero factory invocations, zero session starts.
    ///
    /// MUTATION CHECK: removing `guard isEnabled() else { return }` from
    /// `DoorVideoCoordinator.startForOpen()` makes this call fall through
    /// to `startOrRetain()`, so `sessionStartCount`/`factoryCallCount` both
    /// become 1 instead of 0.
    @Test func startForOpenWithIsEnabledFalseStartsNoSession() async {
        let (factory, factoryCallCount) = makeCountingFactory()
        let coordinator = DoorVideoCoordinator(makeSession: factory, isEnabled: { false })

        coordinator.startForOpen()
        await Task.yield()

        #expect(coordinator.sessionStartCount == 0)
        #expect(factoryCallCount.value == 0)
    }

    /// `viewDoor()` called while a session is already `.connecting` (from a
    /// prior `startForOpen()`) must retain, not replace — the same policy
    /// as two `startForOpen()` calls, but crossing the two entry points.
    ///
    /// MUTATION CHECK: same as the first test above — removing
    /// `DoorVideoCoordinator.startOrRetain()`'s `guard decision == .replace
    /// else { return }` makes `viewDoor()` also start a fresh session while
    /// one is connecting, taking `sessionStartCount` to 2.
    @Test func viewDoorDuringConnectingStillRetainsOneSession() async {
        let (factory, factoryCallCount) = makeCountingFactory()
        let coordinator = DoorVideoCoordinator(makeSession: factory, isEnabled: { true })

        coordinator.startForOpen()
        await Task.yield()
        coordinator.viewDoor()
        await Task.yield()

        #expect(coordinator.sessionStartCount == 1)
        #expect(factoryCallCount.value == 1)
    }

    // MARK: - sessionState publishes the connecting -> streaming transition

    /// Bead gateopener-672.29: the video panel stayed on "Connecting…"
    /// after the underlying session actually started streaming, because
    /// `MainView` read `session.state` directly — `DoorVideoSession` is a
    /// plain (non-`@Observable`) class, so SwiftUI never re-rendered on
    /// that transition. `DoorVideoCoordinator.sessionState` is the fix:
    /// it mirrors `session.state` on the `@Observable` coordinator itself.
    ///
    /// MUTATION CHECK: removing `sessionState = state` from
    /// `DoorVideoCoordinator.handleStateChange(_:for:)` makes
    /// `coordinator.sessionState` stay `.idle` forever, so the poll loop
    /// below times out and the final `#expect(... == .streaming)` fails.
    @Test func sessionStatePublishesStreamingTransition() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 0.05, streamingDuration: 10) },
            isEnabled: { true }
        )

        coordinator.startForOpen()

        let deadline = Date().addingTimeInterval(2)
        while coordinator.sessionState != .streaming, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(coordinator.sessionState == .streaming)
        #expect(coordinator.isPanelVisible == true)
    }

    // MARK: - cooldownUntil publishes and clears (bead gateopener-41m.9)

    /// The coordinator mirrors its current session's `cooldownUntil` via
    /// `onCooldownChange`, and clears it back to `nil` once the session
    /// clears it (e.g. the cooldown wait finishes) — driven end-to-end
    /// through a real session's `onCooldownChange` callback (not a fake),
    /// using the same wiring `startOrRetain()` sets up for `onStateChange`.
    ///
    /// MUTATION CHECK: removing the `newSession.onCooldownChange = { ... }`
    /// wiring in `DoorVideoCoordinator.startOrRetain()` would leave
    /// `coordinator.cooldownUntil` `nil` forever, failing the first
    /// `#expect(coordinator.cooldownUntil != nil)` below.
    @Test func cooldownUntilPublishesThenClears() async {
        let session = DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
        let coordinator = DoorVideoCoordinator(makeSession: { session }, isEnabled: { true })

        coordinator.startForOpen()
        await Task.yield()

        // No real cooldown occurs on the debug-stub timeline; drive the
        // session's own `onCooldownChange` directly (as `waitOutCooldownIfNeeded()`
        // would) to prove the coordinator's wiring/identity-guard/publish
        // path works end-to-end.
        let deadline = Date().addingTimeInterval(5)
        session.onCooldownChange?(deadline)
        #expect(coordinator.cooldownUntil == deadline)

        session.onCooldownChange?(nil)
        #expect(coordinator.cooldownUntil == nil)
    }

    /// `dismiss()` clears `cooldownUntil` immediately, mirroring
    /// `sessionState`'s reset to `.idle`.
    ///
    /// MUTATION CHECK: removing `cooldownUntil = nil` from `dismiss()` would
    /// leave a stale deadline behind after dismissal, failing the final
    /// `#expect`.
    @Test func dismissClearsCooldownUntil() async {
        let session = DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
        let coordinator = DoorVideoCoordinator(makeSession: { session }, isEnabled: { true })

        coordinator.startForOpen()
        await Task.yield()

        session.onCooldownChange?(Date().addingTimeInterval(5))
        #expect(coordinator.cooldownUntil != nil)

        coordinator.dismiss()
        #expect(coordinator.cooldownUntil == nil)
    }

    /// A stale `onCooldownChange` callback from a session that has since
    /// been replaced must NOT clobber the current session's `cooldownUntil`
    /// — the same identity guard `handleStateChange` already relies on.
    ///
    /// MUTATION CHECK: removing the `guard session === changedSession else
    /// { return }` in `handleCooldownChange` would let the stale session's
    /// callback below overwrite `coordinator.cooldownUntil` back to a
    /// non-nil value, failing the final `#expect`.
    @Test func staleCooldownCallbackFromReplacedSessionIsIgnored() async {
        let firstSession = DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
        var callCount = 0
        let sessions = [firstSession, DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)]
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return sessions[callCount]
            },
            isEnabled: { true }
        )

        coordinator.startForOpen()
        await Task.yield()

        // Replace the session: stop the first one to let a fresh
        // startForOpen() build a second.
        coordinator.dismiss()
        coordinator.startForOpen()
        await Task.yield()

        // The now-stale first session fires its callback late.
        firstSession.onCooldownChange?(Date().addingTimeInterval(5))

        #expect(coordinator.cooldownUntil == nil)
    }
}
