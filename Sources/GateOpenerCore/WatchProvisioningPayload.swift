import Foundation

/// Everything the Apple Watch needs to open the gate on its own, pushed from
/// the iPhone over WatchConnectivity. Contains the account password: never
/// log or print any field of this type.
public struct WatchProvisioningPayload: Equatable, Sendable {
    public static let schemaVersion = 1

    public var username: String
    public var password: String
    public var selectedEndpointId: String?
    public var selectedEndpointName: String?
    public var aptId: String?
    public var cachedGates: [Endpoint]
    public var issuedAt: Date

    public init(
        username: String,
        password: String,
        selectedEndpointId: String?,
        selectedEndpointName: String?,
        aptId: String?,
        cachedGates: [Endpoint],
        issuedAt: Date
    ) {
        self.username = username
        self.password = password
        self.selectedEndpointId = selectedEndpointId
        self.selectedEndpointName = selectedEndpointName
        self.aptId = aptId
        self.cachedGates = cachedGates
        self.issuedAt = issuedAt
    }
}

/// A provisioning instruction for the watch: either full provisioning or a
/// sign-out tombstone. Converts to/from a property-list dictionary suitable
/// for `WCSession.updateApplicationContext`.
public enum WatchProvisioningMessage: Equatable, Sendable {
    case provision(WatchProvisioningPayload)
    case signedOut(issuedAt: Date)

    /// Dictionary keys (all values are property-list types).
    public enum Keys {
        public static let version = "v"
        public static let kind = "kind"
        public static let username = "username"
        public static let password = "password"
        public static let selectedEndpointId = "selectedEndpointId"
        public static let selectedEndpointName = "selectedEndpointName"
        public static let aptId = "aptId"
        public static let cachedGates = "cachedGates"
        public static let issuedAt = "issuedAt"
    }

    private static let kindProvision = "provision"
    private static let kindSignedOut = "signedOut"

    public var issuedAt: Date {
        switch self {
        case .provision(let payload): return payload.issuedAt
        case .signedOut(let date): return date
        }
    }

    /// Property-list-safe dictionary (String/Int/Data/Date only).
    public func toContext() -> [String: Any] {
        var dict: [String: Any] = [Keys.version: WatchProvisioningPayload.schemaVersion]
        switch self {
        case .signedOut(let issuedAt):
            dict[Keys.kind] = Self.kindSignedOut
            dict[Keys.issuedAt] = issuedAt
        case .provision(let p):
            dict[Keys.kind] = Self.kindProvision
            dict[Keys.username] = p.username
            dict[Keys.password] = p.password
            if let v = p.selectedEndpointId { dict[Keys.selectedEndpointId] = v }
            if let v = p.selectedEndpointName { dict[Keys.selectedEndpointName] = v }
            if let v = p.aptId { dict[Keys.aptId] = v }
            dict[Keys.cachedGates] = (try? JSONEncoder().encode(p.cachedGates)) ?? Data()
            dict[Keys.issuedAt] = p.issuedAt
        }
        return dict
    }

    /// Returns nil for a missing/unknown version or kind, a missing
    /// issuedAt, or missing username/password on provision. A corrupt
    /// `cachedGates` blob degrades to `[]`.
    public static func fromContext(_ dict: [String: Any]) -> WatchProvisioningMessage? {
        guard let version = dict[Keys.version] as? Int,
              version == WatchProvisioningPayload.schemaVersion,
              let kind = dict[Keys.kind] as? String,
              let issuedAt = dict[Keys.issuedAt] as? Date
        else { return nil }
        switch kind {
        case kindSignedOut:
            return .signedOut(issuedAt: issuedAt)
        case kindProvision:
            guard let username = dict[Keys.username] as? String,
                  let password = dict[Keys.password] as? String
            else { return nil }
            let gates = (dict[Keys.cachedGates] as? Data)
                .flatMap { try? JSONDecoder().decode([Endpoint].self, from: $0) } ?? []
            return .provision(WatchProvisioningPayload(
                username: username,
                password: password,
                selectedEndpointId: dict[Keys.selectedEndpointId] as? String,
                selectedEndpointName: dict[Keys.selectedEndpointName] as? String,
                aptId: dict[Keys.aptId] as? String,
                cachedGates: gates,
                issuedAt: issuedAt
            ))
        default:
            return nil
        }
    }

    /// `.signedOut` when no credentials are stored, else `.provision`
    /// mirroring the settings.
    public static func build(
        settings: AppSettings,
        credentialStore: any CredentialStoring,
        now: Date = Date()
    ) throws -> WatchProvisioningMessage {
        guard let creds = try credentialStore.loadCredentials() else {
            return .signedOut(issuedAt: now)
        }
        return .provision(WatchProvisioningPayload(
            username: creds.username,
            password: creds.password,
            selectedEndpointId: settings.selectedEndpointId,
            selectedEndpointName: settings.selectedEndpointName,
            aptId: settings.aptId,
            cachedGates: settings.cachedGates,
            issuedAt: now
        ))
    }

    /// Applies the message to the watch's stores. A no-op returning false
    /// when `issuedAt <= previouslyApplied`. Does NOT persist
    /// `watchProvisioningAppliedAt`; the caller does. Idempotent.
    @discardableResult
    public func apply(
        to settings: AppSettings,
        credentialStore: any CredentialStoring,
        previouslyApplied: Date? = nil
    ) throws -> Bool {
        if let previous = previouslyApplied, issuedAt <= previous { return false }
        switch self {
        case .provision(let p):
            try credentialStore.saveCredentials(username: p.username, password: p.password)
            try credentialStore.deleteTokens()
            settings.selectedEndpointId = p.selectedEndpointId
            settings.selectedEndpointName = p.selectedEndpointName
            settings.aptId = p.aptId
            settings.cachedGates = p.cachedGates
        case .signedOut:
            try credentialStore.deleteCredentials()
            try credentialStore.deleteTokens()
            settings.selectedEndpointId = nil
            settings.selectedEndpointName = nil
            settings.aptId = nil
            settings.cachedGates = []
        }
        return true
    }
}
