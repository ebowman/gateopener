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

    /// Extra delay to wait before renewing after a FAILED session, on top
    /// of whatever door-busy cooldown `DoorVideoSessionRegistry` already
    /// enforces. Not applied after a normal `.ended` outcome, where renewal
    /// is immediate (`after: 0`).
    public var failureBackoff: TimeInterval

    /// - Parameters:
    ///   - maxPinnedDuration: defaults to 300s (5 minutes). A non-positive
    ///     value is NOT treated as "unbounded" -- per the user ruling this
    ///     policy exists to enforce, unbounded pinning is explicitly
    ///     unwanted, so a non-positive cap means the cap is immediately
    ///     considered reached (any `pinnedElapsed >= 0` stops with
    ///     `.maxDuration`).
    ///   - maxConsecutiveFailures: defaults to 3. A value `<= 0` behaves as
    ///     `1`, i.e. the first failure already stops the pin -- there is no
    ///     sensible reading of "tolerate zero or fewer failures" other than
    ///     "stop on the first one".
    ///   - failureBackoff: defaults to 2s.
    public init(
        maxPinnedDuration: TimeInterval = 300,
        maxConsecutiveFailures: Int = 3,
        failureBackoff: TimeInterval = 2
    ) {
        self.maxPinnedDuration = maxPinnedDuration
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.failureBackoff = failureBackoff
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
    ///    `.renew(after: failureBackoff)`.
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
    public func decide(
        isPinned: Bool,
        outcome: SessionOutcome,
        pinnedElapsed: TimeInterval,
        consecutiveFailures: Int
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
            return .renew(after: failureBackoff)
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

    /// A SHORT, human-readable message safe to show directly in a label for
    /// a given `StopReason`, or `nil` if that reason should show no message
    /// at all.
    ///
    /// - `.maxDuration` -> `"Stream ended - tap to resume"`.
    /// - `.tooManyFailures` -> `"Camera unavailable - unpinned"`.
    /// - `.notPinned` -> `nil`: there is no pin to explain anything about.
    public static func stopMessage(_ reason: StopReason) -> String? {
        switch reason {
        case .maxDuration:
            return "Stream ended - tap to resume"
        case .tooManyFailures:
            return "Camera unavailable - unpinned"
        case .notPinned:
            return nil
        }
    }
}
