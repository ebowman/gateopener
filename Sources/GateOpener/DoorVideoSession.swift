import AppKit
import WebKit
import GateOpenerCore
import os

// MARK: - DoorVideoSessionState

/// The full state of a `DoorVideoSession`, as far as the UI needs to know.
///
/// Mirrors the shape of `GateOpenerCore.GateState` (see that type's doc
/// comment on why `GateController` exposes state via a plain stored
/// property plus an `onStateChange` callback rather than
/// `@Observable`/Combine): this type deliberately lives in the app layer,
/// NOT `GateOpenerCore`, since it is WKWebView/AppKit-specific and
/// `GateOpenerCore` must never import either.
public enum DoorVideoSessionState: Equatable, Sendable {
    /// Nothing has happened yet; `start()` has not been called.
    case idle
    /// `start()` is in flight: resolving a token, discovering the camera
    /// endpoint, negotiating, and waiting for the `rtc/offer` round trip.
    case connecting
    /// The peer connection is up and at least one video frame has been
    /// decoded.
    case streaming
    /// The session ended normally (e.g. `stop()` was called, or the door
    /// closed the stream on its own). `reason` is a short, human-readable
    /// string safe to show directly in UI.
    case ended(reason: String)
    /// The session could not be established. `message` is a SHORT,
    /// human-readable string safe to show directly in a tooltip/label —
    /// never a raw error dump.
    case failed(message: String)
}

// MARK: - DoorVideoSession

/// Establishes and owns exactly ONE live WebRTC session against the Comelit
/// door camera, driven by WKWebView's own WebRTC stack (NOT libwebrtc — see
/// bd memory `gateopener-yjn-spike-result-wkwebview-webkit-s-own`: WebKit's
/// independent implementation receives real RTP from the door station,
/// which a `aiortc`-based client never did).
///
/// This type does exactly what its name says and NOTHING else:
///  - ONE session, established once via `start()`.
///  - NO renegotiation, NO reconnect, NO stale-frame watchdog, NO session
///    continuation. When the door stops sending media, or `stop()` is
///    called, the session is over — a new `DoorVideoSession` instance is
///    the only way to start another one. (Those behaviors are explicitly
///    out of scope for this bead; see gateopener-12h.4/.5.)
///  - NO UI beyond exposing the underlying `WKWebView` for embedding (see
///    `contentView` below) and a state callback.
///
/// ## The recipe (load-bearing, proven against real hardware — do not
/// improvise any element of this)
///
/// See bd memories `gateopener-yjn-spike-result-wkwebview-webkit-s-own` and
/// `gateopener-yjn-spike-addendum-answers-to-a-follow`, and
/// `../comelit/comelit/webrtc_page.html` (the original this page is
/// stripped down from):
///  - `Resources/door-video.html` builds recvonly audio+video transceivers,
///    AUDIO ADDED BEFORE VIDEO — the door's answer generation is sensitive
///    to m-line order — plus a `createDataChannel('data')` so the offer has
///    3 BUNDLE m-sections (audio/video/application).
///  - Non-trickle ICE: the page waits for `iceGatheringState === 'complete'`
///    before returning the offer SDP; the full offer is sent in one shot.
///  - Comelit's STUN host is pre-resolved to IPs HERE, in Swift
///    (`resolveStunIPs`), and injected as `window.__ICE_SERVERS__` before
///    the page negotiates — a bare hostname/mDNS-only candidate is
///    rejected by the door's signaling backend.
///  - The `rtc/offer` PUT is issued from Swift via `URLSession`, using a
///    token obtained through `GateOpenerCore`'s `TokenManager`. THE BEARER
///    TOKEN NEVER REACHES PAGE JS — only the offer/answer SDP strings cross
///    the Swift/JS boundary.
///  - `'#'` in the endpoint id is replaced with `%23` only (not full
///    percent-encoding) before building the `rtc/offer` URL.
///
/// ## GOTCHA
///
/// Plain `evaluateJavaScript(_:)` fails with `WKErrorDomain` code 5
/// ("unsupported type") on ANY Promise-returning expression, even a bare
/// `Promise.resolve(...)`. Every async call into the page here uses
/// `callAsyncJavaScript(_:contentWorld:)` with an explicit `return await
/// ...;` body instead.
///
/// ## Degrade paths
///
/// - Unbundled process (`swift run`, self-test): `door-video.html` is not
///   found in `Bundle.main` (mirrors `GateOpenVideoView.makeIfAvailable`'s
///   handling of `gate-open.mp4`) — this is logged as a notice and
///   `start()` reports `.failed`, never a crash.
/// - No network / non-200 from `rtc/offer` / token unavailable or
///   `needsSetup`: `.failed(message:)` with a short message, never a
///   prompt, never a force-unwrap, never a crash.
@MainActor
public final class DoorVideoSession: NSObject {
    private static let logger = Logger(subsystem: "com.gateopener", category: "door-video")

