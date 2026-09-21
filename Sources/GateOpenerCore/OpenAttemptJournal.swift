import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A cross-process, append-only, capacity-bounded journal of
/// `OpenAttemptRecord`s persisted to a single JSON-lines file, so BOTH the
/// main app process and the widget/App-Intent extension process (which runs
/// out-of-process with `openAppWhenRun = false` — see `OpenGateIntent`) can
/// write and later read the same history. An in-memory log (like
/// `EventLog`) is useless here precisely because the intent path never
/// shares memory with the app.
///
/// FILE FORMAT: one JSON-encoded `OpenAttemptRecord` per line (JSONEncoder
/// with `.iso8601` date encoding), newest-appended-last.
///
/// WRITE STRATEGY: `record(_:)` opens the file with POSIX `open(2)` using
/// `O_RDWR | O_APPEND | O_CREAT` (read+write, because the trim step below
/// reads the file back through the same fd), takes an exclusive `flock`, and
/// then
/// writes the complete line (JSON + trailing `"\n"`) in a SINGLE `write(2)`
/// call. `O_APPEND` makes each such write atomic with respect to the
/// current end-of-file even without a lock (the kernel moves the file
/// offset to EOF and performs the write as one operation for writes that
/// fit within `PIPE_BUF`/atomic-write limits on the local filesystem); the
/// `flock` is what additionally serializes the "should I trim?" decision
/// so no process observes or produces a half-written trim. In-process,
/// every operation is ALSO serialized by a private `NSLock`, because
/// `flock` is scoped to an open-file-description: two threads in the same
/// process that each `open()` their own fd do NOT exclude each other via
/// `flock` alone (BSD/Darwin `flock` semantics), so the in-process lock is
/// required in addition to, not instead of, the cross-process `flock`.
///
/// APPEND + TRIM ATOMICITY: append, the capacity check, and (if needed) the
/// in-place rewrite-to-trim all happen inside ONE acquisition of the
/// exclusive lock on ONE file descriptor, so a trim can never race with,
/// and silently drop, another process's concurrent append. Trimming uses
/// hysteresis: the file is only rewritten once its line count exceeds
/// `capacity + trimHysteresis`, at which point it is truncated back down to
/// exactly `capacity` newest lines. This keeps the common (non-trimming)
/// append path to a single `write(2)` call, at the cost of `entries()`
/// occasionally observing up to `capacity + trimHysteresis` lines in the
/// file on disk -- `entries()` itself still only ever RETURNS the newest
/// `capacity` records (older ones beyond that are dropped from the
/// returned array even before the next physical trim), so no caller-visible
/// behavior changes: `entries().count <= capacity` always holds.
///
/// The trim rewrite itself (when it happens) truncates the file in place
/// and rewrites it from offset 0, rather than writing to a new file and
/// renaming it into place -- an atomic rename would create a NEW inode,
/// orphaning any lock another process is holding (or about to take) on the
/// OLD inode, which would silently break cross-process exclusion.
///
/// CROSS-PROCESS SAFETY: every read-modify-write (append+trim, `clear()`)
/// and every read (`entries()`) is performed while holding an advisory
/// `flock()` on the journal file itself. `flock` is a good fit here (over
/// `NSFileCoordinator`, which is designed for coordinating with other
/// apps/extensions via the file-provider/document-architecture stack and
/// pulls in `NSFilePresenter` ceremony this single-file, same-App-Group,
/// two-known-processes case does not need): both processes are POSIX
/// processes operating on a local file in the shared App Group container,
/// `flock` is simple, synchronous, and has no dependency on a run loop or
/// presenter registration. `flock`'s return value is always checked: if it
/// fails, the whole operation (including an append) is skipped silently
/// rather than proceeding unlocked.
///
/// FAILURE POLICY: every method swallows I/O errors. Logging an open
/// attempt must NEVER fail, slow, or throw into `GateClient.open`'s control
/// flow — `record(_:)` in particular is called synchronously from
/// `GateClient` per `OpenAttemptObserving`'s contract (see that protocol's
/// doc comment: "Implementations MUST be synchronous and non-throwing").
/// A corrupt or partial line (e.g. another process's write was torn by a
/// crash mid-write) is skipped when reading, never thrown.
public final class OpenAttemptJournal: OpenAttemptObserving, @unchecked Sendable {
    /// The file this journal reads/appends. Not necessarily pre-existing —
    /// `record(_:)` creates it (and any missing intermediate directories)
    /// on first use.
    public let fileURL: URL
    /// Maximum number of records retained. `entries()` never returns more
    /// than this many records. The on-disk file may transiently grow up to
    /// `capacity + trimHysteresis` lines before a physical trim runs; see
    /// the type's doc comment.
    public let capacity: Int

