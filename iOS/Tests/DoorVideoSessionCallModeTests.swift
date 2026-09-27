import AVFoundation
import Foundation
import Testing
@testable import GateOpener

/// Tests for bead gateopener-1pm.4: `DoorVideoSession`'s `.call` mode —
/// `audioSessionPlan(for:)`, `callPreflightMessage(for:)`, the "mic:"
/// negotiation-failure mapping, and (via `debugStub(mode:
/// audioSessionController:)` + `NoOpAudioSessionController`) the terminal-
/// transition audio-session restore.
@MainActor
struct DoorVideoSessionCallModeTests {
    // MARK: - audioSessionPlan(for:)

    /// `.view` must stay BYTE-FOR-BYTE the category this type has always
    /// set on a successful view session: `.ambient`, `.default` mode, no
    /// options.
    ///
    /// MUTATION CHECK: returning any other category/mode/non-empty options
    /// for `.view` would fail this assertion.
    @Test func audioSessionPlanViewIsAmbientDefaultNoOptions() {
        let plan = DoorVideoSession.audioSessionPlan(for: .view)
        #expect(plan == DoorVideoSession.AudioSessionPlan(category: .ambient, mode: .default, options: []))
    }

    /// `.call` must activate a genuine two-way voice call: `.playAndRecord`,
    /// `.voiceChat` mode, `[.defaultToSpeaker, .allowBluetoothHFP]`.
    ///
    /// MUTATION CHECK: dropping `.defaultToSpeaker`/`.allowBluetoothHFP`, or
    /// returning `.ambient`/`.view`'s plan for `.call`, would fail this
    /// assertion.
    @Test func audioSessionPlanCallIsPlayAndRecordVoiceChatWithSpeakerAndBluetoothHFP() {
        let plan = DoorVideoSession.audioSessionPlan(for: .call)
        #expect(plan == DoorVideoSession.AudioSessionPlan(
            category: .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        ))
    }

    /// `.view` and `.call` plans must never be equal to each other — a
    /// belt-and-suspenders check that view sessions never silently end up
    /// using the call plan.
    @Test func viewAndCallPlansAreNotEqual() {
        #expect(DoorVideoSession.audioSessionPlan(for: .view) != DoorVideoSession.audioSessionPlan(for: .call))
    }

    // MARK: - callPreflightMessage(for:)

    /// `.denied` is the ONLY permission that fails a `.call` session BEFORE
    /// the page ever loads.
    ///
    /// MUTATION CHECK: returning `nil` for `.denied` would fail this
    /// assertion.
    @Test func callPreflightMessageDeniedReturnsSettingsMessage() {
        #expect(DoorVideoSession.callPreflightMessage(for: .denied) == "Microphone access is off in Settings")
    }

    /// `.undetermined` must proceed — the WebKit/system prompt is what
    /// actually asks the user.
    @Test func callPreflightMessageUndeterminedReturnsNil() {
        #expect(DoorVideoSession.callPreflightMessage(for: .undetermined) == nil)
    }

    /// `.granted` must proceed normally.
    @Test func callPreflightMessageGrantedReturnsNil() {
        #expect(DoorVideoSession.callPreflightMessage(for: .granted) == nil)
    }

    // MARK: - failureMessage(forNegotiationError:) -- the "mic:" mapping

    /// A `startNegotiation()` rejection whose WKWebView-surfaced details
    /// contain "mic:" (door-video.html's `negotiate()` throws "mic: " +
    /// name on a `getUserMedia` failure) must map to "Microphone not
    /// available" -- BEFORE any `DoorVideoNegotiationFailure.userMessage
    /// (for:)` ICE/network fallback ever runs.
    ///
    /// MUTATION CHECK: returning `nil` unconditionally (i.e. never
    /// detecting a mic failure) would fail this assertion.
    @Test func failureMessageForNegotiationErrorDetectsMicPrefixedRejection() {
        let error = NSError(
            domain: "WKErrorDomain",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "JavaScript exception: mic: error:NotAllowedError"]
        )
        #expect(DoorVideoSession.failureMessage(forNegotiationError: error) == "Microphone not available")
    }

    /// An unrelated negotiation failure (e.g. the existing ICE-gathering
    /// timeout) must NOT be misreported as a mic failure -- `nil` here is
    /// what tells `start(mode:)` to fall through to
    /// `DoorVideoNegotiationFailure.userMessage(for:)`.
    ///
    /// MUTATION CHECK: returning "Microphone not available" unconditionally
    /// (i.e. treating every negotiation failure as a mic failure) would
    /// fail this assertion.
    @Test func failureMessageForNegotiationErrorIgnoresUnrelatedFailure() {
        let error = NSError(
            domain: "WKErrorDomain",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "JavaScript exception: ice-gathering-timeout"]
        )
        #expect(DoorVideoSession.failureMessage(forNegotiationError: error) == nil)
    }

    // MARK: - debugStub(mode:audioSessionController:) terminal-transition restore

    /// A `.call` debug stub that runs the NORMAL `.connecting` ->
    /// `.streaming` -> `.ended` timeline must activate the call's audio
    /// plan, then restore `.view`'s (`.ambient`) plan and deactivate --
    /// each exactly once -- entirely through the injected fake, never the
    /// real `AVAudioSession`.
    ///
    /// MUTATION CHECK: removing the `state.didSet` choke point's call to
    /// `restoreAmbientAudioSessionIfNeeded()` would leave `fake.appliedPlans`
    /// with only the `.call` plan (never restored), failing this
    /// assertion.
    @Test func callDebugStubNormalEndingActivatesThenRestoresAudioSessionExactlyOnce() async {
        let fake = NoOpAudioSessionController()
        let session = DoorVideoSession.debugStub(
            connectingDelay: 0.01,
            streamingDuration: 0.01,
            mode: .call,
            audioSessionController: fake
        )

        await session.start()

        #expect(session.state == .ended)
        #expect(fake.appliedPlans == [
            DoorVideoSession.audioSessionPlan(for: .call),
            DoorVideoSession.audioSessionPlan(for: .view),
        ])
        #expect(fake.activeCalls.map(\.active) == [true, false])
        #expect(fake.activeCalls.last?.options == [.notifyOthersOnDeactivation])
    }

    /// Same as above, but for the `failAfter` (failure) timeline -- a
    /// `.call` session that fails must ALSO restore the audio session
    /// exactly once.
    @Test func callDebugStubFailureEndingActivatesThenRestoresAudioSessionExactlyOnce() async {
        let fake = NoOpAudioSessionController()
        let session = DoorVideoSession.debugStub(
            connectingDelay: 0.01,
            failAfter: "boom",
            mode: .call,
            audioSessionController: fake
        )

        await session.start()

        #expect(session.state == .failed("boom"))
        #expect(fake.appliedPlans == [
            DoorVideoSession.audioSessionPlan(for: .call),
            DoorVideoSession.audioSessionPlan(for: .view),
        ])
        #expect(fake.activeCalls.map(\.active) == [true, false])
    }

    /// A `.view` debug stub (the default `mode:`, matching every stub call
    /// site before this bead) must NEVER touch the injected
    /// `AudioSessionControlling` at all -- `.playAndRecord` is never
    /// applied, and the audio session is never (de)activated.
    ///
    /// MUTATION CHECK: calling `activateCallAudioSession()`/
    /// `restoreAmbientAudioSessionIfNeeded()` unconditionally (dropping
    /// their `mode == .call` guard) would fail this assertion.
    @Test func viewDebugStubNeverTouchesAudioSessionController() async {
        let fake = NoOpAudioSessionController()
        let session = DoorVideoSession.debugStub(
            connectingDelay: 0.01,
            streamingDuration: 0.01,
            audioSessionController: fake
        )

        await session.start()

        #expect(session.state == .ended)
        #expect(fake.appliedPlans.isEmpty)
        #expect(fake.activeCalls.isEmpty)
    }

    // MARK: - FIX (reviewer-flagged gap): never-activated + double-restore

    /// A `.call` session that fails BEFORE `activateCallAudioSession()` ever
    /// runs (`debugStub`'s `failBeforeActivation:`, mirroring the real
    /// `start(mode:)` denied-mic-preflight path, which fails before
    /// `.connecting` is even entered) must record ZERO
    /// `AudioSessionControlling` calls -- there is nothing to restore, since
    /// nothing was ever activated.
    ///
    /// MUTATION CHECK: dropping `restoreAmbientAudioSessionIfNeeded()`'s
    /// `didActivateCallAudio` guard (reverting to the `mode == .call`-only
    /// check) would leave `fake.appliedPlans`/`fake.activeCalls` non-empty
    /// (the `.ambient`/`setActive(false)` restore pair), failing this
    /// assertion.
    @Test func callDebugStubFailingBeforeActivationTouchesAudioSessionControllerZeroTimes() async {
        let fake = NoOpAudioSessionController()
        let session = DoorVideoSession.debugStub(
            failBeforeActivation: "Microphone access is off in Settings",
            mode: .call,
            audioSessionController: fake
        )

        await session.start()

        #expect(session.state == .failed("Microphone access is off in Settings"))
        #expect(fake.appliedPlans.isEmpty)
        #expect(fake.activeCalls.isEmpty)
    }

    /// A `.call` session that DOES activate, then has `stop()` land, and
    /// THEN receives a second terminal `state` transition on the same
    /// attempt (the race the reviewer flagged: `stop()` landing during
    /// `startNegotiation()`'s pending `await`, whose eventual throw lands in
    /// a `.failed(...)` catch -- a second `state.didSet` firing after the
    /// first already restored) must restore the audio session EXACTLY ONCE,
    /// not twice.
    ///
    /// Drives the second transition via `forceStateForTesting(_:)` (a
    /// DEBUG-only test hook), since there is no seam to make a real
    /// `startNegotiation()` throw after `stop()` without a real WKWebView
    /// pipeline.
    ///
    /// MUTATION CHECK: `restoreAmbientAudioSessionIfNeeded()` not clearing
    /// `didActivateCallAudio` after doing its work (or the flag not gating
    /// it at all) would leave `fake.appliedPlans`/`fake.activeCalls` with
    /// FOUR entries (the `.call`/`.view` pair applied twice), failing this
    /// assertion.
    @Test func callDebugStubStopThenSecondTerminalTransitionRestoresExactlyOnce() async {
        let fake = NoOpAudioSessionController()
        let session = DoorVideoSession.debugStub(
            connectingDelay: 10,
            streamingDuration: 10,
            mode: .call,
            audioSessionController: fake
        )

        Task { await session.start() }

        let deadline = Date().addingTimeInterval(2)
        while session.state == .idle, Date() < deadline {
            await Task.yield()
        }
        #expect(session.state == .connecting)

        session.stop()
        #expect(session.state == .ended)

        // Reproduce the race: a SECOND terminal transition on the same
        // attempt, after the first (`stop()`'s `.ended`) already restored.
        session.forceStateForTesting(.failed("second transition"))
        #expect(session.state == .failed("second transition"))

        #expect(fake.appliedPlans == [
            DoorVideoSession.audioSessionPlan(for: .call),
            DoorVideoSession.audioSessionPlan(for: .view),
        ])
        #expect(fake.activeCalls.map(\.active) == [true, false])
    }
}
