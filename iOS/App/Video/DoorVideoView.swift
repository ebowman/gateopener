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
struct DoorVideoView: View {
    let session: DoorVideoSession
    var state: DoorVideoSession.State

    var body: some View {
        ZStack {
            Color.black

            DoorVideoWebViewRepresentable(webView: session.webView)
                .opacity(state == .streaming ? 1 : 0)

            switch state {
            case .connecting:
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("Connecting…")
                        .font(.footnote)
                        .foregroundStyle(.white)
                }
            case .failed(let message):
                Text("Camera unavailable")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Camera unavailable: \(message)")
            case .idle, .streaming, .ended:
                EmptyView()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
