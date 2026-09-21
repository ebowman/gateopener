import SwiftUI
import UIKit

/// The `ButtonStyle` for `MainView.openButton` (bead gateopener-41m.10): a
/// filled capsule-ish rounded rect that reads as an obvious primary button,
/// rather than the flat `.plain`-styled rectangle it replaces.
///
/// This type owns ONLY the button's chrome (fill, gradient, shadow, press
/// feedback) — the label content (icon/text/state) is built by
/// `MainView.openButton` itself and passed in as this style's `Label`.
struct OpenGateButtonStyle: ButtonStyle {
    /// The state-driven fill colour (`MainView.accentColor`), passed in by
    /// the caller so this style never needs to know about `GateState`.
    let fillColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        // Reduce Motion: no scale-down on press, just the darken/shadow cue.
        let scale = (pressed && !reduceMotion) ? 0.97 : 1.0

        configuration.label
            .frame(maxWidth: .infinity)
            .frame(minHeight: 96)
            .background(fill(pressed: pressed))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(
                color: .black.opacity(pressed ? 0.08 : 0.22),
                radius: pressed ? 3 : 10,
                x: 0,
                y: pressed ? 1 : 5
            )
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    /// Increased Contrast: a flat fill plus a stroke reads more reliably as
    /// "solid button" than a subtle gradient does under that setting; normal
    /// contrast keeps the vertical gradient for a sense of elevation.
    private func fill(pressed: Bool) -> some View {
        let base = pressed ? fillColor.darkened(by: 0.12) : fillColor
        return ZStack {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(base)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                    )
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [base.lightened(by: 0.08), base.darkened(by: 0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }
}

private extension Color {
    /// Blends toward white by `fraction` (0...1) — used for the subtle
    /// top-edge highlight in the button's elevation gradient.
    func lightened(by fraction: Double) -> Color {
        blended(with: .white, fraction: fraction)
    }

    /// Blends toward black by `fraction` (0...1) — used for both the
    /// gradient's lower edge and the on-press "darken" cue.
    func darkened(by fraction: Double) -> Color {
        blended(with: .black, fraction: fraction)
    }

    private func blended(with other: Color, fraction: Double) -> Color {
        let ui = UIColor(self)
        let otherUI = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ui.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        otherUI.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(min(max(fraction, 0), 1))
        return Color(
            red: Double(r1 + (r2 - r1) * t),
            green: Double(g1 + (g2 - g1) * t),
            blue: Double(b1 + (b2 - b1) * t),
            opacity: Double(a1 + (a2 - a1) * t)
        )
    }
}
