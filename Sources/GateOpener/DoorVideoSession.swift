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

extension DoorVideoSessionState {
    /// Maps this app-layer state down to `GateOpenerCore`'s payload-free
    /// `DoorVideoSessionPhase`, dropping the `.ended`/`.failed` associated
    /// values Core has no business knowing about — see that type's doc
    /// comment in `DoorVideoSessionRetention.swift`.
    ///
    /// Deliberately exhaustive with NO `default` clause: a new case added
    /// to `DoorVideoSessionState` must fail to compile here until it is
    /// explicitly mapped to a phase.
    var phase: DoorVideoSessionPhase {
        switch self {
        case .idle:
            return .idle
        case .connecting:
            return .connecting
        case .streaming:
            return .streaming
        case .ended:
            return .ended
        case .failed:
            return .failed
        }
    }
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
///  - Comelit's STUN host is pre-resolved to IPs via
///    `GateOpenerCore.IceServerList` (shared with iOS, bead
///    gateopener-6s8.5), and injected as `window.__ICE_SERVERS__` before
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

    /// Set the instant `diagnostics` is persisted for the terminal time —
    /// i.e. on `.ended`/`.failed` or `stop()` (see `finalizeDiagnostics
    /// (reason:)`). Guards against a double-persist AND against any further
    /// `diagnostics.append` after that point (e.g. `stop()` called before
    /// the page finished loading, racing a late `didFail`/`didFinish`
    /// navigation-delegate callback that would otherwise append after the
    /// log has already been persisted and handed off).
    private var finalized = false

    /// Release-build diagnostics for THIS session attempt (bead
    /// gateopener-kgx.6, mirroring the iOS recorder wired in
    /// gateopener-672.27): collects every page-side `diag()` line (via the
    /// "diag" `WKScriptMessageHandler` below) plus every Swift-side stage
    /// line, so a failed session leaves a complete, shareable, address-free
    /// record even outside a debugger.
    private let diagnostics = VideoDiagnostics()

    /// Wall-clock start of `start()`, used only to compute "streaming after
    /// X.Xs" for the terminal diagnostics line.
    private var startedAt: Date?

    /// Polling task watching for the first decoded frame after the answer
    /// SDP has been applied; cancelled by `stop()`.
    private var streamingPollTask: Task<Void, Never>?

    /// Set to `true` the instant an `rtc/offer` PUT is accepted (HTTP 200)
    /// by the door. Consulted at every terminal transition (`.ended`,
    /// `.failed`, `stop()`) via `DoorVideoSessionRegistry.
    /// shouldRecordEnd(offerAccepted:)` to decide whether that transition
    /// should call `DoorVideoSessionRegistry.shared.recordSessionEnded()` —
    /// a session that never occupied the door's one session slot (e.g.
    /// failed on token/discovery/negotiation, or was `.doorBusy`/`.timedOut`
    /// on the offer itself) must NOT start a busy-cooldown window for the
    /// NEXT attempt (see that helper's doc comment).
    private var offerAccepted = false

    public init(
        tokenManager: TokenManager,
        gateClient: GateClient,
        session: URLSession = .shared
    ) {
        self.tokenManager = tokenManager
        self.gateClient = gateClient
        self.session = session

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        config.userContentController = contentController

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

        // Registered via a weak-referencing shim (`DiagScriptMessageForwarder`
        // below), NOT `self` directly, mirroring the iOS session's init —
        // `WKUserContentController.add(_:name:)` retains its handler
        // strongly, and the content controller is itself owned (via
        // `contentView.configuration`) by `contentView`, which `self` owns —
        // registering `self` directly would be a permanent retain cycle
        // (`self` -> `contentView` -> `contentController` -> `self`) that
        // only `removeScriptMessageHandler` breaks, which nothing before
        // `stop()` would ever call. Every message body is a page-authored
        // `door-video.html` `diag()` line (see that file); non-`String`
        // bodies are ignored by the forwarder.
        contentController.add(DiagScriptMessageForwarder(target: self), name: "diag")
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
        // The "diag" handler is removed in `stop()` (mirroring iOS); by the
        // time `deinit` runs, either `stop()` already ran and the handler
        // is gone, or `contentView` itself (and its `WKUserContentController`)
        // is being released here regardless, so there is nothing further to
        // tear down.
    }

