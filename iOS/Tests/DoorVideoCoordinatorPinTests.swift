import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `DoorVideoCoordinator`'s pin state and bounded session renewal
/// (bead gateopener-41m.14): `setPinned(_:)`, `pinPolicy`-driven renew/stop
/// decisions on `.ended`/`.failed`, and the pin's interaction with
/// `startOrRetain()`/`dismiss()`.
@MainActor
struct DoorVideoCoordinatorPinTests {
    /// Polls `condition` until it returns `true` or `timeout` elapses,
    /// mirroring the inline poll loops in `DoorVideoCoordinatorTests`.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// No-op sleep so failure-backoff renewals in tests are instant rather
    /// than waiting out `pinPolicy.failureBackoff` for real.
    private func instantRenewSleep(_ duration: Duration) async throws {}

    // MARK: - pinned + stub ends -> second session created

    /// MUTATION CHECK: removing the `.renew` handling's `startSession()`
    /// call in `DoorVideoCoordinator.handlePinnableTermination(_:for:whenNotRenewing:)`
    /// (i.e. making `.renew(after: 0)` fall through to `whenNotRenewing()`
    /// instead) would leave `sessionStartCount == 1` and eventually clear
    /// `session` to `nil`, failing both assertions below.
    @Test func pinnedSessionEndingStartsSecondSession() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                // Fast connecting/streaming so `.ended` fires quickly; the
                // SECOND session must stay `.connecting` long enough for
                // assertions to observe it before it also ends.
                return callCount == 0
                    ? DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02)
                    : DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionStartCount == 2 }

        #expect(coordinator.sessionStartCount == 2)
        #expect(coordinator.session != nil)
    }

    /// `session` is non-nil and `isPanelVisible` stays `true` throughout the
    /// `.renew(after: 0)` seam -- the replacement must be created
    /// synchronously inside the state-change handler, never leaving a gap
    /// where `session == nil` or the panel flashes hidden.
    ///
    /// MUTATION CHECK: making the `after == 0` renewal go through
    /// `whenNotRenewing()` (today's ended handling: `isPanelVisible = false`,
    /// `scheduleAutoClear`) even once before starting the new session would
    /// make `isPanelVisible` observably `false` at some point during the
    /// poll, failing the loop's invariant check.
    @Test func sessionNonNilAndPanelVisibleAcrossRenewSeam() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return callCount == 0
                    ? DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02)
                    : DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        // Wait for the FIRST session to actually become visible before
        // starting the no-flash/no-nil-gap watch below -- the initial
        // `isPanelVisible == false` before any session has even reached
        // `.connecting` is not the seam this test is about.
        await waitUntil { coordinator.isPanelVisible }

        var sawNilSession = false
        var sawHiddenPanel = false
        let deadline = Date().addingTimeInterval(2)
        while coordinator.sessionStartCount < 2, Date() < deadline {
            if coordinator.session == nil { sawNilSession = true }
            if !coordinator.isPanelVisible { sawHiddenPanel = true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(coordinator.sessionStartCount == 2)
        #expect(!sawNilSession)
        #expect(!sawHiddenPanel)
    }

    /// `lastTerminal` stays `.none` across a renewal -- a renewing pin never
    /// shows the "ended"/"failed" placeholder mid-pin.
    ///
    /// MUTATION CHECK: removing `lastTerminal = .none`'s implicit
    /// preservation (i.e. calling `whenNotRenewing()` -- which sets
    /// `lastTerminal = .ended` -- even on the renew path) would make this
    /// fail once the first session ends.
    @Test func lastTerminalStaysNoneAcrossRenewal() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return callCount == 0
                    ? DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02)
                    : DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionStartCount == 2 }

        #expect(coordinator.sessionStartCount == 2)
        #expect(coordinator.lastTerminal == .none)
    }

    // MARK: - unpinned -> no renewal (existing behaviour)

    /// MUTATION CHECK: making `handlePinnableTermination` renew even when
    /// `isPinned == false` (e.g. removing the `guard isPinned` early return)
    /// would make `sessionStartCount` become 2 instead of staying at 1.
    @Test func unpinnedSessionEndingDoesNotRenew() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02) },
            isEnabled: { true }
        )

        coordinator.startForOpen()
        await waitUntil { coordinator.lastTerminal == .ended }

        // Give any (incorrect) renewal a chance to happen.
        try? await Task.sleep(for: .milliseconds(100))

        #expect(coordinator.sessionStartCount == 1)
        #expect(coordinator.lastTerminal == .ended)
    }

    // MARK: - 3 consecutive failing stubs -> unpinned with message, exactly 3 sessions

    /// MUTATION CHECK: removing `consecutiveFailures += 1` from
    /// `DoorVideoCoordinator.handleStateChange(_:for:)`'s `.failed` branch
    /// would make `pinPolicy.decide(...)` never see `consecutiveFailures >=
    /// maxConsecutiveFailures`, so the pin would keep renewing past 3
    /// sessions, failing the `sessionStartCount == 3` assertion.
    @Test func threeConsecutiveFailuresUnpinsWithMessage() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom \(callCount)")
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 3, failureBackoff: 0),
            renewSleep: instantRenewSleep
        )

        coordinator.setPinned(true)
        await waitUntil(timeout: 3) { !coordinator.isPinned }

        #expect(coordinator.isPinned == false)
        // The stop message now carries the last failure's reason (bead
        // gateopener-41m.21) rather than the generic fallback, since
        // `debugStub(failAfter:)`'s message is non-empty.
        #expect(coordinator.pinStopMessage == "Unpinned - boom 2")
        #expect(coordinator.sessionStartCount == 3)
    }

    // MARK: - escalating failure backoff schedule (bead gateopener-41m.21)

    /// With the default schedule `[2, 5, 10]` and `maxConsecutiveFailures ==
    /// 4`, three consecutive failing stubs request backoffs `[2, 5, 10]` (in
    /// that order) via the injected `renewSleep`, and the 4th failure stops
    /// the pin with a message carrying the last failure's reason.
    ///
    /// MUTATION CHECK: hardcoding a single backoff value (rather than
    /// indexing `failureBackoffs` by `consecutiveFailures - 1`) would make
    /// the recorded durations something like `[2, 2, 2]` instead of
    /// `[2, 5, 10]`, failing the first assertion below.
    @Test func escalatingFailureBackoffScheduleRequestsRecordedDurations() async {
        final class DurationRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _durations: [Duration] = []
            func record(_ duration: Duration) {
                lock.lock(); defer { lock.unlock() }
                _durations.append(duration)
            }
            var durations: [Duration] {
                lock.lock(); defer { lock.unlock() }
                return _durations
            }
        }

        let recorder = DurationRecorder()
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom \(callCount)")
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(),
            renewSleep: { duration in recorder.record(duration) }
        )

        coordinator.setPinned(true)
        await waitUntil(timeout: 3) { !coordinator.isPinned }

        #expect(coordinator.sessionStartCount == 4)
        #expect(recorder.durations == [.seconds(2), .seconds(5), .seconds(10)])
        #expect(coordinator.pinStopMessage == "Unpinned - boom 3")
    }

    /// A failure whose message matches
    /// `DoorVideoBusyPolicy.failureMessage(for: .doorBusy)` requests a
    /// backoff of at least the 10s door-busy floor, even though the
    /// schedule's 1st-failure value (2s) would otherwise be used.
    ///
    /// MUTATION CHECK: not deriving `failureWasDoorBusy` (or comparing
    /// against a hardcoded string literal instead of
    /// `DoorVideoBusyPolicy.failureMessage(for: .doorBusy)`) would request a
    /// 2s backoff instead of >= 10s, failing the assertion below.
    @Test func doorBusyFailureRequestsAtLeastTenSecondBackoff() async {
        final class DurationRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _durations: [Duration] = []
            func record(_ duration: Duration) {
                lock.lock(); defer { lock.unlock() }
                _durations.append(duration)
            }
            var durations: [Duration] {
                lock.lock(); defer { lock.unlock() }
                return _durations
            }
        }

        let recorder = DurationRecorder()
        var callCount = 0
        let busyMessage = DoorVideoBusyPolicy.failureMessage(for: .doorBusy)
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                if callCount == 0 {
                    return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: busyMessage)
                }
                return DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(),
            renewSleep: { duration in recorder.record(duration) }
        )

        coordinator.setPinned(true)
        await waitUntil { !recorder.durations.isEmpty }

        #expect(recorder.durations.count == 1)
        #expect(recorder.durations[0] >= .seconds(10))
    }

    // MARK: - injected now() past 300s -> "Stream ended - tap to resume", no new session

    /// MUTATION CHECK: removing the `pinnedElapsed` computation (passing `0`
    /// unconditionally instead of `now().timeIntervalSince(pinStartedAt)`)
    /// would never trigger `.maxDuration`, so `sessionStartCount` would
    /// become 2 and `pinStopMessage` would stay `nil`.
    @Test func maxDurationReachedStopsPinWithMessageAndNoNewSession() async {
        var currentTime = Date()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02) },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxPinnedDuration: 300),
            now: { currentTime }
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionStartCount == 1 }

        // Advance the injected clock past the pin's budget before the first
        // session's `.ended` fires.
        currentTime = currentTime.addingTimeInterval(301)

        await waitUntil { !coordinator.isPinned }

        #expect(coordinator.isPinned == false)
        #expect(coordinator.pinStopMessage == "Stream ended - tap to resume")
        #expect(coordinator.sessionStartCount == 1)
    }

    // MARK: - dismiss() while pinned -> unpinned, no further sessions even after renew delay

    /// MUTATION CHECK: removing `isPinned = false` from `dismiss()` would
    /// leave the pin active; if the pending renew task were not cancelled
    /// either, `sessionStartCount` would grow past 1 once the (non-instant)
    /// backoff elapses.
    @Test func dismissWhilePinnedUnpinsAndPreventsFurtherSessions() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom")
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 3, failureBackoff: 5)
            // Real renewSleep (not instant): the backoff must still be
            // pending when dismiss() arrives below, otherwise this test
            // would not actually exercise cancellation.
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionStartCount == 1 }
        // Let the first session fail and enter its (real, 5s) backoff wait.
        await waitUntil(timeout: 1) { coordinator.session?.state.phase == .failed }

        coordinator.dismiss()

        #expect(coordinator.isPinned == false)

        // Wait comfortably longer than a mistaken short backoff (but well
        // under the real 5s one) to prove no renewal sneaks through.
        try? await Task.sleep(for: .milliseconds(300))

        #expect(coordinator.sessionStartCount == 1)
        #expect(coordinator.session == nil)
    }

    // MARK: - startForOpen() during a backoff wait -> exactly one new session

    /// MUTATION CHECK: removing `renewTask?.cancel(); renewTask = nil` from
    /// `DoorVideoCoordinator.startOrRetain()` would let the pending renewal
    /// ALSO fire once its backoff elapses, producing a second, unwanted
    /// session on top of the one `startForOpen()` triggers here -- observed
    /// as `sessionStartCount` exceeding 2.
    @Test func startForOpenDuringBackoffWaitStartsExactlyOneNewSession() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                if callCount == 0 {
                    return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom")
                }
                return DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 5, failureBackoff: 5)
            // Real renewSleep (not instant): the backoff must still be
            // pending when startForOpen() arrives below.
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionStartCount == 1 }
        await waitUntil(timeout: 1) { coordinator.session?.state.phase == .failed }

        // The pinned session failed and is backing off (5s); a user-driven
        // startForOpen() arrives during that wait.
        coordinator.startForOpen()
        await Task.yield()

        #expect(coordinator.sessionStartCount == 2)

        // Wait past the original backoff window to prove the cancelled
        // renewal never ALSO fires a third session.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.sessionStartCount == 2)
    }

    // MARK: - failure after a session that reached .streaming counts as failure #1

    /// MUTATION CHECK: removing the `if reachedStreamingThisSession {
    /// consecutiveFailures = 0 }` reset in `DoorVideoCoordinator
    /// .handleStateChange(_:for:)` would make this failure count as
    /// consecutive failure #2 (carried over from a prior session's own
    /// failure), which with `maxConsecutiveFailures: 2` would incorrectly
    /// stop the pin instead of renewing -- failing the `isPinned == true`
    /// assertion below.
    @Test func failureAfterStreamingSessionCountsAsFirstFailure() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                switch callCount {
                case 0:
                    // Reaches .streaming, then ends normally.
                    return DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02)
                case 1:
                    // Fails -- this must be treated as failure #1, not #2.
                    return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom")
                default:
                    return DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
                }
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 2, failureBackoff: 0),
            renewSleep: instantRenewSleep
        )

        coordinator.setPinned(true)
        // First session: streaming -> ended -> renew -> second session
        // (which fails) -> should still renew (failure #1 of 2), not stop.
        await waitUntil(timeout: 3) { coordinator.sessionStartCount == 3 }

        #expect(coordinator.sessionStartCount == 3)
        #expect(coordinator.isPinned == true)
    }

    // MARK: - pinStopMessage cleared by a subsequent viewDoor()

    /// MUTATION CHECK: removing `pinStopMessage = nil` from
    /// `DoorVideoCoordinator.startOrRetain()` would leave the stale message
    /// behind after the user taps "View door" again, failing the final
    /// `#expect`.
    @Test func pinStopMessageClearedBySubsequentViewDoor() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom \(callCount)")
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 1, failureBackoff: 0),
            renewSleep: instantRenewSleep
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.pinStopMessage != nil }
        // The stop message carries the last failure's reason (bead
        // gateopener-41m.21) rather than the generic fallback.
        #expect(coordinator.pinStopMessage == "Unpinned - boom 0")

        coordinator.viewDoor()
        await Task.yield()

        #expect(coordinator.pinStopMessage == nil)
    }

    // MARK: - setPinned(true) clears pinStopMessage too

    /// MUTATION CHECK: removing `pinStopMessage = nil` from `setPinned(true)`
    /// would leave a stale message behind when the user re-pins directly
    /// (rather than via `viewDoor()`), failing the final `#expect`.
    @Test func setPinnedTrueClearsPinStopMessage() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom \(callCount)")
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 1, failureBackoff: 0),
            renewSleep: instantRenewSleep
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.pinStopMessage != nil }
        // The stop message carries the last failure's reason (bead
        // gateopener-41m.21) rather than the generic fallback.
        #expect(coordinator.pinStopMessage == "Unpinned - boom 0")

        coordinator.setPinned(true)
        #expect(coordinator.pinStopMessage == nil)
    }

    // MARK: - unpin mid-stream lets the current session end normally, no renewal

    /// MUTATION CHECK: `setPinned(false)` NOT cancelling `renewTask` (were
    /// one somehow pending) or a leftover `isPinned` check firing anyway
    /// would make `sessionStartCount` exceed 1 once the current session
    /// reaches `.ended`.
    @Test func unpinMidStreamEndsNormallyWithNoRenewal() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.05) },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionState == .streaming }

        coordinator.setPinned(false)
        #expect(coordinator.isPinned == false)

        await waitUntil { coordinator.lastTerminal == .ended }

        #expect(coordinator.sessionStartCount == 1)
        #expect(coordinator.lastTerminal == .ended)
    }

    // MARK: - setPinned(true) with no active session starts one via startOrRetain()

    /// MUTATION CHECK: removing the `if phase != .connecting, phase !=
    /// .streaming { startOrRetain() }` call from `setPinned(true)` would
    /// leave `sessionStartCount == 0` after pinning with nothing playing.
    @Test func setPinnedTrueWithNoSessionStartsOne() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        await Task.yield()

        #expect(coordinator.sessionStartCount == 1)
        #expect(coordinator.isPinned == true)
        #expect(coordinator.pinnedSince != nil)
    }

    // MARK: - pinRemaining

    /// MUTATION CHECK: removing the `guard isPinned` in `pinRemaining` (or
    /// always returning a non-nil value) would make the first `#expect ==
    /// nil` fail.
    @Test func pinRemainingNilWhenUnpinnedThenComputedWhenPinned() async {
        var currentTime = Date()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxPinnedDuration: 300),
            now: { currentTime }
        )

        #expect(coordinator.pinRemaining == nil)

        coordinator.setPinned(true)
        #expect(coordinator.pinRemaining == 300)

        currentTime = currentTime.addingTimeInterval(100)
        #expect(coordinator.pinRemaining == 200)
    }

    // MARK: - pinRenewalCount / isRenewing (bead gateopener-41m.15)

    /// The pin's FIRST session is not a renewal: `pinRenewalCount == 0` and
    /// `isRenewing == false` immediately after `setPinned(true)` starts it.
    ///
    /// MUTATION CHECK: incrementing `pinRenewalCount` anywhere in
    /// `setPinned(true)`/`startSession()` itself (rather than only inside
    /// `handlePinnableTermination`'s `.renew` handling) would make this fail.
    @Test func firstPinnedSessionIsNotARenewal() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        await Task.yield()

        #expect(coordinator.pinRenewalCount == 0)
        #expect(coordinator.isRenewing == false)
    }

    /// Once a pinned session ends and is renewed (`.renew(after: 0)`),
    /// `pinRenewalCount` becomes `1` and `isRenewing` becomes `true` — the
    /// signal `DoorVideoSlotContent.content(...)` uses to show
    /// "Reconnecting…" instead of "Connecting…" for the second-and-later
    /// mounted session.
    ///
    /// MUTATION CHECK: removing `pinRenewalCount += 1` from the `after <= 0`
    /// branch of `handlePinnableTermination` would leave this at `0` forever,
    /// failing both assertions below.
    @Test func renewalAfterEndedIncrementsRenewalCountAndSetsIsRenewing() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return callCount == 0
                    ? DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02)
                    : DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionStartCount == 2 }

        #expect(coordinator.pinRenewalCount == 1)
        #expect(coordinator.isRenewing == true)
    }

    /// A renewal that goes through the failure-backoff path (`.renew(after:
    /// > 0)`) also increments `pinRenewalCount`, once the backoff sleep
    /// completes and the replacement session actually starts — not merely
    /// when the renewal is scheduled.
    ///
    /// MUTATION CHECK: incrementing `pinRenewalCount` when `renewTask` is
    /// first scheduled (rather than after `renewSleep` completes and
    /// `startSession` is actually called) would make this pass too early —
    /// this test's `waitUntil` on `sessionStartCount == 2` combined with the
    /// instant `renewSleep` does not by itself distinguish the two, but the
    /// `dismissedDuringBackoffDoesNotCountAsRenewal` test below does.
    @Test func renewalAfterFailureBackoffIncrementsRenewalCount() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return callCount == 0
                    ? DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom")
                    : DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 5, failureBackoff: 0),
            renewSleep: instantRenewSleep
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.sessionStartCount == 2 }

        #expect(coordinator.pinRenewalCount == 1)
        #expect(coordinator.isRenewing == true)
    }

    /// A pending renewal that is CANCELLED by `dismiss()` before its backoff
    /// completes must never have counted as a renewal — `pinRenewalCount`
    /// only increments once `startSession` actually runs, not when a renewal
    /// is merely scheduled.
    ///
    /// MUTATION CHECK: incrementing `pinRenewalCount` at the point
    /// `renewTask` is created (rather than inside the task, after the sleep
    /// and identity guard) would make `pinRenewalCount == 1` here even though
    /// no second session ever actually started.
    @Test func dismissedDuringBackoffDoesNotCountAsRenewal() async {
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom") },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 5, failureBackoff: 5)
            // Real renewSleep: the backoff must still be pending when
            // dismiss() arrives below.
        )

        coordinator.setPinned(true)
        await waitUntil(timeout: 1) { coordinator.session?.state.phase == .failed }

        coordinator.dismiss()

        #expect(coordinator.pinRenewalCount == 0)
        #expect(coordinator.isRenewing == false)

        // Wait comfortably longer than the backoff to prove no delayed
        // increment sneaks through.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.pinRenewalCount == 0)
    }

    /// `setPinned(true)` on a FRESH pin resets `pinRenewalCount` back to `0`
    /// even if a previous pin had renewed — a later pin's first session must
    /// not be mistaken for a renewal of the earlier one.
    ///
    /// MUTATION CHECK: removing `pinRenewalCount = 0` from `setPinned(true)`
    /// would leave the count from the FIRST pin's renewal carried over,
    /// making `isRenewing` incorrectly `true` for the second pin's first
    /// session.
    @Test func rePinningResetsRenewalCount() async {
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                return callCount == 0
                    ? DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02)
                    : DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
            },
            isEnabled: { true }
        )

        coordinator.setPinned(true)
        await waitUntil { coordinator.pinRenewalCount == 1 }

        coordinator.dismiss()
        coordinator.setPinned(true)
        await Task.yield()

        #expect(coordinator.pinRenewalCount == 0)
        #expect(coordinator.isRenewing == false)
    }
}
