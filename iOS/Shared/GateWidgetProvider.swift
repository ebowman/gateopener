import GateOpenerCore
import SwiftUI

#if canImport(WidgetKit)
import WidgetKit

/// Moved from `iOS/Widget/GateWidget.swift` into `iOS/Shared` (bead
/// gateopener-3d7.9) so the watchOS widget extension reuses the identical
/// snapshot-driven provider; it is platform-neutral (app-group defaults only).
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
#endif
