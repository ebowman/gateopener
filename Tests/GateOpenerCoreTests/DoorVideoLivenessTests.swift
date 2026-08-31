import Testing
@testable import GateOpenerCore

/// Tests for `DoorVideoLiveness.rtpCountersShowProgress(previous:current:)`,
/// the pure RTP-liveness decision moved out of `DoorVideoFrameView` (the app
/// target, which has no test target) in gateopener-v6t.2.
struct DoorVideoLivenessTests {
    @Test func previousNilAndCurrentAllZeroIsNotProgress() {
        let current = RTPCounters(framesReceived: 0, packetsReceived: 0)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: nil, current: current) == false)
    }

    @Test func previousNilAndCurrentFramesReceivedPositiveIsProgress() {
        let current = RTPCounters(framesReceived: 1, packetsReceived: 0)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: nil, current: current) == true)
    }

    @Test func previousNilAndCurrentPacketsReceivedPositiveIsProgress() {
        let current = RTPCounters(framesReceived: 0, packetsReceived: 1)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: nil, current: current) == true)
    }

    @Test func strictIncreaseInFramesReceivedOnlyIsProgress() {
        let previous = RTPCounters(framesReceived: 10, packetsReceived: 20)
        let current = RTPCounters(framesReceived: 11, packetsReceived: 20)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: previous, current: current) == true)
    }

    @Test func strictIncreaseInPacketsReceivedOnlyIsProgress() {
        let previous = RTPCounters(framesReceived: 10, packetsReceived: 20)
        let current = RTPCounters(framesReceived: 10, packetsReceived: 21)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: previous, current: current) == true)
    }

    @Test func bothCountersExactlyFlatIsNotProgress() {
        let previous = RTPCounters(framesReceived: 10, packetsReceived: 20)
        let current = RTPCounters(framesReceived: 10, packetsReceived: 20)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: previous, current: current) == false)
    }

    /// Retained-baseline-across-a-gap scenario (gateopener-v6t.3):
    /// `DoorVideoFrameView.pollOnce()` deliberately keeps `lastRTPCounters`
    /// unchanged (rather than nulling it) when a poll cannot obtain RTP
    /// counters at all, so the NEXT poll that can obtain them compares
    /// against this last known-good sample instead of a fresh `nil`. This
    /// is the case that fix protects: a genuinely dead stream's cumulative
    /// counters are identical before and after such a gap, so comparing
    /// across the gap (same as `bothCountersExactlyFlatIsNotProgress`
    /// above, restated here under its own name for discoverability) still
    /// correctly reports no progress — unlike comparing a nonzero `current`
    /// against a nulled `previous`, which would (see
    /// `previousNilFalsePositiveIfUsedMidSessionIsWhyBaselineMustBeRetained`
    /// below) falsely register progress on every such gap.
    @Test func flatCountersAcrossRetainedGapBaselineIsNotProgress() {
        let counters = RTPCounters(framesReceived: 10, packetsReceived: 20)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: counters, current: counters) == false)
    }

    /// Documents WHY `pollOnce()` must never null `lastRTPCounters` mid-
    /// session merely because a single poll's `pc.getStats()` failed:
    /// `rtpCountersShowProgress(previous: nil, current:)` returns `true`
    /// for ANY nonzero `current`, which is exactly correct at session start
    /// (nil means "no counters observed yet") but would be a FALSE POSITIVE
    /// if `previous` were nulled to represent a mid-session gap instead — a
    /// DEAD stream's counters stay nonzero (its last cumulative total)
    /// forever, so every gap would re-arm the plateau clock by treating
    /// that stale nonzero total as fresh progress. This is the bug fixed by
    /// gateopener-v6t.3: keep the baseline unchanged across gaps (see
    /// `flatCountersAcrossRetainedGapBaselineIsNotProgress` above) rather
    /// than nulling it.
    @Test func previousNilFalsePositiveIfUsedMidSessionIsWhyBaselineMustBeRetained() {
        // Same nonzero `current` a dead stream would keep reporting forever.
        let deadStreamCumulativeCounters = RTPCounters(framesReceived: 42, packetsReceived: 84)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: nil, current: deadStreamCumulativeCounters) == true)
    }

    @Test func oneCounterDecreasesWhileOtherStaysFlatIsNotProgress() {
        // Models a stats-reset: framesReceived drops (e.g. the page's stats
        // object reinitialized) while packetsReceived stays exactly flat.
        let previous = RTPCounters(framesReceived: 10, packetsReceived: 20)
        let current = RTPCounters(framesReceived: 5, packetsReceived: 20)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: previous, current: current) == false)
    }

    @Test func oneCounterDecreasesWhileOtherIncreasesIsProgress() {
        // Documents CURRENT (as-shipped) semantics as-is: the function's
        // decision is an OR across the two counters, so a strict increase in
        // EITHER counter counts as progress even if the other counter
        // simultaneously decreases (e.g. a stats reset on one counter
        // coinciding with genuine forward progress on the other). This is
        // not necessarily the ideal behavior — it is asserted here only to
        // pin down and document the function's actual current semantics.
        let previous = RTPCounters(framesReceived: 10, packetsReceived: 20)
        let current = RTPCounters(framesReceived: 5, packetsReceived: 21)
        #expect(DoorVideoLiveness.rtpCountersShowProgress(previous: previous, current: current) == true)
    }
}
