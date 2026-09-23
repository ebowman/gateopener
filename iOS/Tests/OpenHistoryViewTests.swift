import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Tests for `OpenHistoryView`'s pure, unit-testable helpers (bead
/// gateopener-41m.24): press-based grouping, result-badge mapping, phase
/// timeline formatting, source labels, and share-text formatting. None of
/// these touch SwiftUI — they exercise the `static func`s directly.
struct OpenHistoryViewTests {
    private func makeAttempt(
        attempt: Int = 1,
        maxAttempts: Int = 1,
        outcome: OpenAttemptOutcome = .success(status: 202),
        elapsedMilliseconds: Int = 2_900,
        willRetry: Bool = false,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        pressId: UUID? = nil
    ) -> OpenAttemptRecord {
        OpenAttemptRecord(
            timestamp: timestamp,
            attempt: attempt,
            maxAttempts: maxAttempts,
            outcome: outcome,
            elapsedMilliseconds: elapsedMilliseconds,
            willRetry: willRetry,
            pressId: pressId
        )
    }

    private func makePress(
        pressId: UUID,
        timestamp: Date,
        source: String = "intent",
        process: String = "com.example.app",
        appVersion: String = "0.1.9 (11)",
        phase: OpenPressPhase,
        elapsedMilliseconds: Int
    ) -> OpenPressRecord {
        OpenPressRecord(
            pressId: pressId,
            timestamp: timestamp,
            source: source,
            process: process,
            appVersion: appVersion,
            phase: phase,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

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

    // MARK: - offsetText(forMilliseconds:)

    /// MUTATION CHECK: an offset under 1000 ms must render as "+N ms", not
    /// as a fractional-second string.
    @Test func offsetTextUnderOneSecondUsesMilliseconds() {
        #expect(OpenHistoryView.offsetText(forMilliseconds: 0) == "+0 ms")
        #expect(OpenHistoryView.offsetText(forMilliseconds: 412) == "+412 ms")
        #expect(OpenHistoryView.offsetText(forMilliseconds: 999) == "+999 ms")
    }

    /// MUTATION CHECK: 1000 ms and above must switch to one-decimal
    /// seconds, not remain in milliseconds.
    @Test func offsetTextAtOrAboveOneSecondUsesSeconds() {
        #expect(OpenHistoryView.offsetText(forMilliseconds: 1_000) == "+1.0 s")
        #expect(OpenHistoryView.offsetText(forMilliseconds: 1_900) == "+1.9 s")
        #expect(OpenHistoryView.offsetText(forMilliseconds: 25_000) == "+25.0 s")
    }

    // MARK: - sourceLabel(for:)

    /// MUTATION CHECK: "intent" must map to the specific label, not a
    /// generic fallback.
    @Test func sourceLabelIntent() {
        #expect(OpenHistoryView.sourceLabel(for: "intent") == "Action Button / Control")
    }

    @Test func sourceLabelApp() {
        #expect(OpenHistoryView.sourceLabel(for: "app") == "App")
    }

    /// MUTATION CHECK: an unrecognized source must pass through verbatim,
    /// not collapse to one of the known labels.
    @Test func sourceLabelUnknownPassesThroughRaw() {
        #expect(OpenHistoryView.sourceLabel(for: "queued") == "queued")
    }

    // MARK: - groups(from:) — press-based grouping

    @Test func groupsFromEmptyEntriesIsEmpty() {
        #expect(OpenHistoryView.groups(from: []).isEmpty)
    }

    /// A press with just `.started` and `.finished` phases forms one group
    /// whose time is the `.started` timestamp and whose source matches the
    /// `.started` record.
    @Test func groupsFromSinglePressStartedAndFinished() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let finished = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(2), phase: .finished(outcome: "Gate opened"), elapsedMilliseconds: 2_000)

        let groups = OpenHistoryView.groups(from: [.press(started), .press(finished)])
        #expect(groups.count == 1)
        #expect(groups[0].id == pressId.uuidString)
        #expect(groups[0].time == baseTime)
        #expect(groups[0].sourceLabel == "Action Button / Control")
        #expect(groups[0].resultBadge == "Opened")
    }

