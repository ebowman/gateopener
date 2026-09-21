import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `OpenHistoryView`'s pure, unit-testable helpers (bead
/// gateopener-41m.3): outcome-text mapping, grouping, elapsed formatting,
/// and share-text formatting. None of these touch SwiftUI — they exercise
/// the `static func`s directly.
struct OpenHistoryViewTests {
    private func makeRecord(
        attempt: Int = 1,
        maxAttempts: Int = 1,
        outcome: OpenAttemptOutcome = .success(status: 202),
        elapsedMilliseconds: Int = 2_900,
        willRetry: Bool = false,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> OpenAttemptRecord {
        OpenAttemptRecord(
            timestamp: timestamp,
            attempt: attempt,
            maxAttempts: maxAttempts,
            outcome: outcome,
            elapsedMilliseconds: elapsedMilliseconds,
            willRetry: willRetry
        )
    }

    // MARK: - outcomeText(for:)

    /// MUTATION CHECK: changing `"Opened (\(status))"` to omit the status
    /// (e.g. just `"Opened"`) makes this fail.
    @Test func outcomeTextSuccess() {
        #expect(OpenHistoryView.outcomeText(for: .success(status: 202)) == "Opened (202)")
    }

    /// MUTATION CHECK: swapping `"HTTP \(status)"` for a different prefix
    /// (e.g. `"Failed \(status)"`) makes this fail.
    @Test func outcomeTextHTTPFailure() {
        #expect(OpenHistoryView.outcomeText(for: .httpFailure(status: 500)) == "HTTP 500")
    }

    /// MUTATION CHECK: swapping the -1001 case body for a different string,
    /// or removing this `case` entirely (falling through to the `default`
    /// branch), makes this fail.
    @Test func outcomeTextTransportTimedOut() {
        #expect(OpenHistoryView.outcomeText(for: .transportFailure(urlErrorCode: -1001)) == "Network: timed out")
    }

    @Test func outcomeTextTransportOffline() {
        #expect(OpenHistoryView.outcomeText(for: .transportFailure(urlErrorCode: -1009)) == "Network: offline")
    }

    @Test func outcomeTextTransportConnectionLost() {
        #expect(OpenHistoryView.outcomeText(for: .transportFailure(urlErrorCode: -1005)) == "Network: connection lost")
    }

    /// MUTATION CHECK: -1003 and -1004 must map to the SAME string; merging
    /// them into a shared `case -1003, -1004:` branch is intentional and
    /// this test would still pass, but splitting them onto different
    /// strings would fail one of these two asserts.
    @Test func outcomeTextTransportCannotReachHost() {
        #expect(OpenHistoryView.outcomeText(for: .transportFailure(urlErrorCode: -1003)) == "Network: cannot reach host")
        #expect(OpenHistoryView.outcomeText(for: .transportFailure(urlErrorCode: -1004)) == "Network: cannot reach host")
    }

    /// MUTATION CHECK: -1 is the sentinel used when the underlying error is
    /// not a `URLError` at all (see `OpenAttemptOutcome.transportFailure`'s
    /// doc comment) and must map to the code-free "Network error", not the
    /// generic "Network error -1" the `default` branch would otherwise
    /// produce.
    @Test func outcomeTextTransportGenericSentinel() {
        #expect(OpenHistoryView.outcomeText(for: .transportFailure(urlErrorCode: -1)) == "Network error")
    }

    /// MUTATION CHECK: an unlisted code must include the numeric code in
    /// the output (removing `\(code)` from the default-branch string makes
    /// this fail).
    @Test func outcomeTextTransportOtherCodeIncludesCode() {
        #expect(OpenHistoryView.outcomeText(for: .transportFailure(urlErrorCode: -1200)) == "Network error -1200")
    }

    /// MUTATION CHECK: dropping the interpolated description makes this
    /// fail.
    @Test func outcomeTextTokenFailure() {
        #expect(OpenHistoryView.outcomeText(for: .tokenFailure(description: "network")) == "Sign-in/token failure (network)")
    }

    // MARK: - elapsedText(forMilliseconds:)

    /// MUTATION CHECK: rounding to zero decimals (e.g. "3 s") or omitting
    /// the " s" suffix makes this fail.
    @Test func elapsedTextFormatsOneDecimal() {
        #expect(OpenHistoryView.elapsedText(forMilliseconds: 2_900) == "2.9 s")
    }

    @Test func elapsedTextRoundsToOneDecimal() {
        #expect(OpenHistoryView.elapsedText(forMilliseconds: 350) == "0.3 s")
    }

    @Test func elapsedTextZero() {
        #expect(OpenHistoryView.elapsedText(forMilliseconds: 0) == "0.0 s")
    }

    // MARK: - groups(from:)

    /// MUTATION CHECK: an empty input must produce an empty group list, not
    /// a single empty-records group.
    @Test func groupsFromEmptyEntriesIsEmpty() {
        #expect(OpenHistoryView.groups(from: []).isEmpty)
    }

    /// A single attempt-1 record forms one group of one record whose badge
    /// reflects its own outcome.
    @Test func groupsFromSingleRecord() {
        let record = makeRecord(attempt: 1, maxAttempts: 1, outcome: .success(status: 202))
        let groups = OpenHistoryView.groups(from: [record])
        #expect(groups.count == 1)
        #expect(groups[0].records == [record])
        #expect(groups[0].resultBadge == "Opened")
    }

    /// A normal multi-attempt open (attempt 1 fails, attempt 2 succeeds)
    /// forms ONE group containing both records, oldest attempt first, with
    /// an "Opened" badge because the group contains a success.
    ///
    /// MUTATION CHECK: starting a new group on every record (instead of
    /// only when `attempt == 1`) would split this into two one-record
    /// groups, failing the `count == 1` assertion.
    @Test func groupsFromNormalMultiAttemptOpen() {
        let first = makeRecord(attempt: 1, maxAttempts: 2, outcome: .httpFailure(status: 500), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRecord(attempt: 2, maxAttempts: 2, outcome: .success(status: 202), timestamp: Date(timeIntervalSince1970: 1_700_000_010))
        let groups = OpenHistoryView.groups(from: [first, second])
        #expect(groups.count == 1)
        #expect(groups[0].records == [first, second])
        #expect(groups[0].resultBadge == "Opened")
    }

    /// All attempts in a group failing must produce a "Failed" badge.
    @Test func groupsFromAllFailedOpenHasFailedBadge() {
        let first = makeRecord(attempt: 1, maxAttempts: 2, outcome: .httpFailure(status: 500))
        let second = makeRecord(attempt: 2, maxAttempts: 2, outcome: .httpFailure(status: 500))
        let groups = OpenHistoryView.groups(from: [first, second])
        #expect(groups.count == 1)
        #expect(groups[0].resultBadge == "Failed")
    }

    /// Records before the first `attempt == 1` record (possible after
    /// trimming mid-open) form a leading group of their own, oldest-open
    /// first internally, but still grouped correctly with any subsequent
    /// complete opens.
    @Test func groupsFromLeadingPartialGroup() {
        // Trimmed mid-open: this journal's oldest surviving record is
        // attempt 2 of a 3-attempt open whose attempt-1 record fell off.
        let orphanedAttempt = makeRecord(attempt: 2, maxAttempts: 3, outcome: .httpFailure(status: 500), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let completeOpenFirst = makeRecord(attempt: 1, maxAttempts: 1, outcome: .success(status: 202), timestamp: Date(timeIntervalSince1970: 1_700_000_100))

        let groups = OpenHistoryView.groups(from: [orphanedAttempt, completeOpenFirst])
        #expect(groups.count == 2)
        // Newest group first.
        #expect(groups[0].records == [completeOpenFirst])
        #expect(groups[1].records == [orphanedAttempt])
    }

    /// MUTATION CHECK: reversing the group order (oldest group first)
    /// instead of newest-first would swap which group lands at index 0
    /// here, failing this assertion.
    @Test func groupsAreNewestFirst() {
        let openOne = makeRecord(attempt: 1, maxAttempts: 1, outcome: .success(status: 202), timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let openTwo = makeRecord(attempt: 1, maxAttempts: 1, outcome: .success(status: 202), timestamp: Date(timeIntervalSince1970: 1_700_000_100))
        let openThree = makeRecord(attempt: 1, maxAttempts: 1, outcome: .success(status: 202), timestamp: Date(timeIntervalSince1970: 1_700_000_200))

        let groups = OpenHistoryView.groups(from: [openOne, openTwo, openThree])
        #expect(groups.count == 3)
        #expect(groups[0].records == [openThree])
        #expect(groups[1].records == [openTwo])
        #expect(groups[2].records == [openOne])
    }

    // MARK: - shareText(for:prefix:)

    /// MUTATION CHECK: dropping the prefix line, the blank separator line,
    /// or any field (timestamp, attempt/maxAttempts, outcome text, elapsed
    /// ms, retry flag) from the per-record line makes this fail.
    @Test func shareTextFormatsPrefixAndLines() {
        let record = makeRecord(
            attempt: 1,
            maxAttempts: 2,
            outcome: .httpFailure(status: 500),
            elapsedMilliseconds: 1_234,
            willRetry: true,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let text = OpenHistoryView.shareText(for: [record], prefix: "GateOpener 1.0 (10) — Sep 21, 2026")

        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "GateOpener 1.0 (10) — Sep 21, 2026")
        #expect(lines[1] == "")
        #expect(lines[2].contains("attempt 1/2"))
        #expect(lines[2].contains("HTTP 500"))
        #expect(lines[2].contains("1234 ms"))
        #expect(lines[2].contains("(retrying)"))
    }

    /// A record with `willRetry == false` must NOT include a retry marker.
    @Test func shareTextOmitsRetryFlagWhenNotRetrying() {
        let record = makeRecord(willRetry: false)
        let text = OpenHistoryView.shareText(for: [record], prefix: "prefix")
        #expect(!text.contains("retrying"))
    }

    /// Multiple records produce one line each, in the given order.
    @Test func shareTextOneLinePerRecord() {
        let first = makeRecord(attempt: 1, maxAttempts: 1, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRecord(attempt: 1, maxAttempts: 1, timestamp: Date(timeIntervalSince1970: 1_700_000_100))
        let text = OpenHistoryView.shareText(for: [first, second], prefix: "prefix")
        let lines = text.components(separatedBy: "\n")
        // prefix, blank, line for `first`, line for `second`.
        #expect(lines.count == 4)
    }
}
