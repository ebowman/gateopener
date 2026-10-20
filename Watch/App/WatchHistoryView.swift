import SwiftUI
import GateOpenerCore

/// Watch Open history (bead gateopener-3d7.17): latest <= 50 presses, newest
/// first; tap for the timeline; "Send to iPhone" forwards the share text.
struct WatchHistoryView: View {
    let journal: OpenAttemptJournal?

    @State private var groups: [OpenPressGroup] = []
    @State private var entries: [OpenJournalEntry] = []
    @State private var loaded = false
    @State private var sendResult: String?

    private static let maxGroups = 50

    var body: some View {
        List {
            if loaded && groups.isEmpty {
                Text("No presses yet").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                NavigationLink {
                    WatchHistoryDetailView(group: group)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.resultBadge).font(.headline)
                        Text("\(group.sourceLabel) · \(group.time.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !groups.isEmpty {
                Button("Send to iPhone") { send() }
                if let sendResult {
                    Text(sendResult).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("History")
        .task { await reload() }
    }

    private func reload() async {
        let journal = journal
        // Journal file I/O off the main actor.
        let loadedEntries = await Task.detached { journal?.journalEntries() ?? [] }.value
        entries = loadedEntries
        groups = Array(OpenHistoryText.groups(from: loadedEntries).prefix(Self.maxGroups))
        loaded = true
    }

    private func send() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let prefix = "GateOpener Watch \(version) (\(build)) — \(Date().formatted(date: .abbreviated, time: .shortened))"
        let text = OpenHistoryText.shareText(for: entries, prefix: prefix)
        sendResult = WatchHistorySender.send(text: text) ? "Queued for iPhone" : "Watch link not ready"
    }
}

struct WatchHistoryDetailView: View {
    let group: OpenPressGroup

    var body: some View {
        List {
            Text(group.resultBadge).font(.headline)
            ForEach(Array(OpenHistoryText.timelineLines(for: group).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospacedDigit())
            }
            if group.resultBadge == "Unfinished" {
                Text(OpenHistoryText.unfinishedFootnote).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(group.sourceLabel)
    }
}
