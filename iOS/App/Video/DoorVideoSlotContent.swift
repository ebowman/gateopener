import Foundation

/// What `MainView`'s permanent video slot (bead gateopener-41m.11) should
/// show, derived purely from `DoorVideoCoordinator`'s observable state. A
/// pure, static mapping — no `DoorVideoCoordinator`/`MainView` dependency —
/// so every branch is unit-testable without constructing a coordinator, a
/// session, or a view.
enum DoorVideoSlotContent: Equatable {
    /// A visible session exists — `.connecting` (with or without an active
    /// door-busy cooldown) OR `.streaming`. In EVERY sub-case the slot mounts
    /// the SAME `DoorVideoView` at a stable structural position (bead
    /// gateopener-41m.11 FIX PASS, superseding this bead's earlier `.live`/
    /// `.connecting`/`.busyRetry` split): `DoorVideoView` keeps the
    /// `WKWebView` at opacity 1 and draws its own "Connecting…"/"Camera
    /// unavailable" overlay on top for `.idle`/`.connecting`/`.failed`
    /// (see `DoorVideoView.overlay(for:)`, bead gateopener-672.30) — the
    /// hard rule that a WKWebView hosting inline media must never be
    /// removed from (or hidden within) the hierarchy while a session is
    /// live extends to "never absent from the hierarchy while a visible
    /// session exists at all", not just while it is `.streaming`. iOS
    /// pauses/refuses inline media playback in a web view that isn't
    /// actually in a window, which is strictly worse than opacity 0.
    ///
    /// `overlay` layers ADDITIONAL chrome on top of `DoorVideoView` from the
    /// caller's side (`MainView`), never inside `DoorVideoView` itself:
    /// `.none` when `DoorVideoView`'s own overlay already says everything
    /// that needs saying (this covers both plain connecting and streaming —
    /// `DoorVideoView.overlay(for:)` shows nothing while `.streaming`), or
    /// `.busyRetry(secondsRemaining:)` while a door-busy cooldown is
    /// counting down, which must fully obscure `DoorVideoView`'s own
    /// "Connecting…" text so the two never show at once.
    case session(overlay: SessionOverlay)
    /// No visible session, and the last one either never existed or ended
    /// normally (`lastTerminal == .none` or `.ended`): the neutral
    /// "Tap to view door" placeholder — UNLESS `pinStopMessage` is set (bead
    /// gateopener-41m.15 STEP 5), in which case that message is shown
    /// instead, still with the tap-to-view affordance (tapping resumes
    /// UNPINNED via `viewDoor()`, which clears the message).
    case tapToView(message: String?)
    /// No visible session, and the last one failed: the "Retry" placeholder
    /// carrying the REAL failure message (never a generic string) for
    /// display.
    case failed(String)

    /// Additional chrome `MainView` layers on top of the mounted
    /// `DoorVideoView` while a visible session exists. See `.session`'s doc
    /// comment above for why this is layered rather than a separate
    /// top-level case.
    enum SessionOverlay: Equatable {
        /// Nothing extra: `DoorVideoView`'s own overlay (connecting spinner,
        /// failed message, or nothing while streaming) is sufficient.
        case none
        /// A door-busy cooldown is counting down: show "Door camera busy —
        /// retrying in Ns", re-evaluated every second by a `TimelineView`,
        /// drawn opaquely on top so `DoorVideoView`'s own "Connecting…" text
        /// is fully covered (never both visible at once). Takes priority
        /// over `.reconnecting` whenever both would otherwise apply (bead
        /// gateopener-41m.15 STEP 3: "Door camera busy" is more specific/
        /// actionable than the generic "Reconnecting…").
        case busyRetry(secondsRemaining: Int)
        /// A PINNED renewal is between sessions (bead gateopener-41m.15 STEP
        /// 4): the mounted session is not yet `.streaming` (still
        /// `.idle`/`.connecting`, or `.failed` during the failure backoff)
        /// AND this is not the pin's first session — i.e. `DoorVideoView`'s
        /// own "Connecting…"/"Camera unavailable" text underneath must be
        /// fully covered by an opaque scrim reading "Reconnecting…" instead,
        /// so the operator is never told video is continuous when the door
        /// actually enforces a ~15s gap between sessions.
        case reconnecting
    }

