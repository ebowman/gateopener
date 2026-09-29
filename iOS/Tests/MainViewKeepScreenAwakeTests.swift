import Foundation
import Testing
@testable import GateOpener

/// Tests for bead gateopener-41m.15 STEP 5: `MainView
/// .shouldKeepScreenAwake(isPinned:openFlowNeedsAwake:)`, the pure static
/// func combining the two independent reasons the screen should stay awake
/// (the pre-existing open-flow behavior and the video being pinned) so the
/// idle-timer flag is computed in exactly one place.
struct MainViewKeepScreenAwakeTests {
    /// MUTATION CHECK: changing `||` to `&&` would make this fail — pinned
    /// alone (with no open in flight) must still keep the screen awake.
    @Test func pinnedAloneKeepsScreenAwake() {
        #expect(MainView.shouldKeepScreenAwake(isPinned: true, openFlowNeedsAwake: false) == true)
    }

    /// Open-flow alone (not pinned) must still keep the screen awake — the
    /// pre-existing tap-to-open behavior is unaffected by this bead.
    @Test func openFlowAloneKeepsScreenAwake() {
        #expect(MainView.shouldKeepScreenAwake(isPinned: false, openFlowNeedsAwake: true) == true)
    }

    /// Both reasons at once still keeps the screen awake (not a crash / not
    /// double-counted, since this returns a plain `Bool`).
    @Test func bothReasonsKeepsScreenAwake() {
        #expect(MainView.shouldKeepScreenAwake(isPinned: true, openFlowNeedsAwake: true) == true)
    }

    /// Neither reason: the screen must be allowed to sleep.
    ///
    /// MUTATION CHECK: hardcoding `true` (or an inverted `&&`/`||`) would
    /// fail this specific "both false" case while some of the above still
    /// pass.
    @Test func neitherReasonAllowsScreenToSleep() {
        #expect(MainView.shouldKeepScreenAwake(isPinned: false, openFlowNeedsAwake: false) == false)
    }

    // MARK: - isCallActive (bead gateopener-1pm.5)

    /// A live call alone (not pinned, no open in flight) must still keep
    /// the screen awake.
    ///
    /// MUTATION CHECK: dropping `isCallActive` from the `||` chain (or
    /// defaulting it away) would fail this specific case while every case
    /// above still passes.
    @Test func callActiveAloneKeepsScreenAwake() {
        #expect(MainView.shouldKeepScreenAwake(isPinned: false, openFlowNeedsAwake: false, isCallActive: true) == true)
    }

    /// All three reasons at once still keeps the screen awake.
    @Test func allThreeReasonsKeepsScreenAwake() {
        #expect(MainView.shouldKeepScreenAwake(isPinned: true, openFlowNeedsAwake: true, isCallActive: true) == true)
    }

    /// All three false (the explicit form of `neitherReasonAllowsScreenToSleep`
    /// above, now naming `isCallActive` explicitly) allows the screen to
    /// sleep.
    @Test func allThreeReasonsFalseAllowsScreenToSleep() {
        #expect(MainView.shouldKeepScreenAwake(isPinned: false, openFlowNeedsAwake: false, isCallActive: false) == false)
    }
}
