import Foundation

/// Pure policy deciding what a PINNED door video session does when a
/// session finishes (either the door's normal ~28-30s expiry or a
/// `.failed` state). Bounded by design: user ruling in `../comelit` bead
/// `comelit-ecw.11` is explicit that pinning must NOT hammer the door
/// forever, so this type always has a hard stop (`maxPinnedDuration`,
/// `maxConsecutiveFailures`) rather than renewing indefinitely.
///
/// The door's own "one `rtc/offer` session at a time" busy-cooldown (see
/// `DoorVideoBusyPolicy`) is explicitly NOT this policy's job: when this
/// type says `.renew(after:)`, the caller still goes through
/// `DoorVideoSessionRegistry`, which waits out that cooldown itself before
/// actually offering a new session. The `after` delay returned here is
/// purely the EXTRA backoff this policy wants on top of that (currently
/// only non-zero after a `.failed` outcome); it is not, and does not need
/// to be, the door-busy wait itself.
public struct DoorVideoPinPolicy: Sendable, Equatable {
    /// The whole pinned period's time budget. This is NOT reset by
    /// individual session renewals -- `pinnedElapsed`, as passed to
    /// `decide(...)`/`remaining(...)`, is expected to be the time since the
    /// pin itself started, so a pin that keeps renewing successfully still
    /// stops once this total is reached.
    public var maxPinnedDuration: TimeInterval

    /// How many CONSECUTIVE `.failed` session outcomes a pin tolerates
    /// before giving up. A single `.ended` (the door's normal expiry)
    /// resets this count in the caller's bookkeeping; this policy itself is
    /// stateless and only ever sees the count it's handed.
    public var maxConsecutiveFailures: Int

    /// Escalating extra delay to wait before renewing after a FAILED
    /// session, on top of whatever door-busy cooldown
    /// `DoorVideoSessionRegistry` already enforces. Not applied after a
    /// normal `.ended` outcome, where renewal is immediate (`after: 0`).
    ///
    /// Indexed by `consecutiveFailures - 1` (the 1st failure uses index 0,
    /// the 2nd index 1, etc); once `consecutiveFailures - 1` reaches or
    /// exceeds the array's last index, the LAST element is reused for every
    /// further failure rather than going out of bounds. An EMPTY array is
    /// treated as `[2]` (i.e. every failure backs off 2s) rather than
    /// crashing or backing off `0` -- there is no sensible reading of "no
    /// schedule at all" other than falling back to a single safe default.
    public var failureBackoffs: [TimeInterval]

    /// Convenience accessor for the schedule's first element, useful for
    /// callers that only care about a single representative backoff value
    /// (e.g. logging/diagnostics). Mirrors the empty-array fallback in
    /// `failureBackoffs`'s doc comment: `[].first` would be `nil`, so this
    /// returns `2` in that case instead.
    public var failureBackoff: TimeInterval {
        failureBackoffs.first ?? 2
    }

    /// Minimum extra delay enforced when a failed renewal's failure was
    /// specifically a "door busy" outcome (see `decide(...)`'s
    /// `failureWasDoorBusy` parameter). A door-busy failure means the door
    /// itself is still within its own post-session cooldown (see
    /// `DoorVideoBusyPolicy.cooldown`), so retrying sooner than this is
    /// pointless -- the door will just refuse again.
    public var doorBusyMinimumBackoff: TimeInterval = 10

    /// - Parameters:
    ///   - maxPinnedDuration: defaults to 300s (5 minutes). A non-positive
    ///     value is NOT treated as "unbounded" -- per the user ruling this
    ///     policy exists to enforce, unbounded pinning is explicitly
    ///     unwanted, so a non-positive cap means the cap is immediately
    ///     considered reached (any `pinnedElapsed >= 0` stops with
    ///     `.maxDuration`).
    ///   - maxConsecutiveFailures: defaults to 4. A value `<= 0` behaves as
    ///     `1`, i.e. the first failure already stops the pin -- there is no
    ///     sensible reading of "tolerate zero or fewer failures" other than
    ///     "stop on the first one".
    ///   - failureBackoffs: defaults to `[2, 5, 10]`. See `failureBackoffs`'s
    ///     doc comment for indexing/clamping/empty-array behavior.
    public init(
        maxPinnedDuration: TimeInterval = 300,
        maxConsecutiveFailures: Int = 4,
        failureBackoffs: [TimeInterval] = [2, 5, 10]
    ) {
        self.maxPinnedDuration = maxPinnedDuration
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.failureBackoffs = failureBackoffs
    }

