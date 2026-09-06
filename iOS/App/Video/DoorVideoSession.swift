import AVFoundation
import Foundation
import GateOpenerCore
import Network
import WebKit
import os

/// The full state of an iOS `DoorVideoSession`, as far as the UI needs to
/// know. Named `State` (nested, not `DoorVideoSessionState`) since this type
/// is not exposed outside `DoorVideoSession` and the app target has no
/// competing top-level type of that name — contrast the macOS
/// `Sources/GateOpener/DoorVideoSession.swift`, which is a free enum.
extension DoorVideoSession {
    public enum State: Equatable, Sendable {
        /// Nothing has happened yet; `start()` has not been called.
        case idle
        /// `start()` is in flight: resolving a token, discovering the
        /// camera endpoint, negotiating, and waiting for the `rtc/offer`
        /// round trip.
        case connecting
        /// The peer connection is up and the door is sending live frames
        /// (per the "frame" message-handler liveness channel, NOT ICE
        /// state — see this type's doc comment).
        case streaming
        /// The session ended normally: `stop()` was called, the door's
        /// ~28-30s streaming window elapsed, or the liveness detector
        /// declared a stall.
        case ended
        /// The session could not be established, or ended abnormally.
        /// `String` is a SHORT, human-readable message safe to show
        /// directly in UI — never a raw error dump.
        case failed(String)
    }
}

extension DoorVideoSession.State {
    /// Maps this app-layer state down to `GateOpenerCore`'s payload-free
    /// `DoorVideoSessionPhase`, mirroring the macOS
    /// `DoorVideoSessionState.phase` mapping (see that file's doc comment).
    /// Deliberately exhaustive with NO `default` clause.
    var phase: DoorVideoSessionPhase {
        switch self {
        case .idle: return .idle
        case .connecting: return .connecting
        case .streaming: return .streaming
        case .ended: return .ended
        case .failed: return .failed
        }
    }
}

/// Establishes and owns exactly ONE live WebRTC session against the Comelit
/// door camera on iOS, driven by WKWebView's own WebRTC stack (NOT
/// libwebrtc — see bd memory `gateopener-yjn-spike-result-wkwebview-webkit-
/// s-own`: WebKit's independent implementation receives real RTP from the
/// door station).
///
/// Unlike the macOS counterpart (`Sources/GateOpener/DoorVideoSession.swift`,
/// which polls a hidden `<canvas>` for JPEG frames because its host window
/// is a never-key `NSPanel`), the iOS window IS key, so the page's `<video>`
/// element is displayed DIRECTLY inside `webView` — no canvas capture, no
/// frame-polling loop. Liveness is instead driven by a `WKScriptMessageHandler`
/// channel ("frame") that the page's own `requestVideoFrameCallback` loop
/// posts to at ~2Hz (see `Resources/door-video.html`).
///
/// ## The recipe (load-bearing, proven against real hardware — do not
/// improvise any element of this; see bd memories
/// `gateopener-live-video-architecture`, `gateopener-yjn-spike-result-
/// wkwebview-webkit-s-own`)
///
///  - `Resources/door-video.html` builds recvonly audio+video transceivers,
///    AUDIO ADDED BEFORE VIDEO, plus a `createDataChannel('data')`.
///  - Non-trickle ICE: the page waits for `iceGatheringState === 'complete'`
///    before returning the offer SDP.
///  - Comelit's STUN host is pre-resolved to IPs in Swift
///    (`resolveStunIPs`) and injected as `window.__ICE_SERVERS__` before
///    the page negotiates.
///  - The `rtc/offer` PUT is issued from Swift via `URLSession`, using a
///    token obtained through `GateOpenerCore`'s `TokenManager`. THE BEARER
///    TOKEN NEVER REACHES PAGE JS — only the offer/answer SDP strings cross
///    the Swift/JS boundary.
///  - `'#'` in the endpoint id is replaced with `%23` only before building
///    the `rtc/offer` URL.
///  - NEVER use ICE connection state to end a session: ICE stays
///    "connected" for ~10s after the door actually stops sending media
///    (measured on macOS against the same hardware/protocol).
///
/// ## GOTCHA
///
/// Plain `evaluateJavaScript(_:)` fails with `WKErrorDomain` code 5
/// ("unsupported type") on ANY Promise-returning expression. Every async
/// call into the page uses `callAsyncJavaScript(_:contentWorld:)` with an
/// explicit `return await ...;` body instead.
@MainActor
public final class DoorVideoSession: NSObject {
    private static let logger = Logger(subsystem: "ie.boboco.GateOpener", category: "video")