    /// Pure derivation of what the slot should show.
    ///
    /// - Parameters:
    ///   - hasVisibleSession: `DoorVideoCoordinator.isPanelVisible` — `true`
    ///     while the current session is `.connecting` (including while
    ///     waiting out a door-busy cooldown) or `.streaming`.
    ///   - sessionState: `DoorVideoCoordinator.sessionState`, consulted only
    ///     while `hasVisibleSession` is `true` to decide the `SessionOverlay`
    ///     — a session's OWN `.idle`/`.ended`/`.failed` states never reach
    ///     here while `hasVisibleSession` is `true` (those all map
    ///     `isPanelVisible` to `false` in
    ///     `DoorVideoCoordinator.handleStateChange`), but the parameter is
    ///     still exhaustively switched over defensively rather than force-
    ///     unwrapping an assumption.
    ///   - lastTerminal: `DoorVideoCoordinator.lastTerminal` — how the most
    ///     recent session (if any) finished, consulted only when there is no
    ///     visible session.
    ///   - cooldownUntil: `DoorVideoCoordinator.cooldownUntil` — non-nil
    ///     while the current (connecting) session is waiting out a
    ///     door-busy cooldown.
    ///   - isPinned: `DoorVideoCoordinator.isPinned` (bead gateopener-41m.15
    ///     STEP 3/4) — whether the video is currently pinned. Combined with
    ///     `isRenewal` to decide whether a not-yet-streaming/failed-backoff
    ///     session should show "Reconnecting…" instead of `DoorVideoView`'s
    ///     own "Connecting…"/"Camera unavailable" text.
    ///   - isRenewal: `DoorVideoCoordinator.isRenewing` (bead
    ///     gateopener-41m.15 STEP 4) — `true` when the CURRENTLY mounted
    ///     session is a pinned RENEWAL (not the pin's first session).
    ///     `.reconnecting` only ever applies when this is `true`: the pin's
    ///     first session still shows the ordinary "Connecting…" text, since
    ///     there is nothing to "reconnect" to yet.
    ///   - pinStopMessage: `DoorVideoCoordinator.pinStopMessage` (bead
    ///     gateopener-41m.15 STEP 5) — non-nil when the pin most recently
    ///     auto-stopped itself; consulted only when there is no visible
    ///     session, taking priority over the plain "Tap to view door" text
    ///     but leaving the tap-to-view affordance/behavior unchanged.
    ///   - now: Injected (rather than read via `Date()` internally) so this
    ///     stays a pure function callers can unit-test deterministically,
    ///     and so a `TimelineView`'s per-second tick can re-invoke it with a
    ///     fresh `now` without the function itself depending on the clock.
    ///
    /// MUTATION CHECK: swapping the `hasVisibleSession` guard's true/false
    /// branches, dropping the `cooldownUntil > now` comparison (e.g. always
    /// treating any non-nil `cooldownUntil` as in the future), or collapsing
    /// `.ended`/`.failed` in the `lastTerminal` switch onto the same case,
    /// would each make at least one of `DoorVideoSlotContentTests`'
    /// branch-specific assertions fail — every branch below has a dedicated
    /// test asserting a distinct result.
    ///
    /// MUTATION CHECK (gateopener-41m.11 FIX PASS): there must be NO output
    /// meaning "connecting, render a standalone spinner without the web
    /// view" while `hasVisibleSession` is `true` — every `hasVisibleSession
    /// == true` branch below returns `.session(overlay:)`, never `.tapToView`
    /// or `.failed`. Reintroducing a separate "connecting, no web view" case
    /// would silently regress the WKWebView-hosting-view-must-stay-mounted
    /// rule from commit 8797114 (gateopener-672.30) without any test here
    /// catching it structurally — `DoorVideoSlotContentTests` guards this by
    /// asserting the visible-session branches all decode to `.session`.
    ///
    /// MUTATION CHECK (gateopener-41m.15): `.failed` while `hasVisibleSession`
    /// is `true` is now a REAL, reachable path (a pinned session's failure
    /// backoff keeps the failed session mounted — see
    /// `DoorVideoCoordinator.handlePinnableTermination`), not merely
    /// defensive — dropping the `isPinned && isRenewal` check on that branch
    /// would either wrongly show `.reconnecting` for an unpinned failure or
    /// wrongly fall back to `DoorVideoView`'s own "Camera unavailable" text
    /// during a pinned renewal's backoff.
    static func content(
        hasVisibleSession: Bool,
        sessionState: DoorVideoSession.State,
        lastTerminal: DoorVideoCoordinator.LastTerminal,
        cooldownUntil: Date?,
        isPinned: Bool = false,
        isRenewal: Bool = false,
        pinStopMessage: String? = nil,
        now: Date
    ) -> DoorVideoSlotContent {
        guard hasVisibleSession else {
            if let pinStopMessage {
                return .tapToView(message: pinStopMessage)
            }
            switch lastTerminal {
            case .none, .ended:
                return .tapToView(message: nil)
            case .failed(let message):
                return .failed(message)
            }
        }

        let showsReconnecting = isPinned && isRenewal

        switch sessionState {
        case .streaming:
            return .session(overlay: .none)
        case .idle, .connecting:
            if let cooldownUntil, cooldownUntil > now {
                // `ceil` so "14.2s remaining" reads as "15s" (rounding down
                // would show a "0s" flash right before the deadline, and
                // undercounts how long the operator actually has left to
                // wait); `max(1, ...)` guards the same instant where
                // `cooldownUntil` is a hair in the future due to floating-
                // point/clock granularity but the ceiling of the difference
                // would otherwise round to 0.
                //
                // Busy-retry takes priority over `.reconnecting` (see
                // `SessionOverlay.busyRetry`'s doc comment) — checked first
                // regardless of `showsReconnecting`.
                let remaining = max(1, Int(ceil(cooldownUntil.timeIntervalSince(now))))
                return .session(overlay: .busyRetry(secondsRemaining: remaining))
            }
            return .session(overlay: showsReconnecting ? .reconnecting : .none)
        case .failed:
            // A pinned session's failure backoff (bead gateopener-41m.14)
            // keeps the failed session mounted with `hasVisibleSession ==
            // true` for up to `pinPolicy.failureBackoff` seconds — a REAL,
            // reachable path, not merely defensive. During that window the
            // scrim must read "Reconnecting…", covering `DoorVideoView`'s
            // own "Camera unavailable" text, so the operator is not told the
            // pin has failed when it is about to retry.
            return .session(overlay: showsReconnecting ? .reconnecting : .none)
        case .ended:
            // Defensive only — `DoorVideoCoordinator.handleStateChange` sets
            // `isPanelVisible = false` for `.ended` (a pinned `.ended` is
            // renewed synchronously without ever setting `isPanelVisible =
            // false` in between — see `handlePinnableTermination`), so
            // `hasVisibleSession` should never be `true` here in practice.
            // Falls back to a plain mounted session with no extra overlay
            // (matching `DoorVideoView.overlay(for:)`'s own handling of this
            // state) rather than dropping the web view or crashing if that
            // invariant is ever violated.
            return .session(overlay: .none)
        }
    }
}
