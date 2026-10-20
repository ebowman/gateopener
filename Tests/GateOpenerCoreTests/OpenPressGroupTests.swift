import Foundation
import Testing
@testable import GateOpenerCore

struct OpenPressGroupTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func press(_ id: UUID, at t: TimeInterval, source: String = "intent", phase: OpenPressPhase) -> OpenJournalEntry {
        .press(OpenPressRecord(
            pressId: id, timestamp: base.addingTimeInterval(t), source: source, process: "p",
            appVersion: "1", phase: phase, elapsedMilliseconds: 0))
    }

    private func attempt(_ id: UUID?, at t: TimeInterval, n: Int = 1, kind: OpenSendKind = .primary,
                         outcome: OpenAttemptOutcome = .success(status: 202)) -> OpenJournalEntry {
        .attempt(OpenAttemptRecord(
            timestamp: base.addingTimeInterval(t), attempt: n, maxAttempts: 1, outcome: outcome,
            elapsedMilliseconds: 100, willRetry: false, pressId: id, kind: kind))
    }

    /// Fails if grouping stops splitting by pressId or stops sorting newest-first.
    @Test func groupsSplitByPressIdNewestFirst() {
        let a = UUID(), b = UUID()
        let entries = [
            press(a, at: 0, phase: .started), attempt(a, at: 1),
            press(b, at: 100, source: "app", phase: .started), attempt(b, at: 101),
            press(a, at: 2, phase: .finished(outcome: OpenGateFlow.Outcome.acceptedDialog)),
        ]
        let groups = OpenPressGroup.groups(from: entries)
        #expect(groups.map(\.pressId) == [b, a])
        #expect(groups[1].entries.count == 3)
        #expect(groups[0].sourceLabel == "App")
        #expect(groups[1].resultBadge == "Accepted")
    }

    /// Fails if pressId-less attempts stop forming legacy groups (attempt==1 heuristic) with nil pressId.
    @Test func legacyAttemptsFormLegacyGroups() {
        let entries = [attempt(nil, at: 0, n: 1), attempt(nil, at: 1, n: 2), attempt(nil, at: 50, n: 1)]
        let groups = OpenPressGroup.groups(from: entries)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.pressId == nil && $0.sourceLabel == "Unknown (older build)" })
        #expect(groups[1].entries.count == 2)
    }

    /// Fails if the badge mapping (finished > timedOut > unfinished, No network) changes.
    @Test func resultBadges() {
        func badge(_ phases: [OpenPressPhase]) -> String {
            let id = UUID()
            let entries = [press(id, at: 0, phase: .started)] + phases.map { press(id, at: 1, phase: $0) }
            return OpenPressGroup.groups(from: entries)[0].resultBadge
        }
        #expect(badge([.finished(outcome: "Gate opened")]) == "Accepted")
        #expect(badge([.finished(outcome: "No network")]) == "No network")
        #expect(badge([.finished(outcome: "HTTP 500")]) == "Failed: HTTP 500")
        #expect(badge([.timedOut]) == "Timed out")
        #expect(badge([]) == "Unfinished")
    }

    /// Fails if an empty journal yields a press instead of nil.
    @Test func mostRecentPressNoneIsNil() {
        #expect(OpenPressGroup.mostRecentPress(in: [], within: .seconds(900), now: base) == nil)
    }

    /// Fails if the window is not enforced (a press 16 min old must not be returned).
    @Test func mostRecentPressOlderThanWindowIsNil() {
        let id = UUID()
        let entries = [press(id, at: 0, phase: .started)]
        let now = base.addingTimeInterval(16 * 60)
        #expect(OpenPressGroup.mostRecentPress(in: entries, within: .seconds(900), now: now) == nil)
    }

    /// Fails if the newest press is not chosen, or its attempt records are dropped.
    @Test func mostRecentPressInsideWindowIncludesAttempts() {
        let old = UUID(), new = UUID()
        let entries = [
            press(old, at: 0, phase: .started),
            press(new, at: 300, phase: .started), attempt(new, at: 301), attempt(new, at: 302, kind: .confirmation),
        ]
        let g = OpenPressGroup.mostRecentPress(in: entries, within: .seconds(900), now: base.addingTimeInterval(400))
        #expect(g?.pressId == new)
        #expect(g?.entries.count == 3)
        #expect(g?.sendCount == 2)
    }

    /// Fails if a legacy group (newer than any press) is returned by the banner lookup.
    @Test func mostRecentPressIgnoresLegacyGroups() {
        let id = UUID()
        let entries = [press(id, at: 0, phase: .started), attempt(nil, at: 100)]
        let g = OpenPressGroup.mostRecentPress(in: entries, within: .seconds(900), now: base.addingTimeInterval(200))
        #expect(g?.pressId == id)
    }

    /// Fails if the journal extension stops reading the file (end-to-end through a real temp journal).
    @Test func journalMostRecentPressReadsFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = OpenAttemptJournal(fileURL: url)
        let id = UUID()
        journal.record(OpenPressRecord(pressId: id, timestamp: base, source: "intent", process: "p",
                                       appVersion: "1", phase: .started, elapsedMilliseconds: 0))
        #expect(journal.mostRecentPress(within: .seconds(900), now: base.addingTimeInterval(5))?.pressId == id)
        #expect(journal.mostRecentPress(within: .seconds(900), now: base.addingTimeInterval(5000)) == nil)
    }
}
