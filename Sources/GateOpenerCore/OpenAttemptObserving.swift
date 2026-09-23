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
    /// The id of the press (`OpenPressRecord.pressId`) this attempt was made
    /// on behalf of, correlating it to the press-level record written at
    /// intent entry/exit (see `OpenPressContext`). `nil` when the attempt was
    /// made outside any press context (e.g. a test that calls
    /// `GateClient.open` directly), and ALWAYS `nil` when decoding a legacy
    /// JSONL line written before this field existed -- `pressId` is optional
    /// specifically so old on-disk lines keep decoding.
    public let pressId: UUID?

    public init(
        timestamp: Date,
        attempt: Int,
        maxAttempts: Int,
        outcome: OpenAttemptOutcome,
        elapsedMilliseconds: Int,
        willRetry: Bool,
        pressId: UUID? = nil
    ) {
        self.timestamp = timestamp
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds
        self.willRetry = willRetry
        self.pressId = pressId
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

// MARK: - OpenPressPhase

/// One lifecycle checkpoint of a single "press" (one Action-Button/Siri/
/// widget invocation of `OpenGateIntent`, from intent entry to exit),
/// reported as its own `OpenPressRecord`/JSONL line.
///
/// Deliberately ONE PHASE PER LINE (rather than one record per press,
/// mutated in place) so that if the hosting process is killed mid-press
/// (e.g. the ~30s extension lifetime budget, or the user force-quitting the
/// app) every checkpoint reached before the kill is already durably on disk
/// -- there is no "final record" that a kill could prevent from ever being
/// written.
///
/// Case order below is the expected (not enforced) lifecycle order for a
/// successful press: `.started` -> `.environmentReady` -> `.reachability` ->
/// `.tokenResolved` (or `.tokenFailed`) -> `.openStarted` -> `.finished` (or
/// `.timedOut`). Any press may exit early (e.g. `.reachability(false, ...)`
/// followed directly by `.finished`) -- callers are not required to emit
/// every case.
///
/// Explicit `Codable` (see `CodingKeys`/`init(from:)`/`encode(to:)`) rather
/// than the compiler-synthesized enum-with-associated-values encoding: the
/// synthesized form nests each case under its own case-name key (e.g.
/// `{"reachability":{"isReachable":true,"detail":""}}`), which is harder to
/// grep/read in a raw JSONL log and would silently change shape if cases are
/// reordered. Instead every phase encodes as a flat object with a `kind`
/// string discriminator plus only the fields relevant to that case, e.g.
/// `{"kind":"reachability","isReachable":true,"detail":""}` or
/// `{"kind":"openStarted"}`.
public enum OpenPressPhase: Sendable, Equatable {
    /// The intent/press began. `elapsedMilliseconds` is always 0 for this
    /// case (it defines the press's own start).
    case started
    /// `AppEnvironment.make()` (or equivalent composition root) finished
    /// resolving.
    case environmentReady
    /// The reachability check ran before deciding whether to attempt
    /// `open()`. `detail` is a free-form, non-secret string (e.g. the
    /// underlying `NWPath` status name) -- never a token/credential.
    case reachability(isReachable: Bool, detail: String)
    /// A bearer token was resolved successfully. `kind` is a short,
    /// non-secret label for how it was resolved (e.g. "cached", "refreshed")
    /// -- never the token itself.
    case tokenResolved(kind: String)
    /// Token resolution failed. `description` MUST already be sanitized
    /// (see `TokenFailureDescription.sanitizedTokenFailureDescription`) --
    /// this case never carries a raw error/response body.
    case tokenFailed(description: String)
    /// `GateClient.open` (or the `open` closure wrapping it) was invoked.
    case openStarted
    /// The press reached a terminal outcome. `outcome` is
    /// `OpenGateFlow.Outcome.dialog` (a short, non-secret, already
    /// user-facing string) -- never a raw error.
    case finished(outcome: String)
    /// The press's own timeout elapsed before `open()` completed.
    case timedOut

    private enum Kind: String, Codable {
        case started
        case environmentReady
        case reachability
        case tokenResolved
        case tokenFailed
        case openStarted
        case finished
        case timedOut
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case isReachable
        case detail
        case tokenKind
        case description
        case outcome
    }
}

extension OpenPressPhase: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .started:
            self = .started
        case .environmentReady:
            self = .environmentReady
        case .reachability:
            let isReachable = try container.decode(Bool.self, forKey: .isReachable)
            let detail = try container.decode(String.self, forKey: .detail)
            self = .reachability(isReachable: isReachable, detail: detail)
        case .tokenResolved:
            let tokenKind = try container.decode(String.self, forKey: .tokenKind)
            self = .tokenResolved(kind: tokenKind)
        case .tokenFailed:
            let description = try container.decode(String.self, forKey: .description)
            self = .tokenFailed(description: description)
        case .openStarted:
            self = .openStarted
        case .finished:
            let outcome = try container.decode(String.self, forKey: .outcome)
            self = .finished(outcome: outcome)
        case .timedOut:
            self = .timedOut
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .started:
            try container.encode(Kind.started, forKey: .kind)
        case .environmentReady:
            try container.encode(Kind.environmentReady, forKey: .kind)
        case .reachability(let isReachable, let detail):
            try container.encode(Kind.reachability, forKey: .kind)
            try container.encode(isReachable, forKey: .isReachable)
            try container.encode(detail, forKey: .detail)
        case .tokenResolved(let tokenKind):
            try container.encode(Kind.tokenResolved, forKey: .kind)
            try container.encode(tokenKind, forKey: .tokenKind)
        case .tokenFailed(let description):
            try container.encode(Kind.tokenFailed, forKey: .kind)
            try container.encode(description, forKey: .description)
        case .openStarted:
            try container.encode(Kind.openStarted, forKey: .kind)
        case .finished(let outcome):
            try container.encode(Kind.finished, forKey: .kind)
            try container.encode(outcome, forKey: .outcome)
        case .timedOut:
            try container.encode(Kind.timedOut, forKey: .kind)
        }
    }
}

