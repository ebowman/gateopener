import GateOpenerCore
import SwiftUI
import WidgetKit

/// The Home Screen / Lock Screen widget's `TimelineProvider`.
///
/// Reads only from the app-group `UserDefaults` (`WidgetSnapshotStore`) —
/// NEVER touches the network, per bead gateopener-672.14's edge case: the
/// provider must not block. Every `getTimeline` call returns exactly ONE
/// entry with `.never` reload policy; the app/`OpenGateIntent` explicitly
/// call `WidgetCenter.shared.reloadAllTimelines()` whenever the underlying
/// `WidgetSnapshot` changes (see `AppEnvironment.publishSnapshot()` and
/// `OpenGateIntent.runFlow`), so the widget never needs to poll.
struct GateProvider: TimelineProvider {
    func placeholder(in context: Context) -> GateWidgetEntry {
        .placeholder()
    }

    func getSnapshot(in context: Context, completion: @escaping (GateWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GateWidgetEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .never))
    }

    /// Reads the current `WidgetSnapshot` from the app-group defaults. If
    /// `SharedContainer.sharedDefaults()` is `nil` (the App Group
    /// entitlement is missing/misconfigured on this extension), returns a
    /// visible "App Group missing" diagnostic entry rather than silently
    /// rendering blank — per bead gateopener-672.14's edge case.
    private func currentEntry() -> GateWidgetEntry {
        guard let defaults = SharedContainer.sharedDefaults() else {
            return .appGroupMissing()
        }
        guard let snapshot = WidgetSnapshotStore(defaults: defaults).read() else {
            return .placeholder()
        }
        return .from(snapshot: snapshot)
    }
}

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
