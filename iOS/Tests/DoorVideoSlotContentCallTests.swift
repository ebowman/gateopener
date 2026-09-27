import Foundation
import Testing
@testable import GateOpener

/// Tests for bead gateopener-1pm.5's additions to
/// `DoorVideoSlotContent.content(...)`: the `isCall`/`pendingCall` inputs and
/// the `.connectingCall(secondsRemaining:)` overlay they drive. Every branch
/// that changes output from the pre-existing (bead gateopener-41m.11/.15)
/// behavior gets a dedicated test here, mirroring
/// `DoorVideoSlotContentTests`' MUTATION CHECK style — that file's own tests
/// are untouched (they all omit `isCall`/`pendingCall`, which default to
/// `false`, so their expectations are unaffected by this bead).
@MainActor
struct DoorVideoSlotContentCallTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A `.call` session connecting with no cooldown reads "Connecting
    /// call…" (`secondsRemaining == nil`), not the plain `.none` overlay a
    /// `.view` session would get.
    ///
    /// MUTATION CHECK: dropping the `showsConnectingCall` branch (or its
    /// `isCall` half) would make this fall through to `.session(overlay:
    /// .none)` instead.
    @Test func callConnectingWithNoCooldownMapsToConnectingCallWithNilSeconds() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: nil,
            isCall: true,
            now: now
        )
        #expect(result == .session(overlay: .connectingCall(secondsRemaining: nil)))
    }

    /// `pendingCall` alone (before `activeMode` has actually flipped to
    /// `.call`, e.g. the instant a view-to-call switch is requested) also
    /// drives `.connectingCall` — `isCall`/`pendingCall` are combined with
    /// `||`, not `&&`.
    ///
    /// MUTATION CHECK: changing the `isCall || pendingCall` combination to
    /// `&&` would make this (isCall == false) fall through to `.none`.
    @Test func pendingCallAloneMapsToConnectingCallWithNilSeconds() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: nil,
            pendingCall: true,
            now: now
        )
        #expect(result == .session(overlay: .connectingCall(secondsRemaining: nil)))
    }

    /// A `.call` session connecting with a FUTURE cooldown reads "Connecting
    /// call - Ns" — i.e. `.connectingCall(secondsRemaining:)`, not the plain
    /// `.busyRetry` text a `.view` session's same wait would show.
    ///
    /// MUTATION CHECK: checking `showsConnectingCall` AFTER already
    /// returning `.busyRetry` (rather than before) would make this return
    /// `.busyRetry(secondsRemaining: 5)` instead.
    @Test func callConnectingWithFutureCooldownMapsToConnectingCallWithSeconds() {
        let deadline = now.addingTimeInterval(5)
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: deadline,
            isCall: true,
            now: now
        )
        #expect(result == .session(overlay: .connectingCall(secondsRemaining: 5)))
    }

    /// A `.view` session (neither `isCall` nor `pendingCall`) with the SAME
    /// future cooldown must still show the plain `.busyRetry` text — a
    /// regression guard that this bead's new branch is scoped to
    /// `isCall`/`pendingCall` only.
    @Test func viewConnectingWithFutureCooldownStillMapsToBusyRetry() {
        let deadline = now.addingTimeInterval(5)
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: deadline,
            now: now
        )
        #expect(result == .session(overlay: .busyRetry(secondsRemaining: 5)))
    }

    /// `.connectingCall` takes priority over `.reconnecting` — a PINNED
    /// call renewal (`isPinned && isRenewal`) still reads "Connecting
    /// call…", never the generic "Reconnecting…" text.
    ///
    /// MUTATION CHECK: checking `showsReconnecting` before
    /// `showsConnectingCall` would make this return `.reconnecting` instead.
    @Test func callTakesPriorityOverReconnectingWhenBothApply() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .connecting,
            lastTerminal: .none,
            cooldownUntil: nil,
            isPinned: true,
            isRenewal: true,
            isCall: true,
            now: now
        )
        #expect(result == .session(overlay: .connectingCall(secondsRemaining: nil)))
    }

    /// A `.call` session's `.idle` state (mirroring `.connecting`
    /// throughout this mapping) also maps to `.connectingCall`.
    @Test func callIdleMapsToConnectingCallWithNilSeconds() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .idle,
            lastTerminal: .none,
            cooldownUntil: nil,
            isCall: true,
            now: now
        )
        #expect(result == .session(overlay: .connectingCall(secondsRemaining: nil)))
    }

    /// A `.call` session's FAILURE BACKOFF (a pinned call retrying after a
    /// failed attempt) also reads "Connecting call…", covering
    /// `DoorVideoView`'s own "Camera unavailable" text the same way a
    /// pinned view's backoff reads "Reconnecting…".
    @Test func callFailedDuringBackoffMapsToConnectingCallWithNilSeconds() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .failed("boom"),
            lastTerminal: .none,
            cooldownUntil: nil,
            isPinned: true,
            isRenewal: true,
            isCall: true,
            now: now
        )
        #expect(result == .session(overlay: .connectingCall(secondsRemaining: nil)))
    }

    /// Streaming always wins regardless of `isCall`/`pendingCall` — once
    /// frames are flowing there is nothing left to "connect".
    ///
    /// MUTATION CHECK: checking `showsConnectingCall` before the
    /// `sessionState` switch's `.streaming` case (rather than only inside
    /// the `.idle`/`.connecting`/`.failed` branches) would make this
    /// incorrectly return `.connectingCall` instead.
    @Test func callStreamingMapsToNoOverlayRegardlessOfCallFlags() {
        let result = DoorVideoSlotContent.content(
            hasVisibleSession: true,
            sessionState: .streaming,
            lastTerminal: .none,
            cooldownUntil: nil,
            isCall: true,
            pendingCall: true,
            now: now
        )
        #expect(result == .session(overlay: .none))
    }
}
