import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `DoorVideoCoordinator`'s `eventSink` (bead gateopener-41m.20):
/// coordinator/pin events are emitted at the documented points, in the
/// documented format, WITHOUT changing any pin/renewal decision logic
/// itself (already covered by `DoorVideoCoordinatorPinTests`).
@MainActor
struct DoorVideoCoordinatorEventSinkTests {
    /// Polls `condition` until it returns `true` or `timeout` elapses,
    /// mirroring `DoorVideoCoordinatorPinTests`' helper.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// No-op sleep so failure-backoff renewals in tests are instant rather
    /// than waiting out `pinPolicy.failureBackoff` for real — mirrors
    /// `DoorVideoCoordinatorPinTests.instantRenewSleep`.
    private func instantRenewSleep(_ duration: Duration) async throws {}

    /// Thread-safe recorder of event strings, standing in for the real
    /// `VideoDiagnostics.appendEvent`-backed sink `GateOpenerIOSApp` wires —
    /// never touches any `UserDefaults`, real or throwaway, keeping this
    /// test hermetic.
    final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []

        func record(_ event: String) {
            lock.lock(); defer { lock.unlock() }
            _events.append(event)
        }

        var events: [String] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
    }

    // MARK: - setPinned(true)/(false) emit "pin on"/"pin off (user)"

    /// MUTATION CHECK: removing `eventSink("pin on")` from
    /// `DoorVideoCoordinator.setPinned(_:)`'s `true` branch would leave
    /// `recorder.events` empty after `setPinned(true)`, failing the
    /// `contains("pin on")` assertion below.
    @Test func setPinnedTrueEmitsPinOn() async {
        let recorder = EventRecorder()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true },
            eventSink: { recorder.record($0) }
        )

        coordinator.setPinned(true)
        await Task.yield()

        #expect(recorder.events.contains("pin on"))
    }

    /// MUTATION CHECK: removing `eventSink("pin off (user)")` from
    /// `DoorVideoCoordinator.setPinned(_:)`'s `false` branch would leave
    /// `recorder.events` missing that event after `setPinned(false)`.
    @Test func setPinnedFalseEmitsPinOffUser() async {
        let recorder = EventRecorder()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true },
            eventSink: { recorder.record($0) }
        )

        coordinator.setPinned(true)
        coordinator.setPinned(false)
        await Task.yield()

        #expect(recorder.events.contains("pin off (user)"))
    }

    // MARK: - dismiss() emits "dismiss (<reason>)"

    /// MUTATION CHECK: removing `eventSink("dismiss (\(reason))")` from
    /// `dismiss(reason:)` would leave no "dismiss" event recorded, failing
    /// the assertion below.
    @Test func dismissEmitsDismissEventWithDefaultReason() async {
        let recorder = EventRecorder()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true },
            eventSink: { recorder.record($0) }
        )

        coordinator.startForOpen()
        await Task.yield()
        coordinator.dismiss()

        #expect(recorder.events.contains("dismiss (user)"))
    }

    /// An explicit `reason:` (as `GateOpenerIOSApp`'s scenePhase handler
    /// passes) is reflected verbatim in the emitted event text.
    @Test func dismissEmitsDismissEventWithExplicitReason() async {
        let recorder = EventRecorder()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true },
            eventSink: { recorder.record($0) }
        )

        coordinator.startForOpen()
        await Task.yield()
        coordinator.dismiss(reason: "background")

        #expect(recorder.events.contains("dismiss (background)"))
    }

    // MARK: - startForForeground() emits "auto-start (foreground)"

    /// MUTATION CHECK: removing `eventSink("auto-start (foreground)")` from
    /// `startForForeground()` would leave the event unrecorded.
    @Test func startForForegroundEmitsAutoStartEvent() async {
        let recorder = EventRecorder()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true },
            isAutoStartEnabled: { true },
            eventSink: { recorder.record($0) }
        )

        coordinator.startForForeground()
        await Task.yield()

        #expect(recorder.events.contains("auto-start (foreground)"))
    }

    /// `isAutoStartEnabled: { false }` must emit NO event at all — the
    /// no-op guard fires before the sink call.
    @Test func startForForegroundWithAutoStartDisabledEmitsNoEvent() async {
        let recorder = EventRecorder()
        let coordinator = DoorVideoCoordinator(
            makeSession: { DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10) },
            isEnabled: { true },
            isAutoStartEnabled: { false },
            eventSink: { recorder.record($0) }
        )

        coordinator.startForForeground()
        await Task.yield()

        #expect(recorder.events.isEmpty)
    }

    // MARK: - Full pin sequence: pin on -> ended -> renew -> 3x failed+backoff -> stop(tooManyFailures)

    /// The documented end-to-end pin event sequence (bead gateopener-41m.20
    /// DONE-CRITERIA): pin on, an immediate renew after the first session's
    /// normal `.ended`, then three failing renewals each preceded by a "pin
    /// backoff" event, ending in "pin stop: tooManyFailures" — captured via
    /// the injected `eventSink`, independent of `VideoDiagnostics`/
    /// `UserDefaults` entirely.
    ///
    /// MUTATION CHECK: this test exercises the SAME renew/backoff/stop
    /// decision path as `DoorVideoCoordinatorPinTests
    /// .threeConsecutiveFailuresUnpinsWithMessage` — any regression that
    /// breaks event emission at one of the five points below (without
    /// necessarily breaking session-count assertions) is caught here where
    /// it would not be caught there.
    @Test func fullPinSequenceEmitsExpectedEventsInOrder() async {
        let recorder = EventRecorder()
        var callCount = 0
        let coordinator = DoorVideoCoordinator(
            makeSession: {
                defer { callCount += 1 }
                // Session 0: ends normally (no failure).
                if callCount == 0 {
                    return DoorVideoSession.debugStub(connectingDelay: 0.02, streamingDuration: 0.02)
                }
                // Sessions 1, 2, 3: each fails immediately.
                return DoorVideoSession.debugStub(connectingDelay: 0.02, failAfter: "boom \(callCount)")
            },
            isEnabled: { true },
            pinPolicy: DoorVideoPinPolicy(maxConsecutiveFailures: 3, failureBackoff: 2),
            renewSleep: instantRenewSleep,
            eventSink: { recorder.record($0) }
        )

        coordinator.setPinned(true)
        await waitUntil(timeout: 3) { !coordinator.isPinned }

        #expect(coordinator.isPinned == false)
        #expect(coordinator.pinStopMessage == "Camera unavailable - unpinned")
        #expect(coordinator.sessionStartCount == 4)

        let events = recorder.events

        // Sessions: 0 (ends normally) -> renew #1 immediately; 1 (fails,
        // failures=1) -> backoff, renew #2; 2 (fails, failures=2) -> backoff,
        // renew #3; 3 (fails, failures=3 >= maxConsecutiveFailures) -> STOP
        // (no fourth backoff -- `DoorVideoPinPolicy.decide` checks the
        // failure-count limit BEFORE deciding to renew, per its documented
        // rule order).
        #expect(events.first == "pin on")
        #expect(events.contains("pin renew #1 (after ended)"))
        #expect(events.contains(where: { $0.hasPrefix("pin backoff 2s (failures=1)") }))
        #expect(events.contains(where: { $0.hasPrefix("pin renew #2 (after failed: boom") }))
        #expect(events.contains(where: { $0.hasPrefix("pin backoff 2s (failures=2)") }))
        #expect(events.contains(where: { $0.hasPrefix("pin renew #3 (after failed: boom") }))
        #expect(!events.contains(where: { $0.hasPrefix("pin backoff") && $0.contains("failures=3") }))
        #expect(events.last == "pin stop: tooManyFailures")

        // Insertion order: "pin on" precedes the first renew, which
        // precedes the first backoff, and the final stop is last.
        let pinOnIndex = events.firstIndex(of: "pin on")
        let firstRenewIndex = events.firstIndex(of: "pin renew #1 (after ended)")
        let stopIndex = events.firstIndex(of: "pin stop: tooManyFailures")
        #expect(pinOnIndex != nil && firstRenewIndex != nil && stopIndex != nil)
        if let pinOnIndex, let firstRenewIndex, let stopIndex {
            #expect(pinOnIndex < firstRenewIndex)
            #expect(firstRenewIndex < stopIndex)
        }
    }

    // MARK: - cooldownUntil transition to non-nil emits "cooldown wait <s>s"

    /// MUTATION CHECK: removing the `eventSink("cooldown wait ...")` call
    /// from `handleCooldownChange` would leave no such event recorded when
    /// `cooldownUntil` flips from `nil` to a concrete deadline.
    @Test func cooldownUntilBecomingNonNilEmitsCooldownWaitEvent() async {
        let recorder = EventRecorder()
        let session = DoorVideoSession.debugStub(connectingDelay: 10, streamingDuration: 10)
        let fixedNow = Date()
        let coordinator = DoorVideoCoordinator(
            makeSession: { session },
            isEnabled: { true },
            now: { fixedNow },
            eventSink: { recorder.record($0) }
        )

        coordinator.startForOpen()
        await Task.yield()

        session.onCooldownChange?(fixedNow.addingTimeInterval(9))

        #expect(recorder.events.contains(where: { $0.hasPrefix("cooldown wait 9s") }))

        // Clearing back to nil, then setting again, must emit a SECOND
        // event (each new cooldown wait is independently notable) — but
        // merely re-publishing the SAME non-nil value must not duplicate
        // the event (handled by the nil-check guard in
        // `handleCooldownChange`).
        let countAfterFirst = recorder.events.count
        session.onCooldownChange?(fixedNow.addingTimeInterval(9))
        #expect(recorder.events.count == countAfterFirst)
    }
}
