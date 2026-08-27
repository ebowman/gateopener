import AppKit
import AVFoundation
import os
import GateOpenerCore

/// Shows a small, borderless HUD panel in the top-right corner of the
/// screen that PROVABLY never steals keyboard focus from whatever app the
/// user is currently typing into.
///
/// This exists instead of AVKit's built-in Picture-in-Picture because PiP is
/// designed for user-chosen, user-controlled media: it ships its own
/// playback chrome, a close button, and lets the user drag/resize/persist
/// its position across launches. All of that is wrong for a confirmation
/// HUD that appears for a few seconds and then goes away on its own — this
/// controller instead owns a plain `NSPanel` with exactly the behavior this
/// app needs and nothing more.
///
/// The panel is created LAZILY, on the first `show()` call — never in
/// `init` — so a run that never shows an overlay (e.g. a headless
/// self-test) never touches window-server machinery at all. This mirrors
/// `NotificationPresenter`'s lazy resolution of `UNUserNotificationCenter`.
///
/// THE load-bearing guarantee of this type: `show()` calls
/// `orderFrontRegardless()` and NEVER `makeKeyAndOrderFront(_:)` or
/// `NSApp.activate(...)`. The gate is typically triggered by a global
/// hotkey while the user is typing in some other app, and their keystrokes
/// must keep landing in that app, uninterrupted, the entire time the panel
/// is visible.
@MainActor
final class OverlayWindowController {
    private static let logger = Logger(subsystem: "com.gateopener", category: "overlay")

    /// Fixed panel size. 240x180 is a 4:3 aspect ratio deliberately matching
    /// the door camera's native 320x240 resolution, so a future live-feed
    /// overlay (see `setContent(_:)`) can reuse this exact frame without any
    /// geometry rework — do not change this to a square.
    static let panelSize = NSSize(width: 240, height: 180)

    private static let edgeInset: CGFloat = 16

    /// Whether the panel ignores mouse events (clicks pass through to
    /// whatever is underneath). Defaults to `true`, which is what THIS
    /// bead's confirmation overlay needs: it is pure decoration, and a
    /// click over its frame must always reach the app beneath it. Exposed
    /// as a constructor parameter (rather than hard-coded) because a future
    /// "View door" feature reuses this same panel for an interactive,
    /// user-dismissable live feed, and will need clicks to actually hit the
    /// panel. One parameter now avoids restructuring this type later.
    private let ignoresMouseEvents: Bool

    private var panel: OverlayPanel?

    /// Injected rather than constructed internally: `handle(_:)` must read
    /// `showOpenConfirmationOverlay` fresh on every call (see that method's
    /// doc comment for why), and taking the same `AppSettings` instance the
    /// rest of the app layer already holds (see call sites in
    /// `GateOpenerApp.swift`) keeps this type from silently reading a
    /// second, possibly-different `UserDefaults` suite than the one actually
    /// governing the running app.
    private let appSettings: AppSettings

    /// - Parameters:
    ///   - ignoresMouseEvents: see the property doc above. Defaults to
    ///     `true` for the confirmation-overlay use case.
    ///   - appSettings: source of `showOpenConfirmationOverlay`, read fresh
    ///     on every `handle(_:)` call. See the property doc above for why
    ///     this is injected rather than constructed internally.
    init(appSettings: AppSettings, ignoresMouseEvents: Bool = true) {
        self.appSettings = appSettings
        self.ignoresMouseEvents = ignoresMouseEvents
    }

    /// Replaces the panel's displayed content. Callers may call this before
    /// or after `show()`; if called before the panel exists yet, the view is
    /// held and installed the moment the panel is lazily created.
    ///
    /// THIS IS THE SWAPPABILITY SEAM: nothing about panel creation,
    /// positioning, focus behavior, or lifecycle depends on what `view` is.
    /// This bead installs a plain placeholder (see `makePlaceholderContent()`
    /// below); a future live-camera feature calls this same method with an
    /// `RTCMTLNSVideoView` (or similar) instead, touching no other part of
    /// this type.
    func setContent(_ view: NSView) {
        pendingContent = view
        panel?.installContent(view)
    }

    private var pendingContent: NSView?

    /// The content view currently on screen, if any.
    ///
    /// Prefers what the panel actually has installed, falling back to
    /// `pendingContent` for the case where `setContent(_:)` was called
    /// before the panel was lazily created. Both orders must resolve
    /// correctly: `show()` uses this to deliver `OverlayShowHideResponding`
    /// hooks, so returning nil here would silently mean video playback
    /// never starts.
    private func currentContent() -> NSView? {
        panel?.currentContentView ?? pendingContent
    }

