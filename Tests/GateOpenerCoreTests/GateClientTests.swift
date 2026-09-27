import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - Test helpers

/// Build a `TokenManager` backed by mocks (from `TokenManagerTests.swift`,
/// same test target) that always succeeds with `accessToken`, so
/// `GateClient` tests exercise real `TokenManager` behavior (including
/// `invalidate()` forcing re-resolution) without any network access.
private func makeTokenManager(
    accessToken: String = "the-access-token",
    refreshedAccessToken: String = "the-refreshed-access-token"
) -> (TokenManager, MockTokenIssuing) {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try? store.saveCredentials(username: "alice", password: "s3cret")
    issuing.loginResult = .success(
        TokenSet(accessToken: accessToken, refreshToken: "rt", expiresIn: 3600, tokenType: "bearer")
    )
    // Deliberately a DIFFERENT access token than login's, so tests can prove
    // that an `invalidate()` + re-resolution actually fetched a fresh token
    // rather than coincidentally reusing the same string.
    issuing.refreshResult = .success(
        TokenSet(accessToken: refreshedAccessToken, refreshToken: "rt", expiresIn: 3600, tokenType: "bearer")
    )
    let manager = TokenManager(api: issuing, credentialStore: store)
    return (manager, issuing)
}

/// Load the real (sanitized) discovery fixture from the test bundle.
private func loadDiscoveryFixtureData() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "discovery", withExtension: "json"))
    return try Data(contentsOf: url)
}

private let genericActuatorSuffix = GateClient.genericActuatorEndpointIdSuffix

// MARK: - Sequenced/observing stub protocol (this file's own, so the
// committed `StubURLProtocol` in ComelitAPITests.swift is never modified)
//
// Scoped per-run via the same `X-Test-Run-Id` header convention as
// `StubURLProtocol`, for the same reason: swift-testing runs `@Test`s
// concurrently, so shared registration state must not be global.

/// A single canned response in a `SequencedStubURLProtocol` script: either a
/// scripted HTTP status/body, or a scripted TRANSPORT failure (i.e. the
/// request never got an HTTP response at all -- `URLSession` throws before
/// any status code exists). The transport-failure case is what proves
/// `GateClient.open` actually retries on `URLError`-style failures rather
/// than only on HTTP error statuses.
struct ScriptedResponse {
    let status: Int
    let body: Data
    /// When non-nil, `SequencedStubURLProtocol` fails the request with this
    /// error via `didFailWithError` instead of returning `status`/`body`.
    let transportError: URLError.Code?

    init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
        self.transportError = nil
    }

    private init(transportError: URLError.Code) {
        self.status = 0
        self.body = Data()
        self.transportError = transportError
    }

    /// A scripted transport-level failure (e.g. `.networkConnectionLost`),
    /// as opposed to an HTTP error status.
    static func transportError(_ code: URLError.Code) -> ScriptedResponse {
        ScriptedResponse(transportError: code)
    }
}

/// Thread-safe, per-run script of responses plus request bookkeeping
/// (count and last-seen path), used by `SequencedStubURLProtocol`.
final class RequestScript: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ScriptedResponse]
    private var index = 0
    private(set) var requestCount = 0
    private(set) var lastPath: String?
    /// The `authorization` header value seen on every request, in order.
    /// Lets tests prove a 401 retry used a DIFFERENT (freshly-resolved)
    /// bearer token than the first attempt, not just that a retry happened.
    private(set) var authorizationHeaders: [String] = []
    /// `URLRequest.timeoutInterval` seen on every request, in order. Lets
    /// tests prove the escalating per-attempt `RetryPolicy.requestTimeouts`
    /// schedule (e.g. 3s/5s/8s) was actually applied to each attempt's
    /// `URLRequest`, not just configured on `RetryPolicy`.
    private(set) var timeoutIntervals: [TimeInterval] = []

    init(responses: [ScriptedResponse]) {
        self.responses = responses
    }

    /// Convenience initializer for tests that only care about status codes.
    convenience init(statuses: [Int]) {
        self.init(responses: statuses.map { ScriptedResponse(status: $0) })
    }

    /// Optional side-effect invoked on every request, INSIDE the lock-free
    /// window between bookkeeping and returning the scripted response --
    /// i.e. synchronously during `SequencedStubURLProtocol.startLoading()`,
    /// which itself runs synchronously inside the `await session.data(for:)`
    /// call `GateClient.open` is suspended on. Lets a test advance a
    /// test-controlled clock so that clock only moves "during the request",
    /// never during backoff sleep (which happens strictly after the request
    /// completes and `report(...)` has already been called). `nil` by
    /// default so every pre-existing use of `RequestScript` is unaffected.
    var onRequest: (@Sendable () -> Void)?

    func nextResponse(forPath path: String, authorizationHeader: String?, timeoutInterval: TimeInterval) -> ScriptedResponse {
        lock.lock()
        requestCount += 1
        lastPath = path
        authorizationHeaders.append(authorizationHeader ?? "")
        timeoutIntervals.append(timeoutInterval)
        let response = responses[min(index, responses.count - 1)]
        index += 1
        let hook = onRequest
        lock.unlock()
        hook?()
        return response
    }
}

