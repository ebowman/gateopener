import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

@MainActor
struct LastPressBannerTests {
    private let now = Date(timeIntervalSince1970: 1_700_001_000)

    private func makeJournal() -> (OpenAttemptJournal, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("banner-\(UUID()).jsonl")
        return (OpenAttemptJournal(fileURL: url), url)
    }

    private func makeSettings() -> AppSettings {
        let suite = "banner-\(UUID())"
        return AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    private func press(_ journal: OpenAttemptJournal, id: UUID, ago: TimeInterval, source: String,
                       end: OpenPressPhase?, sends: Int = 1) {
        let t = now.addingTimeInterval(-ago)
        journal.record(OpenPressRecord(pressId: id, timestamp: t, source: source, process: "p",
                                       appVersion: "1", phase: .started, elapsedMilliseconds: 0))
        for i in 0..<sends {
            journal.record(OpenAttemptRecord(
                timestamp: t.addingTimeInterval(1), attempt: 1, maxAttempts: 1, outcome: .success(status: 202),
                elapsedMilliseconds: 10, willRetry: false, pressId: id, kind: i == 0 ? .primary : .confirmation))
        }
        if let end {
            journal.record(OpenPressRecord(pressId: id, timestamp: t.addingTimeInterval(2), source: source,
                                           process: "p", appVersion: "1", phase: end, elapsedMilliseconds: 2000))
        }
    }

    private func banner(_ journal: OpenAttemptJournal, _ settings: AppSettings) -> LastPressBanner {
        let n = now
        return LastPressBanner(journal: journal, settings: settings, now: { n })
    }

    /// Fails if the accepted title wording (pi0.4: "Accepted by cloud", never "Opened") changes.
    @Test func titleAccepted() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 120, source: "intent", end: .finished(outcome: OpenGateFlow.Outcome.acceptedDialog))
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.display?.title == "Last press: Accepted by cloud")
    }

    /// Fails if the failure message is not carried into the title.
    @Test func titleFailed() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 120, source: "intent", end: .finished(outcome: "HTTP 500"))
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.display?.title == "Last press: Failed — HTTP 500")
    }

    /// Fails if a timedOut phase is not mapped to the timed-out title.
    @Test func titleTimedOut() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 120, source: "intent", end: .timedOut)
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.display?.title == "Last press: Timed out")
    }

    /// Fails if a press with no terminal phase is not shown as unfinished.
    @Test func titleUnfinished() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 120, source: "intent", end: nil)
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.display?.title == "Last press: Unfinished — iOS stopped it")
    }

    /// Fails if an app press under 60 s old (the one the user just watched) is shown.
    @Test func recentAppPressSuppressed() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 30, source: "app", end: .finished(outcome: OpenGateFlow.Outcome.acceptedDialog))
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(!b.isVisible)
    }

    /// Fails if the 60 s suppression never expires (app press at 90 s must show).
    @Test func olderAppPressShown() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 90, source: "app", end: .finished(outcome: OpenGateFlow.Outcome.acceptedDialog))
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.isVisible)
    }

    /// Fails if suppression is applied to intent presses (Action Button press 5 s ago must show).
    @Test func recentIntentPressShownImmediately() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 5, source: "intent", end: .finished(outcome: OpenGateFlow.Outcome.acceptedDialog))
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.isVisible)
    }

    /// Fails if dismissal is not persisted/honoured on refresh, or a newer press does not un-hide.
    @Test func dismissPersistsAndNewerPressUnhides() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        let settings = makeSettings()
        let first = UUID()
        press(j, id: first, ago: 200, source: "intent", end: .timedOut)
        let b = banner(j, settings); await b.refresh()
        #expect(b.isVisible)
        b.dismiss()
        #expect(!b.isVisible)
        #expect(settings.dismissedLastPressId == first)
        let b2 = banner(j, settings); await b2.refresh()
        #expect(!b2.isVisible)
        press(j, id: UUID(), ago: 100, source: "intent", end: .timedOut)
        await b2.refresh()
        #expect(b2.isVisible)
    }

    /// Fails if the send count ignores confirmation records or the subtitle format changes.
    @Test func subtitleCountsConfirmationSends() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 130, source: "intent", end: .finished(outcome: OpenGateFlow.Outcome.acceptedDialog), sends: 2)
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.display?.subtitle == "Action Button / Control · 2 min ago · 2 sends")
    }

    /// Fails if a single send is pluralised.
    @Test func subtitleSingularSend() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 130, source: "intent", end: .timedOut, sends: 1)
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(b.display?.subtitle.hasSuffix("1 send") == true)
    }

    /// Fails if a press outside the 15 min window is shown.
    @Test func pressOlderThanWindowHidden() async {
        let (j, url) = makeJournal(); defer { try? FileManager.default.removeItem(at: url) }
        press(j, id: UUID(), ago: 16 * 60, source: "intent", end: .timedOut)
        let b = banner(j, makeSettings()); await b.refresh()
        #expect(!b.isVisible)
    }
}
