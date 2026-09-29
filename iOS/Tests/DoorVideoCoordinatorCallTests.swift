import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for bead gateopener-1pm.5: `DoorVideoCoordinator.startCall()`/
/// `hangUp()`/`setMicMuted(_:)`, `activeMode`/`pendingCall`/`isMicMuted`/
/// `isCallActive`, and the pinned-renewal-stays-in-call-mode behavior.
/// Mirrors `DoorVideoCoordinatorTests`' MUTATION CHECK style; that file's
/// existing tests are untouched.
@MainActor
struct DoorVideoCoordinatorCallTests {
    // MARK: - startCall() from idle

    /// `startCall()` with no existing session starts exactly ONE session,
    /// in `.call` mode: `activeMode` flips to `.call` synchronously, and
    /// (bead gateopener-1pm.5's DEBUG fix) the debug stub — built by a
    /// factory with NO knowledge of which mode the coordinator would ask
    /// for, exactly like `GateOpenerIOSApp`'s `makeSession` closure — must
    /// actually run its canned timeline AS a `.call` session: verified here
    /// by checking the injected `NoOpAudioSessionController` receives the
    /// `.call` audio-session plan once the stub reaches `.connecting`.
    ///
    /// MUTATION CHECK: dropping `DoorVideoSession.start(mode:)`'s "explicit
    /// `.call` argument flips a debug stub's mode before the early return"
    /// fix would leave the stub running as `.view` (built with the
    /// default), so `fake.appliedPlans` would stay empty, failing the final
    /// assertion.
    @Test func startCallFromIdleStartsExactlyOneCallSession() async {
        let fake = NoOpAudioSessionController()
        var factoryCallCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                factoryCallCount += 1
                return DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 10, audioSessionController: fake)
            },
            isEnabled: { true }
        )

        coordinator.startCall()

        #expect(coordinator.sessionStartCount == 1)
        #expect(factoryCallCount == 1)
        #expect(coordinator.activeMode == .call)
        #expect(coordinator.pendingCall == true)

        let deadline = Date().addingTimeInterval(2)
        while fake.appliedPlans.isEmpty, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(fake.appliedPlans.first == DoorVideoSession.audioSessionPlan(for: .call))
    }

    // MARK: - startCall() while a view session is connecting/streaming

    /// `startCall()` while a `.view` session is connecting stops that
    /// session (its `state` becomes `.ended`) and starts EXACTLY ONE new
    /// `.call` session — not two, and not zero.
    ///
    /// MUTATION CHECK: removing the "detach the old session's callback
    /// routing before calling `stop()`" guard (nil-ing `session` first) would
    /// let the old view session's `stop()`-induced `.ended` transition run
    /// through the normal pin-renewal machinery — harmless when unpinned,
    /// but see `pinnedStartCallDuringViewDoesNotDoubleStart` below for the
    /// pinned case this guards against.
    @Test func startCallDuringViewSessionStopsOldAndStartsExactlyOneCallSession() async {
        var factoryCallCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                factoryCallCount += 1
                return DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.startForOpen()
        await Task.yield()
        let viewSession = coordinator.session
        #expect(coordinator.activeMode == .view)
        #expect(factoryCallCount == 1)

        coordinator.startCall()

        #expect(factoryCallCount == 2)
        #expect(coordinator.sessionStartCount == 2)
        #expect(coordinator.activeMode == .call)
        #expect(viewSession?.state == .ended)
        #expect(coordinator.session !== viewSession)
        // No flash: the slot was already showing a mounted session and stays
        // showing one across the switch.
        #expect(coordinator.isPanelVisible == true)
    }

    /// A PINNED `.view` session being switched to a call must NOT let the
    /// old session's `stop()`-induced termination race its own pin-renewal
    /// policy into starting a SECOND (`.view`) session alongside the
    /// `.call` session `startCall()` itself starts.
    ///
    /// MUTATION CHECK: removing the identity-severing nil-out before
    /// `stop()` (see `DoorVideoCoordinator.startCall()`'s doc comment) would
    /// make `factoryCallCount`/`sessionStartCount` become 3 instead of 2 —
    /// one for the initial view session, one bogus renewal of it, and one
    /// for the actual `.call` session.
    @Test func pinnedStartCallDuringViewDoesNotDoubleStart() async {
        var factoryCallCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                factoryCallCount += 1
                return DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.startForOpen()
        await Task.yield()
        coordinator.setPinned(true)
        #expect(coordinator.isPinned == true)

        coordinator.startCall()

        #expect(factoryCallCount == 2)
        #expect(coordinator.sessionStartCount == 2)
        #expect(coordinator.activeMode == .call)
    }

    /// A repeat `startCall()` tap while already connecting/streaming a call
    /// is a no-op beyond retaining it — mirrors `viewDoor()`'s retention
    /// policy for an in-flight view session.
    @Test func startCallWhileAlreadyCallingRetainsSameSession() async {
        var factoryCallCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                factoryCallCount += 1
                return DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.startCall()
        let firstSession = coordinator.session
        // Give the first start() Task a chance to actually reach
        // `.connecting` before the second call arrives — mirrors
        // `DoorVideoCoordinatorTests.twoStartForOpenCallsWhileConnectingStartExactlyOneSession()`.
        await Task.yield()
        coordinator.startCall()
        await Task.yield()

        #expect(factoryCallCount == 1)
        #expect(coordinator.sessionStartCount == 1)
        #expect(coordinator.session === firstSession)
    }

    // MARK: - hangUp()

    /// `hangUp()` stops the session, unpins, clears `pendingCall`/
    /// `activeMode`, and does NOT auto-restart anything — the placeholder
    /// shows (no session, `lastTerminal == .none`).
    ///
    /// MUTATION CHECK: calling `setPinned(false)`/leaving any renew task
    /// alive instead of this method's own field resets would leave
    /// `isPinned`/a stray renewal running, failing one of the assertions
    /// below (in particular the final "no auto-restart" check).
    @Test func hangUpStopsSessionUnpinsAndDoesNotAutoRestart() async {
        var factoryCallCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                factoryCallCount += 1
                return DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.startCall()
        // Let the call session actually reach `.connecting` before pinning
        // it — `setPinned(true)` itself starts a FRESH (`.view`) session via
        // `startOrRetain()` if the current one is not yet connecting/
        // streaming, which is a real but separate behavior out of this
        // bead's scope (pinning the literal instant `startCall()` returns,
        // before its `Task` has run at all).
        await Task.yield()
        coordinator.setPinned(true)
        #expect(coordinator.isPinned == true)
        #expect(coordinator.activeMode == .call)

        coordinator.hangUp()

        #expect(coordinator.session == nil)
        #expect(coordinator.sessionState == .idle)
        #expect(coordinator.isPinned == false)
        #expect(coordinator.pendingCall == false)
        #expect(coordinator.isMicMuted == false)
        #expect(coordinator.activeMode == .view)
        #expect(coordinator.lastTerminal == .none)
        #expect(coordinator.isPanelVisible == false)

        // No auto-restart: give any stray renewal task a chance to run.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(factoryCallCount == 1)
        #expect(coordinator.sessionStartCount == 1)
        #expect(coordinator.session == nil)
    }

    // MARK: - setMicMuted(_:)

    /// `setMicMuted(_:)` toggles `isMicMuted` immediately, both directions.
    @Test func setMicMutedTogglesIsMicMutedBothDirections() {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true }
        )

        coordinator.startCall()
        #expect(coordinator.isMicMuted == false)

        coordinator.setMicMuted(true)
        #expect(coordinator.isMicMuted == true)

        coordinator.setMicMuted(false)
        #expect(coordinator.isMicMuted == false)
    }

    // MARK: - isCallActive

    /// `isCallActive` is `false` before any session, and `true` once a
    /// `.call` session is connecting.
    @Test func isCallActiveReflectsCallModeAndPanelVisibility() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true }
        )

        #expect(coordinator.isCallActive == false)

        coordinator.startCall()
        await Task.yield()

        #expect(coordinator.isCallActive == true)
    }

    /// A `.view` session connecting/streaming must NOT report
    /// `isCallActive == true`.
    @Test func isCallActiveFalseForViewSession() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true }
        )

        coordinator.startForOpen()
        await Task.yield()

        #expect(coordinator.isCallActive == false)
    }

    // MARK: - "call start" / "call connected" events

    /// `startCall()` logs "call start" immediately, and "call connected"
    /// once the session reaches `.streaming` — `pendingCall` clears at the
    /// same moment.
    ///
    /// MUTATION CHECK: removing the `eventSink("call connected")` call (or
    /// its `pendingCall` guard, logging it unconditionally on every
    /// `.streaming` transition including later renewals) would fail the
    /// `events.filter { $0 == "call connected" }.count == 1` assertion.
    @Test func callStartAndCallConnectedEventsFireExactlyOnce() async {
        var events: [String] = []
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 10) },
            isEnabled: { true },
            eventSink: { events.append($0) }
        )

        coordinator.startCall()
        #expect(events.contains("call start"))

        let deadline = Date().addingTimeInterval(2)
        while coordinator.sessionState != .streaming, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(coordinator.sessionState == .streaming)
        #expect(coordinator.pendingCall == false)
        #expect(events.filter { $0 == "call connected" }.count == 1)
    }

    // MARK: - Pinned renewal stays in .call mode

    /// A PINNED `.call` session that ends (the door's ~30s window) renews
    /// as a `.call` session again — verified via the injected audio
    /// controller applying the `.call` plan a SECOND time after the first
    /// session's own terminal `.view`-plan restore.
    ///
    /// MUTATION CHECK: `handlePinnableTermination`'s renewal calls reverting
    /// to the old, mode-less `startSession(resetPanelVisible:)` (defaulting
    /// to `.view`) would renew the SECOND session as a plain view session,
    /// so the audio controller would see the `.call` plan only ONCE
    /// (`plansAppliedCount(.call) == 1`), failing the final assertion.
    @Test func pinnedCallRenewalStartsAsCallModeAgain() async {
        let fake = NoOpAudioSessionController()
        var factoryCallCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                factoryCallCount += 1
                return DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02, audioSessionController: fake)
            },
            isEnabled: { true }
        )

        coordinator.startCall()
        await Task.yield()
        coordinator.setPinned(true)

        let deadline = Date().addingTimeInterval(3)
        while coordinator.pinRenewalCount < 1, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(coordinator.pinRenewalCount >= 1)
        #expect(coordinator.activeMode == .call)
        #expect(factoryCallCount == 2)

        // `pinRenewalCount` increments synchronously the instant the renewal
        // is DECIDED, before the renewed session's own `Task { await
        // newSession.start(mode:) }` has actually had a chance to run and
        // apply its audio-session plan — give it one.
        let plansDeadline = Date().addingTimeInterval(2)
        while fake.appliedPlans.filter({ $0 == DoorVideoSession.audioSessionPlan(for: .call) }).count < 2,
              Date() < plansDeadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }

        let callPlanApplications = fake.appliedPlans.filter { $0 == DoorVideoSession.audioSessionPlan(for: .call) }
        #expect(callPlanApplications.count == 2)
    }
}
