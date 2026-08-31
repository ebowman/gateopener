import Foundation

/// Inbound-video RTP counters sampled from `pc.getStats()` via the
/// page's `window.captureFrameAndStats` bridge (see `Resources/
/// door-video.html`). Two counters are tracked, not just one, because
/// either can legitimately be the one that increments most reliably
/// depending on decoder state — mirrors `DoorVideoSession.
/// watchForFirstFrame()`'s analogous preference for `getStats()`-based
/// signals over the page's own `requestVideoFrameCallback`, which that
/// type's doc comment documents as unreliable in this WKWebView
/// context.
public struct RTPCounters: Equatable, Sendable {
    public let framesReceived: Int
    public let packetsReceived: Int

    public init(framesReceived: Int, packetsReceived: Int) {
        self.framesReceived = framesReceived
        self.packetsReceived = packetsReceived
    }
}

/// Pure liveness-decision logic for door-camera video, factored out of
/// `DoorVideoFrameView` (the app target, which has no test target) so it
/// can be reasoned about — and unit-tested — in isolation.
public enum DoorVideoLiveness {
    /// Pure decision, deliberately free of any WKWebView/Date/Task
    /// plumbing so it can be reasoned about (and exercised) in isolation
    /// from the live poll loop: does `current` represent genuine forward
    /// RTP progress relative to `previous`?
    ///
    /// - `previous == nil` (no counters observed yet this session — see
    ///   `DoorVideoFrameView.lastRTPCounters`'s doc comment) counts as
    ///   progress only if `current` ALREADY shows nonzero traffic. An
    ///   all-zero baseline sample (e.g. taken right as negotiation
    ///   completes, before any RTP has actually arrived) must NOT hold the
    ///   plateau clock open indefinitely on its own — a session that never
    ///   receives any RTP at all still needs to plateau/hard-timeout
    ///   normally, exactly as before this fix. NOTE: the caller must only
    ///   pass `nil` for a genuinely fresh session baseline, never as a
    ///   stand-in for "counters were unavailable this poll" — doing the
    ///   latter would let a dead stream's nonzero cumulative counters
    ///   register a false "progress" on every such gap, since any nonzero
    ///   `current` counts as progress against a `nil` previous.
    /// - A counter that DECREASES relative to `previous` indicates a reset
    ///   (e.g. the page's stats object reinitializing) rather than genuine
    ///   progress, and does not by itself count as progress.
    /// - Otherwise, progress is any STRICT increase in either counter —
    ///   this is what fixes the false plateau on a static scene (frames
    ///   are still arriving and being decoded, the picture just isn't
    ///   changing), while a genuinely frozen/dead RTP stream (counters
    ///   stay flat poll after poll) still plateaus after `plateauInterval`.
    public static func rtpCountersShowProgress(previous: RTPCounters?, current: RTPCounters) -> Bool {
        guard let previous else {
            return current.framesReceived > 0 || current.packetsReceived > 0
        }
        return current.framesReceived > previous.framesReceived
            || current.packetsReceived > previous.packetsReceived
    }
}
