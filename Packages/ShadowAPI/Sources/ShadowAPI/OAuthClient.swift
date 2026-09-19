import Foundation

public struct OIDCDiscovery: Sendable, Equatable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let userinfoEndpoint: URL?
}

/// A pending interactive login. The verifier never leaves memory.
public struct AuthorizationRequest: Sendable, Equatable {
    public let url: URL
    public let state: String
    public let verifier: String
}

/// Public PKCE client against Ory Hydra (auth.eu.shadow.tech).
public actor OAuthClient {
    private let http: HTTPClient
    private var config: ShadowConfig { http.config }
    private var cachedDiscovery: OIDCDiscovery?

    public init(http: HTTPClient) { self.http = http }

    public func discovery() async throws -> OIDCDiscovery {
        if let cachedDiscovery { return cachedDiscovery }
        let r = try await http.plain("GET", config.discoveryURL)
        guard r.isSuccess, let j = r.json,
              let auth = j["authorization_endpoint"]?.string.flatMap(URL.init(string:)),
              let token = j["token_endpoint"]?.string.flatMap(URL.init(string:))
        else { throw ShadowError.oauth("OIDC discovery failed: \(r.status) \(r.errorMessage.prefix(200))") }
        let d = OIDCDiscovery(
            authorizationEndpoint: auth, tokenEndpoint: token,
            userinfoEndpoint: j["userinfo_endpoint"]?.string.flatMap(URL.init(string:))
        )
        cachedDiscovery = d
        return d
    }

    public func makeAuthorizationRequest() async throws -> AuthorizationRequest {
        let d = try await discovery()
        let verifier = PKCE.randomToken(bytes: 32)
        let state = PKCE.randomToken(bytes: 16)
        let query = HTTPClient.formEncode([
            ("client_id", config.clientID),
            ("redirect_uri", config.redirectURI),
            ("response_type", "code"),
            ("scope", config.scope),
            ("code_challenge", PKCE.challenge(for: verifier)),
            ("code_challenge_method", "S256"),
            ("prompt", "consent"),
            ("state", state),
        ])
        guard var comps = URLComponents(url: d.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw ShadowError.oauth("bad authorization endpoint")
        }
        comps.percentEncodedQuery = query
        guard let url = comps.url else { throw ShadowError.oauth("could not build the authorization URL") }
        return AuthorizationRequest(url: url, state: state, verifier: verifier)
    }

    /// Extracts the authorization code from a `tech.shadow://…` redirect, or
    /// accepts a bare pasted code. Custom-scheme URLs don't reliably parse via
    /// `URL`, so the query is pulled out by hand (as shadow-cli does).
    ///
    /// A redirect URL must carry the matching `state`; only a bare code (manual
    /// paste, no URL) is accepted without one.
    public static func parseCallback(_ input: String, expectedState: String) throws -> String {
        let pasted = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pasted.contains("code=") || pasted.contains("://") || pasted.contains("error=") else {
            guard !pasted.isEmpty else { throw ShadowError.noAuthorizationCode }
            return pasted
        }
        var qs = pasted
        if let q = pasted.firstIndex(of: "?") { qs = String(pasted[pasted.index(after: q)...]) }
        if let hash = qs.firstIndex(of: "#") { qs = String(qs[..<hash]) }
        let p = HTTPClient.formDecode(qs)
        if let err = p["error"] {
            throw ShadowError.oauth("\(err) \(p["error_description"] ?? "")".trimmingCharacters(in: .whitespaces))
        }
        guard p["state"] == expectedState else { throw ShadowError.stateMismatch }
        guard let code = p["code"], !code.isEmpty else { throw ShadowError.noAuthorizationCode }
        return code
    }

    public func exchange(code: String, verifier: String) async throws -> TokenSet {
        try await token([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", config.redirectURI),
            ("client_id", config.clientID),
            ("code_verifier", verifier),
        ])
    }

    /// Hydra may rotate the refresh token; when it doesn't return a new one the
    /// old one stays valid and is carried over.
    public func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        guard let rt = tokens.refreshToken, !rt.isEmpty else { throw ShadowError.loginRequired("no refresh token") }
        var fresh = try await token([
            ("grant_type", "refresh_token"),
            ("refresh_token", rt),
            ("client_id", config.clientID),
            ("scope", config.scope),
        ])
        if fresh.refreshToken == nil { fresh.refreshToken = rt }
        return fresh
    }

    public func userinfo(accessToken: String) async throws -> JSONValue {
        guard let url = try await discovery().userinfoEndpoint else { throw ShadowError.oauth("no userinfo endpoint") }
        let r = try await http.plain("GET", url, headers: ["Authorization": "Bearer \(accessToken)"])
        guard r.isSuccess else { throw ShadowError.http(status: r.status, message: r.errorMessage, endpoint: "userinfo") }
        return r.json ?? .string(r.text)
    }

    private func token(_ form: [(String, String)]) async throws -> TokenSet {
        let d = try await discovery()
        let r = try await http.plain("POST", d.tokenEndpoint, body: .form(form))
        guard r.isSuccess else {
            let detail = r.json?["error_description"]?.string ?? r.json?["error"]?.string ?? String(r.text.prefix(200))
            throw ShadowError.oauth("token endpoint \(r.status): \(detail)")
        }
        guard let j = r.json, let tokens = TokenSet(tokenResponse: j) else {
            throw ShadowError.decoding("token endpoint returned no access_token")
        }
        return tokens
    }
}