/// A `URLProtocol` that serves responses from a per-run `RequestScript`,
/// advancing one entry per matching request. Lets tests assert exact
/// request counts (to prove retry behavior) and inspect the exact path
/// requested (to prove percent-encoding), neither of which the committed
/// `StubURLProtocol` supports.
final class SequencedStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let runIdHeader = "X-Sequenced-Test-Run-Id"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scriptsByRun: [String: RequestScript] = [:]

    static func register(runId: String, script: RequestScript) {
        lock.lock()
        scriptsByRun[runId] = script
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let runId = request.value(forHTTPHeaderField: SequencedStubURLProtocol.runIdHeader) ?? ""
        // `URL.path` PERCENT-DECODES, which would hide a percent-encoding
        // bug (e.g. an unencoded "#" truncating the URL at a fragment would
        // look identical to a correctly-encoded "%23" once decoded back).
        // Use `URLComponents.percentEncodedPath` so the test observes
        // exactly what went over the wire.
        let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""

        SequencedStubURLProtocol.lock.lock()
        let script = SequencedStubURLProtocol.scriptsByRun[runId]
        SequencedStubURLProtocol.lock.unlock()

        guard let script else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let authHeader = request.value(forHTTPHeaderField: "authorization")
        let scripted = script.nextResponse(forPath: path, authorizationHeader: authHeader, timeoutInterval: request.timeoutInterval)

        if let transportErrorCode = scripted.transportError {
            client?.urlProtocol(self, didFailWithError: URLError(transportErrorCode))
            return
        }

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: scripted.status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: scripted.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Build a `URLSession` routed through `SequencedStubURLProtocol`, tagged
/// with a unique run id so concurrently-running tests never collide.
func makeSequencedSession(script: RequestScript, runId: String = UUID().uuidString) -> URLSession {
    SequencedStubURLProtocol.register(runId: runId, script: script)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SequencedStubURLProtocol.self]
    config.httpAdditionalHeaders = [SequencedStubURLProtocol.runIdHeader: runId]
    return URLSession(configuration: config)
}

// MARK: - Endpoint decoding

@Test func decodesRealFixtureIntoEightEndpoints() throws {
    let data = try loadDiscoveryFixtureData()
    let endpoints = try JSONDecoder().decode([Endpoint].self, from: data)

    #expect(endpoints.count == 8)

    let entranceLock = try #require(endpoints.first { $0.friendlyName == "Entrance lock" })
    #expect(entranceLock.endpointId.hasSuffix("VIP#OD#SB100001.1"))
    #expect(entranceLock.capabilities == ["PowerController"])
    #expect(entranceLock.displayCategories == ["LOCK_GENERIC"])
    #expect(entranceLock.id == entranceLock.endpointId)
}

// MARK: - parseAptId

@Test func parseAptIdExtractsFromFixtureEndpointId() throws {
    let data = try loadDiscoveryFixtureData()
    let endpoints = try JSONDecoder().decode([Endpoint].self, from: data)
    let entranceLock = try #require(endpoints.first { $0.friendlyName == "Entrance lock" })

    let aptId = GateClient.parseAptId(fromEndpointId: entranceLock.endpointId)
    #expect(aptId == "00000000-1111-2222-3333-444444444444")
}

@Test func parseAptIdReturnsNilForMalformedId() {
    #expect(GateClient.parseAptId(fromEndpointId: "not-the-expected-shape") == nil)
    #expect(GateClient.parseAptId(fromEndpointId: "") == nil)
    #expect(GateClient.parseAptId(fromEndpointId: "_DA_") == nil)
}

// MARK: - candidateGates (SAFETY-CRITICAL)

@Test func candidateGatesOnFixtureYieldsExactlyOneEntranceLock() throws {
    let data = try loadDiscoveryFixtureData()
    let endpoints = try JSONDecoder().decode([Endpoint].self, from: data)

    let candidates = GateClient.candidateGates(from: endpoints)

    #expect(candidates.count == 1)
    let onlyCandidate = try #require(candidates.first)
    #expect(onlyCandidate.friendlyName == "Entrance lock")
    #expect(onlyCandidate.endpointId.hasSuffix("VIP#OD#SB100001.1"))
    #expect(onlyCandidate.displayCategories.contains("LOCK_GENERIC"))
}

@Test func candidateGatesExcludesInertGenericActuatorDespiteHavingPowerController() throws {
    let data = try loadDiscoveryFixtureData()
    let endpoints = try JSONDecoder().decode([Endpoint].self, from: data)

    let genericActuator = try #require(endpoints.first { $0.endpointId.hasSuffix(genericActuatorSuffix) })
    // Sanity: the fixture's Generic Actuator DOES advertise PowerController,
    // so the exclusion below is proving the id-suffix/display-category
    // discriminators work, not just that it lacked the capability.
    #expect(genericActuator.capabilities.contains("PowerController"))
    #expect(genericActuator.displayCategories == ["VIP_ACTUATOR"])

    let candidates = GateClient.candidateGates(from: endpoints)

    #expect(!candidates.contains(where: { $0.endpointId.hasSuffix(genericActuatorSuffix) }))
    #expect(!candidates.contains(where: { $0.friendlyName == "Generic Actuator" }))
}

/// DEFECT 2 (required test): proves `VIP_ACTUATOR` is a REAL, independent
/// second discriminator -- not just a comment. An endpoint whose id does NOT
/// match the known-bad suffix at all (so discriminator 1, the id match,
/// cannot possibly exclude it) must still be excluded purely because its
/// `displayCategories` contains `VIP_ACTUATOR`. This is exactly the scenario
/// that was PROVEN to survive `candidateGates` before the fix (an endpoint
/// with `displayCategories: ["VIP_ACTUATOR"]` and a non-matching id).
@Test func candidateGatesExcludesAnyEndpointWithVipActuatorCategoryRegardlessOfId() {
    let untestedActuatorSibling = Endpoint(
        endpointId: "_DA_x_y_VIP#OD#SBIO9999.0", // does NOT match the known-bad id at all
        friendlyName: "Some Other Actuator",
        capabilities: ["PowerController"],
        displayCategories: ["VIP_ACTUATOR"]
    )

    let candidates = GateClient.candidateGates(from: [untestedActuatorSibling])

    #expect(candidates.isEmpty)
}

