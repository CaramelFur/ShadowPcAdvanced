import Foundation
import Security

public protocol TokenStore: Sendable {
    func load() throws -> TokenSet?
    func save(_ tokens: TokenSet) throws
    func clear() throws
}

private func encodeTokens(_ t: TokenSet) throws -> Data {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try enc.encode(t)
}

/// JSON file, mode 0600. Compatible with shadow-cli's `state/oauth_tokens.json`.
public struct FileTokenStore: TokenStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> TokenSet? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: Data(contentsOf: url))
    }

    public func save(_ tokens: TokenSet) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodeTokens(tokens).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Login-keychain generic password holding the token JSON. Under ad-hoc
/// signing the ACL prompts again after each rebuild; a denied read is reported
/// as "no tokens", never an error.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = "dev.caramelfur.shadowpcadvanced.oauth", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> TokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet) throws {
        let data = try encodeTokens(tokens)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "ShadowPcAdvanced session"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ShadowError.transport("Keychain write failed (\(status))")
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ShadowError.transport("Keychain delete failed (\(status))")
        }
    }
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: TokenSet?

    public init(_ tokens: TokenSet? = nil) { self.tokens = tokens }

    public func load() throws -> TokenSet? { lock.withLock { tokens } }
    public func save(_ tokens: TokenSet) throws { lock.withLock { self.tokens = tokens } }
    public func clear() throws { lock.withLock { tokens = nil } }
}
