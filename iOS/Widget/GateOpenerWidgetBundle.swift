import SwiftUI
import WidgetKit

/// The widget extension's entry point. Currently a single widget kind
/// (`GateWidget`); a `WidgetBundle` (rather than a bare `@main Widget`) is
/// used so a later bead (gateopener-672.15's Control Center control, or any
/// future Lock Screen widget) can be added here without restructuring.
@main
struct GateOpenerWidgetBundle: WidgetBundle {
    var body: some Widget {
        GateWidget()
    }
}
