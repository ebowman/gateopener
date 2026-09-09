import Foundation

/// `MainActor`-isolated registry of the door-video session timestamps needed
/// by `DoorVideoBusyPolicy`. This is the shared, stateful counterpart to
/// that pure policy: `DoorVideoBusyPolicy` knows the *rules* (cooldown
/// length, how to classify an offer outcome), this type knows the *facts*
/// (when did a session in this process last end or get accepted).
///
/// Intended to be shared by both door-video-owning controllers referenced in
/// epic gateopener-6s8 (`DoorVideoSession` / the gate-open overlay path and
/// the View-door path), via `.shared`, so a cooldown observed by one is
/// respected by the other. A dedicated instance can be created via `init()`
/// for isolated testing.
///
/// IMPORTANT LIMITATION: this registry only knows about sessions started
/// from THIS process. Per memory `comelit-rtc-offer-500-means-door-busy`,
/// the door itself only allows one `rtc/offer` session at a time across ALL
/// clients (this Mac's other window, the iOS app, a widget, a second Mac,
/// etc.) -- a session still STREAMING in a different process is not
/// detectable from here, so `waitBeforeOffer` can return `.zero` even though
/// the door is, in fact, still busy. Callers must still be prepared to
/// handle a `.doorBusy` outcome from `DoorVideoBusyPolicy.classify` after
/// waiting out this registry's cooldown.
@MainActor
public final class DoorVideoSessionRegistry {
    public static let shared = DoorVideoSessionRegistry()

    /// When the most recent session's media/connection ended (naturally,
    /// failed, or was torn down). This is the ONLY timestamp
    /// `waitBeforeOffer` consults -- see its doc comment below for why.
    public private(set) var lastSessionEnded: Date?

    /// When the most recent `rtc/offer` was accepted (HTTP 200) by the door.
    /// Recorded for diagnostics only (e.g. to reconstruct a session's
    /// observed lifetime in logs); it does NOT feed into `waitBeforeOffer`.
    public private(set) var lastSessionAccepted: Date?

    public init() {}

    /// Records that a door-video session's media/connection ended at `at`.
    public func recordSessionEnded(at: Date = Date()) {
        lastSessionEnded = at
    }

    /// Records that an `rtc/offer` was accepted (HTTP 200) at `at`. An
    /// accepted offer also marks the start of a busy window from the door's
    /// point of view, but `waitBeforeOffer` deliberately does NOT derive a
    /// wait from this timestamp -- see its doc comment.
    public func recordSessionAccepted(at: Date) {
        lastSessionAccepted = at
    }

    /// How long the caller should wait before issuing the next `rtc/offer`,
    /// per `DoorVideoBusyPolicy.waitBeforeOffer(lastSessionEnded:now:)`.
    ///
    /// DESIGN NOTE: this deliberately uses `lastSessionEnded` ONLY.
    /// `lastSessionAccepted` is recorded for diagnostics but intentionally
    /// excluded from this calculation -- an earlier design considered
    /// combining both (e.g. taking the later of `lastSessionEnded` and
    /// `lastSessionAccepted` plus an estimated streaming duration), but step
    /// 2 of gateopener-6s8.1's task description explicitly rejected that in
    /// favor of the simpler, explicit rule: only a confirmed session END
    /// starts the cooldown clock. Deriving a wait from acceptance alone
    /// would require guessing how long the session will stream for, which
    /// is exactly the kind of estimate this policy avoids.
    public func waitBeforeOffer(now: Date = Date()) -> Duration {
        DoorVideoBusyPolicy.waitBeforeOffer(lastSessionEnded: lastSessionEnded, now: now)
    }

    /// Pure helper encoding the rule from gateopener-6s8.2 step 4: a
    /// session that never had its `rtc/offer` accepted never occupied the
    /// door's one session slot, so its termination (a pre-accept failure,
    /// or `stop()` called before an offer was ever accepted) must NOT start
    /// a busy-cooldown window -- doing so would make an UNRELATED prior
    /// failure (e.g. "Sign-in required", which never even reached the
    /// door) impose a 15s wait on the NEXT attempt for no reason.
    ///
    /// Callers should call `recordSessionEnded` if and only if this
    /// returns `true`, i.e. only when `offerAccepted` is `true` -- kept as
    /// a separate pure func (rather than inlining `if offerAccepted { ... }`
    /// at every call site) so this rule has exactly one place it is stated
    /// and can be unit-tested in isolation from `DoorVideoSession`'s
    /// WKWebView-dependent call sites, which cannot be exercised headlessly
    /// (see that type's doc comment).
    public static func shouldRecordEnd(offerAccepted: Bool) -> Bool {
        offerAccepted
    }
}
