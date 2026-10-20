import Foundation
import Testing
@testable import GateOpenerCore

/// Each test notes (REMOVAL) what breaking would make it fail.
struct WatchProvisioningPayloadTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSuite() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let name = "ie.boboco.GateOpener.tests.\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { fatalError("suite") }
        return (d, {
            d.removePersistentDomain(forName: name)
            UserDefaults().removeSuite(named: name)
        })
    }

    private func payload(issuedAt: Date) -> WatchProvisioningPayload {
        WatchProvisioningPayload(
            username: "u@example.com", password: "pw", selectedEndpointId: "ep1",
            selectedEndpointName: "Front", aptId: "apt9",
            cachedGates: [Endpoint(endpointId: "ep1", friendlyName: "Front", capabilities: ["a"], displayCategories: ["b"])],
            issuedAt: issuedAt)
    }

    // REMOVAL: dropping any field from toContext/fromContext breaks equality.
    @Test func roundTripProvision() {
        let m = WatchProvisioningMessage.provision(payload(issuedAt: t0))
        #expect(WatchProvisioningMessage.fromContext(m.toContext()) == m)
    }

    // REMOVAL: dropping the signedOut kind/issuedAt encoding makes this nil/unequal.
    @Test func roundTripSignedOut() {
        let m = WatchProvisioningMessage.signedOut(issuedAt: t0)
        #expect(WatchProvisioningMessage.fromContext(m.toContext()) == m)
    }

    // REMOVAL: without the version/kind guards an empty dict would not be nil.
    @Test func emptyDictIsNil() {
        #expect(WatchProvisioningMessage.fromContext([:]) == nil)
    }

    // REMOVAL: dropping the version check lets a v2 dict decode.
    @Test func unknownVersionIsNil() {
        var d = WatchProvisioningMessage.provision(payload(issuedAt: t0)).toContext()
        d[WatchProvisioningMessage.Keys.version] = 2
        #expect(WatchProvisioningMessage.fromContext(d) == nil)
    }

    // REMOVAL: dropping the kind switch default lets unknown kinds decode.
    @Test func unknownKindIsNil() {
        var d = WatchProvisioningMessage.provision(payload(issuedAt: t0)).toContext()
        d[WatchProvisioningMessage.Keys.kind] = "bogus"
        #expect(WatchProvisioningMessage.fromContext(d) == nil)
    }

    // REMOVAL: making password optional would decode a provision without it.
    @Test func missingPasswordIsNil() {
        var d = WatchProvisioningMessage.provision(payload(issuedAt: t0)).toContext()
        d[WatchProvisioningMessage.Keys.password] = nil
        #expect(WatchProvisioningMessage.fromContext(d) == nil)
    }

    // REMOVAL: returning nil/propagating on bad JSON instead of [] fails this.
    @Test func corruptCachedGatesDegradesToEmpty() {
        var d = WatchProvisioningMessage.provision(payload(issuedAt: t0)).toContext()
        d[WatchProvisioningMessage.Keys.cachedGates] = Data("not json".utf8)
        guard case .provision(let p)? = WatchProvisioningMessage.fromContext(d) else {
            Issue.record("expected provision"); return
        }
        #expect(p.cachedGates == [])
        #expect(p.username == "u@example.com")
    }

    // REMOVAL: always returning .provision fails; also a non-plist value would fail.
    @Test func toContextOnlyUsesPlistTypes() {
        let d = WatchProvisioningMessage.provision(payload(issuedAt: t0)).toContext()
        #expect(PropertyListSerialization.propertyList(d, isValidFor: .binary))
    }

    // REMOVAL: returning .provision regardless of credentials fails this.
    @Test func buildWithoutCredentialsIsSignedOut() throws {
        let (defaults, cleanup) = makeSuite(); defer { cleanup() }
        let m = try WatchProvisioningMessage.build(
            settings: AppSettings(defaults: defaults), credentialStore: MockCredentialStore(), now: t0)
        #expect(m == .signedOut(issuedAt: t0))
    }

    // REMOVAL: not copying a settings field into the payload fails equality.
    @Test func buildWithCredentialsMirrorsSettings() throws {
        let (defaults, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: defaults)
        let p = payload(issuedAt: t0)
        s.selectedEndpointId = p.selectedEndpointId
        s.selectedEndpointName = p.selectedEndpointName
        s.aptId = p.aptId
        s.cachedGates = p.cachedGates
        let store = MockCredentialStore()
        try store.saveCredentials(username: p.username, password: p.password)
        let m = try WatchProvisioningMessage.build(settings: s, credentialStore: store, now: t0)
        #expect(m == .provision(p))
    }

    // REMOVAL: skipping saveCredentials/deleteTokens/settings writes fails an assertion.
    @Test func applyProvisionConfiguresAndDeletesTokens() throws {
        let (defaults, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: defaults)
        let store = MockCredentialStore()
        try store.saveTokens(TokenSet(accessToken: "a", refreshToken: "r", expiresAt: t0, tokenType: "Bearer"))
        let m = WatchProvisioningMessage.provision(payload(issuedAt: t0))
        #expect(try m.apply(to: s, credentialStore: store, previouslyApplied: nil))
        #expect(s.isConfigured)
        #expect(s.selectedEndpointName == "Front")
        #expect(s.aptId == "apt9")
        #expect(s.cachedGates.count == 1)
        #expect(try store.loadCredentials()?.username == "u@example.com")
        #expect(try store.loadCredentials()?.password == "pw")
        #expect(try store.loadTokens() == nil)
        // idempotent
        #expect(try m.apply(to: s, credentialStore: store, previouslyApplied: nil))
        #expect(s.isConfigured)
    }

    // REMOVAL: skipping deleteCredentials or the settings clears fails this.
    @Test func applySignedOutClearsEverything() throws {
        let (defaults, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: defaults)
        let store = MockCredentialStore()
        let prov = WatchProvisioningMessage.provision(payload(issuedAt: t0))
        _ = try prov.apply(to: s, credentialStore: store, previouslyApplied: nil)
        try store.saveTokens(TokenSet(accessToken: "a", refreshToken: nil, expiresAt: t0, tokenType: "Bearer"))
        let out = WatchProvisioningMessage.signedOut(issuedAt: t0.addingTimeInterval(10))
        #expect(try out.apply(to: s, credentialStore: store, previouslyApplied: t0))
        #expect(!s.isConfigured)
        #expect(s.aptId == nil)
        #expect(s.selectedEndpointName == nil)
        #expect(s.cachedGates == [])
        #expect(try store.loadCredentials() == nil)
        #expect(try store.loadTokens() == nil)
        // idempotent
        #expect(try out.apply(to: s, credentialStore: store, previouslyApplied: nil))
        #expect(!s.isConfigured)
    }

    // REMOVAL: dropping the guard or using < instead of <= fails older/equal cases.
    @Test func issuedAtGuard() throws {
        let (defaults, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: defaults)
        let store = MockCredentialStore()
        let m = WatchProvisioningMessage.provision(payload(issuedAt: t0))
        #expect(try m.apply(to: s, credentialStore: store, previouslyApplied: t0.addingTimeInterval(1)) == false)
        #expect(try m.apply(to: s, credentialStore: store, previouslyApplied: t0) == false)
        #expect(!s.isConfigured)
        #expect(try store.loadCredentials() == nil)
        #expect(try m.apply(to: s, credentialStore: store, previouslyApplied: t0.addingTimeInterval(-1)) == true)
        #expect(s.isConfigured)
    }

    // REMOVAL: omitting the key from Keys.all leaves the date after reset().
    @Test func resetClearsWatchProvisioningAppliedAt() {
        let (defaults, cleanup) = makeSuite(); defer { cleanup() }
        let s = AppSettings(defaults: defaults)
        s.watchProvisioningAppliedAt = t0
        #expect(s.watchProvisioningAppliedAt == t0)
        s.reset()
        #expect(s.watchProvisioningAppliedAt == nil)
    }
}
