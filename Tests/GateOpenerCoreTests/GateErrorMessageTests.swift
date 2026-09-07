import Foundation
import Testing
@testable import GateOpenerCore

// MARK: - Test doubles

private struct WeirdError: Error {}

// MARK: - GateErrorMessage.short(for:)
//
// This is the canonical mapping used by the macOS app
// (`Sources/GateOpener/SettingsView.swift`), the iOS Settings screen's
// lock-screen-accessibility toggle (`iOS/App/SettingsView.swift`), and
// `GateController.shortMessage(for:)` (a one-line forwarder, covered by its
// own smoke test in `GateControllerTests.swift`).

@Test func shortUnknownErrorTypeMapsToGenericMessage() throws {
    let message = GateErrorMessage.short(for: WeirdError())
    #expect(message == "Could not open the gate")
}

@Test func shortNoGateFoundMapsToNoGateFoundMessage() throws {
    let message = GateErrorMessage.short(for: GateClientError.noGateFound)
    #expect(message == "No gate found")
}

@Test func shortNoEndpointsFoundMapsToNoGateFoundMessage() throws {
    let message = GateErrorMessage.short(for: GateClientError.noEndpointsFound)
    #expect(message == "No gate found")
}

@Test func shortInvalidCredentialsMapsToWrongUsernameOrPassword() throws {
    let message = GateErrorMessage.short(for: ComelitError.invalidCredentials)
    #expect(message == "Wrong username or password")
}

@Test func shortNetworkServerAndMissingRefreshTokenMapToCouldNotReachTheGate() throws {
    #expect(GateErrorMessage.short(for: ComelitError.network("offline")) == "Could not reach the gate")
    #expect(GateErrorMessage.short(for: ComelitError.server(status: 500, body: "boom")) == "Could not reach the gate")
    #expect(GateErrorMessage.short(for: ComelitError.missingRefreshToken) == "Could not reach the gate")
}

@Test func shortDecodingMapsToCouldNotReachTheGate() throws {
    let message = GateErrorMessage.short(for: ComelitError.decoding("bad json"))
    #expect(message == "Could not reach the gate")
}

/// `URLError` is not special-cased by `short(for:)` (unlike `signIn(for:)`
/// below) — it falls through to the generic fallback, since the
/// gate-opening/refresh call sites that use `short(for:)` do not
/// distinguish "can't reach Comelit" from any other unknown failure the
/// way the sign-in screen does.
@Test func shortURLErrorMapsToGenericFallbackNotNetworkWording() throws {
    let message = GateErrorMessage.short(for: URLError(.notConnectedToInternet))
    #expect(message == "Could not open the gate")
}

/// `errSecInteractionNotAllowed` (-25308) is the status a locked-device
/// App Intent invocation (or the iOS Settings screen's lock-screen toggle,
/// rewriting keychain items in place) surfaces when it tries to
/// read/write a keychain item before first unlock (bead gateopener-672.13
/// step 6). This must map to an explicit, actionable message rather than
/// the generic fallback.
@Test func shortKeychainInteractionNotAllowedMapsToUnlockMessage() throws {
    let loadMessage = GateErrorMessage.short(for: KeychainError.loadFailed(status: errSecInteractionNotAllowed))
    #expect(loadMessage == "Unlock iPhone to open the gate")

    let saveMessage = GateErrorMessage.short(for: KeychainError.saveFailed(status: errSecInteractionNotAllowed))
    #expect(saveMessage == "Unlock iPhone to open the gate")

    let deleteMessage = GateErrorMessage.short(for: KeychainError.deleteFailed(status: errSecInteractionNotAllowed))
    #expect(deleteMessage == "Unlock iPhone to open the gate")
}

/// A DIFFERENT `KeychainError` status must NOT be mapped to the unlock
/// message — distinguishes this from a vacuous "any KeychainError ->
/// unlock message" mapping (mutation check: flipping the `==
/// errSecInteractionNotAllowed` guard to always-true would make this
/// test fail).
@Test func shortKeychainOtherStatusDoesNotMapToUnlockMessage() throws {
    let message = GateErrorMessage.short(for: KeychainError.loadFailed(status: errSecItemNotFound))
    #expect(message != "Unlock iPhone to open the gate")
    #expect(message == "Could not open the gate")
}