    /// Mixed press phases AND an attempt record sharing the same `pressId`
    /// all land in the same group.
    @Test func groupsFromMixedPressAndAttemptSamePressId() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let openStarted = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1), phase: .openStarted, elapsedMilliseconds: 1_000)
        let attempt = makeAttempt(attempt: 1, maxAttempts: 3, outcome: .success(status: 202), timestamp: baseTime.addingTimeInterval(1.5), pressId: pressId)
        let finished = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(2), phase: .finished(outcome: "Gate opened"), elapsedMilliseconds: 2_000)

        let groups = OpenHistoryView.groups(from: [.press(started), .press(openStarted), .attempt(attempt), .press(finished)])
        #expect(groups.count == 1)
        #expect(groups[0].entries.count == 4)
    }

    /// Two interleaved concurrent presses (different `pressId`s, entries
    /// interleaved in journal order) split into two separate groups, each
    /// containing only its own entries.
    @Test func groupsFromTwoInterleavedConcurrentPresses() {
        let pressA = UUID()
        let pressB = UUID()
        let startedA = makePress(pressId: pressA, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let startedB = makePress(pressId: pressB, timestamp: baseTime.addingTimeInterval(0.1), phase: .started, elapsedMilliseconds: 0)
        let finishedA = makePress(pressId: pressA, timestamp: baseTime.addingTimeInterval(2), phase: .finished(outcome: "Gate opened"), elapsedMilliseconds: 2_000)
        let finishedB = makePress(pressId: pressB, timestamp: baseTime.addingTimeInterval(2.2), phase: .finished(outcome: "No network"), elapsedMilliseconds: 2_100)

        let entries: [OpenJournalEntry] = [.press(startedA), .press(startedB), .press(finishedA), .press(finishedB)]
        let groups = OpenHistoryView.groups(from: entries)

        #expect(groups.count == 2)
        let ids = Set(groups.map(\.id))
        #expect(ids == [pressA.uuidString, pressB.uuidString])
        // Newest-first by started time: B started after A.
        #expect(groups[0].id == pressB.uuidString)
        #expect(groups[1].id == pressA.uuidString)
        #expect(groups[0].entries.count == 2)
        #expect(groups[1].entries.count == 2)
    }

    /// A press with only a `.started` phase (never finished/timed out)
    /// forms its own group with an "Unfinished" badge.
    @Test func groupsFromUnfinishedPress() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)

        let groups = OpenHistoryView.groups(from: [.press(started)])
        #expect(groups.count == 1)
        #expect(groups[0].resultBadge == "Unfinished")
    }

    /// `OpenAttemptRecord`s with no `pressId` fall back to the legacy
    /// attempt==1 heuristic, labelled "Unknown (older build)".
    @Test func groupsFromLegacyAttemptsWithoutPressId() {
        let first = makeAttempt(attempt: 1, maxAttempts: 2, outcome: .httpFailure(status: 500), timestamp: baseTime, pressId: nil)
        let second = makeAttempt(attempt: 2, maxAttempts: 2, outcome: .success(status: 202), timestamp: baseTime.addingTimeInterval(1), pressId: nil)

        let groups = OpenHistoryView.groups(from: [.attempt(first), .attempt(second)])
        #expect(groups.count == 1)
        #expect(groups[0].entries.count == 2)
        #expect(groups[0].sourceLabel == "Unknown (older build)")
        #expect(groups[0].resultBadge == "Opened")
    }

    /// Legacy attempts before the first `attempt == 1` record (journal
    /// trimmed mid-open) form a leading legacy group, matching the old
    /// heuristic's documented behavior.
    @Test func groupsFromLegacyLeadingPartialGroup() {
        let orphanedAttempt = makeAttempt(attempt: 2, maxAttempts: 3, outcome: .httpFailure(status: 500), timestamp: baseTime, pressId: nil)
        let completeOpenFirst = makeAttempt(attempt: 1, maxAttempts: 1, outcome: .success(status: 202), timestamp: baseTime.addingTimeInterval(100), pressId: nil)

        let groups = OpenHistoryView.groups(from: [.attempt(orphanedAttempt), .attempt(completeOpenFirst)])
        #expect(groups.count == 2)
        // Newest group first.
        #expect(groups[0].entries == [.attempt(completeOpenFirst)])
        #expect(groups[1].entries == [.attempt(orphanedAttempt)])
    }

    /// A press group and a legacy group both present sort together
    /// newest-first by time.
    @Test func groupsMixPressAndLegacySortedNewestFirst() {
        let pressId = UUID()
        let olderStarted = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let legacyAttempt = makeAttempt(attempt: 1, maxAttempts: 1, outcome: .success(status: 202), timestamp: baseTime.addingTimeInterval(100), pressId: nil)

        let groups = OpenHistoryView.groups(from: [.press(olderStarted), .attempt(legacyAttempt)])
        #expect(groups.count == 2)
        #expect(groups[0].sourceLabel == "Unknown (older build)")
        #expect(groups[1].id == pressId.uuidString)
    }

    /// MUTATION CHECK: reversing the group order (oldest group first)
    /// instead of newest-first would swap which group lands at index 0
    /// here, failing this assertion.
    @Test func groupsAreNewestFirst() {
        let pressOne = UUID()
        let pressTwo = UUID()
        let pressThree = UUID()
        let startedOne = makePress(pressId: pressOne, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let startedTwo = makePress(pressId: pressTwo, timestamp: baseTime.addingTimeInterval(100), phase: .started, elapsedMilliseconds: 0)
        let startedThree = makePress(pressId: pressThree, timestamp: baseTime.addingTimeInterval(200), phase: .started, elapsedMilliseconds: 0)

        let groups = OpenHistoryView.groups(from: [.press(startedOne), .press(startedTwo), .press(startedThree)])
        #expect(groups.count == 3)
        #expect(groups[0].id == pressThree.uuidString)
        #expect(groups[1].id == pressTwo.uuidString)
        #expect(groups[2].id == pressOne.uuidString)
    }

    // MARK: - resultBadge(for:) — every case

    @Test func resultBadgeFinishedGateOpenedIsOpened() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let finished = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1), phase: .finished(outcome: "Gate opened"), elapsedMilliseconds: 1_000)
        let group = OpenHistoryView.groups(from: [.press(started), .press(finished)])[0]
        #expect(group.resultBadge == "Opened")
    }

    @Test func resultBadgeFinishedNoNetworkIsNoNetwork() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let finished = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1), phase: .finished(outcome: "No network"), elapsedMilliseconds: 1_000)
        let group = OpenHistoryView.groups(from: [.press(started), .press(finished)])[0]
        #expect(group.resultBadge == "No network")
    }

    /// MUTATION CHECK: any other finished outcome must be prefixed with
    /// "Failed: " and include the raw outcome text verbatim.
    @Test func resultBadgeFinishedOtherOutcomeIsFailedPrefixed() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let finished = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1), phase: .finished(outcome: "HTTP 500"), elapsedMilliseconds: 1_000)
        let group = OpenHistoryView.groups(from: [.press(started), .press(finished)])[0]
        #expect(group.resultBadge == "Failed: HTTP 500")
    }

    @Test func resultBadgeTimedOutIsTimedOut() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let timedOut = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(25), phase: .timedOut, elapsedMilliseconds: 25_000)
        let group = OpenHistoryView.groups(from: [.press(started), .press(timedOut)])[0]
        #expect(group.resultBadge == "Timed out")
    }

    @Test func resultBadgeNoTerminalPhaseIsUnfinished() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let openStarted = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1), phase: .openStarted, elapsedMilliseconds: 1_000)
        let group = OpenHistoryView.groups(from: [.press(started), .press(openStarted)])[0]
        #expect(group.resultBadge == "Unfinished")
    }

    @Test func resultBadgeLegacyAllFailedIsFailed() {
        let first = makeAttempt(attempt: 1, maxAttempts: 2, outcome: .httpFailure(status: 500), timestamp: baseTime, pressId: nil)
        let second = makeAttempt(attempt: 2, maxAttempts: 2, outcome: .httpFailure(status: 500), timestamp: baseTime.addingTimeInterval(1), pressId: nil)
        let group = OpenHistoryView.groups(from: [.attempt(first), .attempt(second)])[0]
        #expect(group.resultBadge == "Failed")
    }

    @Test func resultBadgeLegacyAnySuccessIsOpened() {
        let first = makeAttempt(attempt: 1, maxAttempts: 2, outcome: .httpFailure(status: 500), timestamp: baseTime, pressId: nil)
        let second = makeAttempt(attempt: 2, maxAttempts: 2, outcome: .success(status: 202), timestamp: baseTime.addingTimeInterval(1), pressId: nil)
        let group = OpenHistoryView.groups(from: [.attempt(first), .attempt(second)])[0]
        #expect(group.resultBadge == "Opened")
    }

    // MARK: - timelineLines(for:)

    /// MUTATION CHECK: dropping the source label or app version from the
    /// `.started` line makes this fail.
    @Test func timelineLinesStartedFormatsMillisecondsSourceAndVersion() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, source: "intent", appVersion: "0.1.9 (11)", phase: .started, elapsedMilliseconds: 0)
        let group = OpenHistoryView.groups(from: [.press(started)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines == ["+0 ms started (Action Button / Control, 0.1.9 (11))"])
    }

    @Test func timelineLinesEnvironmentReady() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let envReady = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(0.412), phase: .environmentReady, elapsedMilliseconds: 412)
        let group = OpenHistoryView.groups(from: [.press(started), .press(envReady)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+412 ms environment ready")
    }

    /// MUTATION CHECK: a reachable reading must include the detail after
    /// "network: ", NOT the "unreachable — " prefix used for the false case.
    @Test func timelineLinesReachabilityReachable() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let reachability = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(0.415), phase: .reachability(isReachable: true, detail: "satisfied wifi expensive=false constrained=false"), elapsedMilliseconds: 415)
        let group = OpenHistoryView.groups(from: [.press(started), .press(reachability)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+415 ms network: satisfied wifi expensive=false constrained=false")
    }

    /// MUTATION CHECK: an unreachable reading must use the "unreachable — "
    /// prefix, not the plain "network: " form used for the true case.
    @Test func timelineLinesReachabilityUnreachable() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let reachability = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(0.415), phase: .reachability(isReachable: false, detail: "unsatisfied"), elapsedMilliseconds: 415)
        let group = OpenHistoryView.groups(from: [.press(started), .press(reachability)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+415 ms network: unreachable — unsatisfied")
    }

    @Test func timelineLinesTokenResolved() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let token = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1.9), phase: .tokenResolved(kind: "keychainValid"), elapsedMilliseconds: 1_900)
        let group = OpenHistoryView.groups(from: [.press(started), .press(token)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+1.9 s token: keychainValid")
    }

    @Test func timelineLinesTokenFailed() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let token = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1.9), phase: .tokenFailed(description: "server(500)"), elapsedMilliseconds: 1_900)
        let group = OpenHistoryView.groups(from: [.press(started), .press(token)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+1.9 s token failed: server(500)")
    }

    @Test func timelineLinesOpenStarted() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let openStarted = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(1.9), phase: .openStarted, elapsedMilliseconds: 1_900)
        let group = OpenHistoryView.groups(from: [.press(started), .press(openStarted)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+1.9 s open started")
    }

    @Test func timelineLinesFinished() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let finished = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(9.3), phase: .finished(outcome: "Gate opened"), elapsedMilliseconds: 9_300)
        let group = OpenHistoryView.groups(from: [.press(started), .press(finished)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+9.3 s finished: Gate opened")
    }

    @Test func timelineLinesTimedOut() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let timedOut = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(25), phase: .timedOut, elapsedMilliseconds: 25_000)
        let group = OpenHistoryView.groups(from: [.press(started), .press(timedOut)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+25.0 s timed out")
    }

    /// Attempt lines within a press group compute their own offset from the
    /// press's `.started` timestamp (not from `elapsedMilliseconds`, which
    /// `OpenAttemptRecord` doesn't carry relative to press start), and
    /// include the attempt/maxAttempts, outcome, elapsed, and retry marker.
    @Test func timelineLinesAttemptOffsetsFromPressStart() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let attemptOne = makeAttempt(
            attempt: 1,
            maxAttempts: 3,
            outcome: .transportFailure(urlErrorCode: -1001),
            elapsedMilliseconds: 5_000,
            willRetry: true,
            timestamp: baseTime.addingTimeInterval(4.2),
            pressId: pressId
        )
        let attemptTwo = makeAttempt(
            attempt: 2,
            maxAttempts: 3,
            outcome: .success(status: 202),
            elapsedMilliseconds: 2_300,
            willRetry: false,
            timestamp: baseTime.addingTimeInterval(9.3),
            pressId: pressId
        )
        let group = OpenHistoryView.groups(from: [.press(started), .attempt(attemptOne), .attempt(attemptTwo)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1] == "+4.2 s attempt 1/3 Network: timed out 5.0 s  retrying")
        #expect(lines[2] == "+9.3 s attempt 2/3 Opened (202) 2.3 s")
    }

    /// MUTATION CHECK: an attempt timestamped BEFORE the press's `.started`
    /// timestamp (e.g. slight clock skew) must clamp its offset to 0, not go
    /// negative.
    @Test func timelineLinesAttemptOffsetClampedAtZero() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let earlyAttempt = makeAttempt(attempt: 1, maxAttempts: 1, outcome: .success(status: 202), timestamp: baseTime.addingTimeInterval(-1), pressId: pressId)
        let group = OpenHistoryView.groups(from: [.press(started), .attempt(earlyAttempt)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines[1].hasPrefix("+0 ms"))
    }

    /// A legacy (pressId-less) group's timeline has one line per attempt,
    /// with no "+offset" prefix.
    @Test func timelineLinesLegacyGroupHasNoOffsetPrefix() {
        let attempt = makeAttempt(attempt: 1, maxAttempts: 2, outcome: .httpFailure(status: 500), elapsedMilliseconds: 1_234, willRetry: true, timestamp: baseTime, pressId: nil)
        let group = OpenHistoryView.groups(from: [.attempt(attempt)])[0]
        let lines = OpenHistoryView.timelineLines(for: group)
        #expect(lines == ["attempt 1/2 HTTP 500 1.2 s  retrying"])
    }

    // MARK: - shareText(for:prefix:)

    /// MUTATION CHECK: dropping the prefix line, the blank separator line,
    /// the group header, or any timeline line from the per-press block makes
    /// this fail.
    @Test func shareTextFormatsPrefixHeaderAndIndentedLines() {
        let pressId = UUID()
        let started = makePress(pressId: pressId, timestamp: baseTime, source: "intent", phase: .started, elapsedMilliseconds: 0)
        let finished = makePress(pressId: pressId, timestamp: baseTime.addingTimeInterval(2), phase: .finished(outcome: "Gate opened"), elapsedMilliseconds: 2_000)

        let text = OpenHistoryView.shareText(for: [.press(started), .press(finished)], prefix: "GateOpener 1.0 (10) — Sep 21, 2026")
        let lines = text.components(separatedBy: "\n")

        #expect(lines[0] == "GateOpener 1.0 (10) — Sep 21, 2026")
        #expect(lines[1] == "")
        #expect(lines[2].contains("Action Button / Control"))
        #expect(lines[2].contains("Opened"))
        #expect(lines[3] == "  +0 ms started (Action Button / Control, 0.1.9 (11))")
        #expect(lines[4] == "  +2.0 s finished: Gate opened")
    }

    /// Two presses each produce their own header + indented lines, separated
    /// by a blank line, with no trailing blank line at the very end.
    @Test func shareTextMultiplePressesSeparatedByBlankLine() {
        let pressOne = UUID()
        let pressTwo = UUID()
        let startedOne = makePress(pressId: pressOne, timestamp: baseTime, phase: .started, elapsedMilliseconds: 0)
        let startedTwo = makePress(pressId: pressTwo, timestamp: baseTime.addingTimeInterval(100), phase: .started, elapsedMilliseconds: 0)

        let text = OpenHistoryView.shareText(for: [.press(startedOne), .press(startedTwo)], prefix: "prefix")
        let lines = text.components(separatedBy: "\n")

        // prefix, blank, header(two), line(two), blank, header(one), line(one) — no trailing blank.
        #expect(lines.count == 7)
        #expect(lines.last != "")
    }
}
