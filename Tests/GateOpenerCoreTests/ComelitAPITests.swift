import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - Stub URLProtocol

/// A `URLProtocol` that serves canned responses for offline testing, keyed by
/// request path suffix. No live network calls are made.
///
/// Because swift-testing runs `@Test` functions concurrently by default, stub
/// registrations are scoped per test via a unique `X-Test-Run-Id` header
/// injected by `makeStubbedSession(runId:)`, rather than shared global state —
/// this avoids cross-test races where one test's handler matches another
/// test's concurrently in-flight request.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: Data
        let responseURL: URL?

        init(status: Int, headers: [String: String] = [:], body: Data, responseURL: URL? = nil) {
            self.status = status
            self.headers = headers
            self.body = body
            self.responseURL = responseURL
        }
    }

    private static let lock = NSLock()
    /// Per-run (test-scoped) ordered list of (path-suffix matcher, stub) pairs.
    nonisolated(unsafe) private static var handlersByRun: [String: [(String, Stub)]] = [:]

    static let runIdHeader = "X-Test-Run-Id"

    static func addHandler(runId: String, pathSuffix: String, stub: Stub) {
        lock.lock()
        handlersByRun[runId, default: []].append((pathSuffix, stub))
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let runId = request.value(forHTTPHeaderField: StubURLProtocol.runIdHeader) ?? ""
        let path = request.url?.path ?? ""

        StubURLProtocol.lock.lock()
        let match = StubURLProtocol.handlersByRun[runId]?.first(where: { path.hasSuffix($0.0) })
        StubURLProtocol.lock.unlock()

        guard let (_, stub) = match else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let responseURL = stub.responseURL ?? request.url!
        let httpResponse = HTTPURLResponse(
            url: responseURL,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Build a `URLSession` that routes through `StubURLProtocol` and tags every
/// outgoing request with a unique run id, so stub registrations for this test
/// never collide with those of a concurrently running test.
func makeStubbedSession(runId: String = UUID().uuidString) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    config.httpAdditionalHeaders = [StubURLProtocol.runIdHeader: runId]
    return URLSession(configuration: config)
}

// MARK: - Recording URLProtocol (gateopener-41m.4)

/// A `URLProtocol` that both serves a canned response per path suffix AND
/// records every matching request's `timeoutInterval`/count -- unlike
/// `StubURLProtocol`, which serves responses but records nothing. Used by
/// the step-1/step-2 timeout+retry acceptance tests, which need to inspect
/// what actually went out on the wire across MULTIPLE requests to
/// DIFFERENT endpoints in a single `login()` call (`/o-auth-2/auth` and
/// `/o-auth-2/token`), which `SequencedStubURLProtocol` (in
/// `GateClientTests.swift`, scripted per single-endpoint call sequence)
/// does not model either.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let runIdHeader = "X-Recording-Test-Run-Id"

    /// Per-suffix queue of canned (status, body) responses: each matching
    /// request consumes the next entry in order, and once exhausted the
    /// LAST entry is reused for any further requests (mirrors
    /// `RequestScript`'s behavior in GateClientTests.swift) -- this is what
    /// lets a test script "500 then 200" for a retry.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusesByRun: [String: [String: [(Int, Data)]]] = [:]
    nonisolated(unsafe) private static var statusIndexByRun: [String: [String: Int]] = [:]
    nonisolated(unsafe) private static var timeoutsByRun: [String: [TimeInterval]] = [:]
    nonisolated(unsafe) private static var countsByRun: [String: [String: Int]] = [:]

    /// Register (append) the next canned status/body for requests whose
    /// path has the given suffix, for this run. Calling this more than
    /// once for the same suffix queues additional responses, served in
    /// registration order. Defaults to 200 + empty body for any path not
    /// explicitly configured.
    static func setStatus(runId: String, pathSuffix: String, status: Int, body: Data) {
        lock.lock()
        statusesByRun[runId, default: [:]][pathSuffix, default: []].append((status, body))
        lock.unlock()
    }

    static func timeoutIntervals(runId: String) -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return timeoutsByRun[runId] ?? []
    }

    static func requestCount(runId: String, pathSuffix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return countsByRun[runId]?[pathSuffix] ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// The path suffixes this test double understands `requestCount(_:)`
    /// might be asked about: `/o-auth-2/auth` and `/o-auth-2/token`. A
    /// request's count is attributed to whichever of these its path ends
    /// with (a request always matches exactly one).
    private static let knownSuffixes = ["/o-auth-2/auth", "/o-auth-2/token"]

    override func startLoading() {
        let runId = request.value(forHTTPHeaderField: RecordingURLProtocol.runIdHeader) ?? ""
        let path = request.url?.path ?? ""

        RecordingURLProtocol.lock.lock()
        RecordingURLProtocol.timeoutsByRun[runId, default: []].append(request.timeoutInterval)

        let matchedSuffix = RecordingURLProtocol.knownSuffixes.first(where: { path.hasSuffix($0) })
        if let matchedSuffix {
            RecordingURLProtocol.countsByRun[runId, default: [:]][matchedSuffix, default: 0] += 1
        }

        var status = 200
        var body = Data()
        if let matchedSuffix, let queue = RecordingURLProtocol.statusesByRun[runId]?[matchedSuffix], !queue.isEmpty {
            let index = RecordingURLProtocol.statusIndexByRun[runId]?[matchedSuffix] ?? 0
            let entry = queue[min(index, queue.count - 1)]
            status = entry.0
            body = entry.1
            RecordingURLProtocol.statusIndexByRun[runId, default: [:]][matchedSuffix] = index + 1
        }
        RecordingURLProtocol.lock.unlock()

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Build a `URLSession` routed through `RecordingURLProtocol`, tagged
    /// with a unique run id so concurrently-running tests never collide.
    static func makeSession(runId: String = UUID().uuidString) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        config.httpAdditionalHeaders = [RecordingURLProtocol.runIdHeader: runId]
        return URLSession(configuration: config)
    }
}