    /// Compat initializer for callers/tests still passing a single
    /// `failureBackoff:` value -- equivalent to `failureBackoffs: [value]`,
    /// i.e. every consecutive failure uses the SAME backoff (no escalation).
    public init(
        maxPinnedDuration: TimeInterval = 300,
        maxConsecutiveFailures: Int = 4,
        failureBackoff: TimeInterval
    ) {
        self.init(
            maxPinnedDuration: maxPinnedDuration,
            maxConsecutiveFailures: maxConsecutiveFailures,
            failureBackoffs: [failureBackoff]
        )
    }

    /// Looks up the backoff to use for the given (1-based) consecutive
    /// failure count, per `failureBackoffs`'s indexing/clamping/empty-array
    /// rules.
    private func scheduledBackoff(forConsecutiveFailures consecutiveFailures: Int) -> TimeInterval {
        guard !failureBackoffs.isEmpty else { return 2 }
        let index = max(0, consecutiveFailures - 1)
        let clampedIndex = min(index, failureBackoffs.count - 1)
        return failureBackoffs[clampedIndex]
    }

    /// How a finished session ended, as classified by the caller.
    public enum SessionOutcome: Sendable, Equatable {
        /// The door's normal ~28-30s streaming window elapsed on its own.
        case ended
        /// The session entered any `.failed` state.
        case failed
    }

    /// What a pinned video session should do next.
    public enum Decision: Sendable, Equatable {
        /// Start a new session after waiting `after` seconds (on top of any
        /// door-busy cooldown `DoorVideoSessionRegistry` separately
        /// enforces).
        case renew(after: TimeInterval)
        /// Give up on the pin, for the given reason.
        case stop(StopReason)
    }

    /// Why a pinned session stopped instead of renewing.
    public enum StopReason: Sendable, Equatable {
        /// The video wasn't pinned in the first place, so there is nothing
        /// to renew.
        case notPinned
        /// The pin's total time budget (`maxPinnedDuration`) was reached.
        case maxDuration
        /// Too many consecutive `.failed` outcomes (`maxConsecutiveFailures`).
        case tooManyFailures
    }

    /// Decides what a pinned door video session should do when a session
    /// finishes. Rules are evaluated in this exact order (each rule's guard
    /// only applies once the ones above it have not already produced a
    /// decision):
    ///
    /// 1. `isPinned == false` -> `.stop(.notPinned)`: nothing to renew.
    /// 2. `pinnedElapsed >= maxPinnedDuration` -> `.stop(.maxDuration)`: the
    ///    pin's whole time budget is spent. Checked before the failure-count
    ///    rule, so a session that both hits the duration cap AND is this
    ///    pin's 3rd+ consecutive failure reports `.maxDuration`, not
    ///    `.tooManyFailures` -- duration is the more informative reason to
    ///    show a human in that case, since it would have stopped there
    ///    regardless of the failures.
    /// 3. `outcome == .failed` and `consecutiveFailures >=
    ///    maxConsecutiveFailures` -> `.stop(.tooManyFailures)`.
    ///    `consecutiveFailures` is the count INCLUDING the failure currently
    ///    being decided (i.e. the caller increments before calling this).
    /// 4. `outcome == .failed` (and none of the above fired) ->
    ///    `.renew(after:)` using `failureBackoffs`' schedule for the current
    ///    `consecutiveFailures` count; if `failureWasDoorBusy` is `true`,
    ///    that scheduled value is raised to
    ///    `max(scheduleValue, doorBusyMinimumBackoff)` -- a door-busy failure
    ///    still counts as a failure and does not change rule order, it only
    ///    ever raises (never lowers) the wait.
    /// 5. `outcome == .ended` (and none of the above fired) ->
    ///    `.renew(after: 0)`: the door's normal expiry needs no extra delay
    ///    beyond whatever door-busy cooldown the caller separately waits
    ///    out.
    ///
    /// - Parameters:
    ///   - isPinned: whether the video is currently pinned. `false` short-
    ///     circuits to `.stop(.notPinned)` regardless of every other
    ///     parameter.
    ///   - outcome: how the just-finished session ended.
    ///   - pinnedElapsed: time elapsed since the pin itself started (not
    ///     since the last renewal). A negative value is treated as `0`,
    ///     since a pin cannot have negative elapsed time; this only exists
    ///     to make the function total against a caller's clock-skew bug
    ///     rather than producing a nonsensical decision.
    ///   - consecutiveFailures: the number of consecutive `.failed`
    ///     outcomes so far, INCLUDING the one being decided right now.
    ///   - failureWasDoorBusy: whether the failure being decided (only
    ///     meaningful when `outcome == .failed`) was specifically the door
    ///     reporting itself busy (see `DoorVideoBusyPolicy.failureMessage(for:
    ///     .doorBusy)`). Defaults to `false` so existing callers/tests that
    ///     never pass it keep their current (schedule-only) behavior.
    public func decide(
        isPinned: Bool,
        outcome: SessionOutcome,
        pinnedElapsed: TimeInterval,
        consecutiveFailures: Int,
        failureWasDoorBusy: Bool = false
    ) -> Decision {
        guard isPinned else {
            return .stop(.notPinned)
        }

        let clampedElapsed = max(0, pinnedElapsed)
        guard clampedElapsed < maxPinnedDuration else {
            return .stop(.maxDuration)
        }

        let failureLimit = max(1, maxConsecutiveFailures)
        if outcome == .failed, consecutiveFailures >= failureLimit {
            return .stop(.tooManyFailures)
        }

        switch outcome {
        case .failed:
            let scheduled = scheduledBackoff(forConsecutiveFailures: consecutiveFailures)
            let delay = failureWasDoorBusy ? max(scheduled, doorBusyMinimumBackoff) : scheduled
            return .renew(after: delay)
        case .ended:
            return .renew(after: 0)
        }
    }

