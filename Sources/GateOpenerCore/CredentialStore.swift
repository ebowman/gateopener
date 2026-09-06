import Foundation
import Security

/// Abstraction over persistent storage of the user's Comelit credentials and
/// OAuth token set. Concrete implementations MUST treat every value passed
/// to `saveCredentials`/`saveTokens` as a secret: never log it, never write
/// it anywhere other than the platform keychain.
///
/// Loading an item that has never been saved (or that was deleted) returns
/// `nil` — it is NOT an error condition. Only genuine storage failures
/// (keychain unavailable, malformed data, OS errors) throw.
public protocol CredentialStoring: Sendable {
    /// Persist the username/password pair, overwriting any previously saved pair.
    func saveCredentials(username: String, password: String) throws

    /// Load the previously saved username/password pair, or `nil` if none exists.
    func loadCredentials() throws -> (username: String, password: String)?

    /// Remove any saved username/password pair. A no-op if none exists.
    func deleteCredentials() throws

    /// Persist the OAuth token set, overwriting any previously saved token set.
    func saveTokens(_ tokens: TokenSet) throws

    /// Load the previously saved OAuth token set, or `nil` if none exists.
    func loadTokens() throws -> TokenSet?

    /// Remove any saved OAuth token set. A no-op if none exists.
    func deleteTokens() throws
}

/// Errors surfaced by `KeychainCredentialStore`. The underlying `OSStatus` is
/// carried for diagnostics, but no secret value is ever included — only
/// status codes and (for decode failures) the fact that decoding failed.
public enum KeychainError: Error, Equatable {
    /// A `SecItemAdd`/`SecItemUpdate` call failed with the given status.
    case saveFailed(status: OSStatus)
    /// A `SecItemCopyMatching` call failed with the given status (a status of
    /// `errSecItemNotFound` is handled as `nil`, not this error).
    case loadFailed(status: OSStatus)
    /// A `SecItemDelete` call failed with the given status (a status of
    /// `errSecItemNotFound` is handled as success, not this error).
    case deleteFailed(status: OSStatus)
    /// The item was found in the keychain but its payload could not be
    /// decoded as the expected shape (JSON for tokens, UTF-8 for passwords).
    case decodeFailed
}

/// The accessibility class applied to items saved by `KeychainCredentialStore`.
///
/// Both cases restrict the item to this device only (never migrates via
/// iCloud Keychain backup/restore to a different device) — see
/// `KeychainCredentialStore.makeAddAttributes(accessibility:)`, which also
/// sets `kSecAttrSynchronizable` to `false` for the same reason, belt and
/// braces.
public enum KeychainAccessibility: Sendable {
    /// Item is readable once the device has been unlocked at least once
    /// since boot, including while subsequently locked again (e.g. for a
    /// headless background refresh). This is the default.
    case afterFirstUnlockThisDeviceOnly
    /// Item is only readable while the device is unlocked. Appropriate for
    /// an "allow while locked" opt-out setting.
    case whenUnlockedThisDeviceOnly

