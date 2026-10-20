import Foundation
import Testing
import GateOpenerCore
@testable import GateOpener

/// Credential store whose `loadCredentials` always throws.
private final class ThrowingCredentialStore: CredentialStoring, @unchecked Sendable {
    struct Boom: Error {}
    func saveCredentials(username: String, password: String) throws {}
    func loadCredentials() throws -> (username: String, password: String)? { throw Boom() }
    func deleteCredentials() throws {}
    func saveTokens(_ tokens: TokenSet) throws {}
    func loadTokens() throws -> TokenSet? { nil }
    func deleteTokens() throws {}
}

@MainActor
struct WatchSyncTests {
    private func makeSync(
        session: FakeWatchSession,
        store: any CredentialStoring = {
            let s = InMemoryCredentialStore()
            try? s.saveCredentials(username: "alice", password: "secret")
            return s
        }()
    ) -> WatchSync {
        let defaults = UserDefaults(suiteName: "WatchSyncTests-\(UUID().uuidString)")!
        return WatchSync(session: session, appSettings: AppSettings(defaults: defaults), credentialStore: store)
    }

    // Fails if the isSupported guard is removed (session would be touched).
    @Test func unsupportedMakesZeroSessionCalls() {
        let session = FakeWatchSession()
        session.isSupported = false
        let sync = makeSync(session: session)
        sync.start()
        sync.pushNow(reason: "test")
        #expect(session.contexts.isEmpty)
        #expect(session.activateCallCount == 0)
        #expect(sync.status == .unsupported)
    }

    // Fails if the push is not sent, sent twice, or carries the wrong payload.
    @Test func readySessionSendsOneProvisionContext() {
        let session = FakeWatchSession()
        let sync = makeSync(session: session)
        sync.pushNow(reason: "test")
        #expect(session.contexts.count == 1)
        #expect(session.contexts.first?["kind"] as? String == "provision")
        #expect(session.contexts.first?["username"] as? String == "alice")
    }

    // Fails if the activation gate or the push-on-activation trigger (a) is removed.
    @Test func notActivatedDefersThenSendsOnActivation() {
        let session = FakeWatchSession()
        session.activationState = .notActivated
        let sync = makeSync(session: session)
        sync.pushNow(reason: "test")
        #expect(session.contexts.isEmpty)
        #expect(sync.status == .pending)
        session.activationState = .activated
        session.fireStateChange()
        #expect(session.contexts.count == 1)
        #expect(session.contexts.first?["kind"] as? String == "provision")
    }

    // Fails if sign-out does not produce a tombstone (trigger e).
    @Test func signedOutPushesSignedOutKind() throws {
        let session = FakeWatchSession()
        let store = InMemoryCredentialStore()
        let sync = makeSync(session: session, store: store)
        try store.deleteCredentials()
        sync.pushNow(reason: "sign-out")
        #expect(session.contexts.count == 1)
        #expect(session.contexts.first?["kind"] as? String == "signedOut")
        #expect(session.contexts.first?["password"] == nil)
    }

    // Fails if a throwing updateApplicationContext crashes or is not surfaced.
    @Test func updateFailureIsSwallowedAndReported() {
        let session = FakeWatchSession()
        session.updateError = FakeWatchSession.PushError()
        let sync = makeSync(session: session)
        sync.pushNow(reason: "test")
        guard case .failed = sync.status else {
            Issue.record("expected .failed, got \(sync.status)")
            return
        }
    }

    // Fails if a keychain error is turned into a .signedOut push.
    @Test func buildFailurePushesNothing() {
        let session = FakeWatchSession()
        let sync = makeSync(session: session, store: ThrowingCredentialStore())
        sync.pushNow(reason: "test")
        #expect(session.contexts.isEmpty)
        guard case .failed = sync.status else {
            Issue.record("expected .failed, got \(sync.status)")
            return
        }
    }

    // Fails if the pairing check is removed or status not updated.
    @Test func notPairedStatus() {
        let session = FakeWatchSession()
        session.isPaired = false
        let sync = makeSync(session: session)
        sync.pushNow(reason: "test")
        #expect(session.contexts.isEmpty)
        #expect(sync.status == .notPaired)
    }

    // Fails if the installed check is removed or status not updated.
    @Test func watchAppNotInstalledStatus() {
        let session = FakeWatchSession()
        session.isWatchAppInstalled = false
        let sync = makeSync(session: session)
        sync.pushNow(reason: "test")
        #expect(session.contexts.isEmpty)
        #expect(sync.status == .watchAppNotInstalled)
    }

    // Fails if status is not set to .sent with the injected clock time.
    @Test func sentStatusCarriesTimestamp() {
        let session = FakeWatchSession()
        let fixed = Date(timeIntervalSince1970: 1_000)
        let defaults = UserDefaults(suiteName: "WatchSyncTests-\(UUID().uuidString)")!
        let store = InMemoryCredentialStore()
        try? store.saveCredentials(username: "a", password: "b")
        let sync = WatchSync(session: session, appSettings: AppSettings(defaults: defaults), credentialStore: store, now: { fixed })
        sync.pushNow(reason: "test")
        #expect(sync.status == .sent(at: fixed))
    }

    // Fails if start() does not activate the session.
    @Test func startActivatesSession() {
        let session = FakeWatchSession()
        makeSync(session: session).start()
        #expect(session.activateCallCount == 1)
    }
}
