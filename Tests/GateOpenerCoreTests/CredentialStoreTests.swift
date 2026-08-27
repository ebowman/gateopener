import Foundation
import Security
import Testing
@testable import GateOpenerCore

// MARK: - MockCredentialStore
//
// In-memory, thread-safe `CredentialStoring` used by this bead's own tests.
// NOTE for later beads (.4, .7 — API client / app wiring): this mock lives in
// the TEST TARGET (`GateOpenerCoreTests`), so it is only reachable from other
// test files via `@testable import GateOpenerCore` plus being compiled in the
// same test target. If a later bead's tests need it from a different test
// target, it will need to be duplicated or moved into a shared test-support
// module — it is intentionally not part of the library target.

/// In-memory, thread-safe mock of `CredentialStoring` for use in tests.
///
/// Exposes call counters and a way to assert everything was cleared, for
/// tests that need to verify interaction counts rather than just final state.
final class MockCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _credentials: (username: String, password: String)?
    private var _tokens: TokenSet?

    private(set) var saveCredentialsCallCount = 0
    private(set) var loadCredentialsCallCount = 0
    private(set) var deleteCredentialsCallCount = 0
    private(set) var saveTokensCallCount = 0
    private(set) var loadTokensCallCount = 0
    private(set) var deleteTokensCallCount = 0

    func saveCredentials(username: String, password: String) throws {
        lock.lock()
        defer { lock.unlock() }
        saveCredentialsCallCount += 1
        _credentials = (username: username, password: password)
    }

    func loadCredentials() throws -> (username: String, password: String)? {
        lock.lock()
        defer { lock.unlock() }
        loadCredentialsCallCount += 1
        return _credentials
    }

    func deleteCredentials() throws {
        lock.lock()
        defer { lock.unlock() }
        deleteCredentialsCallCount += 1
        _credentials = nil
    }

    func saveTokens(_ tokens: TokenSet) throws {
        lock.lock()
        defer { lock.unlock() }
        saveTokensCallCount += 1
        _tokens = tokens
    }

    func loadTokens() throws -> TokenSet? {
        lock.lock()
        defer { lock.unlock() }
        loadTokensCallCount += 1
        return _tokens
    }

    func deleteTokens() throws {
        lock.lock()
        defer { lock.unlock() }
        deleteTokensCallCount += 1
        _tokens = nil
    }

    /// True when neither credentials nor tokens are currently stored.
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _credentials == nil && _tokens == nil
    }
}

// MARK: - MockCredentialStore tests

@Test func mockRoundTripsCredentials() throws {
    let store = MockCredentialStore()
    #expect(try store.loadCredentials() == nil)

    try store.saveCredentials(username: "alice", password: "s3cret")
    let loaded = try store.loadCredentials()
    #expect(loaded?.username == "alice")
    #expect(loaded?.password == "s3cret")

    try store.deleteCredentials()
    #expect(try store.loadCredentials() == nil)
}

@Test func mockRoundTripsTokens() throws {
    let store = MockCredentialStore()
    #expect(try store.loadTokens() == nil)

    let tokens = TokenSet(
        accessToken: "access-1",
        refreshToken: "refresh-1",
        expiresAt: Date(timeIntervalSince1970: 1_000_000),
        tokenType: "Bearer"
    )
    try store.saveTokens(tokens)
    #expect(try store.loadTokens() == tokens)

    try store.deleteTokens()
    #expect(try store.loadTokens() == nil)
}

@Test func mockOverwriteCredentialsSecondSaveWins() throws {
    let store = MockCredentialStore()
    try store.saveCredentials(username: "alice", password: "first")
    try store.saveCredentials(username: "alice", password: "second")
    let loaded = try store.loadCredentials()
    #expect(loaded?.password == "second")
    #expect(store.saveCredentialsCallCount == 2)
}

@Test func mockOverwriteTokensSecondSaveWins() throws {
    let store = MockCredentialStore()
    let first = TokenSet(accessToken: "a1", refreshToken: nil, expiresAt: Date(), tokenType: "Bearer")
    let second = TokenSet(accessToken: "a2", refreshToken: nil, expiresAt: Date(), tokenType: "Bearer")
    try store.saveTokens(first)
    try store.saveTokens(second)
    #expect(try store.loadTokens()?.accessToken == "a2")
    #expect(store.saveTokensCallCount == 2)
}

@Test func mockIsEmptyAfterDeletes() throws {
    let store = MockCredentialStore()
    try store.saveCredentials(username: "alice", password: "pw")
    try store.saveTokens(TokenSet(accessToken: "a", refreshToken: nil, expiresAt: Date(), tokenType: "Bearer"))
    #expect(!store.isEmpty)

    try store.deleteCredentials()
    try store.deleteTokens()
    #expect(store.isEmpty)
}

