import AppKit
import os

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

    /// - Parameter ignoresMouseEvents: see the property doc above. Defaults
    ///   to `true` for the confirmation-overlay use case.
    init(ignoresMouseEvents: Bool = true) {
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
    }

    /// Hides the panel. No-op if the panel was never created or is already
    /// hidden.
    func hide() {
        panel?.orderOut(nil)
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

        let installedContent = pendingContent ?? Self.makePlaceholderContent()
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

    /// Placeholder content for this bead: a rounded, semi-transparent dark
    /// HUD backing with no live data. A future feature replaces this by
    /// calling `setContent(_:)` — see that method's doc comment.
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
    }
}

extension OverlayWindowController {
    /// Logs every `canBecomeKey`/`canBecomeMain` query so runtime behavior
    /// (not just code inspection) can be confirmed: both must always log
    /// `false`. Internal logging hook only — not part of the public API.
    fileprivate static func logKeyMainQuery(kind: String, result: Bool) {
        logger.debug("\(kind, privacy: .public) queried, returning \(result, privacy: .public)")
    }
}
