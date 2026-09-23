#if DEBUG
import Foundation
import Testing
@testable import GateOpener

/// Tests for `DebugLaunchOptions`' pure argument-parsing helpers (bead
/// gateopener-41m.15 STEP 6/9): `parseSecondsFlag(_:in:)` (backing
/// `autoOpenAfterSeconds`/`autoPinAfterSeconds`) and
/// `parseMockVideoTimeline(in:)` (backing `mockVideoTimeline`). These take an
/// explicit `[String]` array rather than reading `ProcessInfo.processInfo
/// .arguments` directly, since the real process arguments are fixed for the
/// life of the test process and cannot be swapped per-test.
struct DebugLaunchOptionsParsingTests {
    // MARK: - parseSecondsFlag (--auto-open-after / --auto-pin-after)

    /// MUTATION CHECK: returning the flag's own index (rather than
    /// `flagIndex + 1`'s value) or dropping the `Double(...)` conversion
    /// entirely would fail this assertion.
    @Test func parseSecondsFlagParsesValidValue() {
        let result = DebugLaunchOptions.parseSecondsFlag("--auto-open-after", in: ["app", "--auto-open-after", "3.5"])
        #expect(result == 3.5)
    }

    /// MUTATION CHECK: dropping the `firstIndex(of:)` guard (e.g. always
    /// looking at a fixed index) would return a non-nil value here despite
    /// the flag being entirely absent.
    @Test func parseSecondsFlagReturnsNilWhenFlagAbsent() {
        let result = DebugLaunchOptions.parseSecondsFlag("--auto-open-after", in: ["app", "--mock-gate", "ok"])
        #expect(result == nil)
    }

    /// The flag is the LAST argument, with nothing following it.
    ///
    /// MUTATION CHECK: removing the `arguments.count > flagIndex + 1` bounds
    /// check would crash (array index out of range) instead of returning
    /// `nil`.
    @Test func parseSecondsFlagReturnsNilWhenFlagIsLastArgument() {
        let result = DebugLaunchOptions.parseSecondsFlag("--auto-open-after", in: ["app", "--auto-open-after"])
        #expect(result == nil)
    }

    /// MUTATION CHECK: removing the `Double(...)` conversion's optional
    /// binding (e.g. force-unwrapping) would crash instead of returning
    /// `nil` for a non-numeric following argument.
    @Test func parseSecondsFlagReturnsNilWhenValueIsMalformed() {
        let result = DebugLaunchOptions.parseSecondsFlag("--auto-open-after", in: ["app", "--auto-open-after", "soon"])
        #expect(result == nil)
    }

    /// Distinct flags parse independently — `--auto-pin-after`'s value is
    /// not accidentally read from an unrelated `--auto-open-after` flag also
    /// present on the command line.
    @Test func parseSecondsFlagDistinguishesFlags() {
        let arguments = ["app", "--auto-open-after", "2", "--auto-pin-after", "9"]
        #expect(DebugLaunchOptions.parseSecondsFlag("--auto-open-after", in: arguments) == 2)
        #expect(DebugLaunchOptions.parseSecondsFlag("--auto-pin-after", in: arguments) == 9)
    }

    // MARK: - parseMockVideoTimeline (--mock-video [<connecting> <streaming>])

    /// MUTATION CHECK: swapping which of `flagIndex + 1`/`flagIndex + 2` maps
    /// to `connectingSeconds` vs. `streamingSeconds` would make this
    /// assertion fail (distinct literals catch the swap).
    @Test func parseMockVideoTimelineParsesBothValues() {
        let result = DebugLaunchOptions.parseMockVideoTimeline(in: ["app", "--mock-video", "1", "5"])
        #expect(result?.connectingSeconds == 1)
        #expect(result?.streamingSeconds == 5)
    }

    /// A bare `--mock-video` (no following arguments at all, the
    /// pre-existing form predating this bead) must return `nil` so
    /// `debugStub()`'s own defaults apply — not a partially-populated tuple.
    ///
    /// MUTATION CHECK: relaxing the `arguments.count > flagIndex + 2` bound
    /// to `flagIndex + 1` would let this incorrectly attempt to parse past
    /// the end of the array or silently succeed with a bogus one-argument
    /// reading.
    @Test func parseMockVideoTimelineReturnsNilWhenFlagIsBare() {
        let result = DebugLaunchOptions.parseMockVideoTimeline(in: ["app", "--mock-video"])
        #expect(result == nil)
    }

    /// Only ONE trailing numeric argument (`--mock-video 1`, missing the
    /// streaming leg) must return `nil` entirely, never a half-populated
    /// result defaulting the missing leg to something arbitrary.
    @Test func parseMockVideoTimelineReturnsNilWhenOnlyOneArgumentFollows() {
        let result = DebugLaunchOptions.parseMockVideoTimeline(in: ["app", "--mock-video", "1"])
        #expect(result == nil)
    }

    /// A malformed first argument (`--mock-video abc 5`) must return `nil`
    /// entirely, not fall back to defaulting just the malformed leg.
    @Test func parseMockVideoTimelineReturnsNilWhenFirstArgumentIsMalformed() {
        let result = DebugLaunchOptions.parseMockVideoTimeline(in: ["app", "--mock-video", "abc", "5"])
        #expect(result == nil)
    }

    /// A malformed second argument (`--mock-video 1 abc`) must also return
    /// `nil` entirely.
    @Test func parseMockVideoTimelineReturnsNilWhenSecondArgumentIsMalformed() {
        let result = DebugLaunchOptions.parseMockVideoTimeline(in: ["app", "--mock-video", "1", "abc"])
        #expect(result == nil)
    }

    /// The flag being entirely absent returns `nil`.
    @Test func parseMockVideoTimelineReturnsNilWhenFlagAbsent() {
        let result = DebugLaunchOptions.parseMockVideoTimeline(in: ["app", "--mock-gate", "ok"])
        #expect(result == nil)
    }
}
#endif
