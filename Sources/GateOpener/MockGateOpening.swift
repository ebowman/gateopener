import Foundation
import GateOpenerCore

/// A `GateOpening` conformer that records calls instead of touching the
/// network, used ONLY when `GATEOPENER_MOCK=1` is set in the environment.
///
/// This exists so left-click/right-click discrimination can be verified
/// (bead gateopener-4ub.8 done-criteria: "a left-click demonstrably calls
/// openGate() exactly once; a right-click does NOT") WITHOUT ever opening
/// the real physical gate. Never wire this in unless
/// `ProcessInfo.processInfo.environment["GATEOPENER_MOCK"] == "1"`.
actor MockGateOpening: GateOpening {
    /// Number of times `open(endpointId:)` has actually been invoked.
    private(set) var openCallCount = 0

    /// The endpoint id(s) passed to `open(endpointId:)`, in call order.
    private(set) var openedEndpointIds: [String] = []

    /// A fixed, obviously-fake endpoint so `.needsSetup` never appears in
    /// mock mode (mock mode exists to test the click plumbing, not the
    /// first-time-setup flow).
    static let mockEndpoint = Endpoint(
        endpointId: "MOCK_APT_MOCK#OD#MOCKGATE",
        friendlyName: "Mock Gate (verification mode)",
        capabilities: ["PowerController"],
        displayCategories: ["LOCK_GENERIC"]
    )

    func discover(aptId: String?) async throws -> [Endpoint] {
        [Self.mockEndpoint]
    }

    func open(endpointId: String) async throws {
        openCallCount += 1
        openedEndpointIds.append(endpointId)
        // Simulate a short, realistic-ish delay so the `.opening` UI state
        // is visibly observable, without the ~2s of a real call.
        try? await Task.sleep(for: .milliseconds(400))
    }
}

/// A `TokenResolving` conformer that never touches the network or keychain,
/// used alongside `MockGateOpening` in `GATEOPENER_MOCK=1` mode.
actor MockTokenResolving: TokenResolving {
    func accessToken() async throws -> String {
        "mock-access-token"
    }
}

/// A `CredentialStoring` conformer backed by in-memory state only, used
/// alongside `MockGateOpening` in `GATEOPENER_MOCK=1` mode so no real
/// keychain item is ever touched during verification.
final class MockCredentialStore: CredentialStoring, @unchecked Sendable {
    private var credentials: (username: String, password: String)?
    private var tokens: TokenSet?

    init() {
        // Pre-populated so the mock controller starts in `.idle`, not
        // `.needsSetup` — mock mode is for verifying click plumbing.
        credentials = (username: "mock-user", password: "mock-password")
    }

    func saveCredentials(username: String, password: String) throws {
        credentials = (username: username, password: password)
    }

    func loadCredentials() throws -> (username: String, password: String)? {
        credentials
    }

    func deleteCredentials() throws {
        credentials = nil
    }

    func saveTokens(_ tokens: TokenSet) throws {
        self.tokens = tokens
    }

    func loadTokens() throws -> TokenSet? {
        tokens
    }

    func deleteTokens() throws {
        tokens = nil
    }
}
