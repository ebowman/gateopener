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

    @State private var entries: [OpenJournalEntry] = []
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

    private var groups: [Group] {
        Self.groups(from: entries)
    }

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
                ForEach(groups) { group in
                    Section {
                        DisclosureGroup {
                            ForEach(Array(Self.timelineLines(for: group).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if group.resultBadge == "Unfinished" {
                                Text(Self.unfinishedFootnote)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.groupHeaderDateFormatter.string(from: group.time))
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
    }

    // MARK: - Pure, unit-testable helpers

    /// One group per PRESS: every `OpenPressRecord`/`OpenAttemptRecord`
    /// sharing the same `pressId`. `OpenAttemptRecord`s with no `pressId`
    /// (predating bead gateopener-41m.22, or produced outside any press
    /// context) fall back to the OLD attempt==1 heuristic, forming their own
    /// "legacy" groups labelled source "Unknown (older build)".
    ///
    /// A group's `time` is its `.started` press record's timestamp; failing
    /// that (a press whose `.started` line fell off the journal via
    /// trimming), the earliest entry in the group. Legacy groups use their
    /// first record's timestamp, exactly as before.
    ///
    /// Returned newest group first, by `time`.
    ///
    /// `nonisolated` (and every pure helper below) despite `OpenHistoryView`
    /// being a `View` (implicitly `@MainActor`-isolated under this project's
    /// `SWIFT_STRICT_CONCURRENCY: complete` setting): these are pure
    /// functions over `Sendable` value types with no UI/actor state, and
    /// tests call them directly off the main actor.
    nonisolated struct Group: Identifiable {
        let id: String
        let time: Date
        /// The raw `OpenPressRecord.source` of this group's `.started`
        /// phase, or `nil` for a legacy (pressId-less) group.
        let source: String?
        /// Every entry (press phases and attempts) belonging to this press,
        /// in the order they appear in the journal (oldest first).
        let entries: [OpenJournalEntry]

        /// "Action Button / Control" for "intent", "App" for "app", the raw
        /// value for anything else, "Unknown (older build)" for a legacy
        /// group with no `pressId` at all.
        var sourceLabel: String {
            guard let source else { return "Unknown (older build)" }
            return OpenHistoryView.sourceLabel(for: source)
        }

        var resultBadge: String {
            OpenHistoryView.resultBadge(for: self)
        }
    }

    /// "Action Button / Control" for "intent", "App" for "app", the raw
    /// value for anything else.
    nonisolated static func sourceLabel(for source: String) -> String {
        switch source {
        case "intent":
            return "Action Button / Control"
        case "app":
            return "App"
        default:
            return source
        }
    }

    nonisolated static let unfinishedFootnote =
        "This press started but never reported a result — iOS may have stopped the extension before it finished."

    nonisolated static func groups(from entries: [OpenJournalEntry]) -> [Group] {
        var byPressId: [UUID: [OpenJournalEntry]] = [:]
        var pressOrder: [UUID] = []
        var legacyAttempts: [OpenAttemptRecord] = []

        for entry in entries {
            switch entry {
            case .press(let press):
                if byPressId[press.pressId] == nil {
                    pressOrder.append(press.pressId)
                }
                byPressId[press.pressId, default: []].append(entry)
            case .attempt(let attempt):
                guard let pressId = attempt.pressId else {
                    legacyAttempts.append(attempt)
                    continue
                }
                if byPressId[pressId] == nil {
                    pressOrder.append(pressId)
                }
                byPressId[pressId, default: []].append(entry)
            }
        }

        var groups: [Group] = pressOrder.map { pressId in
            let groupEntries = byPressId[pressId] ?? []
            let startedRecord = groupEntries.compactMap { entry -> OpenPressRecord? in
                if case .press(let press) = entry, case .started = press.phase { return press }
                return nil
            }.first
            let time = startedRecord?.timestamp ?? groupEntries.map(timestamp(of:)).min() ?? Date()
            let source = startedRecord?.source
            return Group(id: pressId.uuidString, time: time, source: source, entries: groupEntries)
        }

        groups.append(contentsOf: legacyGroups(from: legacyAttempts))

        return groups.sorted { $0.time > $1.time }
    }

    /// Legacy fallback grouping for `OpenAttemptRecord`s with no `pressId`:
    /// the pre-gateopener-41m.24 attempt==1 heuristic. Records before the
    /// first `attempt == 1` record (possible after the journal has been
    /// trimmed mid-open) form a leading group. Ids are stable (derived from
    /// the group's first timestamp + its index among legacy groups), not
    /// positional in the combined list, so `List` animates correctly across
    /// reloads.
    private nonisolated static func legacyGroups(from attempts: [OpenAttemptRecord]) -> [Group] {
        var rawGroups: [[OpenAttemptRecord]] = []
        for record in attempts {
            if record.attempt == 1 || rawGroups.isEmpty {
                rawGroups.append([record])
            } else {
                rawGroups[rawGroups.count - 1].append(record)
            }
        }
        let isoFormatter = ISO8601DateFormatter()
        return rawGroups.enumerated().map { index, records in
            let time = records.first?.timestamp ?? Date()
            let id = "legacy-\(isoFormatter.string(from: time))-\(index)"
            return Group(id: id, time: time, source: nil, entries: records.map { .attempt($0) })
        }
    }

    private nonisolated static func timestamp(of entry: OpenJournalEntry) -> Date {
        switch entry {
        case .press(let press): return press.timestamp
        case .attempt(let attempt): return attempt.timestamp
        }
    }

    /// Result badge precedence for a press-backed group: `.finished` beats
    /// `.timedOut` beats "no terminal phase yet" (`Unfinished`) — though in
    /// practice a press only ever emits ONE of `.finished`/`.timedOut`, this
    /// searches for `.finished` first to match the bead's documented
    /// precedence. A legacy (pressId-less) group has no phases at all, so it
    /// keeps the OLD attempt-outcome-scan logic (Opened if any attempt in
    /// the group succeeded, else Failed).
    nonisolated static func resultBadge(for group: Group) -> String {
        guard group.source != nil else {
            return legacyResultBadge(for: group.entries)
        }

        for entry in group.entries {
            guard case .press(let press) = entry, case .finished(let outcome) = press.phase else { continue }
            if outcome == "Gate opened" { return "Opened" }
            if outcome == "No network" { return "No network" }
            return "Failed: \(outcome)"
        }
        for entry in group.entries {
            guard case .press(let press) = entry, case .timedOut = press.phase else { continue }
            return "Timed out"
        }
        return "Unfinished"
    }

    private nonisolated static func legacyResultBadge(for entries: [OpenJournalEntry]) -> String {
        let attempts = entries.compactMap { entry -> OpenAttemptRecord? in
            if case .attempt(let record) = entry { return record }
            return nil
        }
        return attempts.contains { if case .success = $0.outcome { return true } else { return false } } ? "Opened" : "Failed"
    }

    /// Full phase/attempt timeline for one press group, oldest first, each
    /// line prefixed with its "+offset" from the press's `.started` phase.
    /// Press lines use the press record's own `elapsedMilliseconds`; attempt
    /// lines compute their offset as `attempt.timestamp - startedTimestamp`,
    /// clamped to >= 0 (an attempt's wall-clock timestamp could in principle
    /// race slightly behind the press-relative elapsed clock).
    ///
    /// A legacy (pressId-less) group has no phase lines at all — this
    /// returns one line per attempt, mirroring the pre-gateopener-41m.24
    /// share-line format (no offset prefix, since there is no press start to
    /// offset from).
    nonisolated static func timelineLines(for group: Group) -> [String] {
        guard group.source != nil else {
            return legacyTimelineLines(for: group.entries)
        }

        let startedTimestamp = group.entries.compactMap { entry -> Date? in
            if case .press(let press) = entry, case .started = press.phase { return press.timestamp }
            return nil
        }.first ?? group.time

        return group.entries.map { entry in
            switch entry {
            case .press(let press):
                return pressLine(for: press)
            case .attempt(let attempt):
                let offsetMilliseconds = max(0, Int(attempt.timestamp.timeIntervalSince(startedTimestamp) * 1000))
                return attemptLine(for: attempt, offsetMilliseconds: offsetMilliseconds)
            }
        }
    }

    private nonisolated static func legacyTimelineLines(for entries: [OpenJournalEntry]) -> [String] {
        entries.compactMap { entry -> String? in
            guard case .attempt(let record) = entry else { return nil }
            let outcome = outcomeText(for: record.outcome)
            let retry = record.willRetry ? "  retrying" : ""
            return "attempt \(record.attempt)/\(record.maxAttempts) \(outcome) \(elapsedText(forMilliseconds: record.elapsedMilliseconds))\(retry)"
        }
    }

    private nonisolated static func pressLine(for press: OpenPressRecord) -> String {
        let offset = offsetText(forMilliseconds: press.elapsedMilliseconds)
        switch press.phase {
        case .started:
            return "\(offset) started (\(sourceLabel(for: press.source)), \(press.appVersion))"
        case .environmentReady:
            return "\(offset) environment ready"
        case .reachability(let isReachable, let detail):
            if isReachable {
                return "\(offset) network: \(detail)"
            }
            return "\(offset) network: unreachable — \(detail)"
        case .tokenResolved(let kind):
            return "\(offset) token: \(kind)"
        case .tokenFailed(let description):
            return "\(offset) token failed: \(description)"
        case .openStarted:
            return "\(offset) open started"
        case .finished(let outcome):
            return "\(offset) finished: \(outcome)"
        case .timedOut:
            return "\(offset) timed out"
        }
    }

    private nonisolated static func attemptLine(for attempt: OpenAttemptRecord, offsetMilliseconds: Int) -> String {
        let offset = offsetText(forMilliseconds: offsetMilliseconds)
        let outcome = outcomeText(for: attempt.outcome)
        let retry = attempt.willRetry ? "  retrying" : ""
        return "\(offset) attempt \(attempt.attempt)/\(attempt.maxAttempts) \(outcome) \(elapsedText(forMilliseconds: attempt.elapsedMilliseconds))\(retry)"
    }

    /// "+0 ms" / "+412 ms" for offsets under 1000 ms; "+1.9 s" / "+25.0 s"
    /// (one decimal place) for offsets >= 1000 ms.
    nonisolated static func offsetText(forMilliseconds milliseconds: Int) -> String {
        guard milliseconds >= 1_000 else { return "+\(milliseconds) ms" }
        let seconds = Double(milliseconds) / 1000.0
        return String(format: "+%.1f s", seconds)
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

    /// One block per press: a header line (time + source + badge), then the
    /// press's `timelineLines(for:)`, each indented two spaces, then a blank
    /// separator line before the next press's block. Prefixed with the
    /// caller-supplied `prefix` line (e.g. "GateOpener 1.0 (10) — Sep 21,
    /// 2026 at 9:00 AM").
    nonisolated static func shareText(for entries: [OpenJournalEntry], prefix: String) -> String {
        var lines = [prefix, ""]
        for group in groups(from: entries) {
            lines.append("\(groupHeaderDateFormatter.string(from: group.time)) — \(group.sourceLabel) — \(resultBadge(for: group))")
            for line in timelineLines(for: group) {
                lines.append("  \(line)")
            }
            lines.append("")
        }
        // Drop the single trailing blank separator line after the last
        // press, so the text doesn't end with an extra empty line.
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static let groupHeaderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
