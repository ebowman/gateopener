import Foundation

/// Pure policy for the Comelit door's "one `rtc/offer` session at a time"
/// behaviour, confirmed empirically in memory
/// `comelit-rtc-offer-500-means-door-busy`: after a session's media stops,
/// the door answers `rtc/offer` with HTTP 500 for roughly 10-15s before it
/// will accept a new session. This type has no notion of *which* session
/// last ran or *why* it ended -- see `DoorVideoSessionRegistry` for the
/// stateful wrapper that tracks that and calls into this policy.
public enum DoorVideoBusyPolicy {
    /// The door's observed busy window after a session's media stops.
    /// Memory `comelit-rtc-offer-500-means-door-busy` recorded 500s
    /// persisting through +9-10s and a clean 200 at +19s, i.e. somewhere in
    /// the 10-15s range; 15s is chosen as the conservative (longer) bound so
    /// callers wait out the whole observed window rather than racing the
    /// door's lower edge and re-triggering another 500.
    public static let cooldown: Duration = .seconds(15)

    /// How long a caller should wait before issuing a new `rtc/offer`, given
    /// when the previous session ended.
    ///
    /// - `lastSessionEnded == nil` (no prior session in this process):
    ///   `.zero` -- nothing to wait out.
    /// - `now - lastSessionEnded >= cooldown`: `.zero` -- the busy window has
    ///   already elapsed.
    /// - Otherwise: the remaining time until `cooldown` has elapsed, i.e.
    ///   `cooldown - (now - lastSessionEnded)`.
    public static func waitBeforeOffer(lastSessionEnded: Date?, now: Date) -> Duration {
        guard let lastSessionEnded else {
            return .zero
        }
        let elapsed: Duration = .seconds(now.timeIntervalSince(lastSessionEnded))
        guard elapsed < cooldown else {
            return .zero
        }
        return cooldown - elapsed
    }

    /// Outcome of a single `PUT rtc/offer` attempt, classified from the HTTP
    /// response status (if any arrived) and/or the transport-level failure
    /// (if the request never got a response).
    public enum OfferOutcome: Sendable, Equatable {
        case accepted
        case doorBusy
        case unauthorized
        case serverError(Int)
        case timedOut
        case network
    }

    /// A transport-level failure for an `rtc/offer` attempt that never
    /// produced an HTTP status (the request itself failed or expired).
    public enum OfferTransportError: Sendable, Equatable {
        case timedOut
        case other
    }

    /// Classifies a single `rtc/offer` attempt into an `OfferOutcome`.
    ///
    /// A non-nil `httpStatus` always takes precedence over `transportError`:
    /// if the door answered at all, that answer is authoritative even if the
    /// caller also recorded some transport-layer flag for the same attempt.
    ///
    /// - `200` -> `.accepted`: the door took the session.
    /// - `500` -> `.doorBusy`: per memory
    ///   `comelit-rtc-offer-500-means-door-busy`, this is the door refusing
    ///   because another session is still active or within its post-session
    ///   busy window -- NOT a generic server fault.
    /// - `401` / `403` -> `.unauthorized`: the bearer token is invalid or
    ///   expired.
    /// - any other 4xx/5xx -> `.serverError(status)`: an unrecognized error
    ///   status, kept distinct from `.doorBusy` so callers don't apply the
    ///   busy-cooldown logic to a status that doesn't mean that.
    /// - `httpStatus == nil` and `transportError == .timedOut` ->
    ///   `.timedOut`.
    /// - `httpStatus == nil` and `transportError == .other` (or `nil`) ->
    ///   `.network`.
    public static func classify(httpStatus: Int?, transportError: OfferTransportError?) -> OfferOutcome {
        if let httpStatus {
            switch httpStatus {
            case 200:
                return .accepted
            case 500:
                return .doorBusy
            case 401, 403:
                return .unauthorized
            default:
                return .serverError(httpStatus)
            }
        }
        switch transportError {
        case .timedOut:
            return .timedOut
        case .other, nil:
            return .network
        }
    }