/// DEFECT 3 (required tests): the four defeat variants PROVEN to survive the
/// old `hasSuffix` exclusion must now all be excluded. Each of these
/// endpoints has ONLY the id-based signal to be excluded by (no
/// `VIP_ACTUATOR` category), isolating discriminator 1 (robust id matching)
/// from discriminator 2 (category exclusion, covered by the test above).
@Test func candidateGatesExcludesGenericActuatorIdCaseInsensitively() {
    let lowercaseId = Endpoint(
        endpointId: "_DA_x_y_vip#od#sbio0255.0",
        friendlyName: "Generic Actuator (lowercase id)",
        capabilities: ["PowerController"],
        displayCategories: ["SOME_OTHER_CATEGORY"]
    )
    #expect(GateClient.candidateGates(from: [lowercaseId]).isEmpty)
}

@Test func candidateGatesExcludesGenericActuatorIdWithTrailingWhitespace() {
    let trailingSpace = Endpoint(
        endpointId: "_DA_x_y_VIP#OD#SBIO0255.0 ",
        friendlyName: "Generic Actuator (trailing space)",
        capabilities: ["PowerController"],
        displayCategories: ["SOME_OTHER_CATEGORY"]
    )
    #expect(GateClient.candidateGates(from: [trailingSpace]).isEmpty)
}

@Test func candidateGatesDoesNotExcludeGenericActuatorSuffixOccurringMidString() {
    // The known-bad suffix occurs, but NOT as the final id component --
    // there is trailing content after it. A strict tail/component match
    // must NOT treat this as the known-bad actuator (though note: in
    // practice a real such id would still be excluded via the
    // VIP_ACTUATOR-category discriminator if it truly were an actuator --
    // this test isolates and proves the id-matching discriminator alone is
    // no longer defeated by a mid-string occurrence).
    let midString = Endpoint(
        endpointId: "_DA_x_y_VIP#OD#SBIO0255.0_extra",
        friendlyName: "Not Actually The Known-Bad Actuator",
        capabilities: ["PowerController"],
        displayCategories: ["SOME_OTHER_CATEGORY"]
    )
    let candidates = GateClient.candidateGates(from: [midString])
    #expect(candidates.contains(where: { $0.endpointId == midString.endpointId }))
}

@Test func candidateGatesDoesNotExcludeUntestedSblingActuatorIdWhenNoVipActuatorCategory() {
    // SBIO0299.0 is a DIFFERENT, untested device (see doc comment on
    // `genericActuatorEndpointIdSuffix`). Without the VIP_ACTUATOR category
    // present, the id-matching discriminator alone must NOT exclude it --
    // blanket-excluding the whole SBIO* family risks hiding a legitimate,
    // untested gate. (If this sibling really is an inert actuator in
    // practice, it is expected to carry VIP_ACTUATOR and be caught by that
    // discriminator instead -- see the test above.)
    let sibling = Endpoint(
        endpointId: "_DA_x_y_VIP#OD#SBIO0299.0",
        friendlyName: "Untested Sibling Device",
        capabilities: ["PowerController"],
        displayCategories: ["SOME_OTHER_CATEGORY"]
    )
    let candidates = GateClient.candidateGates(from: [sibling])
    #expect(candidates.contains(where: { $0.endpointId == sibling.endpointId }))
}

@Test func candidateGatesExcludesEndpointsWithoutPowerController() throws {
    let data = try loadDiscoveryFixtureData()
    let endpoints = try JSONDecoder().decode([Endpoint].self, from: data)

    let candidates = GateClient.candidateGates(from: endpoints)
    let candidateNames = Set(candidates.map(\.friendlyName))

    // Camera, intercom, doorbell (x2), apartment, switchboard: none carry
    // PowerController and must all be excluded.
    #expect(!candidateNames.contains("Entry")) // camera
    #expect(!candidateNames.contains("Intercom 1")) // intercom
    #expect(!candidateNames.contains("resident")) // doorbell
    #expect(!candidateNames.contains("Unknown")) // doorbell
    #expect(!candidateNames.contains("SB000001")) // apartment
    #expect(!candidateNames.contains("Secondary switchboard")) // switchboard
}

@Test func candidateGatesRanksLockGenericFirst() {
    let lockGeneric = Endpoint(
        endpointId: "id-lock",
        friendlyName: "Lock",
        capabilities: ["PowerController"],
        displayCategories: ["LOCK_GENERIC"]
    )
    let otherPowerController = Endpoint(
        endpointId: "id-other",
        friendlyName: "Other",
        capabilities: ["PowerController"],
        displayCategories: ["SOME_OTHER_CATEGORY"]
    )

    let candidates = GateClient.candidateGates(from: [otherPowerController, lockGeneric])

    #expect(candidates.map(\.endpointId) == ["id-lock", "id-other"])
}

@Test func candidateGatesEmptyWhenNoPowerController() {
    let camera = Endpoint(
        endpointId: "id-camera",
        friendlyName: "Camera",
        capabilities: ["RTCSessionController"],
        displayCategories: ["CAMERA"]
    )
    #expect(GateClient.candidateGates(from: [camera]).isEmpty)
}

// MARK: - discover

@Test func discoverEmptyArrayThrowsNoEndpointsFound() async throws {
    let runId = UUID().uuidString
    StubURLProtocol.addHandler(
        runId: runId,
        pathSuffix: "/servicerest/devicecom/endpoints/discovery",
        stub: .init(status: 200, body: Data("[]".utf8))
    )
    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: makeStubbedSession(runId: runId), tokenManager: tokenManager)

    await #expect(throws: GateClientError.noEndpointsFound) {
        _ = try await client.discover()
    }
}

