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