// MARK: - PKCE

@Test func pkceChallengeMatchesKnownVector() {
    // Independently computed with:
    // python3 -c "import hashlib, base64; v='12345678-1234-5678-1234-567812345678'; \
    //   print(base64.urlsafe_b64encode(hashlib.sha256(v.encode('ascii')).digest()).decode('ascii').rstrip('='))"
    let verifier = "12345678-1234-5678-1234-567812345678"
    let expectedChallenge = "dJQI-KnaeFQSx5vN76rLkrBZL6qWSAbi8hKbG8R2IU0"
    #expect(PKCE.challenge(forVerifier: verifier) == expectedChallenge)
}

@Test func pkceGeneratedVerifierIsLowercaseUUID() {
    let (verifier, challenge) = PKCE.generate()
    #expect(UUID(uuidString: verifier) != nil)
    #expect(verifier == verifier.lowercased())
    #expect(!challenge.contains("+"))
    #expect(!challenge.contains("/"))
    #expect(!challenge.contains("="))
}

// MARK: - TokenSet expiry

@Test func tokenSetNotExpiredWithComfortableMargin() {
    let tokens = TokenSet(
        accessToken: "abc",
        refreshToken: nil,
        expiresIn: 600,
        tokenType: "bearer",
        receivedAt: Date()
    )
    #expect(!tokens.isExpired(skew: 300))
}

@Test func tokenSetExpiredWithinSkewWindow() {
    let tokens = TokenSet(
        accessToken: "abc",
        refreshToken: nil,
        expiresIn: 60,
        tokenType: "bearer",
        receivedAt: Date()
    )
    #expect(tokens.isExpired(skew: 300))
}

@Test func tokenSetDefaultsExpiresInWhenAbsent() {
    let receivedAt = Date()
    let tokens = TokenSet(
        accessToken: "abc",
        refreshToken: nil,
        expiresIn: nil,
        tokenType: "bearer",
        receivedAt: receivedAt
    )
    let expectedExpiry = receivedAt.addingTimeInterval(TokenSet.defaultExpiresIn)
    #expect(abs(tokens.expiresAt.timeIntervalSince(expectedExpiry)) < 1)
}

// MARK: - Login: happy path

@Test func loginTwoStepExchangeProducesTokenSet() async throws {
    let runId = UUID().uuidString
    let authBody: [String: Any] = ["location": "https://app.comelitgroup.com/oauth_redirect/comelit?code=abc123&state=xyz"]
    let authData = try JSONSerialization.data(withJSONObject: authBody)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/auth", stub: .init(status: 200, body: authData))

    let tokenBody: [String: Any] = [
        "access_token": "the-access-token",
        "refresh_token": "the-refresh-token",
        "token_type": "bearer",
        "expires_in": 3600,
    ]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/token", stub: .init(status: 200, body: tokenData))

    let api = ComelitAPI(session: makeStubbedSession(runId: runId))
    let tokens = try await api.login(username: "user@example.com", password: "hunter2")

    #expect(tokens.accessToken == "the-access-token")
    #expect(tokens.refreshToken == "the-refresh-token")
    #expect(tokens.tokenType == "bearer")
    #expect(!tokens.isExpired(skew: 300))
}

