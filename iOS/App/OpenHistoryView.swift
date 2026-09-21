import SwiftUI
import GateOpenerCore

/// Bead gateopener-41m.3: an "Open history" screen so the user can see WHY
/// an Action Button/widget/app open failed, and share it.
///
/// Reads `journal.entries()` fresh every time this view appears (and via
/// pull-to-refresh) rather than caching at `init` — the journal is written
/// by BOTH this app process AND the out-of-process Action Button/widget
/// intent (`OpenGateIntent`, `openAppWhenRun = false`), so a record can land
/// on disk without this process ever observing a state change.
struct OpenHistoryView: View {
    /// `nil` when the App Group container is unavailable, or a mock gate
    /// client was injected (`--mock-gate`) — see `AppEnvironment
    /// .openAttemptJournal`'s doc comment. Distinguished in the UI from "no
    /// entries yet" (an empty, non-nil journal): see `body`.
    var journal: OpenAttemptJournal?

    @State private var entries: [OpenAttemptRecord] = []

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

    private var shareText: String? {
        guard !entries.isEmpty else { return nil }
        let prefix = "GateOpener \(appVersion) — \(Self.shareDateFormatter.string(from: Date()))"
        return Self.shareText(for: entries, prefix: prefix)
    }

    var body: some View {
        List {
            if journal == nil {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "clock.badge.exclamationmark"
                )
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "No opens recorded yet",
                    systemImage: "clock",
                    description: Text("Opens from the app, widget and Action Button appear here.")
                )
            } else {
                ForEach(Self.groups(from: entries), id: \.id) { group in
                    Section {
                        ForEach(Array(group.records.enumerated()), id: \.offset) { _, record in
                            row(for: record)
                        }
                    } header: {
                        HStack {
                            Text(Self.groupHeaderDateFormatter.string(from: group.records.first?.timestamp ?? Date()))
                            Spacer()
                            Text(group.resultBadge)
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
                    journal?.clear()
                    reload()
                }
                .disabled(entries.isEmpty)
            }
        }
    }

    private func row(for record: OpenAttemptRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.rowTimeFormatter.string(from: record.timestamp))
                    .font(.subheadline)
                Text("Attempt \(record.attempt) of \(record.maxAttempts)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.outcomeText(for: record.outcome))
                    .font(.subheadline)
                HStack(spacing: 4) {
                    Text(Self.elapsedText(forMilliseconds: record.elapsedMilliseconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if record.willRetry {
                        Text("retrying")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func reload() {
        entries = journal?.entries() ?? []
    }

    // MARK: - Pure, unit-testable helpers

    /// One group per open call: a new group starts at every record whose
    /// `attempt == 1`. Records before the first `attempt == 1` record
    /// (possible after the journal has been trimmed mid-open) form a
    /// leading group. Returned newest group first; within a group, oldest
    /// attempt first.
    ///
    /// `nonisolated` (and every pure helper below) despite `OpenHistoryView`
    /// being a `View` (implicitly `@MainActor`-isolated under this project's
    /// `SWIFT_STRICT_CONCURRENCY: complete` setting): these are pure
    /// functions over `Sendable` value types with no UI/actor state, and
    /// tests call them directly off the main actor.
    nonisolated struct Group: Identifiable {
        let id: Int
        let records: [OpenAttemptRecord]

        var resultBadge: String {
            records.contains { if case .success = $0.outcome { return true } else { return false } } ? "Opened" : "Failed"
        }
    }

    nonisolated static func groups(from entries: [OpenAttemptRecord]) -> [Group] {
        var groups: [[OpenAttemptRecord]] = []
        for record in entries {
            if record.attempt == 1 || groups.isEmpty {
                groups.append([record])
            } else {
                groups[groups.count - 1].append(record)
            }
        }
        return groups.enumerated().map { index, records in
            Group(id: index, records: records)
        }.reversed()
    }

    /// success(s) → "Opened (s)"; httpFailure(s) → "HTTP s"; transportFailure
    /// mapped per common `URLError` codes; tokenFailure(d) → "Sign-in/token
    /// failure (d)".
    nonisolated static func outcomeText(for outcome: OpenAttemptOutcome) -> String {
        switch outcome {
        case .success(let status):
            return "Opened (\(status))"
        case .httpFailure(let status):
            return "HTTP \(status)"
        case .transportFailure(let code):
            switch code {
            case -1001:
                return "Network: timed out"
            case -1009:
                return "Network: offline"
            case -1005:
                return "Network: connection lost"
            case -1003, -1004:
                return "Network: cannot reach host"
            case -1:
                return "Network error"
            default:
                return "Network error \(code)"
            }
        case .tokenFailure(let description):
            return "Sign-in/token failure (\(description))"
        }
    }

    /// "2.9 s" — one decimal place.
    nonisolated static func elapsedText(forMilliseconds milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000.0
        return String(format: "%.1f s", seconds)
    }

    /// One line per record: ISO8601 local timestamp, attempt n/m, outcome
    /// text, elapsed ms, and a trailing retry flag; prefixed with the
    /// caller-supplied `prefix` line (e.g. "GateOpener 1.0 (10) — Sep 21,
    /// 2026 at 9:00 AM").
    nonisolated static func shareText(for entries: [OpenAttemptRecord], prefix: String) -> String {
        let lines = entries.map(shareLine(for:))
        return ([prefix, ""] + lines).joined(separator: "\n")
    }

    /// A fresh `ISO8601DateFormatter` per call, deliberately NOT cached in a
    /// `static let`: `ISO8601DateFormatter` is not `Sendable`, so a shared
    /// mutable static would be rejected under this project's
    /// `SWIFT_STRICT_CONCURRENCY: complete` setting (and would be an actual
    /// data race if ever called concurrently from multiple threads). Share
    /// text is only ever built for a bounded (<= `OpenAttemptJournal
    /// .capacity`, 200) list of records, so the per-call construction cost
    /// here is immaterial.
    private nonisolated static func shareLine(for record: OpenAttemptRecord) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: record.timestamp)
        let outcome = outcomeText(for: record.outcome)
        let retry = record.willRetry ? " (retrying)" : ""
        return "\(timestamp) attempt \(record.attempt)/\(record.maxAttempts) \(outcome) \(record.elapsedMilliseconds) ms\(retry)"
    }

    private static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let groupHeaderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
