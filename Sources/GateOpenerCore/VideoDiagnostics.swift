import Foundation

/// Collects a plain-text diagnostics log for exactly ONE `DoorVideoSession`
/// attempt, so an operator hitting the "does not work off the LAN" failure
/// (bead gateopener-672.27) can capture and share a log naming candidate
/// types, the selected candidate pair, and the failure stage -- from a
/// RELEASE (TestFlight) build, where there is no attached debug console.
///
/// Deliberately independent of `os.Logger`: `Logger` output is not easily
/// exfiltrated from a Release build by an end user, whereas this type's
/// `text` is designed to be persisted to the shared app-group `UserDefaults`
/// and displayed/shared directly from Settings.
///
/// `append(_:)` caps total stored text at `maxBytes` (16KB) by dropping the
/// OLDEST lines first, so the most recent (most diagnostically relevant --
/// typically the failure/terminal lines) content is always retained.
///
/// A PINNED viewing period (bead gateopener-41m.20) is 6+ sessions long, and
/// the interesting failure is rarely the last one -- each renewal calling
/// `persist(to:)` would otherwise overwrite the evidence of the one before,
/// per this type's single-session `defaultsKey`. `appendToHistory`/
/// `loadHistory`/`clearHistory` (below) maintain a SEPARATE rolling record,
/// under a different key, that survives across renewals: `persist(to:)`
/// writes both the single "last session" blob (unchanged, so `loadLast` and
/// existing callers keep working) and this session's block in the history.
@MainActor
public final class VideoDiagnostics {
    /// The `UserDefaults` key both `persist(to:)` and `loadLast(from:)` use.
    public static let defaultsKey = "videoDiagnostics"

    /// The `UserDefaults` key the rolling history (`appendToHistory`/
    /// `loadHistory`/`clearHistory`) is stored under. Deliberately distinct
    /// from `defaultsKey` so the single-session blob keeps working exactly
    /// as before for any caller that never adopts the history API.
    public static let historyDefaultsKey = "videoDiagnosticsHistory"

    /// Total cap on `text`'s UTF-8 byte size. 16KB comfortably holds a full
    /// ~30-35s session's worth of state transitions, candidate summaries,
    /// and selected-pair polls (each line is well under 200 bytes) while
    /// staying small enough to store in `UserDefaults` and paste into a bug
    /// report without truncation concerns downstream.
    public static let maxBytes = 16 * 1024

    /// Total cap on the encoded rolling history `Data`. A pinned viewing
    /// period is 6+ sessions; 64KB comfortably holds several full sessions'
    /// blocks plus interleaved pin/coordinator event lines while remaining
    /// well within `UserDefaults`' practical per-key size expectations. When
    /// exceeded, whole OLDEST entries (session blocks or single event lines)
    /// are dropped from the front -- never a partial session -- so the
    /// history is always a set of complete, self-contained blocks.
    public static let maxHistoryBytes = 64 * 1024

    /// A stable identifier for THIS `VideoDiagnostics` instance, i.e. this
    /// one session attempt. A session persists several times during its
    /// life (bead gateopener-41m.20: on every terminal diagnostic line and
    /// on `stop()`) -- `id` lets `appendToHistory` recognize a re-persist of
    /// the SAME session and replace its block in place (keeping its
    /// original chronological position) rather than appending a duplicate.
    public let id = UUID()

    /// When this `VideoDiagnostics` instance was created, used as the
    /// session block's header timestamp and its position key when the
    /// history is capped/ordered.
    public let startedAt: Date

    private var lines: [String] = []

    public init(now: Date = Date()) {
        self.startedAt = now
    }

    /// Appends one line (a newline is added automatically). If the
    /// resulting `text` would exceed `maxBytes`, the OLDEST lines are
    /// dropped (one at a time) until it fits again -- never the newest,
    /// since the newest lines (state transitions, the terminal reason) are
    /// exactly what a diagnostic report needs most.
    public func append(_ line: String) {
        lines.append(line)
        while textByteCount() > Self.maxBytes, lines.count > 1 {
            lines.removeFirst()
        }
        // Edge case: a single line alone already exceeds maxBytes (e.g. a
        // pathologically long SDP dump was appended by mistake). Truncate
        // it rather than looping forever with lines.count == 1.
        if lines.count == 1, textByteCount() > Self.maxBytes {
            lines[0] = String(lines[0].prefix(Self.maxBytes))
        }
    }

