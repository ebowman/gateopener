import Foundation
import CryptoKit

/// Errors surfaced by `ComelitAPI`.
///
/// The `.invalidCredentials` case is load-bearing: callers (and a later retry
/// bead) must distinguish "the password is wrong" (never retry) from transient
/// network/server failures (safe to retry). `.invalidCredentials` is detected by
/// inspecting the response BODY for `wrong_username_or_password`, regardless of
/// the HTTP status code the server happens to return for it.
public enum ComelitError: Error, Equatable, Sendable {
    case invalidCredentials
    /// `code` is the originating `URLError.code.rawValue` when the failure
    /// came from a `URLError` (offline, timed out, host unreachable, etc.),
    /// and `nil` for every other transport-failure origin (invalid URL,
    /// non-HTTP response, JSON body encoding failure, ...). Defaulted to
    /// `nil` so every pre-existing `.network(message)` call site keeps
    /// compiling unchanged; only call sites that actually observe a
    /// `URLError` populate it, so `GateErrorMessage` can distinguish
    /// "offline"/"timed out" from a generic transport failure without
    /// parsing `message`.
    case network(String, code: Int? = nil)
    case server(status: Int, body: String)
    case decoding(String)
    case missingRefreshToken
}

/// PKCE (Proof Key for Code Exchange) verifier/challenge generation.
///
/// NOTE: the verifier is a plain UUIDv4 string (lowercase), NOT raw random bytes.
/// This matches the Comelit mobile app's own implementation, which the Python
/// reference (`comelit/auth.py`) validated against the live service.
public enum PKCE {
    /// Generate a fresh (verifier, challenge) pair.
    public static func generate() -> (verifier: String, challenge: String) {
        let verifier = UUID().uuidString.lowercased()
        let challenge = challenge(forVerifier: verifier)
        return (verifier, challenge)
    }

    /// Compute the S256 code challenge for a given verifier:
    /// base64url(SHA256(verifier UTF-8 bytes)) with padding stripped.
    public static func challenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let base64 = Data(digest).base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Client for the Comelit cloud OAuth2 + PKCE login/refresh flow and (later)
/// device API calls. Holds no mutable state; every call is independent so it is
/// safe to use concurrently.
public struct ComelitAPI: Sendable {
    public static let baseURL = "https://api.comelitgroup.com"
    // Public client id baked into the Comelit mobile app (same for all users; not a secret).
    public static let clientID = "kgDV0WRlQcSF4jPsz887lOTPyVVtP7Oh"
    public static let redirectURI = "https://app.comelitgroup.com/oauth_redirect/comelit"
    public static let scope = "all"
    public static let userAgent = "ktor-client"

    private let session: URLSession
    /// `URLRequest.timeoutInterval` applied to EVERY request this type
    /// builds (auth, token exchange, refresh). 8s rationale: normal cloud
    /// latency is 1.6-1.9s (memory `comelit-cloud-latency-and-timeout-budget`)
    /// and token calls are rare, so one generous bounded attempt beats
    /// several tight ones. See `docs/PROTOCOL.md`'s "Token endpoints"
    /// section.
    private let requestTimeout: Duration
    /// Injectable sleep function so tests never actually sleep. Mirrors
    /// `RetryPolicy.sleep` in `GateClient.swift`.
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        session: URLSession = .shared,
        requestTimeout: Duration = .seconds(8),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.session = session
        self.requestTimeout = requestTimeout
        self.sleep = sleep
    }

    // MARK: - Login

    /// Full OAuth2 Authorization-Code + PKCE login, mirroring `comelit/auth.py::login`.
    ///
    /// Step 1: POST credentials + PKCE challenge to `/o-auth-2/auth`; the response
    /// carries a redirect target containing `?code=...`.
    /// Step 2: exchange the code + PKCE verifier for tokens at `/o-auth-2/token`.
    public func login(username: String, password: String) async throws -> TokenSet {
        let verifier = UUID().uuidString.lowercased()
        let challenge = PKCE.challenge(forVerifier: verifier)
        let state = UUID().uuidString.lowercased()

        let code = try await requestAuthorizationCode(
            username: username,
            password: password,
            challenge: challenge,
            state: state
        )

        return try await exchangeCodeForTokens(code: code, verifier: verifier)
    }