    /// Appends `line` to `diagnostics` (unless the session has already been
    /// finalized — see `finalized`'s doc comment) and mirrors it to the
    /// unified log, so `log show`/`log stream` alone carries the full
    /// record without opening the app or reading persisted `UserDefaults`.
    private func recordDiag(_ line: String) {
        guard !finalized else { return }
        diagnostics.append(line)
        Self.logger.notice("diag: \(line, privacy: .public)")
    }

    /// Called once, on the FIRST terminal transition this instance ever
    /// reaches (`.ended`, `.failed`, or `stop()`): appends the terminal
    /// line, persists `diagnostics` to `defaults`, and sets `finalized` so
    /// no further `recordDiag` calls can append after the log has been
    /// handed off. Safe to call more than once — only the first call has
    /// any effect — since `stop()` after an already-`.failed` state, or a
    /// late navigation-delegate callback racing `stop()`, would otherwise
    /// double-persist or append post-persist.
    private func finalizeDiagnostics(_ reason: VideoDiagnosticsStage.TerminalReason, defaults: UserDefaults = .standard) {
        guard !finalized else { return }
        let line = VideoDiagnosticsStage.terminal(reason)
        diagnostics.append(line)
        Self.logger.notice("diag: \(line, privacy: .public)")
        diagnostics.persist(to: defaults)
        finalized = true

        // Registry bookkeeping lives at this SAME choke point (guarded by
        // the same `finalized` flag, so it fires exactly once per session,
        // on whichever of `.ended`/`.failed`/`stop()` reaches here first) —
        // see `DoorVideoSessionRegistry.shouldRecordEnd(offerAccepted:)`'s
        // doc comment for why a session that never had its offer accepted
        // must NOT record an end (it never occupied the door's session
        // slot, so it must not start a busy-cooldown window for the next
        // attempt).
        if DoorVideoSessionRegistry.shouldRecordEnd(offerAccepted: offerAccepted) {
            DoorVideoSessionRegistry.shared.recordSessionEnded()
        }
    }

    // MARK: - start()'s two concurrent branches (bead gateopener-6s8.4)

    /// Outcome of branch A (token refresh -> camera-endpoint discovery).
    /// Never thrown — every failure this branch can hit is captured here so
    /// `start()` can decide, AFTER both branches have finished, which
    /// failure (if any) to report, per this bead's priority rule (branch A
    /// wins if both failed).
    private enum BranchAResult {
        case success(token: String, endpointId: String)
        case failure(message: String)
    }

    /// Outcome of branch B (STUN resolve -> page load -> inject ICE servers
    /// -> `startNegotiation()`). Never thrown, for the same reason as
    /// `BranchAResult`.
    private enum BranchBResult {
        case success(offerSDP: String)
        case failure(message: String)
    }

