import Foundation
import GateOpenerCore

// MARK: - Test doubles shared across the iOS unit-test bundle (bead gateopener-672.18)
//
// None of these ever touch the real Keychain access group
// (`SharedContainer.keychainAccessGroup`) or the real shared `UserDefaults`
// app-group suite: every test in this bundle constructs its own throwaway
// `UserDefaults(suiteName:)` and an in-memory `CredentialStoring` fake, per
// this bead's EDGE CASES.

/// In-memory `CredentialStoring` fake. Never touches the Keychain.
final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: (username: String, password: String)?
    private var tokens: TokenSet?

    func saveCredentials(username: String, password: String) throws {
        lock.lock(); defer { lock.unlock() }
        credentials = (username, password)
    }

    func loadCredentials() throws -> (username: String, password: String)? {
        lock.lock(); defer { lock.unlock() }
        return credentials
    }

    func deleteCredentials() throws {
        lock.lock(); defer { lock.unlock() }
        credentials = nil
    }

    func saveTokens(_ tokens: TokenSet) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    func loadTokens() throws -> TokenSet? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    func deleteTokens() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}

/// Fake `GateOpening`: never touches the network. `open(endpointId:)`
/// either succeeds instantly or throws `FakeGateOpeningError.forcedFailure`,
/// and every call is counted so tests can assert call counts directly
/// (rather than only inferring them from resulting state).
final class FakeGateOpening: GateOpening, @unchecked Sendable {
    enum FakeGateOpeningError: Error { case forcedFailure }

    private let lock = NSLock()
    private var _openCallCount = 0
    private var _discoverCallCount = 0

    var shouldSucceed: Bool = true
    var discoverResult: [Endpoint] = []

    var openCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _openCallCount
    }

    var discoverCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _discoverCallCount
    }

    /// Synchronous helper so `NSLock.lock()`/`unlock()` are never called
    /// directly inside an `async` function body — Swift 6 strict
    /// concurrency flags that as "unavailable from asynchronous contexts".
    private func recordDiscoverCall() -> [Endpoint] {
        lock.lock(); defer { lock.unlock() }
        _discoverCallCount += 1
        return discoverResult
    }

    private func recordOpenCall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _openCallCount += 1
        return shouldSucceed
    }

    func discover(aptId: String?) async throws -> [Endpoint] {
        recordDiscoverCall()
    }

    func open(endpointId: String) async throws {
        guard recordOpenCall() else {
            throw FakeGateOpeningError.forcedFailure
        }
    }
}

/// Fake `TokenResolving`: never touches the network or the Keychain.
final class FakeTokenResolving: TokenResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var shouldThrowNotConfigured = false

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    /// Synchronous helper — see `FakeGateOpening`'s doc comment on why
    /// `lock`/`unlock` must not be called directly inside `async` bodies.
    private func recordCall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
        return shouldThrowNotConfigured
    }

    func accessToken() async throws -> String {
        if recordCall() {
            throw TokenManagerError.notConfigured
        }
        return "fake-access-token"
    }
}

/// Fake `ReachabilityProviding`, always reporting a fixed value and never
/// invoking its change handler on its own (tests that need a live flip call
/// `fireChange(_:)` explicitly).
final class FakeReachabilityProviding: ReachabilityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?

    var isReachable: Bool

    init(isReachable: Bool) {
        self.isReachable = isReachable
    }

    func setOnChange(_ handler: (@Sendable (Bool) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func fireChange(_ reachable: Bool) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(reachable)
    }
}

/// Thread-safe recorder of `WidgetSnapshot.Phase` values, used to assert
/// snapshot write ORDER (not just the final value) — mirrors
/// `Tests/GateOpenerCoreTests/OpenGateFlowTests.swift`'s `PhaseRecorder`.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [WidgetSnapshot.Phase?] = []

    func record(_ phase: WidgetSnapshot.Phase?) {
        lock.lock(); defer { lock.unlock() }
        _phases.append(phase)
    }

    var phases: [WidgetSnapshot.Phase?] {
        lock.lock(); defer { lock.unlock() }
        return _phases
    }
}

/// Thread-safe call counter.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

/// Builds a throwaway `UserDefaults` suite, and returns a cleanup closure
/// that removes the persistent domain — call this in every test's
/// `defer`/teardown so no test pollutes another test or the real app
/// domain. Never the real shared app-group suite.
func makeInMemoryDefaults(function: String = #function) -> (defaults: UserDefaults, cleanup: () -> Void) {
    let suiteName = "ie.boboco.GateOpener.iOSTests.\(function).\(UUID())"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Failed to create UserDefaults suite for testing")
    }
    let cleanup = {
        defaults.removePersistentDomain(forName: suiteName)
    }
    return (defaults, cleanup)
}
