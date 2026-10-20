import SwiftUI
import GateOpenerCore

/// Bead gateopener-41m.3 (original), reworked by gateopener-41m.24: an "Open
/// history" screen so the user can see WHY an Action Button/widget/app open
/// failed, and share it — grouped one row PER PRESS (not per legacy
/// attempt-1 heuristic), including presses that never finished, so a user
/// who mashed the Action Button three times can see which press actually
/// opened the gate and where the others died.
///
/// Reads `journal.journalEntries()` fresh every time this view appears (and
/// via pull-to-refresh) rather than caching at `init` — the journal is
/// written by BOTH this app process AND the out-of-process Action
/// Button/widget intent (`OpenGateIntent`, `openAppWhenRun = false`), so a
/// record can land on disk without this process ever observing a state
/// change.
struct OpenHistoryView: View {
    /// `nil` when the App Group container is unavailable, or a mock gate
    /// client was injected (`--mock-gate`) — see `AppEnvironment
    /// .openAttemptJournal`'s doc comment. Distinguished in the UI from "no
    /// entries yet" (an empty, non-nil journal): see `body`.
    var journal: OpenAttemptJournal?

    /// Transfers sent from the watch (bead gateopener-3d7.17); injectable for tests.
    var watchHistory: WatchHistoryStore? = SharedContainer.watchHistoryURL().map(WatchHistoryStore.init(url:))

    @State private var entries: [OpenJournalEntry] = []
    @State private var watchTransfers: [WatchHistoryStore.Transfer] = []
    @State private var isConfirmingClear = false

    private var appVersion: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(shortVersion) (\(build))"
    }

    private static let shareDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var groups: [OpenPressGroup] {
        OpenHistoryText.groups(from: entries)
    }

    private var shareText: String? {
        guard !entries.isEmpty || !watchTransfers.isEmpty else { return nil }
        let prefix = "GateOpener \(appVersion) — \(Self.shareDateFormatter.string(from: Date()))"
        return OpenHistoryText.shareText(for: entries, prefix: prefix, watchTransfers: watchTransfers)
    }

    var body: some View {
        List {
            if journal == nil {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "clock.badge.exclamationmark"
                )
            } else if entries.isEmpty && watchTransfers.isEmpty {
                ContentUnavailableView(
                    "No opens recorded yet",
                    systemImage: "clock",
                    description: Text("Opens from the app, widget and Action Button appear here.")
                )
            } else {
                Text(OpenHistoryText.acceptedFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(groups) { group in
                    Section {
                        DisclosureGroup {
                            ForEach(Array(OpenHistoryText.timelineLines(for: group).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if group.resultBadge == "Unfinished" {
                                Text(OpenHistoryText.unfinishedFootnote)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(OpenHistoryText.makeGroupHeaderDateFormatter().string(from: group.time))
                                    Text(group.sourceLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(group.resultBadge)
                            }
                        }
                    }
                }
            }
            if journal != nil, !watchTransfers.isEmpty {
                Section {
                    DisclosureGroup("From watch") {
                        ForEach(watchTransfers, id: \.sentAt) { transfer in
                            Text(transfer.text)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Open history")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear { reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let shareText {
                    ShareLink("Share", item: shareText)
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Clear", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear open history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                journal?.clear()
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all recorded open attempts from this device.")
        }
    }

    private func reload() {
        entries = journal?.journalEntries() ?? []
        watchTransfers = watchHistory?.transfers() ?? []
    }
}
