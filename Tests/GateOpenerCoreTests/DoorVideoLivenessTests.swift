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
