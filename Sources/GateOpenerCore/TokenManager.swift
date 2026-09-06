import Foundation

/// Errors surfaced by `TokenManager`.
public enum TokenManagerError: Error, Equatable, Sendable {
    /// No credentials (username/password) are stored at all, so there is
    /// nothing `TokenManager` can use to obtain a token. The UI should
    /// prompt the user to enter their Comelit credentials.
    case notConfigured
}

/// Abstraction over the two `ComelitAPI` operations `TokenManager` needs, so
/// tests can inject a mock with no network access.
///
/// `ComelitAPI` already has matching method signatures, so it conforms via a
/// plain (no-op-body) extension below — no changes to `ComelitAPI.swift` are
/// needed.
public protocol TokenIssuing: Sendable {
    func login(username: String, password: String) async throws -> TokenSet
    func refresh(_ tokens: TokenSet) async throws -> TokenSet
}

extension ComelitAPI: TokenIssuing {}

/// Owns the lifecycle of the OAuth access token used to call the Comelit API:
/// caching it in memory, persisting it to a `CredentialStoring` backend,
/// proactively refreshing it before it expires, and falling back to a full
/// username/password login when refresh is not possible or fails.
///
/// ## Resolution order
///
/// `accessToken()` resolves a usable access token in this order:
///  1. An in-memory cached token that is not near expiry.
///  2. A token loaded from the credential store that is not near expiry
///     (which is then cached in memory).
///  3. A refresh, using the stored refresh token, if any token (in-memory or
///     stored) has one available.
///  4. A full login, using stored username/password.
///  5. `TokenManagerError.notConfigured`, if there are no stored credentials
///     at all to attempt a login with.
///
/// Expiry is judged with `TokenSet.isExpired(now:skew:)` using the default
/// 5-minute skew: a token that will die within the next 5 minutes is treated
/// as unusable, so a caller never starts a request with a token that expires
/// mid-flight.
///
/// ## Concurrency coalescing
///
/// `TokenManager` is an `actor`, but actor isolation alone does NOT prevent
/// two concurrent `accessToken()` calls from both deciding "no valid token"
/// and both starting a login/refresh: the first call reaches an `await` (the
/// network call), which suspends and lets the second call run, and the
/// second call sees the same "no valid token" state.
///
/// To coalesce concurrent calls into a single in-flight network operation,
/// `accessToken()` records the in-flight resolution as a `Task` in
/// `inFlightTask`. A caller that finds `inFlightTask` already set simply
/// awaits that existing task's value instead of starting a new one. The task
/// is cleared when it completes (success or failure) so the next call after
/// completion re-evaluates the cache from scratch.
public actor TokenManager {
    private let api: any TokenIssuing
    private var credentialStore: any CredentialStoring
    private let now: () -> Date

    /// The current in-memory cached token, if any.
    private var cachedToken: TokenSet?

    /// The single in-flight resolution task, if a call to `accessToken()` (or
    /// `prewarm()`) is currently in progress. Concurrent callers await this
    /// same task rather than starting their own, guaranteeing at most one
    /// login/refresh at a time -- this is the same coalescing mechanism
    /// shared by both entry points, not a second one added for `prewarm()`.
    private var inFlightTask: Task<String, Error>?

    public init(
        api: any TokenIssuing,
        credentialStore: any CredentialStoring,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.credentialStore = credentialStore
        self.now = now
    }

    /// Resolve a usable access token, refreshing or logging in as needed.
    /// See the type-level documentation for the full resolution order.
    public func accessToken() async throws -> String {
        try await coalesced { try await self.resolveAccessToken() }
    }

    /// Best-effort, best-effort-off-the-critical-path refresh of a
    /// soon-to-expire token, intended to be called on every app foreground.
    ///
    /// - If there are no stored tokens at all, this returns immediately with
    ///   no network call: `prewarm()` never triggers a login, since signing
    ///   in is an explicit user action, not something that should happen
    ///   silently in the background.
    /// - If the stored token does not expire within `window` of now, this
    ///   returns immediately with no network call.
    /// - Otherwise this runs exactly the same refresh path `accessToken()`
    ///   uses (including its fall-back-to-login-from-stored-credentials
    ///   behaviour) and persists the result.
    ///
    /// Errors are swallowed: `prewarm()` never throws. If the refresh (and
    /// any fallback login) fails, the previously stored/cached tokens are
    /// left untouched, and the real `accessToken()` call on the critical
    /// open path will surface the failure when it is actually needed.
    ///
    /// Shares the same single-flight `inFlightTask` as `accessToken()`, so a
    /// `prewarm()` racing a concurrent `accessToken()` (or another
    /// `prewarm()`) coalesces into a single refresh/login rather than two.
    public func prewarm(expiringWithin window: Duration = .seconds(600)) async {
        guard let stored = (try? credentialStore.loadTokens()) ?? nil else {
            return
        }

        let referenceNow = now()
        let windowSeconds = TimeInterval(window.components.seconds)
            + TimeInterval(window.components.attoseconds) / 1e18
        guard stored.expiresAt <= referenceNow.addingTimeInterval(windowSeconds) else {
            return
        }

        _ = try? await coalesced { try await self.resolveAccessToken() }
    }

    /// Runs `operation` as the single in-flight resolution task, or awaits
    /// the existing one if a call to `accessToken()`/`prewarm()` is already
    /// in progress. This is the one and only coalescing mechanism used by
    /// both public entry points.
    private func coalesced(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        if let existing = inFlightTask {
            return try await existing.value
        }

        let task = Task { try await operation() }
        inFlightTask = task

        defer { inFlightTask = nil }

        return try await task.value
    }

    /// Drops the in-memory cached token only. Used when the server rejects a
    /// token mid-flight (e.g. a 401), so the next `accessToken()` call
    /// re-resolves rather than handing out the same bad token again.
    ///
    /// This deliberately does NOT delete the persisted token from the
    /// credential store: the stored token (and, importantly, its refresh
    /// token) may still be usable via `refresh()` even though the in-memory
    /// copy was rejected — e.g. if the rejection was caused by clock skew,
    /// a transient server-side issue, or the in-memory copy being stale
    /// relative to a token refreshed by another process. Deleting the
    /// persisted token would force an unnecessary full login (and, if the
    /// stored password is also stale/wrong, a needless credential-invalid
    /// error) when a plain refresh would have sufficed.
    public func invalidate() {
        cachedToken = nil
    }

    /// Swaps in a new `CredentialStoring` backend for all FUTURE loads/saves:
    /// the next `accessToken()`/`prewarm()` call that needs to read stored
    /// tokens/credentials, and every subsequent `saveTokens`/`saveTokens`
    /// call made by a refresh or login, go through `store` rather than
    /// whatever backend this actor was constructed with.
    ///
    /// This exists so a caller that rebuilds its `CredentialStoring` mid-
    /// session (e.g. `AppEnvironment.updateKeychainAccessibility(allowWhileLocked:)`,
    /// which constructs a freshly-accessibility-configured
    /// `KeychainCredentialStore`) can keep this actor's already-in-flight
    /// identity (its in-memory `cachedToken` and single-flight
    /// `inFlightTask` coalescing) while still ensuring the NEW accessibility
    /// class applies to the very next token persisted, instead of only
    /// taking effect on the next app launch.
    ///
    /// Does NOT touch `cachedToken`: an in-memory token already resolved
    /// under the old store remains valid and is not reloaded or invalidated
    /// by this call. Single-flight coalescing (`inFlightTask`) is likewise
    /// unaffected — an in-flight resolution started before this call
    /// completes normally against whichever store was current when it
    /// started reading/writing.
    public func setCredentialStore(_ store: any CredentialStoring) {
        credentialStore = store
    }

    // MARK: - Resolution

    private func resolveAccessToken() async throws -> String {
        if let cached = cachedToken, !cached.isExpired() {
            return cached.accessToken
        }

        let stored = try credentialStore.loadTokens()

        if let stored, !stored.isExpired() {
            cachedToken = stored
            return stored.accessToken
        }

        // Try a refresh first, using whichever token (stored, preferentially,
        // else the stale in-memory one) carries a refresh token.
        if let refreshable = stored ?? cachedToken,
           refreshable.refreshToken != nil,
           let refreshed = try? await api.refresh(refreshable) {
            try credentialStore.saveTokens(refreshed)
            cachedToken = refreshed
            return refreshed.accessToken
        }

        // Refresh was unavailable or failed for any reason (expired/revoked
        // refresh token, network error, etc.) -- silently fall through to a
        // full login rather than surfacing the refresh failure.
        guard let credentials = try credentialStore.loadCredentials() else {
            throw TokenManagerError.notConfigured
        }

        // A failure here (in particular `.invalidCredentials`) is NOT
        // swallowed: it propagates directly to the caller so the UI can
        // distinguish "your password is wrong" from a transient failure.
        let loggedIn = try await api.login(username: credentials.username, password: credentials.password)
        try credentialStore.saveTokens(loggedIn)
        cachedToken = loggedIn
        return loggedIn.accessToken
    }
}
