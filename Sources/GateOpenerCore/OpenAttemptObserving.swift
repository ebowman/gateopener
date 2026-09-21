import Foundation

// MARK: - OpenAttemptOutcome

/// The closed set of outcomes a single `GateClient.open` HTTP attempt can
/// resolve to, as reported to an injected `OpenAttemptObserving`.
///
/// Deliberately an enum (not a raw status/error dump): each case carries
/// only the non-secret metadata a caller needs to render a message like
/// "attempt 2 of 3 failed HTTP 500 after 2.9s" -- never a response body,
/// header, or token.
public enum OpenAttemptOutcome: Sendable, Equatable, Codable {
    /// The attempt succeeded (HTTP 202, or HTTP 200 accepted defensively).
    case success(status: Int)
    /// The attempt got an HTTP response, but a non-success status.
    case httpFailure(status: Int)
    /// The attempt never got an HTTP response at all (a transport-level
    /// failure). `urlErrorCode` is `URLError.code.rawValue` when the
    /// underlying error is a `URLError`, or `-1` if it is some other error
    /// type.
    case transportFailure(urlErrorCode: Int)
    /// Resolving a bearer token failed before any HTTP request was made for
    /// this attempt (e.g. `.invalidCredentials`). `description` is a
    /// human-readable, non-secret description of the failure -- never the
    /// credential/token itself.
    case tokenFailure(description: String)
}

// MARK: - OpenAttemptRecord

/// A record of exactly one attempt within a single `GateClient.open` call,
/// reported to an injected `OpenAttemptObserving` so a caller can log
/// something like "attempt 2 of 3 failed HTTP 500 after 2.9s".
public struct OpenAttemptRecord: Sendable, Equatable, Codable {
    /// When this attempt was made.
    public let timestamp: Date
    /// The 1-based index of this attempt (1...`maxAttempts`).
    public let attempt: Int
    /// The total number of attempts the governing `RetryPolicy` allows.
    public let maxAttempts: Int
    /// How this attempt resolved.
    public let outcome: OpenAttemptOutcome
    /// Wall-clock duration of this attempt's own request only -- it does
    /// NOT include any backoff sleep before or after the attempt.
    public let elapsedMilliseconds: Int
    /// Whether `GateClient.open` will make a further attempt after this one.
    public let willRetry: Bool

    public init(
        timestamp: Date,
        attempt: Int,
        maxAttempts: Int,
        outcome: OpenAttemptOutcome,
        elapsedMilliseconds: Int,
        willRetry: Bool
    ) {
        self.timestamp = timestamp
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds
        self.willRetry = willRetry
    }
}

// MARK: - OpenAttemptObserving

/// Observer notified once per `GateClient.open` attempt, after that
/// attempt's outcome (and whether it will be retried) is known.
///
/// Implementations MUST be synchronous and non-throwing (`record` returns
/// `Void` and is not `async`/`throws`), and are called outside any lock held
/// by `GateClient` -- the observer can never affect `open`'s control flow or
/// timing.
public protocol OpenAttemptObserving: Sendable {
    func record(_ record: OpenAttemptRecord)
}
