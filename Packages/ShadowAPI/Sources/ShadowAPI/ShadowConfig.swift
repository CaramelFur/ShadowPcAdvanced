import Foundation

/// Endpoints and client identity recovered from the Shadow PC.app bundle.
/// Every value can be overridden through the same environment variables
/// shadow-cli honours.
public struct ShadowConfig: Sendable, Equatable {
    public var oauthIssuer: URL
    public var clientID: String
    public var redirectURI: String
    public var scope: String
    /// Launcher API base. Per-user in principle (resolved via TINAG), but the EU
    /// production base is stable.
    public var apiBase: URL
    /// Cloudflare (error 1010) bans plain library user-agents; look like the app.
    public var userAgent: String
    public var shadowAgent: String

    public var discoveryURL: URL {
        oauthIssuer.appendingPathComponent("hydra/.well-known/openid-configuration")
    }

    /// URL scheme of `redirectURI` — the one the app has to receive.
    public var redirectScheme: String {
        redirectURI.components(separatedBy: "://").first ?? redirectURI
    }

    public init(
        oauthIssuer: URL = URL(string: "https://auth.eu.shadow.tech")!,
        clientID: String = "0c6ee748-5352-412c-944f-947e15df8bf0",
        redirectURI: String = "tech.shadow://openidconnect/callback",
        scope: String = "openid email vm_access api profile offline",
        apiBase: URL = URL(string: "https://api.eu.shadow.tech/v1/pu/virtual-desktop/launcher-api/v3")!,
        userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) shadow/9.9.10457 Chrome/126.0.0.0 Electron/31.0.0 Safari/537.36",
        shadowAgent: String = "Renderer-nodecli"
    ) {
        self.oauthIssuer = oauthIssuer
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
        self.apiBase = apiBase
        self.userAgent = userAgent
        self.shadowAgent = shadowAgent
    }

    /// Defaults with shadow-cli's environment overrides applied.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ShadowConfig {
        var c = ShadowConfig()
        if let v = env["BASE_OAUTH_URL"], let u = URL(string: v) { c.oauthIssuer = u }
        if let v = env["OAUTH_CLIENT_ID"], !v.isEmpty { c.clientID = v }
        if let v = env["OAUTH_REDIRECT_URI"], !v.isEmpty { c.redirectURI = v }
        if let v = env["SHADOW_API_BASE"], let u = URL(string: v) { c.apiBase = u }
        return c
    }
}
