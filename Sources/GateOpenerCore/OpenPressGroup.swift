import Foundation

/// One group per PRESS: every `OpenPressRecord`/`OpenAttemptRecord` sharing
/// the same `pressId`. Moved out of `OpenHistoryView` (bead gateopener-pi0.3)
/// so the history screen and the main-screen "last press" banner share ONE
/// grouping implementation.
///
/// `OpenAttemptRecord`s with no `pressId` (predating gateopener-41m.22) fall
/// back to the OLD attempt==1 heuristic, forming "legacy" groups
/// (`pressId == nil`, `source == nil`).
public struct OpenPressGroup: Identifiable, Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case accepted
        /// `nil` message only for legacy groups (no recorded outcome text).
        case failed(String?)
        case timedOut
        case unfinished
    }

    public let id: String
    /// `nil` for a legacy (pressId-less) group.
    public let pressId: UUID?
    public let time: Date
    /// The raw `OpenPressRecord.source` of this group's `.started` phase, or
    /// `nil` for a legacy group (or a press whose `.started` line was trimmed).
    public let source: String?
    /// Every entry belonging to this press, oldest first.
    public let entries: [OpenJournalEntry]

    public init(id: String, pressId: UUID?, time: Date, source: String?, entries: [OpenJournalEntry]) {
        self.id = id
        self.pressId = pressId
        self.time = time
        self.source = source
        self.entries = entries
    }

    public var sourceLabel: String {
        guard let source else { return "Unknown (older build)" }
        return Self.sourceLabel(for: source)
    }

    public var resultBadge: String { Self.resultBadge(for: self) }

    /// Number of send attempts (primary + confirmation) in this group.
    public var sendCount: Int {
        entries.reduce(0) { count, entry in
            if case .attempt = entry { return count + 1 }
            return count
        }
    }

    public var result: Result { Self.result(for: self) }

    // MARK: - Labels

    public static func sourceLabel(for source: String) -> String {
        switch source {
        case "intent": return "Action Button / Control"
        case "app": return "App"
        default: return source
        }
    }

    /// Result precedence for a press-backed group: `.finished` beats
    /// `.timedOut` beats "no terminal phase yet" (unfinished). A legacy group
    /// has no phases: accepted if any attempt succeeded, else failed.
    public static func result(for group: OpenPressGroup) -> Result {
        guard group.source != nil else {
            let attempts = group.entries.compactMap { entry -> OpenAttemptRecord? in
                if case .attempt(let record) = entry { return record }
                return nil
            }
            let ok = attempts.contains { if case .success = $0.outcome { return true } else { return false } }
            return ok ? .accepted : .failed(nil)
        }
        for entry in group.entries {
            guard case .press(let press) = entry, case .finished(let outcome) = press.phase else { continue }
            // "Gate opened" is the pre-pi0.4 literal still present in journal lines on disk.
            if outcome == OpenGateFlow.Outcome.acceptedDialog || outcome == "Gate opened" { return .accepted }
            return .failed(outcome)
        }
        for entry in group.entries {
            guard case .press(let press) = entry, case .timedOut = press.phase else { continue }
            return .timedOut
        }
        return .unfinished
    }

    public static func resultBadge(for group: OpenPressGroup) -> String {
        switch result(for: group) {
        case .accepted: return "Accepted"
        case .failed(nil): return "Failed"
        case .failed(let message?): return message == "No network" ? "No network" : "Failed: \(message)"
        case .timedOut: return "Timed out"
        case .unfinished: return "Unfinished"
        }
    }

    // MARK: - Grouping

    /// Returned newest group first, by `time`. A group's `time` is its
    /// `.started` press record's timestamp; failing that, the earliest entry.
    public static func groups(from entries: [OpenJournalEntry]) -> [OpenPressGroup] {
        var byPressId: [UUID: [OpenJournalEntry]] = [:]
        var pressOrder: [UUID] = []
        var legacyAttempts: [OpenAttemptRecord] = []

        for entry in entries {
            switch entry {
            case .press(let press):
                if byPressId[press.pressId] == nil { pressOrder.append(press.pressId) }
                byPressId[press.pressId, default: []].append(entry)
            case .attempt(let attempt):
                guard let pressId = attempt.pressId else {
                    legacyAttempts.append(attempt)
                    continue
                }
                if byPressId[pressId] == nil { pressOrder.append(pressId) }
                byPressId[pressId, default: []].append(entry)
            }
        }

        var groups: [OpenPressGroup] = pressOrder.map { pressId in
            let groupEntries = byPressId[pressId] ?? []
            let startedRecord = groupEntries.compactMap { entry -> OpenPressRecord? in
                if case .press(let press) = entry, case .started = press.phase { return press }
                return nil
            }.first
            let time = startedRecord?.timestamp ?? groupEntries.map(timestamp(of:)).min() ?? Date()
            return OpenPressGroup(
                id: pressId.uuidString, pressId: pressId, time: time,
                source: startedRecord?.source, entries: groupEntries
            )
        }
        groups.append(contentsOf: legacyGroups(from: legacyAttempts))
        return groups.sorted { $0.time > $1.time }
    }

    /// The most recent PRESS-backed group (legacy groups are ignored) whose
    /// time is within `window` of `now`, or `nil`.
    public static func mostRecentPress(
        in entries: [OpenJournalEntry], within window: Duration, now: Date
    ) -> OpenPressGroup? {
        guard let latest = groups(from: entries).first(where: { $0.pressId != nil }) else { return nil }
        let seconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
        return now.timeIntervalSince(latest.time) <= seconds ? latest : nil
    }

    private static func legacyGroups(from attempts: [OpenAttemptRecord]) -> [OpenPressGroup] {
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
            return OpenPressGroup(id: id, pressId: nil, time: time, source: nil, entries: records.map { .attempt($0) })
        }
    }

    private static func timestamp(of entry: OpenJournalEntry) -> Date {
        switch entry {
        case .press(let press): return press.timestamp
        case .attempt(let attempt): return attempt.timestamp
        }
    }
}

extension OpenAttemptJournal {
    /// Reads the journal (bounded by its capacity) and returns the most
    /// recent press within `window`, or `nil`. Does file I/O: call off the
    /// main actor.
    public func mostRecentPress(within window: Duration, now: Date) -> OpenPressGroup? {
        OpenPressGroup.mostRecentPress(in: journalEntries(), within: window, now: now)
    }
}