/// `.decodeFailed` is a `KeychainError` case with no associated `OSStatus`,
/// so it can never match the unlock-message branch — falls through to the
/// generic fallback.
@Test func shortKeychainDecodeFailedMapsToGenericFallback() throws {
    let message = GateErrorMessage.short(for: KeychainError.decodeFailed)
    #expect(message == "Could not open the gate")
}

// MARK: - GateErrorMessage.signIn(for:)
//
// The sign-in-specific mapping used by `iOS/App/SignInView.swift`.
// Deliberately different wording from `short(for:)` above for several
// cases (nothing is being "opened" yet on the sign-in screen).

@Test func signInInvalidCredentialsMapsToWrongUsernameOrPassword() throws {
    let message = GateErrorMessage.signIn(for: ComelitError.invalidCredentials)
    #expect(message == "Wrong username or password")
}

@Test func signInNetworkMapsToCantReachComelitWording() throws {
    let message = GateErrorMessage.signIn(for: ComelitError.network("offline"))
    #expect(message == "Can't reach Comelit. Check your connection and try again.")
}

@Test func signInServerMissingRefreshTokenAndDecodingMapToSignInFailedWording() throws {
    #expect(GateErrorMessage.signIn(for: ComelitError.server(status: 500, body: "boom")) == "Sign-in failed. Please try again.")
    #expect(GateErrorMessage.signIn(for: ComelitError.missingRefreshToken) == "Sign-in failed. Please try again.")
    #expect(GateErrorMessage.signIn(for: ComelitError.decoding("bad json")) == "Sign-in failed. Please try again.")
}

@Test func signInNoGateFoundMapsToNoGateFoundOnThisAccountWording() throws {
    #expect(GateErrorMessage.signIn(for: GateClientError.noGateFound) == "No gate found on this account")
    #expect(GateErrorMessage.signIn(for: GateClientError.noEndpointsFound) == "No gate found on this account")
}

/// `URLError` (offline, timeout, host not found, etc.) surfaces directly
/// from `URLSession` rather than being wrapped in `ComelitError.network`
/// in every code path, so `signIn(for:)` special-cases it directly to land
/// on the same network wording rather than the generic sign-in fallback.
/// Mutation check: deleting this branch would make the message fall
/// through to "Sign-in failed. Please try again." instead.
@Test func signInURLErrorMapsToCantReachComelitWording() throws {
    let message = GateErrorMessage.signIn(for: URLError(.notConnectedToInternet))
    #expect(message == "Can't reach Comelit. Check your connection and try again.")
}

@Test func signInUnknownErrorTypeMapsToSignInFailedWording() throws {
    let message = GateErrorMessage.signIn(for: WeirdError())
    #expect(message == "Sign-in failed. Please try again.")
}

/// `signIn(for:)` shares the same keychain-interaction branch as
/// `short(for:)` — the wording is identical in both contexts.
@Test func signInKeychainInteractionNotAllowedMapsToUnlockMessage() throws {
    let message = GateErrorMessage.signIn(for: KeychainError.loadFailed(status: errSecInteractionNotAllowed))
    #expect(message == "Unlock iPhone to open the gate")
}

/// A DIFFERENT `KeychainError` status must NOT be mapped to the unlock
/// message under `signIn(for:)` either (mutation check: flipping the `==
/// errSecInteractionNotAllowed` guard to always-true would make this test
/// fail).
@Test func signInKeychainOtherStatusDoesNotMapToUnlockMessage() throws {
    let message = GateErrorMessage.signIn(for: KeychainError.loadFailed(status: errSecItemNotFound))
    #expect(message != "Unlock iPhone to open the gate")
    #expect(message == "Sign-in failed. Please try again.")
}
