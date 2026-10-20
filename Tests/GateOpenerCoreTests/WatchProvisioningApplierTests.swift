import Foundation
import Testing
@testable import GateOpenerCore

/// Each test notes (REMOVAL) what breaking would make it fail.
struct WatchProvisioningApplierTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let name = "ie.boboco.GateOpener.tests.\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { fatalError("suite") }
        return (d, { d.removePersistentDomain(forName: name) })
    }

    private func provision(_ at: Date) -> WatchProvisioningMessage {
        .provision(WatchProvisioningPayload(
            username: "u@example.com", password: "pw", selectedEndpointId: "ep1",
            selectedEndpointName: "Front", aptId: "apt9", cachedGates: [], issuedAt: at))
    }

    // REMOVAL: dropping the empty/decode guard (or writing before it) would write or return non-nil.
    @Test func emptyContextIsNilAndWritesNothing() throws {
        let (d, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: d); let store = MockCredentialStore()
        let a = WatchProvisioningApplier(settings: s, credentialStore: store)
        #expect(a.handle(context: [:]) == nil)
        #expect(s.watchProvisioningAppliedAt == nil)
        #expect(!s.isConfigured)
        #expect(try store.loadCredentials() == nil)
    }

    // REMOVAL: not persisting appliedAt, not applying, or not returning the message fails.
    @Test func validProvisionAppliesAndPersistsIssuedAt() throws {
        let (d, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: d); let store = MockCredentialStore()
        let a = WatchProvisioningApplier(settings: s, credentialStore: store)
        let m = provision(t0)
        #expect(a.handle(context: m.toContext()) == m)
        #expect(s.watchProvisioningAppliedAt == t0)
        #expect(s.isConfigured)
        #expect(try store.loadCredentials()?.username == "u@example.com")
    }

    // REMOVAL: not persisting appliedAt makes the second delivery apply again (non-nil).
    @Test func duplicateDeliveryIsNoOp() {
        let (d, cleanup) = makeSuite(); defer { cleanup() }
        let a = WatchProvisioningApplier(settings: AppSettings(defaults: d), credentialStore: MockCredentialStore())
        let ctx = provision(t0).toContext()
        #expect(a.handle(context: ctx) != nil)
        #expect(a.handle(context: ctx) == nil)
    }

    // REMOVAL: dropping the previouslyApplied argument lets an older message overwrite newer state.
    @Test func olderIssuedAtIsIgnored() throws {
        let (d, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: d); let store = MockCredentialStore()
        let a = WatchProvisioningApplier(settings: s, credentialStore: store)
        _ = a.handle(context: provision(t0).toContext())
        let older = WatchProvisioningMessage.signedOut(issuedAt: t0.addingTimeInterval(-60))
        #expect(a.handle(context: older.toContext()) == nil)
        #expect(s.watchProvisioningAppliedAt == t0)
        #expect(try store.loadCredentials() != nil)
        #expect(s.isConfigured)
    }

    // REMOVAL: not applying the tombstone (credentials/appliedAt) fails.
    @Test func signedOutDeletesCredentialsAndAdvancesAppliedAt() throws {
        let (d, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: d); let store = MockCredentialStore()
        let a = WatchProvisioningApplier(settings: s, credentialStore: store)
        _ = a.handle(context: provision(t0).toContext())
        let out = WatchProvisioningMessage.signedOut(issuedAt: t0.addingTimeInterval(10))
        #expect(a.handle(context: out.toContext()) == out)
        #expect(try store.loadCredentials() == nil)
        #expect(!s.isConfigured)
        #expect(s.watchProvisioningAppliedAt == t0.addingTimeInterval(10))
    }

    // REMOVAL: persisting appliedAt before/without the decode guard would advance it on garbage.
    @Test func undecodableContextChangesNothing() throws {
        let (d, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: d); let store = MockCredentialStore()
        let a = WatchProvisioningApplier(settings: s, credentialStore: store)
        #expect(a.handle(context: ["v": 99, "junk": "x"]) == nil)
        #expect(s.watchProvisioningAppliedAt == nil)
        #expect(try store.loadCredentials() == nil)
    }

    // REMOVAL: persisting appliedAt before/regardless of apply success would make the retry a stale no-op.
    @Test func applyThrowingLeavesAppliedAtUnchangedAndReturnsNil() throws {
        struct Boom: Error {}
        let (d, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: d); let store = MockCredentialStore()
        store.saveCredentialsError = Boom()
        let a = WatchProvisioningApplier(settings: s, credentialStore: store)
        let ctx = provision(t0).toContext()
        #expect(a.handle(context: ctx) == nil)
        #expect(s.watchProvisioningAppliedAt == nil)
        // The next delivery retries and succeeds.
        store.saveCredentialsError = nil
        #expect(a.handle(context: ctx) != nil)
        #expect(s.watchProvisioningAppliedAt == t0)
    }

    // REMOVAL: returning false for .provision lets a re-provisioned watch keep the old account's cached token.
    @Test func provisionInvalidatesCachedToken() {
        #expect(WatchProvisioningReaction.shouldInvalidateCachedToken(for: provision(t0)))
    }

    // REMOVAL: returning false for .signedOut lets a signed-out watch keep opening with a cached token.
    @Test func signedOutInvalidatesCachedToken() {
        #expect(WatchProvisioningReaction.shouldInvalidateCachedToken(for: .signedOut(issuedAt: t0)))
    }
}