    /// Whether a caller should retry immediately after this outcome.
    ///
    /// Returns `true` ONLY for `.network`. Specifically:
    /// - `.timedOut` is never retried: per memory
    ///   `comelit-rtc-offer-500-means-door-busy` and the design notes on
    ///   epic gateopener-6s8, the `PUT` may have succeeded server-side and
    ///   consumed the door's one session slot even though this process never
    ///   saw the response, so blindly retrying could either hit `.doorBusy`
    ///   against its own just-accepted session or, worse, race a second
    ///   session against the one it already started.
    /// - `.doorBusy` is never retried here: this is not a "try again now"
    ///   condition, it needs `waitBeforeOffer`'s cooldown, not a fast retry.
    /// - `.unauthorized` and `.serverError` are not transient network
    ///   failures, so a fast retry is not expected to help.
    /// - `.network` (the request never reached the door at all) is the one
    ///   case where an immediate retry has a real chance of succeeding.
    public static func shouldRetry(_ outcome: OfferOutcome) -> Bool {
        outcome == .network
    }

    /// A SHORT, human-readable message safe to show directly in a
    /// tooltip/label for a given `OfferOutcome`, used by
    /// `DoorVideoSession.start()` to map an `rtc/offer` failure to
    /// `DoorVideoSessionState.failed(message:)`.
    ///
    /// - `.doorBusy` -> "Door camera busy": the door refused because
    ///   another session is active or within its post-session cooldown (see
    ///   `cooldown`'s doc comment) -- distinct from a generic network
    ///   failure so a human sees the ACTUAL reason rather than assuming
    ///   their network is broken.
    /// - `.unauthorized` -> "Sign-in required": the bearer token was
    ///   rejected outright by this specific call, mirroring the wording
    ///   `DoorVideoSession.start()` already uses for
    ///   `TokenManagerError.notConfigured`.
    /// - `.timedOut` -> "Door camera not responding": the PUT never got a
    ///   response within the request timeout -- neither confirmed accepted
    ///   nor confirmed rejected, so this is deliberately worded differently
    ///   from both "busy" and "could not reach" (see `.network` below).
    /// - `.network` / `.serverError` -> "Could not reach door camera": kept
    ///   as the EXISTING wording (`DoorVideoSession.start()`'s current
    ///   catch-all message) for both, since a caller cannot tell a raw
    ///   transport failure apart from an unrecognized server error in any
    ///   way a human-facing message should distinguish.
    /// - `.accepted` -> `""`: `.accepted` is not a failure and this case
    ///   should never actually be shown to a human; an empty string is
    ///   returned (rather than a `fatalError`/`preconditionFailure`) so a
    ///   caller that mistakenly maps every outcome through this helper
    ///   (including the success path) fails soft/visibly-wrong rather than
    ///   crashing a live session.
    public static func failureMessage(for outcome: OfferOutcome) -> String {
        switch outcome {
        case .accepted:
            return ""
        case .doorBusy:
            return "Door camera busy"
        case .unauthorized:
            return "Sign-in required"
        case .timedOut:
            return "Door camera not responding"
        case .network, .serverError:
            return "Could not reach door camera"
        }
    }

    /// A SHORT machine-readable label for a given `OfferOutcome`, used to
    /// extend the existing `VideoDiagnosticsStage.offerAttempt` failure
    /// outcome string (e.g. today's `"500"` becomes `"500 door-busy"`,
    /// today's `"network-error"` stays distinguishable from a genuine
    /// timeout via `"timeout"`).
    ///
    /// Deliberately kept separate from `failureMessage(for:)` -- that one is
    /// prose meant for a human in a tooltip; this one is a short,
    /// grep-friendly diagnostic tag meant to sit next to an HTTP status
    /// number in a log line, per this bead's step 2.
    ///
    /// - `.accepted` -> `"accepted"` (not expected to appear in a FAILURE
    ///   outcome string, but defined for completeness/exhaustiveness rather
    ///   than crashing if ever misused).
    /// - `.doorBusy` -> `"door-busy"`.
    /// - `.unauthorized` -> `"unauthorized"`.
    /// - `.serverError` -> `"server-error"` (the numeric status itself is
    ///   already present alongside this label in the diag line; this label
    ///   only adds the classification word).
    /// - `.timedOut` -> `"timeout"`.
    /// - `.network` -> `"network-error"` (matches the existing diag string
    ///   used before this classification existed, so old and new logs read
    ///   consistently for this specific case).
    public static func diagLabel(for outcome: OfferOutcome) -> String {
        switch outcome {
        case .accepted:
            return "accepted"
        case .doorBusy:
            return "door-busy"
        case .unauthorized:
            return "unauthorized"
        case .serverError:
            return "server-error"
        case .timedOut:
            return "timeout"
        case .network:
            return "network-error"
        }
    }
}
