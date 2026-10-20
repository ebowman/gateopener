import Foundation

/// Pure, Foundation-only formatting for the Open history screens (iPhone and
/// watch) and the share text. Moved out of `OpenHistoryView` (bead
/// gateopener-3d7.17) so both platforms share one implementation.
public enum OpenHistoryText {

    /// Grouping lives in core (`OpenPressGroup`, bead gateopener-pi0.3) so the
    /// main-screen banner shares it; these are thin wrappers.
    public typealias Group = OpenPressGroup

    /// "Action Button / Control" for "intent", "App" for "app", the raw
    /// value for anything else.
    public static func sourceLabel(for source: String) -> String {
        OpenPressGroup.sourceLabel(for: source)
    }

    public static let unfinishedFootnote =
        "This press started but never reported a result — iOS may have stopped the extension before it finished."

    public static func groups(from entries: [OpenJournalEntry]) -> [Group] {
        OpenPressGroup.groups(from: entries)
    }

    /// One-line footer shown above the history groups.
    public static let acceptedFooter = "Accepted means Comelit's cloud took the command; it does not confirm the gate moved."

    public static func resultBadge(for group: Group) -> String {
        OpenPressGroup.resultBadge(for: group)
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
    public static func timelineLines(for group: Group) -> [String] {
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

    private static func legacyTimelineLines(for entries: [OpenJournalEntry]) -> [String] {
        entries.compactMap { entry -> String? in
            guard case .attempt(let record) = entry else { return nil }
            if record.kind == .confirmation {
                return "\(confirmationText(for: record.outcome)) \(elapsedText(forMilliseconds: record.elapsedMilliseconds))"
            }
            let outcome = outcomeText(for: record.outcome)
            let retry = record.willRetry ? "  retrying" : ""
            return "attempt \(record.attempt)/\(record.maxAttempts) \(outcome) \(elapsedText(forMilliseconds: record.elapsedMilliseconds))\(retry)"
        }
    }

    private static func pressLine(for press: OpenPressRecord) -> String {
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
        case .attempt(let number):
            return "\(offset) Attempt \(number)"
        case .waitingForNetwork:
            return "\(offset) Waiting for network"
        case .credentialsUnreadable(let status):
            return "\(offset) Credentials unreadable (OSStatus \(status))"
        }
    }

    private static func attemptLine(for attempt: OpenAttemptRecord, offsetMilliseconds: Int) -> String {
        let offset = offsetText(forMilliseconds: offsetMilliseconds)
        if attempt.kind == .confirmation {
            return "\(offset) \(confirmationText(for: attempt.outcome)) \(elapsedText(forMilliseconds: attempt.elapsedMilliseconds))"
        }
        let outcome = outcomeText(for: attempt.outcome)
        let retry = attempt.willRetry ? "  retrying" : ""
        return "\(offset) attempt \(attempt.attempt)/\(attempt.maxAttempts) \(outcome) \(elapsedText(forMilliseconds: attempt.elapsedMilliseconds))\(retry)"
    }

    /// The post-accept confirmation send (gateopener-pi0.5): "confirmation:
    /// Accepted (202)" on 202/200, otherwise "confirmation: " + the usual
    /// outcome text (e.g. "confirmation: HTTP 500").
    public static func confirmationText(for outcome: OpenAttemptOutcome) -> String {
        if case .success(let status) = outcome { return "confirmation: Accepted (\(status))" }
        return "confirmation: \(outcomeText(for: outcome))"
    }

    /// "+0 ms" / "+412 ms" for offsets under 1000 ms; "+1.9 s" / "+25.0 s"
    /// (one decimal place) for offsets >= 1000 ms.
    public static func offsetText(forMilliseconds milliseconds: Int) -> String {
        guard milliseconds >= 1_000 else { return "+\(milliseconds) ms" }
        let seconds = Double(milliseconds) / 1000.0
        return String(format: "+%.1f s", seconds)
    }

    /// success(s) → "Accepted (s)"; httpFailure(s) → "HTTP s"; transportFailure
    /// mapped per common `URLError` codes; tokenFailure(d) → "Sign-in/token
    /// failure (d)".
    public static func outcomeText(for outcome: OpenAttemptOutcome) -> String {
        switch outcome {
        case .success(let status):
            return "Accepted (\(status))"
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
    public static func elapsedText(forMilliseconds milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000.0
        return String(format: "%.1f s", seconds)
    }

    /// One block per press: a header line (time + source + badge), then the
    /// press's `timelineLines(for:)`, each indented two spaces, then a blank
    /// separator line before the next press's block. Prefixed with the
    /// caller-supplied `prefix` line (e.g. "GateOpener 1.0 (10) — Sep 21,
    /// 2026 at 9:00 AM").
    public static func shareText(
        for entries: [OpenJournalEntry],
        prefix: String,
        watchTransfers: [WatchHistoryStore.Transfer] = []
    ) -> String {
        let dateFormatter = makeGroupHeaderDateFormatter()
        var lines = [prefix, ""]
        for group in groups(from: entries) {
            lines.append("\(dateFormatter.string(from: group.time)) — \(group.sourceLabel) — \(resultBadge(for: group))")
            for line in timelineLines(for: group) {
                lines.append("  \(line)")
            }
            if group.resultBadge == "Unfinished" {
                lines.append("  \(unfinishedFootnote)")
            }
            lines.append("")
        }
        // Drop the single trailing blank separator line after the last
        // press, so the text doesn't end with an extra empty line.
        if lines.last == "" {
            lines.removeLast()
        }
        if let block = WatchHistoryStore.shareBlock(for: watchTransfers) {
            if !entries.isEmpty { lines.append("") }
            lines.append(block)
        }
        return lines.joined(separator: "\n")
    }

    /// Builds a fresh `DateFormatter` per call: `DateFormatter` is not
    /// `Sendable`, so a single shared instance can't safely be read from a
    /// `nonisolated` context (like `shareText(for:prefix:)`) as well as the
    /// `@MainActor`-isolated view body. Constructing one per call is cheap at
    /// the volume of history entries this view deals with.
    public static func makeGroupHeaderDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}
