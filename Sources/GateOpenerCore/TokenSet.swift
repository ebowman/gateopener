import Foundation

/// An OAuth2 token set (access token, optional refresh token, and absolute expiry).
///
/// `expiresAt` is always an absolute point in time, computed at the moment the
/// token set is received from an `expires_in` seconds value. This lets callers
/// (and later beads) check expiry without needing to know when the token was issued.
public struct TokenSet: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var tokenType: String

    /// Default lifetime (seconds) to assume when a token response omits `expires_in`.
    public static let defaultExpiresIn: TimeInterval = 3600

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, tokenType: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }

    /// Construct a `TokenSet` from a token response, computing `expiresAt` as
    /// `receivedAt + expiresIn`. If `expiresIn` is `nil`, `defaultExpiresIn` (3600s)
    /// is used instead of crashing or leaving the token permanently "expired".
    public init(
        accessToken: String,
        refreshToken: String?,
        expiresIn: TimeInterval?,
        tokenType: String,
        receivedAt: Date = Date()
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = receivedAt.addingTimeInterval(expiresIn ?? TokenSet.defaultExpiresIn)
        self.tokenType = tokenType
    }

    /// True when the token has already expired, or will expire within `skew`
    /// seconds of `now`. Used by callers (and a later refresh-retry bead) to
    /// decide whether a proactive refresh is warranted.
    public func isExpired(now: Date = Date(), skew: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(now) <= skew
    }
}
