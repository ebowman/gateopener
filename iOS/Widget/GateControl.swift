import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center / Lock Screen bottom controls / Action Button
/// control (bead gateopener-672.15), driven by the same `OpenGateIntent`
/// (`openAppWhenRun = false`) every other one-tap surface uses.
///
/// This is a MOMENTARY button, not a toggle, by design (this bead's edge
/// case): `ControlWidgetButton` fires `OpenGateIntent.perform()` immediately
/// on press with no confirm step — a gate is a one-shot action, not a
/// persistent on/off state, so `ControlWidgetToggle` would be the wrong
/// shape even though the intent happens to be idempotent-ish.
///
/// Control Center itself shows no feedback beyond the button press (no
/// dialog surface there); Siri/the Action Button read `OpenGateIntent`'s
/// `IntentDialog` aloud, which is why that intent's dialog strings must
/// stay short — see `OpenGateFlow.Outcome.dialog` and its call sites.
struct GateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ie.boboco.GateOpener.control") {
            ControlWidgetButton(action: OpenGateIntent()) {
                Label("Open Gate", systemImage: GateSymbol.name)
            }
            .tint(.accentColor)
        }
        .displayName("Open Gate")
        .description("Opens your Comelit gate")
    }
}