    /// The friendly-name substring (case-insensitive) used to pick the door
    /// camera endpoint out of discovery results.
    private static let cameraFriendlyNameHint = "entry"

    /// The known door-camera endpoint id suffix, used as a fallback when no
    /// endpoint's `friendlyName` matches `cameraFriendlyNameHint`.
    private static let cameraEndpointIdSuffix = "VIP#EN#SB100001"

    private static let stunHost = "stun.cloud.comelitgroup.com"
    private static let stunPort = 3478

    /// `WKWebView` is exposed directly (rather than wrapping it in a custom
    /// `NSView`/`AVSampleBufferDisplayLayer` bridge) because the video is
    /// already rendered by WebKit into a `<video>` element inside the page
    /// — the web view itself IS the fully-composited, correctly-scaled
    /// render target, and no further frame extraction/compositing is
    /// needed for a live-preview use case (contrast `GateOpenVideoView`,
    /// which decodes a *local* asset via `AVPlayerLayer`; there is no
    /// bundled asset here to hand to `AVPlayer`). This also keeps
    /// `DoorVideoSession` a single owner of the whole pipeline: one type,
    /// one `WKWebView`, one peer connection, no second view class to keep
    /// in sync with it.
    ///
    /// It conforms to `OverlayShowHideResponding` (see the extension below)
    /// so it is directly installable via `OverlayWindowController.
    /// setContent(_:)`.
    public let contentView: WKWebView

    /// Current state; mutating this always invokes `onStateChange`.
    public private(set) var state: DoorVideoSessionState = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    /// Invoked on every state transition, mirroring `GateController.
    /// onStateChange`. Always invoked on the main actor.
    public var onStateChange: ((DoorVideoSessionState) -> Void)?

    private let tokenManager: TokenManager
    private let gateClient: GateClient
    private let session: URLSession

    /// Guards `stop()`/`close()` idempotency and prevents `start()` from
    /// being invoked more than once per instance (this type is ONE
    /// session, never reused).
    private var hasStarted = false
    private var hasStopped = false

    /// Polling task watching for the first decoded frame after the answer
    /// SDP has been applied; cancelled by `stop()`.
    private var streamingPollTask: Task<Void, Never>?

    public init(
        tokenManager: TokenManager,
        gateClient: GateClient,
        session: URLSession = .shared
    ) {
        self.tokenManager = tokenManager
        self.gateClient = gateClient
        self.session = session

        let config = WKWebViewConfiguration()
        // A minimal non-zero frame avoids a degenerate 0x0 layout before the
        // embedder resizes it. This type does NOT manage window placement —
        // whatever embeds `contentView` owns that — but embedding into a
        // REAL, ordered-front window (or a window-hosted, layer-backed view
        // hierarchy, e.g. `OverlayWindowController.setContent(_:)`) is NOT
        // optional: gateopener-12h.8 found, verified against real hardware,
        // that a `WKWebView` never added to a window decodes RTP
        // (framesDecoded > 0 in `pc.getStats()`) but never composites a
        // single pixel to its `<video>` element (videoWidth/videoHeight
        // stay 0). The embedder MUST add `contentView` to a window (or a
        // view hierarchy already in a window) and order that window front
        // BEFORE relying on the stream painting anything visible.
        self.contentView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: config)

