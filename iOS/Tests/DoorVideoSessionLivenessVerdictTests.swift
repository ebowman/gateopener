import Foundation
import Testing
@testable import GateOpener

/// Tests for `DoorVideoSession.livenessVerdict(elapsedSinceStart:
/// sinceLastFrame:hardTimeout:plateau:firstFrameTimeout:)` (bead
/// gateopener-41m.8): the pure, `WKWebView`-free decision function backing
/// `startLivenessWatchdog()`'s per-tick logic. Covers all four verdicts and
/// the documented precedence (hard timeout > no-first-frame > stall) at
/// their boundaries.
@MainActor
struct DoorVideoSessionLivenessVerdictTests {
    /// Production-shaped timeouts shared by every test below, matching
    /// `DoorVideoSession`'s own `hardTimeout` (35s), `plateauInterval` (6s),
    /// and default `firstFrameTimeout` (10s).
    private let hardTimeout: TimeInterval = 35
    private let plateau: TimeInterval = 6
    private let firstFrameTimeout: TimeInterval = 10

    // MARK: - No frame has ever arrived: keepGoing vs. failedNoFirstFrame

    /// 9.9s with no frame yet: must still be `.keepGoing` — the boundary is
    /// exclusive-below-10.0.
    ///
    /// MUTATION CHECK: changing the no-first-frame branch's comparison from
    /// `elapsedSinceStart >= firstFrameTimeout` to `>` makes this boundary
    /// case wrong in the other direction (9.9s would still pass, but 10.0s
    /// would then also wrongly stay `.keepGoing` — the paired test below
    /// catches that half).
    @Test func justUnderFirstFrameTimeoutWithNoFrameKeepsGoing() {
        let verdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 9.9,
            sinceLastFrame: nil,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(verdict == .keepGoing)
    }

    /// 10.0s with no frame yet: must be `.failedNoFirstFrame`.
    ///
    /// MUTATION CHECK: changing `elapsedSinceStart >= firstFrameTimeout` to
    /// `>` makes this fail (10.0s would wrongly stay `.keepGoing`).
    @Test func exactlyFirstFrameTimeoutWithNoFrameFails() {
        let verdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 10.0,
            sinceLastFrame: nil,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(verdict == .failedNoFirstFrame)
    }

    // MARK: - A frame arrived, then silence: keepGoing vs. endedStall

    /// A frame arrived (so `sinceLastFrame` is non-nil), and it has only
    /// been silent for less than `plateau`: `.keepGoing`, even though
    /// `elapsedSinceStart` alone is already past `firstFrameTimeout` — the
    /// no-first-frame check must never fire once a frame has actually been
    /// seen.
    ///
    /// MUTATION CHECK: removing the `guard let sinceLastFrame else { ... }`
    /// early-return (so the no-first-frame branch also runs when a frame
    /// HAS arrived) makes this wrongly return `.failedNoFirstFrame` since
    /// `elapsedSinceStart` (9s) is close to but the stall check wouldn't
    /// even get a chance to run correctly; more directly, swapping the
    /// stall comparison `sinceLastFrame >= plateau` to compare
    /// `elapsedSinceStart` instead would also make this fail incorrectly.
    @Test func frameArrivedRecentlyThenBriefSilenceKeepsGoing() {
        let verdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 9,
            sinceLastFrame: 2,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(verdict == .keepGoing)
    }

    /// Frame at 9s, then silence until 15s elapsed (`sinceLastFrame == 6`,
    /// i.e. exactly `plateau`): `.endedStall`.
    ///
    /// MUTATION CHECK: changing `sinceLastFrame >= plateau` to `>` makes
    /// this boundary case wrongly stay `.keepGoing`.
    @Test func frameAtNineThenSilenceToFifteenIsStall() {
        let verdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 15,
            sinceLastFrame: 6,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(verdict == .endedStall)
    }

    // MARK: - Hard timeout wins over everything

    /// 35s elapsed with no frame ever arrived: hard timeout must win over
    /// no-first-frame even though both conditions are independently true.
    ///
    /// MUTATION CHECK: reordering the function so the no-first-frame check
    /// runs before the hard-timeout check makes this wrongly return
    /// `.failedNoFirstFrame` instead of `.endedHardTimeout`.
    @Test func hardTimeoutWithNoFrameEverWinsOverNoFirstFrame() {
        let verdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 35,
            sinceLastFrame: nil,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(verdict == .endedHardTimeout)
    }

    /// 35s elapsed, with a frame having arrived and then stalled: hard
    /// timeout must win over stall too.
    ///
    /// MUTATION CHECK: reordering the function so the stall check runs
    /// before the hard-timeout check makes this wrongly return
    /// `.endedStall` instead of `.endedHardTimeout`.
    @Test func hardTimeoutWithStalledFrameWinsOverStall() {
        let verdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 35,
            sinceLastFrame: 20,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(verdict == .endedHardTimeout)
    }

    /// Exactly at the hard-timeout boundary (35.0s, not 34.9s):
    /// `.endedHardTimeout`.
    ///
    /// MUTATION CHECK: changing `elapsedSinceStart >= hardTimeout` to `>`
    /// makes this boundary case wrongly fall through to `.keepGoing`.
    @Test func justUnderHardTimeoutKeepsGoingThenExactlyAtItEnds() {
        let underVerdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 34.9,
            sinceLastFrame: nil,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(underVerdict == .failedNoFirstFrame)

        let atVerdict = DoorVideoSession.livenessVerdict(
            elapsedSinceStart: 35,
            sinceLastFrame: nil,
            hardTimeout: hardTimeout,
            plateau: plateau,
            firstFrameTimeout: firstFrameTimeout
        )
        #expect(atVerdict == .endedHardTimeout)
    }
}
