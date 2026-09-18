import Foundation

/// Same JSON shape as shadow-cli's `state/oauth_tokens.json`.
public struct TokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var tokenType: String?
    public var scope: String?
    /// Absolute expiry, already 60 s early. Stored as epoch **milliseconds**.
    public var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case scope
        case expiresAt = "expires_at"
    }

    public init(accessToken: String, refreshToken: String?, idToken: String?, tokenType: String?, scope: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
    }

    /// From a token-endpoint response.
    public init?(tokenResponse j: JSONValue, now: Date = Date()) {
        guard let access = j["access_token"]?.string, !access.isEmpty else { return nil }
        let expiresIn = j["expires_in"]?.double ?? 3600
        self.init(
            accessToken: access,
            refreshToken: j["refresh_token"]?.string,
            idToken: j["id_token"]?.string,
            tokenType: j["token_type"]?.string,
            scope: j["scope"]?.string,
            expiresAt: now.addingTimeInterval(expiresIn - 60)
        )
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try c.decodeIfPresent(String.self, forKey: .idToken)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        let raw = try c.decodeIfPresent(Double.self, forKey: .expiresAt) ?? 0
        // Tolerate seconds, though shadow-cli always writes milliseconds.
        expiresAt = Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessToken, forKey: .accessToken)
        try c.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try c.encodeIfPresent(idToken, forKey: .idToken)
        try c.encodeIfPresent(tokenType, forKey: .tokenType)
        try c.encodeIfPresent(scope, forKey: .scope)
        try c.encode(Int64((expiresAt.timeIntervalSince1970 * 1000).rounded()), forKey: .expiresAt)
    }

    public func isValid(at now: Date = Date()) -> Bool { now < expiresAt }
}
