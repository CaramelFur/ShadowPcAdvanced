import Foundation

/// Per-session VM proxy ("Proximus"): `proximus_url`, else `https://<ip>/<port÷1000>`.
public final class VMProxyAPI: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient) { self.http = http }

    /// reachable / streamer_up / vm_status. Best effort: `nil` on any failure.
    public func status(_ proxy: ProxyContext) async -> VMStatusSignals? {
        await statusResponse(proxy).signals
    }

    /// Same, plus the HTTP status so callers can tell an expired proxy token
    /// (401/403) from an unreachable VM (`code == nil`).
    public func statusResponse(_ proxy: ProxyContext) async -> (code: Int?, signals: VMStatusSignals?) {
        guard let r = try? await http.api("GET", proxy.url("/status"), bearer: proxy.token) else { return (nil, nil) }
        return (r.status, r.isSuccess ? VMStatusSignals(json: r.json?.unwrapped) : nil)
    }

    /// Creates the launcher client, which provisions the SPICE ticket.
    /// `opaque` is a JSON *string*, not an object.
    func createLauncherClient(_ proxy: ProxyContext) async throws -> JSONValue {
        let opaque: [String: Any] = [
            "os": "Mac", "arch": "x64", "platform-type": "desktop", "os-name": "Mac",
            "timestamp": ISO8601DateFormatter.shadow.string(from: Date()),
        ]
        let opaqueData = try JSONSerialization.data(withJSONObject: opaque, options: [.withoutEscapingSlashes])
        let body: [String: Any] = ["type": "launcher", "opaque": String(decoding: opaqueData, as: UTF8.self)]
        let r = try await http.api("POST", proxy.url("/clients"), bearer: proxy.token, body: .json(body))
        guard let d = r.json?.unwrapped, d["id"]?.stringified != nil else {
            throw ShadowError.http(status: r.status, message: String(r.errorMessage.prefix(400)), endpoint: "POST /clients")
        }
        return d
    }

    /// The console ladder from shadow-cli's `getSpiceConsole`:
    /// `spice_url` → `spice_secret` + fixed `/spice` route → remote-consoles.
    public func openSpiceConsole(_ proxy: ProxyContext) async throws -> SpiceTicket {
        let d = try await createLauncherClient(proxy)
        let clientID = d["id"]?.stringified ?? ""
        let secret = d["spice_secret"]?.string ?? ""

        // Newer proxy: full spice_url handed back directly.
        if let uri = d["spice_url"]?.string, !uri.isEmpty {
            return SpiceTicket(uri: uri, secret: secret, clientID: clientID, proxy: proxy)
        }
        // Legacy proxy: ticket in spice_secret; the websocket bridge is the
        // fixed /<N>/spice route on the proxy host.
        if !secret.isEmpty {
            let base = proxy.base.absoluteString
            let uri = (base.hasPrefix("https:") ? "wss:" + base.dropFirst("https:".count) : base) + "/spice"
            return SpiceTicket(uri: uri, secret: secret, clientID: clientID, proxy: proxy)
        }
        // Fallback: the documented per-client remote-consoles route.
        let body: [String: Any] = ["protocol": "spice", "type": "spice-html5"]
        let rc = try await http.api("POST", proxy.url("/\(clientID)/remote-consoles"), bearer: proxy.token, body: .json(body))
        if let rd = rc.json?.unwrapped, let uri = rd["spice_url"]?.string, !uri.isEmpty {
            return SpiceTicket(uri: uri, secret: rd["spice_secret"]?.string ?? "", clientID: clientID, proxy: proxy)
        }
        throw ShadowError.noSpiceConsole(Redactor.redact(d).serialized())
    }

    /// Tear down a launcher client so the single-client SPICE console isn't
    /// left held by a closed window.
    public func deleteClient(_ proxy: ProxyContext, clientID: String) async {
        guard !clientID.isEmpty else { return }
        _ = try? await http.api("DELETE", proxy.url("/clients/\(clientID)"), bearer: proxy.token)
    }
}

extension ISO8601DateFormatter {
    /// `new Date().toISOString()` format.
    static let shadow: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
