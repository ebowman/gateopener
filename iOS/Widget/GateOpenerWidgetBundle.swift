import SwiftUI
import WidgetKit

/// The widget extension's entry point. `GateWidget` is the Home Screen /
/// Lock Screen widget (bead gateopener-672.14); `GateControl` is the
/// Control Center / Lock Screen bottom controls / Action Button control
/// (bead gateopener-672.15). A `WidgetBundle` (rather than a bare `@main
/// Widget`) is used so both — and any future Lock Screen widget — can live
/// here without restructuring.
@main
struct GateOpenerWidgetBundle: WidgetBundle {
    var body: some Widget {
        GateWidget()
        GateControl()
    }
}