@Test func loginExtractsCodeFromLocationHeader() async throws {
    let runId = UUID().uuidString
    StubURLProtocol.addHandler(
        runId: runId,
        pathSuffix: "/o-auth-2/auth",
        stub: .init(
            status: 200,
            headers: ["Location": "https://app.comelitgroup.com/oauth_redirect/comelit?code=from-header&state=xyz"],
            body: Data("{}".utf8)
        )
    )
    let tokenBody: [String: Any] = ["access_token": "tok-from-header", "expires_in": 3600]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/token", stub: .init(status: 200, body: tokenData))

    let api = ComelitAPI(session: makeStubbedSession(runId: runId))
    let tokens = try await api.login(username: "user@example.com", password: "hunter2")

    #expect(tokens.accessToken == "tok-from-header")
}

@Test func loginExtractsCodeFromJSONBodyField() async throws {
    let runId = UUID().uuidString
    let authBody: [String: Any] = ["code": "from-json-field"]
    let authData = try JSONSerialization.data(withJSONObject: authBody)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/auth", stub: .init(status: 200, body: authData))

    let tokenBody: [String: Any] = ["access_token": "tok-from-json", "expires_in": 3600]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/token", stub: .init(status: 200, body: tokenData))

    let api = ComelitAPI(session: makeStubbedSession(runId: runId))
    let tokens = try await api.login(username: "user@example.com", password: "hunter2")

    #expect(tokens.accessToken == "tok-from-json")
}

// MARK: - Login: error mapping

@Test func loginWrongCredentialsMapsToInvalidCredentials() async throws {
    let runId = UUID().uuidString
    let body = Data(#"{"error":"wrong_username_or_password"}"#.utf8)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/auth", stub: .init(status: 401, body: body))

    let api = ComelitAPI(session: makeStubbedSession(runId: runId))
    await #expect(throws: ComelitError.invalidCredentials) {
        _ = try await api.login(username: "user@example.com", password: "wrong")
    }
}