    /// Shows the panel, creating it on first call. Safe to call repeatedly:
    /// at most one panel is ever created, so a second call reuses the
    /// existing one rather than stacking another on screen.
    ///
    /// It is NOT a no-op while already visible: each call re-runs
    /// `position(_:on:)` and `orderFrontRegardless()`. That is deliberate —
    /// it is what lets a show() after a hide() re-display correctly, and it
    /// re-anchors the panel if the active screen changed between calls.
    ///
    /// Silently degrades (logs a notice and returns) if there is no screen
    /// at all to position against — e.g. a headless CI/self-test process.
    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Self.logger.notice("no screen available; skipping overlay presentation")
            return
        }

        let resolvedPanel = resolvePanel()
        position(resolvedPanel, on: screen)

        // orderFrontRegardless() — NEVER makeKeyAndOrderFront(_:), NEVER
        // NSApp.activate(...). Either of those would steal focus from
        // whatever app the user is currently typing into, which is exactly
        // what this entire type exists to prevent.
        resolvedPanel.orderFrontRegardless()

        (currentContent() as? OverlayShowHideResponding)?.overlayWillShow()
    }

    /// Hides the panel. No-op if the panel was never created or is already
    /// hidden.
    func hide() {
        panel?.orderOut(nil)
        (currentContent() as? OverlayShowHideResponding)?.overlayDidHide()
    }

    // MARK: - GateState-driven presentation (gateopener-9kk.5)

    /// How long `.succeeded` holds the overlay on screen (landing the
    /// confirmation) before the fade-out begins. `GateController` auto-resets
    /// to `.idle` `holdDuration + fadeDuration` seconds later at most
    /// (`autoResetDelay` is 3s), so this pair MUST sum to comfortably less
    /// than that or the overlay would still be visible/fading when `.idle`
    /// arrives from the auto-reset rather than from the fast-open path.
    private static let succeededHoldDuration: Duration = .milliseconds(1200)
    private static let fadeDuration: TimeInterval = 0.25

    /// Pending fade-then-hide work (scheduled from `.succeeded`/`.failed`),
    /// held so a later transition can cancel it before it runs — mirrors
    /// `StatusItemController.stillTryingTimer`'s
    /// invalidate-before-reschedule idiom, adapted to `Task` since the work
    /// here is a `Duration`-based hold rather than a single `Timer` fire.
    private var pendingResolveTask: Task<Void, Never>?

    /// `true` exactly while a `.succeeded`/`.failed` hold-then-fade sequence
    /// is scheduled or in progress (from the moment `handle(_:)` schedules it
    /// until the fade completes and the panel is ordered out). Read by the
    /// `.idle`/`.needsSetup` branch to implement reentrancy rule (b) below.
    private var isResolveFadePending = false

    /// Downstream observer of `GateState`, shaped like
    /// `NotificationPresenter.handle(_:)`: never called from `openGate()`'s
    /// call chain, only assigned/chained onto `GateController.onStateChange`
    /// (wiring itself is bead gateopener-9kk.6, not this method).
    ///
    /// Gated on `AppSettings.showOpenConfirmationOverlay`, read FRESH on
    /// every call (not cached at init) so toggling the setting in Settings
    /// takes effect immediately without an app relaunch. When the setting is
    /// `false` this is a total no-op: no panel is ever created (this method
    /// returns before touching `panel`/`resolvePanel()` at all), and any
    /// previously-scheduled fade is left alone rather than force-cancelled —
    /// there is nothing to cancel, since a panel is only ever created inside
    /// this same gate.
    func handle(_ state: GateState) {
        guard appSettings.showOpenConfirmationOverlay else { return }

        switch state {
        case .opening:
            handleOpening()
        case .succeeded:
            handleResolved(holdDuration: Self.succeededHoldDuration)
        case .failed:
            // No hold: a lingering overlay after a failure would visually
            // imply success. See the `handleResolved(holdDuration:)` doc
            // comment.
            handleResolved(holdDuration: .zero)
        case .idle, .needsSetup:
            handleIdleOrNeedsSetup()
        }
    }

    /// `.opening` → show and (re)start playback from zero.
    ///
    /// Reentrancy rule (a): a second open can commence while the overlay is
    /// still fading out from a previous one (e.g. `.opening` arrives again
    /// before a `.failed`/`.succeeded` fade has finished). Cancel that
    /// pending fade/hide FIRST, then reset `alphaValue` to 1 before calling
    /// `show()` — otherwise `show()` would order front a panel whose alpha
    /// is mid-fade (or already 0), producing a visible glitch or an
    /// invisible-but-technically-onscreen overlay. `show()` itself re-runs
    /// `overlayWillShow()` (via `OverlayShowHideResponding`), which is what
    /// actually restarts video playback from zero — see
    /// `GateOpenVideoView.overlayWillShow()`.
    private func handleOpening() {
        cancelPendingResolve()
        panel?.alphaValue = 1
        show()
    }

    /// `.succeeded` and `.failed` share this shape structurally (hold for
    /// `holdDuration`, then fade), differing only in what `holdDuration` the
    /// caller passes: `.succeeded` holds ~1.2s to land the confirmation
    /// before fading (`Self.succeededHoldDuration`); `.failed` passes
    /// `.zero` so it fades immediately — a lingering overlay after a failure
    /// would visually imply success, and the actual failure messaging is
    /// `NotificationPresenter`'s job, not this type's.
    private func handleResolved(holdDuration: Duration) {
        // Any prior pending resolve (e.g. a stale `.failed` fade from a
        // previous attempt that never got cancelled) must not race this new
        // one; cancel-before-reschedule, same idiom as (a) above and as
        // `StatusItemController.scheduleStillTryingCheck()`.
        cancelPendingResolve()
        guard panel != nil else { return }

        isResolveFadePending = true
        pendingResolveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: holdDuration)
            } catch {
                // Cancelled (superseded by a newer transition, e.g. a fast
                // re-open via handleOpening()'s cancelPendingResolve()) —
                // that newer transition already owns the panel's fate, so
                // this stale sequence must do nothing further.
                return
            }
            await self?.fadeOutThenHide()
        }
    }

    /// `.idle`/`.needsSetup` → hide immediately, UNLESS a `.succeeded`/
    /// `.failed` hold-then-fade is already pending.
    ///
    /// Reentrancy rule (b), implemented exactly as specified: a fast
    /// `.opening -> .succeeded -> .idle` sequence (GateController's
    /// auto-reset, or a quick subsequent state read) must not truncate the
    /// hold-then-fade that `.succeeded` just scheduled — so if
    /// `isResolveFadePending` is true, this is a no-op; the scheduled fade
    /// (from `handleResolved()`) is solely responsible for eventually
    /// hiding the panel. If NO fade is pending (e.g. `.idle` arrives with no
    /// preceding `.succeeded`/`.failed` at all, or after a previous fade has
    /// already completed), `.idle` is not ignored indefinitely: it forces an
    /// immediate hide so the overlay never outlives the state machine.
    private func handleIdleOrNeedsSetup() {
        guard !isResolveFadePending else { return }
        guard panel != nil else { return }
        panel?.alphaValue = 1
        hide()
    }

    /// Animates `alphaValue` to 0 over `fadeDuration`, then orders the panel
    /// out and resets `alphaValue` back to 1.
    ///
    /// The alpha reset back to 1 happens HERE, immediately after
    /// `orderOut(nil)` and before this method returns — i.e. it is in place
    /// before any subsequent `show()` can possibly run, since `show()` is
    /// only ever invoked from `handleOpening()` on the main actor, and this
    /// whole method runs on the main actor too. A panel left at alpha 0 and
    /// then ordered front by a later `show()` would be an invisible overlay;
    /// this is the fix for that failure mode.
    ///
    /// Guards against a second reentrancy-(a) case: `handleOpening()` can
    /// call `cancelPendingResolve()` (which marks `pendingResolveTask`
    /// cancelled) WHILE this method's animation await is already in flight —
    /// `Task` cancellation cannot interrupt the running
    /// `NSAnimationContext` block itself. Without the `Task.isCancelled`
    /// check below, this method would run `hide()` + reset alpha AFTER
    /// `handleOpening()` has already reset alpha and called `show()`,
    /// clobbering the fresh show with a hide. Checking `Task.isCancelled`
    /// immediately after the animation completes and bailing out (doing
    /// NEITHER `hide()` nor the alpha reset) leaves the panel exactly as the
    /// superseding `handleOpening()` call left it.
    private func fadeOutThenHide() async {
        guard let panel else {
            isResolveFadePending = false
            return
        }

        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 0
            } completionHandler: {
                continuation.resume()
            }
        }

        guard !Task.isCancelled else {
            // Superseded mid-animation by a new .opening — see doc comment
            // above. The superseding call already owns alpha/visibility.
            return
        }

        hide()
        // Reset BEFORE the next possible show() — see doc comment above.
        panel.alphaValue = 1
        isResolveFadePending = false
        pendingResolveTask = nil
    }

    private func cancelPendingResolve() {
        pendingResolveTask?.cancel()
        pendingResolveTask = nil
        isResolveFadePending = false
    }

    // MARK: - Private

    private func resolvePanel() -> OverlayPanel {
        if let panel { return panel }

        let created = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        // isFloatingPanel — keeps the panel above normal windows without
        // requiring it to be key or main. Without this a borderless panel
        // can still get buried behind ordinary document windows.
        created.isFloatingPanel = true

        // .statusBar level — sits above regular app windows (and roughly
        // level with menu-bar-adjacent UI). Without this the overlay could
        // appear behind the very app the user is looking at.
        created.level = .statusBar

        // Transparent, non-opaque, with a shadow — lets the placeholder's
        // rounded corners show real (non-rectangular) window edges. Without
        // isOpaque = false + backgroundColor = .clear, AppKit paints an
        // opaque rectangular backing behind the content, producing a
        // visible square around the rounded HUD. hasShadow = true keeps a
        // normal drop shadow despite the transparent background.
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true

        // hidesOnDeactivate = false — without this, AppKit would hide the
        // panel the instant the app is no longer frontmost, which is
        // guaranteed to happen almost immediately since this panel never
        // takes focus in the first place.
        created.hidesOnDeactivate = false

        // collectionBehavior — .canJoinAllSpaces + .fullScreenAuxiliary so
        // the overlay can appear regardless of which Space or full-screen
        // app is active (the hotkey can fire from anywhere); .stationary so
        // the panel does not slide around during Space-switch animations.
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // ignoresMouseEvents — see the property doc above; defaults to
        // true so a click over the overlay's frame passes through to
        // whatever is underneath, since the confirmation overlay is pure
        // decoration.
        created.ignoresMouseEvents = ignoresMouseEvents

        let contentView = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        created.contentView = contentView

        let installedContent = pendingContent ?? Self.makeDefaultContent()
        created.installContent(installedContent)

        panel = created
        return created
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = Self.panelSize
        let origin = NSPoint(
            x: visible.maxX - size.width - Self.edgeInset,
            y: visible.maxY - size.height - Self.edgeInset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// Default content: the bundled gate-open video (see
    /// `GateOpenVideoView`). Falls back to the plain HUD placeholder when
    /// the video asset cannot be located — see
    /// `GateOpenVideoView.makeIfAvailable()` for why that happens (chiefly:
    /// an unbundled process, where `Bundle.main` has no `Resources`
    /// directory at all) and why it must never crash.
    private static func makeDefaultContent() -> NSView {
        GateOpenVideoView.makeIfAvailable(size: panelSize) ?? makePlaceholderContent()
    }

    /// Placeholder content: a rounded, semi-transparent dark HUD backing
    /// with no live data. Used both as this bead's degrade path (see
    /// `makeDefaultContent()`) and available to any future feature via
    /// `setContent(_:)` — see that method's doc comment.
    private static func makePlaceholderContent() -> NSView {
        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        return effectView
    }
}

/// `NSPanel` subclass that unconditionally refuses key/main status.
///
/// A panel with `.nonactivatingPanel` in its style mask is documented to
/// avoid activating the app when ordered front, but empirically it can
/// still become key in some configurations (e.g. certain mouse-down
/// sequences over its content). Overriding `canBecomeKey`/`canBecomeMain`
/// to unconditionally return `false` removes that ambiguity entirely: this
/// window is now structurally incapable of taking focus, regardless of how
/// it is ordered front or clicked.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        OverlayWindowController.logKeyMainQuery(kind: "canBecomeKey", result: false)
        return false
    }

    override var canBecomeMain: Bool {
        OverlayWindowController.logKeyMainQuery(kind: "canBecomeMain", result: false)
        return false
    }

    /// Removes any previously-installed content subview and installs
    /// `view`, resizing it to fill the panel's content view. Kept on the
    /// panel (rather than the controller) since it is purely a window-layout
    /// concern.
    func installContent(_ view: NSView) {
        guard let host = contentView else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        currentContentView = view
    }

    /// Tracks whatever view was most recently installed via
    /// `installContent(_:)`, so `OverlayWindowController.show()`/`hide()`
    /// can look it up (via `currentContent()`) to deliver
    /// `OverlayShowHideResponding` lifecycle hooks without keeping their own
    /// separate reference.
    private(set) var currentContentView: NSView?
}

/// Optional lifecycle hook for content installed via
/// `OverlayWindowController.setContent(_:)`. See that method's doc comment
/// for the swappability seam this protocol participates in.
///
/// Content that does not need to know about `show()`/`hide()` (e.g. a
/// static placeholder) simply does not conform; the controller only invokes
/// these methods when the currently-installed content does.
@MainActor
protocol OverlayShowHideResponding: AnyObject {
    /// Called from `OverlayWindowController.show()`, after the panel has
    /// been ordered front, every time `show()` runs (not just the first
    /// time the panel is created).
    func overlayWillShow()

    /// Called from `OverlayWindowController.hide()`, after the panel has
    /// been ordered out.
    func overlayDidHide()
}

extension OverlayWindowController {
    /// Logs every `canBecomeKey`/`canBecomeMain` query so runtime behavior
    /// (not just code inspection) can be confirmed: both must always log
    /// `false`. Internal logging hook only — not part of the public API.
    fileprivate static func logKeyMainQuery(kind: String, result: Bool) {
        logger.debug("\(kind, privacy: .public) queried, returning \(result, privacy: .public)")
    }
}
