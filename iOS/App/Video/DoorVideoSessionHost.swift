import SwiftUI

/// Wraps `DoorVideoView` with an explicit identity keyed on the SESSION
/// INSTANCE (bead gateopener-41m.18): `.id(ObjectIdentifier(session))`,
/// never on `state`, so SwiftUI treats a pinned renewal (a new
/// `DoorVideoSession` instance swapped in while the caller stays on the
/// same structural `.session` branch — see
/// `DoorVideoCoordinator.startSession(resetPanelVisible: false)`) as a
/// genuinely new view identity and remounts `DoorVideoView`, forcing its
/// `UIViewRepresentable` to host the NEW session's `webView` rather than
/// silently keep the OLD (dead, blanked) one attached. Keyed on `session`
/// alone (not `state`) so a same-session `.connecting` -> `.streaming`
/// transition — the common case, and the one gateopener-672.30 depends on
/// staying mounted/visible through negotiation — never remounts.
///
/// `MainView.sessionVideo(session:overlay:)` applies its pin/close/countdown
/// overlays OUTSIDE this type (via `.overlay { ... }` on the value returned
/// here), so that chrome never remounts across a renewal either.
struct DoorVideoSessionHost: View {
    let session: DoorVideoSession
    let state: DoorVideoSession.State

    var body: some View {
        DoorVideoView(session: session, state: state)
            .id(ObjectIdentifier(session))
    }
}
