import Foundation

// MARK: - Errors

/// Additional errors surfaced by `GateClient`, layered on top of `ComelitError`.
///
/// These live here (rather than in `ComelitAPI.swift`, which is owned by an
/// earlier bead) because they are specific to the gate-discovery/open flow:
/// `.noEndpointsFound` means the discovery call itself returned nothing
/// (e.g. an unprovisioned account), while `.noGateFound` means discovery
/// succeeded but none of the returned endpoints survived `candidateGates`
/// filtering (e.g. only cameras/doorbells, no controllable lock). The UI
/// needs to tell these apart from a generic network/server failure so it can
/// show "no gate found" rather than a scary error.
public enum GateClientError: Error, Equatable, Sendable {
    case noEndpointsFound
    case noGateFound
}

// MARK: - Sanitized error descriptions for persistence

/// Produces a short, bounded description of a token-resolution failure that
/// is SAFE to persist to disk (via `OpenAttemptJournal`/`OpenAttemptRecord`).
///
/// This exists because `String(describing: error)` on a `ComelitError` can
/// include up to 300 characters of the raw auth-server response body (see
/// `ComelitError.server(status:body:)`), which may contain sensitive detail
/// from the server. This helper NEVER includes response bodies, server
/// messages, usernames, or tokens -- only the error's case name and, for
/// `.server`, the HTTP status code.
public enum TokenFailureDescription {
    /// See the enum's doc comment for the sanitization rules.
    public static func sanitizedTokenFailureDescription(_ error: Error) -> String {
        if let comelitError = error as? ComelitError {
            switch comelitError {
            case .invalidCredentials:
                return "invalidCredentials"
            case .network:
                return "network"
            case .server(let status, _):
                return "server(\(status))"
            case .decoding:
                return "decoding"
            case .missingRefreshToken:
                return "missingRefreshToken"
            }
        }
        if let tokenManagerError = error as? TokenManagerError {
            switch tokenManagerError {
            case .notConfigured:
                return "notConfigured"
            }
        }
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .saveFailed:
                return "saveFailed"
            case .loadFailed:
                return "loadFailed"
            case .deleteFailed:
                return "deleteFailed"
            case .decodeFailed:
                return "decodeFailed"
            }
        }
        return String(describing: type(of: error))
    }
}

// MARK: - Endpoint model

/// A single device/endpoint returned by the Comelit discovery API.
///
/// The real payload includes several fields this type does not model
/// (`manufacturerName`, `description`, `options`, ...); decoding tolerates
/// and ignores unknown fields since `Endpoint` only declares the ones it
/// needs. `capabilities` and `displayCategories` default to `[]` if absent
/// from the payload, since some endpoint shapes may omit them.
public struct Endpoint: Codable, Equatable, Sendable, Identifiable {
    public let endpointId: String
    public let friendlyName: String
    public let capabilities: [String]
    public let displayCategories: [String]

    public var id: String { endpointId }

    public init(
        endpointId: String,
        friendlyName: String,
        capabilities: [String] = [],
        displayCategories: [String] = []
    ) {
        self.endpointId = endpointId
        self.friendlyName = friendlyName
        self.capabilities = capabilities
        self.displayCategories = displayCategories
    }

    private enum CodingKeys: String, CodingKey {
        case endpointId
        case friendlyName
        case capabilities
        case displayCategories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpointId = try container.decode(String.self, forKey: .endpointId)
        friendlyName = try container.decode(String.self, forKey: .friendlyName)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        displayCategories = try container.decodeIfPresent([String].self, forKey: .displayCategories) ?? []
    }
}

// MARK: - Retry configuration