    /// The friendly-name substring (case-insensitive) used to pick the door
    /// camera endpoint out of discovery results.
    private static let cameraFriendlyNameHint = "entry"

    /// The known door-camera endpoint id suffix, used as a fallback when no
    /// endpoint's `friendlyName` matches `cameraFriendlyNameHint`.
    private static let cameraEndpointIdSuffix = "VIP#EN#SB100001"

    private static let stunHost = "stun.cloud.comelitgroup.com"
    private static let stunPort = 3478

    /// Hard ceiling on total session length, matching the door's own
    /// ~28-30s streaming window plus slack — measured on macOS against the
    /// same hardware/protocol (bd memory `gateopener-live-video-
    /// architecture`). This is a BACKSTOP only; the liveness detector
    /// (stall on no new frame) is expected to fire first in the normal
    /// case where the door cuts the stream on schedule.
    private static let hardTimeout: TimeInterval = 35

    /// How long with no new "frame" message before the session is declared
    /// stalled and ended. Matches the plateau-detection intent of
    /// `GateOpenerCore.DoorVideoLiveness` (macOS drives the same decision
    /// off RTP counter progress instead, since it has no direct per-frame
    /// callback channel into a displayed `<video>` element).
    private static let plateauInterval: TimeInterval = 6

    /// The `WKWebView` hosting `door-video.html`. Exposed directly (rather
    /// than wrapped in a custom view) because the `<video>` element inside
    /// the page is displayed DIRECTLY on iOS — see this type's doc comment
    /// for why that differs from the macOS canvas-capture approach.
    public let webView: WKWebView

    /// Current state; mutating this always invokes `onStateChange`.
    public private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    /// Invoked on every state transition. Always invoked on the main actor.
    public var onStateChange: ((State) -> Void)?

    private let tokenManager: TokenManager
    private let gateClient: any GateOpening
    private let appSettings: AppSettings
    private let urlSession: URLSession

    /// Guards `stop()` idempotency and lets `start()`'s in-flight guards
    /// (`guard !hasStopped else { return }`) bail out promptly if `stop()`
    /// races an in-progress `start()`. `start()` itself is re-entrant per
    /// `GateOpenerCore.DoorVideoSessionRetention` — see that method's doc
    /// comment — rather than guarded by a separate "already started" flag.
    private var hasStopped = false

    private var pageLoadContinuation: CheckedContinuation<Void, Never>?

    /// Timestamp (wall-clock) of the most recent "frame" message received
    /// from the page, or the session start time if none has arrived yet.
    /// Used by the liveness watchdog to detect a stall.
    private var lastFrameAt: Date?

    /// Wall-clock time `start()` began negotiating, used for the hard
    /// timeout.
    private var sessionStartedAt: Date?

    /// Polls for liveness (new "frame" messages) and enforces the hard
    /// timeout; cancelled by `stop()`.
    private var livenessTask: Task<Void, Never>?

    #if DEBUG
    /// Set only by `debugStub(connectingDelay:streamingDuration:)` below.
    /// When non-`nil`, `start()` skips ALL real work (no network, no
    /// WKWebView page load, no token resolution) and instead runs this
    /// canned `.connecting` -> `.streaming` -> `.ended` timeline — see that
    /// factory's doc comment.
    private var debugStubTimeline: (connectingDelay: TimeInterval, streamingDuration: TimeInterval)?
    #endif

