import Foundation
import Security

/// The single, canonical place errors are mapped to short, human-readable
/// strings suitable for display (a menu-bar tooltip/notification, an inline
/// form error, a lock-screen dialog). Both `short(for:)` and `signIn(for:)`
/// share the keychain-interaction and network branches below; the only
/// difference between them is wording for the sign-in-specific context
/// (`iOS/App/SignInView.swift`), where nothing is being "opened" yet.
///
/// Structurally, neither function ever interpolates the underlying error's
/// associated values into the returned string — never a raw `Error`
/// description, which could contain a URL, status body fragment, token, or
/// other implementation detail unsuitable for end-user display.
public enum GateErrorMessage {
    /// The generic short mapping used everywhere an error needs to be
    /// summarized as "the gate could not be opened/refreshed/updated" —
    /// the macOS app (`Sources/GateOpener/SettingsView.swift`), the iOS
    /// Settings screen's lock-screen-accessibility toggle
    /// (`iOS/App/SettingsView.swift`), and `GateController.shortMessage(for:)`
    /// (kept as a one-line forwarder to this function so its existing
    /// tests keep passing).
    public static func short(for error: Error) -> String {
        if let comelitError = error as? ComelitError {
            switch comelitError {
            case .invalidCredentials:
                return "Wrong username or password"
            case .network, .server, .missingRefreshToken:
                return "Could not reach the gate"
            case .decoding:
                return "Could not reach the gate"
            }
        }
        if let gateClientError = error as? GateClientError {
            switch gateClientError {
            case .noEndpointsFound, .noGateFound:
                return "No gate found"
            }
        }
        if let keychainMessage = keychainInteractionMessage(for: error) {
            return keychainMessage
        }
        // Unknown error type: a generic short message, never the raw
        // description (which could contain a URL, status body fragment, or
        // other implementation detail unsuitable for end-user display).
        return "Could not open the gate"
    }

    /// The sign-in-specific mapping used by `iOS/App/SignInView.swift`.
    /// Deliberately does NOT match `short(for:)` verbatim: the wording here
    /// is tailored to the sign-in context.
    public static func signIn(for error: Error) -> String {
        if let comelitError = error as? ComelitError {
            switch comelitError {
            case .invalidCredentials:
                return "Wrong username or password"
            case .network:
                return "Can't reach Comelit. Check your connection and try again."
            case .server, .missingRefreshToken, .decoding:
                return "Sign-in failed. Please try again."
            }
        }
        if let gateClientError = error as? GateClientError {
            switch gateClientError {
            case .noEndpointsFound, .noGateFound:
                return "No gate found on this account"
            }
        }
        if let keychainMessage = keychainInteractionMessage(for: error) {
            return keychainMessage
        }
        // `URLError` (offline, timeout, host not found, etc.) surfaces
        // directly from `URLSession` rather than being wrapped in
        // `ComelitError.network` in every code path, so it needs its own
        // check here to land on the network message rather than the generic
        // sign-in fallback below.
        if error is URLError {
            return "Can't reach Comelit. Check your connection and try again."
        }
        return "Sign-in failed. Please try again."
    }

    /// `errSecInteractionNotAllowed` (-25308): the keychain item's
    /// accessibility class requires the device to have been unlocked (see
    /// `KeychainAccessibility`), but the current process cannot prompt
    /// for/perform that interaction right now — this is the status a
    /// locked-device App Intent / widget invocation (or the iOS Settings
    /// screen's lock-screen-accessibility toggle, which rewrites keychain
    /// items in place) surfaces when it tries to read/write
    /// credentials/tokens before first unlock. Mapped to an explicit,
    /// actionable message rather than falling through to either function's
    /// generic fallback. Shared by both `short(for:)` and `signIn(for:)`
    /// since the wording is identical in both contexts.
    private static func keychainInteractionMessage(for error: Error) -> String? {
        guard let keychainError = error as? KeychainError else { return nil }
        switch keychainError {
        case .loadFailed(let status), .saveFailed(let status), .deleteFailed(let status):
            if status == errSecInteractionNotAllowed {
                return "Unlock iPhone to open the gate"
            }
        case .decodeFailed:
            break
        }
        return nil
    }
}