/// Controls `GateClient.open`'s retry/backoff behavior. Injectable so tests
/// can run with zero real delay.
public struct RetryPolicy: Sendable {
    /// Total number of attempts (including the first try). Must be >= 1.
    public let maxAttempts: Int
    /// Base delay for exponential backoff, e.g. attempt 1 waits ~baseDelay,
    /// attempt 2 waits ~baseDelay*2, etc. (before jitter).
    public let baseDelay: Duration
    /// Upper bound on total wall-clock time spent sleeping between attempts.
    /// Once the cumulative planned delay would exceed this, no further
    /// retries are attempted (this bounds worst-case latency for a human
    /// standing at the gate).
    ///
    /// Shrunk from 6s to 2s when per-attempt timeouts became escalating
    /// (`requestTimeouts`, see below) rather than a flat 3s: the retry
    /// budget is now dominated by the *requests themselves* (up to 16s for
    /// the default 3/5/8s schedule), so the sleep budget only needs to be
    /// large enough to avoid hammering a struggling server back-to-back, not
    /// to bound overall wait time on its own.
    public let maxTotalDelay: Duration
    /// Per-attempt timeout (`URLRequest.timeoutInterval`) schedule, applied
    /// to EACH individual HTTP attempt: attempt `k` (1-based) uses
    /// `requestTimeouts[min(k - 1, requestTimeouts.count - 1)]`, so once the
    /// array is exhausted the LAST value is reused for any further attempts
    /// (`maxAttempts > requestTimeouts.count`), and with `maxAttempts == 1`
    /// only the first value is ever used. Must be non-empty (enforced by a
    /// precondition in `init`).
    ///
    /// Without a per-attempt timeout, a hanging server relies entirely on
    /// `URLSessionConfiguration`'s default request timeout (60s), so 3
    /// attempts could block for up to ~180s even though `maxTotalDelay`
    /// bounds only time spent SLEEPING between attempts, not time spent
    /// waiting on an individual request.
    ///
    /// Escalating rather than flat: measured live Comelit-cloud latency puts
    /// the healthy median around 1.7s, so a flat 3s timeout leaves only
    /// ~1.1s of margin -- on weak Wi-Fi/cellular, all 3 attempts can time
    /// out even though a slightly longer wait would have succeeded (see
    /// memory `comelit-cloud-latency-and-timeout-budget`). Retrying is SAFE
    /// here (the actuator is momentary and the official app itself sends
    /// the open command twice), so this escalates the PER-ATTEMPT budget
    /// instead of adding more attempts: default `[3s, 5s, 8s]`. The first
    /// attempt's timeout must NEVER be shrunk below 3s (per that same
    /// memory) -- callers needing a different bound can inject their own
    /// array, but should preserve that floor.
    ///
    /// Worst case for the default policy (`maxAttempts == 3`,
    /// `requestTimeouts == [3s, 5s, 8s]`, `maxTotalDelay == 2s`): `3 + 5 + 8
    /// = 16s` of requests, plus at most `2s` of bounded backoff sleep between
    /// attempts, for a `<= 18s` total -- comfortably under
    /// `OpenGateFlow`'s 25s extension-lifetime deadline.
    public let requestTimeouts: [Duration]
    /// Injectable sleep function so tests never actually sleep.
    public let sleep: @Sendable (Duration) async throws -> Void

    /// Primary initializer: escalating per-attempt timeout schedule.
    ///
    /// - Precondition: `requestTimeouts` must be non-empty.
    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(400),
        maxTotalDelay: Duration = .seconds(2),
        requestTimeouts: [Duration] = [.seconds(3), .seconds(5), .seconds(8)],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        precondition(!requestTimeouts.isEmpty, "RetryPolicy.requestTimeouts must be non-empty")
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxTotalDelay = maxTotalDelay
        self.requestTimeouts = requestTimeouts
        self.sleep = sleep
    }

    /// Source-compatibility initializer for existing call sites that pass a
    /// single, uniform `requestTimeout: Duration` (pre-dating the escalating
    /// `requestTimeouts` schedule). Equivalent to passing `[requestTimeout]`
    /// -- i.e. every attempt uses the same timeout.
    public init(
        maxAttempts: Int = 3,
        baseDelay: Duration = .milliseconds(400),
        maxTotalDelay: Duration = .seconds(2),
        requestTimeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(
            maxAttempts: maxAttempts,
            baseDelay: baseDelay,
            maxTotalDelay: maxTotalDelay,
            requestTimeouts: [requestTimeout],
            sleep: sleep
        )
    }

    /// The default, real-world policy: 3 attempts, ~400ms exponential
    /// backoff with jitter, escalating 3s/5s/8s per-attempt timeouts, real
    /// `Task.sleep`.
    public static let `default` = RetryPolicy()

    /// A policy for tests: same attempt/backoff/timeout shape as `.default`,
    /// but `sleep` is a no-op so tests complete instantly.
    public static func noDelay(maxAttempts: Int = 3) -> RetryPolicy {
        RetryPolicy(
            maxAttempts: maxAttempts,
            baseDelay: .milliseconds(400),
            maxTotalDelay: .seconds(2),
            requestTimeouts: [.seconds(3), .seconds(5), .seconds(8)],
            sleep: { _ in }
        )
    }
}