    /// Time remaining in the pin's total budget, clamped at `0`.
    ///
    /// A negative `pinnedElapsed` is treated as `0` elapsed (i.e. the full
    /// `maxPinnedDuration` remains), matching `decide(...)`'s handling of
    /// the same defensive case.
    public func remaining(pinnedElapsed: TimeInterval) -> TimeInterval {
        let clampedElapsed = max(0, pinnedElapsed)
        return max(0, maxPinnedDuration - clampedElapsed)
    }

    /// The hard cap `stopMessage(_:lastFailure:)` guarantees for every
    /// message it returns, matching this bead's DONE-CRITERIA.
    private static let stopMessageMaxLength = 40

    /// A SHORT, human-readable message safe to show directly in a label for
    /// a given `StopReason`, or `nil` if that reason should show no message
    /// at all. Guaranteed to be at most `stopMessageMaxLength` (40)
    /// characters.
    ///
    /// - `.maxDuration` -> `"Stream ended - tap to resume"`.
    /// - `.tooManyFailures` with a non-empty `lastFailure` -> `"Unpinned -
    ///   <lastFailure>"`, truncating `lastFailure` (appending "…") as needed
    ///   to keep the whole message at or under the 40-character cap.
    /// - `.tooManyFailures` with `lastFailure == nil` or empty -> the
    ///   existing `"Camera unavailable - unpinned"`.
    /// - `.notPinned` -> `nil`: there is no pin to explain anything about.
    ///
    /// - Parameter lastFailure: the most recent `.failed(message:)` text
    ///   seen on this pin, if any. Defaults to `nil` so existing one-argument
    ///   call sites keep compiling and behaving exactly as before (the
    ///   existing "Camera unavailable - unpinned" wording).
    public static func stopMessage(_ reason: StopReason, lastFailure: String? = nil) -> String? {
        switch reason {
        case .maxDuration:
            return "Stream ended - tap to resume"
        case .tooManyFailures:
            guard let lastFailure, !lastFailure.isEmpty else {
                return "Camera unavailable - unpinned"
            }
            let prefix = "Unpinned - "
            let budget = stopMessageMaxLength - prefix.count
            guard budget > 0 else {
                return "Camera unavailable - unpinned"
            }
            if lastFailure.count <= budget {
                return prefix + lastFailure
            }
            let truncationBudget = budget - 1 // room for the "…" suffix
            guard truncationBudget > 0 else {
                return "Camera unavailable - unpinned"
            }
            let truncated = String(lastFailure.prefix(truncationBudget)) + "…"
            return prefix + truncated
        case .notPinned:
            return nil
        }
    }
}
