import GateOpenerCore
import SwiftUI
import WidgetKit

#if canImport(AppIntents)
import AppIntents
#endif

/// A single widget-timeline entry: everything `GateWidgetEntryView` needs to
/// render one snapshot, for one `WidgetFamily`, at one point in time.
///
/// Lives in `iOS/Shared` (compiled into the app AND the widget extension)
/// rather than `iOS/Widget`, per bead gateopener-672.14 step 7: the DEBUG
/// `--widget-preview` launch flag in the app target renders these SAME
/// views the real widget extension renders, so a screenshot of the app's
/// plain SwiftUI list is real evidence the widget views compile and render
/// correctly — the `TimelineProvider`/`WidgetBundle` machinery (which only
/// the extension process ever runs) stays in `iOS/Widget`.
public struct GateWidgetEntry: TimelineEntry, Sendable {
    public let date: Date
    public let gateName: String?
    public let phase: WidgetSnapshot.Phase
    public let message: String?
    /// `true` only for the synthetic "App Group missing" diagnostic entry
    /// (`SharedContainer.sharedDefaults()` returned `nil`). Never occurs in
    /// a correctly-entitled build; exists purely so a misconfiguration is
    /// visible in the widget rather than silently blank.
    public let appGroupMissing: Bool

    public init(
        date: Date,
        gateName: String?,
        phase: WidgetSnapshot.Phase,
        message: String?,
        appGroupMissing: Bool = false
    ) {
        self.date = date
        self.gateName = gateName
        self.phase = phase
        self.message = message
        self.appGroupMissing = appGroupMissing
    }

    /// A sensible idle placeholder/snapshot entry for the widget gallery,
    /// before any real `WidgetSnapshot` has ever been written.
    public static func placeholder(date: Date = Date()) -> GateWidgetEntry {
        GateWidgetEntry(date: date, gateName: nil, phase: .idle, message: nil)
    }

    /// Maps a real `WidgetSnapshot` (read from the app-group defaults) to a
    /// timeline entry.
    public static func from(snapshot: WidgetSnapshot) -> GateWidgetEntry {
        GateWidgetEntry(
            date: snapshot.updatedAt,
            gateName: snapshot.gateName,
            phase: snapshot.phase,
            message: snapshot.message
        )
    }

    /// The "App Group missing" diagnostic entry, used when
    /// `SharedContainer.sharedDefaults()` returns `nil`.
    public static func appGroupMissing(date: Date = Date()) -> GateWidgetEntry {
        GateWidgetEntry(date: date, gateName: nil, phase: .needsSetup, message: nil, appGroupMissing: true)
    }
}

/// Renders one `GateWidgetEntry` for a given `WidgetFamily`. Used by the
/// real widget extension (`iOS/Widget/GateWidget.swift`) AND, via the
/// DEBUG-only `--widget-preview` launch flag, by the app itself (see
/// `iOS/App/WidgetPreviewView.swift`) so both consumers share exactly one
/// rendering implementation.
public struct GateWidgetEntryView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    public let entry: GateWidgetEntry

    /// Overrides `@Environment(\.widgetFamily)` when non-`nil`. `\.widgetFamily`
    /// is a READ-ONLY environment key from outside WidgetKit's own timeline
    /// rendering (there is no `WritableKeyPath` overload of `.environment(_:_:)`
    /// for it), so the app's DEBUG-only `--widget-preview` harness
    /// (`iOS/App/WidgetPreviewView.swift`), which needs to force every
    /// family in a plain list, passes this explicitly instead. The real
    /// widget extension never sets this — it relies on WidgetKit itself
    /// populating `\.widgetFamily` from the family the timeline is
    /// currently rendering.
    private let familyOverride: WidgetFamily?

    private var family: WidgetFamily {
        familyOverride ?? environmentFamily
    }

    public init(entry: GateWidgetEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    public var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                accessoryCircularBody
            case .accessoryRectangular:
                accessoryRectangularBody
            case .systemMedium:
                systemMediumBody
            default:
                systemSmallBody
            }
        }
        .widgetURL(URL(string: "gateopener://main"))
    }

    // MARK: - Shared bits

    private var gateDisplayName: String {
        entry.gateName ?? "Gate"
    }

    private var isNeedsSetup: Bool {
        entry.appGroupMissing || entry.phase == .needsSetup
    }

    private var tint: Color {
        if entry.appGroupMissing { return .red }
        switch entry.phase {
        case .needsSetup: return .accentColor
        case .idle: return .accentColor
        case .queued, .opening: return .orange
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private var outcomeText: String {
        if entry.appGroupMissing {
            return "App Group missing"
        }
        switch entry.phase {
        case .needsSetup:
            return "Open GateOpener to sign in"
        case .idle:
            return "Ready"
        case .queued:
            return "Waiting for network…"
        case .opening:
            return "Opening…"
        case .succeeded:
            return "Opened \(Self.timeFormatter.string(from: entry.date))"
        case .failed:
            return "Failed: \(entry.message ?? "Unknown error")"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var openButton: some View {
        Button(intent: OpenGateIntent()) {
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.title)
                Text("Open")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(isNeedsSetup)
    }

    // MARK: - systemSmall

    private var systemSmallBody: some View {
        VStack(spacing: 8) {
            Text(gateDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            openButton
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    // MARK: - systemMedium

    private var systemMediumBody: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(gateDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(outcomeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            openButton
                .frame(width: 96)
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
    }

    // MARK: - accessoryCircular

    private var accessoryCircularBody: some View {
        Button(intent: OpenGateIntent()) {
            Image(systemName: "lock.fill")
        }
        .disabled(isNeedsSetup)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    // MARK: - accessoryRectangular

    private var accessoryRectangularBody: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(gateDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(outcomeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

/// Sample entries covering every phase, for both `#Preview` (in
/// `iOS/Widget/GateWidget.swift`, the only place the `Widget`-conforming
/// `GateWidget` type — required by `#Preview(as:)` — is visible) and the
/// app's DEBUG-only `--widget-preview` launch flag
/// (`iOS/App/WidgetPreviewView.swift`), so both consumers render the exact
/// same sample data.
public enum GateWidgetSampleEntries {
    public static let idle = GateWidgetEntry(date: .now, gateName: "Front Gate", phase: .idle, message: nil)
    public static let queued = GateWidgetEntry(date: .now, gateName: "Front Gate", phase: .queued, message: nil)
    public static let opening = GateWidgetEntry(date: .now, gateName: "Front Gate", phase: .opening, message: nil)
    public static let succeeded = GateWidgetEntry(date: .now, gateName: "Front Gate", phase: .succeeded, message: nil)
    public static let failed = GateWidgetEntry(date: .now, gateName: "Front Gate", phase: .failed, message: "Network timeout")
    public static let needsSetup = GateWidgetEntry(date: .now, gateName: nil, phase: .needsSetup, message: nil)

    public static let all: [(String, GateWidgetEntry)] = [
        ("Idle", idle),
        ("Queued", queued),
        ("Opening", opening),
        ("Succeeded", succeeded),
        ("Failed", failed),
        ("Needs Setup", needsSetup),
    ]
}
