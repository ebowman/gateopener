import Foundation

// HARD CONSTRAINT: secrets NEVER go here. Username, password, and OAuth
// tokens live ONLY in the Keychain (see bead .3 / CredentialStore). No key
// in this file may hold a credential or token — only non-secret UI/session
// state such as the selected gate endpoint and the last discovery date.

/// Persisted, NON-SECRET configuration for GateOpener, backed by `UserDefaults`.
///
/// `GateOpenerCore` must not import SwiftUI or AppKit so it stays headlessly
/// testable (load-bearing constraint from bead .1). For that reason this type
/// is a plain class rather than `ObservableObject`/`@Observable` — it does
/// not depend on Combine or the Observation framework. A later bead's
/// `GateController` (in the app target, where SwiftUI/AppKit are already in
/// play) is expected to wrap or forward `AppSettings` for observability.
///
/// `UserDefaults` is documented by Apple as thread-safe, so this class is
/// marked `@unchecked Sendable`: all mutable state is delegated to
/// `UserDefaults` itself, and `AppSettings` holds no other mutable storage.
public final class AppSettings: @unchecked Sendable {
    private enum Keys {
        static let aptId = "ie.boboco.GateOpener.aptId"
        static let selectedEndpointId = "ie.boboco.GateOpener.selectedEndpointId"
        static let selectedEndpointName = "ie.boboco.GateOpener.selectedEndpointName"
        static let lastDiscoveryDate = "ie.boboco.GateOpener.lastDiscoveryDate"
        static let shortcutPreference = "ie.boboco.GateOpener.shortcutPreference"
        static let showOpenConfirmationOverlay = "ie.boboco.GateOpener.showOpenConfirmationOverlay"
        static let autoShowDoorVideoOnOpen = "ie.boboco.GateOpener.autoShowDoorVideoOnOpen"

        /// All keys owned by `AppSettings`. Used by `reset()` so unrelated
        /// UserDefaults keys (e.g. from other parts of the app, or the test
        /// suite) are never touched.
        static let all = [
            aptId, selectedEndpointId, selectedEndpointName, lastDiscoveryDate, shortcutPreference,
            showOpenConfirmationOverlay, autoShowDoorVideoOnOpen,
        ]
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: The `UserDefaults` suite to persist into.
    ///   Defaults to `.standard`; tests should inject a throwaway
    ///   `UserDefaults(suiteName:)` instance so they never pollute the real
    ///   app domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The apartment id associated with the signed-in account.
    ///
    /// This is OPTIONAL and VESTIGIAL. Live verification against the real
    /// Comelit API (2026-08-27) showed that gate discovery works with no
    /// `aptId` parameter at all, returns an identical set of endpoints, and
    /// there is no apartment-list API to populate it from up front — the
    /// value is only ever parseable out of an `endpointId` after the fact.
    /// Nothing in this file (see `isConfigured`) may gate behavior on
    /// `aptId` being present. Do not "fix" this back to required.
    public var aptId: String? {
        get { defaults.string(forKey: Keys.aptId) }
        set { defaults.set(newValue, forKey: Keys.aptId) }
    }

    /// The id of the gate endpoint the user has chosen to open with one click.
    public var selectedEndpointId: String? {
        get { defaults.string(forKey: Keys.selectedEndpointId) }
        set { defaults.set(newValue, forKey: Keys.selectedEndpointId) }
    }

    /// The human-readable name of the selected gate endpoint, for display.
    public var selectedEndpointName: String? {
        get { defaults.string(forKey: Keys.selectedEndpointName) }
        set { defaults.set(newValue, forKey: Keys.selectedEndpointName) }
    }

    /// The timestamp of the most recent successful endpoint discovery.
    public var lastDiscoveryDate: Date? {
        get { defaults.object(forKey: Keys.lastDiscoveryDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastDiscoveryDate) }
    }

