import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - gateopener-69h: Duration -> TimeInterval exact conversion

/// Acceptance test: whole-second durations convert unchanged.
///
/// MUTATION CHECK: removing the `attoseconds` term from `timeInterval`
/// leaves this particular case passing (0 attoseconds contributes nothing),
/// so this test alone does not catch that mutation -- see the fractional
/// cases below, which do.
@Test func timeIntervalWholeSecondsConvertsExactly() {
    #expect(Duration.seconds(8).timeInterval == 8.0)
}

/// Acceptance test: a duration with a fractional-second remainder (2.5s
/// expressed as 2500ms) converts exactly, not truncated to 2.0.
///
/// MUTATION CHECK: removing the `attoseconds` term from `timeInterval`
/// (i.e. reverting to `TimeInterval(components.seconds)` alone) makes this
/// assertion fail: 2.5 != 2.0.
@Test func timeIntervalFractionalSecondsConvertsExactly() {
    #expect(Duration.milliseconds(2500).timeInterval == 2.5)
}

/// Acceptance test: a sub-one-second duration (500ms) converts to 0.5, not
/// truncated to 0 -- the case called out in the bead description as
/// dangerous, since a `URLRequest.timeoutInterval` of exactly 0 is treated
/// as "no override" and silently falls back to the 60s system default.
///
/// MUTATION CHECK: removing the `attoseconds` term makes this assertion
/// fail: 0.5 != 0.0.
@Test func timeIntervalSubSecondConvertsExactly() {
    #expect(Duration.milliseconds(500).timeInterval == 0.5)
}

/// Edge case: `.zero` converts to exactly `0.0`.
@Test func timeIntervalZeroConvertsToZero() {
    #expect(Duration.zero.timeInterval == 0.0)
}

/// Edge case: a negative duration converts to a negative `TimeInterval`,
/// preserving sign across both the whole-second and fractional components.
///
/// MUTATION CHECK: removing the `attoseconds` term makes this assertion
/// fail: -1.5 != -1.0 (or -2.0, depending on how `seconds` truncates/rounds
/// the negative whole-second component).
@Test func timeIntervalNegativeDurationConvertsExactly() {
    #expect(Duration.milliseconds(-1500).timeInterval == -1.5)
}