    /// Step 1 of login: POST to `/o-auth-2/auth`, extract the authorization code.
    private func requestAuthorizationCode(
        username: String,
        password: String,
        challenge: String,
        state: String
    ) async throws -> String {
        guard let url = URL(string: "\(Self.baseURL)/o-auth-2/auth") else {
            throw ComelitError.network("invalid URL for /o-auth-2/auth")
        }

        let body: [String: String] = [
            "username": username,
            "password": password,
            "responseType": "code",
            "clientId": Self.clientID,
            "redirectUri": Self.redirectURI,
            "scope": Self.scope,
            "state": state,
            "codeChallenge": challenge,
            "codeChallengeMethod": "S256",
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("application/json,application/xml,text/xml", forHTTPHeaderField: "accept")
        request.timeoutInterval = TimeInterval(requestTimeout.components.seconds)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ComelitError.decoding("failed to encode auth request body: \(error)")
        }

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComelitError.network("non-HTTP response from /o-auth-2/auth")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""

        if bodyString.contains("wrong_username_or_password") {
            throw ComelitError.invalidCredentials
        }

        guard httpResponse.statusCode == 200 else {
            throw ComelitError.server(status: httpResponse.statusCode, body: String(bodyString.prefix(300)))
        }

        if let code = extractCode(fromBodyData: data, response: httpResponse) {
            return code
        }

        throw ComelitError.decoding("login step 1 returned no auth code. Body: \(String(bodyString.prefix(300)))")
    }

    /// Extract the authorization `code` query parameter defensively from, in order:
    /// 1. a JSON body field named `location` (as returned by `/o-auth-2/auth`),
    /// 2. an HTTP `Location` header (if URLSession did not already follow it),
    /// 3. the final (possibly redirected) response URL's query string.
    private func extractCode(fromBodyData data: Data, response: HTTPURLResponse) -> String? {
        // 1. JSON body field "location".
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let location = json["location"] as? String,
           let code = code(fromURLString: location) {
            return code
        }

        // 2. JSON body field "code" directly.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? String {
            return code
        }

        // 3. Location header.
        if let locationHeader = response.value(forHTTPHeaderField: "Location")
            ?? response.value(forHTTPHeaderField: "location"),
           let code = code(fromURLString: locationHeader) {
            return code
        }

        // 4. Final redirected response URL's query string.
        if let finalURL = response.url, let code = code(fromURL: finalURL) {
            return code
        }

