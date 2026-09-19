import Foundation

/// Loosely-typed JSON. The launcher API is reverse-engineered and its shapes
/// drift (`data` envelope optional, `status` string-or-object, …), so all
/// lenient decoding goes through this instead of strict `Codable` structs.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any: Any?) {
        switch any {
        case nil, is NSNull:
            self = .null
        case let n as NSNumber:
            // JSONSerialization bridges booleans as NSNumber too.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]:
            self = .object(o.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    public init?(data: Data) {
        guard !data.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        self.init(any: any)
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if n.rounded() == n, abs(n) < 9e15 { return Int64(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public func serialized(pretty: Bool = false) -> String {
        var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        guard let d = try? JSONSerialization.data(withJSONObject: any, options: opts) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self, let v = o[key], v != .null { return v }
        return nil
    }

    /// `body.data ?? body` — the envelope is optional across endpoints.
    public var unwrapped: JSONValue { self["data"] ?? self }

    public var isNull: Bool { self == .null }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var int: Int? { double.flatMap { $0.isFinite ? Int($0) : nil } }

    /// String, or a number rendered without a trailing `.0`.
    public var stringified: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    /// JS-style truthiness, used where shadow-cli relies on it.
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }
}