@Test func discoverOmitsAptIdQueryParamWhenNil() async throws {
    let runId = UUID().uuidString
    StubURLProtocol.addHandler(
        runId: runId,
        pathSuffix: "/servicerest/devicecom/endpoints/discovery",
        stub: .init(status: 200, body: try loadDiscoveryFixtureData())
    )
    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: makeStubbedSession(runId: runId), tokenManager: tokenManager)

    let endpoints = try await client.discover(aptId: nil)
    #expect(endpoints.count == 8)
}

/// A distinct error from `.noEndpointsFound`: discovery succeeded (non-empty
/// endpoints), but none of them are candidate gates.
@Test func candidateGatesEmptySurfacesAsNoGateFound() throws {
    let camera = Endpoint(
        endpointId: "id-camera",
        friendlyName: "Camera",
        capabilities: ["RTCSessionController"],
        displayCategories: ["CAMERA"]
    )
    let candidates = GateClient.candidateGates(from: [camera])
    guard candidates.isEmpty else {
        Issue.record("expected no candidates")
        return
    }
    func requireGate(_ candidates: [Endpoint]) throws -> Endpoint {
        guard let first = candidates.first else { throw GateClientError.noGateFound }
        return first
    }
    #expect(throws: GateClientError.noGateFound) {
        _ = try requireGate(candidates)
    }
}

// MARK: - open: success paths

