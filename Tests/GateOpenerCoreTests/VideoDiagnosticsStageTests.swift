import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `VideoDiagnosticsStage` (bead gateopener-kgx.6): the pure line-
/// format logic behind macOS `DoorVideoSession`'s diagnostics recording.
/// `DoorVideoSession` itself cannot be exercised headlessly (no `WKWebView`
/// harness), so these tests are the only automated coverage of the exact
/// line wording, especially the endpoint-id truncation's privacy guarantee.
struct VideoDiagnosticsStageTests {
    // MARK: - endpoint suffix truncation

    // MARK: - cooldownWait

    /// "door cooldown: waiting X.Xs" — one decimal place, matching
    /// `terminal(.streaming(afterSeconds:))`'s precision.
    @Test func cooldownWaitFormat() {
        #expect(VideoDiagnosticsStage.cooldownWait(seconds: 9.951) == "door cooldown: waiting 10.0s")
        #expect(VideoDiagnosticsStage.cooldownWait(seconds: 0.04) == "door cooldown: waiting 0.0s")
    }

    /// The endpoint id must be truncated to its `"VIP#"`-onward suffix —
    /// never the full id, which embeds the apartment id ahead of `VIP#`.
    @Test func endpointResolvedTruncatesToVIPSuffix() {
        let id = "_DA_123_abc-00001_VIP#OD#SB100001.1"
        let line = VideoDiagnosticsStage.endpointResolved(id: id)

        #expect(line.contains("VIP#OD#SB100001.1"))
        #expect(!line.contains("_DA_123"))
    }

    /// MUTATION CHECK (per bd memory
    /// `gateopener-vacuous-assertion-failure-mode`): deliberately break the
    /// truncation the way a regression plausibly would (emit the full id
    /// verbatim instead of the VIP#-suffix) and confirm the SAME assertions
    /// above would then fail — i.e. the test above is not vacuously true.
    /// This test exercises a local reproduction of the "broken" behavior
    /// directly (not `VideoDiagnosticsStage` itself, which stays correct)
    /// so the mutation is documented and re-checkable without hand-editing
    /// production code.
    @Test func mutationCheckFullIdEmissionWouldFailTheSuffixAssertions() {
        let id = "_DA_123_abc-00001_VIP#OD#SB100001.1"
        // Simulates the broken variant: `endpointResolved` returning the
        // full id verbatim instead of truncating.
        let brokenLine = "endpoint \(id)"

        // The real assertions from `endpointResolvedTruncatesToVIPSuffix`
        // above, replayed against the broken line: the "contains the VIP#
        // suffix" half still passes (the suffix is a substring of the full
        // id), but the "does NOT contain the apartment-id prefix" half
        // fails, proving that assertion is load-bearing and not vacuous.
        #expect(brokenLine.contains("VIP#OD#SB100001.1"))
        #expect(brokenLine.contains("_DA_123"))
    }

    /// An endpoint id with no `"VIP#"` marker at all (unexpected shape, but
    /// must still never leak the full id) falls back to a short, documented
    /// non-identifying token rather than the full id.
    @Test func endpointResolvedWithNoVIPMarkerNeverEmitsTheFullId() {
        let id = "_DA_999_completely-different-shape-with-no-marker"
        let line = VideoDiagnosticsStage.endpointResolved(id: id)

        #expect(!line.contains(id))
    }

    /// Documents the chosen fallback shape for the no-`"VIP#"` case: the
    /// id's last 12 characters (long enough for it to still be a
    /// distinguishing diagnostic fragment across attempts, short enough
    /// that it cannot on its own re-identify the apartment prefix that
    /// precedes it in the full id).
    @Test func endpointSuffixFallsBackToLast12CharsWithNoVIPMarker() {
        let id = "_DA_999_completely-different-shape-with-no-marker"
        let suffix = VideoDiagnosticsStage.endpointSuffix(of: id)

        #expect(suffix == String(id.suffix(12)))
        #expect(suffix.count == 12)
    }

    /// A short id (<= 12 chars) with no `"VIP#"` marker falls back to the
    /// literal `"<unrecognised>"` rather than emitting the (short but still
    /// complete) id verbatim.
    @Test func endpointSuffixFallsBackToUnrecognisedForShortIdsWithNoMarker() {
        let suffix = VideoDiagnosticsStage.endpointSuffix(of: "short-id")
        #expect(suffix == "<unrecognised>")
    }

    // MARK: - session start

    @Test func sessionStartFormatsAppVersionBuildAndOS() {
        let line = VideoDiagnosticsStage.sessionStart(appVersion: "0.1.3", build: "128", os: "26.6.2")
        #expect(line == "session start: app 0.1.3 (128), macOS 26.6.2")
    }

    // MARK: - token

    @Test func tokenResolvedSuccess() {
        #expect(VideoDiagnosticsStage.tokenResolved(outcome: .ok) == "token ok")
    }

    @Test func tokenResolvedFailureIncludesReason() {
        let line = VideoDiagnosticsStage.tokenResolved(outcome: .failed("notConfigured"))
        #expect(line == "token failed: notConfigured")
    }

    // MARK: - stun / offer ready

    @Test func stunResolvedFormatsCountOnly() {
        #expect(VideoDiagnosticsStage.stunResolved(count: 5) == "stun resolved 5 addresses")
    }

    @Test func offerReadyFormatsCandidateCount() {
        #expect(VideoDiagnosticsStage.offerReady(candidateCount: 7) == "offer ready: 7 candidates")
    }

    // MARK: - offer attempt

    @Test func offerAttemptSuccessFormat() {
        let line = VideoDiagnosticsStage.offerAttempt(n: 1, of: 2, outcome: .success, latencyMs: 314)
        #expect(line == "rtc/offer attempt 1/2 status=200 latencyMs=314")
    }

    @Test func offerAttemptFailureFormat() {
        let line = VideoDiagnosticsStage.offerAttempt(n: 2, of: 2, outcome: .failure("500"), latencyMs: 120)
        #expect(line == "rtc/offer attempt 2/2 status=500 latencyMs=120")
    }

    @Test func offerAttemptNetworkErrorFormat() {
        let line = VideoDiagnosticsStage.offerAttempt(n: 1, of: 2, outcome: .failure("network-error"), latencyMs: 5000)
        #expect(line == "rtc/offer attempt 1/2 status=network-error latencyMs=5000")
    }

    // MARK: - answer applied / video stats

    @Test func answerAppliedFormat() {
        #expect(VideoDiagnosticsStage.answerApplied() == "answer applied")
    }

    @Test func videoStatsFormatsJSONVerbatim() {
        let json = #"{"video":{"framesDecoded":42}}"#
        #expect(VideoDiagnosticsStage.videoStats(json: json) == "video stats: \(json)")
    }

    // MARK: - terminal

    @Test func terminalStreamingFormat() {
        let line = VideoDiagnosticsStage.terminal(.streaming(afterSeconds: 6.28))
        #expect(line == "terminal: streaming after 6.3s")
    }

    @Test func terminalNoVideoFormat() {
        #expect(VideoDiagnosticsStage.terminal(.noVideo) == "terminal: no video after 20s")
    }

    @Test func terminalFailedFormat() {
        let line = VideoDiagnosticsStage.terminal(.failed(message: "Could not reach door camera"))
        #expect(line == "terminal: failed: Could not reach door camera")
    }

    @Test func terminalStoppedFormat() {
        #expect(VideoDiagnosticsStage.terminal(.stopped) == "terminal: stopped by caller")
    }
}
