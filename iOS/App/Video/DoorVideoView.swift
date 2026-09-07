import SwiftUI
import WebKit

/// Hosts a `DoorVideoSession`'s `webView` inside SwiftUI, with a small
/// overlay reflecting `session.state`: a "Connecting…" spinner while
/// negotiating, and a short "Camera unavailable" label if the session
/// failed. Fixed at a 16:9 aspect ratio, matching a typical door-camera feed.
///
/// This view does NOT call `session.start()`/`stop()` itself — the owning
/// screen (bead gateopener-672.12) controls the session's lifecycle; this
/// type is purely a presentation wrapper.
///
/// The web view is kept at opacity 1 AT ALL TIMES (bead gateopener-672.30):
/// iOS pauses/refuses inline media playback in a hidden (opacity-0) web
/// view, so hiding it while `.connecting` was the root cause of a native
/// "paused, tap to play" glyph appearing once the first frame arrived. An
/// opaque dark overlay is drawn ON TOP instead while connecting/failed, and
/// removed (with an animation) once streaming — see `overlay(for:)` below.
struct DoorVideoView: View {
    let session: DoorVideoSession
    var state: DoorVideoSession.State

    /// The kind of opaque overlay to draw on top of the (always-visible)
    /// web view for a given `DoorVideoSession.State`. Pure mapping, unit
    /// tested directly in `DoorVideoViewOverlayTests` — extracted so the
    /// state -> presentation decision is testable without a live
    /// `WKWebView`/SwiftUI hierarchy.
    enum OverlayKind: Equatable {
        /// The "Connecting…" spinner overlay: `.idle` and `.connecting`
        /// both show it (a session that has not even called `start()` yet
        /// looks, to the operator, identical to one still negotiating).
        case connecting
        /// The "Camera unavailable" label overlay, carrying the underlying
        /// failure message for `accessibilityLabel` (never shown verbatim).
        case failed(String)
        /// No overlay: the (already-visible) web view is shown as-is.
        case none
    }

    /// Pure mapping from session state to the overlay this view draws.
    /// `.idle`/`.connecting` -> `.connecting`; `.failed` -> `.failed`;
    /// `.streaming`/`.ended` -> `.none`.
    static func overlay(for state: DoorVideoSession.State) -> OverlayKind {
        switch state {
        case .idle, .connecting:
            return .connecting
        case .failed(let message):
            return .failed(message)
        case .streaming, .ended:
            return .none
        }
    }

    var body: some View {
        ZStack {
            Color.black

            DoorVideoWebViewRepresentable(webView: session.webView)

            switch Self.overlay(for: state) {
            case .connecting:
                ZStack {
                    Color.black.opacity(0.92)
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("Connecting…")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                }
                .transition(.opacity)
            case .failed(let message):
                ZStack {
                    Color.black.opacity(0.92)
                    Text("Camera unavailable")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .accessibilityLabel("Camera unavailable: \(message)")
                }
                .transition(.opacity)
            case .none:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.25), value: Self.overlay(for: state))
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            session.ensurePlayingFromHost()
        }
    }
}

/// `UIViewRepresentable` wrapper around a pre-built `WKWebView` (owned by
/// `DoorVideoSession`, not created here) so SwiftUI can host it directly.
private struct DoorVideoWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Nothing to update: `DoorVideoSession` owns all of the web view's
        // navigation/content state; this representable exists purely to
        // place the existing `WKWebView` instance into the SwiftUI view
        // hierarchy.
    }
}
