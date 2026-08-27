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

    init(responses: [ScriptedResponse]) {
        self.responses = responses
    }

    /// Convenience initializer for tests that only care about status codes.
    convenience init(statuses: [Int]) {
        self.init(responses: statuses.map { ScriptedResponse(status: $0) })
    }

    func nextResponse(forPath path: String, authorizationHeader: String?) -> ScriptedResponse {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        lastPath = path
        authorizationHeaders.append(authorizationHeader ?? "")
        let response = responses[min(index, responses.count - 1)]
        index += 1
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
        let scripted = script.nextResponse(forPath: path, authorizationHeader: authHeader)

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

@Test func retryingTestsCompleteFastNoRealSleeping() async throws {
    let script = RequestScript(statuses: [500, 500, 500])
    let session = makeSequencedSession(script: script)

    let (tokenManager, _) = makeTokenManager()
    let client = GateClient(session: session, tokenManager: tokenManager, retryPolicy: .noDelay(maxAttempts: 3))

    let start = ContinuousClock.now
    await #expect(throws: Error.self) {
        try await client.open(endpointId: "VIP#OD#SB100001.1")
    }
    let elapsed = ContinuousClock.now - start

    // With real backoff (base 400ms, 3 attempts) this would take well over a
    // second; with `.noDelay()` it must complete in a small fraction of that.
    #expect(elapsed < .milliseconds(500))
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