    /// The `kSecAttrAccessible` value corresponding to this case.
    var secAttr: CFString {
        switch self {
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

/// Keychain-backed implementation of `CredentialStoring`.
///
/// ## Storage design
///
/// Two DISTINCT `kSecClassGenericPassword` items are used, both scoped to
/// `service`:
///
///  - **Credentials item** — `kSecAttrAccount` is fixed to
///    `credentialsAccount` ("credentials"). The secret data (`kSecValueData`)
///    is a small JSON blob `{"username": ..., "password": ...}`. Storing the
///    username alongside the password (rather than putting the username in
///    `kSecAttrAccount`) means `loadCredentials()` can recover BOTH values
///    from a single, predictably-keyed item without needing to enumerate
///    keychain items or guess the account name in advance.
///
///  - **Tokens item** — `kSecAttrAccount` is fixed to `tokensAccount`
///    ("tokens"). The secret data is the JSON encoding of `TokenSet`. Tokens
///    are stored in the keychain, never in UserDefaults or a plaintext file,
///    because the refresh token is a long-lived bearer credential exactly as
///    sensitive as the account password — anyone who obtains it can mint new
///    access tokens indefinitely.
///
/// Both items use `kSecAttrAccessibleAfterFirstUnlock` so a background
/// refresh can read/write tokens after a reboot, before the user has
/// interactively unlocked the session again (as opposed to
/// `WhenUnlocked`, which would block headless refresh).
///
/// ## Concurrency
///
/// This class is `final` and holds no mutable state of its own — every
/// operation is a self-contained, synchronous call into the Security
/// framework, which is safe to invoke concurrently from multiple threads
/// (each call reads its arguments, performs the operation, and returns).
/// It is therefore `Sendable` without needing `@unchecked Sendable` or a
/// lock: there is no shared mutable state to protect.
public final class KeychainCredentialStore: CredentialStoring, Sendable {
    /// The default keychain service string used by the production app.
    public static let defaultService = "ie.boboco.GateOpener"

    private static let credentialsAccount = "credentials"
    private static let tokensAccount = "tokens"

    private let service: String
    private let accessGroup: String?
    private let accessibility: KeychainAccessibility

    /// - Parameters:
    ///   - service: The `kSecAttrService` value scoping all keychain
    ///     items created by this instance. Defaults to the production service
    ///     string. Tests should pass a unique value (e.g. including a UUID) so
    ///     that concurrent test runs never collide with each other or with the
    ///     real app's stored credentials.
    ///   - accessGroup: The `kSecAttrAccessGroup` value used to share items
    ///     between the iOS app and its widget extension. Defaults to `nil`,
    ///     which omits the attribute entirely — required on macOS and in the
    ///     unsigned `swift test` binary, both of which lack an access-group
    ///     entitlement and would fail every keychain call if one were forced.
    ///   - accessibility: The `kSecAttrAccessible` class applied to saved
    ///     items. Defaults to `.afterFirstUnlockThisDeviceOnly`, matching the
    ///     store's previous, unconfigurable behaviour.
    public init(
        service: String = KeychainCredentialStore.defaultService,
        accessGroup: String? = nil,
        accessibility: KeychainAccessibility = .afterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    // MARK: - Credentials

    private struct StoredCredentials: Codable {
        let username: String
        let password: String
    }

    public func saveCredentials(username: String, password: String) throws {
        let payload = StoredCredentials(username: username, password: password)
        guard let data = try? JSONEncoder().encode(payload) else {
            throw KeychainError.decodeFailed
        }
        try save(account: Self.credentialsAccount, data: data)
    }

    public func loadCredentials() throws -> (username: String, password: String)? {
        guard let data = try load(account: Self.credentialsAccount) else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            throw KeychainError.decodeFailed
        }
        return (username: payload.username, password: payload.password)
    }

    public func deleteCredentials() throws {
        try delete(account: Self.credentialsAccount)
    }

    // MARK: - Tokens

    public func saveTokens(_ tokens: TokenSet) throws {
        guard let data = try? JSONEncoder().encode(tokens) else {
            throw KeychainError.decodeFailed
        }
        try save(account: Self.tokensAccount, data: data)
    }

    public func loadTokens() throws -> TokenSet? {
        guard let data = try load(account: Self.tokensAccount) else {
            return nil
        }
        guard let tokens = try? JSONDecoder().decode(TokenSet.self, from: data) else {
            throw KeychainError.decodeFailed
        }
        return tokens
    }

    public func deleteTokens() throws {
        try delete(account: Self.tokensAccount)
    }

    // MARK: - Accessibility rewrite

    /// Re-saves any currently-stored credentials and tokens under a new
    /// `KeychainAccessibility` class, in place.
    ///
    /// This only rewrites items that already exist in the keychain — it is a
    /// no-op (does not throw) if nothing is stored. It does NOT change this
    /// instance's own `accessibility` for future `saveCredentials`/
    /// `saveTokens` calls: those keep using the accessibility this instance
    /// was constructed with. Callers that want subsequent saves to use the
    /// new class too (e.g. after flipping an "allow while locked" setting)
    /// must construct a new `KeychainCredentialStore` with the new
    /// `accessibility` value and use that store going forward.
    public func rewriteAccessibility(to newAccessibility: KeychainAccessibility) throws {
        if let data = try load(account: Self.credentialsAccount) {
            try rewriteItem(account: Self.credentialsAccount, data: data, accessibility: newAccessibility)
        }
        if let data = try load(account: Self.tokensAccount) {
            try rewriteItem(account: Self.tokensAccount, data: data, accessibility: newAccessibility)
        }
    }

    /// Rewrites a single existing item's `kSecAttrAccessible` (and re-applies
    /// its data) using `SecItemUpdate`. `kSecAttrAccessible` cannot always be
    /// changed via update in every keychain configuration, so on failure this
    /// falls back to delete + add with the new attributes.
    ///
    /// `internal` (rather than `private`) so `@testable import` tests can
    /// verify it builds its update/add dictionaries from
    /// `makeBaseQuery`/`makeAddAttributes` — the underlying
    /// `kSecAttrAccessible` value it writes is not independently observable
    /// via `SecItemCopyMatching` on every keychain configuration (notably
    /// the legacy file-based macOS login keychain used by unsigned
    /// `swift test` binaries does not return or filter on that attribute),
    /// so this is the most direct non-vacuous test seam available.
    func rewriteItem(account: String, data: Data, accessibility: KeychainAccessibility) throws {
        let query = Self.makeBaseQuery(service: service, account: account, accessGroup: accessGroup)
        var attributesToUpdate = Self.makeAddAttributes(accessibility: accessibility)
        attributesToUpdate[kSecValueData as String] = data

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        // Fall back to delete + add with the new attributes.
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: deleteStatus)
        }

        var addQuery = Self.makeBaseQuery(service: service, account: account, accessGroup: accessGroup)
        addQuery.merge(Self.makeAddAttributes(accessibility: accessibility)) { _, new in new }
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(status: addStatus)
        }
    }

