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
///  - Comelit's STUN host is pre-resolved to IPs via
///    `GateOpenerCore.IceServerList` (shared with macOS, bead
///    gateopener-6s8.5) and injected as `window.__ICE_SERVERS__` before
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

    /// How long after `sessionStartedAt` with NO frame ever having arrived
    /// before the session is declared failed (as opposed to a stall, which
    /// only applies once at least one frame has been seen — see
    /// `livenessVerdict(elapsedSinceStart:sinceLastFrame:hardTimeout:plateau:
    /// firstFrameTimeout:)`). This is the "rtc/offer succeeded (HTTP 200 +
    /// answer applied) but the door never actually sends media" case from
    /// bead gateopener-12h.10 (2 of 5 rapid reopens got 200 but zero
    /// frames). Matches `../comelit`'s `FIRST_FRAME_TIMEOUT_SECONDS`.
    ///
    /// Instance-level (not `static`) so it is injectable per-session for
    /// tests, but every real call site relies on the default.
    private let firstFrameTimeout: TimeInterval

    /// The `WKWebView` hosting `door-video.html`. Exposed directly (rather
    /// than wrapped in a custom view) because the `<video>` element inside
    /// the page is displayed DIRECTLY on iOS — see this type's doc comment
    /// for why that differs from the macOS canvas-capture approach.
    public let webView: WKWebView

    /// Current state; mutating this always invokes `onStateChange`.
    public private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            diagnostics.append("[\(Self.diagTimestamp())] state: \(oldValue) -> \(state)")
            switch state {
            case .ended, .failed:
                // Covers early-return failure paths inside `start()` that
                // set `state` directly rather than going through
                // `stop()`/`endDueToLiveness(reason:)` (e.g. "No camera",
                // "Sign-in required") -- those two call sites ALSO persist,
                // redundantly but harmlessly, so every terminal transition
                // is guaranteed to leave a persisted log regardless of
                // which code path produced it.
                persistDiagnostics()

                // Registry bookkeeping lives at this SAME choke point (bead
                // gateopener-41m.9), for the identical reason: EVERY terminal
                // transition — `stop()`, `endDueToLiveness(reason:)`,
                // `endDueToNoFirstFrame()` (the first-frame-timeout path from
                // gateopener-41m.8, which ends via `performLivenessTeardown`
                // AFTER the offer was accepted), and every early-return
                // `.failed` inside `start()` — passes through here exactly
                // once (this `didSet` already only fires on a genuine value
                // change). See `DoorVideoSessionRegistry.
                // shouldRecordEnd(offerAccepted:)`'s doc comment for why a
                // session that never had its offer accepted must NOT record
                // an end.
                if DoorVideoSessionRegistry.shouldRecordEnd(offerAccepted: offerAccepted) {
                    registry.recordSessionEnded()
                }
            case .streaming:
                // Bead gateopener-672.30: iOS pauses/refuses inline media
                // playback in a hidden (opacity-0) web view, and by the
                // time this session reaches `.streaming` (the first "frame"
                // message has already arrived — see `recordFrameReceived`),
                // WebKit may have paused the element regardless. Re-issue
                // play() defensively on every transition into `.streaming`
                // — `ensurePlaying()` itself is a no-op ("playing") when
                // the element is already playing.
                callEnsurePlaying()
            case .idle, .connecting:
                break
            }
            onStateChange?(state)
        }
    }

    /// Invoked on every state transition. Always invoked on the main actor.
    public var onStateChange: ((State) -> Void)?

    /// Release-build diagnostics for THIS session attempt (bead
    /// gateopener-672.27) -- see `VideoDiagnostics`'s doc comment. Exposed
    /// so callers (or tests) can inspect the in-flight log, though the
    /// canonical read path for the UI is `VideoDiagnostics.loadLast(from:)`
    /// against the persisted app-group defaults, not this live instance.
    public let diagnostics = VideoDiagnostics()

    private let tokenManager: TokenManager
    private let gateClient: any GateOpening
    private let appSettings: AppSettings
    private let urlSession: URLSession

    /// The `DoorVideoSessionRegistry` consulted for the door-busy cooldown
    /// (bead gateopener-41m.9), mirroring macOS's `DoorVideoSession`, which
    /// always uses `DoorVideoSessionRegistry.shared`. Injectable (default
    /// `.shared`) purely so tests can supply an isolated instance rather
    /// than mutating the process-wide singleton.
    private let registry: DoorVideoSessionRegistry

    /// Sleeps out the door-busy cooldown computed from `registry`. Injected
    /// (default `Task.sleep(for:)`) so tests can observe/skip the actual
    /// wait without a real delay.
    private let cooldownSleep: (Duration) async throws -> Void

    /// Guards `stop()` idempotency and lets `start()`'s in-flight guards
    /// (`guard !hasStopped else { return }`) bail out promptly if `stop()`
    /// races an in-progress `start()`. `start()` itself is re-entrant per
    /// `GateOpenerCore.DoorVideoSessionRetention` — see that method's doc
    /// comment — rather than guarded by a separate "already started" flag.
    private var hasStopped = false

    /// Set to `true` the instant an `rtc/offer` PUT is accepted (HTTP 200)
    /// by the door. Consulted at every terminal transition (`.ended`,
    /// `.failed`, `stop()`) via `DoorVideoSessionRegistry.
    /// shouldRecordEnd(offerAccepted:)` to decide whether that transition
    /// should call `registry.recordSessionEnded()` — a session that never
    /// occupied the door's one session slot must NOT start a busy-cooldown
    /// window for the NEXT attempt. Mirrors macOS's `DoorVideoSession.
    /// offerAccepted` exactly.
    private var offerAccepted = false

    /// Non-`nil` while `start()` is sleeping out a door-busy cooldown before
    /// issuing the `rtc/offer` PUT (bead gateopener-41m.9); the deadline the
    /// wait is sleeping until. `nil` at every other time (before the wait
    /// starts, after it ends, and on every terminal transition). Surfaced to
    /// `DoorVideoCoordinator` via `onCooldownChange`.
    private(set) var cooldownUntil: Date? {
        didSet {
            guard oldValue != cooldownUntil else { return }
            onCooldownChange?(cooldownUntil)
        }
    }

    /// Invoked on every `cooldownUntil` change. Always invoked on the main
    /// actor, mirroring `onStateChange`.
    public var onCooldownChange: ((Date?) -> Void)?

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
        urlSession: URLSession = .shared,
        firstFrameTimeout: TimeInterval = 10,
        registry: DoorVideoSessionRegistry = .shared,
        cooldownSleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.tokenManager = tokenManager
        self.gateClient = gateClient
        self.appSettings = appSettings
        self.urlSession = urlSession
        self.firstFrameTimeout = firstFrameTimeout
        self.registry = registry
        self.cooldownSleep = cooldownSleep

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
        // No white flash: `DoorVideoView` (bead gateopener-672.30) now keeps
        // this web view visible (opacity 1) from the moment it appears,
        // including before `door-video.html` has loaded, so its default
        // white background would otherwise show through briefly.
        self.webView.isOpaque = false
        self.webView.backgroundColor = .black
        self.webView.scrollView.backgroundColor = .black

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
        // Second forwarder instance (same weak-referencing shim, different
        // registered name) for the page's "diag" diagnostics channel -- see
        // `DiagScriptMessageForwarder` below and `door-video.html`'s
        // `diag()` helper. Purely additive: a page that never calls
        // `window.webkit.messageHandlers.diag.postMessage` (impossible here
        // since this handler now always exists once this initializer has
        // run) simply never triggers it.
        contentController.add(DiagScriptMessageForwarder(target: self), name: "diag")
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

        diagnostics.append("[\(Self.diagTimestamp())] session start, network path: \(await Self.currentNetworkPathDescription())")

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
        diagnostics.append("[\(Self.diagTimestamp())] camera endpoint chosen: \(endpointId)")

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

        let resolvedStunAddresses = IceServerList.resolveStunAddresses(host: Self.stunHost)
        let iceServerURLs = IceServerList.urls(host: Self.stunHost, port: Self.stunPort, resolved: resolvedStunAddresses)
        let pathSummary = Self.currentPathSummary()
        Self.logger.info("STUN ICE servers: \(iceServerURLs, privacy: .public); path: \(pathSummary, privacy: .public)")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.pageLoadContinuation = continuation
            self.webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }

        guard !hasStopped else { return }

        // Diagnostics only (bead gateopener-672.27): log the array exactly
        // as it is about to be injected into the page, whatever upstream
        // logic (`IceServerList.resolveStunAddresses`/`IceServerList.urls`,
        // moved to Core in gateopener-6s8.5) produced it. This never reads
        // or duplicates that logic, only the resulting variable.
        diagnostics.append("[\(Self.diagTimestamp())] injecting ICE servers: \(iceServerURLs)")

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
            let message = DoorVideoNegotiationFailure.userMessage(for: error)
            diagnostics.append("[\(Self.diagTimestamp())] gathering failed: \(message)")
            state = .failed(message)
            return
        }

        guard !hasStopped else { return }

        // Wait out any remaining door-busy cooldown from a PRIOR session in
        // this process (see `DoorVideoBusyPolicy`/`DoorVideoSessionRegistry`)
        // before issuing the offer PUT at all. `state` stays `.connecting`
        // throughout — mirrors macOS's `DoorVideoSession.start()` exactly.
        await waitOutCooldownIfNeeded()

        // `stop()` may have been called while sleeping out the cooldown
        // above — no offer PUT may be sent in that case.
        guard !hasStopped else { return }

        let answerSDP: String
        do {
            answerSDP = try await putOfferWithRetry(endpointId: endpointId, token: token, sdp: offerSDP)
        } catch let DoorVideoSessionError.offer(outcome) {
            Self.logger.error("rtc/offer failed: \(String(describing: outcome), privacy: .public)")
            let message = DoorVideoBusyPolicy.failureMessage(for: outcome)
            state = .failed(message)
            return
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
        cooldownUntil = nil

        diagnostics.append("[\(Self.diagTimestamp())] terminal reason: stopped")
        persistDiagnostics()

        livenessTask?.cancel()
        livenessTask = nil

        pageLoadContinuation?.resume()
        pageLoadContinuation = nil

        // Fire-and-forget: best-effort teardown of the RTCPeerConnection
        // inside the page, plus blanking the <video> element. Errors here
        // are logged, never surfaced (the session is ending regardless).
        Task { [weak webView] in
            guard let webView else { return }
            // markClosing() first (bead gateopener-672.30) so the page's
            // "pause" event listener (see door-video.html) recognizes the
            // pause closeSession() is about to cause as deliberate teardown
            // and does NOT retry play() against a peer connection that is
            // being closed right underneath it.
            _ = try? await webView.callAsyncJavaScript(
                "if (window.markClosing) { window.markClosing(); }",
                contentWorld: .page
            )
            _ = try? await webView.callAsyncJavaScript(
                "return window.closeSession ? window.closeSession() : null;",
                contentWorld: .page
            )
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "frame")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "diag")

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

    /// Consults `registry.waitBeforeOffer()` and, if positive, sets
    /// `cooldownUntil` to the resulting deadline and sleeps it out via the
    /// injected `cooldownSleep` closure before returning — a dedicated,
    /// `WKWebView`-free seam (bead gateopener-41m.9) factored out of
    /// `start()` so it can be exercised directly by a test (with a fake
    /// `registry`/`cooldownSleep`) without driving the rest of `start()`'s
    /// WKWebView/network pipeline.
    ///
    /// `cooldownUntil` is set BEFORE the sleep and cleared in a `defer` (so
    /// it is also cleared if `cooldownSleep` throws, e.g. a cancelled
    /// `Task.sleep` from `stop()` racing this wait) — a `stop()` called
    /// during the wait leaves no stale `cooldownUntil` behind, and the
    /// caller's own `guard !hasStopped` immediately after this returns is
    /// what prevents the offer PUT itself from ever being sent in that case.
    /// `state` is left untouched here — it stays whatever the caller already
    /// set it to (`.connecting`) — this is not a new user-visible phase.
    ///
    /// `internal` (not `private`) so `@testable import GateOpener` test
    /// targets can call it directly.
    func waitOutCooldownIfNeeded() async {
        let cooldown = registry.waitBeforeOffer()
        guard cooldown > .zero else { return }

        let deadline = Date().addingTimeInterval(
            Double(cooldown.components.seconds) + Double(cooldown.components.attoseconds) / 1e18
        )
        cooldownUntil = deadline
        diagnostics.append("[\(Self.diagTimestamp())] door-busy cooldown wait: \(deadline.timeIntervalSinceNow)s")
        defer { cooldownUntil = nil }
        try? await cooldownSleep(cooldown)
    }

    /// Calls `door-video.html`'s `window.ensurePlaying()` and appends the
    /// returned status string ("playing"/"resumed"/"rejected:<name>"/
    /// "no-video") to `diagnostics` (bead gateopener-672.30). Fire-and-
    /// forget: failures (e.g. the page not loaded yet) are swallowed since
    /// this is a best-effort nudge, never load-bearing for the session
    /// itself succeeding or failing.
    private func callEnsurePlaying() {
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.webView.callAsyncJavaScript(
                "return await window.ensurePlaying ? await window.ensurePlaying() : \"no-fn\";",
                contentWorld: .page
            )
            let status = (result as? String) ?? "unavailable"
            self.diagnostics.append("[\(Self.diagTimestamp())] ensurePlaying: \(status)")
        }
    }

    /// Called by `DoorVideoView.onAppear` (bead gateopener-672.30) so a
    /// view that re-appears while a session is already `.streaming` (e.g.
    /// navigating away and back) gets the same defensive `ensurePlaying()`
    /// nudge as the initial transition into `.streaming` — see that
    /// `didSet` case above. A no-op for every other state: `.idle`/
    /// `.connecting` have no page loaded yet (or no video track applied
    /// yet) to nudge, and `.ended`/`.failed` have already torn the page
    /// down, so calling `ensurePlaying()` there would be meaningless.
    public func ensurePlayingFromHost() {
        guard state == .streaming else { return }
        callEnsurePlaying()
    }

    // MARK: - Liveness watchdog

    /// The three-way (four-way counting `.keepGoing`) liveness decision,
    /// returned by the pure `livenessVerdict(elapsedSinceStart:
    /// sinceLastFrame:hardTimeout:plateau:firstFrameTimeout:)` function
    /// below so it can be unit-tested without a `WKWebView`.
    enum LivenessVerdict: Equatable {
        /// No terminal condition met yet; keep polling.
        case keepGoing
        /// `elapsedSinceStart >= hardTimeout`. Ends in `.ended` (the door's
        /// own ~28-30s window, or the backstop, is a normal end).
        case endedHardTimeout
        /// A frame HAS arrived before, but none for >= `plateau`. Ends in
        /// `.ended` (a genuine stall of an established stream is also a
        /// normal end).
        case endedStall
        /// NO frame has EVER arrived and `elapsedSinceStart >=
        /// firstFrameTimeout`. Ends in `.failed("No video from door
        /// camera")` — the rtc/offer succeeded but the door never actually
        /// sent media, which is an error, not a normal end.
        case failedNoFirstFrame
    }

    /// Pure decision function backing `startLivenessWatchdog()`'s per-tick
    /// logic — kept free of `self`/`WKWebView` so it can be exhaustively
    /// unit-tested.
    ///
    /// Precedence when more than one condition is simultaneously true:
    /// **hard timeout > no-first-frame > stall.** In practice hard timeout
    /// (35s) and no-first-frame (10s) can only coincide if `firstFrameTimeout
    /// >= hardTimeout` (not the production configuration), and stall
    /// requires a frame to have already arrived (so it can never coincide
    /// with no-first-frame); the explicit ordering below is what makes that
    /// guarantee hold regardless of how the two timeouts are configured.
    ///
    /// - Parameters:
    ///   - elapsedSinceStart: `now - sessionStartedAt`.
    ///   - sinceLastFrame: `now - lastFrameAt`, or `nil` if no frame has ever
    ///     arrived.
    ///   - hardTimeout: The absolute session-length backstop.
    ///   - plateau: How long with no new frame (after at least one frame
    ///     arrived) before a stall is declared.
    ///   - firstFrameTimeout: How long with no frame EVER arriving before the
    ///     session is declared failed.
    static func livenessVerdict(
        elapsedSinceStart: TimeInterval,
        sinceLastFrame: TimeInterval?,
        hardTimeout: TimeInterval,
        plateau: TimeInterval,
        firstFrameTimeout: TimeInterval
    ) -> LivenessVerdict {
        if elapsedSinceStart >= hardTimeout {
            return .endedHardTimeout
        }
        guard let sinceLastFrame else {
            // No frame has ever arrived.
            if elapsedSinceStart >= firstFrameTimeout {
                return .failedNoFirstFrame
            }
            return .keepGoing
        }
        if sinceLastFrame >= plateau {
            return .endedStall
        }
        return .keepGoing
    }

    /// Watches for new "frame" messages (see `userContentController(_:
    /// didReceive:)` below) and ends the session on a stall
    /// (`plateauInterval` with no new frame), the hard timeout, or (bead
    /// gateopener-41m.8) a first-frame timeout — NEVER on ICE connection
    /// state, per this type's doc comment and bd memory
    /// `gateopener-live-video-architecture` (ICE can stay "connected" for
    /// ~10s after the door actually stops sending media).
    private func startLivenessWatchdog() {
        livenessTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let self, !self.hasStopped else { return }

                guard let startedAt = self.sessionStartedAt else { continue }
                let now = Date()
                let elapsedSinceStart = now.timeIntervalSince(startedAt)
                let sinceLastFrame = self.lastFrameAt.map { now.timeIntervalSince($0) }

                let verdict = Self.livenessVerdict(
                    elapsedSinceStart: elapsedSinceStart,
                    sinceLastFrame: sinceLastFrame,
                    hardTimeout: Self.hardTimeout,
                    plateau: Self.plateauInterval,
                    firstFrameTimeout: self.firstFrameTimeout
                )

                switch verdict {
                case .keepGoing:
                    continue
                case .endedHardTimeout:
                    Self.logger.notice("hard timeout (\(Self.hardTimeout, privacy: .public)s) reached; ending session")
                    self.endDueToLiveness(reason: "hard timeout after \(Self.hardTimeout)s")
                    return
                case .endedStall:
                    Self.logger.notice("no new frame for \(Self.plateauInterval, privacy: .public)s; ending session (stall)")
                    self.endDueToLiveness(reason: "stall after \(Self.plateauInterval)s")
                    return
                case .failedNoFirstFrame:
                    Self.logger.notice("no first frame after \(self.firstFrameTimeout, privacy: .public)s; failing session")
                    self.endDueToNoFirstFrame()
                    return
                }
            }
        }
    }

    /// Shared teardown steps for every liveness-driven ending
    /// (`endDueToLiveness(reason:)` and `endDueToNoFirstFrame()`): guards
    /// `hasStopped` idempotency, appends + persists a diagnostics line,
    /// resumes any in-flight page-load continuation, blanks the page
    /// (`markClosing()` then `closeSession()`, best-effort, same order and
    /// rationale as `stop()`), and removes both script-message handlers.
    /// Does NOT set `state` — callers set the terminal state themselves
    /// (`.ended` vs `.failed`) after this returns.
    ///
    /// - Parameter reason: Appended to `diagnostics` as `terminal reason:
    ///   <reason>`.
    /// - Returns: `true` if teardown ran (the caller should proceed to set
    ///   `state`); `false` if the session had already stopped (the caller
    ///   must NOT touch `state` — this is what prevents a first frame that
    ///   arrives between the verdict and the teardown from resurrecting the
    ///   session, since `recordFrameReceived()` itself also checks
    ///   `hasStopped`, and either guard winning is sufficient).
    @discardableResult
    private func performLivenessTeardown(reason: String) -> Bool {
        guard !hasStopped else { return false }
        hasStopped = true
        cooldownUntil = nil

        diagnostics.append("[\(Self.diagTimestamp())] terminal reason: \(reason)")
        persistDiagnostics()

        pageLoadContinuation?.resume()
        pageLoadContinuation = nil

        Task { [weak webView] in
            guard let webView else { return }
            // markClosing() first — see the identical comment in stop()
            // above.
            _ = try? await webView.callAsyncJavaScript(
                "if (window.markClosing) { window.markClosing(); }",
                contentWorld: .page
            )
            _ = try? await webView.callAsyncJavaScript(
                "return window.closeSession ? window.closeSession() : null;",
                contentWorld: .page
            )
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "frame")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "diag")

        return true
    }

    /// Common teardown for both stall and hard-timeout endings: runs the
    /// shared teardown steps (`performLivenessTeardown(reason:)`) and
    /// transitions to `.ended` (never `.failed` — the door closing its own
    /// ~28-30s window, or a genuine stall, is a NORMAL end of session, not
    /// an error).
    ///
    /// - Parameter reason: A short, human-readable terminal reason (e.g.
    ///   "stall after 6.0s" or "hard timeout after 35.0s") appended to
    ///   `diagnostics` and persisted before `state` transitions to `.ended`.
    private func endDueToLiveness(reason: String) {
        guard performLivenessTeardown(reason: reason) else { return }
        state = .ended
    }

    /// Teardown for the "rtc/offer succeeded but no frame ever arrived"
    /// failure (bead gateopener-41m.8): runs the SAME shared teardown steps
    /// as `endDueToLiveness(reason:)` via `performLivenessTeardown(reason:)`,
    /// but transitions to `.failed("No video from door camera")` instead of
    /// `.ended` — unlike a stall or the hard timeout, a session that never
    /// received a single frame is an error, not a normal end of stream.
    private func endDueToNoFirstFrame() {
        guard performLivenessTeardown(reason: "no first frame after \(firstFrameTimeout)s") else { return }
        state = .failed("No video from door camera")
    }

    // MARK: - rtc/offer (Swift-side; the bearer token never reaches page JS)

    private struct OfferResponse: Decodable { let answer: String }

    /// Maps a `URLError` (the request never reached the door at all) to a
    /// `DoorVideoBusyPolicy.OfferOutcome` via `DoorVideoBusyPolicy.classify`
    /// — a pure, `WKWebView`/network-free seam (bead gateopener-41m.9) so
    /// the "500 -> no retry, URLError -> retry" decision can be exercised in
    /// a test without an actual `URLSession` round trip. `internal` (not
    /// `private`) so `@testable import GateOpener` test targets can call it
    /// directly.
    static func classifyTransportFailure(_ urlError: URLError) -> DoorVideoBusyPolicy.OfferOutcome {
        let transportError: DoorVideoBusyPolicy.OfferTransportError = urlError.code == .timedOut ? .timedOut : .other
        return DoorVideoBusyPolicy.classify(httpStatus: nil, transportError: transportError)
    }

    /// A single `rtc/offer` PUT attempt, classified via
    /// `DoorVideoBusyPolicy.classify(httpStatus:transportError:)` rather than
    /// thrown as a raw HTTP-status/transport `Error` — mirrors macOS's
    /// `DoorVideoSession.putOfferOnce` exactly (including the malformed-URL
    /// fallback to `.network`, an unreachable-in-practice programmer-error
    /// path).
    private func putOfferOnce(
        endpointId: String,
        token: String,
        sdp: String,
        sessionId: String
    ) async -> (outcome: DoorVideoBusyPolicy.OfferOutcome, answer: String?) {
        // '#' -> %23 only, matching the proven recipe (NOT full percent
        // encoding, which the door's signaling backend does not expect).
        let encodedEndpoint = endpointId.replacingOccurrences(of: "#", with: "%23")
        guard let url = URL(string: "\(ComelitAPI.baseURL)/servicerest/devicecom/endpoint/\(encodedEndpoint)/rtc/offer") else {
            return (.network, nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("ktor-client", forHTTPHeaderField: "user-agent")
        let body: [String: String] = ["sessionId": sessionId, "offer": sdp]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return (.network, nil)
        }
        request.httpBody = httpBody

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            return (Self.classifyTransportFailure(urlError), nil)
        } catch {
            return (DoorVideoBusyPolicy.classify(httpStatus: nil, transportError: .other), nil)
        }
        guard let http = response as? HTTPURLResponse else {
            return (DoorVideoBusyPolicy.classify(httpStatus: nil, transportError: .other), nil)
        }
        let outcome = DoorVideoBusyPolicy.classify(httpStatus: http.statusCode, transportError: nil)
        guard outcome == .accepted else {
            return (outcome, nil)
        }
        guard let decoded = try? JSONDecoder().decode(OfferResponse.self, from: data) else {
            // The door said 200 but the body did not decode -- treat as a
            // server-error outcome (distinct from `.doorBusy`/`.accepted`)
            // rather than accepting a session with no usable answer SDP.
            return (.serverError(http.statusCode), nil)
        }
        return (.accepted, decoded.answer)
    }

    /// Issues the `rtc/offer` PUT with the same policy as macOS's
    /// `DoorVideoSession.putOfferWithRetry`: ONE attempt, classified via
    /// `DoorVideoBusyPolicy.classify`. Per that policy's `shouldRetry`, the
    /// ONLY retryable outcome is `.network` — retried exactly ONCE, after
    /// 500ms, with a FRESH `sessionId`. Every other outcome (`.doorBusy`,
    /// `.unauthorized`, `.serverError`, `.timedOut`) is NOT retried and
    /// thrown immediately as `DoorVideoSessionError.offer(outcome)` so
    /// `start()` can map the SPECIFIC outcome via
    /// `DoorVideoBusyPolicy.failureMessage(for:)`.
    ///
    /// The SAME offer SDP is reused across the one allowed retry
    /// (deliberately NOT regenerated) — see macOS's doc comment on the same
    /// method for why.
    ///
    /// On `.accepted`, records `registry.recordSessionAccepted(at:)` and
    /// sets `offerAccepted = true` (consulted at every terminal transition
    /// via `DoorVideoSessionRegistry.shouldRecordEnd(offerAccepted:)`)
    /// before returning the answer SDP.
    ///
    /// Every `await` in this func is followed by a `hasStopped` check before
    /// any further diagnostics/registry side effect, so a `stop()` racing an
    /// in-flight PUT or the retry's sleep cannot record a diag line or
    /// registry mutation after the session has been torn down.
    private func putOfferWithRetry(endpointId: String, token: String, sdp: String) async throws -> String {
        let maxAttempts = 2 // one attempt + at most one .network retry

        for attempt in 1...maxAttempts {
            guard !hasStopped else { throw DoorVideoSessionError.offer(.network) }

            let sessionId = UUID().uuidString.lowercased()
            let attemptStart = Date()
            let (outcome, answer) = await putOfferOnce(endpointId: endpointId, token: token, sdp: sdp, sessionId: sessionId)
            let latencyMs = Int(Date().timeIntervalSince(attemptStart) * 1000)

            guard !hasStopped else { throw DoorVideoSessionError.offer(.network) }

            if outcome == .accepted, let answer {
                Self.logger.notice("rtc/offer attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) succeeded")
                diagnostics.append("[\(Self.diagTimestamp())] rtc/offer attempt \(attempt)/\(maxAttempts) status=200 latencyMs=\(latencyMs)")
                offerAccepted = true
                registry.recordSessionAccepted(at: Date())
                return answer
            }

            let retryable = DoorVideoBusyPolicy.shouldRetry(outcome)
            Self.logger.notice("rtc/offer attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed: \(String(describing: outcome), privacy: .public), retryable=\(retryable, privacy: .public)")

            let diagLabel = DoorVideoBusyPolicy.diagLabel(for: outcome)
            let statusDescription: String
            switch outcome {
            case .doorBusy:
                statusDescription = "500 \(diagLabel)"
            case .serverError(let status):
                statusDescription = "\(status) \(diagLabel)"
            case .unauthorized, .timedOut, .network, .accepted:
                statusDescription = diagLabel
            }
            diagnostics.append("[\(Self.diagTimestamp())] rtc/offer attempt \(attempt)/\(maxAttempts) status=\(statusDescription) latencyMs=\(latencyMs) retryable=\(retryable)")

            guard !hasStopped else { throw DoorVideoSessionError.offer(outcome) }

            guard retryable, attempt < maxAttempts else {
                throw DoorVideoSessionError.offer(outcome)
            }

            try? await Task.sleep(for: .milliseconds(500))
            guard !hasStopped else { throw DoorVideoSessionError.offer(outcome) }
        }
        // Unreachable: the loop above always either returns or throws on
        // its final iteration.
        throw DoorVideoSessionError.offer(.network)
    }

    // MARK: - Diagnostics (bead gateopener-672.27)

    /// A monotonic-enough, human-readable timestamp for `diagnostics` lines:
    /// milliseconds since epoch, matching the format `door-video.html`'s own
    /// `diag()` helper uses for its page-side lines, so Swift- and page-
    /// originated lines in the merged log sort/compare consistently.
    private static func diagTimestamp() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    /// One-shot snapshot of the current network path via a short-lived
    /// `NWPathMonitor`, for the "session start" diagnostics line. Never logs
    /// anything more specific than interface types and IPv4/IPv6/expensive
    /// support -- no addresses. `NWPathMonitor` only delivers its first path
    /// asynchronously (there is no synchronous "current path" API without
    /// starting one), so this `await`s its first delivery (or a short
    /// timeout, via a `race` against `Task.sleep`, so a session can never
    /// hang waiting on this) rather than blocking any thread synchronously
    /// -- `start()` is `@MainActor`, and a blocking wait here would freeze
    /// the whole app's UI for up to the timeout on every session start.
    private static func currentNetworkPathDescription() async -> String {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    let monitor = NWPathMonitor()
                    let queue = DispatchQueue(label: "ie.boboco.GateOpener.video.diag.pathmonitor")
                    monitor.pathUpdateHandler = { path in
                        let interfaceTypes = path.availableInterfaces.map { "\($0.type)" }
                        let description = "interfaces=\(interfaceTypes) ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6) expensive=\(path.isExpensive)"
                        monitor.cancel()
                        continuation.resume(returning: description)
                    }
                    monitor.start(queue: queue)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return "unknown"
            }
            // First finisher wins; cancel the other (the timeout task if the
            // path arrived first, or -- harmlessly, since the continuation
            // is one-shot and NWPathMonitor.cancel() is idempotent -- the
            // monitor task if the timeout fired first).
            guard let first = await group.next() ?? nil else { return "unknown" }
            group.cancelAll()
            return first
        }
    }

    /// Persists `diagnostics.text` to the app-group shared defaults (falling
    /// back to `.standard` if the App Group entitlement is unavailable, e.g.
    /// a plain SPM test target with no entitlements at all -- see
    /// `SharedContainer.sharedDefaults()`'s doc comment), so a Release
    /// (TestFlight) build still leaves a shareable log after every session,
    /// not just failures.
    private func persistDiagnostics() {
        diagnostics.persist(to: SharedContainer.sharedDefaults() ?? .standard)
    }

    /// Called (on the main actor) by `DiagScriptMessageForwarder` on every
    /// "diag" message from `door-video.html`'s `diag()` helper -- see that
    /// type's doc comment. Appends the page's own already-timestamped line
    /// verbatim (it is prefixed with `[<page-side-ms>]` by the page itself,
    /// distinguishable from this file's Swift-side lines only by the
    /// magnitude of the timestamp if ever compared -- both are epoch-ish
    /// millisecond counters).
    fileprivate func recordDiagMessage(_ line: String) {
        guard !hasStopped else { return }
        diagnostics.append("[page] \(line)")
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
    ///   - registry: The `DoorVideoSessionRegistry` this stub is constructed
    ///     with. Defaults to a FRESH, isolated instance (NOT `.shared`) —
    ///     bead gateopener-41m.9's edge case: `debugStub` must not consult
    ///     the process-wide registry unless a caller opts in explicitly by
    ///     passing one (e.g. a test asserting registry interaction), since
    ///     other tests rely on `debugStub`'s instant, side-effect-free
    ///     starts and must not have their timing perturbed by a busy-cooldown
    ///     left behind by an unrelated real session. In practice this stub's
    ///     canned timeline never calls into the registry either way (it never
    ///     reaches `putOfferWithRetry` or the terminal-state registry hook's
    ///     `offerAccepted` check, which is always `false` here) — the fresh
    ///     instance is defensive/documentation-of-intent rather than
    ///     load-bearing today.
    public static func debugStub(
        connectingDelay: TimeInterval = 2,
        streamingDuration: TimeInterval = 8,
        registry: DoorVideoSessionRegistry = DoorVideoSessionRegistry()
    ) -> DoorVideoSession {
        let session = DoorVideoSession(
            tokenManager: TokenManager(api: ComelitAPI(), credentialStore: DebugStubNullCredentialStore()),
            gateClient: DebugStubNullGateOpening(),
            appSettings: AppSettings(defaults: UserDefaults(suiteName: "ie.boboco.GateOpener.debugStub") ?? .standard),
            registry: registry
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
    /// Wraps a classified `rtc/offer` failure outcome so callers (`start()`)
    /// can distinguish `.doorBusy`/`.unauthorized`/`.timedOut`/`.network`/
    /// `.serverError` and map each to its own `DoorVideoSession.State.failed`
    /// message via `DoorVideoBusyPolicy.failureMessage(for:)`. Mirrors
    /// macOS's `DoorVideoSessionError.offer` exactly.
    case offer(DoorVideoBusyPolicy.OfferOutcome)
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

// MARK: - "diag" diagnostics channel (bead gateopener-672.27)

/// Receives "diag" messages on behalf of a `DoorVideoSession`, mirroring
/// `ScriptMessageForwarder` above exactly (same weak-referencing shim
/// rationale — see `DoorVideoSession.init`'s doc comment). A second,
/// separate forwarder type (rather than making `ScriptMessageForwarder`
/// handle multiple names) so each message name's routing stays a trivial,
/// obviously-correct one-liner.
private final class DiagScriptMessageForwarder: NSObject, WKScriptMessageHandler {
    private weak var target: DoorVideoSession?

    init(target: DoorVideoSession) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "diag", let line = message.body as? String else { return }
        Task { @MainActor [weak target] in
            target?.recordDiagMessage(line)
        }
    }
}