    /// - Parameter appSettings: Supplies `cachedGates` — the last
    ///   locally-persisted discovery result (`GateController.discover()`
    ///   writes it; see that type and `AppSettings.cachedGates`'s doc
    ///   comments) — so `resolveCameraEndpointId()` can answer "is there a
    ///   camera?" without a network call when a camera was already found by
    ///   a previous discovery. See that method's doc comment for the full
    ///   cache-then-live-discovery policy.
    public init(
        tokenManager: TokenManager,
        gateClient: any GateOpening,
        appSettings: AppSettings,
        urlSession: URLSession = .shared
    ) {
        self.tokenManager = tokenManager
        self.gateClient = gateClient
        self.appSettings = appSettings
        self.urlSession = urlSession

        let config = WKWebViewConfiguration()
        // Without these two, iOS refuses to autoplay the <video> element
        // inline and the view stays permanently black: WKWebView defaults
        // to requiring an explicit user gesture before ANY media plays, and
        // to allowing playback only fullscreen unless inline playback is
        // explicitly opted into.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // The stream is recvonly/muted (v1 has no door audio) and shown
        // inline in the app's own UI; Picture in Picture would only ever
        // be a confusing, unwanted affordance here.
        config.allowsPictureInPictureMediaPlayback = false

        let contentController = WKUserContentController()
        config.userContentController = contentController

        self.webView = WKWebView(frame: .zero, configuration: config)

        super.init()

        webView.navigationDelegate = self
        // Registered via a weak-referencing shim (`ScriptMessageForwarder`
        // below), NOT `self` directly: `WKUserContentController.add(_:
        // name:)` retains its handler strongly, and the content controller
        // is itself owned (via `webView.configuration`) by `webView`, which
        // `self` owns — registering `self` directly would be a permanent
        // retain cycle (`self` -> `webView` -> `contentController` ->
        // `self`) that only `removeScriptMessageHandler` breaks, which
        // nothing before this class would ever call.
        contentController.add(ScriptMessageForwarder(target: self), name: "frame")
    }

    deinit {
        // `stop()` is @MainActor and this type is always used on the main
        // actor per its own @MainActor annotation, but `deinit` itself is
        // `nonisolated` under Swift 6 — there is nothing further to release
        // here beyond what ARC already tears down. Callers are expected to
        // call `stop()` explicitly before releasing their last reference so
        // teardown (peer connection close) is deterministic rather than
        // relying on `deinit` timing.
    }

    // MARK: - start()

    /// Establishes a WebRTC session, unless one is already
    /// connecting/streaming (in which case this call is a retained no-op —
    /// `GateOpenerCore.DoorVideoSessionRetention.decision(forExistingPhase:)`
    /// applied against this instance's own `state.phase`, since a
    /// `DoorVideoSession` only ever represents one logical session slot,
    /// matching the retain-vs-replace policy `OverlayWindowController`
    /// applies to a whole session INSTANCE on macOS). `.idle` (never
    /// started) and a second `start()` after `.ended`/`.failed` both
    /// `.replace`, i.e. run a fresh session.
    ///
    /// Never throws: all failure paths are reported via `state`.
    public func start() async {
        switch DoorVideoSessionRetention.decision(forExistingPhase: state.phase) {
        case .retain:
            Self.logger.notice("start() called while \(String(describing: self.state), privacy: .public); retaining existing session")
            return
        case .replace:
            break
        }

        // Reset per-session instance state so a second start() (after
        // .ended/.failed) behaves like a fresh instance would.
        hasStopped = false
        lastFrameAt = nil
        livenessTask?.cancel()
        livenessTask = nil

        #if DEBUG
        if let timeline = debugStubTimeline {
            await runDebugStubTimeline(timeline)
            return
        }
        #endif

        state = .connecting

        guard let endpointId = try? await resolveCameraEndpointId() else {
            // No camera endpoint discovered: fail immediately. See
            // `resolveCameraEndpointId()`'s doc comment — when a camera was
            // already known from a previous discovery
            // (`appSettings.cachedGates`), this makes NO network call at
            // all; only a genuinely stale/empty cache falls through to a
            // live discovery round trip.
            state = .failed("No camera")
            return
        }

        guard let pageURL = Bundle.main.url(forResource: "door-video", withExtension: "html") else {
            Self.logger.notice("door-video.html not found in bundle; DoorVideoSession cannot start")
            state = .failed("Video page unavailable")
            return
        }

        let token: String
        do {
            token = try await tokenManager.accessToken()
        } catch TokenManagerError.notConfigured {
            state = .failed("Sign-in required")
            return
        } catch {
            state = .failed("Could not get access token")
            return
        }

        guard !hasStopped else { return }

        let resolvedStunAddresses = Self.resolveStunAddresses(host: Self.stunHost)
        let iceServerURLs = Self.iceServerURLs(host: Self.stunHost, port: Self.stunPort, resolved: resolvedStunAddresses)
        let pathSummary = Self.currentPathSummary()
        Self.logger.info("STUN ICE servers: \(iceServerURLs, privacy: .public); path: \(pathSummary, privacy: .public)")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.pageLoadContinuation = continuation
            self.webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }

