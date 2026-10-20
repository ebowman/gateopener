import GateOpenerCore
import SwiftUI
import WidgetKit

/// Smart Stack / watch-face widget (bead gateopener-3d7.9). Same
/// snapshot-driven `GateProvider` (`iOS/Shared/GateWidgetProvider.swift`)
/// and views as the iOS widget, under a distinct kind. The rectangular
/// family hosts an interactive `Button(intent: OpenGateIntent())`;
/// circular/corner/inline are non-interactive and use `.widgetURL`. When the
/// button is disabled (needsSetup) the outer `.widgetURL` opens the app. The
/// Smart Stack interactive tap is unverified on the simulator and is checked
/// on hardware in bead 3d7.12.
struct GateWatchWidget: Widget {
    let kind: String = "ie.boboco.GateOpener.watchgate"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GateProvider()) { entry in
            GateWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Open Gate")
        .description("One tap to open your gate.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

#Preview("Rectangular - idle", as: .accessoryRectangular) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.idle
}

#Preview("Rectangular - needsSetup", as: .accessoryRectangular) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.needsSetup
}

#Preview("Circular - idle", as: .accessoryCircular) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.idle
}

#Preview("Circular - needsSetup", as: .accessoryCircular) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.needsSetup
}

#Preview("Corner - idle", as: .accessoryCorner) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.idle
}

#Preview("Corner - needsSetup", as: .accessoryCorner) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.needsSetup
}

#Preview("Inline - idle", as: .accessoryInline) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.idle
}

#Preview("Inline - needsSetup", as: .accessoryInline) {
    GateWatchWidget()
} timeline: {
    GateWidgetSampleEntries.needsSetup
}
