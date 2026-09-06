import Foundation

/// Cross-process identifiers shared by the GateOpener iOS app and its widget
/// extension.
///
/// These values are a CONTRACT, not configuration: they must be byte-for-byte
/// identical to the App Group and Keychain Sharing entitlements configured on
/// both the app target and the widget extension target in Xcode. If either
/// side's entitlements drift from these strings, `UserDefaults(suiteName:)`
/// silently returns `nil` (see `sharedDefaults()`) and Keychain queries using
/// `keychainAccessGroup` silently fail to find items the other process wrote
/// — there is no compiler check tying entitlement plists to this file, so any
/// change here must be mirrored in the `.entitlements` files by hand.
///
/// `GateOpenerCore` is Foundation-only (no WidgetKit/UIKit/AppKit/SwiftUI),
/// so this type only exposes the identifiers and a `UserDefaults` accessor —
/// reloading widget timelines is the app layer's job.
public enum SharedContainer {
    /// The App Group identifier both the iOS app and the widget extension
    /// must declare in their "App Groups" entitlement.
    public static let appGroupId = "group.ie.boboco.GateOpener"

    /// The Keychain access group both the iOS app and the widget extension
    /// must declare in their "Keychain Sharing" entitlement, so the widget
    /// can read credentials the app wrote (and vice versa).
    public static let keychainAccessGroup = "Y5SB82BPYL.ie.boboco.GateOpener"

    /// The `UserDefaults` suite backing the shared App Group container.
    ///
    /// Returns `nil` if the App Group entitlement is missing or misconfigured
    /// on the running process (e.g. in a plain SPM test target with no
    /// entitlements at all) — callers must handle `nil` rather than force
    /// unwrapping.
    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }
}
