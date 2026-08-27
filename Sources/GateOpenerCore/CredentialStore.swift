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

    /// - Parameter service: The `kSecAttrService` value scoping all keychain
    ///   items created by this instance. Defaults to the production service
    ///   string. Tests should pass a unique value (e.g. including a UUID) so
    ///   that concurrent test runs never collide with each other or with the
    ///   real app's stored credentials.
    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
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

    // MARK: - Generic keychain plumbing

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Adds a new keychain item, or updates the existing one in place if an
    /// item with the same service+account already exists. This explicit
    /// add-then-update-on-duplicate flow guarantees `saveCredentials`/
    /// `saveTokens` overwrite rather than fail with `errSecDuplicateItem`.
    private func save(account: String, data: Data) throws {
        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let query = baseQuery(account: account)
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
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