    /// The user's global-hotkey preference: unset (use the default chord),
    /// explicitly disabled (no hotkey), or a specific custom chord.
    ///
    /// This is NOT a secret — it is a key code and modifier bitmask, not a
    /// credential — so it belongs in UserDefaults like the rest of this
    /// file, never in the Keychain. Stored as JSON-encoded `Data` since
    /// `ShortcutPreference` is an enum with an associated value, which
    /// `UserDefaults` cannot store as a native property-list type directly.
    /// A missing or corrupt/unrecognized stored value decodes to `.unset`
    /// (see `ShortcutPreference.init(from:)`) rather than crashing.
    public var shortcutPreference: ShortcutPreference {
        get {
            guard let data = defaults.data(forKey: Keys.shortcutPreference) else { return .unset }
            return (try? JSONDecoder().decode(ShortcutPreference.self, from: data)) ?? .unset
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.shortcutPreference)
        }
    }

    /// Whether the canned "gate opened" confirmation overlay/animation is
    /// shown after a successful open. Defaults to `true` — the overlay is
    /// the whole point of the feature.
    ///
    /// This is distinct from (and must not be confused with)
    /// `autoShowDoorVideoOnOpen` below, the separate preference for
    /// auto-playing the live door camera on open. This property governs
    /// only the canned confirmation animation.
    public var showOpenConfirmationOverlay: Bool {
        get {
            // UserDefaults.bool(forKey:) returns `false` for an absent key,
            // which would silently default this feature OFF — the opposite
            // of the intended default. So an absent key must be treated as
            // `true` explicitly; do not "simplify" this back to
            // `defaults.bool(forKey:)`.
            defaults.object(forKey: Keys.showOpenConfirmationOverlay) == nil
                ? true
                : defaults.bool(forKey: Keys.showOpenConfirmationOverlay)
        }
        set { defaults.set(newValue, forKey: Keys.showOpenConfirmationOverlay) }
    }

    /// Whether opening the gate also starts a LIVE door-camera video session
    /// in the confirmation overlay (bead gateopener-12h.6), alongside the
    /// canned confirmation animation `showOpenConfirmationOverlay` above
    /// governs. Defaults to `true` — this is the behavior the user asked
    /// for verbatim ("I get a 'session' of live video so I can see the gate
    /// opening"), so it must work out of the box with no configuration.
    ///
    /// DELIBERATELY A SEPARATE PREFERENCE from `showOpenConfirmationOverlay`,
    /// not a reuse of it: a live video session runs for the door's full
    /// ~28-30s natural session length (see `DoorVideoSession`/
    /// `DoorVideoFrameView`'s plateau detector), which is a much bigger
    /// on-screen commitment than the confirmation overlay's ~1.45s
    /// hold+fade. A user may reasonably want the instant "yes, it opened"
    /// confirmation on every single open (keep
    /// `showOpenConfirmationOverlay` on) without also getting a ~30-second
    /// video panel on screen every time (turn `autoShowDoorVideoOnOpen`
    /// off) — folding these into one toggle would remove that choice.
    /// Turning `showOpenConfirmationOverlay` off does NOT imply turning
    /// this off too: a user could in principle want live video without the
    /// canned animation, though in practice `OverlayWindowController`
    /// always shows the canned animation first (video arrives ~4-6s later
    /// and needs somewhere to land) — see that type's `handle(_:)`.
    public var autoShowDoorVideoOnOpen: Bool {
        get {
            // Same absent-key-means-true handling as
            // `showOpenConfirmationOverlay` above, and for the same reason:
            // `UserDefaults.bool(forKey:)`'s `false`-for-absent-key default
            // would silently ship this feature OFF for every user who has
            // never touched the toggle, which is the opposite of the
            // required default.
            defaults.object(forKey: Keys.autoShowDoorVideoOnOpen) == nil
                ? true
                : defaults.bool(forKey: Keys.autoShowDoorVideoOnOpen)
        }
        set { defaults.set(newValue, forKey: Keys.autoShowDoorVideoOnOpen) }
    }

    /// True if and only if a non-empty `selectedEndpointId` is present.
    ///
    /// Deliberately NOT dependent on `aptId` — see the doc comment on
    /// `aptId` above for why.
    public var isConfigured: Bool {
        guard let id = selectedEndpointId else { return false }
        return !id.isEmpty
    }

    /// Clears every key this class owns (used by "Sign out"). Does not
    /// touch any UserDefaults key not listed in `Keys.all`.
    public func reset() {
        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
    }
}