        super.init()
        contentView.navigationDelegate = self
    }

    deinit {
        // `close()` is @MainActor and this type is always used on the main
        // actor per its own @MainActor annotation, but `deinit` itself is
        // `nonisolated` under Swift 6 — there is nothing further to release
        // here beyond what ARC already tears down (the WKWebView, the
        // peer connection inside the page, and the poll task are all
        // released with this instance). Callers are expected to call
        // `stop()` explicitly before releasing their last reference so
        // teardown is deterministic rather than relying on `deinit` timing.
    }

    // MARK: - start()

    /// Establishes the one and only WebRTC session this instance will ever
    /// have. Safe to call at most once; a second call is a no-op (logged)
    /// since this type does not support restarting.
    ///
    /// Never throws: all failure paths are reported via `state`.
    public func start() async {
        guard !hasStarted else {
            Self.logger.notice("DoorVideoSession.start() called more than once; ignoring")
            return
        }
        hasStarted = true
        state = .connecting

        guard let pageURL = Bundle.main.url(forResource: "door-video", withExtension: "html") else {
            // Mirrors GateOpenVideoView.makeIfAvailable's degrade path: an
            // unbundled process (swift run, self-test) has no Resources
            // directory to resolve at all. Logged as a notice, not an
            // error — this is expected outside a built .app bundle.
            Self.logger.notice("door-video.html not found in bundle; DoorVideoSession cannot start")
            state = .failed(message: "Video page unavailable")
            return
        }

        let token: String
        do {
            token = try await tokenManager.accessToken()
        } catch TokenManagerError.notConfigured {
            state = .failed(message: "Sign-in required")
            return
        } catch {
            state = .failed(message: "Could not get access token")
            return
        }

        let endpointId: String
        do {
            endpointId = try await resolveCameraEndpointId()
        } catch {
            state = .failed(message: "Door camera not found")
            return
        }

        let stunIPs = Self.resolveStunIPs(host: Self.stunHost)
        let iceServerURLs = stunIPs.isEmpty
            ? ["stun:\(Self.stunHost):\(Self.stunPort)"]
            : stunIPs.map { "stun:\($0):\(Self.stunPort)" }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.pageLoadContinuation = continuation
            self.contentView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }

        guard !hasStopped else { return }

        do {
            try await injectIceServers(iceServerURLs)
        } catch {
            state = .failed(message: "Video page failed to load")
            return
        }

        guard !hasStopped else { return }

        let offerSDP: String
        do {
            offerSDP = try await startNegotiation()
        } catch {
            state = .failed(message: "Could not negotiate video session")
            return
        }

        guard !hasStopped else { return }

        let answerSDP: String
        do {
            answerSDP = try await putOfferWithRetry(endpointId: endpointId, token: token, sdp: offerSDP)
        } catch {
            Self.logger.error("rtc/offer failed after retry: \(String(describing: error), privacy: .public)")
            state = .failed(message: "Could not reach door camera")
            return
        }

        guard !hasStopped else { return }

        do {
            try await applyAnswer(answerSDP)
        } catch {
            state = .failed(message: "Could not apply video answer")
            return
        }

        guard !hasStopped else { return }

        watchForFirstFrame()
    }

    // MARK: - stop()/close()

    /// Tears down the peer connection and stops the web view so no session
    /// or decoder leaks. Idempotent: safe to call multiple times, and safe
    /// to call even if `start()` was never called or is still in flight.
    public func stop() {
        guard !hasStopped else { return }
        hasStopped = true

        streamingPollTask?.cancel()
        streamingPollTask = nil

        pageLoadContinuation?.resume()
        pageLoadContinuation = nil

        // Fire-and-forget: best-effort teardown of the RTCPeerConnection
        // inside the page. Errors here are logged, never surfaced (the
        // session is ending regardless).
        Task { [weak contentView] in
            guard let contentView else { return }
            _ = try? await contentView.callAsyncJavaScript(
                "return window.closeSession ? window.closeSession() : null;",
                contentWorld: .page
            )
        }

        contentView.stopLoading()
        contentView.navigationDelegate = nil
        contentView.loadHTMLString("", baseURL: nil)

        if case .failed = state {
            // Preserve a failure reason already reported rather than
            // clobbering it with a generic "ended" — stop() after a failed
            // start() should not overwrite the more specific message.
            return
        }
        state = .ended(reason: "stopped")
    }

    /// Alias for `stop()`, per the bead's naming ("stop()/close()").
    public func close() {
        stop()
    }

    // MARK: - Camera endpoint selection

    /// Selects the door camera endpoint: `friendlyName` containing "entry"
    /// (case-insensitive) takes priority; otherwise the first endpoint
    /// whose id ends with the known camera id suffix
    /// (`VIP#EN#SB100001`, matched as the final `_`-separated id
    /// component, mirroring `GateClient`'s existing
    /// `endpointIdMatchesGenericActuator` robustness rather than a bare
    /// `hasSuffix`). Reuses `GateClient.discover()` — no new discovery path.
    private func resolveCameraEndpointId() async throws -> String {
        let endpoints = try await gateClient.discover()

        if let byName = endpoints.first(where: {
            $0.friendlyName.range(of: Self.cameraFriendlyNameHint, options: .caseInsensitive) != nil
        }) {
            return byName.endpointId
        }

        if let byId = endpoints.first(where: { Self.endpointIdMatchesCameraSuffix($0.endpointId) }) {
            return byId.endpointId
        }

        throw DoorVideoSessionError.cameraNotFound
    }

    /// Robustly test whether `endpointId`'s final `_`-separated component
    /// case-insensitively equals `cameraEndpointIdSuffix`, mirroring
    /// `GateClient.endpointIdMatchesGenericActuator`'s approach (trim
    /// whitespace, compare case-insensitively, match the LAST id component
    /// exactly rather than a bare string tail).
    private static func endpointIdMatchesCameraSuffix(_ endpointId: String) -> Bool {
        let trimmed = endpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastComponent = trimmed.components(separatedBy: "_").last else { return false }
        return lastComponent.caseInsensitiveCompare(cameraEndpointIdSuffix) == .orderedSame
    }

    // MARK: - STUN pre-resolution

    /// Resolves `host` to its IP addresses via `getaddrinfo`, so the
    /// page can be handed real `stun:<ip>:3478` URLs instead of a hostname
    /// the door's signaling backend may reject. Returns `[]` (never
    /// throws) on any resolution failure — the caller falls back to the
    /// hostname form.
    private static func resolveStunIPs(host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        var ips: [String] = []
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return ips }
        defer { freeaddrinfo(first) }
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let p = ptr {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(p.pointee.ai_addr, p.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !ip.isEmpty, !ips.contains(ip) { ips.append(ip) }
            }
            ptr = p.pointee.ai_next
        }
        return ips
    }

    // MARK: - Page bridging (all async calls MUST use callAsyncJavaScript,
    // never evaluateJavaScript — see the GOTCHA in the type doc comment)

    private var pageLoadContinuation: CheckedContinuation<Void, Never>?

    private func injectIceServers(_ iceServerURLs: [String]) async throws {
        let jsArray = iceServerURLs.map { "\"\($0)\"" }.joined(separator: ",")
        let js = "window.__ICE_SERVERS__ = [\(jsArray)];"
        _ = try await contentView.callAsyncJavaScript(js, contentWorld: .page)
    }

    private func startNegotiation() async throws -> String {
        let raw = try await contentView.callAsyncJavaScript(
            "return await window.startNegotiation();",
            contentWorld: .page
        )
        guard let sdp = raw as? String, !sdp.isEmpty else {
            throw DoorVideoSessionError.negotiationFailed
        }

        // Cheap, permanent diagnostic (not a page round trip): confirms
        // the non-trickle offer actually carries ICE candidates before it
        // is PUT to rtc/offer, which -- verified against real hardware for
        // gateopener-12h.3 -- it reliably does (the page's own
        // iceGatheringState-complete wait in negotiate() already blocks
        // `startNegotiation()`'s Promise from resolving until gathering
        // finishes, so no separate Swift-side poll is needed here).
        let candidateCount = sdp.components(separatedBy: "a=candidate:").count - 1
        Self.logger.notice("offer SDP ready: \(sdp.count) chars, \(candidateCount, privacy: .public) ICE candidates")

        return sdp
    }

    private func applyAnswer(_ answerSDP: String) async throws {
        // Escape backslashes/backticks/`$` so the SDP can be embedded in a
        // JS template literal without breaking out of it or triggering
        // template-literal interpolation.
        let escaped = answerSDP
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let js = "return await window.applyAnswer(`\(escaped)`);"
        _ = try await contentView.callAsyncJavaScript(js, contentWorld: .page)
    }

    /// Polls `window.getState()` for `hasVideoFrame` becoming true, then
    /// transitions to `.streaming`. This is the ONLY polling this type
    /// does — there is no ongoing stale-frame watchdog (out of scope; see
    /// gateopener-12h.4).
    private func watchForFirstFrame() {
        streamingPollTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(20)
            var lastLoggedState = ""
            while Date() < deadline {
                if Task.isCancelled { return }
                guard !self.hasStopped else { return }

                // Primary signal: pc.getStats()'s inbound-rtp video report
                // (framesDecoded/packetsReceived), NOT the page's
                // requestVideoFrameCallback-driven hasVideoFrame flag.
                // Verified against real hardware (gateopener-12h.3
                // investigation): the peer connection can report
                // framesDecoded in the hundreds -- real, decoded video --
                // while requestVideoFrameCallback never fires and
                // video.videoWidth/videoHeight stay 0, so hasVideoFrame is
                // an unreliable signal in this WKWebView context (likely
                // WebKit-specific requestVideoFrameCallback flakiness, not
                // a negotiation problem -- negotiation/ICE/DTLS all
                // succeed). getStats() is the ground truth the WebRTC spec
                // guarantees; the <video> element's own frame-callback API
                // is not.
                do {
                    let raw = try await self.contentView.callAsyncJavaScript(
                        "return await window.getVideoStats();",
                        contentWorld: .page
                    )
                    if let jsonStr = raw as? String {
                        if jsonStr != lastLoggedState {
                            lastLoggedState = jsonStr
                            Self.logger.notice("video stats: \(jsonStr, privacy: .public)")
                        }
                        if let data = jsonStr.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let video = obj["video"] as? [String: Any],
                           let framesDecoded = video["framesDecoded"] as? Int, framesDecoded > 0 {
                            self.state = .streaming
                            return
                        }
                    }
                } catch {
                    // Transient eval errors while polling are not fatal on
                    // their own; keep polling until the deadline.
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !self.hasStopped else { return }
            self.state = .failed(message: "No video received")
        }
    }

    // MARK: - rtc/offer (Swift-side; the bearer token never reaches page JS)

    private struct OfferResponse: Decodable { let answer: String }

    private func putOffer(endpointId: String, token: String, sdp: String, sessionId: String) async throws -> String {
        // '#' -> %23 only, matching the proven recipe (NOT full percent
        // encoding, which the door's signaling backend does not expect).
        let encodedEndpoint = endpointId.replacingOccurrences(of: "#", with: "%23")
        guard let url = URL(string: "\(ComelitAPI.baseURL)/servicerest/devicecom/endpoint/\(encodedEndpoint)/rtc/offer") else {
            throw DoorVideoSessionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("ktor-client", forHTTPHeaderField: "user-agent")
        let body: [String: String] = ["sessionId": sessionId, "offer": sdp]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DoorVideoSessionError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw DoorVideoSessionError.network
        }
        guard http.statusCode == 200 else {
            throw DoorVideoSessionError.server(status: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(OfferResponse.self, from: data)
        return decoded.answer
    }

    /// Wraps `putOffer` with a bounded retry, matching a real-world
    /// observation from the reference iOS app: `rtc/offer` sometimes
    /// returns a TRANSIENT HTTP 500 that a second attempt clears, so a
    /// single 500 is not necessarily proof of a malformed offer.
    ///
    /// Reuses `GateOpenerCore.RetryPolicy` (the same type `GateClient`
    /// itself is built on) rather than inventing a second retry mechanism
    /// — `DoorVideoSession` already imports `GateOpenerCore`, so this is a
    /// same-module reuse, not a new dependency.
    ///
    ///  - 2 attempts total (1 retry), matching the reference app's observed
    ///    behavior — NOT an aggressive/unbounded loop against the door.
    ///  - Retries ONLY on HTTP 500 and transport/network errors
    ///    (`DoorVideoSessionError.network`); any other HTTP status (4xx, or
    ///    a non-500 5xx) is treated as non-retryable and rethrown
    ///    immediately, since retrying an auth/shape problem will not fix it.
    ///  - A FRESH `sessionId` (uuid4) is minted for the retry attempt, per
    ///    the bead's requirement. The SAME offer SDP is reused across
    ///    attempts (deliberately NOT regenerated): the SDP's ICE
    ///    ufrag/password and DTLS fingerprint are tied to the single
    ///    `RTCPeerConnection` already created and gathered in the page, and
    ///    Comelit's `sessionId` is the field that scopes one negotiation
    ///    attempt from the next — nothing about a transient 500 implies the
    ///    offer itself was malformed. Regenerating the offer would require
    ///    tearing down and rebuilding the whole peer connection (a second
    ///    ICE-gathering round trip), which is unwarranted extra latency and
    ///    complexity for what the reference app treats as a quick retry.
    ///  - Backoff is a few hundred ms (`RetryPolicy.baseDelay`), bounded by
    ///    `maxTotalDelay`, so the retry cannot meaningfully add to the
    ///    human-facing wait.
    private func putOfferWithRetry(endpointId: String, token: String, sdp: String) async throws -> String {
        let policy = RetryPolicy(
            maxAttempts: 2,
            baseDelay: .milliseconds(500),
            maxTotalDelay: .seconds(2),
            requestTimeout: .seconds(5)
        )

        var lastError: Error = DoorVideoSessionError.network
        for attempt in 1...policy.maxAttempts {
            let sessionId = UUID().uuidString.lowercased()
            do {
                let answer = try await putOffer(endpointId: endpointId, token: token, sdp: sdp, sessionId: sessionId)
                Self.logger.notice("rtc/offer attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public) succeeded")
                return answer
            } catch {
                lastError = error
                let retryable: Bool
                if case DoorVideoSessionError.server(let status) = error, status == 500 {
                    retryable = true
                } else if case DoorVideoSessionError.network = error {
                    retryable = true
                } else {
                    retryable = false
                }
                Self.logger.notice("rtc/offer attempt \(attempt, privacy: .public)/\(policy.maxAttempts, privacy: .public) failed: \(String(describing: error), privacy: .public), retryable=\(retryable, privacy: .public)")

                guard retryable, attempt < policy.maxAttempts else {
                    throw error
                }
                try? await policy.sleep(policy.baseDelay)
            }
        }
        throw lastError
    }
}

// MARK: - Errors

enum DoorVideoSessionError: Error, Equatable {
    case cameraNotFound
    case negotiationFailed
    case invalidURL
    case network
    case server(status: Int)
}

// MARK: - WKNavigationDelegate

extension DoorVideoSession: WKNavigationDelegate {
    public nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.pageLoadContinuation?.resume()
            self.pageLoadContinuation = nil
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.pageLoadContinuation?.resume()
            self.pageLoadContinuation = nil
        }
    }

    public nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.pageLoadContinuation?.resume()
            self.pageLoadContinuation = nil
        }
    }
}

// MARK: - OverlayShowHideResponding

/// Conforms so `DoorVideoSession.contentView` is directly installable via
/// `OverlayWindowController.setContent(_:)`: the panel already fires
/// `overlayWillShow()`/`overlayDidHide()` on content conforming to this
/// protocol when it is shown/hidden, and this type does not need a second
/// wrapper view to participate. Neither hook drives playback here (unlike
/// `GateOpenVideoView`, which restarts a local clip on every show) since
/// this type's session lifecycle is owned entirely by `start()`/`stop()` —
/// a later bead (gateopener-12h.5) decides how overlay visibility maps to
/// starting/stopping a session.
extension DoorVideoSession: OverlayShowHideResponding {
    public func overlayWillShow() {}
    public func overlayDidHide() {}
}