// MARK: - GateClient

/// Client for the Comelit device-discovery and gate-open API calls.
///
/// This is the ONLY type in this codebase that issues the command that
/// physically opens a gate (`open(endpointId:)`). Correctness here has
/// real-world consequences: sending the wrong endpoint, or `{"value":false}`,
/// or failing to retry a transient 500, all have a human standing at a gate
/// that doesn't open (or, worse, a "gate opened" button that quietly does
/// nothing because it hit the inert Generic Actuator).
public struct GateClient: Sendable {
    /// The real Generic Actuator endpoint id suffix. It advertises
    /// `PowerController` and returns HTTP 202 on `open`, exactly like a real
    /// gate lock -- but it is NOT wired to anything physical. If this were
    /// ever offered as "the gate", pressing it would silently do nothing.
    /// MUST be excluded from `candidateGates` regardless of what
    /// `displayCategories` says, as one of two independent discriminators
    /// (the other being the `VIP_ACTUATOR` display-category exclusion below).
    ///
    /// Deliberately matched narrowly (only this exact, known-bad actuator id,
    /// matched robustly -- see `endpointIdMatchesGenericActuator` below) and
    /// NOT as a broad `SBIO*` family match: a sibling id such as
    /// `SBIO0299.0` is a different, untested device, and blanket-excluding
    /// the whole `SBIO*` family risks hiding a legitimate gate we've never
    /// seen. Siblings that are genuinely inert actuators are expected to be
    /// caught by the `VIP_ACTUATOR` displayCategories exclusion instead,
    /// since untested actuators legitimately carry that category.
    public static let genericActuatorEndpointIdSuffix = "VIP#OD#SBIO0255.0"

    /// The known-bad actuator id component, in isolation (i.e. without the
    /// `VIP#OD#` prefix), used for the robust component-wise match in
    /// `endpointIdMatchesGenericActuator`.
    private static let genericActuatorIdComponent = "SBIO0255.0"

    /// The displayCategory the real Generic Actuator reports (as opposed to
    /// `LOCK_GENERIC`, which real gates report). This is the SECOND,
    /// independent discriminator promised by the doc comment on
    /// `candidateGates`: any endpoint advertising this category is excluded
    /// outright, regardless of its id. This also catches untested `SBIO*`
    /// siblings of the known-bad actuator (see
    /// `genericActuatorEndpointIdSuffix` above) without requiring us to
    /// blanket-exclude the whole id family.
    private static let vipActuatorDisplayCategory = "VIP_ACTUATOR"

    private static let powerControllerCapability = "PowerController"
    private static let lockGenericDisplayCategory = "LOCK_GENERIC"

    /// Robustly test whether `endpointId` refers to the known-bad Generic
    /// Actuator (`...VIP#OD#SBIO0255.0`).
    ///
    /// Deliberately NOT a plain `hasSuffix` check, which is case-sensitive,
    /// intolerant of incidental whitespace, and matches ANYWHERE the exact
    /// tail bytes occur (including mid-string, e.g. as a substring of a
    /// longer trailing component). Instead this:
    ///  - trims whitespace from the id before comparing,
    ///  - compares case-insensitively,
    ///  - splits on `_` (the endpointId component separator -- see
    ///    `parseAptId`) and requires the LAST component to case-insensitively
    ///    equal `VIP#OD#SBIO0255.0` exactly, rather than merely ending with
    ///    it -- so `..._VIP#OD#SBIO0255.0_extra` does NOT match, and a
    ///    sibling like `..._VIP#OD#SBIO0299.0` does NOT match.
    private static func endpointIdMatchesGenericActuator(_ endpointId: String) -> Bool {
        let trimmed = endpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastComponent = trimmed.components(separatedBy: "_").last else { return false }
        return lastComponent.caseInsensitiveCompare(genericActuatorEndpointIdSuffix) == .orderedSame
    }

