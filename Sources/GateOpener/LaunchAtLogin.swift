import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` (bead gateopener-4ub.11).
///
/// This deliberately holds NO cached boolean: every read goes straight to
/// `SMAppService.mainApp.status`, so the Settings toggle can never drift
/// from the true registration state (e.g. if the user removed GateOpener
/// from Login Items in System Settings behind the app's back).
///
/// `register()`/`unregister()` can both throw — most commonly when the
/// bundle is unsigned, not code-signed with a stable identity, or not
/// running from a location `SMAppService` accepts (e.g. launched via
/// `swift run` with no real .app bundle, or a bundle outside
/// `/Applications`/a user-writable location `SMAppService` trusts). Callers
/// MUST catch and present `LaunchAtLoginError.userMessage` rather than a
/// raw `Error` — never crash, never show an NSError description that could
/// mention paths/entitlements irrelevant to the operator.
@MainActor
enum LaunchAtLogin {
    /// True current registration status, read fresh every call — never
    /// cached. Mirrors exactly what `SMAppService.mainApp.status` reports.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Attempts to register (or unregister) GateOpener as a login item.
    ///
    /// - Parameter enabled: `true` to register for launch-at-login, `false`
    ///   to unregister.
    /// - Throws: `LaunchAtLoginError` with a short, human-readable message
    ///   suitable for direct display — never a raw `Error`.
    static func setEnabled(_ enabled: Bool) throws(LaunchAtLoginError) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw LaunchAtLoginError.from(error, whileEnabling: enabled)
        }
    }
}

/// A short, human-readable Launch-at-Login failure. Never surfaces a raw
/// `Error`/`NSError` description to the UI.
struct LaunchAtLoginError: Error {
    let message: String

    /// Values from `ServiceManagement/SMErrors.h`. Declared as named
    /// constants rather than inline literals because the SDK enum is not
    /// exposed to Swift: an inline magic number in a `case` cannot be
    /// checked by the compiler and silently drifts. (A previous version of
    /// this file used `case 1` for "denied by user", which is wrong — the
    /// enum starts at `kSMErrorInternalFailure = 2` and denial is 11 — so a
    /// real denial was misreported as a wrong-install-location problem.)
    private enum SMErrorCode {
        static let launchDeniedByUser = 11   // kSMErrorLaunchDeniedByUser
        static let alreadyRegistered = 12    // kSMErrorAlreadyRegistered
        static let invalidSignature = 3      // kSMErrorInvalidSignature
    }

    /// Domains `SMAppService` reports these codes under. Matching on a bare
    /// code without its domain risks false positives — e.g. code 11 in
    /// `NSPOSIXErrorDomain` is EDEADLK, nothing to do with Login Items.
    private static let smErrorDomains: Set<String> = [
        "SMAppServiceErrorDomain",
        "com.apple.ServiceManagement",
        "SMErrorDomainFramework",
    ]

    /// Maps the underlying `SMAppService` failure to a clear, actionable
    /// message, inspecting BOTH the `NSError` domain and code — never the
    /// code alone. Falls back to a generic-but-actionable message rather
    /// than passing `error.localizedDescription` through, since that can
    /// read like an internal diagnostic (e.g. mentioning XPC or a path).
    ///
    /// Honesty requirement: a user denial must NOT be reported as an
    /// install-location problem. Those need opposite actions from the user,
    /// and conflating them sends them chasing the wrong fix.
    static func from(_ error: Error, whileEnabling enabling: Bool) -> LaunchAtLoginError {
        let nsError = error as NSError
        let isServiceManagementError = smErrorDomains.contains(nsError.domain)

        if isServiceManagementError {
            switch nsError.code {
            case SMErrorCode.launchDeniedByUser:
                return LaunchAtLoginError(
                    message: "Launch at Login was denied. Enable it for GateOpener in System Settings > General > Login Items."
                )
            case SMErrorCode.alreadyRegistered:
                return LaunchAtLoginError(
                    message: "GateOpener is already registered to launch at login."
                )
            case SMErrorCode.invalidSignature:
                return LaunchAtLoginError(
                    message: "Launch at Login needs a properly signed copy of GateOpener. Move it to /Applications and try again."
                )
            default:
                break
            }
        }

        // Most common real-world case in practice: the bundle is unsigned,
        // ad-hoc-signed in a way SMAppService rejects outright, or not
        // running from a stable installed location (e.g. a DMG, a
        // Downloads folder, or directly via `swift run`/`.build/`).
        if !Bundle.main.bundlePath.hasPrefix("/Applications") {
            let action = enabling ? "enable" : "disable"
            return LaunchAtLoginError(
                message: "Couldn't \(action) Launch at Login. Move GateOpener to /Applications first, then try again."
            )
        }

        return LaunchAtLoginError(
            message: "Couldn't update Launch at Login. Try again, or set it manually in System Settings > General > Login Items."
        )
    }
}
