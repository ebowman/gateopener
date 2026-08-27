import AppKit
import GateOpenerCore

/// Maps `GateState` to the SF Symbol / tooltip shown in the menu bar.
///
/// All icons are template images (`isTemplate = true`) so AppKit tints them
/// correctly for the current menu-bar appearance (light/dark, and the
/// "reduce transparency"/accent variants macOS applies to template images).
enum GateIcon {
    /// SF Symbol name for a given state. `.opening` deliberately uses a
    /// visually distinct symbol (not just a color/animation change) so the
    /// "your click registered" feedback is unmistakable even to someone who
    /// can't distinguish subtle color shifts.
    static func symbolName(for state: GateState) -> String {
        switch state {
        case .needsSetup:
            return "questionmark.circle"
        case .idle:
            return "lock.fill"
        case .opening:
            return "arrow.triangle.2.circlepath"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Short tooltip text for a given state. `stillTryingAfterEscalation`
    /// overrides `.opening`'s normal tooltip once the caller has determined
    /// (by timing from its own receipt of `.opening`, since `GateState`
    /// carries no timestamp) that the attempt has been running for longer
    /// than the ~2s normal case would suggest.
    static func tooltip(for state: GateState, stillTryingAfterEscalation: Bool = false) -> String {
        switch state {
        case .needsSetup:
            return "GateOpener — set up your account"
        case .idle:
            return "GateOpener — click to open the gate"
        case .opening:
            return stillTryingAfterEscalation ? "GateOpener — still trying…" : "GateOpener — opening…"
        case .succeeded:
            return "GateOpener — gate opened"
        case .failed(let message):
            return "GateOpener — \(message)"
        }
    }

    /// Builds the `NSImage` for a given state: a template-rendered SF Symbol,
    /// with `.needsSetup` additionally rendered at reduced opacity ("greyed")
    /// to distinguish it from the normal `.idle` icon at a glance.
    static func image(for state: GateState) -> NSImage? {
        let name = symbolName(for: state)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: tooltip(for: state)) else {
            return nil
        }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let configured = base.withSymbolConfiguration(config) else {
            base.isTemplate = true
            return base
        }
        configured.isTemplate = true

        if case .needsSetup = state {
            return configured.grayedOutForBadge()
        }
        return configured
    }
}

private extension NSImage {
    /// Returns a copy of this template image drawn at reduced opacity, used
    /// to visually distinguish `.needsSetup` ("badged/greyed") from the
    /// normal `.idle` icon. Still a template image so it continues to tint
    /// correctly for light/dark menu bars.
    func grayedOutForBadge() -> NSImage {
        let size = self.size
        let result = NSImage(size: size)
        result.lockFocus()
        self.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.45
        )
        result.unlockFocus()
        result.isTemplate = true
        return result
    }
}