    private let session: URLSession
    private let tokenManager: TokenManager
    private let baseURL: String
    private let retryPolicy: RetryPolicy
    /// Optional observer notified once per `open(endpointId:)` attempt. `nil`
    /// by default, in which case `open` behaves exactly as if the observer
    /// did not exist (see `OpenAttemptObserving`'s doc comment).
    private let attemptObserver: (any OpenAttemptObserving)?
    /// Injectable clock, used only to timestamp/measure attempts reported to
    /// `attemptObserver`. Defaults to the real `Date()`/`ContinuousClock` so
    /// production behavior is unchanged; tests can inject a fixed sequence.
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        tokenManager: TokenManager,
        baseURL: String = ComelitAPI.baseURL,
        retryPolicy: RetryPolicy = .default,
        attemptObserver: (any OpenAttemptObserving)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.tokenManager = tokenManager
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy
        self.attemptObserver = attemptObserver
        self.now = now
    }

    // MARK: - Discovery

    /// Discover the endpoints (devices) available to the account.
    ///
    /// `aptId` is OPTIONAL (live-verified against the real API): when `nil`,
    /// the `aptId` query parameter is omitted entirely rather than sent
    /// empty.
    ///
    /// Throws `GateClientError.noEndpointsFound` if the response is a valid,
    /// successfully-decoded empty array (e.g. an unprovisioned account) --
    /// distinct from a network/server/decoding failure.
    public func discover(aptId: String? = nil) async throws -> [Endpoint] {
        guard var components = URLComponents(string: "\(baseURL)/servicerest/devicecom/endpoints/discovery") else {
            throw ComelitError.network("invalid URL for endpoints/discovery")
        }
        if let aptId {
            components.queryItems = [URLQueryItem(name: "aptId", value: aptId)]
        }
        guard let url = components.url else {
            throw ComelitError.network("invalid URL for endpoints/discovery")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(ComelitAPI.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let token = try await tokenManager.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComelitError.network("non-HTTP response from endpoints/discovery")
        }

        guard httpResponse.statusCode == 200 else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw ComelitError.server(status: httpResponse.statusCode, body: String(bodyString.prefix(300)))
        }

        let endpoints: [Endpoint]
        do {
            endpoints = try JSONDecoder().decode([Endpoint].self, from: data)
        } catch {
            throw ComelitError.decoding("failed to decode endpoints/discovery response: \(error)")
        }

        guard !endpoints.isEmpty else {
            throw GateClientError.noEndpointsFound
        }

        return endpoints
    }

    // MARK: - aptId parsing

    /// Parse the apartment id embedded in an endpointId of the form
    /// `_DA_<aptId>_<deviceUuid>-00001_VIP#OD#SB100001.1`.
    ///
    /// Splits on `_` and returns the component at index 2. Returns `nil` if
    /// the id does not have at least that many `_`-separated components
    /// (i.e. does not match the expected shape).
    public static func parseAptId(fromEndpointId endpointId: String) -> String? {
        let parts = endpointId.components(separatedBy: "_")
        guard parts.count > 2 else { return nil }
        let aptId = parts[2]
        guard !aptId.isEmpty else { return nil }
        return aptId
    }

    // MARK: - Candidate gate filtering (SAFETY-CRITICAL)

    /// Filter `endpoints` down to those that are plausible physical gates.
    ///
    /// SAFETY-CRITICAL: this determines what the UI is allowed to present as
    /// "the gate". THREE filtering steps are applied, in order:
    ///
    ///  1. Keep only endpoints whose `capabilities` contain `PowerController`.
    ///  2. Exclude any endpoint whose id robustly matches
    ///     `genericActuatorEndpointIdSuffix` (the known-bad, inert Generic
    ///     Actuator id), via `endpointIdMatchesGenericActuator` -- see that
    ///     function's doc comment for exactly what "robustly" means
    ///     (case-insensitive, whitespace-trimmed, matched as the final
    ///     `_`-separated id component rather than a bare string tail).
    ///  3. Exclude any endpoint whose `displayCategories` contains
    ///     `VIP_ACTUATOR` (`vipActuatorDisplayCategory`), regardless of its
    ///     id. This is the SECOND independent discriminator: it also catches
    ///     untested `SBIO*` siblings of the known-bad actuator (see the doc
    ///     comment on `genericActuatorEndpointIdSuffix`) without requiring a
    ///     blanket id-family exclusion that could hide a real, untested gate.
    ///
    /// Among what remains, endpoints with `LOCK_GENERIC` in their
    /// `displayCategories` are ranked first (real gates report this
    /// category).
    public static func candidateGates(from endpoints: [Endpoint]) -> [Endpoint] {
        let powerControllers = endpoints.filter { $0.capabilities.contains(powerControllerCapability) }

        let excludingGenericActuatorId = powerControllers.filter {
            !endpointIdMatchesGenericActuator($0.endpointId)
        }

        let excludingVipActuatorCategory = excludingGenericActuatorId.filter {
            !$0.displayCategories.contains(vipActuatorDisplayCategory)
        }

        let (lockGeneric, others) = excludingVipActuatorCategory.reduce(into: ([Endpoint](), [Endpoint]())) { acc, endpoint in
            if endpoint.displayCategories.contains(lockGenericDisplayCategory) {
                acc.0.append(endpoint)
            } else {
                acc.1.append(endpoint)
            }
        }

        return lockGeneric + others
    }

    // MARK: - Open (THE COMMAND THAT OPENS THE GATE)

    /// Send the "open" command to the given endpoint.
    ///
    /// PUT `{baseURL}/servicerest/devicecom/endpoint/{percent-encoded
    /// endpointId}/power` with body `{"value":true}`.
    ///
    /// NEVER sends `{"value":false}` -- the live API 500s on it, and there is
    /// deliberately no close/toggle entry point in this type at all.
    ///
    /// Retries per `retryPolicy`:
    ///  - Retries on HTTP 5xx, HTTP 429, and transport (network) errors --
    ///    including transport errors that arrive already wrapped as
    ///    `ComelitError.network(...)` by `performRequest`. Retryability is
    ///    decided in exactly ONE place (`isRetryable(_:)` below), classifying
    ///    the *error value*, not the catch clause it happened to be caught
    ///    in -- catch-order-dependent control flow previously caused a bug
    ///    where transport failures were silently non-retried.
    ///  - Does NOT retry other 4xx (e.g. 400, 403).
    ///  - On HTTP 401, calls `tokenManager.invalidate()` and retries exactly
    ///    once with a freshly-resolved token (this one retry is in addition
    ///    to, and does not consume, the normal 5xx/429/transport retry
    ///    budget's "success" path -- but it is still bounded by
    ///    `maxAttempts` overall so a persistently-401ing server cannot loop
    ///    forever).
    ///  - `.invalidCredentials` (raised by `tokenManager.accessToken()`
    ///    itself, e.g. because stored credentials are wrong) is NEVER
    ///    retried -- retrying a wrong password against the live service is
    ///    pointless and could contribute to account lockout. This is
    ///    enforced structurally: `.invalidCredentials` can only originate
    ///    from the `tokenManager.accessToken()` call below, which throws
    ///    immediately, entirely outside the retry classification path used
    ///    for the HTTP request itself.
    ///
    /// Succeeds (returns normally) on HTTP 202 (the documented success code)
    /// or HTTP 200 (accepted defensively).
    public func open(endpointId: String) async throws {
        guard let encodedId = Self.percentEncodeEndpointId(endpointId) else {
            throw ComelitError.network("failed to percent-encode endpointId")
        }
        guard let url = URL(string: "\(baseURL)/servicerest/devicecom/endpoint/\(encodedId)/power") else {
            throw ComelitError.network("invalid URL for endpoint/power")
        }

        let bodyData = Data(#"{"value":true}"#.utf8)

        var didInvalidateFor401 = false
        var totalDelay: Duration = .zero
        var lastError: Error = ComelitError.network("open: no attempts were made")

        for attempt in 1...retryPolicy.maxAttempts {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(ComelitAPI.userAgent, forHTTPHeaderField: "user-agent")
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.httpBody = bodyData
            // Bound each individual attempt's wait -- see
            // `RetryPolicy.requestTimeouts` doc comment for why this is
            // necessary on top of `maxTotalDelay`. Attempt `k` (1-based)
            // uses `requestTimeouts[min(k - 1, count - 1)]`, so once the
            // schedule is exhausted the last value is reused for any
            // further attempts.
            let timeoutForAttempt = retryPolicy.requestTimeouts[min(attempt - 1, retryPolicy.requestTimeouts.count - 1)]
            request.timeoutInterval = TimeInterval(timeoutForAttempt.components.seconds)
                + Double(timeoutForAttempt.components.attoseconds) / 1e18

            do {
                let token = try await tokenManager.accessToken()
                request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            } catch {
                // .invalidCredentials (or any other token-resolution failure)
                // is never retried here: there is no point retrying an open
                // call when we cannot even get a token, and retrying wrong
                // credentials against the live service is actively harmful.
                // This throw is unconditional and never consults
                // `isRetryable(_:)` -- token-resolution failures are not
                // eligible for retry at all, regardless of their type.
                //
                // Reported to `attemptObserver` as a single `.tokenFailure`
                // record, `willRetry: false`, BEFORE the token failure is
                // rethrown -- this happens before any HTTP request for this
                // attempt, so there is no request duration to measure
                // (`elapsedMilliseconds` is 0).
                report(
                    attempt: attempt,
                    startedAt: now(),
                    outcome: .tokenFailure(description: TokenFailureDescription.sanitizedTokenFailureDescription(error)),
                    willRetry: false
                )
                throw error
            }

            // Timestamp captured just before issuing this attempt's HTTP
            // request, so `elapsedMilliseconds` measures only the request
            // itself -- never any backoff sleep, which happens after the
            // observer has already been notified for this attempt.
            let attemptStartedAt = now()

            // Outcome of ONE HTTP attempt, classified into exactly one of:
            // success, a thrown 401 (needs its own one-shot handling above
            // ordinary retry), or an error to hand to `isRetryable(_:)`.
            //
            // `performRequestPreservingRawError` (rather than
            // `performRequest`, used by `discover`) is used here so the
            // ORIGINAL thrown error -- before it is wrapped into
            // `ComelitError.network(String)`, which erases its type -- is
            // still available to classify as a `URLError` for the
            // `.transportFailure(urlErrorCode:)` observer outcome below.
            do {
                let (data, response) = try await performRequestPreservingRawError(request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    let error = ComelitError.network("non-HTTP response from endpoint/power")
                    lastError = error
                    let willRetry = !(attempt == retryPolicy.maxAttempts || !isRetryable(error))
                    report(
                        attempt: attempt,
                        startedAt: attemptStartedAt,
                        outcome: .transportFailure(urlErrorCode: -1),
                        willRetry: willRetry
                    )
                    if !willRetry { throw error }
                    try await backoffAndAdvance(attempt: attempt, totalDelay: &totalDelay)
                    continue
                }

                if httpResponse.statusCode == 202 || httpResponse.statusCode == 200 {
                    report(
                        attempt: attempt,
                        startedAt: attemptStartedAt,
                        outcome: .success(status: httpResponse.statusCode),
                        willRetry: false
                    )
                    return
                }

                let bodyString = String(data: data, encoding: .utf8) ?? ""

                if httpResponse.statusCode == 401 {
                    let error = ComelitError.server(status: 401, body: String(bodyString.prefix(300)))
                    lastError = error
                    if !didInvalidateFor401 {
                        didInvalidateFor401 = true
                        await tokenManager.invalidate()
                        let willRetry = attempt != retryPolicy.maxAttempts
                        report(
                            attempt: attempt,
                            startedAt: attemptStartedAt,
                            outcome: .httpFailure(status: 401),
                            willRetry: willRetry
                        )
                        if !willRetry { throw error }
                        try await backoffAndAdvance(attempt: attempt, totalDelay: &totalDelay)
                        continue
                    } else {
                        // Already retried once for a 401 with a fresh token
                        // and still got 401: do not loop forever.
                        report(
                            attempt: attempt,
                            startedAt: attemptStartedAt,
                            outcome: .httpFailure(status: 401),
                            willRetry: false
                        )
                        throw error
                    }
                }

                let error = ComelitError.server(status: httpResponse.statusCode, body: String(bodyString.prefix(300)))
                lastError = error

                guard isRetryable(error) else {
                    // Non-retryable 4xx (e.g. 400, 403): fail fast.
                    report(
                        attempt: attempt,
                        startedAt: attemptStartedAt,
                        outcome: .httpFailure(status: httpResponse.statusCode),
                        willRetry: false
                    )
                    throw error
                }

                let willRetry = attempt != retryPolicy.maxAttempts
                report(
                    attempt: attempt,
                    startedAt: attemptStartedAt,
                    outcome: .httpFailure(status: httpResponse.statusCode),
                    willRetry: willRetry
                )
                if !willRetry { throw error }
                try await backoffAndAdvance(attempt: attempt, totalDelay: &totalDelay)
                continue
            } catch {
                // Cancellation is never reported and always rethrown as-is
                // -- an observer record for a cancelled attempt would be
                // misleading (no outcome was actually decided), and `open`
                // must still propagate cancellation exactly as before this
                // bead's change.
                if error is CancellationError { throw error }

                // Reached for: transport errors thrown by
                // `performRequestPreservingRawError` (a `RawTransportError`
                // wrapping the original error -- see below), and the
                // non-HTTP-response / non-retryable-status / 401 cases above
                // that `throw` out of the inner `do` once their own attempt
                // budget or retryability check says to stop (already
                // reported to `attemptObserver` at their own throw site
                // above, where the concrete HTTP status was known -- see
                // `RawTransportError` handling below for why they are not
                // reported again here).
                //
                // A single call to `isRetryable(_:)` decides retry vs.
                // rethrow for EVERYTHING that lands here, so a transport
                // error is never accidentally treated as unconditionally
                // fatal the way `catch let error as ComelitError { throw
                // error }` previously did (that clause matched
                // `ComelitError.network(...)` BEFORE the transport-specific
                // handling could run, since `performRequest` had already
                // wrapped the error).
                let classified: Error
                if let rawTransportError = error as? RawTransportError {
                    // A genuine transport failure from
                    // `performRequestPreservingRawError`, not yet reported to
                    // `attemptObserver` -- report it here, with the real
                    // `URLError.code.rawValue` when available.
                    let underlyingURLErrorCode = (rawTransportError.underlying as? URLError)?.code.rawValue
                    classified = ComelitError.network(
                        rawTransportError.underlying.localizedDescription,
                        code: underlyingURLErrorCode
                    )
                    lastError = classified
                    let willRetry = !(attempt == retryPolicy.maxAttempts || !isRetryable(classified))
                    // `urlErrorCode` here is the `.transportFailure` observer
                    // outcome's own `-1`-sentinel-on-unknown convention
                    // (unrelated to and unchanged by `ComelitError.network`'s
                    // new `code:`, which is `nil`, not `-1`, when unknown).
                    let urlErrorCode = underlyingURLErrorCode ?? -1
                    report(
                        attempt: attempt,
                        startedAt: attemptStartedAt,
                        outcome: .transportFailure(urlErrorCode: urlErrorCode),
                        willRetry: willRetry
                    )
                } else if let comelitError = error as? ComelitError {
                    // Already reported above, at its own throw site.
                    classified = comelitError
                    lastError = classified
                } else {
                    // Should not normally happen (every error reaching here
                    // is either a `RawTransportError` or a `ComelitError`
                    // thrown above), but handle defensively: treat unknown
                    // thrown errors as transport-like and retryable, and
                    // report them (never previously reported, since they are
                    // neither of the recognized cases above).
                    let fallback = ComelitError.network(error.localizedDescription)
                    classified = fallback
                    lastError = classified
                    let willRetry = !(attempt == retryPolicy.maxAttempts || !isRetryable(fallback))
                    report(
                        attempt: attempt,
                        startedAt: attemptStartedAt,
                        outcome: .transportFailure(urlErrorCode: -1),
                        willRetry: willRetry
                    )
                }

                if attempt == retryPolicy.maxAttempts || !isRetryable(classified) {
                    throw classified
                }
                try await backoffAndAdvance(attempt: attempt, totalDelay: &totalDelay)
                continue
            }
        }

        throw lastError
    }

    /// Single source of truth for "should this error be retried". Anything
    /// that decides retry-vs-fail for the HTTP request loop in `open` must
    /// go through this function rather than re-deriving retryability from
    /// catch-clause type or ordering (that fragility is what caused transport
    /// errors to never retry previously).
    ///
    ///  - `.network` (transport failures, non-HTTP responses): retryable.
    ///  - `.server` with status >= 500 or == 429: retryable.
    ///  - `.server` with any other status (e.g. 400, 403): NOT retryable.
    ///  - `.invalidCredentials`, `.decoding`, `.missingRefreshToken`: NOT
    ///    retryable (none of these are expected to originate from the HTTP
    ///    attempt itself, but are classified defensively as non-retryable
    ///    rather than silently retried).
    private func isRetryable(_ error: Error) -> Bool {
        guard let comelitError = error as? ComelitError else {
            // Unknown error type reaching here: treat as non-retryable by
            // default (conservative), though in practice `performRequest`
            // always wraps into `.network` before this is consulted.
            return false
        }
        switch comelitError {
        case .network:
            return true
        case .server(let status, _):
            return status >= 500 || status == 429
        case .invalidCredentials, .decoding, .missingRefreshToken:
            return false
        }
    }

    /// Sleep for the exponential-backoff delay for `attempt`, with jitter,
    /// bounded so cumulative delay never exceeds `retryPolicy.maxTotalDelay`.
    /// Advances `totalDelay` by the amount actually slept.
    private func backoffAndAdvance(attempt: Int, totalDelay: inout Duration) async throws {
        let multiplier = 1 << (attempt - 1) // 1, 2, 4, ...
        let base = retryPolicy.baseDelay * Double(multiplier)
        let jitterFraction = Double.random(in: 0.0...0.3)
        let delayWithJitter = base * (1.0 + jitterFraction)

        let remaining = retryPolicy.maxTotalDelay - totalDelay
        guard remaining > .zero else { return }

        let boundedDelay = min(delayWithJitter, remaining)
        guard boundedDelay > .zero else { return }

        try await retryPolicy.sleep(boundedDelay)
        totalDelay += boundedDelay
    }

    // MARK: - Shared plumbing

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ComelitError.network(error.localizedDescription, code: (error as? URLError)?.code.rawValue)
        }
    }

    /// Like `performRequest`, but on transport failure throws
    /// `RawTransportError` (preserving the original, un-stringified error)
    /// instead of immediately wrapping into `ComelitError.network(String)`.
    ///
    /// Used only by `open`, which needs the original error's type (to
    /// extract `URLError.code.rawValue` for the `.transportFailure`
    /// observer outcome reported to `attemptObserver`) before it is
    /// classified. `discover` and everything else keep using
    /// `performRequest`, which is unaffected by this addition.
    private func performRequestPreservingRawError(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw RawTransportError(underlying: error)
        }
    }

    /// Wraps a transport-layer error exactly as thrown by `URLSession`,
    /// before any stringification/classification -- used only internally by
    /// `open` (via `performRequestPreservingRawError`) so the original
    /// error's type (typically `URLError`) is still inspectable when
    /// building the `.transportFailure(urlErrorCode:)` observer outcome.
    private struct RawTransportError: Error {
        let underlying: Error
    }

    /// Notify `attemptObserver` (if any) of one attempt's outcome. A no-op
    /// when `attemptObserver` is `nil`. Synchronous and non-throwing, and
    /// never called while holding any lock, per `OpenAttemptObserving`'s
    /// contract.
    private func report(
        attempt: Int,
        startedAt: Date,
        outcome: OpenAttemptOutcome,
        willRetry: Bool
    ) {
        guard let attemptObserver else { return }
        let elapsedSeconds = now().timeIntervalSince(startedAt)
        // Never negative even if `now()` is a test-injected clock that isn't
        // monotonic; never a fractional millisecond lost to rounding-down
        // for typical (sub-second) request durations.
        let elapsedMilliseconds = Int(max(0, elapsedSeconds) * 1000)
        attemptObserver.record(
            OpenAttemptRecord(
                timestamp: startedAt,
                attempt: attempt,
                maxAttempts: retryPolicy.maxAttempts,
                outcome: outcome,
                elapsedMilliseconds: elapsedMilliseconds,
                willRetry: willRetry
            )
        )
    }

    /// Percent-encode an endpointId for use as a single URL path component.
    /// The id contains `#`, which (if left unencoded) is interpreted as a
    /// URL fragment delimiter and silently truncates the path -- the request
    /// would then hit the wrong endpoint. `.urlPathAllowed` still permits
    /// `#` (and a few other reserved characters unsafe here), so this
    /// removes it and other path-component-unsafe characters explicitly.
    static func percentEncodeEndpointId(_ endpointId: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#/?")
        return endpointId.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
