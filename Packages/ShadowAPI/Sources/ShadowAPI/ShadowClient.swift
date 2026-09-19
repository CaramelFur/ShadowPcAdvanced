import Foundation

/// Wires the pieces together: one HTTP funnel, one session, both APIs.
public final class ShadowClient: Sendable {
    public let http: HTTPClient
    public let oauth: OAuthClient
    public let auth: AuthSession
    public let launcher: LauncherAPI
    public let proxy: VMProxyAPI

    public init(config: ShadowConfig = .fromEnvironment(), store: TokenStore, logSink: APILogSink? = nil, protocolClasses: [AnyClass]? = nil) {
        http = HTTPClient(config: config, logSink: logSink, protocolClasses: protocolClasses)
        oauth = OAuthClient(http: http)
        auth = AuthSession(oauth: oauth, store: store)
        launcher = LauncherAPI(http: http, auth: auth)
        proxy = VMProxyAPI(http: http)
    }

    /// Mint a proxy token and open a SPICE console for a running VM.
    public func openSpiceConsole(vmID: String, address: VMAddress) async throws -> SpiceTicket {
        try await proxy.openSpiceConsole(try await launcher.proxyContext(vmID, address: address))
    }
}