        return nil
    }

    private func code(fromURLString string: String) -> String? {
        guard let url = URL(string: string) else { return nil }
        return code(fromURL: url)
    }

    private func code(fromURL url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    /// Step 2 of login: exchange an authorization code + PKCE verifier for tokens.
    ///
    /// Retried once on transport failure or HTTP >= 500 / 429 (see
    /// `performTokenRequest(form:allowRetry:)`): this is the token EXCHANGE,
    /// distinct from the credential-submitting `/o-auth-2/auth` POST (step 1
    /// of `login`), which is never retried.
    private func exchangeCodeForTokens(code: String, verifier: String) async throws -> TokenSet {
        let form: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "scope": Self.scope,
            "code": code,
            "code_verifier": verifier,
        ]
        return try await performTokenRequest(form: form, allowRetry: true)
    }

    // MARK: - Refresh

    /// Exchange a refresh token for a new `TokenSet` via the `refresh_token` grant.
    /// Throws `.missingRefreshToken` if `tokens.refreshToken` is `nil`.
    public func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        guard let refreshToken = tokens.refreshToken else {
            throw ComelitError.missingRefreshToken
        }

        let form: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
            "scope": Self.scope,
        ]
        return try await performTokenRequest(form: form, allowRetry: true)
    }

    // MARK: - Shared token-endpoint plumbing

    /// Delay before the single retry attempt on `/o-auth-2/token` (see
    /// `performTokenRequest(form:allowRetry:)`). Routed through the
    /// injectable `sleep` closure so tests never really sleep.
    private static let retryDelay: Duration = .milliseconds(500)

    /// A single `/o-auth-2/token` HTTP attempt's outcome, ahead of any
    /// error-mapping: either an HTTP response (of any status), or a
    /// transport failure. Modeled as a value rather than thrown errors so
    /// the retry decision in `performTokenRequest` can inspect a
    /// transport-failure vs. HTTP-status distinction directly, without
    /// having to pattern-match back out of a thrown `ComelitError`.
    private enum TokenAttemptOutcome {
        case response(data: Data, httpResponse: HTTPURLResponse)
        /// `code` is the originating `URLError.code.rawValue` when the
        /// transport failure came from a `URLError`, `nil` otherwise (e.g.
        /// an invalid URL or non-HTTP response) -- threaded straight into
        /// `ComelitError.network(_:code:)` at the throw site in
        /// `performTokenRequest` so an offline/timed-out token refresh maps
        /// to the same specific message as an offline gate open.
        case transportFailure(String, code: Int?)
    }

    /// POST to `/o-auth-2/token`, optionally retrying EXACTLY ONCE after a
    /// fixed 500ms delay (via the injectable `sleep` closure) if the first
    /// attempt fails with a transport error or an HTTP status of 500+ or
    /// 429.
    ///
    /// `allowRetry` is `false` for nothing today (both token-endpoint
    /// callers -- `exchangeCodeForTokens` and `refresh` -- pass `true`); it
    /// exists so a future caller of this shared plumbing can opt out
    /// without duplicating the request-building logic. The credential-
    /// submitting `/o-auth-2/auth` POST is a SEPARATE method
    /// (`requestAuthorizationCode`) that never calls this at all, and so is
    /// never retried, regardless of this flag.
    ///
    /// Never retries a 4xx status (other than 429), and never retries a
    /// `wrong_username_or_password` body regardless of its HTTP status:
    /// both indicate a request the server will never accept no matter how
    /// many times it is resent.
    private func performTokenRequest(form: [String: String], allowRetry: Bool) async throws -> TokenSet {
        var outcome = await attemptTokenRequest(form: form)

        if allowRetry, Self.isRetryable(outcome) {
            try await sleep(Self.retryDelay)
            outcome = await attemptTokenRequest(form: form)
        }

        switch outcome {
        case .transportFailure(let description, let code):
            throw ComelitError.network(description, code: code)
        case .response(let data, let httpResponse):
            let bodyString = String(data: data, encoding: .utf8) ?? ""

            if bodyString.contains("wrong_username_or_password") {
                throw ComelitError.invalidCredentials
            }

            guard httpResponse.statusCode == 200 else {
                throw ComelitError.server(status: httpResponse.statusCode, body: String(bodyString.prefix(300)))
            }

            return try Self.decodeTokenResponse(data: data)
        }
    }

    /// Whether a `/o-auth-2/token` attempt's outcome is safe to retry: a
    /// transport failure, or an HTTP 500+ / 429 response whose body is NOT
    /// a `wrong_username_or_password` credential rejection (that always
    /// wins regardless of status, and is never retried).
    private static func isRetryable(_ outcome: TokenAttemptOutcome) -> Bool {
        switch outcome {
        case .transportFailure:
            return true
        case .response(let data, let httpResponse):
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            if bodyString.contains("wrong_username_or_password") {
                return false
            }
            return httpResponse.statusCode >= 500 || httpResponse.statusCode == 429
        }
    }

    /// A single HTTP attempt against `/o-auth-2/token`. Never throws --
    /// transport failures and HTTP responses of any status are both
    /// reported via `TokenAttemptOutcome` so the caller can make the retry
    /// decision before any error-mapping happens.
    private func attemptTokenRequest(form: [String: String]) async -> TokenAttemptOutcome {
        guard let url = URL(string: "\(Self.baseURL)/o-auth-2/token") else {
            return .transportFailure("invalid URL for /o-auth-2/token", code: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "content-type"
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = TimeInterval(requestTimeout.components.seconds)
        request.httpBody = Self.formURLEncode(form).data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transportFailure("non-HTTP response from /o-auth-2/token", code: nil)
            }
            return .response(data: data, httpResponse: httpResponse)
        } catch {
            return .transportFailure(error.localizedDescription, code: (error as? URLError)?.code.rawValue)
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw ComelitError.network(error.localizedDescription)
        }
    }

    private static func decodeTokenResponse(data: Data) throws -> TokenSet {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ComelitError.decoding("token response was not a JSON object")
        }

        guard let accessToken = json["access_token"] as? String else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw ComelitError.decoding(
                "token response returned no access_token. Body: \(String(bodyString.prefix(300)))"
            )
        }

        let refreshToken = json["refresh_token"] as? String
        let tokenType = json["token_type"] as? String ?? "bearer"

        let expiresIn: TimeInterval?
        if let seconds = json["expires_in"] as? Double {
            expiresIn = seconds
        } else if let seconds = json["expires_in"] as? Int {
            expiresIn = TimeInterval(seconds)
        } else {
            expiresIn = nil
        }

        return TokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            tokenType: tokenType
        )
    }

    private static func formURLEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .sorted()
            .joined(separator: "&")
    }
}
