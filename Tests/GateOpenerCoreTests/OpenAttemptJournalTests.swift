import Foundation
import Testing
@testable import GateOpenerCore

/// Tests for `OpenAttemptJournal` (bead gateopener-41m.2): a cross-process,
/// append-only, capacity-bounded JSON-lines journal of `OpenAttemptRecord`s.
///
/// Every test uses a throwaway temp-directory file URL — NEVER
/// `SharedContainer.openAttemptJournalURL()`/the real App Group container,
/// which is unavailable in a plain SPM test target anyway (no entitlements)
/// and must never be touched by tests regardless.
struct OpenAttemptJournalTests {
    /// Builds a fresh temp-directory file URL (not yet existing) for one
    /// test, plus a cleanup closure that removes the ENCLOSING throwaway
    /// directory afterwards (the journal may create sibling/rewritten files
    /// there).
    private func makeTempJournalURL() -> (url: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAttemptJournalTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("open-attempts.jsonl")
        return (url, { try? FileManager.default.removeItem(at: directory) })
    }

    private func makeRecord(
        attempt: Int = 1,
        maxAttempts: Int = 1,
        outcome: OpenAttemptOutcome = .success(status: 202),
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> OpenAttemptRecord {
        OpenAttemptRecord(
            timestamp: timestamp,
            attempt: attempt,
            maxAttempts: maxAttempts,
            outcome: outcome,
            elapsedMilliseconds: 100,
            willRetry: false
        )
    }

    // MARK: - Missing file -> []

    @Test func entriesReturnsEmptyWhenFileDoesNotExist() {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url)
        #expect(journal.entries() == [])
    }

    // MARK: - Append + order

    @Test func recordAppendsAndEntriesReturnsOldestFirst() {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url)
        let first = makeRecord(attempt: 1, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRecord(attempt: 2, timestamp: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRecord(attempt: 3, timestamp: Date(timeIntervalSince1970: 1_700_000_200))

        journal.record(first)
        journal.record(second)
        journal.record(third)

        let entries = journal.entries()
        #expect(entries == [first, second, third])
    }

    // MARK: - Trim at capacity

    @Test func recordTrimsToCapacityKeepingNewest() {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url, capacity: 3)
        let records = (0..<5).map { index in
            makeRecord(attempt: index, timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        for record in records {
            journal.record(record)
        }

        let entries = journal.entries()
        #expect(entries.count == 3)
        #expect(entries == Array(records.suffix(3)))
    }

    // MARK: - Corrupt line skip

    @Test func entriesSkipsCorruptLinesWithoutThrowing() throws {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url)
        let valid = makeRecord(attempt: 1)
        journal.record(valid)

        // Inject a corrupt line directly between two valid appends, and a
        // trailing corrupt (non-JSON) partial line at the very end -- both
        // must be silently skipped, never thrown.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write("not valid json at all\n".data(using: .utf8)!)
        try handle.close()

        let secondValid = makeRecord(attempt: 2, timestamp: Date(timeIntervalSince1970: 1_700_000_050))
        journal.record(secondValid)

        let handle2 = try FileHandle(forWritingTo: url)
        handle2.seekToEndOfFile()
        handle2.write("{\"truncated\": tru".data(using: .utf8)!) // no trailing newline
        try handle2.close()

        let entries = journal.entries()
        #expect(entries == [valid, secondValid])
    }

    // MARK: - Clear

    @Test func clearRemovesAllEntries() {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url)
        journal.record(makeRecord(attempt: 1))
        journal.record(makeRecord(attempt: 2))
        #expect(journal.entries().count == 2)

        journal.clear()
        #expect(journal.entries() == [])
    }

