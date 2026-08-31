import AppKit
import os

/// Layer-backed `NSView` that renders a live door-camera image inside
/// `OverlayWindowController`'s panel by POLLING `DoorVideoSession.
/// contentView`'s `window.captureFrameJpeg(quality)` via `callAsyncJavaScript`
/// and drawing the decoded JPEG into a plain `NSImageView`.
///
/// THIS IS THE ONLY SUPPORTED WAY TO SHOW DOOR VIDEO ON SCREEN — do not
/// attempt to display `DoorVideoSession.contentView` (a `WKWebView`)
/// directly. `OverlayWindowController`'s panel is `.nonactivatingPanel` and
/// can never become key, and a `WKWebView` never composites a single pixel
/// until its host window becomes key at least once (verified against real
/// hardware, gateopener-12h.8). `captureFrameJpeg()` reads pixels out of a
/// hidden `<canvas>` inside the page instead, which — also verified against
/// real hardware — works fine from a fully non-activating panel: a real
/// 320x240 door frame was captured and visually confirmed. So the
/// `WKWebView` stays off-screen as a pure decoding engine; this view is the
/// only thing the user ever looks at.
///
/// ## Polling
///
/// Polls at `pollInterval` (125ms ≈ 8fps, matching the ../comelit reference
/// implementation's MJPEG poll rate) via `Task.sleep` + `callAsyncJavaScript`
/// (NEVER `evaluateJavaScript` — see `DoorVideoSession`'s GOTCHA doc comment:
/// `WKErrorDomain` code 5 on any Promise-returning expression). Each tick:
/// decode the returned base64 JPEG data URL off the main actor (JPEG decode
/// is nontrivial CPU work; keeping it off the main actor keeps the poll loop
/// from janking any UI event handling), then hop back to set `imageView.
/// image`.
///
/// ## Session-end detection (gateopener-12h.4 measurements)
///
/// The door's session lasts ~28-30s and `DoorVideoSession` does NOT
/// auto-detect that — it stays `.streaming` until `stop()` is called
/// explicitly, and ICE state lags the actual stop by 10-20s (unusable as a
/// live signal; it would leave a frozen picture on screen for that whole
/// window). So this view detects end-of-session itself, from the signals
/// that are actually timely, in priority order:
///
///  1. RTP progress (PRIMARY — fixes a false plateau on a static scene,
///     e.g. a still door/hallway): each poll's combined bridge call
///     (`window.captureFrameAndStats`) also returns the peer connection's
///     inbound-video `framesReceived`/`packetsReceived` counters. Any
///     STRICT increase in either counter resets the plateau clock, even if
///     the decoded JPEG is byte-identical to the previous poll — real RTP
///     is still arriving and being decoded, the camera's subject just
///     isn't moving. See `rtpCountersShowProgress(previous:current:)`,
///     factored out as a pure, WKWebView-free function specifically so
///     this logic can be reasoned about (and, environment permitting,
///     tested) in isolation. A counter that goes DOWN (stats reset) or
///     stays flat does NOT count as progress, so a genuinely frozen/dead
///     RTP stream still plateaus after `plateauInterval` like before.
///  2. Byte-difference fallback (only when RTP counters are unavailable
///     for this poll — e.g. `pc.getStats()` itself failed): `captureFrameJpeg()`
///     returning `nil` (video.videoWidth/videoHeight go to 0 once the
///     underlying `<video>` element stops receiving frames) or the same
///     frame repeating for `plateauInterval` is the fallback plateau
///     signal, exactly as before this fix.
///
/// Either signal is treated as the PRIMARY end-of-session trigger; a
/// `hardTimeout` backstop guards against the poll loop itself somehow
/// wedging without ever observing a plateau. On either trigger this view
/// calls `onSessionEnded` exactly once and stops polling — it does NOT call
/// `session.stop()` itself (that is the owner's job, since the owner is
/// what constructed the session).
@MainActor
final class DoorVideoFrameView: NSView, OverlayShowHideResponding {
    private static let logger = Logger(subsystem: "com.gateopener", category: "door-video-frame")

    /// ~8fps, matching the ../comelit reference implementation's MJPEG poll
    /// interval.
    static let pollInterval: Duration = .milliseconds(125)

    /// No new decoded frame for this long means the session is over. Chosen
    /// within the bead's specified 2-3s window.
    static let plateauInterval: TimeInterval = 2.5

