import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - MockTokenIssuing

/// In-memory, thread-safe mock of `TokenIssuing` for use in `TokenManager`
/// tests. Exposes call counters so tests can assert exactly how many
/// login/refresh calls were made, and configurable results/errors so tests
/// can script both success and failure paths.
///
/// `loginGate`, if set, is awaited (via a `CheckedContinuation` under the
/// covers) before `login` returns, letting a test hold a login call open
/// until it has verified that a second concurrent caller is also blocked —
/// making the coalescing test deterministic rather than timing-dependent.
final class MockTokenIssuing: TokenIssuing, @unchecked Sendable {
    private let lock = NSLock()

    private(set) var loginCallCount = 0
    private(set) var refreshCallCount = 0

    var loginResult: Result<TokenSet, Error> = .failure(TestError.unconfigured)
    var refreshResult: Result<TokenSet, Error> = .failure(TestError.unconfigured)

    /// When non-nil, `login` suspends on this gate before returning its
    /// scripted result. Signal the gate (via `openLoginGate()`) to let it
    /// proceed. Used to make the concurrency-coalescing test deterministic.
    /// All continuations currently waiting on the gate. This MUST be a
    /// collection, not a single slot: two concurrent `login` calls both
    /// suspend here, and a single slot would let the second overwrite (and
    /// permanently orphan) the first — turning a coalescing regression into
    /// a hang instead of a clean assertion failure.
    private var loginGateContinuations: [CheckedContinuation<Void, Never>] = []
    private var loginGateEnabled = false
    private var loginGateOpen = false

    /// Same mechanism as `loginGate`, but for `refresh` calls. Used to make
    /// the prewarm/accessToken coalescing test deterministic rather than
    /// timing-dependent.
    private var refreshGateContinuations: [CheckedContinuation<Void, Never>] = []
    private var refreshGateEnabled = false
    private var refreshGateOpen = false

    enum TestError: Error, Equatable {
        case unconfigured
    }

    /// Runs `body` while holding `lock`, synchronously. Kept as a private
    /// helper (rather than calling `lock.lock()`/`lock.unlock()` directly
    /// inside `async` functions) because Swift 6 strict concurrency flags
    /// direct `NSLock` lock/unlock calls made from an `async` context as
    /// unavailable; wrapping them in a synchronous closure sidesteps that
    /// diagnostic while still using a plain, well-understood `NSLock`.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Call before use to enable gating of `login` calls.
    func enableLoginGate() {
        withLock { loginGateEnabled = true }
    }