@Test func loginServerErrorMapsToServerError() async throws {
    let runId = UUID().uuidString
    let body = Data("internal error".utf8)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/auth", stub: .init(status: 500, body: body))

    let api = ComelitAPI(session: makeStubbedSession(runId: runId))
    do {
        _ = try await api.login(username: "user@example.com", password: "pw")
        Issue.record("expected ComelitError.server to be thrown")
    } catch ComelitError.server(let status, _) {
        #expect(status == 500)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

// MARK: - Refresh

@Test func refreshWithStubbedSuccessReturnsNewTokenSet() async throws {
    let runId = UUID().uuidString
    let tokenBody: [String: Any] = [
        "access_token": "refreshed-access-token",
        "refresh_token": "refreshed-refresh-token",
        "expires_in": 7200,
        "token_type": "bearer",
    ]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
    StubURLProtocol.addHandler(runId: runId, pathSuffix: "/o-auth-2/token", stub: .init(status: 200, body: tokenData))

    let api = ComelitAPI(session: makeStubbedSession(runId: runId))
    let original = TokenSet(
        accessToken: "old-token",
        refreshToken: "old-refresh-token",
        expiresIn: 10,
        tokenType: "bearer"
    )
    let refreshed = try await api.refresh(original)

    #expect(refreshed.accessToken == "refreshed-access-token")
    #expect(refreshed.refreshToken == "refreshed-refresh-token")
}

@Test func refreshWithNoRefreshTokenThrowsMissingRefreshToken() async throws {
    let api = ComelitAPI(session: makeStubbedSession())
    let tokensWithoutRefresh = TokenSet(
        accessToken: "old-token",
        refreshToken: nil,
        expiresIn: 10,
        tokenType: "bearer"
    )
    await #expect(throws: ComelitError.missingRefreshToken) {
        _ = try await api.refresh(tokensWithoutRefresh)
    }
}

// MARK: - gateopener-41m.4: per-request timeout

/// Acceptance test for step 1: the default `requestTimeout` (8s) is applied
/// to the `/o-auth-2/token` refresh request's `URLRequest.timeoutInterval`.
@Test func refreshAppliesDefaultEightSecondTimeout() async throws {
    let script = RequestScript(statuses: [200])
    let session = makeSequencedSession(script: script)
    let api = ComelitAPI(session: session)

    let original = TokenSet(accessToken: "old", refreshToken: "old-refresh", expiresIn: 10, tokenType: "bearer")
    // Body need not decode successfully for this test -- it only asserts on
    // the request's timeoutInterval, not the (irrelevant, and in this case
    // absent) response body. A 200 with an empty body throws `.decoding`,
    // which is expected and ignored here.
    _ = try? await api.refresh(original)

    #expect(script.timeoutIntervals == [8])
}

/// Acceptance test for step 1: BOTH `/o-auth-2/auth` and `/o-auth-2/token`
/// requests issued by `login` carry the same `requestTimeout`.
@Test func loginAppliesTimeoutToBothAuthAndTokenRequests() async throws {
    let runId = UUID().uuidString
    let authBody: [String: Any] = ["location": "https://app.comelitgroup.com/oauth_redirect/comelit?code=abc123&state=xyz"]
    let authData = try JSONSerialization.data(withJSONObject: authBody)
    RecordingURLProtocol.setStatus(runId: runId, pathSuffix: "/o-auth-2/auth", status: 200, body: authData)

    let tokenBody: [String: Any] = ["access_token": "tok", "expires_in": 3600]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
    RecordingURLProtocol.setStatus(runId: runId, pathSuffix: "/o-auth-2/token", status: 200, body: tokenData)

    let recordingSession = RecordingURLProtocol.makeSession(runId: runId)
    let api = ComelitAPI(session: recordingSession)
    _ = try await api.login(username: "user@example.com", password: "hunter2")

    let timeouts = RecordingURLProtocol.timeoutIntervals(runId: runId)
    #expect(timeouts.count == 2)
    #expect(timeouts.allSatisfy { $0 == 8 })
}

/// Acceptance test for step 1: a custom `requestTimeout` passed to `init` is
/// honoured on the refresh request.
@Test func refreshHonoursCustomRequestTimeout() async throws {
    let script = RequestScript(statuses: [200])
    let session = makeSequencedSession(script: script)
    let api = ComelitAPI(session: session, requestTimeout: .seconds(4))

    let original = TokenSet(accessToken: "old", refreshToken: "old-refresh", expiresIn: 10, tokenType: "bearer")
    _ = try? await api.refresh(original)

    #expect(script.timeoutIntervals == [4])
}

// MARK: - gateopener-41m.4: single retry on refresh_token / authorization_code

/// Acceptance test for step 2: refresh returns 500 then 200 -> succeeds
/// with exactly 2 requests.
@Test func refresh500ThenSuccessRetriesOnceAndSucceeds() async throws {
    let tokenBody: [String: Any] = ["access_token": "refreshed", "expires_in": 3600]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
    let script = RequestScript(responses: [
        ScriptedResponse(status: 500, body: Data("server error".utf8)),
        ScriptedResponse(status: 200, body: tokenData),
    ])
    let session = makeSequencedSession(script: script)
    let api = ComelitAPI(session: session, sleep: { _ in })

    let original = TokenSet(accessToken: "old", refreshToken: "old-refresh", expiresIn: 10, tokenType: "bearer")
    let refreshed = try await api.refresh(original)

    #expect(refreshed.accessToken == "refreshed")
    #expect(script.requestCount == 2)
}

/// Acceptance test for step 2: refresh 400 -> exactly 1 request (a 4xx that
/// is not 429 is never retried).
@Test func refresh400DoesNotRetry() async throws {
    let script = RequestScript(statuses: [400])
    let session = makeSequencedSession(script: script)
    let api = ComelitAPI(session: session, sleep: { _ in })

    let original = TokenSet(accessToken: "old", refreshToken: "old-refresh", expiresIn: 10, tokenType: "bearer")
    do {
        _ = try await api.refresh(original)
        Issue.record("expected ComelitError.server to be thrown")
    } catch ComelitError.server(let status, _) {
        #expect(status == 400)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(script.requestCount == 1)
}

/// Acceptance test for step 2: two consecutive transport failures ->
/// throws `.network` after exactly 2 requests (the single retry is
/// exhausted, not retried again).
@Test func refreshTransportErrorTwiceThrowsNetworkAfterExactlyTwoRequests() async throws {
    let script = RequestScript(responses: [
        .transportError(.networkConnectionLost),
        .transportError(.networkConnectionLost),
    ])
    let session = makeSequencedSession(script: script)
    let api = ComelitAPI(session: session, sleep: { _ in })

    let original = TokenSet(accessToken: "old", refreshToken: "old-refresh", expiresIn: 10, tokenType: "bearer")
    do {
        _ = try await api.refresh(original)
        Issue.record("expected ComelitError.network to be thrown")
    } catch ComelitError.network {
        // expected
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(script.requestCount == 2)
}

/// Acceptance test for step 2: the retry delay is routed through the
/// injectable sleep closure, invoked exactly once with 500ms.
@Test func refreshRetrySleepsExactlyOnceWithFiveHundredMilliseconds() async throws {
    let tokenBody: [String: Any] = ["access_token": "refreshed", "expires_in": 3600]
    let tokenData = try JSONSerialization.data(withJSONObject: tokenBody)
    let script = RequestScript(responses: [
        ScriptedResponse(status: 500, body: Data("server error".utf8)),
        ScriptedResponse(status: 200, body: tokenData),
    ])
    let session = makeSequencedSession(script: script)
    let recorder = SleepRecorder()
    let api = ComelitAPI(session: session, sleep: { recorder.record($0) })

    let original = TokenSet(accessToken: "old", refreshToken: "old-refresh", expiresIn: 10, tokenType: "bearer")
    _ = try await api.refresh(original)

    #expect(recorder.durations == [.milliseconds(500)])
}

/// Acceptance test for step 2: a `wrong_username_or_password` body on the
/// refresh request maps to `.invalidCredentials` and is NEVER retried,
/// even though the stub would return 200 on a second call if one happened.
@Test func refreshWrongCredentialsBodyNeverRetries() async throws {
    let script = RequestScript(responses: [
        ScriptedResponse(status: 400, body: Data(#"{"error":"wrong_username_or_password"}"#.utf8)),
        ScriptedResponse(status: 200, body: Data(#"{"access_token":"should-not-be-reached"}"#.utf8)),
    ])
    let session = makeSequencedSession(script: script)
    let api = ComelitAPI(session: session, sleep: { _ in })

    let original = TokenSet(accessToken: "old", refreshToken: "old-refresh", expiresIn: 10, tokenType: "bearer")
    await #expect(throws: ComelitError.invalidCredentials) {
        _ = try await api.refresh(original)
    }

    #expect(script.requestCount == 1)
}

/// Acceptance test for step 2: the `authorization_code` token exchange
/// (step 2 of `login`) also gets exactly one retry on a 500 -- proves the
/// retry applies to BOTH grant types sharing `performTokenRequest`, not
/// just `refresh_token`. `/o-auth-2/auth` (step 1) always succeeds on its
/// single request; only the `/o-auth-2/token` exchange is scripted to fail
/// once then succeed.
@Test func loginTokenExchange500ThenSuccessRetriesOnceAndSucceeds() async throws {
    let runId = UUID().uuidString
    let authBody: [String: Any] = ["location": "https://app.comelitgroup.com/oauth_redirect/comelit?code=abc123&state=xyz"]
    let authData = try JSONSerialization.data(withJSONObject: authBody)
    RecordingURLProtocol.setStatus(runId: runId, pathSuffix: "/o-auth-2/auth", status: 200, body: authData)
    RecordingURLProtocol.setStatus(runId: runId, pathSuffix: "/o-auth-2/token", status: 500, body: Data("server error".utf8))
    RecordingURLProtocol.setStatus(
        runId: runId,
        pathSuffix: "/o-auth-2/token",
        status: 200,
        body: Data(#"{"access_token":"tok-after-retry","expires_in":3600}"#.utf8)
    )

    let session = RecordingURLProtocol.makeSession(runId: runId)
    let api = ComelitAPI(session: session, sleep: { _ in })
    let tokens = try await api.login(username: "user@example.com", password: "hunter2")

    #expect(tokens.accessToken == "tok-after-retry")
    #expect(RecordingURLProtocol.requestCount(runId: runId, pathSuffix: "/o-auth-2/token") == 2)
}

/// Acceptance test for step 2: the credential-submitting `/o-auth-2/auth`
/// POST is NEVER retried, even on a 500 -- `login` fails after exactly 1
/// request to `/o-auth-2/auth`.
@Test func loginAuthStep500NeverRetries() async throws {
    let runId = UUID().uuidString
    let recordingSession = RecordingURLProtocol.makeSession(runId: runId)
    RecordingURLProtocol.setStatus(runId: runId, pathSuffix: "/o-auth-2/auth", status: 500, body: Data("boom".utf8))

    let api = ComelitAPI(session: recordingSession, sleep: { _ in })
    do {
        _ = try await api.login(username: "user@example.com", password: "pw")
        Issue.record("expected ComelitError.server to be thrown")
    } catch ComelitError.server(let status, _) {
        #expect(status == 500)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(RecordingURLProtocol.requestCount(runId: runId, pathSuffix: "/o-auth-2/auth") == 1)
}
