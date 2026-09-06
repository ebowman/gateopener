#if DEBUG
import GateOpenerCore
import SwiftUI
import WidgetKit

/// DEBUG-only verification screen (bead gateopener-672.14 step 7,
/// `--widget-preview` launch flag): renders `GateWidgetEntryView`
/// (`iOS/Shared/GateWidgetViews.swift` — the SAME view type the real
/// `GateOpenerWidget` extension renders) for every `WidgetFamily` the
/// widget supports, across every `GateWidgetSampleEntries` sample state, in
/// a plain SwiftUI list that a screenshot script can capture. This is the
/// only automatable evidence available for widget rendering: the widget
/// gallery and Xcode's preview canvas are not scriptable, and `xcrun
/// simctl` has no widget API.
///
/// Compiled ONLY into the app target (this whole file is `#if DEBUG`, and
/// lives in `iOS/App`, not `iOS/Shared`) — the widget extension never
/// needs it.
struct WidgetPreviewView: View {
    private static let families: [WidgetPreviewFamily] = [
        WidgetPreviewFamily(name: "systemSmall", family: .systemSmall),
        WidgetPreviewFamily(name: "systemMedium", family: .systemMedium),
        WidgetPreviewFamily(name: "accessoryCircular", family: .accessoryCircular),
        WidgetPreviewFamily(name: "accessoryRectangular", family: .accessoryRectangular),
    ]

    var body: some View {
        List {
            ForEach(GateWidgetSampleEntries.all, id: \.0) { stateName, entry in
                Section(stateName) {
                    ForEach(Self.families) { previewFamily in
                        WidgetPreviewRow(entry: entry, previewFamily: previewFamily)
                    }
                }
            }
        }
        .navigationTitle("Widget Preview")
    }
}

/// One `(name, WidgetFamily)` pairing, `Identifiable` so `ForEach` needs no
/// tuple `id:` key path (a likely contributor to the type-checker timeout
/// this file previously hit when everything was inlined as nested `ForEach`
/// closures over tuples).
private struct WidgetPreviewFamily: Identifiable {
    let name: String
    let family: WidgetFamily
    var id: String { name }
}

/// One rendered row: the family name label plus `GateWidgetEntryView`
/// itself, sized to roughly match the real widget family's on-device
/// dimensions. Extracted to its own `View` (rather than inlined in
/// `WidgetPreviewView.body`) so the compiler type-checks each piece
/// independently instead of one deeply nested expression.
private struct WidgetPreviewRow: View {
    let entry: GateWidgetEntry
    let previewFamily: WidgetPreviewFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(previewFamily.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            GateWidgetEntryView(entry: entry, familyOverride: previewFamily.family)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.vertical, 4)
    }

    private var size: CGSize {
        switch previewFamily.family {
        case .systemSmall:
            return CGSize(width: 160, height: 160)
        case .accessoryCircular:
            return CGSize(width: 160, height: 80)
        case .accessoryRectangular:
            return CGSize(width: 320, height: 60)
        default:
            return CGSize(width: 320, height: 160)
        }
    }
}
#endif