    /// How many lines past `capacity` the file is allowed to grow before a
    /// trim rewrite runs. Keeps the common append path to a single
    /// `write(2)` call instead of rewriting the file on every append.
    /// Exposed (not just `private`) so tests can assert the physical
    /// on-disk line count bound without hard-coding this value.
    static let trimHysteresis = 20
    private let trimHysteresis = OpenAttemptJournal.trimHysteresis

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Serializes ALL journal operations within this process. Required in
    /// addition to the cross-process `flock`: `flock` is scoped to an
    /// open-file-description, so two threads that each open their own fd on
    /// the same path are NOT excluded from each other by `flock` alone.
    private let processLock = NSLock()

    public init(fileURL: URL, capacity: Int = 200) {
        self.fileURL = fileURL
        self.capacity = capacity
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - OpenAttemptObserving

    /// Appends `record` as one JSON line via a single atomic `write(2)`
    /// (the fd is opened `O_APPEND`), then -- while still holding the same
    /// lock acquisition -- trims the file to `capacity` lines if it has
    /// grown past `capacity + trimHysteresis`. Synchronous, non-throwing,
    /// and swallows every failure (missing container, permission error,
    /// lock failure, encode failure) — a logging failure must never affect
    /// `GateClient.open`.
    public func record(_ record: OpenAttemptRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A) // "\n"

        processLock.lock()
        defer { processLock.unlock() }

        withExclusiveLock { fd in
            guard Self.appendLine(line, to: fd) else { return }
            Self.trimToCapacityIfNeeded(fd: fd, capacity: capacity, hysteresis: trimHysteresis, encoder: encoder, decoder: decoder)
        }
    }

    // MARK: - Read access

    /// All currently-persisted records, oldest first, capped at `capacity`
    /// entries (the newest `capacity`). Returns `[]` (never throws) if the
    /// file does not exist, cannot be read, or every line in it is corrupt.
    /// Corrupt/partial individual lines are skipped rather than failing the
    /// whole read.
    public func entries() -> [OpenAttemptRecord] {
        processLock.lock()
        defer { processLock.unlock() }

        let records = withSharedLock { fd -> [OpenAttemptRecord] in
            guard let data = Self.readAllFromStart(fd) else { return [] }
            return Self.parseLines(data, decoder: decoder)
        } ?? []
        return Array(records.suffix(capacity))
    }

    /// Removes all persisted records by truncating the journal file to
    /// empty. Swallows any I/O failure (including a missing file, which is
    /// treated as already-clear).
    public func clear() {
        processLock.lock()
        defer { processLock.unlock() }

        withExclusiveLock { fd in
            _ = ftruncate(fd, 0)
        }
    }

    // MARK: - Private: line parsing

