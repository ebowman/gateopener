#if DEBUG
import Foundation
import GateOpenerCore
import UIKit
import WebKit
import os

/// `--mic-probe` / Settings' "Run mic probe" row (bead gateopener-1pm.1
/// SPIKE): answers, without any real `DoorVideoSession`/network/token
/// machinery, whether `door-video.html` loaded via `loadFileURL` (a
/// `file://` origin, exactly as `DoorVideoSession` loads it) is a secure
/// context that can call `navigator.mediaDevices.getUserMedia`, and — per
/// this bead's NOTES (the viewdoor-capture-2026-09-27 analysis) — whether,
/// once granted, the resulting `RTCPeerConnection`'s local SDP contains a
/// real (non-mDNS) LAN host candidate.
///
/// Deliberately standalone: does NOT construct a `DoorVideoSession` at all
/// (no token/gate/registry dependencies), reusing only
/// `DoorVideoSession.makeWebViewConfiguration()` (so the
/// `WKWebViewConfiguration` itself is guaranteed identical to a real
/// session's) and `DoorVideoSession`'s pure `mediaCaptureDecision`/
/// `isOurOrigin` statics (so the grant/deny decision under test is the SAME
/// logic the real session runs in production, not a re-implementation that
/// could silently diverge).
///
/// Cannot be exercised meaningfully in the simulator (no real microphone
/// device / simulator getUserMedia quirks) — this exists to be run on a
/// real iPhone (`--mic-probe` launch arg, or the Settings row for an
/// already-installed build where launch args are impractical).
@MainActor
enum MicProbe {
    private static let logger = Logger(subsystem: "ie.boboco.GateOpener", category: "video")

    /// Runs the probe end-to-end: loads `door-video.html` into a throwaway
    /// `WKWebView`, executes `mic-probe.js`'s body via `callAsyncJavaScript`,
    /// logs the one-line result via `os.Logger`, and appends the SAME line
    /// to the video diagnostics history (`VideoDiagnostics.appendEvent`) so
    /// it can be shared from Settings without re-running anything.
    ///
    /// Never throws: every failure path (missing bundle resource, JS
    /// exception, malformed JSON result) is folded into the logged/appended
    /// line itself, since this exists purely to be read by a human, not
    /// handled programmatically by any caller.
    static func run() async {
        let line = await resultLine()
        logger.notice("\(line, privacy: .public)")
        VideoDiagnostics.appendEvent(line, to: SharedContainer.sharedDefaults() ?? .standard)
    }

    /// Builds the exact "mic-probe: ..." line `run()` logs/persists,
    /// isolated from those side effects so it is straightforward to reason
    /// about independently (there is no meaningful way to unit test the
    /// real WKWebView/getUserMedia path itself — see this type's doc
    /// comment).
    private static func resultLine() async -> String {
        guard let pageURL = Bundle.main.url(forResource: "door-video", withExtension: "html") else {
            return "mic-probe: door-video.html not found in bundle"
        }
        guard let probeURL = Bundle.main.url(forResource: "mic-probe", withExtension: "js"),
              let probeSource = try? String(contentsOf: probeURL, encoding: .utf8) else {
            return "mic-probe: mic-probe.js not found in bundle"
        }

        // Bead gateopener-1pm.1 fix pass: a zero-size web view that is never
        // added to any window can make WebKit hold or silently deny a
        // `getUserMedia` prompt (mirroring `DoorVideoView`'s own "kept at
        // opacity 1 AT ALL TIMES" rule, bead gateopener-672.30 — a hidden or
        // unattached web view is not a reliable host for live media). So
        // this throwaway web view is attached, VISIBLY (non-zero alpha), to
        // the first connected `UIWindowScene`'s key window for the
        // lifetime of the probe, then removed again once done — see the
        // `defer` right below.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1, height: 1),
            configuration: DoorVideoSession.makeWebViewConfiguration()
        )
        webView.alpha = 0.01
        let hostWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .keyWindow
        hostWindow?.addSubview(webView)
        defer { webView.removeFromSuperview() }

        let delegate = MicProbeDelegate()
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.pageLoadContinuation = continuation
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }

        // `probeSource` (`mic-probe.js`) is a plain statement list, not a
        // function declaration — see that file's own doc comment on why —
        // so it is wrapped here as the body of an async arrow function IIFE,
        // matching every other page call in `DoorVideoSession` in using
        // `callAsyncJavaScript` (never `evaluateJavaScript`, which fails on
        // any Promise-returning expression).
        let functionBody = "return await (async () => {\n\(probeSource)\n})();"
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(functionBody, contentWorld: .page)
        } catch {
            return "mic-probe: probe script threw: \(String(describing: error))"
        }

        guard let jsonString = raw as? String,
              let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "mic-probe: probe returned unparseable result: \(String(describing: raw))"
        }

        let isSecureContext = (object["isSecureContext"] as? Bool) ?? false
        let hasMediaDevices = (object["hasMediaDevices"] as? Bool) ?? false
        let gum = (object["gum"] as? String) ?? "unknown"
        let hostCandidate = (object["hostCandidate"] as? String) ?? "unknown"

        // Keeps `webView`/`delegate` alive for the whole function body above
        // (both are locals with no other retainer once this function
        // returns) — referenced here only so neither is flagged/optimized
        // away before `callAsyncJavaScript` above has actually completed.
        _ = webView
        _ = delegate

        return "mic-probe: secure=\(isSecureContext) mediaDevices=\(hasMediaDevices) gum=\(gum) host=\(hostCandidate)"
    }
}

/// Standalone `WKNavigationDelegate` + `WKUIDelegate` for `MicProbe`'s
/// throwaway web view — mirrors `DoorVideoSession`'s own
/// `pageLoadContinuation`/`WKUIDelegate` wiring (see that type) but does
/// not reuse its instance methods, since `MicProbe` never constructs a
/// `DoorVideoSession` (see `MicProbe`'s doc comment on why). The
/// grant/deny DECISION itself still calls `DoorVideoSession`'s pure
/// statics directly, so this is not a re-implementation of that logic.
@MainActor
private final class MicProbeDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    var pageLoadContinuation: CheckedContinuation<Void, Never>?

    // `nonisolated` (matching `DoorVideoSession`'s own `WKNavigationDelegate`
    // conformance): this protocol requirement is not itself
    // `@MainActor`-isolated, so satisfying it from an `@MainActor` class
    // requires either `nonisolated` + an explicit hop to touch actor-isolated
    // state (`pageLoadContinuation`, here), or leaving the class off the
    // actor entirely — the latter is not viable since `MicProbe.resultLine()`
    // itself already runs on the main actor and constructs/reads this
    // delegate from there.
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.pageLoadContinuation?.resume()
            self.pageLoadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.pageLoadContinuation?.resume()
            self.pageLoadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.pageLoadContinuation?.resume()
            self.pageLoadContinuation = nil
        }
    }

    // Deliberately NOT `nonisolated` (unlike the navigation methods above):
    // `WKSecurityOrigin.protocol`/`.host` are themselves `@MainActor`-
    // isolated in the SDK's overlay, so reading them requires this method
    // to run on the main actor too — which it already does, since this
    // class is `@MainActor` and only ever installed on a main-actor-
    // confined `WKWebView`. Mirrors `DoorVideoSession`'s own `WKUIDelegate`
    // conformance exactly.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let originIsOurs = DoorVideoSession.isOurOrigin(protocol: origin.protocol, host: origin.host)
        decisionHandler(DoorVideoSession.mediaCaptureDecision(type: type, originIsOurs: originIsOurs))
    }
}
#endif
