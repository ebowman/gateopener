import SwiftUI
import Observation
import GateOpenerCore

/// Bead gateopener-pi0.3: the guaranteed feedback channel for Action Button
/// presses (notifications can be denied). Shows the outcome of the most
/// recent press within the last 15 minutes, read from the shared journal.
@MainActor
@Observable
final class LastPressBanner {
    struct Display: Equatable {
        let pressId: UUID
        let title: String
        let subtitle: String
    }

    nonisolated static let window: Duration = .seconds(15 * 60)
    /// A press from the in-app Open button newer than this is the one the
    /// user just watched on screen, so it is not echoed back.
    nonisolated static let appSuppressionSeconds: TimeInterval = 60

    private(set) var display: Display?
    var isVisible: Bool { display != nil }

    @ObservationIgnored private let journal: OpenAttemptJournal?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let now: @Sendable () -> Date

    init(journal: OpenAttemptJournal?, settings: AppSettings, now: @escaping @Sendable () -> Date = { Date() }) {
        self.journal = journal
        self.settings = settings
        self.now = now
    }

    /// Reads the journal off the main actor, then publishes the result.
    func refresh() async {
        guard let journal else {
            display = nil
            return
        }
        let at = now()
        let group = await Task.detached(priority: .utility) {
            journal.mostRecentPress(within: Self.window, now: at)
        }.value
        display = Self.display(for: group, now: at, dismissedPressId: settings.dismissedLastPressId)
    }

    /// Hides the current press until a newer one appears.
    func dismiss() {
        guard let display else { return }
        settings.dismissedLastPressId = display.pressId
        self.display = nil
    }

    // MARK: - Pure helpers

    nonisolated static func display(for group: OpenPressGroup?, now: Date, dismissedPressId: UUID?) -> Display? {
        guard let group, let pressId = group.pressId else { return nil }
        if pressId == dismissedPressId { return nil }
        if group.source == "app", now.timeIntervalSince(group.time) < appSuppressionSeconds { return nil }
        return Display(
            pressId: pressId,
            title: title(for: group.result),
            subtitle: subtitle(for: group, now: now)
        )
    }

    nonisolated static func title(for result: OpenPressGroup.Result) -> String {
        switch result {
        case .accepted: return "Last press: Accepted by cloud"
        case .failed(let message?): return "Last press: Failed — \(message)"
        case .failed(nil): return "Last press: Failed"
        case .timedOut: return "Last press: Timed out"
        case .unfinished: return "Last press: Unfinished — iOS stopped it"
        }
    }

    nonisolated static func subtitle(for group: OpenPressGroup, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(group.time) / 60))
        let sends = group.sendCount
        return "\(group.sourceLabel) · \(minutes) min ago · \(sends) \(sends == 1 ? "send" : "sends")"
    }
}

/// The banner row. Owns its view model; refreshes on appear, when the scene
/// becomes active, and after each in-app open finishes. Always present in the
/// layout (empty when hidden) so those triggers keep firing.
struct LastPressBannerView: View {
    let journal: OpenAttemptJournal?
    let settings: AppSettings
    let state: GateState

    @State private var model: LastPressBanner
    @Environment(\.scenePhase) private var scenePhase

    init(journal: OpenAttemptJournal?, settings: AppSettings, state: GateState) {
        self.journal = journal
        self.settings = settings
        self.state = state
        _model = State(initialValue: LastPressBanner(journal: journal, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let display = model.display {
                BannerRow(display: display, journal: journal) { model.dismiss() }
                    .transition(.opacity)
            }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .onChange(of: state) { _, newState in
            switch newState {
            case .succeeded, .failed: Task { await model.refresh() }
            default: break
            }
        }
    }
}

private struct BannerRow: View {
    let display: LastPressBanner.Display
    let journal: OpenAttemptJournal?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink {
                OpenHistoryView(journal: journal)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.title).font(.subheadline.weight(.semibold))
                    Text(display.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

#if DEBUG
#Preview("Accepted") {
    BannerRow(display: .init(pressId: UUID(), title: "Last press: Accepted by cloud",
                             subtitle: "Action Button / Control · 2 min ago · 2 sends"),
              journal: nil, onDismiss: {})
}
#Preview("Failed") {
    BannerRow(display: .init(pressId: UUID(), title: "Last press: Failed — HTTP 500",
                             subtitle: "Action Button / Control · 1 min ago · 1 send"),
              journal: nil, onDismiss: {})
}
#Preview("Unfinished") {
    BannerRow(display: .init(pressId: UUID(), title: "Last press: Unfinished — iOS stopped it",
                             subtitle: "Action Button / Control · 3 min ago · 0 sends"),
              journal: nil, onDismiss: {})
}
#endif