    private static func parseLines(_ data: Data, decoder: JSONDecoder) -> [OpenAttemptRecord] {
        guard !data.isEmpty else { return [] }
        let newline: UInt8 = 0x0A
        var records: [OpenAttemptRecord] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == newline {
                let lineData = data[start..<index]
                if !lineData.isEmpty, let decoded = try? decoder.decode(OpenAttemptRecord.self, from: Data(lineData)) {
                    records.append(decoded)
                }
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        // Trailing partial line with no terminating newline (e.g. a write
        // torn by a crash mid-append): attempt to decode it too, but skip
        // silently if it's corrupt/incomplete.
        if start < data.endIndex {
            let lineData = data[start..<data.endIndex]
            if let decoded = try? decoder.decode(OpenAttemptRecord.self, from: Data(lineData)) {
                records.append(decoded)
            }
        }
        return records
    }

    // MARK: - Private: appending + trimming (called while holding both locks)

    /// Writes `line` (already newline-terminated) to `fd` in one `write(2)`
    /// call. `fd` was opened with `O_APPEND`, so the kernel atomically seeks
    /// to EOF and performs the write. Retries on `EINTR`; gives up silently
    /// on any other failure or short write, per this journal's
    /// swallow-all-I/O-errors policy.
    private static func appendLine(_ line: Data, to fd: Int32) -> Bool {
        line.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var remaining = rawBuffer.count
            var pointer = base
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    /// Rewrites the file to keep only the newest `capacity` lines, if the
    /// current line count exceeds `capacity + hysteresis`. Called while
    /// already holding the exclusive `flock` on `fd` (and the in-process
    /// lock), as part of the SAME lock acquisition as the append that
    /// preceded it, so no concurrent append from another process/thread can
    /// be lost between "append" and "trim".
    /// Reads the whole file (from a read-modify-write-capable `fd`), and
    /// only if that read fully succeeds, checks whether the line count
    /// exceeds `capacity + hysteresis`; if so, truncates and rewrites the
    /// file in place with just the newest `capacity` lines. If the read
    /// fails (e.g. wrong `fd` mode, I/O error) this is a NO-OP: the file is
    /// never truncated based on a failed or partial read, since that would
    /// destroy data we couldn't actually verify was safe to drop.
    private static func trimToCapacityIfNeeded(fd: Int32, capacity: Int, hysteresis: Int, encoder: JSONEncoder, decoder: JSONDecoder) {
        guard let data = readAllFromStart(fd) else { return }
        let records = parseLines(data, decoder: decoder)
        guard records.count > capacity + hysteresis else { return }
        let kept = records.suffix(capacity)
        var rewritten = Data()
        for entry in kept {
            guard let line = try? encoder.encode(entry) else { continue }
            rewritten.append(line)
            rewritten.append(0x0A)
        }
        guard ftruncate(fd, 0) == 0 else { return }
        // `fd` is opened O_APPEND, so this write lands at EOF, which after
        // truncating to 0 is offset 0 -- i.e. the rewrite starts from the
        // beginning of the (now-empty) file, as intended.
        _ = appendLine(rewritten, to: fd)
    }

    /// Reads the entire file from offset 0 on `fd`. Returns `nil` (never an
    /// empty `Data()`) if the initial `lseek` or any `read(2)` call fails,
    /// so callers can distinguish "read failed" from "file is legitimately
    /// empty" and avoid treating a failed read as if the file were empty.
    private static func readAllFromStart(_ fd: Int32) -> Data? {
        guard lseek(fd, 0, SEEK_SET) == 0 else { return nil }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return read(fd, base, rawBuffer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if bytesRead == 0 { break }
            result.append(contentsOf: buffer[0..<bytesRead])
        }
        return result
    }

    // MARK: - Private: file access + advisory locking

    /// Opens (creating if necessary) `fileURL` for read+append (`O_RDWR |
    /// O_APPEND | O_CREAT` for exclusive/write access, since the trim step
    /// needs to read back through the same fd it appended with), takes an
    /// exclusive `flock` on that fd, runs `body` with the raw file
    /// descriptor, then always unlocks and closes — even if `body` returns
    /// early. Swallows every failure (missing App Group container,
    /// permission error, lock failure, etc.) by simply not calling `body`
    /// and returning `nil`.
    @discardableResult
    private func withExclusiveLock<T>(_ body: (Int32) -> T) -> T? {
        withLock(exclusive: true, body: body)
    }

    /// Same as `withExclusiveLock`, but opens for reading and takes a
    /// shared (read) `flock`, allowing concurrent readers while still
    /// excluding a concurrent writer's read-modify-write.
    @discardableResult
    private func withSharedLock<T>(_ body: (Int32) -> T) -> T? {
        withLock(exclusive: false, body: body)
    }

    private func withLock<T>(exclusive: Bool, body: (Int32) -> T) -> T? {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
                return nil
            }
        }

        let path = fileURL.path
        // Exclusive (write) operations open O_RDWR (not O_WRONLY): the same
        // fd is used both to append (via O_APPEND, so every `write(2)` of a
        // complete line is atomically positioned at EOF by the kernel) AND,
        // under the same lock acquisition, to read the whole file back for
        // the capacity/trim check -- a write-only fd would make that read
        // fail with EBADF. Shared (read) operations don't need O_APPEND
        // since they always explicitly `lseek` to the start before reading.
        let flags: Int32 = exclusive ? (O_RDWR | O_APPEND | O_CREAT) : (O_RDONLY | O_CREAT)
        let fd = path.withCString { open($0, flags, 0o644) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let operation: Int32 = exclusive ? LOCK_EX : LOCK_SH
        guard flock(fd, operation) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }

        return body(fd)
    }
}
