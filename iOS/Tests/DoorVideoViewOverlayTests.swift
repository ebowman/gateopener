import Foundation
import Testing
@testable import GateOpener

/// Tests for `DoorVideoView.overlay(for:)` (bead gateopener-672.30): the
/// pure mapping from `DoorVideoSession.State` to the overlay kind drawn on
/// top of the now-always-visible web view. Covers all five `State` cases.
@MainActor
struct DoorVideoViewOverlayTests {
    /// MUTATION CHECK: changing the `.idle` branch in `overlay(for:)` to
    /// return `.none` (instead of `.connecting`) makes this assertion fail
    /// — `.idle` must show the same "Connecting…" overlay as `.connecting`,
    /// since a session that has not even called `start()` yet looks
    /// identical to the operator.
    @Test func idleMapsToConnectingOverlay() {
        #expect(DoorVideoView.overlay(for: .idle) == .connecting)
    }

    /// MUTATION CHECK: changing the `.connecting` branch to return `.none`
    /// makes this fail, leaving the web view fully exposed (paused/blank)
    /// during negotiation instead of behind the dark overlay.
    @Test func connectingMapsToConnectingOverlay() {
        #expect(DoorVideoView.overlay(for: .connecting) == .connecting)
    }

    /// MUTATION CHECK: changing the `.streaming` branch to return
    /// `.connecting` (or anything but `.none`) makes this fail, leaving an
    /// opaque overlay permanently covering live video once streaming
    /// starts.
    @Test func streamingMapsToNoOverlay() {
        #expect(DoorVideoView.overlay(for: .streaming) == .none)
    }

    /// MUTATION CHECK: changing the `.ended` branch to return `.connecting`
    /// makes this fail — a session that ended normally (door's own ~28-30s
    /// window elapsed, or `stop()`) must NOT show the connecting spinner
    /// again.
    @Test func endedMapsToNoOverlay() {
        #expect(DoorVideoView.overlay(for: .ended) == .none)
    }

    /// MUTATION CHECK: changing the `.failed` branch to return `.none` (or
    /// `.connecting`) makes this fail. Also asserts the underlying message
    /// is carried through unchanged, distinguishing this from a
    /// `.connecting`/`.none` case that happens to share the same shape.
    @Test func failedMapsToFailedOverlayCarryingMessage() {
        #expect(DoorVideoView.overlay(for: .failed("No camera")) == .failed("No camera"))
        #expect(DoorVideoView.overlay(for: .failed("No camera")) != .failed("Sign-in required"))
    }
}