    // MARK: - Generic keychain plumbing

    /// Builds the base `SecItemXxx` query dictionary shared by add, update,
    /// copy-matching and delete calls for a given `service`/`account` pair.
    ///
    /// `kSecAttrAccessGroup` is included ONLY when `accessGroup` is non-nil:
    /// on macOS (and in the unsigned SwiftPM test binary) the process has no
    /// access-group entitlement, and forcing the attribute in unconditionally
    /// would make every keychain call fail there.
    static func makeBaseQuery(service: String, account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Builds the attributes applied when adding (or rewriting) a keychain
    /// item: the requested accessibility class, and `kSecAttrSynchronizable`
    /// forced to `false` so the item never syncs via iCloud Keychain to
    /// another device, regardless of the user's iCloud Keychain setting.
    static func makeAddAttributes(accessibility: KeychainAccessibility) -> [String: Any] {
        [
            kSecAttrAccessible as String: accessibility.secAttr,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func baseQuery(account: String) -> [String: Any] {
        Self.makeBaseQuery(service: service, account: account, accessGroup: accessGroup)
    }

    /// Adds a new keychain item, or updates the existing one in place if an
    /// item with the same service+account already exists. This explicit
    /// add-then-update-on-duplicate flow guarantees `saveCredentials`/
    /// `saveTokens` overwrite rather than fail with `errSecDuplicateItem`.
    private func save(account: String, data: Data) throws {
        var addQuery = baseQuery(account: account)
        addQuery.merge(Self.makeAddAttributes(accessibility: accessibility)) { _, new in new }
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let query = baseQuery(account: account)
            var attributesToUpdate = Self.makeAddAttributes(accessibility: accessibility)
            attributesToUpdate[kSecValueData as String] = data
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: updateStatus)
            }
            return
        }
        throw KeychainError.saveFailed(status: addStatus)
    }

    /// Returns the raw secret data for `account`, or `nil` if no such item
    /// exists. Any other failure status is surfaced as `KeychainError.loadFailed`.
    private func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError.decodeFailed
        }
        return data
    }

    /// Deletes the item for `account`. A missing item is treated as success
    /// (deleting something that isn't there achieves the caller's goal).
    private func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}
