import SwiftUI
import Testing
@testable import GateOpener

/// Tests for `GateOpenerIOSApp.videoAction(for:)` (bead gateopener-41m.17):
/// the pure scenePhase -> door-video-lifecycle decision extracted from the
/// `.onChange(of: scenePhase)` handler. `.background` still dismisses;
/// `.inactive` (a brief Notification Center/Control Center/app-switcher/call
/// banner/Face ID blip) must leave a live or connecting session alone rather
/// than tearing it down and forcing a fresh `rtc/offer` on return to
/// `.active`.
struct GateOpenerIOSAppScenePhaseTests {
    // MARK: - .background -> .dismiss

    /// MUTATION CHECK: changing `case .background: return .dismiss` to
    /// `return .none` (or any other case) in
    /// `GateOpenerIOSApp.videoAction(for:)` fails this assertion — a
    /// backgrounded app must always tear down any live door-video session.
    @Test func backgroundReturnsDismiss() {
        #expect(GateOpenerIOSApp.videoAction(for: .background) == .dismiss)
    }

    // MARK: - .inactive -> .none

    /// MUTATION CHECK: changing `case .inactive: return .none` to
    /// `return .dismiss` in `GateOpenerIOSApp.videoAction(for:)` — i.e.
    /// reverting to the pre-bead-41m.17 behavior of dismissing on any
    /// non-`.active` phase — fails this assertion. A brief `.inactive` blip
    /// (Notification Center pull-down, app-switcher peek, call banner, Face
    /// ID, system alert) must not tear down a live/connecting session.
    @Test func inactiveReturnsNone() {
        #expect(GateOpenerIOSApp.videoAction(for: .inactive) == .none)
    }

    // MARK: - .active -> .startIfAppropriate

    /// MUTATION CHECK: changing `case .active: return .startIfAppropriate`
    /// to `return .none` (or `.dismiss`) fails this assertion — foregrounding
    /// must still prewarm the token manager, publish the widget snapshot,
    /// and attempt to start/retain door video.
    @Test func activeReturnsStartIfAppropriate() {
        #expect(GateOpenerIOSApp.videoAction(for: .active) == .startIfAppropriate)
    }
}