    /// Branch A: resolves an access token, then discovers the camera
    /// endpoint id. Records every diag line the ORIGINAL sequential
    /// `start()` recorded for these two steps, in the same order, plus a
    /// final "auth+discovery took Xms" line on completion (success or
    /// failure) — see `VideoDiagnosticsStage.authDiscoveryDuration(ms:)`.
    ///
    /// Every `await` is followed by a `hasStopped` check before recording
    /// anything further, matching this type's existing convention
    /// elsewhere (e.g. `putOfferWithRetry`) so a `stop()` racing this
    /// branch cannot append a diag line after teardown — `recordDiag`
    /// itself already no-ops post-`finalized`, but the early return also
    /// skips the pointless remaining work (endpoint discovery after a
    /// token that arrived post-stop, etc).
    private func runAuthDiscoveryBranch() async -> BranchAResult {
        let branchStart = Date()

        let token: String
        do {
            token = try await tokenManager.accessToken()
            recordDiag(VideoDiagnosticsStage.tokenResolved(outcome: .ok))
        } catch TokenManagerError.notConfigured {
            recordDiag(VideoDiagnosticsStage.tokenResolved(outcome: .failed("notConfigured")))
            recordDiag(VideoDiagnosticsStage.authDiscoveryDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Sign-in required")
        } catch {
            recordDiag(VideoDiagnosticsStage.tokenResolved(outcome: .failed(String(describing: error))))
            recordDiag(VideoDiagnosticsStage.authDiscoveryDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Could not get access token")
        }

        guard !hasStopped else {
            recordDiag(VideoDiagnosticsStage.authDiscoveryDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Could not get access token")
        }

        let endpointId: String
        do {
            endpointId = try await resolveCameraEndpointId()
            recordDiag(VideoDiagnosticsStage.endpointResolved(id: endpointId))
        } catch {
            recordDiag(VideoDiagnosticsStage.authDiscoveryDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Door camera not found")
        }

        recordDiag(VideoDiagnosticsStage.authDiscoveryDuration(ms: Self.elapsedMs(since: branchStart)))
        return .success(token: token, endpointId: endpointId)
    }

    /// Branch B: resolves Comelit's STUN host to IPs, loads
    /// `door-video.html` into `contentView` (awaiting the SAME
    /// `pageLoadContinuation` the navigation delegate resumes today),
    /// injects the resolved ICE server URLs, then negotiates the
    /// non-trickle offer. Records every diag line the original sequential
    /// `start()` recorded for these steps, in the same order, plus a final
    /// "gathering took Xms" line on completion (success or failure) — see
    /// `VideoDiagnosticsStage.gatheringDuration(ms:)`.
    ///
    /// `pageURL` is resolved by the CALLER (`start()`) before either branch
    /// is launched, since a missing `door-video.html` is reported as a
    /// dedicated "Video page unavailable" failure that neither branch A nor
    /// B individually owns (it precedes both in the original sequential
    /// flow, and both branches would otherwise need to special-case it).
    ///
    /// `hasStopped` is checked after every `await` before any further diag
    /// line, mirroring branch A. If `stop()` resumes `pageLoadContinuation`
    /// while this branch is awaiting it, this branch's own `guard
    /// !hasStopped` immediately after that `await` returns `.failure`
    /// without EVER touching `pageLoadContinuation` again — so the
    /// continuation this branch owns is resumed exactly once, by whichever
    /// of {navigation delegate, `stop()`} gets there first, never by this
    /// branch itself a second time.
    private func runGatheringBranch(pageURL: URL) async -> BranchBResult {
        let branchStart = Date()

        let resolvedStunAddresses = IceServerList.resolveStunAddresses(host: Self.stunHost)
        recordDiag(VideoDiagnosticsStage.stunResolved(count: resolvedStunAddresses.count))
        let iceServerURLs = IceServerList.urls(host: Self.stunHost, port: Self.stunPort, resolved: resolvedStunAddresses)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.pageLoadContinuation = continuation
            self.contentView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        }

        guard !hasStopped else {
            recordDiag(VideoDiagnosticsStage.gatheringDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Video page failed to load")
        }

        do {
            try await injectIceServers(iceServerURLs)
        } catch {
            recordDiag(VideoDiagnosticsStage.gatheringDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Video page failed to load")
        }

        guard !hasStopped else {
            recordDiag(VideoDiagnosticsStage.gatheringDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Video page failed to load")
        }

        let offerSDP: String
        do {
            offerSDP = try await startNegotiation()
        } catch {
            recordDiag(VideoDiagnosticsStage.gatheringDuration(ms: Self.elapsedMs(since: branchStart)))
            return .failure(message: "Could not negotiate video session")
        }

        recordDiag(VideoDiagnosticsStage.gatheringDuration(ms: Self.elapsedMs(since: branchStart)))
        return .success(offerSDP: offerSDP)
    }

    /// Milliseconds elapsed since `start`, as an `Int` (matching
    /// `putOfferOnce`'s existing `latencyMs` computation style).
    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - start()

    /// Establishes the one and only WebRTC session this instance will ever
    /// have. Safe to call at most once; a second call is a no-op (logged)
    /// since this type does not support restarting.
    ///
    /// Never throws: all failure paths are reported via `state`.
    ///
    /// Runs two branches CONCURRENTLY (bead gateopener-6s8.4): branch A
    /// (`runAuthDiscoveryBranch`, token -> discovery) and branch B
    /// (`runGatheringBranch`, STUN resolve -> page load -> inject ICE
    /// servers -> negotiate) — neither needs the other's result, and cold
    /// token refresh + discovery can cost up to ~8s that used to fully
    /// precede gathering. Both are joined (both `async let`s are awaited
    /// to completion — never cancelled early) before the door-busy cooldown
    /// wait and the `rtc/offer` PUT, which DO need both results (the token
    /// and endpoint id from A, the offer SDP from B).
    ///
    /// Failure priority, per this bead: if BOTH branches failed, branch A's
    /// failure message is reported (auth/discovery failures are the more
    /// actionable message for the user). If only one branch failed, that
    /// branch's message is reported and the OTHER branch's (now-unused)
    /// successful result is simply discarded — both branches are always
    /// awaited to completion here (via `async let`), so there is never a
    /// dangling continuation or an orphaned child task left running past
    /// this function's return.
    public func start() async {
        guard !hasStarted else {
            Self.logger.notice("DoorVideoSession.start() called more than once; ignoring")
            return
        }
        hasStarted = true
        startedAt = Date()
        state = .connecting

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        recordDiag(VideoDiagnosticsStage.sessionStart(appVersion: appVersion, build: build, os: osVersion))

        guard let pageURL = Bundle.main.url(forResource: "door-video", withExtension: "html") else {
            // Mirrors GateOpenVideoView.makeIfAvailable's degrade path: an
            // unbundled process (swift run, self-test) has no Resources
            // directory to resolve at all. Logged as a notice, not an
            // error — this is expected outside a built .app bundle.
            Self.logger.notice("door-video.html not found in bundle; DoorVideoSession cannot start")
            let message = "Video page unavailable"
            state = .failed(message: message)
            finalizeDiagnostics(.failed(message: message))
            return
        }

        async let branchAResult = runAuthDiscoveryBranch()
        async let branchBResult = runGatheringBranch(pageURL: pageURL)

        // Both branches are ALWAYS awaited fully here — never cancelled
        // early — so `pageLoadContinuation` (owned by branch B) is never
        // left dangling and any late navigation-delegate callback or
        // `stop()` racing either branch always finds a branch that is
        // either still legitimately running or has already returned.
        let resolvedA = await branchAResult
        let resolvedB = await branchBResult

        guard !hasStopped else { return }

        let token: String
        let endpointId: String
        switch resolvedA {
        case .success(let resolvedToken, let resolvedEndpointId):
            token = resolvedToken
            endpointId = resolvedEndpointId
        case .failure(let message):
            // Branch A's failure wins regardless of branch B's outcome —
            // this bead's stated priority. Branch B's result (success or
            // its own failure) is discarded here without further action.
            state = .failed(message: message)
            finalizeDiagnostics(.failed(message: message))
            return
        }

        let offerSDP: String
        switch resolvedB {
        case .success(let resolvedOfferSDP):
            offerSDP = resolvedOfferSDP
        case .failure(let message):
            state = .failed(message: message)
            finalizeDiagnostics(.failed(message: message))
            return
        }

        guard !hasStopped else { return }

        // Wait out any remaining door-busy cooldown from a PRIOR session in
        // this process (see `DoorVideoBusyPolicy`/`DoorVideoSessionRegistry`)
        // before issuing the offer PUT at all. `state` stays `.connecting`
        // throughout — this is not a new user-visible phase, just a delay
        // before the existing "connecting" phase's offer step.
        let cooldown = DoorVideoSessionRegistry.shared.waitBeforeOffer()
        if cooldown > .zero {
            let cooldownSeconds = Double(cooldown.components.seconds)
                + Double(cooldown.components.attoseconds) / 1e18
            recordDiag(VideoDiagnosticsStage.cooldownWait(seconds: cooldownSeconds))
            try? await Task.sleep(for: cooldown)
        }

        guard !hasStopped else { return }

        let answerSDP: String
        do {
            answerSDP = try await putOfferWithRetry(endpointId: endpointId, token: token, sdp: offerSDP)
        } catch let DoorVideoSessionError.offer(outcome) {
            Self.logger.error("rtc/offer failed: \(String(describing: outcome), privacy: .public)")
            let message = DoorVideoBusyPolicy.failureMessage(for: outcome)
            state = .failed(message: message)
            finalizeDiagnostics(.failed(message: message))
            return
        } catch {
            Self.logger.error("rtc/offer failed: \(String(describing: error), privacy: .public)")
            let message = "Could not reach door camera"
            state = .failed(message: message)
            finalizeDiagnostics(.failed(message: message))
            return
        }

        guard !hasStopped else { return }

        do {
            try await applyAnswer(answerSDP)
            recordDiag(VideoDiagnosticsStage.answerApplied())
        } catch {
            let message = "Could not apply video answer"
            state = .failed(message: message)
            finalizeDiagnostics(.failed(message: message))
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
        // Breaks the retain cycle described in `init`'s doc comment; also
        // ensures no further page-originated "diag" message can reach
        // `recordDiag` after this point (belt-and-suspenders alongside the
        // `finalized` guard below, since `finalizeDiagnostics` may not have
        // run yet the very first time `stop()` reaches this line).
        contentView.configuration.userContentController.removeScriptMessageHandler(forName: "diag")

        if case .failed = state {
            // Preserve a failure reason already reported rather than
            // clobbering it with a generic "ended" — stop() after a failed
            // start() should not overwrite the more specific message. The
            // failure path already called `finalizeDiagnostics(.failed(...))`
            // when `state` was set, so this is a no-op persist (guarded by
            // `finalized`), matching the edge case that `stop()` after an
            // already-failed `start()` must not persist twice.
            finalizeDiagnostics(.failed(message: Self.failureMessage(from: state)))
            return
        }
        state = .ended(reason: "stopped")
        finalizeDiagnostics(.stopped)
    }

    /// Extracts `.failed`'s associated message, or a fallback if `state`
    /// somehow is not `.failed` when this is called (defensive only — every
    /// call site already checked `case .failed = state` first).
    private static func failureMessage(from state: DoorVideoSessionState) -> String {
        if case .failed(let message) = state {
            return message
        }
        return "unknown"
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
        recordDiag(VideoDiagnosticsStage.offerReady(candidateCount: candidateCount))

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
                            self.recordDiag(VideoDiagnosticsStage.videoStats(json: jsonStr))
                        }
                        if let data = jsonStr.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let video = obj["video"] as? [String: Any],
                           let framesDecoded = video["framesDecoded"] as? Int, framesDecoded > 0 {
                            self.state = .streaming
                            // .streaming is NOT a terminal state (per this
                            // bead's requirement) -- no `finalizeDiagnostics`
                            // call here; the eventual .ended/.failed/stop()
                            // that follows is what finalizes and persists.
                            let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                            self.recordDiag(VideoDiagnosticsStage.terminal(.streaming(afterSeconds: elapsed)))
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
            self.finalizeDiagnostics(.noVideo)
        }
    }

    // MARK: - rtc/offer (Swift-side; the bearer token never reaches page JS)

    private struct OfferResponse: Decodable { let answer: String }

    /// A single `rtc/offer` PUT attempt, classified via
    /// `DoorVideoBusyPolicy.classify(httpStatus:transportError:)` rather
    /// than thrown as a raw HTTP-status/transport `Error` — see
    /// `putOfferWithRetry` for how the outcome drives retry and the
    /// eventual `DoorVideoSessionState.failed(message:)`.
    ///
    /// `request.timeoutInterval = 12` is set explicitly on the REQUEST
    /// (not relying on `session`'s configuration): `URLRequest.
    /// timeoutInterval` takes precedence over
    /// `URLSessionConfiguration.timeoutIntervalForRequest` for the request
    /// it is set on, per Foundation's documented behavior, so this is
    /// effective regardless of `session`'s configuration UNLESS that
    /// configuration's `timeoutIntervalForRequest` is somehow shorter than
    /// 12s and takes priority in some undocumented edge case -- `session`
    /// is `URLSession.shared` at every real call site (`GateOpenerApp.
    /// swift`), whose default configuration's `timeoutIntervalForRequest`
    /// is 60s (longer than 12s), so this 12s request-level timeout is the
    /// binding one in practice.
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
            // Not a real HTTP/transport outcome (a malformed URL is a
            // programmer error, not a door-busy/network condition), but
            // `.network` is the closest existing classification and keeps
            // this an unreachable-in-practice path rather than a new state
            // the rest of the pipeline has to special-case.
            return (.network, nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 12
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
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            let transportError: DoorVideoBusyPolicy.OfferTransportError = urlError.code == .timedOut ? .timedOut : .other
            return (DoorVideoBusyPolicy.classify(httpStatus: nil, transportError: transportError), nil)
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

    /// Issues the `rtc/offer` PUT with the epic gateopener-6s8 policy: ONE
    /// attempt, a 12s per-request timeout (see `putOfferOnce`), classified
    /// via `DoorVideoBusyPolicy.classify`. Per that policy's `shouldRetry`,
    /// the ONLY retryable outcome is `.network` (the request never reached
    /// the door at all) — retried exactly ONCE, after 500ms, with a FRESH
    /// `sessionId`. Every other outcome (`.doorBusy`, `.unauthorized`,
    /// `.serverError`, `.timedOut`) is NOT retried and thrown immediately:
    ///  - `.doorBusy` needs `waitBeforeOffer`'s cooldown before the NEXT
    ///    session attempt, not a fast retry against a door that has already
    ///    said no.
    ///  - `.timedOut` is never retried: the PUT may have succeeded
    ///    server-side and consumed the door's one session slot even though
    ///    this process never saw the response — blindly retrying risks
    ///    racing a second session against one already accepted.
    ///  - `.unauthorized`/`.serverError` are not transient network
    ///    failures, so a fast retry is not expected to help.
    ///
    /// The SAME offer SDP is reused across the one allowed retry
    /// (deliberately NOT regenerated): the SDP's ICE ufrag/password and
    /// DTLS fingerprint are tied to the single `RTCPeerConnection` already
    /// created and gathered in the page, and Comelit's `sessionId` is the
    /// field that scopes one negotiation attempt from the next — nothing
    /// about a `.network` failure implies the offer itself was malformed.
    ///
    /// On `.accepted`, records `DoorVideoSessionRegistry.shared.
    /// recordSessionAccepted()` and sets `offerAccepted = true` (consulted
    /// by `finalizeDiagnostics` to decide whether a later terminal
    /// transition should record a session END — see that property's doc
    /// comment) before returning the answer SDP.
    ///
    /// On failure, throws `DoorVideoSessionError.offer(outcome)` so `start()`
    /// can map the SPECIFIC outcome to a `DoorVideoSessionState.failed(
    /// message:)` via `DoorVideoBusyPolicy.failureMessage(for:)`, rather than
    /// the previous one-size-fits-all "Could not reach door camera".
    ///
    /// Every `await` in this func is followed by a `hasStopped` check
    /// before any further diagnostics/registry side effect, so a `stop()`
    /// racing an in-flight PUT or the retry's sleep cannot record a diag
    /// line or registry mutation after the session has been torn down.
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
                recordDiag(VideoDiagnosticsStage.offerAttempt(n: attempt, of: maxAttempts, outcome: .success, latencyMs: latencyMs))
                offerAccepted = true
                DoorVideoSessionRegistry.shared.recordSessionAccepted(at: Date())
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
            recordDiag(VideoDiagnosticsStage.offerAttempt(n: attempt, of: maxAttempts, outcome: .failure(statusDescription), latencyMs: latencyMs))

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
}

// MARK: - Errors

enum DoorVideoSessionError: Error, Equatable {
    case cameraNotFound
    case negotiationFailed
    /// Wraps a classified `rtc/offer` failure outcome so callers (`start()`)
    /// can distinguish `.doorBusy`/`.unauthorized`/`.timedOut`/`.network`/
    /// `.serverError` and map each to its own
    /// `DoorVideoSessionState.failed(message:)` via
    /// `DoorVideoBusyPolicy.failureMessage(for:)`, rather than a single
    /// generic transport/server error case.
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

// MARK: - "diag" diagnostics channel (bead gateopener-kgx.6)

/// Receives "diag" messages on behalf of a `DoorVideoSession` without the
/// session itself being retained by `WKUserContentController` — mirrors
/// `iOS/App/Video/DoorVideoSession.swift`'s `DiagScriptMessageForwarder`
/// exactly, including the weak `target` reference (see `DoorVideoSession.
/// init`'s doc comment for why `add(_:name:)` is never given `self`
/// directly).
private final class DiagScriptMessageForwarder: NSObject, WKScriptMessageHandler {
    private weak var target: DoorVideoSession?

    init(target: DoorVideoSession) {
        self.target = target
    }

    /// Ignores any message whose body is not a `String` (per this bead's
    /// edge case), and any message once `target` has been deallocated.
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

extension DoorVideoSession {
    /// Called (on the main actor) by `DiagScriptMessageForwarder` on every
    /// "diag" message from `door-video.html`'s `diag()` helper; see that
    /// type's doc comment. `fileprivate` (not `private`) so the forwarder,
    /// a sibling top-level type in this file, can reach it despite
    /// `recordDiag`/`diagnostics`/`finalized` being otherwise private to
    /// `DoorVideoSession`.
    fileprivate func recordDiagMessage(_ line: String) {
        recordDiag(line)
    }
}