    /// Release any (current or future) call to `login` that is waiting on
    /// the gate.
    func openLoginGate() {
        let continuations: [CheckedContinuation<Void, Never>] = withLock {
            let waiting = loginGateContinuations
            loginGateContinuations = []
            loginGateOpen = true
            return waiting
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func login(username: String, password: String) async throws -> TokenSet {
        let shouldWait: Bool = withLock {
            loginCallCount += 1
            return loginGateEnabled && !loginGateOpen
        }

        if shouldWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately: Bool = withLock {
                    if loginGateOpen {
                        return true
                    } else {
                        loginGateContinuations.append(continuation)
                        return false
                    }
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }

        switch loginResult {
        case .success(let tokens):
            return tokens
        case .failure(let error):
            throw error
        }
    }

    /// Call before use to enable gating of `refresh` calls.
    func enableRefreshGate() {
        withLock { refreshGateEnabled = true }
    }

    /// Release any (current or future) call to `refresh` that is waiting on
    /// the gate.
    func openRefreshGate() {
        let continuations: [CheckedContinuation<Void, Never>] = withLock {
            let waiting = refreshGateContinuations
            refreshGateContinuations = []
            refreshGateOpen = true
            return waiting
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        let shouldWait: Bool = withLock {
            refreshCallCount += 1
            return refreshGateEnabled && !refreshGateOpen
        }

        if shouldWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately: Bool = withLock {
                    if refreshGateOpen {
                        return true
                    } else {
                        refreshGateContinuations.append(continuation)
                        return false
                    }
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }

        switch refreshResult {
        case .success(let tokens):
            return tokens
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Test helpers

private func makeTokenSet(
    accessToken: String = "access-token",
    refreshToken: String? = "refresh-token",
    expiresIn: TimeInterval = 3600
) -> TokenSet {
    TokenSet(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn,
        tokenType: "bearer"
    )
}

// MARK: - Tests

@Test func freshCachedTokenReturnedWithoutAPICall() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let fresh = makeTokenSet(accessToken: "fresh-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(fresh)

    let manager = TokenManager(api: issuing, credentialStore: store)

    let token1 = try await manager.accessToken()
    #expect(token1 == "fresh-token")

    // Second call should hit the in-memory cache, not even reload from the store's persisted token.
    let token2 = try await manager.accessToken()
    #expect(token2 == "fresh-token")

    #expect(issuing.loginCallCount == 0)
    #expect(issuing.refreshCallCount == 0)
}

@Test func expiredStoredTokenTriggersRefresh() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let expired = makeTokenSet(accessToken: "old-token", expiresIn: -10)
    let refreshed = makeTokenSet(accessToken: "refreshed-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(expired)
    issuing.refreshResult = .success(refreshed)

    let manager = TokenManager(api: issuing, credentialStore: store)
    let token = try await manager.accessToken()

    #expect(token == "refreshed-token")
    #expect(issuing.refreshCallCount == 1)
    #expect(issuing.loginCallCount == 0)

    // The refreshed token set was persisted back to the store.
    let persisted = try store.loadTokens()
    #expect(persisted?.accessToken == "refreshed-token")
}

@Test func failedRefreshFallsBackToFullLogin() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let expired = makeTokenSet(accessToken: "old-token", expiresIn: -10)
    let loggedIn = makeTokenSet(accessToken: "login-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(expired)
    issuing.refreshResult = .failure(ComelitError.missingRefreshToken)
    issuing.loginResult = .success(loggedIn)

    let manager = TokenManager(api: issuing, credentialStore: store)
    let token = try await manager.accessToken()

    #expect(token == "login-token")
    #expect(issuing.refreshCallCount == 1)
    #expect(issuing.loginCallCount == 1)

    let persisted = try store.loadTokens()
    #expect(persisted?.accessToken == "login-token")
}

@Test func noStoredCredentialsThrowsNotConfigured() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    #expect(store.isEmpty)

    let manager = TokenManager(api: issuing, credentialStore: store)

    await #expect(throws: TokenManagerError.notConfigured) {
        _ = try await manager.accessToken()
    }

    #expect(issuing.loginCallCount == 0)
    #expect(issuing.refreshCallCount == 0)
}

@Test func fullLoginInvalidCredentialsPropagatesDistinctly() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    try store.saveCredentials(username: "alice", password: "wrong-password")
    issuing.loginResult = .failure(ComelitError.invalidCredentials)

    let manager = TokenManager(api: issuing, credentialStore: store)

    await #expect(throws: ComelitError.invalidCredentials) {
        _ = try await manager.accessToken()
    }

    #expect(issuing.loginCallCount == 1)
}

@Test func concurrentAccessTokenCallsCoalesceToOneLogin() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let loggedIn = makeTokenSet(accessToken: "login-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    issuing.loginResult = .success(loggedIn)
    issuing.enableLoginGate()

    let manager = TokenManager(api: issuing, credentialStore: store)

    async let first = manager.accessToken()
    async let second = manager.accessToken()

    // Give both callers a genuine chance to reach (and suspend inside) login
    // before releasing the gate, so this isn't a lucky race.
    while issuing.loginCallCount < 1 {
        await Task.yield()
    }
    // A brief additional yield window to let a hypothetical second (buggy)
    // login call register itself before we open the gate.
    for _ in 0..<50 {
        await Task.yield()
    }
    issuing.openLoginGate()

    let (token1, token2) = try await (first, second)

    #expect(token1 == "login-token")
    #expect(token2 == "login-token")
    #expect(issuing.loginCallCount == 1)
}

@Test func invalidateForcesReResolution() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let fresh = makeTokenSet(accessToken: "fresh-token", expiresIn: 3600)
    let refreshed = makeTokenSet(accessToken: "refreshed-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(fresh)
    issuing.refreshResult = .success(refreshed)

    let manager = TokenManager(api: issuing, credentialStore: store)

    let token1 = try await manager.accessToken()
    #expect(token1 == "fresh-token")

    await manager.invalidate()

    // The in-memory cache is gone, but the store still has "fresh-token"
    // (not expired), so re-resolution should return it again from the
    // store rather than requiring a refresh or login.
    let token2 = try await manager.accessToken()
    #expect(token2 == "fresh-token")
    #expect(issuing.refreshCallCount == 0)
    #expect(issuing.loginCallCount == 0)
}

@Test func invalidateThenExpiredStoredTokenTriggersReAuthentication() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let expiring = makeTokenSet(accessToken: "about-to-expire", expiresIn: 3600)
    let refreshed = makeTokenSet(accessToken: "refreshed-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(expiring)
    issuing.refreshResult = .success(refreshed)

    let manager = TokenManager(api: issuing, credentialStore: store)
    _ = try await manager.accessToken()

    // Simulate the server rejecting the token mid-flight: invalidate, then
    // make the persisted copy look expired by overwriting it.
    await manager.invalidate()
    let nowExpired = makeTokenSet(accessToken: "about-to-expire", expiresIn: -10)
    try store.saveTokens(nowExpired)

    let token = try await manager.accessToken()
    #expect(token == "refreshed-token")
    #expect(issuing.refreshCallCount == 1)
}

@Test func tokenExpiringWithinSkewIsTreatedAsNeedingRenewal() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    // Expires in 60s: within the 5-minute (300s) skew window, so it must be
    // treated as needing renewal even though it is not technically expired yet.
    let nearExpiry = makeTokenSet(accessToken: "near-expiry", expiresIn: 60)
    let refreshed = makeTokenSet(accessToken: "refreshed-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(nearExpiry)
    issuing.refreshResult = .success(refreshed)

    let manager = TokenManager(api: issuing, credentialStore: store)
    let token = try await manager.accessToken()

    #expect(token == "refreshed-token")
    #expect(issuing.refreshCallCount == 1)
}

@Test func tokenExpiringWellOutsideSkewIsUsedAsIs() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    // Expires in 600s: outside the 5-minute (300s) skew window, so it should
    // be used as-is without a refresh.
    let comfortable = makeTokenSet(accessToken: "comfortable-token", expiresIn: 600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(comfortable)

    let manager = TokenManager(api: issuing, credentialStore: store)
    let token = try await manager.accessToken()

    #expect(token == "comfortable-token")
    #expect(issuing.refreshCallCount == 0)
    #expect(issuing.loginCallCount == 0)
}

// MARK: - prewarm() tests

@Test func prewarmWithFreshTokenMakesNoNetworkCall() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let fixedNow = Date()
    // Expires in 1h -- well outside the default 600s prewarm window.
    let fresh = makeTokenSet(accessToken: "fresh-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(fresh)

    let manager = TokenManager(api: issuing, credentialStore: store, now: { fixedNow })

    await manager.prewarm()

    #expect(issuing.refreshCallCount == 0)
    #expect(issuing.loginCallCount == 0)

    // The stored token must be untouched.
    let persisted = try store.loadTokens()
    #expect(persisted?.accessToken == "fresh-token")
}

@Test func prewarmWithSoonToExpireTokenRefreshesExactlyOnce() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let fixedNow = Date()
    // Expires in 5 minutes -- inside the default 600s (10 min) prewarm window.
    let soonToExpire = makeTokenSet(accessToken: "soon-to-expire", expiresIn: 300)
    let refreshed = makeTokenSet(accessToken: "refreshed-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(soonToExpire)
    issuing.refreshResult = .success(refreshed)

    let manager = TokenManager(api: issuing, credentialStore: store, now: { fixedNow })

    await manager.prewarm()

    #expect(issuing.refreshCallCount == 1)
    #expect(issuing.loginCallCount == 0)

    let persisted = try store.loadTokens()
    #expect(persisted?.accessToken == "refreshed-token")
}

@Test func prewarmWithNoStoredTokensMakesNoNetworkCall() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    #expect(store.isEmpty)

    let manager = TokenManager(api: issuing, credentialStore: store)

    await manager.prewarm()

    #expect(issuing.loginCallCount == 0)
    #expect(issuing.refreshCallCount == 0)
}

@Test func prewarmSwallowsFailureAndLeavesOldTokensStored() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let fixedNow = Date()
    let soonToExpire = makeTokenSet(accessToken: "soon-to-expire", expiresIn: 300)
    try store.saveTokens(soonToExpire)
    // No stored credentials, so the fallback-to-login path cannot succeed
    // either: refresh fails, then login fails with .notConfigured.
    issuing.refreshResult = .failure(ComelitError.missingRefreshToken)