    /// `clear()` on a journal file that was never created must be a
    /// harmless no-op (not a crash), since it swallows I/O failures.
    @Test func clearOnMissingFileDoesNotThrowOrCrash() {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url)
        journal.clear()
        #expect(journal.entries() == [])
    }

    // MARK: - All outcome cases round-trip through the on-disk format

    @Test(arguments: [
        OpenAttemptOutcome.success(status: 202),
        .httpFailure(status: 500),
        .transportFailure(urlErrorCode: URLError.networkConnectionLost.rawValue),
        .tokenFailure(description: "invalid credentials"),
    ])
    func recordRoundTripsEveryOutcomeCase(outcome: OpenAttemptOutcome) {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url)
        let record = makeRecord(outcome: outcome)
        journal.record(record)

        #expect(journal.entries() == [record])
    }

    // MARK: - Concurrency regressions (gateopener-41m.2 fix pass)

    /// 8 concurrent tasks x 50 records into ONE journal instance, capacity
    /// high enough that no trimming occurs -- every one of the 400 records
    /// must survive and decode. This reproduces the reviewer's original
    /// failure (384/400 survived) against the pre-fix `seekToEndOfFile` +
    /// `write` implementation.
    @Test func concurrentRecordsFromOneInstanceAllSurvive() async {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let journal = OpenAttemptJournal(fileURL: url, capacity: 10_000)
        let taskCount = 8
        let recordsPerTask = 50

        await withTaskGroup(of: Void.self) { group in
            for taskIndex in 0..<taskCount {
                group.addTask {
                    for recordIndex in 0..<recordsPerTask {
                        let record = self.makeRecord(
                            attempt: taskIndex * recordsPerTask + recordIndex,
                            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(taskIndex * recordsPerTask + recordIndex))
                        )
                        journal.record(record)
                    }
                }
            }
        }

        let entries = journal.entries()
        #expect(entries.count == taskCount * recordsPerTask)
        // Every attempt index 0..<400 must appear exactly once -- proves no
        // record was silently dropped or corrupted (a corrupt line would be
        // skipped by `entries()`, which would show up as a missing index).
        let attempts = Set(entries.map(\.attempt))
        #expect(attempts.count == taskCount * recordsPerTask)
    }

    /// Two SEPARATE `OpenAttemptJournal` instances on the SAME `fileURL`
    /// (simulating two processes, as far as a unit test can) writing
    /// concurrently with a small capacity, so trimming is exercised
    /// concurrently with appends from the other instance. Asserts count,
    /// full decodability, and no partial/corrupt line -- deliberately does
    /// NOT over-assert cross-instance ordering.
    @Test func concurrentRecordsFromTwoInstancesNeverCorruptOrLose() async {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let capacity = 50
        let journalA = OpenAttemptJournal(fileURL: url, capacity: capacity)
        let journalB = OpenAttemptJournal(fileURL: url, capacity: capacity)
        let recordsPerInstance = 100

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<recordsPerInstance {
                    journalA.record(self.makeRecord(
                        attempt: index,
                        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                    ))
                }
            }
            group.addTask {
                for index in 0..<recordsPerInstance {
                    journalB.record(self.makeRecord(
                        attempt: 10_000 + index,
                        timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
                    ))
                }
            }
        }

        // Read the raw file directly to prove every line -- not just what
        // `entries()` returns -- is complete and decodable: no partial line
        // from a torn concurrent write.
        let rawData = try? Data(contentsOf: url)
        #expect(rawData != nil)
        if let rawData {
            let text = String(decoding: rawData, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            #expect(!lines.isEmpty)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for line in lines {
                let lineData = Data(line.utf8)
                let decoded = try? decoder.decode(OpenAttemptRecord.self, from: lineData)
                #expect(decoded != nil, "found a corrupt/partial line: \(line)")
            }
        }

        let entries = journalA.entries()
        #expect(entries.count == capacity)
        // Both instances read/write the same file, so `entries()` from
        // either instance must agree.
        #expect(journalB.entries().count == capacity)
    }

    // MARK: - Physical trim regressions (gateopener-41m.2 review 2 fix)

    /// Reads the raw file directly and returns the non-empty physical lines,
    /// bypassing `entries()` entirely -- `entries()` always caps its result
    /// at `capacity` via `suffix(capacity)` regardless of whether a physical
    /// trim ever actually ran, so it cannot detect an unbounded on-disk file
    /// the way this helper can.
    private func physicalLines(at url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The reviewer's exact reproduction: capacity 10, 500 sequential
    /// records into one instance. Before the fix, the write-only fd made
    /// `trimToCapacityIfNeeded`'s `read(2)` fail EBADF, which was swallowed
    /// into an empty `Data()`/`nil`, so `parseLines` returned `[]`, the
    /// `records.count > capacity + hysteresis` guard was never true, and the
    /// trim never ran -- leaving all 500 lines on disk. Asserts the physical
    /// line count is bounded by `capacity + trimHysteresis`, and that the
    /// physical lines that remain are exactly the newest records, in order.
    @Test func physicalFileIsTrimmedAfterExceedingCapacityPlusHysteresis() throws {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let capacity = 10
        let journal = OpenAttemptJournal(fileURL: url, capacity: capacity)
        let totalRecords = 500
        for index in 0..<totalRecords {
            journal.record(makeRecord(
                attempt: index,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            ))
        }

        let lines = try physicalLines(at: url)
        #expect(lines.count <= capacity + OpenAttemptJournal.trimHysteresis)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = lines.compactMap { line -> OpenAttemptRecord? in
            try? decoder.decode(OpenAttemptRecord.self, from: Data(line.utf8))
        }
        #expect(decoded.count == lines.count, "every physical line must decode")

        // The last physical line must be the very last record written...
        #expect(decoded.last?.attempt == totalRecords - 1)
        // ...and the retained physical lines must be exactly the newest
        // records, contiguous and ascending by attempt index (i.e. no gap,
        // no stale/old record left behind by a partial trim).
        let attempts = decoded.map(\.attempt)
        let expectedAttempts = Array((totalRecords - attempts.count)..<totalRecords)
        #expect(attempts == expectedAttempts)
    }

    /// After the physical trim above has run, `entries()` must still return
    /// exactly `capacity` records -- the newest ones, oldest-first.
    @Test func entriesAfterTrimReturnsExactlyCapacityNewestOldestFirst() throws {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let capacity = 10
        let journal = OpenAttemptJournal(fileURL: url, capacity: capacity)
        let totalRecords = 500
        let records = (0..<totalRecords).map { index in
            makeRecord(
                attempt: index,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        for record in records {
            journal.record(record)
        }

        let entries = journal.entries()
        #expect(entries.count == capacity)
        #expect(entries == Array(records.suffix(capacity)))
        // Explicitly confirm oldest-first ordering.
        #expect(entries.map(\.attempt) == entries.map(\.attempt).sorted())
    }

    /// Two instances on the same file, capacity 50, 300 records each,
    /// concurrently -- exercises the trim path racing with a concurrent
    /// append from the other "process". The physical line count must stay
    /// bounded and every physical line must decode (no torn/partial write
    /// left behind by a trim that raced with an in-flight append).
    @Test func concurrentTrimAcrossTwoInstancesStaysBoundedAndDecodable() async throws {
        let (url, cleanup) = makeTempJournalURL()
        defer { cleanup() }

        let capacity = 50
        let journalA = OpenAttemptJournal(fileURL: url, capacity: capacity)
        let journalB = OpenAttemptJournal(fileURL: url, capacity: capacity)
        let recordsPerInstance = 300

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<recordsPerInstance {
                    journalA.record(self.makeRecord(
                        attempt: index,
                        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                    ))
                }
            }
            group.addTask {
                for index in 0..<recordsPerInstance {
                    journalB.record(self.makeRecord(
                        attempt: 10_000 + index,
                        timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
                    ))
                }
            }
        }

        let lines = try physicalLines(at: url)
        #expect(lines.count <= capacity + OpenAttemptJournal.trimHysteresis)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            let decoded = try? decoder.decode(OpenAttemptRecord.self, from: Data(line.utf8))
            #expect(decoded != nil, "found a corrupt/partial physical line after concurrent trim: \(line)")
        }
    }
}
