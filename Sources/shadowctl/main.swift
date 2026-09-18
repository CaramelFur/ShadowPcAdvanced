import AppKit
import Foundation
import ShadowAPI

// Headless parity CLI for ShadowAPI — compare against `node shadow.mjs`.
//   shadowctl list [--token-file <oauth_tokens.json>] [--no-refresh]
//   shadowctl device-uuid | handler | token-check | config

struct StderrLog: APILogSink {
    func record(_ e: APILogEntry) {
        FileHandle.standardError.write(Data("  \(e.method) \(e.url) -> \(e.status.map(String.init) ?? e.error ?? "?")\n".utf8))
    }
}

/// Never writes: `--no-refresh` runs must not fork shadow-cli's rotating refresh token.
struct ReadOnlyStore: TokenStore {
    let inner: TokenStore
    func load() throws -> TokenSet? { try inner.load() }
    func save(_ tokens: TokenSet) throws {}
    func clear() throws {}
}

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}

let verbose = flag("-v")
let noRefresh = flag("--no-refresh")
let tokenFile = option("--token-file")

@MainActor func makeClient() -> ShadowClient {
    var store: TokenStore = tokenFile.map { FileTokenStore(url: URL(fileURLWithPath: $0)) } ?? KeychainTokenStore()
    if noRefresh { store = ReadOnlyStore(inner: store) }
    return ShadowClient(store: store, logSink: verbose ? StderrLog() : nil)
}

func die(_ m: String) -> Never {
    FileHandle.standardError.write(Data("error: \(m)\n".utf8))
    exit(1)
}

@MainActor func run() async throws {
    switch args.first ?? "help" {
    case "config":
        let c = ShadowConfig.fromEnvironment()
        print("issuer:   \(c.oauthIssuer.absoluteString)")
        print("api base: \(c.apiBase.absoluteString)")
        print("redirect: \(c.redirectURI)")

    case "device-uuid":
        print(DeviceUUID.current)

    case "handler":
        let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "tech.shadow://probe")!)
        print(url?.path ?? "(none)")

    case "token-check":
        let store: TokenStore = tokenFile.map { FileTokenStore(url: URL(fileURLWithPath: $0)) } ?? KeychainTokenStore()
        guard let t = try store.load() else { die("no stored tokens") }
        let left = Int(t.expiresAt.timeIntervalSinceNow)
        print("access token: \(Redactor.mask(t.accessToken))  \(left > 0 ? "valid for \(left)s" : "expired \(-left)s ago")")
        print("refresh token: \(t.refreshToken == nil ? "none" : "present")")

    case "list":
        let client = makeClient()
        if noRefresh, let t = try? ReadOnlyStore(inner: tokenFile.map { FileTokenStore(url: URL(fileURLWithPath: $0)) } ?? KeychainTokenStore()).load(), !t.isValid() {
            die("stored access token is expired and --no-refresh was given")
        }
        let vms = try await client.launcher.listVMs()
        if vms.isEmpty { print("No VMs on this account."); return }
        print("\n\(vms.count) VM(s):")
        for vm in vms {
            async let detail = client.launcher.vm(vm.id)
            async let timeout = client.launcher.timeout(vm.id)
            async let addr = client.launcher.address(vm.id)
            let (d, t, a) = try await (detail, timeout, addr)
            var signals: VMStatusSignals?
            if let a, let ctx = try? await client.launcher.proxyContext(vm.id, address: a) {
                signals = await client.proxy.status(ctx)
            }
            var merged = vm
            if let d { merged.status = d.status ?? vm.status }
            print("\n  \(vm.name)  [\(merged.state(address: a, proxy: signals))]")
            func kv(_ k: String, _ v: String?) {
                if let v, !v.isEmpty { print("      \((k + ":").padding(toLength: 18, withPad: " ", startingAt: 0)) \(v)") }
            }
            kv("id", vm.id)
            kv("datacenter", vm.datacenter)
            kv("hardware", vm.hardware)
            kv("provider", vm.provider)
            if let s = signals { kv("signals", "vm_status=\(s.vmStatus ?? "\"\"") reachable=\(s.reachable) streamer_up=\(s.streamerUp)") }
            if let a { kv("address", "\(a.ip)\(a.sessionID.map { "  session=\($0)" } ?? "")") }
            kv("auto-shutdown", t.map { "\($0) min idle" })
        }
        print("")

    default:
        print("usage: shadowctl [-v] <list|device-uuid|handler|token-check|config> [--token-file <path>] [--no-refresh]")
    }
}

do { try await run() } catch { die(error.localizedDescription) }
