import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let text: String
    /// Parsed body when it is JSON.
    public let json: JSONValue?

    public var isSuccess: Bool { status < 400 }

    /// `error.message` if present, else the raw body — for error reporting.
    public var errorMessage: String {
        json?["error"]?["message"]?.string ?? json?["message"]?.string ?? json?.serialized() ?? text
    }
}

/// The single funnel every request goes through (shadow-cli's `api()`): fixed
/// header set, Cloudflare detection, optional 429 retry, redacted logging.
public final class HTTPClient: @unchecked Sendable {
    public enum Body {
        case none
        case json(Any)
        case form([(String, String)])
    }

    public let config: ShadowConfig
    private let session: URLSession
    private let deviceUUID: String
    private let logSink: APILogSink?

    public init(
        config: ShadowConfig = .fromEnvironment(),
        deviceUUID: String = DeviceUUID.current,
        logSink: APILogSink? = nil,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.config = config
        self.deviceUUID = deviceUUID
        self.logSink = logSink
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        session = URLSession(configuration: cfg)
    }

    /// `apiHeaders()` from shadow-cli. The same set goes to VM-proxy hosts.
    func apiHeaders(bearer: String, extra: [String: String]) -> [String: String] {
        var h = [
            "Authorization": "Bearer \(bearer)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": config.userAgent,
            "X-Shadow-Agent": config.shadowAgent,
        ]
        if !deviceUUID.isEmpty { h["X-Shadow-Uuid"] = deviceUUID }
        h.merge(extra) { _, new in new }
        return h
    }

    /// Authenticated API call (launcher or VM proxy).
    public func api(
        _ method: String, _ url: URL, bearer: String,
        headers: [String: String] = [:], body: Body = .none, retryOn429: Bool = false
    ) async throws -> HTTPResponse {
        try await send(method, url, headers: apiHeaders(bearer: bearer, extra: headers), body: body, retryOn429: retryOn429)
    }

    /// Bare call (OIDC endpoints): only User-Agent/Accept plus `headers`.
    public func plain(_ method: String, _ url: URL, headers: [String: String] = [:], body: Body = .none) async throws -> HTTPResponse {
        var h = ["User-Agent": config.userAgent, "Accept": "application/json"]
        h.merge(headers) { _, new in new }
        return try await send(method, url, headers: h, body: body, retryOn429: false)
    }

    private func send(_ method: String, _ url: URL, headers: [String: String], body: Body, retryOn429: Bool) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        var headers = headers
        switch body {
        case .none:
            break
        case .json(let obj):
            req.httpBody = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        case .form(let pairs):
            headers["Content-Type"] = "application/x-www-form-urlencoded"
            req.httpBody = Data(HTTPClient.formEncode(pairs).utf8)
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        var attempt = 0
        while true {
            attempt += 1
            let resp = try await perform(req, headers: headers)
            if resp.status == 403, resp.json?["cloudflare_error"] != nil || resp.headers["cf-mitigated"] != nil {
                throw ShadowError.cloudflareBlocked
            }
            if resp.status == 429, retryOn429 {
                guard attempt < 6 else { throw ShadowError.rateLimited(endpoint: url.path) }
                let wait = resp.headers["retry-after"].flatMap(Double.init) ?? 5
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 1), 30) * 1_000_000_000))
                continue
            }
            return resp
        }
    }

    private func perform(_ req: URLRequest, headers: [String: String]) async throws -> HTTPResponse {
        let started = Date()
        func log(status: Int?, respHeaders: [String: String], data: Data?, error: String?) {
            guard let logSink, let url = req.url else { return }
            logSink.record(APILogEntry(
                id: UUID(), date: started, method: req.httpMethod ?? "GET", url: Redactor.url(url),
                requestHeaders: Redactor.headers(headers),
                requestBody: Redactor.body(req.httpBody, contentType: headers["Content-Type"]),
                status: status, responseHeaders: Redactor.headers(respHeaders),
                responseBody: Redactor.body(data, contentType: respHeaders["content-type"]),
                error: error, duration: Date().timeIntervalSince(started)
            ))
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var respHeaders: [String: String] = [:]
            for (k, v) in http.allHeaderFields { respHeaders[String(describing: k).lowercased()] = String(describing: v) }
            log(status: http.statusCode, respHeaders: respHeaders, data: data, error: nil)
            return HTTPResponse(status: http.statusCode, headers: respHeaders, text: String(decoding: data, as: UTF8.self), json: JSONValue(data: data))
        } catch let e as ShadowError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            log(status: nil, respHeaders: [:], data: nil, error: error.localizedDescription)
            throw ShadowError.transport(error.localizedDescription)
        }
    }

    // MARK: - form encoding

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// application/x-www-form-urlencoded, also used for the authorize query.
    public static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    /// Inverse of `formEncode`; tolerant of `+` for spaces.
    public static func formDecode(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (x: Substring) in x.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(x) }
            guard let k = kv.first else { continue }
            out[decode(k)] = kv.count > 1 ? decode(kv[1]) : ""
        }
        return out
    }
}