    /// The full accumulated log, one line per `append(_:)` call, joined by
    /// newlines.
    public var text: String {
        lines.joined(separator: "\n")
    }

    private func textByteCount() -> Int {
        text.utf8.count
    }

    /// Persists `text` to `defaults` under `defaultsKey`, AND
    /// appends/replaces this session's block in the rolling history under
    /// `historyDefaultsKey` (bead gateopener-41m.20). Called on every
    /// terminal state and on `stop()`, per this bead's requirement that a
    /// RELEASE build still leaves a shareable log after any given attempt
    /// (successful or not) -- there is deliberately no "only persist on
    /// failure" branch, since a same-network success and an off-network
    /// failure both need to be comparable from the same Settings row.
    ///
    /// Both writes are best-effort and never throw: `UserDefaults` itself
    /// has no throwing API, and the history encode step below fails soft
    /// (silently skipping the history update while still writing the
    /// single-session blob) rather than ever propagating into video code.
    public func persist(to defaults: UserDefaults) {
        defaults.set(text, forKey: Self.defaultsKey)
        Self.appendToHistory(id: id, startedAt: startedAt, sessionLog: text, to: defaults)
    }

    /// Loads the last persisted session's log text, or `nil` if none has
    /// ever been persisted (fresh install, or `UserDefaults(suiteName:)`
    /// returned `nil` for the caller's suite).
    public static func loadLast(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey)
    }

    // MARK: - Rolling history (bead gateopener-41m.20)

    /// One entry in the rolling history stream: either a full session's
    /// diagnostics block, or a single timestamped coordinator/pin event
    /// line. Stored as a flat, chronologically-ordered array (oldest first,
    /// newest last) in ONE `Data` value so session blocks and interleaved
    /// event lines share a single insertion-ordered timeline, exactly as
    /// they occurred.
    private enum HistoryEntry: Codable, Equatable {
        case session(id: UUID, startedAt: Date, text: String)
        case event(at: Date, text: String)

        /// Approximate encoded size, used by the cap-enforcement logic in
        /// `store(_:to:)`. Doesn't need to be exact -- it only needs to be
        /// monotonic with the actual encoded size closely enough that
        /// capping converges after a bounded number of re-encodes.
        var approximateByteCount: Int {
            switch self {
            case .session(_, _, let text):
                return text.utf8.count + 64
            case .event(_, let text):
                return text.utf8.count + 32
            }
        }
    }

    /// Redacts any substring that looks like a bearer token or an
    /// `Authorization` header value from `line`, case-insensitively. This is
    /// the ONLY guard of its kind in this file (the single-session `append`
    /// above intentionally has none -- every existing call site already
    /// avoids secrets by construction; see `EventLog.swift`'s equivalent
    /// design note), added here specifically because the history stream
    /// aggregates many sessions' worth of text over a long period and is
    /// the surface most likely to be pasted whole into a bug report.
    ///
    /// Matches "Bearer " (any case) and "authorization" (any case,
    /// anywhere in the line, e.g. an `Authorization:` header dump) by
    /// replacing the ENTIRE line with `[redacted]` -- a partial redaction
    /// risks leaving a trailing token fragment visible, and a diagnostics
    /// line that trips this guard was never supposed to contain a secret in
    /// the first place, so losing the rest of that one line costs nothing
    /// diagnostically.
    static func redacted(_ line: String) -> String {
        let lowered = line.lowercased()
        if lowered.contains("bearer ") || lowered.contains("authorization") {
            return "[redacted]"
        }
        return line
    }

    /// A local-time ISO8601 timestamp for a session block's header line
    /// (`=== video session <...> id=<8 hex> ===`) and for event lines.
    private static func headerTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Appends this session's diagnostics block to the history, or -- if a
    /// block for the same `id` already exists (this session has persisted
    /// before) -- replaces it in place, preserving its original
    /// chronological position rather than moving it to the end. This is how
    /// a session that persists several times during its life (every
    /// terminal diagnostic line, then again on `stop()`) ends up in the
    /// history exactly ONCE, in its final form.
    ///
    /// Every line of `sessionLog` is passed through `redacted(_:)` before
    /// storage.
    ///
    /// Never throws: an encode/decode failure (corrupt existing data, e.g.
    /// from a future format change) is treated as "no prior history" and
    /// simply starts a fresh one, rather than propagating into video code.
    public static func appendToHistory(id: UUID, startedAt: Date, sessionLog: String, to defaults: UserDefaults) {
        let redactedLog = sessionLog
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { redacted(String($0)) }
            .joined(separator: "\n")

        let header = "=== video session \(headerTimestamp(startedAt)) id=\(shortId(id)) ==="
        let block = header + "\n" + redactedLog

        var entries = load(from: defaults)
        if let index = entries.firstIndex(where: { if case .session(let existingId, _, _) = $0 { return existingId == id } else { return false } }) {
            entries[index] = .session(id: id, startedAt: startedAt, text: block)
        } else {
            entries.append(.session(id: id, startedAt: startedAt, text: block))
        }
        store(entries, to: defaults)
    }

    /// Appends a single, timestamped coordinator/pin event line (bead
    /// gateopener-41m.20 step 2/4, e.g. "pin on", "pin renew #2 (after
    /// failed: Door camera busy)", "pin stop: tooManyFailures") to the
    /// history, interleaved chronologically with session blocks by
    /// insertion order.
    ///
    /// `line` is passed through `redacted(_:)` before storage, matching
    /// `appendToHistory`'s guard.
    public static func appendEvent(_ line: String, to defaults: UserDefaults, now: Date = Date()) {
        var entries = load(from: defaults)
        entries.append(.event(at: now, text: redacted(line)))
        store(entries, to: defaults)
    }

    /// Renders the full rolling history as plain text: each entry (session
    /// block or event line) in insertion order, separated by a blank line,
    /// newest-relevant-content-preserved per the cap in `store(_:to:)`.
    /// Returns `nil` if the history is empty or has never been written.
    public static func loadHistory(from defaults: UserDefaults) -> String? {
        let entries = load(from: defaults)
        guard !entries.isEmpty else { return nil }
        return entries.map { entry -> String in
            switch entry {
            case .session(_, _, let text):
                return text
            case .event(let at, let text):
                return "[\(headerTimestamp(at))] \(text)"
            }
        }.joined(separator: "\n\n")
    }

    /// Clears the rolling history entirely.
    public static func clearHistory(in defaults: UserDefaults) {
        defaults.removeObject(forKey: historyDefaultsKey)
    }

    /// The first 8 hex characters of `id`'s UUID string (with hyphens
    /// removed first), used as the short, grep-friendly identifier in a
    /// session block's header line.
    private static func shortId(_ id: UUID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// Decodes the stored history `Data` into `[HistoryEntry]`, or `[]` if
    /// nothing has ever been stored or the stored data is corrupt/from an
    /// incompatible format (fails soft rather than throwing into video
    /// code).
    private static func load(from defaults: UserDefaults) -> [HistoryEntry] {
        guard let data = defaults.data(forKey: historyDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    /// Encodes `entries` and writes them to `defaults`, first enforcing
    /// `maxHistoryBytes` by dropping WHOLE oldest entries (never cutting a
    /// session block in half) from the front until the encoded size fits.
    /// Best-effort: an encode failure silently skips the write rather than
    /// throwing.
    private static func store(_ entries: [HistoryEntry], to defaults: UserDefaults) {
        var trimmed = entries
        // Fast pre-trim using the approximate byte count, so the encode
        // loop below converges in a bounded number of iterations even for
        // a very long history.
        while trimmed.count > 1, trimmed.reduce(0, { $0 + $1.approximateByteCount }) > maxHistoryBytes {
            trimmed.removeFirst()
        }

        guard var data = try? JSONEncoder().encode(trimmed) else { return }

        // Precise trim against the ACTUAL encoded size, since JSON framing
        // overhead means the approximate count above is not exact.
        while data.count > maxHistoryBytes, trimmed.count > 1 {
            trimmed.removeFirst()
            guard let reencoded = try? JSONEncoder().encode(trimmed) else { return }
            data = reencoded
        }

        // Edge case: a single entry alone already exceeds the cap (e.g. a
        // pathologically long session block). Keep it anyway -- there is
        // nothing else to drop, and dropping the only entry would silently
        // discard the most recent diagnostics entirely, defeating the
        // history's purpose after exactly the kind of large event a
        // diagnostic report needs most.
        defaults.set(data, forKey: historyDefaultsKey)
    }
}