// MARK: - OpenPressRecord

/// A single lifecycle checkpoint (`phase`) of one press, persisted to the
/// same journal file as `OpenAttemptRecord`s (see `OpenJournalEntry`) so a
/// post-incident read of the journal shows exactly where each press got to
/// before it succeeded, failed, or the process was killed.
///
/// One `OpenPressRecord` is written per PHASE, not per press -- see
/// `OpenPressPhase`'s doc comment for why.
public struct OpenPressRecord: Sendable, Equatable, Codable {
    /// Correlates every phase of the same press, and correlates
    /// `OpenAttemptRecord`s made during this press's `open()` call (via
    /// `OpenPressContext.pressId`).
    public let pressId: UUID
    /// When this phase was recorded.
    public let timestamp: Date
    /// Where the press originated, e.g. "intent", "app", "queued". A short,
    /// non-secret label -- never free-form user input.
    public let source: String
    /// The process that recorded this phase, e.g.
    /// `Bundle.main.bundleIdentifier ?? "?"`. `GateOpenerCore` itself never
    /// reads `Bundle.main` (it has no UIKit/Foundation-bundle dependency
    /// beyond what's already imported) -- callers pass this in.
    public let process: String
    /// The app version string, e.g. "0.1.9 (11)". Caller-supplied, same
    /// convention as `VideoDiagnosticsStage.sessionStart(appVersion:...)`.
    public let appVersion: String
    /// This phase of the press's lifecycle.
    public let phase: OpenPressPhase
    /// Milliseconds elapsed since the press started (i.e. since the
    /// `pressStartedAt` passed to whatever emitted `.started`). Always 0 for
    /// `.started` itself.
    public let elapsedMilliseconds: Int

    public init(
        pressId: UUID,
        timestamp: Date,
        source: String,
        process: String,
        appVersion: String,
        phase: OpenPressPhase,
        elapsedMilliseconds: Int
    ) {
        self.pressId = pressId
        self.timestamp = timestamp
        self.source = source
        self.process = process
        self.appVersion = appVersion
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

// MARK: - OpenJournalEntry

/// The on-disk union of every record kind `OpenAttemptJournal` can persist,
/// one per JSON line.
///
/// FORMAT: encodes with a top-level `"kind"` discriminator alongside the
/// wrapped record's own fields (NOT the compiler-synthesized nested-payload
/// shape) -- `{"kind":"press", <OpenPressRecord fields>}` or
/// `{"kind":"attempt", <OpenAttemptRecord fields>}` -- so the line stays a
/// single flat, human-readable JSON object.
///
/// LEGACY DECODE: a JSONL line with no top-level `"kind"` key predates this
/// type (every line `OpenAttemptJournal` ever wrote before this bead) and is
/// decoded as `.attempt(OpenAttemptRecord)` with `pressId == nil` --
/// `OpenAttemptJournal`'s line-parsing tries `OpenJournalEntry` first, and
/// only falls back to a bare legacy `OpenAttemptRecord` decode when that
/// fails to find a `"kind"` key at all (see `OpenAttemptJournal.parseLines`).
public enum OpenJournalEntry: Codable, Sendable, Equatable {
    case press(OpenPressRecord)
    case attempt(OpenAttemptRecord)

    private enum Kind: String, Codable {
        case press
        case attempt
    }

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let singleValue = try decoder.singleValueContainer()
        switch kind {
        case .press:
            self = .press(try singleValue.decode(OpenPressRecord.self))
        case .attempt:
            self = .attempt(try singleValue.decode(OpenAttemptRecord.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .press(let record):
            try record.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.press, forKey: .kind)
        case .attempt(let record):
            try record.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.attempt, forKey: .kind)
        }
    }
}

// MARK: - OpenPressContext

/// Carries the current press's id across the `async` call graph from
/// `OpenGateFlow.run` down into `GateClient.open`'s per-attempt
/// `report(...)`, WITHOUT changing either type's public parameter list for
/// the value itself (no `pressId` parameter threaded through `GateClient
/// .open`).
///
/// `@TaskLocal` values set via `withValue(_:operation:)` before
/// `TaskGroup.addTask` propagate into that child task -- i.e. a value bound
/// on the parent task before `addTask` is inherited by the child, even
/// though the child is a structurally separate `Task`. This is exercised
/// directly by
/// `OpenGateFlowTests.attemptRecordsProducedInsideOpenCarryTheFlowsPressId` (and
/// unit-tested for propagation itself by
/// `GateClientTests`/`OpenGateFlowTests`'s TaskLocal-focused cases).
public enum OpenPressContext {
    @TaskLocal public static var pressId: UUID?
}