    /// Backstop in case the plateau detector itself never fires (e.g. the
    /// poll loop wedges). Comfortably above the measured ~28.3-28.9s session
    /// lengths (gateopener-12h.4) plus the plateau window, but short enough
    /// that a genuinely stuck session cannot outlive it by much.
    static let hardTimeout: TimeInterval = 35

    /// Inbound-video RTP counters sampled from `pc.getStats()` via the
    /// page's `window.captureFrameAndStats` bridge (see `Resources/
    /// door-video.html`). Two counters are tracked, not just one, because
    /// either can legitimately be the one that increments most reliably
    /// depending on decoder state — mirrors `DoorVideoSession.
    /// watchForFirstFrame()`'s analogous preference for `getStats()`-based
    /// signals over the page's own `requestVideoFrameCallback`, which that
    /// type's doc comment documents as unreliable in this WKWebView
    /// context.
    struct RTPCounters: Equatable {
        let framesReceived: Int
        let packetsReceived: Int
    }

    /// Pure decision, deliberately free of any WKWebView/Date/Task
    /// plumbing so it can be reasoned about (and exercised) in isolation
    /// from the live poll loop: does `current` represent genuine forward
    /// RTP progress relative to `previous`?
    ///
    /// - `previous == nil` (no counters observed yet, or the previous poll
    ///   could not obtain any — see `lastRTPCounters`'s doc comment) counts
    ///   as progress only if `current` ALREADY shows nonzero traffic. An
    ///   all-zero baseline sample (e.g. taken right as negotiation
    ///   completes, before any RTP has actually arrived) must NOT hold the
    ///   plateau clock open indefinitely on its own — a session that never
    ///   receives any RTP at all still needs to plateau/hard-timeout
    ///   normally, exactly as before this fix.
    /// - A counter that DECREASES relative to `previous` indicates a reset
    ///   (e.g. the page's stats object reinitializing) rather than genuine
    ///   progress, and does not by itself count as progress.
    /// - Otherwise, progress is any STRICT increase in either counter —
    ///   this is what fixes the false plateau on a static scene (frames
    ///   are still arriving and being decoded, the picture just isn't
    ///   changing), while a genuinely frozen/dead RTP stream (counters
    ///   stay flat poll after poll) still plateaus after `plateauInterval`.
    static func rtpCountersShowProgress(previous: RTPCounters?, current: RTPCounters) -> Bool {
        guard let previous else {
            return current.framesReceived > 0 || current.packetsReceived > 0
        }
        return current.framesReceived > previous.framesReceived
            || current.packetsReceived > previous.packetsReceived
    }

    private let session: DoorVideoSession
    private let imageView: NSImageView
    private let connectingLabel: NSTextField

    /// Invoked exactly once, on the main actor, the first time this view
    /// detects the session has ended (plateau or hard timeout). The owner is
    /// responsible for tearing down the overlay/session in response — this
    /// view only detects and reports, it never hides itself or calls
    /// `session.stop()`.
    var onSessionEnded: (() -> Void)?

    /// Invoked when the user clicks anywhere on this view. Wired by
    /// `DoorVideoOverlayController` to its own `dismiss()` — see that type's
    /// doc comment on why the View-door panel (unlike the confirmation
    /// overlay) is constructed with `ignoresMouseEvents: false` specifically
    /// so this can work. `nil` by default (no-op).
    var onClickToDismiss: (() -> Void)?

    private var pollTask: Task<Void, Never>?
    /// The plateau clock: reset whenever EITHER liveness signal (RTP
    /// progress, primarily; byte-difference, as a fallback — see the type
    /// doc comment) fires. `checkForEndOfSession()` plateaus when this is
    /// more than `plateauInterval` in the past.
    private var lastProgressAt: Date?
    private var lastFrameData: Data?
    /// The most recent RTP counters this view has observed, or `nil` if
    /// none has been observed yet this session. `nil` is also restored
    /// mid-session (see `pollOnce()`) whenever a poll cannot obtain RTP
    /// counters at all, so a later poll that CAN obtain them treats that
    /// as a fresh baseline rather than comparing across a gap with no
    /// data.
    private var lastRTPCounters: RTPCounters?
    private var sessionStartedAt: Date?
    private var hasReportedEnded = false

