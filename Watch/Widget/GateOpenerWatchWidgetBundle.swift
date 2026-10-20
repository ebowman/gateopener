import SwiftUI
import WidgetKit

/// The watchOS widget extension's entry point (bead gateopener-3d7.9).
@main
struct GateOpenerWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        GateWatchWidget()
        if #available(watchOS 26.0, *) {
            GateControl()
        }
    }
}
