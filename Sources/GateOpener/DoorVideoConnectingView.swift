import AppKit

/// Plain HUD placeholder shown by `DoorVideoOverlayController` while a
/// `DoorVideoSession` is connecting (measured time-to-first-frame ~6s,
/// dominated by the cloud round trip — see `DoorVideoSession`'s doc
/// comment), and reused verbatim (with different text) to show a brief
/// human-readable failure message before the panel disappears.
///
/// A blank panel for ~6 seconds reads as broken (bead requirement), so this
/// view exists purely to make the wait legible: a rounded, semi-transparent
/// dark HUD backing (visually consistent with
/// `OverlayWindowController.makePlaceholderContent()`, the confirmation
/// overlay's own degrade-path placeholder) plus a centered label.
///
/// Does NOT conform to `OverlayShowHideResponding` — it has no playback or
/// polling to start/stop, just static text.
///
/// Supports the same click-to-dismiss affordance as `DoorVideoFrameView`
/// (see that type's `mouseDown(_:)` doc comment for why this is safe and
/// does not touch keyboard focus): the panel hosting this view is
/// constructed with `ignoresMouseEvents: false`, so a click while
/// "Connecting…" or a failure message is showing dismisses the panel too,
/// not just once live frames arrive.
final class DoorVideoConnectingView: NSView {
    /// Invoked when the user clicks anywhere on this view. Wired by
    /// `DoorVideoOverlayController` to its own `dismiss()`.
    var onClickToDismiss: (() -> Void)?
    /// - Parameters:
    ///   - size: the panel size to fill.
    ///   - text: defaults to "Connecting…" for the in-flight case;
    ///     `DoorVideoOverlayController` passes a short failure message
    ///     (e.g. "Could not reach door camera") for the failure case.
    init(size: NSSize, text: String = "Connecting…") {
        super.init(frame: NSRect(origin: .zero, size: size))

        let effectView = NSVisualEffectView(frame: bounds)
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]
        addSubview(effectView)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.frame = NSRect(x: 12, y: (size.height - 32) / 2, width: size.width - 24, height: 32)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(label)

        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("DoorVideoConnectingView does not support NSCoder-based instantiation")
    }

    override func mouseDown(with event: NSEvent) {
        onClickToDismiss?()
    }
}
