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
}