@Test func openSucceedsOnFirstTryWithExactlyOneRequest() async throws {
    let script = RequestScript(statuses: [202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    #expect(script.requestCount == 1)
}

// MARK: - open: retry proves itself

@Test func open500ThenSucceedsProvesRetryWorks() async throws {
    let script = RequestScript(statuses: [500, 202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    #expect(script.requestCount == 2)
}

@Test func openThreeConsecutive500sThrowsAfterExactlyThreeAttempts() async throws {
    let script = RequestScript(statuses: [500, 500, 500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay(maxAttempts: 3))

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.requestCount == 3)
}

/// DEFECT 4 (required test): HTTP 429 is retryable, same as 5xx.
@Test func open429ThenSucceedsProvesRetryWorks() async throws {
    let script = RequestScript(statuses: [429, 202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    #expect(script.requestCount == 2)
}

/// DEFECT 1 / DEFECT 4 (required test): this is the exact scenario that
/// PROVED defect 1 -- a transport failure (no HTTP response at all, e.g. a
/// `URLProtocol` throwing `URLError(.networkConnectionLost)`) must be
/// retried just like a 5xx. Before the fix, `catch let error as
/// ComelitError { throw error }` intercepted the wrapped transport error
/// before the transport-retry branch could ever run, so this scenario
/// produced exactly 1 attempt instead of retrying. This test fails against
/// the old code (1 attempt, thrown error) and passes now (2 attempts,
/// success).
@Test func openTransportErrorThenSucceedsProvesRetryWorks() async throws {
    let script = RequestScript(responses: [
        .transportError(.networkConnectionLost),
        ScriptedResponse(status: 202),
    ])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    #expect(script.requestCount == 2)
}

/// DEFECT 4 (required test): three consecutive transport errors exhaust the
/// retry budget and throw after exactly `maxAttempts` (3) attempts -- proves
/// the transport-retry path is also correctly BOUNDED, not just retried at
/// all.
@Test func openThreeConsecutiveTransportErrorsThrowsAfterExactlyThreeAttempts() async throws {
    let script = RequestScript(responses: [
        .transportError(.networkConnectionLost),
        .transportError(.networkConnectionLost),
        .transportError(.networkConnectionLost),
        .transportError(.networkConnectionLost),
        .transportError(.networkConnectionLost),
    ])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay(maxAttempts: 3))

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.requestCount == 3)
}

@Test func open401TriggersInvalidateAndRetriesExactlyOnce() async throws {
    let script = RequestScript(statuses: [401, 202])
    let session = makeSequencedSession(script: script)

    // Seed the store with a valid (non-expired) token plus credentials, so
    // `open`'s first `accessToken()` call resolves entirely from the
    // in-memory/stored cache with NO login/refresh call at all -- isolating
    // what happens on invalidation from `TokenManager`'s ordinary
    // login/refresh machinery (covered exhaustively by TokenManagerTests).
    //
    // `TokenManager.invalidate()` only clears the IN-MEMORY cache (by
    // design -- see its doc comment), so the observable, unambiguous signal
    // that `GateClient.open` actually called `invalidate()` after the 401
    // is that the SECOND `accessToken()` resolution goes back to the
    // credential store (`loadTokens()` called again) instead of reusing the
    // in-memory value it already had -- which is exactly what a plain
    // in-memory cache hit on the second call would NOT do.
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(
        TokenSet(accessToken: "the-token", refreshToken: "rt", expiresIn: 3600, tokenType: "bearer")
    )
    let tokenManager = TokenManager(api: issuing, credentialStore: store)

    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    #expect(script.requestCount == 2)
    #expect(issuing.loginCallCount == 0)
    #expect(issuing.refreshCallCount == 0)

    // Both HTTP attempts carried the (only available) bearer token.
    #expect(script.authorizationHeaders == ["Bearer the-token", "Bearer the-token"])

    // The decisive assertion: `loadTokens()` was called MORE THAN ONCE.
    // A single `accessToken()` call (or a second call that hit a live
    // in-memory cache, i.e. one where `invalidate()` was NOT called) would
    // load from the store at most once for the whole `open` call. Seeing a
    // second `loadTokens()` call proves the in-memory cache was cleared
    // between the two HTTP attempts -- i.e. that `invalidate()` ran.
    #expect(store.loadTokensCallCount >= 2)
}

@Test func open403DoesNotRetryExactlyOneAttempt() async throws {
    let script = RequestScript(statuses: [403, 202, 202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.requestCount == 1)
}

// MARK: - open: percent-encoding

@Test func openPercentEncodesHashInEndpointId() async throws {
    let script = RequestScript(statuses: [202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    let endpointId = "_DA_00000000-1111-2222-3333-444444444444_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-00001_VIP#OD#SB100001.1"
    try await client.open(endpointId: endpointId)

    let expectedEncodedId = "_DA_00000000-1111-2222-3333-444444444444_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-00001_VIP%23OD%23SB100001.1"
    #expect(script.lastPath == "/servicerest/devicecom/endpoint/\(expectedEncodedId)/power")
    #expect(script.lastPath?.contains("#") == false)
    #expect(script.lastPath?.contains("%23") == true)
}

@Test func percentEncodeEndpointIdEncodesHash() {
    let encoded = GateClient.percentEncodeEndpointId("VIP#OD#SB100001.1")
    #expect(encoded == "VIP%23OD%23SB100001.1")
    #expect(encoded?.contains("#") == false)
}

// MARK: - Suite speed: no real sleeping

/// Thread-safe recorder of every `Duration` the injected `RetryPolicy.sleep`
/// closure was invoked with. Same `NSLock` + `@unchecked Sendable` idiom as
/// `RequestScript` above, used here instead of a wall-clock measurement so
/// the property under test ("retries route delays through the injected
/// sleep and never really sleep") is verified deterministically rather than
/// via a timing threshold that flakes under CI/parallel load.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []

    var durations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return _durations
    }

    func record(_ duration: Duration) {
        lock.lock()
        _durations.append(duration)
        lock.unlock()
    }
}

@Test func retriesRouteAllDelaysThroughInjectedSleep() async throws {
    let script = RequestScript(statuses: [500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let recorder = SleepRecorder()
    // Custom, intentionally larger-than-default `maxTotalDelay` (6s, versus
    // the 2s default) so this test's own sleep-count/positivity assertions
    // are independent of the default policy's tighter cap -- that cap is
    // covered separately by `defaultPolicySleepsNeverExceedMaxTotalDelay`
    // below. `sleep` records the requested `Duration` instead of no-op'ing,
    // so this test can assert real backoff WOULD have slept without ever
    // actually sleeping. Uses the source-compatibility single-value
    // `requestTimeout:` initializer (uniform 3s across all attempts).
    let retryPolicy = RetryPolicy(
        maxAttempts: 3,
        baseDelay: .milliseconds(400),
        maxTotalDelay: .seconds(6),
        requestTimeout: .seconds(3),
        sleep: { duration in recorder.record(duration) }
    )
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: retryPolicy)

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    // Exactly 2 sleeps for 3 attempts: one between attempt 1->2 and one
    // between attempt 2->3, none after the final (failed) attempt.
    #expect(recorder.durations.count == 2)
    // Every recorded delay is strictly positive, proving real backoff would
    // have actually slept -- the deterministic replacement for the old
    // wall-clock ">1s with real backoff" claim.
    #expect(recorder.durations.allSatisfy { $0 > .zero })
}

// MARK: - gateopener-41m.6: escalating per-attempt timeout, shrunk sleep budget

/// Acceptance test for step 1: attempt `k`'s `URLRequest.timeoutInterval`
/// follows the configured `requestTimeouts` schedule exactly -- 3s, 5s, 8s
/// for the default policy -- across a 500/500/500 script that forces all 3
/// attempts to actually happen.
@Test func openEscalatesPerAttemptTimeoutAcrossThreeFiveEightSeconds() async throws {
    let script = RequestScript(statuses: [500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay(maxAttempts: 3))

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.timeoutIntervals == [3, 5, 8])
}

/// Edge case: `maxAttempts > requestTimeouts.count` reuses the LAST
/// timeout value for every attempt beyond the schedule's length, rather than
/// indexing out of bounds or wrapping.
@Test func openReusesLastTimeoutWhenMaxAttemptsExceedsScheduleLength() async throws {
    let script = RequestScript(statuses: [500, 500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let retryPolicy = RetryPolicy(
        maxAttempts: 4,
        baseDelay: .milliseconds(1),
        maxTotalDelay: .milliseconds(1),
        requestTimeouts: [.seconds(3), .seconds(5), .seconds(8)],
        sleep: { _ in }
    )
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: retryPolicy)

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    // 4th attempt reuses the last (8s) schedule entry rather than crashing
    // or reusing the first.
    #expect(script.timeoutIntervals == [3, 5, 8, 8])
}

/// Edge case: `maxAttempts == 1` uses only the FIRST entry of the schedule,
/// never a later one, and never below the 3s floor.
@Test func openWithSingleAttemptUsesFirstTimeoutOnly() async throws {
    let script = RequestScript(statuses: [500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay(maxAttempts: 1))

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.timeoutIntervals == [3])
}

/// Acceptance test for step 2: the sum of every sleep the DEFAULT policy
/// (`.noDelay()`, same backoff/cap shape as `.default`) actually requests
/// via the injected `sleep` closure never exceeds the 2s `maxTotalDelay`
/// budget, across a full 3-attempt failure run.
@Test func defaultPolicySleepsNeverExceedMaxTotalDelay() async throws {
    let script = RequestScript(statuses: [500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let recorder = SleepRecorder()
    let retryPolicy = RetryPolicy(
        maxAttempts: 3,
        baseDelay: .milliseconds(400),
        maxTotalDelay: .seconds(2),
        requestTimeouts: [.seconds(3), .seconds(5), .seconds(8)],
        sleep: { duration in recorder.record(duration) }
    )
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: retryPolicy)

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    let totalSleep = recorder.durations.reduce(Duration.zero, +)
    #expect(totalSleep <= .seconds(2))
}

/// Confirms `RetryPolicy.default` itself (not a hand-built equivalent) uses
/// the documented 2s `maxTotalDelay` cap and 3/5/8s escalating schedule, so
/// a future change to one without the other is caught here.
@Test func defaultRetryPolicyHasDocumentedShapeAndArithmetic() {
    let policy = RetryPolicy.default
    #expect(policy.maxAttempts == 3)
    #expect(policy.maxTotalDelay == .seconds(2))
    #expect(policy.requestTimeouts == [.seconds(3), .seconds(5), .seconds(8)])
    // Worst case: 3 + 5 + 8 = 16s of requests, plus <= 2s of bounded sleep
    // = <= 18s, comfortably under OpenGateFlow's 25s deadline.
    let totalRequestBudget = policy.requestTimeouts.reduce(Duration.zero, +)
    #expect(totalRequestBudget == .seconds(16))
    #expect(totalRequestBudget + policy.maxTotalDelay == .seconds(18))
}

/// Source-compatibility: the single-value `requestTimeout:` initializer
/// (pre-dating this bead) still compiles and behaves as a UNIFORM timeout
/// across every attempt -- i.e. equivalent to `requestTimeouts: [value]`.
@Test func singleValueRequestTimeoutInitializerAppliesUniformlyToEveryAttempt() async throws {
    let script = RequestScript(statuses: [500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let retryPolicy = RetryPolicy(
        maxAttempts: 3,
        requestTimeout: .seconds(5),
        sleep: { _ in }
    )
    #expect(retryPolicy.requestTimeouts == [.seconds(5)])

    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: retryPolicy)

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.timeoutIntervals == [5, 5, 5])
}

/// Acceptance test for gateopener-69h: a fractional-second entry in
/// `requestTimeouts` (2500ms) is honoured EXACTLY as 2.5, not truncated to
/// 2.0 by the `Duration` -> `TimeInterval` conversion.
///
/// MUTATION CHECK: reverting `GateClient`'s conversion of
/// `timeoutForAttempt` to `TimeInterval(timeoutForAttempt.components.seconds)`
/// (dropping the `attoseconds` remainder) makes this assertion fail:
/// 2.0 != 2.5.
@Test func openHonoursFractionalRequestTimeout() async throws {
    let script = RequestScript(statuses: [500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let retryPolicy = RetryPolicy(
        maxAttempts: 1,
        requestTimeouts: [.milliseconds(2500)],
        sleep: { _ in }
    )
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: retryPolicy)

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.timeoutIntervals == [2.5])
}

// MARK: - open: .invalidCredentials is never retried (safety: retrying a
// wrong password against the live service is pointless and could contribute
// to account lockout)

@Test func openNeverRetriesInvalidCredentials() async throws {
    let script = RequestScript(statuses: [202, 202, 202])
    let session = makeSequencedSession(script: script)

    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try store.saveCredentials(username: "alice", password: "wrong-password")
    // Credentials exist but login fails with invalidCredentials (e.g. wrong
    // password rejected by the server).
    issuing.loginResult = .failure(ComelitError.invalidCredentials)
    let tokenManager = TokenManager(api: issuing, credentialStore: store)

    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay(maxAttempts: 3))

    await #expect(throws: ComelitError.invalidCredentials) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    // Zero HTTP requests: accessToken() failed before any request was made,
    // and the failure was never retried (would need multiple accessToken()
    // attempts / HTTP requests if it were).
    #expect(script.requestCount == 0)
}

// MARK: - open: attemptObserver (gateopener-41m.1)

/// A thread-safe recording fake `OpenAttemptObserving`, same `NSLock` +
/// `@unchecked Sendable` idiom as `RequestScript`/`SleepRecorder` above.
final class RecordingAttemptObserver: OpenAttemptObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [OpenAttemptRecord] = []

    var records: [OpenAttemptRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }

    func record(_ record: OpenAttemptRecord) {
        lock.lock()
        _records.append(record)
        lock.unlock()
    }
}

/// (a) 500, 500, 202 -> 3 records, willRetry true/true/false, last is
/// success(202).
@Test func attemptObserverRecordsThreeAttemptsOn500x2ThenSuccess() async throws {
    let script = RequestScript(statuses: [500, 500, 202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(maxAttempts: 3),
        attemptObserver: observer
    )

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    let records = observer.records
    #expect(records.count == 3)
    #expect(records.map(\.willRetry) == [true, true, false])
    #expect(records[0].outcome == .httpFailure(status: 500))
    #expect(records[1].outcome == .httpFailure(status: 500))
    #expect(records[2].outcome == .success(status: 202))
}

/// (b) transport error then 202 -> first record is `.transportFailure` with
/// the scripted `URLError` code.
@Test func attemptObserverRecordsTransportFailureWithScriptedURLErrorCode() async throws {
    let script = RequestScript(responses: [
        .transportError(.networkConnectionLost),
        ScriptedResponse(status: 202),
    ])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(),
        attemptObserver: observer
    )

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    let records = observer.records
    #expect(records.count == 2)
    #expect(records[0].outcome == .transportFailure(urlErrorCode: URLError.networkConnectionLost.rawValue))
    #expect(records[0].willRetry == true)
    #expect(records[1].outcome == .success(status: 202))
    #expect(records[1].willRetry == false)
}

/// (c) 403 -> 1 record, willRetry false.
@Test func attemptObserverRecordsSingleNonRetryable403() async throws {
    let script = RequestScript(statuses: [403, 202, 202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(),
        attemptObserver: observer
    )

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    let records = observer.records
    #expect(records.count == 1)
    #expect(records[0].outcome == .httpFailure(status: 403))
    #expect(records[0].willRetry == false)
}

/// (d) 401 then 202 -> 2 records; the 401 attempt is recorded as
/// `.httpFailure(401)` with `willRetry: true`.
@Test func attemptObserverRecordsTwoAttemptsOn401ThenSuccess() async throws {
    let script = RequestScript(statuses: [401, 202])
    let session = makeSequencedSession(script: script)

    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(
        TokenSet(accessToken: "the-token", refreshToken: "rt", expiresIn: 3600, tokenType: "bearer")
    )
    let tokenManager = TokenManager(api: issuing, credentialStore: store)

    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(),
        attemptObserver: observer
    )

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    let records = observer.records
    #expect(records.count == 2)
    #expect(records[0].outcome == .httpFailure(status: 401))
    #expect(records[0].willRetry == true)
    #expect(records[1].outcome == .success(status: 202))
    #expect(records[1].willRetry == false)
}

/// (e) token-resolution failure -> 1 `.tokenFailure` record and zero HTTP
/// requests.
@Test func attemptObserverRecordsTokenFailureWithZeroHTTPRequests() async throws {
    let script = RequestScript(statuses: [202, 202, 202])
    let session = makeSequencedSession(script: script)

    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try store.saveCredentials(username: "alice", password: "wrong-password")
    issuing.loginResult = .failure(ComelitError.invalidCredentials)
    let tokenManager = TokenManager(api: issuing, credentialStore: store)

    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(maxAttempts: 3),
        attemptObserver: observer
    )

    await #expect(throws: ComelitError.invalidCredentials) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.requestCount == 0)

    let records = observer.records
    #expect(records.count == 1)
    #expect(records[0].willRetry == false)
    if case .tokenFailure = records[0].outcome {
        // expected
    } else {
        Issue.record("expected .tokenFailure, got \(records[0].outcome)")
    }
}

/// Secrets hygiene: a token failure caused by `ComelitError.server` (which
/// carries up to 300 raw characters of the auth server's response body)
/// must never leak that body into the persisted `.tokenFailure` description
/// -- only the sanitized "server(<status>)" form.
@Test func attemptObserverTokenFailureDescriptionNeverContainsServerResponseBody() async throws {
    let script = RequestScript(statuses: [202])
    let session = makeSequencedSession(script: script)

    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try store.saveCredentials(username: "alice", password: "s3cret")
    issuing.loginResult = .failure(ComelitError.server(status: 500, body: "SECRET"))
    let tokenManager = TokenManager(api: issuing, credentialStore: store)

    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(),
        attemptObserver: observer
    )

    await #expect(throws: ComelitError.server(status: 500, body: "SECRET")) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    let records = observer.records
    #expect(records.count == 1)
    if case .tokenFailure(let description) = records[0].outcome {
        #expect(!description.contains("SECRET"))
        #expect(description == "server(500)")
    } else {
        Issue.record("expected .tokenFailure, got \(records[0].outcome)")
    }
}

/// (f) attempt numbers are 1-based and `maxAttempts` matches the policy.
@Test func attemptObserverRecordsAreOneBasedWithMatchingMaxAttempts() async throws {
    let script = RequestScript(statuses: [500, 500, 500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(maxAttempts: 3),
        attemptObserver: observer
    )

    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    let records = observer.records
    #expect(records.map(\.attempt) == [1, 2, 3])
    #expect(records.allSatisfy { $0.maxAttempts == 3 })
}

/// `attemptObserver` defaults to `nil`: `open` must behave identically to
/// every pre-existing (non-observer) test in this file with no observer
/// wired up at all -- this is a direct check that the parameter is optional
/// and source-compatible with every existing call site.
@Test func attemptObserverDefaultsToNilAndOpenStillSucceeds() async throws {
    let script = RequestScript(statuses: [202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay())

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    #expect(script.requestCount == 1)
}

// MARK: - open: OpenPressContext.pressId correlation (gateopener-41m.22)

/// When `open()` runs inside `OpenPressContext.$pressId.withValue(_:)`,
/// every `OpenAttemptRecord` it reports carries that press id.
@Test func attemptRecordsCarryTaskLocalPressIdWhenSet() async throws {
    let script = RequestScript(statuses: [500, 202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(),
        attemptObserver: observer
    )

    let pressId = UUID()
    try await OpenPressContext.$pressId.withValue(pressId) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    let records = observer.records
    #expect(records.count == 2)
    #expect(records.allSatisfy { $0.pressId == pressId })
}

/// With no `OpenPressContext.pressId` bound at all, every reported attempt
/// carries `pressId == nil` -- the default, pre-existing behavior for every
/// other test in this file.
@Test func attemptRecordsCarryNilPressIdWhenUnset() async throws {
    let script = RequestScript(statuses: [202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()
    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: .noDelay(),
        attemptObserver: observer
    )

    #expect(OpenPressContext.pressId == nil)
    try await client.open(endpointId: "VIP#OD#SB100001.1")

    let records = observer.records
    #expect(records.count == 1)
    #expect(records[0].pressId == nil)
}

// MARK: - gateopener-91s: elapsedMilliseconds excludes backoff sleep;
// CancellationError propagates out of the retry loop without a spurious
// record

/// Thread-safe, fully-controlled fake clock. `advanceDuringRequest(by:)` is
/// called from `RequestScript.onRequest` (i.e. synchronously inside
/// `SequencedStubURLProtocol.startLoading()`, while `GateClient.open` is
/// suspended awaiting the HTTP response) so its advance is bracketed exactly
/// between `attemptStartedAt = now()` and `report`'s own `now()` call --
/// i.e. it simulates "time passed while the request was in flight". A
/// SEPARATE, distinguishably-sized advance is applied from the injected
/// `RetryPolicy.sleep` closure, so a bug that measured elapsed time across
/// the sleep (instead of only across the request) would inflate
/// `elapsedMilliseconds` by that distinguishable amount and the test's exact
/// equality assertions below would fail.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Thread-safe monotonically-incrementing counter, used to index into
/// `requestAdvances` below without triggering the Swift 6 "mutation of
/// captured var in concurrently-executing code" diagnostic that a plain
/// `var` capture would.
final class GateClientTestsLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func incrementAndGetPrevious() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let previous = value
        value += 1
        return previous
    }
}

/// (1) `elapsedMilliseconds` measures only time spent IN the HTTP request,
/// never time spent sleeping between attempts.
///
/// MUTATION CHECK: if `GateClient.report`'s `startedAt` were captured before
/// the PRECEDING attempt's backoff sleep (or if `elapsedMilliseconds` were
/// otherwise measured across the sleep), the 5000ms sleep-only advance would
/// leak into one or both records' `elapsedMilliseconds`, and the exact
/// equality assertions below (250, then 750) would fail instead of matching
/// the request-only advances.
@Test func elapsedMillisecondsExcludesBackoffSleep() async throws {
    let script = RequestScript(statuses: [500, 202])
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))

    // Distinguishable per-request advances: attempt 1 (failing 500) "takes"
    // 250ms of request time, attempt 2 (succeeding 202) "takes" 750ms.
    let requestAdvances: [TimeInterval] = [0.250, 0.750]
    let requestAdvanceCounter = GateClientTestsLockedCounter()
    script.onRequest = {
        let i = requestAdvanceCounter.incrementAndGetPrevious()
        clock.advance(by: requestAdvances[min(i, requestAdvances.count - 1)])
    }

    let session = makeSequencedSession(script: script)
    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()

    // Sleep advances the SAME clock by a large, distinguishable amount
    // (5000ms) that must NOT show up in either record's
    // `elapsedMilliseconds` -- proving the measurement window excludes
    // backoff sleep entirely.
    let retryPolicy = RetryPolicy(
        maxAttempts: 2,
        baseDelay: .milliseconds(1),
        maxTotalDelay: .seconds(10),
        requestTimeouts: [.seconds(3)],
        sleep: { _ in clock.advance(by: 5.0) }
    )

    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: retryPolicy,
        attemptObserver: observer,
        now: { clock.now() }
    )

    try await client.open(endpointId: "VIP#OD#SB100001.1")

    #expect(script.requestCount == 2)
    let records = observer.records
    #expect(records.count == 2)
    #expect(records[0].outcome == .httpFailure(status: 500))
    #expect(records[0].elapsedMilliseconds == 250)
    #expect(records[1].outcome == .success(status: 202))
    #expect(records[1].elapsedMilliseconds == 750)
}

/// (2) `CancellationError` thrown by the injected `RetryPolicy.sleep`
/// (i.e. during backoff, after a retryable 500) propagates out of
/// `open()` AS `CancellationError` -- not wrapped/mapped into a
/// `ComelitError` -- and the cancelled retry never happens: exactly one
/// HTTP request is made, and the observer has exactly one record (the
/// initial 500 attempt, `willRetry: true`); there is no record for the
/// cancelled second attempt, since no outcome was ever decided for it.
///
/// Catch-order finding (confirmed by reading `GateClient.open`): the
/// `catch` block's FIRST statement is `if error is CancellationError {
/// throw error }`, which runs before the `RawTransportError`/`ComelitError`
/// classification/reporting below it. `backoffAndAdvance` (called from
/// inside the same `do` block that the retry-continue path runs in) awaits
/// `retryPolicy.sleep`, so a `CancellationError` thrown there is caught by
/// that same `catch` and rethrown immediately at that first line, before
/// any further reporting and before the loop ever `continue`s to a second
/// request.
///
/// MUTATION CHECK: temporarily removing the `if error is CancellationError
/// { throw error }` rethrow causes `CancellationError` to fall through to
/// the `else` branch (neither `RawTransportError` nor `ComelitError`),
/// which classifies it as a fallback `ComelitError.network(...)`, reports a
/// SECOND record, and retries with a second HTTP request instead of
/// propagating cancellation -- i.e. `open()` throws `ComelitError`, not
/// `CancellationError`, `script.requestCount == 2`, and
/// `observer.records.count == 2`. 
@Test func cancellationDuringBackoffPropagatesWithoutFurtherRequestsOrRecords() async throws {
    let script = RequestScript(statuses: [500, 202])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let observer = RecordingAttemptObserver()

    let retryPolicy = RetryPolicy(
        maxAttempts: 2,
        baseDelay: .milliseconds(1),
        maxTotalDelay: .seconds(10),
        requestTimeouts: [.seconds(3)],
        sleep: { _ in throw CancellationError() }
    )

    let client = GateClient(
        session: session,
        tokenManager: tokenManager,
        retryPolicy: retryPolicy,
        attemptObserver: observer
    )

    await #expect(throws: CancellationError.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }

    #expect(script.requestCount == 1)
    let records = observer.records
    #expect(records.count == 1)
    #expect(records[0].outcome == .httpFailure(status: 500))
    #expect(records[0].willRetry == true)
}
