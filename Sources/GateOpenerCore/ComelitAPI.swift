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
    case network(String)
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

    public init(session: URLSession = .shared) {
        self.session = session
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
    private func exchangeCodeForTokens(code: String, verifier: String) async throws -> TokenSet {
        let form: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "scope": Self.scope,
            "code": code,
            "code_verifier": verifier,
        ]
        return try await performTokenRequest(form: form)
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
        return try await performTokenRequest(form: form)
    }

    // MARK: - Shared token-endpoint plumbing

    private func performTokenRequest(form: [String: String]) async throws -> TokenSet {
        guard let url = URL(string: "\(Self.baseURL)/o-auth-2/token") else {
            throw ComelitError.network("invalid URL for /o-auth-2/token")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "content-type"
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = Self.formURLEncode(form).data(using: .utf8)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComelitError.network("non-HTTP response from /o-auth-2/token")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? ""

        if bodyString.contains("wrong_username_or_password") {
            throw ComelitError.invalidCredentials
        }

        guard httpResponse.statusCode == 200 else {
            throw ComelitError.server(status: httpResponse.statusCode, body: String(bodyString.prefix(300)))
        }

        return try Self.decodeTokenResponse(data: data)
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