    init(session: DoorVideoSession, frame: NSRect) {
        self.session = session

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        self.imageView = imageView

        let label = NSTextField(labelWithString: "Connecting…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (frame.height - 20) / 2, width: frame.width, height: 20)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        self.connectingLabel = label

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // LOAD-BEARING (gateopener-12h.8, gateopener-12h.5 bugfix): the
        // WKWebView must be a subview inside a REAL, ordered-front window
        // hierarchy for RTP to composite into its <video> element at all —
        // see DoorVideoSession.contentView's own doc comment and the
        // gateopener-12h.8 root-cause writeup. Canvas capture
        // (captureFrameJpeg) does NOT need the window to become KEY (that
        // was verified in the 12h.8 "option (c)" experiment, run in a panel
        // configured exactly like OverlayWindowController's), but it does
        // need the web view actually installed somewhere in that panel's
        // view tree. Before this fix nothing ever added `session.
        // contentView` to this view (or anywhere else in the production
        // "View door" path) — captureFrameJpeg() therefore always returned
        // nil (video.videoWidth/videoHeight stayed 0 forever) and the panel
        // sat on "Connecting…" until the hard-timeout backstop fired.
        //
        // Added FIRST (bottom of z-order) and behind the opaque imageView/
        // label, so the raw WKWebView (whose own <video> element never
        // actually paints per 12h.8 — only the hidden <canvas> inside it
        // does) is never what the user visually sees; captureFrameJpeg's
        // decoded JPEG drawn into `imageView` is. Sized to fill this view
        // like the other subviews, purely so it has a sane non-zero layout;
        // its own pixels are irrelevant since only its canvas is ever read.
        session.contentView.frame = NSRect(origin: .zero, size: frame.size)
        session.contentView.autoresizingMask = [.width, .height]
        addSubview(session.contentView)

        addSubview(imageView)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("DoorVideoFrameView does not support NSCoder-based instantiation")
    }

    /// Reports a click anywhere on this view to `onClickToDismiss`. Only
    /// reachable at all because the panel hosting this view is constructed
    /// with `ignoresMouseEvents: false` (see `DoorVideoOverlayController`);
    /// this does NOT and cannot affect keyboard focus — `mouseDown(_:)` is a
    /// pure mouse-event override and never calls `makeKeyAndOrderFront(_:)`/
    /// `NSApp.activate(...)` itself, nor does receiving a mouse click cause
    /// AppKit to grant a `.nonactivatingPanel` key status on its own
    /// (`OverlayPanel.canBecomeKey` unconditionally returns `false`
    /// regardless of mouse activity).
    override func mouseDown(with event: NSEvent) {
        onClickToDismiss?()
    }

    // MARK: - OverlayShowHideResponding

    /// Starts polling. Safe to call more than once (e.g. if `setContent(_:)`
    /// happens to re-fire this — see `OverlayWindowController.setContent(_:)`'s
    /// same-view no-op guard, which normally prevents that): a prior poll
    /// task is cancelled first so at most one polling loop ever runs.
    func overlayWillShow() {
        startPolling()
    }

    /// Stops polling. Does NOT call `session.stop()` — this view does not
    /// own the session's lifecycle, only its own polling loop.
    func overlayDidHide() {
        stopPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        hasReportedEnded = false
        sessionStartedAt = Date()
        lastProgressAt = nil
        lastFrameData = nil
        lastRTPCounters = nil

        // Defence in depth (gateopener-f8w.2): every production call site
        // (`OverlayWindowController.startOpenVideoSessionIfEnabled()`,
        // `DoorVideoOverlayController.start()`) constructs a brand-new
        // `DoorVideoFrameView` per session today, so `imageView.image` is
        // always nil the first time `startPolling()` runs for a given
        // instance in practice. This reset does not rely on that: it makes
        // "no frame decoded by THIS session yet" structurally true from
        // `imageView`'s own state, not merely from caller discipline, so a
        // future caller that reuses an existing `DoorVideoFrameView` across
        // sessions (or a second `overlayWillShow()` on the same instance)
        // can never display an image left over from a previous session
        // before this one's own first frame decodes. Restores the
        // "Connecting…" label to match, exactly mirroring `init`'s initial
        // (unhidden) state.
        imageView.image = nil
        connectingLabel.isHidden = false

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                if Task.isCancelled { return }
                self.checkForEndOfSession()
                if Task.isCancelled { return }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async {
        // Single combined bridge call per poll (not two): the page's
        // `window.captureFrameAndStats` returns the captured JPEG data URL
        // AND the current RTP counters together, JSON.stringify()'d —
        // matching `DoorVideoSession`'s existing stringify-then-
        // `JSONSerialization` bridging pattern (see `getVideoStats` there)
        // rather than doubling `callAsyncJavaScript` round trips.
        let raw: Any?
        do {
            raw = try await session.contentView.callAsyncJavaScript(
                "return window.captureFrameAndStats ? await window.captureFrameAndStats(0.85) : null;",
                contentWorld: .page
            )
        } catch {
            // Transient eval errors are not fatal on their own; the plateau
            // detector (driven off lastProgressAt) is what decides whether
            // this is actually the end of the session.
            return
        }

        guard let jsonString = raw as? String,
              let jsonData = jsonString.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        let now = Date()
        var progressed = false

        // PRIMARY liveness signal: RTP progress. `video` is a dictionary
        // (present, though possibly all-zero) whenever the page could read
        // `pc.getStats()` at all; it is JSON `null` — which fails this cast
        // — specifically when it could not, in which case `rtpAvailable`
        // stays false and the byte-difference fallback below is what
        // decides progress instead.
        var rtpAvailable = false
        if let videoStats = payload["video"] as? [String: Any],
           let framesReceived = (videoStats["framesReceived"] as? NSNumber)?.intValue,
           let packetsReceived = (videoStats["packetsReceived"] as? NSNumber)?.intValue {
            rtpAvailable = true
            let current = RTPCounters(framesReceived: framesReceived, packetsReceived: packetsReceived)
            if Self.rtpCountersShowProgress(previous: lastRTPCounters, current: current) {
                progressed = true
            }
            lastRTPCounters = current
        } else {
            // RTP counters unavailable this poll — do not compare a FUTURE
            // available sample against a stale baseline from before this
            // gap (see `lastRTPCounters`'s doc comment).
            lastRTPCounters = nil
        }

        guard let dataURL = payload["jpeg"] as? String,
              let commaIndex = dataURL.firstIndex(of: ","),
              let jpegData = Data(base64Encoded: String(dataURL[dataURL.index(after: commaIndex)...])) else {
            // No frame captured this poll (e.g. the <video> element has no
            // natural size yet). RTP progress alone, if any, still resets
            // the plateau clock.
            if progressed { lastProgressAt = now }
            return
        }

        // A stalled/ended RTP session does NOT make captureFrameJpeg()
        // start returning nil: a plain HTML5 <video> element holds its last
        // decoded frame on screen indefinitely once new samples stop
        // arriving (it does not go blank or reset videoWidth/videoHeight to
        // 0), so the hidden <canvas> keeps happily re-encoding the SAME
        // pixels every poll and captureFrameJpeg() keeps "succeeding"
        // forever. Comparing the raw JPEG bytes against the previous poll's
        // catches that: WebKit's canvas JPEG encoder is deterministic for
        // identical input pixels at a fixed quality (0.85, fixed above), so
        // byte-identical output means the underlying video frame did not
        // actually change. This is now only the FALLBACK plateau signal —
        // used only when RTP counters were unavailable this poll — because
        // relying on it alone was exactly what caused a false plateau on a
        // static scene: a real, live RTP stream decoding an unchanging
        // picture (e.g. a still hallway) produces byte-identical JPEGs poll
        // after poll even though the session is genuinely still live.
        let isNewJPEG = jpegData != lastFrameData
        lastFrameData = jpegData
        if !rtpAvailable && isNewJPEG {
            progressed = true
        }

        if progressed {
            lastProgressAt = now
        }

        guard isNewJPEG else { return }

        // Decode off the main actor: JPEG decode is real CPU work and this
        // runs every ~125ms for up to ~30s.
        let image = await Task.detached(priority: .userInitiated) {
            NSImage(data: jpegData)
        }.value

        guard let image else { return }

        self.imageView.image = image
        if !self.connectingLabel.isHidden {
            self.connectingLabel.isHidden = true
        }
    }

    private func checkForEndOfSession() {
        guard !hasReportedEnded else { return }

        let now = Date()
        if let sessionStartedAt, now.timeIntervalSince(sessionStartedAt) >= Self.hardTimeout {
            Self.logger.notice("door video hard timeout reached; reporting session ended")
            reportSessionEnded()
            return
        }

        guard let lastProgressAt else {
            // No liveness signal has arrived yet — still connecting, not a
            // plateau.
            return
        }
        if now.timeIntervalSince(lastProgressAt) >= Self.plateauInterval {
            Self.logger.notice("door video frame plateau detected; reporting session ended")
            reportSessionEnded()
        }
    }

    private func reportSessionEnded() {
        guard !hasReportedEnded else { return }
        hasReportedEnded = true
        stopPolling()
        onSessionEnded?()
    }
}