    let manager = TokenManager(api: issuing, credentialStore: store, now: { fixedNow })

    await manager.prewarm() // must not throw

    #expect(issuing.refreshCallCount == 1)
    #expect(issuing.loginCallCount == 0)

    // The old token set must remain stored, untouched by the failed attempt.
    let persisted = try store.loadTokens()
    #expect(persisted?.accessToken == "soon-to-expire")
}

@Test func concurrentPrewarmAndAccessTokenCoalesceToOneRefresh() async throws {
    let store = MockCredentialStore()
    let issuing = MockTokenIssuing()
    let fixedNow = Date()
    let soonToExpire = makeTokenSet(accessToken: "soon-to-expire", expiresIn: 300)
    let refreshed = makeTokenSet(accessToken: "refreshed-token", expiresIn: 3600)
    try store.saveCredentials(username: "alice", password: "s3cret")
    try store.saveTokens(soonToExpire)
    issuing.refreshResult = .success(refreshed)
    issuing.enableRefreshGate()

    let manager = TokenManager(api: issuing, credentialStore: store, now: { fixedNow })

    async let prewarmed: Void = manager.prewarm()
    async let accessed = manager.accessToken()

    // Give both callers a genuine chance to reach (and suspend inside)
    // refresh before releasing the gate, so this isn't a lucky race: if
    // coalescing is broken, both `prewarm()` and `accessToken()` will have
    // independently called `refresh()` and be waiting on the gate here.
    while issuing.refreshCallCount < 1 {
        await Task.yield()
    }
    for _ in 0..<50 {
        await Task.yield()
    }
    issuing.openRefreshGate()

    let token = try await accessed
    await prewarmed

    #expect(token == "refreshed-token")
    #expect(issuing.refreshCallCount == 1)
    #expect(issuing.loginCallCount == 0)
}
