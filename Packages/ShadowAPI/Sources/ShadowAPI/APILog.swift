import Foundation

/// One request/response pair. Everything in here is already redacted.
public struct APILogEntry: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let method: String
    public let url: String
    public let requestHeaders: [String: String]
    public let requestBody: String?
    public let status: Int?
    public let responseHeaders: [String: String]
    public let responseBody: String?
    public let error: String?
    public let duration: TimeInterval

    /// Reproduces the request with secrets still redacted.
    public var curl: String {
        var parts = ["curl -X \(method) '\(url)'"]
        for (k, v) in requestHeaders.sorted(by: { $0.key < $1.key }) { parts.append("-H '\(k): \(v)'") }
        if let b = requestBody, !b.isEmpty { parts.append("--data '\(b.replacingOccurrences(of: "'", with: "'\\''"))'") }
        return parts.joined(separator: " \\\n  ")
    }
}

public protocol APILogSink: Sendable {
    func record(_ entry: APILogEntry)
}

/// Strips secrets before anything reaches a log sink.
public enum Redactor {
    static let sensitiveHeaders: Set<String> = ["authorization", "cookie", "set-cookie", "proxy-authorization"]
    static let sensitiveKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "token", "spice_secret", "password", "secret",
        "code", "code_verifier", "tlskey", "streamingtoken", "cbp_token",
    ]
    static let sensitiveQueryKeys: Set<String> = ["code", "state", "password", "token", "access_token"]
    static let maxBody = 64 * 1024

    /// `abcd…(94)` — enough to tell two tokens apart, never enough to use one.
    public static func mask(_ s: String) -> String {
        s.count <= 8 ? "…(\(s.count))" : "\(s.prefix(4))…(\(s.count))"
    }

    public static func headers(_ h: [String: String]) -> [String: String] {
        var out = h
        for (k, v) in h where sensitiveHeaders.contains(k.lowercased()) {
            if let space = v.firstIndex(of: " ") {
                out[k] = "\(v[..<space]) \(mask(String(v[v.index(after: space)...])))"
            } else {
                out[k] = mask(v)
            }
        }
        return out
    }

    public static func url(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems else {
            return url.absoluteString
        }
        comps.queryItems = items.map { item in
            guard sensitiveQueryKeys.contains(item.name.lowercased()), let v = item.value else { return item }
            return URLQueryItem(name: item.name, value: mask(v))
        }
        return comps.string ?? url.absoluteString
    }

    public static func body(_ data: Data?, contentType: String?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let text: String
        if let json = JSONValue(data: data), json.object != nil || json.array != nil {
            text = redact(json).serialized(pretty: true)
        } else if (contentType ?? "").contains("x-www-form-urlencoded") {
            text = form(String(decoding: data, as: UTF8.self))
        } else {
            text = looseTokens(String(decoding: data, as: UTF8.self))
        }
        return text.count > maxBody ? String(text.prefix(maxBody)) + "\n…(truncated)" : text
    }

    static func redact(_ v: JSONValue) -> JSONValue {
        switch v {
        case .array(let a):
            return .array(a.map(redact))
        case .object(let o):
            return .object(Dictionary(uniqueKeysWithValues: o.map { key, value -> (String, JSONValue) in
                if sensitiveKeys.contains(key.lowercased()), let s = value.stringified { return (key, .string(mask(s))) }
                return (key, redact(value))
            }))
        case .string(let s):
            return .string(looseTokens(s))
        default:
            return v
        }
    }

    static func form(_ s: String) -> String {
        s.split(separator: "&").map { pair -> String in
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, sensitiveKeys.contains(kv[0].lowercased()) else { return String(pair) }
            return "\(kv[0])=\(mask(String(kv[1])))"
        }.joined(separator: "&")
    }

    /// Last line of defence: anything JWT-shaped or bearer-shaped in free text.
    static func looseTokens(_ s: String) -> String {
        var out = s
        for pattern in [#"eyJ[A-Za-z0-9_\-]{8,}(\.[A-Za-z0-9_\-]+){0,2}"#, #"(?i)(bearer\s+)[A-Za-z0-9._\-]{16,}"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hit = ns.substring(with: m.range)
                out = (out as NSString).replacingCharacters(in: m.range, with: mask(hit))
            }
        }
        return out
    }
}
