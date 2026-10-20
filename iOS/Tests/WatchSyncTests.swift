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

    // Fails if sessionStateDidChange stops moving a non-activated session to .pending.
    @Test func stateChangeWhileInactiveSetsPending() {
        let session = FakeWatchSession()
        let sync = makeSync(session: session)
        sync.pushNow(reason: "test")
        #expect(sync.status != .pending)
        session.activationState = .inactive
        session.fireStateChange()
        #expect(sync.status == .pending)
        #expect(session.contexts.count == 1)
    }

    // Fails if sessionStateDidChange ignores the isSupported guard.
    @Test func stateChangeUnsupportedSetsUnsupported() {
        let session = FakeWatchSession()
        let sync = makeSync(session: session)
        session.isSupported = false
        session.fireStateChange()
        #expect(sync.status == .unsupported)
        #expect(session.contexts.isEmpty)
    }

    // Fails if a state change does not re-evaluate pairing (unpaired -> paired sends).
    @Test func stateChangePairingMovesNotPairedToSent() {
        let session = FakeWatchSession()
        session.isPaired = false
        let sync = makeSync(session: session)
        session.fireStateChange()
        #expect(sync.status == .notPaired)
        session.isPaired = true
        session.fireStateChange()
        guard case .sent = sync.status else {
            Issue.record("expected .sent, got \(sync.status)")
            return
        }
        #expect(session.contexts.count == 1)
    }

    // Fails if a lagging isWatchAppInstalled is not re-evaluated on state change.
    @Test func installLagResolvesOnStateChange() {
        let session = FakeWatchSession()
        session.isWatchAppInstalled = false
        let sync = makeSync(session: session)
        session.fireStateChange()
        #expect(sync.status == .watchAppNotInstalled)
        session.isWatchAppInstalled = true
        session.fireStateChange()
        guard case .sent = sync.status else {
            Issue.record("expected .sent, got \(sync.status)")
            return
        }
    }

    // Fails if a successful retry leaves the stale .failed status.
    @Test func failedThenSuccessfulPushBecomesSent() {
        let session = FakeWatchSession()
        session.updateError = FakeWatchSession.PushError()
        let sync = makeSync(session: session)
        sync.pushNow(reason: "test")
        guard case .failed = sync.status else {
            Issue.record("expected .failed before retry, got \(sync.status)")
            return
        }
        session.updateError = nil
        sync.pushNow(reason: "settings")
        guard case .sent = sync.status else {
            Issue.record("expected .sent, got \(sync.status)")
            return
        }
    }

    // Fails if the store is captured at init instead of read on each push.
    @Test func credentialStoreIsReadLazilyOnEachPush() throws {
        final class Box { var store: any CredentialStoring; init(store: any CredentialStoring) { self.store = store } }
        let first = InMemoryCredentialStore()
        try first.saveCredentials(username: "alice", password: "secret")
        let second = InMemoryCredentialStore()
        try second.saveCredentials(username: "bob", password: "pw")
        let box = Box(store: first)
        let session = FakeWatchSession()
        let defaults = UserDefaults(suiteName: "WatchSyncTests-\(UUID().uuidString)")!
        let sync = WatchSync(session: session, appSettings: AppSettings(defaults: defaults), credentialStoreProvider: { box.store })
        sync.pushNow(reason: "a")
        box.store = second
        sync.pushNow(reason: "b")
        #expect(session.contexts.map { $0["username"] as? String } == ["alice", "bob"])
    }

    // Fails if sendFromSettings skips start() or the deferred push is lost on activation.
    @Test func sendFromSettingsActivatesWhenNotActivatedThenPushesOnActivation() {
        let session = FakeWatchSession()
        session.activationState = .notActivated
        let sync = makeSync(session: session)
        sync.sendFromSettings()
        #expect(session.activateCallCount == 1)
        #expect(session.contexts.isEmpty)
        #expect(sync.status == .pending)
        session.activationState = .activated
        session.fireStateChange()
        #expect(session.contexts.count == 1)
        #expect(session.contexts.first?["kind"] as? String == "provision")
    }

    // Fails if sendFromSettings activates needlessly or does not push immediately.
    @Test func sendFromSettingsWhenActivatedPushesImmediately() {
        let session = FakeWatchSession()
        let sync = makeSync(session: session)
        sync.sendFromSettings()
        #expect(session.activateCallCount == 0)
        #expect(session.contexts.count == 1)
    }

    // Fails if the pending wording ignores session activation.
    @Test func pendingLineDistinguishesWaitingFromSending() {
        let session = FakeWatchSession()
        session.activationState = .notActivated
        let sync = makeSync(session: session)
        #expect(!sync.isSessionActivated)
        #expect(WatchSyncSection.pendingLine(sessionActivated: sync.isSessionActivated) == "Waiting for your watch\u{2026}")
        session.activationState = .activated
        #expect(WatchSyncSection.pendingLine(sessionActivated: sync.isSessionActivated) == "Sending\u{2026}")
    }

    private func makeStore() -> WatchHistoryStore {
        WatchHistoryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-sync-\(UUID().uuidString).json"))
    }

    private func makeSync(session: FakeWatchSession, history: WatchHistoryStore) -> WatchSync {
        let defaults = UserDefaults(suiteName: "WatchSyncTests-\(UUID().uuidString)")!
        return WatchSync(
            session: session, appSettings: AppSettings(defaults: defaults),
            credentialStore: InMemoryCredentialStore(), watchHistoryStore: history
        )
    }

    // Fails if the session's onUserInfo is not wired to the store (nothing written).
    @Test func watchHistoryUserInfoIsWrittenToStore() {
        let session = FakeWatchSession()
        let history = makeStore()
        let sync = makeSync(session: session, history: history)
        session.deliver(userInfo: ["kind": "watchHistory", "text": "press log", "sentAt": Date()])
        #expect(history.transfers().map(\.text) == ["press log"])
        _ = sync
    }

    // Fails if the cap of 5 or newest-first ordering is dropped.
    @Test func watchHistoryKeepsFiveNewestFirst() {
        let session = FakeWatchSession()
        let history = makeStore()
        let sync = makeSync(session: session, history: history)
        for i in 1...6 {
            session.deliver(userInfo: ["kind": "watchHistory", "text": "t\(i)", "sentAt": Date(timeIntervalSince1970: Double(i))])
        }
        #expect(history.transfers().map(\.text) == ["t6", "t5", "t4", "t3", "t2"])
        _ = sync
    }

    // Fails if the kind check is removed (unrelated userInfo would be stored).
    @Test func unrelatedUserInfoIsIgnored() {
        let session = FakeWatchSession()
        let history = makeStore()
        let sync = makeSync(session: session, history: history)
        session.deliver(userInfo: ["kind": "something", "text": "nope"])
        #expect(history.transfers().isEmpty)
        _ = sync
    }
}
