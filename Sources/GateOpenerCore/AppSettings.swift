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

        /// All keys owned by `AppSettings`. Used by `reset()` so unrelated
        /// UserDefaults keys (e.g. from other parts of the app, or the test
        /// suite) are never touched.
        static let all = [aptId, selectedEndpointId, selectedEndpointName, lastDiscoveryDate]
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
