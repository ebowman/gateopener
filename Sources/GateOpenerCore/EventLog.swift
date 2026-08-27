import Foundation

// MARK: - LogLevel

/// The category/severity of a `LogEntry`. Kept small and closed (not a raw
/// string) so every call site is forced through a known, reviewed set of
/// kinds rather than free-form text.
public enum LogLevel: String, Sendable, Equatable, CaseIterable {
    case info
    case warning
    case error
}

// MARK: - OpenFailureReason

/// A closed set of known open-failure reasons that carry no HTTP status
/// code (e.g. a network-layer error rather than an HTTP response).
///
/// Deliberately an enum, not a free-form `String`: a `String` parameter is
/// the only shape through which a caller could ever pass a secret (an
/// error's `localizedDescription`, a URL with a credential in its query
/// string, an `Authorization` header value) into the log, even by
/// accident. Closing the channel to a fixed, reviewed set of cases makes
/// that structurally impossible, matching every other method on
/// `EventLog`. If a new failure kind needs representing, add a new case
/// here — never widen this back to `String`.
public enum OpenFailureReason: String, Sendable, Equatable, CaseIterable {
    case timeout
    case unauthorized
    case serverError
    case transport
    case cancelled
    case unknown

    /// The exact text this reason renders as in a log message.
    var logText: String {
        switch self {
        case .timeout: return "timed out"
        case .unauthorized: return "unauthorized"
        case .serverError: return "server error"
        case .transport: return "transport error"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown error"
        }
    }
}

// MARK: - LogEntry

/// A single, already-redacted diagnostic log entry.
///
/// `message` is asserted, by construction, to never contain a secret: every
/// call site that produces a `LogEntry` (see `EventLog`'s typed logging
/// methods below) is written so the underlying secret value is structurally
/// unreachable from `message` — token/password strings are never
/// interpolated, only non-secret metadata (attempt counts, HTTP status
/// codes, token lifetimes) is.
public struct LogEntry: Sendable, Equatable {
    public let timestamp: Date
    public let level: LogLevel
    public let message: String

