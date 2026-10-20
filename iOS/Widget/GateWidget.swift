import GateOpenerCore
import SwiftUI
import WidgetKit

/// `StaticConfiguration` for the one-tap gate-open widget (bead
/// gateopener-672.14 step 2/3). The interactive `Button(intent:
/// OpenGateIntent())` inside `GateWidgetEntryView` (`iOS/Shared`) runs the
/// shared `OpenGateIntent` (`openAppWhenRun = false`) entirely inside this
/// extension process, without launching the app.
struct GateWidget: Widget {
    let kind: String = "ie.boboco.GateOpener.gate"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GateProvider()) { entry in
            GateWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Open Gate")
        .description("One tap to open your gate.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Previews

#Preview("Small - idle", as: .systemSmall) {
    GateWidget()
} timeline: {
    GateWidgetSampleEntries.idle
}

#Preview("Small - needsSetup", as: .systemSmall) {
    GateWidget()
} timeline: {
    GateWidgetSampleEntries.needsSetup
}

#Preview("Medium - opening", as: .systemMedium) {
    GateWidget()
} timeline: {
    GateWidgetSampleEntries.opening
}

#Preview("Medium - succeeded", as: .systemMedium) {
    GateWidget()
} timeline: {
    GateWidgetSampleEntries.succeeded
}

#Preview("Medium - failed", as: .systemMedium) {
    GateWidget()
} timeline: {
    GateWidgetSampleEntries.failed
}

#Preview("Circular", as: .accessoryCircular) {
    GateWidget()
} timeline: {
    GateWidgetSampleEntries.idle
}

#Preview("Rectangular", as: .accessoryRectangular) {
    GateWidget()
} timeline: {
    GateWidgetSampleEntries.queued
}
