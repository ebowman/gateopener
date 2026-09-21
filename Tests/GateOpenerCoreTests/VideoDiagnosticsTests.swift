import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `VideoDiagnostics` (bead gateopener-672.27): the release-build
/// diagnostics recorder `DoorVideoSession` appends to and persists so a
/// TestFlight (Release) build can still produce a shareable log after an
/// off-LAN video failure.
@MainActor
struct VideoDiagnosticsTests {
    /// Creates a throwaway UserDefaults suite and returns it along with a
    /// closure that removes it. Callers should `defer { cleanup() }`.
    private func makeInMemoryDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "ie.boboco.GateOpener.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for testing")
        }
        let cleanup = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (defaults, cleanup)
    }

    // MARK: - append() caps at 16KB, keeping the most recent lines

    /// MUTATION CHECK: removing the `while textByteCount() > Self.maxBytes`
    /// eviction loop in `VideoDiagnostics.append(_:)`
    /// (`iOS/App/Video/VideoDiagnostics.swift`) makes `text.utf8.count`
    /// grow unbounded, failing the `<= VideoDiagnostics.maxBytes` assertion
    /// below.
    @Test func appendCapsAt16KBKeepingMostRecentLines() {
        let diagnostics = VideoDiagnostics()

        // Each line is ~40 bytes; 1000 lines is ~40KB, comfortably over the
        // 16KB cap, so eviction must have happened at least once.
        for i in 0..<1000 {
            diagnostics.append("line \(i): 0123456789012345678901234")
        }

        #expect(diagnostics.text.utf8.count <= VideoDiagnostics.maxBytes)

        // The MOST RECENT line must still be present (never evicted)...
        #expect(diagnostics.text.contains("line 999:"))
        // ...while an early line must have been evicted to make room.
        #expect(!diagnostics.text.contains("line 0: "))
    }

    /// A single pathologically long line (longer than the entire cap) must
    /// be truncated rather than looping forever trying to evict it (there
    /// is nothing else to evict once `lines.count == 1`).
    @Test func appendTruncatesASingleOversizedLine() {
        let diagnostics = VideoDiagnostics()
        let oversized = String(repeating: "x", count: VideoDiagnostics.maxBytes * 2)

        diagnostics.append(oversized)

        #expect(diagnostics.text.utf8.count <= VideoDiagnostics.maxBytes)
    }

    /// Appending many lines, each individually small, must never exceed the
    /// cap at any point along the way (not just at the end).
    @Test func appendNeverExceedsCapAtAnyPoint() {
        let diagnostics = VideoDiagnostics()
        for i in 0..<2000 {
            diagnostics.append("diagnostic line number \(i) with some padding text")
            #expect(diagnostics.text.utf8.count <= VideoDiagnostics.maxBytes)
        }
    }

    // MARK: - persist/loadLast round-trip

    @Test func persistThenLoadLastRoundTrips() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let diagnostics = VideoDiagnostics()
        diagnostics.append("state: idle -> connecting")
        diagnostics.append("state: connecting -> streaming")
        diagnostics.append("terminal reason: stopped")

        diagnostics.persist(to: defaults)

        let loaded = VideoDiagnostics.loadLast(from: defaults)
        #expect(loaded == diagnostics.text)
        #expect(loaded?.contains("terminal reason: stopped") == true)
    }

    /// MUTATION CHECK: if `persist(to:)` wrote under the wrong key (or
    /// `loadLast(from:)` read a different key), this would fail because
    /// `loadLast` would return `nil` even though something WAS persisted.
    @Test func persistUsesTheDocumentedDefaultsKey() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let diagnostics = VideoDiagnostics()
        diagnostics.append("only line")
        diagnostics.persist(to: defaults)

        #expect(defaults.string(forKey: VideoDiagnostics.defaultsKey) == "only line")
    }

    // MARK: - loadLast is nil when absent

    @Test func loadLastIsNilWhenNothingEverPersisted() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        #expect(VideoDiagnostics.loadLast(from: defaults) == nil)
    }

    // MARK: - Rolling history (bead gateopener-41m.20)

    /// `persist(to:)` must keep writing the single-session `defaultsKey`
    /// blob UNCHANGED, alongside the new history -- existing callers
    /// (macOS's `DoorVideoSession`, `loadLast`) must never regress.
    ///
    /// MUTATION CHECK: removing `defaults.set(text, forKey: Self.defaultsKey)`
    /// from `persist(to:)` would make `loadLast` return `nil` even though a
    /// history entry exists, failing the first `#expect` below.
    @Test func persistStillWritesLastSessionKeyUnchanged() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let diagnostics = VideoDiagnostics()
        diagnostics.append("state: idle -> connecting")
        diagnostics.persist(to: defaults)

        #expect(VideoDiagnostics.loadLast(from: defaults) == diagnostics.text)
        #expect(VideoDiagnostics.loadHistory(from: defaults)?.contains("state: idle -> connecting") == true)
    }

    /// `loadHistory` is `nil` when nothing has ever been persisted or
    /// appended.
    @Test func loadHistoryIsNilWhenEmpty() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        #expect(VideoDiagnostics.loadHistory(from: defaults) == nil)
    }

    /// Persisting two DIFFERENT sessions must leave both blocks present in
    /// the history, each headed by its own `=== video session ... id=...
    /// ===` line.
    ///
    /// MUTATION CHECK: if `appendToHistory` always replaced index 0 instead
    /// of matching by `id`, the second session's persist would clobber the
    /// first's block, leaving only one `=== video session` header in the
    /// history and failing the count assertion below.
    @Test func appendToHistoryKeepsMultipleDistinctSessions() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let first = VideoDiagnostics()
        first.append("session one: state idle -> connecting")
        first.persist(to: defaults)

        let second = VideoDiagnostics()
        second.append("session two: state idle -> connecting")
        second.persist(to: defaults)

        let history = VideoDiagnostics.loadHistory(from: defaults)
        #expect(history?.contains("session one: state idle -> connecting") == true)
        #expect(history?.contains("session two: state idle -> connecting") == true)

        let headerCount = history?.components(separatedBy: "=== video session").count ?? 1
        #expect(headerCount - 1 == 2)
    }

    /// A session that persists SEVERAL times during its life (every
    /// terminal diagnostic line, then again on `stop()`, mirroring
    /// `DoorVideoSession`'s real call pattern) must end up in the history
    /// exactly ONCE, in its FINAL form -- replaced in place, not appended as
    /// a duplicate block.
    ///
    /// MUTATION CHECK: if `appendToHistory` always appended instead of
    /// replacing-in-place by `id`, this session's three `persist(to:)` calls
    /// would leave three separate `=== video session` blocks in the
    /// history, failing the `headerCount == 1` assertion, and the OLDEST
    /// (stale) text would still be present instead of only the final text.
    @Test func repeatedPersistOfSameSessionReplacesInPlace() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let session = VideoDiagnostics()
        session.append("state: idle -> connecting")
        session.persist(to: defaults)

        session.append("state: connecting -> streaming")
        session.persist(to: defaults)

        session.append("terminal reason: stopped")
        session.persist(to: defaults)

        let history = VideoDiagnostics.loadHistory(from: defaults) ?? ""
        let headerCount = history.components(separatedBy: "=== video session").count - 1
        #expect(headerCount == 1)
        #expect(history.contains("terminal reason: stopped"))
        #expect(history.contains("state: idle -> connecting"))
    }

    /// Replacing a session in place must preserve its ORIGINAL chronological
    /// position in the history, not move it to the end -- a session that
    /// started first (and persisted last) must still sort before a session
    /// that started (and finished) later.
    ///
    /// MUTATION CHECK: if `appendToHistory` removed-then-re-appended the
    /// matched entry instead of replacing it at its existing index, the
    /// first session's block (re-persisted last) would end up AFTER the
    /// second session's block in the rendered history text, failing the
    /// ordering assertion below.
    @Test func replaceInPlaceKeepsOriginalChronologicalPosition() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let first = VideoDiagnostics()
        first.append("first session: line one")
        first.persist(to: defaults)

        let second = VideoDiagnostics()
        second.append("second session: line one")
        second.persist(to: defaults)

        // Re-persist the FIRST session again (as if it had a later terminal
        // line arrive after the second session already started/persisted).
        first.append("first session: terminal")
        first.persist(to: defaults)

        let history = VideoDiagnostics.loadHistory(from: defaults) ?? ""
        let firstRange = history.range(of: "first session: terminal")
        let secondRange = history.range(of: "second session: line one")
        #expect(firstRange != nil && secondRange != nil)
        if let firstRange, let secondRange {
            #expect(firstRange.lowerBound < secondRange.lowerBound)
        }
    }

    /// When the total encoded history exceeds `maxHistoryBytes`, WHOLE
    /// oldest entries must be dropped from the front -- never a partial
    /// session -- until it fits again.
    ///
    /// MUTATION CHECK: removing the trimming loop in `store(_:to:)` would
    /// let the stored `Data` grow unbounded, failing the size assertion
    /// below for a history built from many large sessions.
    @Test func historyCapDropsWholeOldestSessionsNeverPartial() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        // Each session's log is ~2KB; 64 sessions is ~128KB, comfortably
        // over the 64KB cap, so eviction of whole oldest sessions must
        // happen.
        for i in 0..<64 {
            let session = VideoDiagnostics()
            session.append("session \(i): " + String(repeating: "x", count: 2000))
            session.persist(to: defaults)
        }

        guard let data = defaults.data(forKey: VideoDiagnostics.historyDefaultsKey) else {
            Issue.record("expected history data to be present")
            return
        }
        #expect(data.count <= VideoDiagnostics.maxHistoryBytes)

        let history = VideoDiagnostics.loadHistory(from: defaults) ?? ""
        // The most recent session must still be present...
        #expect(history.contains("session 63:"))
        // ...while an early session must have been fully evicted (not just
        // truncated -- its header line must be gone entirely).
        #expect(!history.contains("session 0:"))

        // Every remaining block is a COMPLETE header + a full 2000-byte
        // payload line -- i.e. no block was cut in half. A partial cut
        // would leave a header with no matching "session N:" text, or vice
        // versa; every header present must have its own full payload.
        let headers = history.components(separatedBy: "\n\n").filter { $0.contains("=== video session") }
        for block in headers {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.count >= 2)
        }
    }

    /// Event lines (`appendEvent`) interleave with session blocks in
    /// INSERTION order, not sorted by timestamp -- the history is an
    /// insertion-ordered stream, matching how `DoorVideoCoordinator` will
    /// call it live.
    ///
    /// MUTATION CHECK: if `appendEvent`/`appendToHistory` sorted entries by
    /// timestamp instead of preserving insertion order, reordering these
    /// three calls (event, session, event with an out-of-order `now:`)
    /// would still produce insertion order below, so a sort-based
    /// implementation would fail this exact ordering assertion.
    @Test func eventsInterleaveWithSessionsInInsertionOrder() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        VideoDiagnostics.appendEvent("pin on", to: defaults, now: Date().addingTimeInterval(100))

        let session = VideoDiagnostics()
        session.append("session line")
        session.persist(to: defaults)

        VideoDiagnostics.appendEvent("pin off (user)", to: defaults, now: Date().addingTimeInterval(-100))

        let history = VideoDiagnostics.loadHistory(from: defaults) ?? ""
        let pinOnRange = history.range(of: "pin on")
        let sessionRange = history.range(of: "session line")
        let pinOffRange = history.range(of: "pin off (user)")

        #expect(pinOnRange != nil && sessionRange != nil && pinOffRange != nil)
        if let pinOnRange, let sessionRange, let pinOffRange {
            #expect(pinOnRange.lowerBound < sessionRange.lowerBound)
            #expect(sessionRange.lowerBound < pinOffRange.lowerBound)
        }
    }

    /// `clearHistory` removes the history entirely, leaving `loadHistory`
    /// `nil` again -- and must NOT touch the single-session `defaultsKey`
    /// blob (`loadLast` is unaffected).
    ///
    /// MUTATION CHECK: if `clearHistory` also removed `defaultsKey`, the
    /// final `loadLast` assertion below would fail (`nil` instead of the
    /// preserved last-session text).
    @Test func clearHistoryRemovesHistoryButNotLastSession() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let session = VideoDiagnostics()
        session.append("some diagnostics")
        session.persist(to: defaults)

        VideoDiagnostics.clearHistory(in: defaults)

        #expect(VideoDiagnostics.loadHistory(from: defaults) == nil)
        #expect(VideoDiagnostics.loadLast(from: defaults) == "some diagnostics")
    }

    /// A line containing "Bearer " (any case) must be redacted from the
    /// history -- the token itself must never appear in stored text.
    ///
    /// MUTATION CHECK: removing the `bearer ` check from `redacted(_:)`
    /// would leave the raw token line intact in the history, failing the
    /// `!contains("secret-token-value")` assertion below.
    @Test func historyRedactsLinesContainingBearerToken() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        let session = VideoDiagnostics()
        session.append("state: idle -> connecting")
        session.append("Authorization: Bearer secret-token-value")
        session.persist(to: defaults)

        let history = VideoDiagnostics.loadHistory(from: defaults) ?? ""
        #expect(!history.contains("secret-token-value"))
        #expect(history.contains("[redacted]"))
        #expect(history.contains("state: idle -> connecting"))
    }

    /// A line containing "authorization" (lowercase, no explicit "Bearer ")
    /// must also be redacted -- e.g. a raw header dump.
    @Test func historyRedactsLinesContainingAuthorizationCaseInsensitive() {
        let (defaults, cleanup) = makeInMemoryDefaults()
        defer { cleanup() }

        VideoDiagnostics.appendEvent("AUTHORIZATION header: something-sensitive", to: defaults)

        let history = VideoDiagnostics.loadHistory(from: defaults) ?? ""
        #expect(!history.contains("something-sensitive"))
        #expect(history.contains("[redacted]"))
    }
}
