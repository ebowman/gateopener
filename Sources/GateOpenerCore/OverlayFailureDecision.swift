import Foundation

/// Pure policy for what `OverlayWindowController` must do when the
/// open-triggered `DoorVideoSession` fails (or ends before it ever streamed),
/// given whether `GateState` has already resolved for the current open.
///
/// Extracted for epic gateopener-6s8 / bead gateopener-6s8.3: THE BUG this
/// exists to fix is that `handleResolved(holdDuration:)` and
/// `handleIdleOrNeedsSetup()` both return early while a video session is in
/// flight for the current open (see their doc comments in
/// `OverlayWindowController.swift`), so when that video session later fails,
/// nothing is left to schedule the hold-then-fade that would otherwise hide
/// the panel — it strands on screen, ignoring mouse events, until the next
/// open. This type is the single source of truth for "what happens now",
/// decided purely from whether `GateState` already resolved (and if so, with
/// what hold duration) — no `NSView`/`Task`/timing concerns leak in here.
public enum OverlayFailureDecision: Equatable {
    /// `GateState` already resolved (`.succeeded`/`.failed`) for this open
    /// while the video session was still in flight — the resolve handler
    /// deferred its hold-then-fade rather than running it. The caller must
    /// now run that SAME hold-then-fade sequence with `hold` as the hold
    /// duration, since nothing else will ever schedule it.
    case scheduleFade(hold: Duration)

    /// `GateState` has not resolved yet for this open. The caller must do
    /// nothing further: once `GateState` does resolve, the normal
    /// `handleResolved(holdDuration:)` path will run unobstructed (the video
    /// session is no longer in flight) and will schedule its own
    /// hold-then-fade as usual.
    case awaitGateResolution

    /// Decides what to do given the hold duration `GateState`'s resolve
    /// handler deferred, if any.
    ///
    /// - `gateResolvedHold == nil`: `GateState` has not resolved for the
    ///   current open yet (or that deferred hold has already been consumed
    ///   and cleared) -> `.awaitGateResolution`.
    /// - `gateResolvedHold != nil`: `GateState` already resolved and deferred
    ///   exactly this hold duration -> `.scheduleFade(hold: gateResolvedHold)`.
    public static func decide(gateResolvedHold: Duration?) -> OverlayFailureDecision {
        guard let gateResolvedHold else {
            return .awaitGateResolution
        }
        return .scheduleFade(hold: gateResolvedHold)
    }

    /// Whether a given failure `message` is short and actionable enough to
    /// briefly show to the user (via `DoorVideoConnectingView(text:)`) before
    /// the panel fades, rather than just fading the canned animation away
    /// silently.
    ///
    /// Deliberately narrow: `true` ONLY for the two specific messages
    /// `DoorVideoBusyPolicy.failureMessage(for:)` produces for `.doorBusy`
    /// ("Door camera busy") and `.timedOut` ("Door camera not responding") —
    /// referenced from `DoorVideoBusyPolicy` itself rather than duplicated as
    /// string literals here, so the two can never silently drift apart. Both
    /// are short, specific, and actionable ("the door is busy, try again in
    /// a moment" / "the door didn't respond, try again"). Every other
    /// failure message (e.g. "Could not reach door camera", "Sign-in
    /// required") returns `false`: those are either too generic to be worth
    /// interrupting the hold-then-fade for, or (sign-in) not something the
    /// gate-open overlay's brief HUD is the right place to surface.
    public static func showsReason(for message: String) -> Bool {
        switch message {
        case DoorVideoBusyPolicy.failureMessage(for: .doorBusy),
             DoorVideoBusyPolicy.failureMessage(for: .timedOut):
            return true
        default:
            return false
        }
    }
}