        guard !hasStopped else { return }

        do {
            try await injectIceServers(iceServerURLs)
        } catch {
            state = .failed("Video page failed to load")
            return
        }

        guard !hasStopped else { return }

        let offerSDP: String
        do {
            offerSDP = try await startNegotiation()
        } catch {
            state = .failed("Could not negotiate video session")
            return
        }

        guard !hasStopped else { return }

        let answerSDP: String
        do {
            answerSDP = try await putOfferWithRetry(endpointId: endpointId, token: token, sdp: offerSDP)
        } catch {
            Self.logger.error("rtc/offer failed after retry: \(String(describing: error), privacy: .public)")
            state = .failed("Could not reach door camera")
            return
        }

        guard !hasStopped else { return }

        do {
            try await applyAnswer(answerSDP)
        } catch {
            state = .failed("Could not apply video answer")
            return
        }

        guard !hasStopped else { return }

        // .ambient: recvonly + muted <video> never plays audible sound, but
        // the session categorizes itself as ambient anyway so it can NEVER
        // interrupt the operator's own music/podcast — the audio session
        // route is otherwise left entirely alone.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)

        sessionStartedAt = Date()
        startLivenessWatchdog()
    }

    // MARK: - stop()

    /// Tears down the peer connection and blanks the page so no session or
    /// decoder leaks. Idempotent: safe to call multiple times, and safe to
    /// call even if `start()` was never called or is still in flight.
    public func stop() {
        guard !hasStopped else { return }
        hasStopped = true

        livenessTask?.cancel()
        livenessTask = nil

        pageLoadContinuation?.resume()
        pageLoadContinuation = nil

        // Fire-and-forget: best-effort teardown of the RTCPeerConnection
        // inside the page, plus blanking the <video> element. Errors here
        // are logged, never surfaced (the session is ending regardless).
        Task { [weak webView] in
            guard let webView else { return }
            _ = try? await webView.callAsyncJavaScript(
                "return window.closeSession ? window.closeSession() : null;",
                contentWorld: .page
            )
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "frame")

        if case .failed = state {
            // Preserve a failure reason already reported rather than
            // clobbering it with a generic "ended".
            return
        }
        state = .ended
    }

    // MARK: - Camera endpoint selection

    /// Selects the door camera endpoint: `friendlyName` containing "entry"
    /// (case-insensitive) takes priority; otherwise the first endpoint
    /// whose id ends with the known camera id suffix (`VIP#EN#SB100001`,
    /// matched as the final `_`-separated id component). Mirrors the macOS
    /// `DoorVideoSession.resolveCameraEndpointId()`/
    /// `endpointIdMatchesCameraSuffix` matching logic exactly.
    ///
    /// Cache-then-live-discovery policy (the "no camera -> `.failed`
    /// immediately, with no network call" edge case from this bead):
    /// `appSettings.cachedGates` — the last locally-persisted discovery
    /// result `GateController.discover()` already wrote, a synchronous,
    /// no-network read — is checked FIRST. If it already contains a camera
    /// match, that endpoint id is returned immediately with zero network
    /// calls. Only when the cache is empty or has no camera match does this
    /// fall back to a live `gateClient.discover(aptId:)` round trip (the
    /// cache may simply be stale/never populated, e.g. first run before
    /// Settings has ever loaded gates) — a live "no camera anywhere" result
    /// is what throws `DoorVideoSessionError.cameraNotFound`.
    private func resolveCameraEndpointId() async throws -> String {
        if let cached = Self.findCameraEndpointId(in: appSettings.cachedGates) {
            return cached
        }

        let endpoints = try await gateClient.discover(aptId: nil)
        guard let found = Self.findCameraEndpointId(in: endpoints) else {
            throw DoorVideoSessionError.cameraNotFound
        }
        return found
    }

    /// Pure lookup shared by both the cache-check and live-discovery paths
    /// of `resolveCameraEndpointId()`: `friendlyName` containing "entry"
    /// (case-insensitive) takes priority; otherwise the first endpoint
    /// whose id ends with `cameraEndpointIdSuffix`.
    private static func findCameraEndpointId(in endpoints: [Endpoint]) -> String? {
        if let byName = endpoints.first(where: {
            $0.friendlyName.range(of: Self.cameraFriendlyNameHint, options: .caseInsensitive) != nil
        }) {
            return byName.endpointId
        }
        if let byId = endpoints.first(where: { Self.endpointIdMatchesCameraSuffix($0.endpointId) }) {
            return byId.endpointId
        }
        return nil
    }

    /// Robustly test whether `endpointId`'s final `_`-separated component
    /// case-insensitively equals `cameraEndpointIdSuffix`. Mirrors macOS's
    /// `DoorVideoSession.endpointIdMatchesCameraSuffix` exactly.
    private static func endpointIdMatchesCameraSuffix(_ endpointId: String) -> Bool {
        let trimmed = endpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastComponent = trimmed.components(separatedBy: "_").last else { return false }
        return lastComponent.caseInsensitiveCompare(cameraEndpointIdSuffix) == .orderedSame
    }

    // MARK: - STUN pre-resolution

    /// Resolves `host` to its addresses via `getaddrinfo`, so the page can
    /// be handed real `stun:<ip>:3478`/`stun:[<ip6>]:3478` URLs alongside
    /// the hostname form. Unlike macOS's IPv4-only
    /// `DoorVideoSession.resolveStunIPs`, this resolves with
    /// `ai_family = AF_UNSPEC` and `ai_flags = AI_DEFAULT`
    /// (`AI_V4MAPPED_CFG | AI_ADDRCONFIG` on iOS): on an IPv6-only/NAT64
    /// cellular network, this makes the resolver SYNTHESIZE an IPv6 address
    /// for this IPv4-only host, giving WKWebView's ICE gathering a route to
    /// an actual STUN response where a bare IPv4 literal would silently
    /// fail (root cause of bead gateopener-672.28: video works over
    /// STUN-only on IPv4 Wi-Fi/hotel networks but fails on cellular).
    /// Returns `[]` (never throws) on any resolution failure — the caller
    /// still injects the hostname-form entry regardless (see
    /// `iceServerURLs`).
    private nonisolated static func resolveStunAddresses(host: String) -> [(family: Int32, address: String)] {
        var hints = addrinfo(
            ai_flags: AI_DEFAULT, ai_family: AF_UNSPEC, ai_socktype: SOCK_DGRAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        var addresses: [(family: Int32, address: String)] = []
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return addresses }
        defer { freeaddrinfo(first) }
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let p = ptr {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(p.pointee.ai_addr, p.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let family = p.pointee.ai_family
                if !address.isEmpty, !addresses.contains(where: { $0.family == family && $0.address == address }) {
                    addresses.append((family: family, address: address))
                }
            }
            ptr = p.pointee.ai_next
        }
        return addresses
    }

    /// Pure formatting/ordering helper (unit-tested directly in
    /// `IceServerURLTests`): builds the final `stun:` URL list injected as
    /// `window.__ICE_SERVERS__`. Order is significant only insofar as the
    /// hostname form is tried first (WebKit resolves it itself, including
    /// NAT64 synthesis — the HTTP-500-on-hostname problem documented in bd
    /// memory `gateopener-yjn-spike-*` was Chromium-specific and was never
    /// observed in WKWebView), then IPv6/synthesized literals (bracketed
    /// per RFC 3986), then IPv4 literals — never empty, since the hostname
    /// entry is unconditional.
    nonisolated static func iceServerURLs(host: String, port: Int, resolved: [(family: Int32, address: String)]) -> [String] {
        var urls: [String] = ["stun:\(host):\(port)"]

        for entry in resolved where entry.family == AF_INET6 {
            let url = "stun:[\(entry.address)]:\(port)"
            if !urls.contains(url) { urls.append(url) }
        }
        for entry in resolved where entry.family == AF_INET {
            let url = "stun:\(entry.address):\(port)"
            if !urls.contains(url) { urls.append(url) }
        }

        return urls
    }

    /// One-shot, cheap `NWPath` snapshot for the ICE-server log line only
    /// (optional per this bead's brief). `NWPathMonitor.currentPath` is a
    /// synchronous, non-blocking read of whatever path the monitor already
    /// knows about at construction time — unlike `NWPathMonitorReachability`
    /// (this app's long-lived reachability source elsewhere), there is no
    /// `start(queue:)`/handler/wait here, so this can safely run on the
    /// main actor inside `start()`.
    private static func currentPathSummary() -> String {
        let path = NWPathMonitor().currentPath
        return "ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6)"
    }

    // MARK: - Page bridging (all async calls MUST use callAsyncJavaScript,
    // never evaluateJavaScript — see the GOTCHA in the type doc comment)

    private func injectIceServers(_ iceServerURLs: [String]) async throws {
        let jsArray = iceServerURLs.map { "\"\($0)\"" }.joined(separator: ",")
        let js = "window.__ICE_SERVERS__ = [\(jsArray)];"
        _ = try await webView.callAsyncJavaScript(js, contentWorld: .page)
    }

    private func startNegotiation() async throws -> String {
        let raw = try await webView.callAsyncJavaScript(
            "return await window.startNegotiation();",
            contentWorld: .page
        )
        guard let sdp = raw as? String, !sdp.isEmpty else {
            throw DoorVideoSessionError.negotiationFailed
        }
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
        _ = try await webView.callAsyncJavaScript(js, contentWorld: .page)
    }

    // MARK: - Liveness watchdog

    /// Watches for new "frame" messages (see `userContentController(_:
    /// didReceive:)` below) and ends the session on a stall
    /// (`plateauInterval` with no new frame) or the hard timeout —
    /// NEVER on ICE connection state, per this type's doc comment and bd
    /// memory `gateopener-live-video-architecture` (ICE can stay
    /// "connected" for ~10s after the door actually stops sending media).
    private func startLivenessWatchdog() {
        livenessTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let self, !self.hasStopped else { return }

                let now = Date()
                if let startedAt = self.sessionStartedAt, now.timeIntervalSince(startedAt) >= Self.hardTimeout {
                    Self.logger.notice("hard timeout (\(Self.hardTimeout, privacy: .public)s) reached; ending session")
                    self.endDueToLiveness()
                    return
                }

                guard let lastFrameAt = self.lastFrameAt else {
                    // No frame has arrived yet; only the hard timeout above
                    // (not the plateau interval) applies until the first
                    // frame is seen, matching `DoorVideoLiveness
                    // .rtpCountersShowProgress`'s "a nil baseline must not
                    // count as progress OR as an immediate stall" guard —
                    // a session that never receives any frame at all still
                    // needs to end via the hard timeout, not a premature
                    // plateau firing before any frame was ever possible.
                    continue
                }
                if now.timeIntervalSince(lastFrameAt) >= Self.plateauInterval {
                    Self.logger.notice("no new frame for \(Self.plateauInterval, privacy: .public)s; ending session (stall)")
                    self.endDueToLiveness()
                    return
                }
            }
        }
    }

    /// Common teardown for both stall and hard-timeout endings: runs the
    /// same JS teardown/blank as `stop()` and transitions to `.ended`
    /// (never `.failed` — the door closing its own ~28-30s window, or a
    /// genuine stall, is a NORMAL end of session, not an error).
    private func endDueToLiveness() {
        guard !hasStopped else { return }
        hasStopped = true

        pageLoadContinuation?.resume()
        pageLoadContinuation = nil

        Task { [weak webView] in
            guard let webView else { return }
            _ = try? await webView.callAsyncJavaScript(
                "return window.closeSession ? window.closeSession() : null;",
                contentWorld: .page
            )
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "frame")

        state = .ended
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
            (data, response) = try await urlSession.data(for: request)
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

    /// Wraps `putOffer` with a bounded retry — same semantics as macOS's
    /// `DoorVideoSession.putOfferWithRetry`: 2 attempts total, retryable
    /// only on HTTP 500/network errors, a fresh `sessionId` per attempt,
    /// the SAME offer SDP reused across attempts.
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

#if DEBUG
extension DoorVideoSession {
    /// Builds a `DoorVideoSession` that never touches the network or loads
    /// `door-video.html`: `start()` instead runs a canned
    /// `.connecting` -> `.streaming` -> `.ended` timeline, driven purely by
    /// `Task.sleep`. Used by `--mock-video` (`DebugLaunchOptions`) so the
    /// door-video panel (bead gateopener-672.12) can be exercised on the
    /// simulator, where `--mock-gate`'s `cachedGates` has no camera
    /// endpoint and a real `DoorVideoSession` would fail fast with "No
    /// camera".
    ///
    /// The real dependencies (`tokenManager`, `gateClient`, `appSettings`)
    /// are still required by `init` but are never exercised by the stub
    /// timeline, so throwaway-but-real instances are constructed here
    /// rather than widening `init`'s parameters to optionals for a
    /// DEBUG-only path.
    ///
    /// - Parameters:
    ///   - connectingDelay: How long `state` stays `.connecting` before
    ///     flipping to `.streaming`. Defaults to 2s.
    ///   - streamingDuration: How long `state` stays `.streaming` before
    ///     flipping to `.ended`. Defaults to 8s.
    public static func debugStub(
        connectingDelay: TimeInterval = 2,
        streamingDuration: TimeInterval = 8
    ) -> DoorVideoSession {
        let session = DoorVideoSession(
            tokenManager: TokenManager(api: ComelitAPI(), credentialStore: DebugStubNullCredentialStore()),
            gateClient: DebugStubNullGateOpening(),
            appSettings: AppSettings(defaults: UserDefaults(suiteName: "ie.boboco.GateOpener.debugStub") ?? .standard)
        )
        session.debugStubTimeline = (connectingDelay: connectingDelay, streamingDuration: streamingDuration)
        return session
    }

    /// Runs the canned timeline installed by `debugStub`. Never touches
    /// `webView`/network/JS bridging — `state` transitions are the only
    /// observable effect, matching what `DoorVideoView` needs to render the
    /// "Connecting…" overlay and then the (blank, since no real page is
    /// loaded) streaming state.
    fileprivate func runDebugStubTimeline(_ timeline: (connectingDelay: TimeInterval, streamingDuration: TimeInterval)) async {
        state = .connecting
        try? await Task.sleep(for: .seconds(timeline.connectingDelay))
        guard !hasStopped else { return }

        state = .streaming
        try? await Task.sleep(for: .seconds(timeline.streamingDuration))
        guard !hasStopped else { return }

        hasStopped = true
        state = .ended
    }
}

/// Throwaway `CredentialStoring` used only by `debugStub` — never actually
/// called, since the stub timeline never resolves a token.
private struct DebugStubNullCredentialStore: CredentialStoring {
    func saveCredentials(username: String, password: String) throws {}
    func loadCredentials() throws -> (username: String, password: String)? { nil }
    func deleteCredentials() throws {}
    func saveTokens(_ tokens: TokenSet) throws {}
    func loadTokens() throws -> TokenSet? { nil }
    func deleteTokens() throws {}
}

/// Throwaway `GateOpening` used only by `debugStub` — never actually called,
/// since the stub timeline never discovers or opens anything.
private struct DebugStubNullGateOpening: GateOpening {
    func discover(aptId: String?) async throws -> [Endpoint] { [] }
    func open(endpointId: String) async throws {}
}
#endif

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

// MARK: - "frame" liveness channel

/// Receives "frame" messages on behalf of a `DoorVideoSession` without the
/// session itself being retained by `WKUserContentController` (see
/// `DoorVideoSession.init`'s doc comment on why `add(_:name:)` is never
/// given `self` directly).
private final class ScriptMessageForwarder: NSObject, WKScriptMessageHandler {
    private weak var target: DoorVideoSession?

    init(target: DoorVideoSession) {
        self.target = target
    }

    /// Receives a "frame" message every time the page's
    /// `requestVideoFrameCallback` loop posts one (throttled to ~2Hz in
    /// `door-video.html`). Records `Date()` (the Swift-side receipt time,
    /// not the page's `now` timestamp — the two clocks are not directly
    /// comparable and only the RELATIVE gap between successive Swift-side
    /// receipts matters for stall detection) and, on the first frame,
    /// transitions `.connecting` -> `.streaming`.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "frame" else { return }
        Task { @MainActor [weak target] in
            target?.recordFrameReceived()
        }
    }
}

extension DoorVideoSession {
    /// Called (on the main actor) by `ScriptMessageForwarder` on every
    /// "frame" message; see that type's doc comment. Internal surface only
    /// so the forwarder can drive it despite `lastFrameAt`/`state`/
    /// `hasStopped` being otherwise private. No-ops once the session has
    /// stopped (mirrors every other post-`stop()` guard in this file).
    fileprivate func recordFrameReceived() {
        guard !hasStopped else { return }
        lastFrameAt = Date()
        if state == .connecting {
            state = .streaming
        }
    }
}