// MARK: - KeychainCredentialStore tests
//
// SwiftPM test binaries are unsigned and, depending on the CI/dev machine's
// keychain configuration, may be unable to use the Security framework at all
// (missing entitlements, no interactive session, ACL prompts). Rather than
// fail or hang, these tests detect the relevant OSStatus values up front by
// performing a harmless probe write and SELF-SKIP via `Bool` conditions
// evaluated before the test body runs, using `#expect` early-return guards.
//
// Each test uses a unique `service` (UUID-suffixed) so runs never collide
// with the real app's keychain items or with each other, and always cleans
// up whatever it created, even on failure.

/// Statuses that indicate the keychain is unavailable/unusable in this
/// environment (as opposed to a genuine test failure).
private func isEnvironmentUnavailableStatus(_ status: OSStatus) -> Bool {
    switch status {
    case errSecMissingEntitlement, errSecNotAvailable, errSecInteractionNotAllowed:
        return true
    default:
        return false
    }
}

/// Attempts a harmless save+delete against a throwaway keychain item to
/// determine whether the keychain is usable in this environment. Returns
/// `nil` if usable, or the `OSStatus` that indicates unavailability.
private func probeKeychainUnavailableStatus(service: String) -> OSStatus? {
    let probeAccount = "gateopener-probe"
    var addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: probeAccount,
        kSecValueData as String: Data("probe".utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
    ]
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    // Clean up regardless of outcome.
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: probeAccount
    ]
    SecItemDelete(deleteQuery as CFDictionary)
    addQuery.removeAll()

    if status == errSecSuccess {
        return nil
    }
    if isEnvironmentUnavailableStatus(status) {
        return status
    }
    // Unexpected status (e.g. duplicate from a previous crashed run) —
    // treat as available; the real test will surface any genuine problem.
    return nil
}

/// Unique per-test-run service string so keychain tests never collide with
/// the production app or with each other/prior runs.
private func uniqueTestService() -> String {
    "ie.boboco.GateOpener.test.\(UUID().uuidString)"
}

@Test func keychainRoundTripsCredentials() throws {
    let service = uniqueTestService()
    guard probeKeychainUnavailableStatus(service: service) == nil else {
        // Keychain unavailable in this environment (unsigned SwiftPM test
        // binary, headless CI, etc.) — skip rather than fail or hang.
        return
    }
    let store = KeychainCredentialStore(service: service)
    defer {
        try? store.deleteCredentials()
        try? store.deleteTokens()
    }

    #expect(try store.loadCredentials() == nil)
    try store.saveCredentials(username: "alice", password: "s3cret")
    let loaded = try store.loadCredentials()
    #expect(loaded?.username == "alice")
    #expect(loaded?.password == "s3cret")
}

@Test func keychainOverwriteCredentialsSecondPasswordWins() throws {
    let service = uniqueTestService()
    guard probeKeychainUnavailableStatus(service: service) == nil else {
        return
    }
    let store = KeychainCredentialStore(service: service)
    defer {
        try? store.deleteCredentials()
        try? store.deleteTokens()
    }

    try store.saveCredentials(username: "alice", password: "first-password")
    try store.saveCredentials(username: "alice", password: "second-password")
    let loaded = try store.loadCredentials()
    #expect(loaded?.password == "second-password")
}

@Test func keychainRoundTripsTokens() throws {
    let service = uniqueTestService()
    guard probeKeychainUnavailableStatus(service: service) == nil else {
        return
    }
    let store = KeychainCredentialStore(service: service)
    defer {
        try? store.deleteCredentials()
        try? store.deleteTokens()
    }

    #expect(try store.loadTokens() == nil)
    let tokens = TokenSet(
        accessToken: "access-xyz",
        refreshToken: "refresh-xyz",
        expiresAt: Date(timeIntervalSince1970: 2_000_000),
        tokenType: "Bearer"
    )
    try store.saveTokens(tokens)
    #expect(try store.loadTokens() == tokens)
}

@Test func keychainDeleteCredentialsThenLoadReturnsNil() throws {
    let service = uniqueTestService()
    guard probeKeychainUnavailableStatus(service: service) == nil else {
        return
    }
    let store = KeychainCredentialStore(service: service)
    defer {
        try? store.deleteCredentials()
        try? store.deleteTokens()
    }

    try store.saveCredentials(username: "alice", password: "pw")
    try store.deleteCredentials()
    #expect(try store.loadCredentials() == nil)
}

@Test func keychainDeleteNonexistentIsNoOp() throws {
    let service = uniqueTestService()
    guard probeKeychainUnavailableStatus(service: service) == nil else {
        return
    }
    let store = KeychainCredentialStore(service: service)

    // Nothing has ever been saved for this fresh, unique service — deleting
    // must not throw.
    try store.deleteCredentials()
    try store.deleteTokens()
    #expect(try store.loadCredentials() == nil)
    #expect(try store.loadTokens() == nil)
}
