import Foundation
import Testing
import WebKit
@testable import GateOpener

/// Tests for bead gateopener-1pm.1's `WKUIDelegate` mic-permission
/// decision: `DoorVideoSession.mediaCaptureDecision(type:originIsOurs:)` and
/// `DoorVideoSession.isOurOrigin(protocol:host:)`. Both are pure statics —
/// see their doc comments in `DoorVideoSession.swift` — precisely so they
/// are testable without a real `WKSecurityOrigin`/`WKUIDelegate` call (a
/// `WKSecurityOrigin` cannot be constructed directly).
struct DoorVideoSessionMicPermissionTests {
    // MARK: - mediaCaptureDecision

    /// The only case that should ever grant: microphone, from our own page.
    ///
    /// MUTATION CHECK: returning `.deny` unconditionally, or dropping the
    /// `type == .microphone` check, would fail this assertion.
    @Test func mediaCaptureDecisionGrantsMicFromOurOrigin() {
        let decision = DoorVideoSession.mediaCaptureDecision(type: .microphone, originIsOurs: true)
        #expect(decision == .grant)
    }

    /// Camera is never requested by this app and must be denied even from
    /// our own origin.
    ///
    /// MUTATION CHECK: dropping the `type == .microphone` check (e.g.
    /// granting any type from our origin) would fail this assertion.
    @Test func mediaCaptureDecisionDeniesCameraFromOurOrigin() {
        let decision = DoorVideoSession.mediaCaptureDecision(type: .camera, originIsOurs: true)
        #expect(decision == .deny)
    }

    /// A microphone request from a foreign origin must be denied —
    /// `door-video.html` never loads third-party content, so this should
    /// never legitimately happen, but the guard must hold regardless.
    ///
    /// MUTATION CHECK: dropping the `originIsOurs` check (e.g. granting any
    /// microphone request regardless of origin) would fail this assertion.
    @Test func mediaCaptureDecisionDeniesMicFromForeignOrigin() {
        let decision = DoorVideoSession.mediaCaptureDecision(type: .microphone, originIsOurs: false)
        #expect(decision == .deny)
    }

    /// `.cameraAndMicrophone` is NOT "microphone only" and must be denied
    /// even from our own origin — granting it would silently also grant
    /// camera access.
    ///
    /// MUTATION CHECK: treating `.cameraAndMicrophone` as equivalent to
    /// `.microphone` (e.g. `type != .camera` instead of `type ==
    /// .microphone`) would fail this assertion.
    @Test func mediaCaptureDecisionDeniesCameraAndMicrophoneFromOurOrigin() {
        let decision = DoorVideoSession.mediaCaptureDecision(type: .cameraAndMicrophone, originIsOurs: true)
        #expect(decision == .deny)
    }

    /// Belt-and-suspenders: camera from a foreign origin is also denied.
    @Test func mediaCaptureDecisionDeniesCameraFromForeignOrigin() {
        let decision = DoorVideoSession.mediaCaptureDecision(type: .camera, originIsOurs: false)
        #expect(decision == .deny)
    }

    // MARK: - isOurOrigin

    /// `door-video.html` is loaded via `loadFileURL` today, i.e. a
    /// `file://` origin — this MUST be recognized as ours.
    ///
    /// MUTATION CHECK: comparing against any string other than `"file"`
    /// would fail this assertion.
    @Test func isOurOriginTrueForFileProtocol() {
        #expect(DoorVideoSession.isOurOrigin(protocol: "file", host: "") == true)
    }

    /// An arbitrary third-party https origin must never be treated as ours.
    ///
    /// MUTATION CHECK: a hardcoded `true` return, or checking only `host`
    /// and ignoring `protocol`, would fail this assertion.
    @Test func isOurOriginFalseForForeignHTTPSOrigin() {
        #expect(DoorVideoSession.isOurOrigin(protocol: "https", host: "example.com") == false)
    }

    /// Bead gateopener-1pm.2's prospective future origin (an https
    /// baseURL/localhost, NOT yet implemented — see `isOurOrigin`'s doc
    /// comment) is deliberately NOT recognized as ours by THIS bead's
    /// implementation. Documents the current (not yet widened) behavior so
    /// a future change to `isOurOrigin` that silently starts accepting an
    /// arbitrary https host is caught by this test failing, forcing an
    /// explicit, deliberate update here instead.
    @Test func isOurOriginFalseForFutureHTTPSOriginNotYetImplemented() {
        #expect(DoorVideoSession.isOurOrigin(protocol: "https", host: "gateopener.local") == false)
    }

    /// An empty `protocol` (never a real WKSecurityOrigin value, but a
    /// defensive check) must not be treated as ours.
    @Test func isOurOriginFalseForEmptyProtocol() {
        #expect(DoorVideoSession.isOurOrigin(protocol: "", host: "") == false)
    }
}
