import Foundation
import Testing
@testable import GateOpener

/// Tests for `DoorVideoSlotContent.content(...)` (bead gateopener-41m.11):
/// the pure mapping from `DoorVideoCoordinator`'s observable state to what
/// `MainView`'s permanent video slot shows. Every branch gets a dedicated
/// test asserting a distinct result, per this type's own MUTATION CHECK doc
/// comment.
@MainActor
struct DoorVideoSlotContentTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - No visible session

    /// No session has ever run (`lastTerminal == .none`): the neutral
    /// "Tap to view door" placeholder.
    ///
    /// MUTATION CHECK: changing the `.none` branch inside the
    /// `!hasVisibleSession` guard to return anything but `.tapToView` fails
    /// this assertion.
    @Test func noSessionEverAndNoneTerminalMapsToTapToView() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: false,
            sessionState: .idle,
            lastTerminal: .none,
            cooldownUntil: nil,
            now: now
        )
        #expect(result == .tapToView)
    }

    /// The last session ended normally (`lastTerminal == .ended`): still the
    /// neutral "Tap to view door" placeholder, not a "failed" one.
    ///
    /// MUTATION CHECK: collapsing `.ended` onto the `.failed` branch (or
    /// mapping it to some other case) fails this assertion.
    @Test func endedTerminalMapsToTapToView() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: false,
            sessionState: .idle,
            lastTerminal: .ended,
            cooldownUntil: nil,
            now: now
        )
        #expect(result == .tapToView)
    }

    /// The last session failed: `.failed(message)`, carrying the REAL
    /// message through unchanged.
    ///
    /// MUTATION CHECK: mapping `.failed` onto `.tapToView` (dropping the
    /// message), or hardcoding a different message, fails this assertion.
    @Test func failedTerminalMapsToFailedWithMessage() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: false,
            sessionState: .idle,
            lastTerminal: .failed("Door camera busy"),
            cooldownUntil: nil,
            now: now
        )
        #expect(result == .failed("Door camera busy"))
        #expect(result != .failed("No camera"))
    }

    // MARK: - Visible session: streaming

    /// A visible session in `.streaming` maps to `.session(overlay: .none)`
    /// — `DoorVideoView`'s own overlay mapping already shows nothing while
    /// streaming, so no additional overlay is layered on top.
    ///
    /// MUTATION CHECK: changing the `.streaming` branch to return anything
    /// but `.session(overlay: .none)` fails this assertion.
    @Test func visibleStreamingSessionMapsToSessionWithNoOverlay() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .streaming,
            lastTerminal: .none,
            cooldownUntil: nil,
            now: now
        )
        #expect(result == .session(overlay: .none))
    }

    // MARK: - Visible session: connecting (no cooldown, or an elapsed one)

    /// A visible, connecting session with no cooldown in play maps to
    /// `.session(overlay: .none)` — the mounted `DoorVideoView` draws its
    /// own "Connecting…" overlay; `MainView` layers nothing extra on top.
    ///
    /// MUTATION CHECK (gateopener-41m.11 FIX PASS, supersedes this bead's
    /// original `.connecting(String)` case): a visible, connecting session
    /// must map to the SAME `.session` case that streaming maps to — NOT a
    /// separate case meaning "render a standalone spinner without the web
    /// view". Regressing to a distinct non-`.session` case here would
    /// silently reintroduce the bug from commit 8797114 (gateopener-672.30)
    /// where the WKWebView-hosting view is absent from the hierarchy while
    /// `.connecting`, which is strictly worse for inline media playback than
    /// opacity 0.
    @Test func connectingWithNoCooldownMapsToSessionWithNoOverlay() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: nil,
            now: now
        )
        #expect(result == .session(overlay: .none))
        if case .session = result {
            // Web view is mounted — see MUTATION CHECK above.
        } else {
            Issue.record("Expected .session (web view mounted), got \(result)")
        }
    }

    /// A visible, connecting session whose `cooldownUntil` is already in the
    /// PAST (edge case explicitly called out in this bead's STEPS) must map
    /// to `.session(overlay: .none)`, not `.session(overlay: .busyRetry)` —
    /// a stale/expired cooldown deadline is indistinguishable from "no
    /// cooldown at all" to the operator.
    ///
    /// MUTATION CHECK: dropping the `cooldownUntil > now` comparison (i.e.
    /// treating ANY non-nil `cooldownUntil` as still active) makes this
    /// return a `.busyRetry` overlay instead, failing the assertion.
    @Test func connectingWithCooldownInThePastMapsToSessionWithNoOverlay() {
        let pastDeadline = now.addingTimeInterval(-5)
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: pastDeadline,
            now: now
        )
        #expect(result == .session(overlay: .none))
    }

    /// `.idle` (a session that hasn't even called `start()` yet) is treated
    /// identically to `.connecting` while visible — mirrors
    /// `DoorVideoView.overlay(for:)`'s existing `.idle`/`.connecting`
    /// pairing, and MUST still mount the web view (the `.session` case).
    ///
    /// MUTATION CHECK: routing `.idle` to a different top-level case than
    /// `.connecting` (e.g. `.tapToView`) fails this assertion.
    @Test func visibleIdleSessionMapsToSessionWithNoOverlay() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .idle,
            lastTerminal: .none,
            cooldownUntil: nil,
            now: now
        )
        #expect(result == .session(overlay: .none))
    }

    // MARK: - Visible session: busy-retry cooldown

    /// A visible, connecting session with `cooldownUntil` in the future maps
    /// to `.session(overlay: .busyRetry(secondsRemaining:))` — the web view
    /// stays mounted (`.session`), with the countdown layered as an
    /// additional overlay — seconds rounded UP (`ceil`): 14.2s remaining
    /// must show "15", not "14" — undercounting would let the label hit
    /// "0s" a moment before the door is actually available again.
    ///
    /// MUTATION CHECK (gateopener-41m.11 FIX PASS): this must be the SAME
    /// `.session` case as plain connecting/streaming, just with a non-`.none`
    /// overlay — a session waiting out a door-busy cooldown is still a
    /// visible session and the web view must stay mounted throughout the
    /// wait, never dropped to a standalone busy-retry view. Also:
    /// `Int(...)` (truncating/floor) instead of `ceil` would make the
    /// countdown compute 14 instead of 15, failing the assertion.
    @Test func busyRetryMapsToSessionWithBusyRetryOverlayAndRoundsUpFractionalRemaining() {
        let deadline = now.addingTimeInterval(14.2)
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: deadline,
            now: now
        )
        #expect(result == .session(overlay: .busyRetry(secondsRemaining: 15)))
    }

    /// An exact whole-second remaining value (10.0s) must show exactly
    /// "10", not "11" — `ceil` of an exact integer must not round up an
    /// extra second.
    ///
    /// MUTATION CHECK: adding a stray `+ 1` (or using `floor` plus an
    /// unconditional `+ 1`) after the `ceil` would make this compute 11
    /// instead of 10, failing the assertion.
    @Test func busyRetrySecondsExactWholeSecondIsNotRoundedUpFurther() {
        let deadline = now.addingTimeInterval(10.0)
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: deadline,
            now: now
        )
        #expect(result == .session(overlay: .busyRetry(secondsRemaining: 10)))
    }

    /// A cooldown deadline a hair (a fraction of a second) in the future
    /// must still show a minimum of "1", never "0" — the slot must never
    /// flash a "retrying in 0s" label right before the deadline elapses.
    ///
    /// MUTATION CHECK: removing the `max(1, ...)` floor would let this
    /// compute 0 (since `ceil(0.05) == 1` already saves this specific
    /// input, so the real regression this guards is a hypothetical
    /// zero-or-negative `ceil` result from clock-granularity edge cases);
    /// the test still locks in the minimum-1 contract explicitly so a
    /// future refactor of the rounding logic cannot silently drop it.
    @Test func busyRetrySecondsNeverShowsZero() {
        let deadline = now.addingTimeInterval(0.05)
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: deadline,
            now: now
        )
        guard case .session(.busyRetry(let secondsRemaining)) = result else {
            Issue.record("Expected .session(overlay: .busyRetry), got \(result)")
            return
        }
        #expect(secondsRemaining >= 1)
    }
}
