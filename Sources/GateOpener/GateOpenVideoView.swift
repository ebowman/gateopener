import AppKit
import AVFoundation
import os

/// Layer-backed `NSView` that plays the bundled gate-open confirmation clip
/// inside `OverlayWindowController`'s panel, installed through that
/// controller's `setContent(_:)` swappability seam (see that method's doc
/// comment in `OverlayWindowController.swift`).
///
/// PLAYBACK SEMANTICS — the clip is NOT seamlessly loopable: it shows a
/// gate opening and STAYING OPEN, so its first and last frames deliberately
/// differ. This view therefore plays the clip exactly ONCE per `show()` and
/// then holds the final frame (gate open) on screen for as long as the
/// overlay remains visible, rather than looping — looping would make the
/// gate appear to snap shut and reopen repeatedly, which reads as "cycling"
/// rather than "opened". Do not add `AVPlayerLooper` or a seek-to-`.zero`
/// completion handler here; see `overlayWillShow()`/`overlayDidHide()`
/// below.
///
/// Muted unconditionally (`isMuted` AND `volume = 0`) regardless of whether
/// the bundled asset happens to carry an audio track, so this can never
/// become audible even if a future asset swap adds sound.
///
/// Degrades to `nil` (never crashes) via `makeIfAvailable(size:)` when the
/// bundled asset cannot be located — chiefly because the running process is
/// unbundled (`swift run`, `.build/debug/GateOpener`, or this app's own
/// self-test), in which case `Bundle.main` has no `Resources` directory to
/// resolve at all. This mirrors `NotificationPresenter`'s guard against
/// touching `UNUserNotificationCenter` on an unbundled process — see that
/// type's doc comment.
@MainActor
final class GateOpenVideoView: NSView, OverlayShowHideResponding {
    private static let logger = Logger(subsystem: "com.gateopener", category: "overlay-video")

    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private var didReachEndObserver: NSObjectProtocol?

    /// Creates a `GateOpenVideoView` sized to `size`, or `nil` if the
    /// bundled `gate-open.mp4` resource cannot be located.
    ///
    /// `Bundle.main.url(forResource:withExtension:)` returns `nil` (rather
    /// than throwing) for an unbundled process, which is exactly the
    /// degrade path this method is built around: log a notice and return
    /// `nil`, letting the caller fall back to other content. Never force-
    /// unwraps, never throws, never crashes.
    static func makeIfAvailable(size: NSSize) -> GateOpenVideoView? {
        guard let url = Bundle.main.url(forResource: "gate-open", withExtension: "mp4") else {
            logger.notice("gate-open.mp4 not found in bundle; degrading overlay content")
            return nil
        }
        return GateOpenVideoView(assetURL: url, frame: NSRect(origin: .zero, size: size))
    }

    private init(assetURL: URL, frame: NSRect) {
        let item = AVPlayerItem(url: assetURL)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        // Default is .pause, but set explicitly: this is the behavior this
        // view relies on to hold the final frame at end of playback rather
        // than looping or advancing past the end.
        player.actionAtItemEnd = .pause

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect

        self.player = player
        self.playerLayer = layer

        super.init(frame: frame)

        wantsLayer = true
        self.layer = CALayer()
        self.layer?.addSublayer(layer)
        layer.frame = bounds

        didReachEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.holdFinalFrame()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("GateOpenVideoView does not support NSCoder-based instantiation")
    }

    // No explicit `deinit` observer teardown: `didReachEndObserver` is held
    // strictly for documentation/ownership clarity, but
    // `NotificationCenter`'s block-based `addObserver(forName:object:queue:)`
    // token is safe to simply let ARC release along with this instance —
    // there is no dangling-callback risk since the closure only captures
    // `self` weakly. Removing it manually here would additionally require
    // touching a non-`Sendable` `NSObjectProtocol` from a `nonisolated
    // deinit` under Swift 6 strict concurrency, which does not compile.

    override func layout() {
        super.layout()
        // Keeps the player layer tracking the view's bounds. The panel is
        // fixed-size today (see OverlayWindowController.panelSize), but
        // this must not break if that changes in the future.
        playerLayer.frame = bounds
    }

    // MARK: - OverlayShowHideResponding

    /// Restarts playback from the beginning every time the overlay is
    /// shown, so a second open never resumes mid-animation from wherever
    /// the previous playthrough left off.
    func overlayWillShow() {
        player.seek(to: .zero)
        player.play()
    }

    /// Pauses playback when the overlay is hidden. Deliberately does NOT
    /// tear down the player/item (no `replaceCurrentItem(with: nil)`): the
    /// asset is small and local, decoder resources here are cheap to leave
    /// paused-but-resident, and rebuilding the player on every show/hide
    /// cycle would add needless churn for a HUD that opens and closes
    /// frequently. `pause()` is sufficient to stop any advancement (and any
    /// possibility of the disabled-but-still-technically-active audio path)
    /// while hidden.
    func overlayDidHide() {
        player.pause()
    }

    // MARK: - Private

    /// Ensures the final frame stays visible at end-of-item rather than the
    /// layer going blank. `actionAtItemEnd = .pause` already stops playback
    /// on the final frame in observed testing (see the bead report), so
    /// this explicit pause is a belt-and-braces safety net in case some
    /// macOS version/timing advances the player past the last frame before
    /// the pause takes effect.
    private func holdFinalFrame() {
        player.pause()
    }
}