    /// Internal (not `public`): the only production call site is
    /// `EventLog.append(level:message:)` in this same file/module. Keeping
    /// this initializer non-public means no caller outside
    /// `GateOpenerCore` can construct a `LogEntry` with an arbitrary
    /// `message` and inject it anywhere — defence in depth on top of the
    /// fact that `EventLog.append` is already `private` and there is no
    /// public method on `EventLog` that accepts a `LogEntry`.
    init(timestamp: Date, level: LogLevel, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

// MARK: - EventLog
//
// HARD REQUIREMENT (bead gateopener-4ub.10): no access token, refresh
// token, password, PKCE verifier, or Authorization header value may EVER
// enter a log entry. `EventLog`'s public API is deliberately built almost
// entirely from TYPED methods (`logTokenRefreshed(expiresIn:)`,
// `logOpenAttempt(attempt:of:)`, `logOpenFailed(attempt:status:)`, etc.)
// that accept only non-secret metadata (counts, HTTP status codes, token
// lifetimes in seconds) — there is no parameter through which a caller
// *could* pass a raw token or password even by mistake, short of actively
// working around the type signature. A general-purpose `log(String)`
// escape hatch is intentionally NOT provided, because it would invite a
// caller to interpolate a secret into a free-form message; every event
// this app needs to record has a typed method below instead. If a future
// event kind is added, add a new typed method (not a free-form string
// parameter) and keep this constraint intact.

/// A thread-safe, bounded ring buffer of the most recent diagnostic events,
/// suitable for display in a Settings "Show Log" disclosure with a "Copy"
/// button (see `formattedText()`).
///
/// Thread safety is provided by an internal `NSLock` guarding a fixed-size
/// buffer, so `EventLog` can be called from any thread/actor (including
/// background token-refresh work) without additional synchronization by
/// callers.
public final class EventLog: @unchecked Sendable {
    /// Maximum number of entries retained. Oldest entries are dropped first
    /// once this cap is reached — this is a ring buffer, not an
    /// ever-growing log.
    public static let capacity = 100

    private let lock = NSLock()
    private var entries: [LogEntry] = []

    public init() {}

    // MARK: - Typed logging API (secret-safe by construction)

    /// Records that an open attempt N of `total` was started.
    public func logOpenAttempt(attempt: Int, of total: Int) {
        append(level: .info, message: "open attempted (attempt \(attempt) of \(total))")
    }

    /// Records that open attempt N of `total` failed with the given HTTP
    /// status code. `status` is an `Int` (not the response body/headers),
    /// so there is no way for this call site to leak an Authorization
    /// header or response payload.
    public func logOpenFailed(attempt: Int, of total: Int, status: Int) {
        append(level: .warning, message: "attempt \(attempt) of \(total) failed with HTTP \(status)")
    }

    /// Records that open attempt N of `total` failed with no HTTP status
    /// available (e.g. a network-layer error). Takes a closed
    /// `OpenFailureReason` enum, not a free-form `String` — see that
    /// type's doc comment for why: it is the only way to make this
    /// channel structurally incapable of carrying a secret.
    public func logOpenFailed(attempt: Int, of total: Int, reason: OpenFailureReason) {
        append(level: .warning, message: "attempt \(attempt) of \(total) failed (\(reason.logText))")
    }

    /// Records that the open command succeeded.
    public func logOpenSucceeded() {
        append(level: .info, message: "open succeeded")
    }

    /// Records that the access token was refreshed. `expiresIn` is the
    /// token's LIFETIME in seconds — never the token value itself, which
    /// this method has no parameter through which to accept.
    ///
    /// `expiresIn` is not validated by its caller (the intended call site
    /// is `tokenSet.expiresAt.timeIntervalSinceNow`, a computed
    /// `TimeInterval` that can legitimately be `.nan`/`.infinity`/a huge
    /// magnitude), so this must never trap on those inputs — a logging
    /// path must never crash the app. Non-finite or absurdly large/small
    /// values are rendered as "unknown" rather than converted to `Int`
    /// (`Int(Double)` traps on non-finite input and on magnitudes outside
    /// `Int`'s range).
    public func logTokenRefreshed(expiresIn: TimeInterval) {
        append(level: .info, message: "refreshed token (expires in \(formattedExpiresIn(expiresIn))s)")
    }

    /// Renders a token lifetime for `logTokenRefreshed`, never trapping.
    /// Non-finite (`.nan`, `.infinity`, `-.infinity`) or out-of-`Int`-range
    /// values render as `"unknown"`; everything else renders as the
    /// rounded integer seconds.
    private func formattedExpiresIn(_ expiresIn: TimeInterval) -> String {
        guard expiresIn.isFinite else { return "unknown" }
        // `Int(Double)` traps if the value doesn't fit in `Int`'s range, so
        // convert with `Int(exactly:)` and let a nil result mean "unknown".
        //
        // Do NOT reintroduce a range comparison here. The obvious-looking
        // `expiresIn <= Double(Int.max)` is WRONG: `Double(Int.max)` rounds
        // UP to 9223372036854775808.0 (== Int.max + 1), which is not
        // representable as an Int, so `<=` admits it and the conversion then
        // traps. `Int(exactly:)` has no such boundary to get wrong.
        guard let seconds = Int(exactly: expiresIn.rounded()) else { return "unknown" }
        return String(seconds)
    }

    /// Records that a full username/password login was performed. Takes no
    /// parameters at all — a login event carries no non-secret detail worth
    /// recording beyond the fact that it happened.
    public func logLoginPerformed() {
        append(level: .info, message: "login performed")
    }

    /// Records that gate discovery was performed, and how many endpoints
    /// were found. `endpointCount` is a count, never the endpoint IDs
    /// themselves (which, while not classic "secrets", are still kept out
    /// of the log to avoid over-sharing device identifiers).
    public func logDiscoveryPerformed(endpointCount: Int) {
        append(level: .info, message: "discovery performed (\(endpointCount) endpoint(s) found)")
    }

    // MARK: - Read access

    /// A point-in-time copy of the current buffer contents, oldest first.
    public func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// The buffer rendered as plain text, one entry per line, suitable for
    /// putting directly on the pasteboard from a Settings "Copy" button.
    public func formattedText() -> String {
        let formatter = ISO8601DateFormatter()
        return snapshot()
            .map { entry in
                "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
            }
            .joined(separator: "\n")
    }

    /// Removes all entries. Exposed primarily for tests, but harmless to
    /// call from app code (e.g. a future "Clear Log" affordance).
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    // MARK: - Private

    private func append(level: LogLevel, message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }
}
