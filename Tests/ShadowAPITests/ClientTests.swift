import XCTest
@testable import ShadowAPI

final class CollectingLog: APILogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [APILogEntry] = []
    var entries: [APILogEntry] { lock.withLock { _entries } }
    func record(_ entry: APILogEntry) { lock.withLock { _entries.append(entry) } }
}

final class ClientTests: XCTestCase {
    let config = ShadowConfig(
        oauthIssuer: URL(string: "https://auth.test")!,
        apiBase: URL(string: "https://api.test/v3")!
    )
    let discovery = #"{"authorization_endpoint":"https://auth.test/oauth2/auth","token_endpoint":"https://auth.test/oauth2/token","userinfo_endpoint":"https://auth.test/userinfo"}"#

    func tokens(_ access: String, valid: Bool = true) -> TokenSet {
        TokenSet(accessToken: access, refreshToken: "refresh-1", idToken: nil, tokenType: "bearer", scope: nil,
                 expiresAt: Date().addingTimeInterval(valid ? 3600 : -10))
    }

    func makeClient(_ store: TokenStore, log: APILogSink? = nil) -> ShadowClient {
        ShadowClient(config: config, store: store, logSink: log, protocolClasses: [StubURLProtocol.self])
    }

    override func tearDown() { StubURLProtocol.handler = nil }

    func testHeadersAndVmIdAreSent() async throws {
        StubURLProtocol.handler = { _, _ in (200, [:], #"{"data":{"timeout":30}}"#) }
        let t = try await makeClient(InMemoryTokenStore(tokens("good"))).launcher.timeout("vm-1")
        XCTAssertEqual(t, 30)
        let req = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://api.test/v3/shadow/vm/timeout")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer good")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Vm-Id"), "vm-1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Shadow-Agent"), "Renderer-nodecli")
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.contains("Electron/") ?? false)
    }

    func testConcurrent401sRefreshExactlyOnce() async throws {
        let discovery = self.discovery
        StubURLProtocol.handler = { req, _ in
            switch req.url!.path {
            case "/hydra/.well-known/openid-configuration": return (200, [:], discovery)
            case "/oauth2/token": return (200, [:], #"{"access_token":"fresh","expires_in":3600}"#)
            default:
                let ok = req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                return ok ? (200, [:], #"{"entries":[{"id":"a"}]}"#) : (401, [:], "{}")
            }
        }
        let store = InMemoryTokenStore(tokens("stale"))
        let client = makeClient(store)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await client.launcher.listVMs().count } }
            for try await n in group { XCTAssertEqual(n, 1) }
        }
        XCTAssertEqual(StubURLProtocol.count(path: "/oauth2/token"), 1)
        let saved = try store.load()
        XCTAssertEqual(saved?.accessToken, "fresh")
        // Hydra returned no new refresh token: the old one is kept.
        XCTAssertEqual(saved?.refreshToken, "refresh-1")
    }

    func testExpiredTokenRefreshesBeforeTheCall() async throws {
        let discovery = self.discovery
        StubURLProtocol.handler = { req, body in
            switch req.url!.path {
            case "/hydra/.well-known/openid-configuration": return (200, [:], discovery)
            case "/oauth2/token":
                let form = HTTPClient.formDecode(String(decoding: body ?? Data(), as: UTF8.self))
                XCTAssertEqual(form["grant_type"], "refresh_token")
                XCTAssertEqual(form["refresh_token"], "refresh-1")
                return (200, [:], #"{"access_token":"fresh","refresh_token":"refresh-2","expires_in":3600}"#)
            default: return (200, [:], #"{"entries":[]}"#)
            }
        }
        let store = InMemoryTokenStore(tokens("old", valid: false))
        _ = try await makeClient(store).launcher.listVMs()
        XCTAssertEqual(try store.load()?.refreshToken, "refresh-2")
    }

    func testRejectedRefreshMeansLoginRequired() async throws {
        let discovery = self.discovery
        StubURLProtocol.handler = { req, _ in
            switch req.url!.path {
            case "/hydra/.well-known/openid-configuration": return (200, [:], discovery)
            case "/oauth2/token": return (400, [:], #"{"error":"invalid_grant"}"#)
            default: return (401, [:], "{}")
            }
        }
        let store = InMemoryTokenStore(tokens("stale"))
        let client = makeClient(store)
        do {
            _ = try await client.launcher.listVMs()
            XCTFail("expected loginRequired")
        } catch let e as ShadowError {
            guard case .loginRequired = e else { return XCTFail("got \(e)") }
        }
        XCTAssertNil(try store.load())
        let state = await client.auth.state
        XCTAssertEqual(state, .loggedOut)
    }

    func testCloudflareDetection() async {
        StubURLProtocol.handler = { _, _ in (403, [:], #"{"cloudflare_error":true,"error_code":1010}"#) }
        do {
            _ = try await makeClient(InMemoryTokenStore(tokens("good"))).launcher.listVMs()
            XCTFail("expected cloudflareBlocked")
        } catch { XCTAssertEqual(error as? ShadowError, .cloudflareBlocked) }
    }

    func testRetryOn429() async throws {
        let lock = NSLock()
        var hits = 0
        StubURLProtocol.handler = { _, _ in
            let n = lock.withLock { hits += 1; return hits }
            return n == 1 ? (429, ["Retry-After": "1"], "{}") : (200, [:], #"{"data":{"ip":"1.2.3.4","port":2443}}"#)
        }
        let addr = try await makeClient(InMemoryTokenStore(tokens("good"))).launcher.address("vm-1")
        XCTAssertEqual(addr?.ip, "1.2.3.4")
        XCTAssertEqual(StubURLProtocol.count(path: "/shadow/vm/ip"), 2)
    }

    func testStoppedVMHasNoAddressAndStartToleratesAlreadyRunning() async throws {
        StubURLProtocol.handler = { req, _ in
            req.url!.path.hasSuffix("/ip")
                ? (400, [:], #"{"error":{"message":"vm not started"}}"#)
                : (400, [:], #"{"error":{"message":"VM already started"}}"#)
        }
        let client = makeClient(InMemoryTokenStore(tokens("good")))
        let addr = try await client.launcher.address("vm-1")
        XCTAssertNil(addr)
        try await client.launcher.start("vm-1")
    }

    func testProxyTokenSendsBareArray() async throws {
        StubURLProtocol.handler = { _, body in
            let json = JSONValue(data: body ?? Data())
            XCTAssertEqual(json?.array?.first?["client_type"]?.string, "launcher")
            return (200, [:], #"{"data":[{"client_type":"main","token":"no"},{"client_type":"launcher","token":"ptok"}]}"#)
        }
        let tok = try await makeClient(InMemoryTokenStore(tokens("good"))).launcher.proxyToken("vm-1")
        XCTAssertEqual(tok, "ptok")
    }

    func testSpiceConsoleLadder() async throws {
        let proxy = ProxyContext(base: URL(string: "https://x.compute.test/2")!, token: "ptok")
        let client = makeClient(InMemoryTokenStore(tokens("good")))

        // Legacy proxy: secret only → fixed /spice route.
        StubURLProtocol.handler = { req, body in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ptok")
            let sent = JSONValue(data: body ?? Data())
            XCTAssertEqual(sent?["type"]?.string, "launcher")
            XCTAssertNotNil(sent?["opaque"]?.string, "opaque must be a JSON string")
            return (200, [:], #"{"data":{"id":"c1","spice_secret":"tick"}}"#)
        }
        let legacy = try await client.proxy.openSpiceConsole(proxy)
        XCTAssertEqual(legacy.uri, "wss://x.compute.test/2/spice")
        XCTAssertEqual(legacy.secret, "tick")
        XCTAssertEqual(legacy.clientID, "c1")

        // Newer proxy: spice_url handed back directly.
        StubURLProtocol.handler = { _, _ in (200, [:], #"{"id":7,"spice_url":"wss://y/spice","spice_secret":"s"}"#) }
        let modern = try await client.proxy.openSpiceConsole(proxy)
        XCTAssertEqual(modern.uri, "wss://y/spice")
        XCTAssertEqual(modern.clientID, "7")

        // Fallback: remote-consoles.
        StubURLProtocol.handler = { req, _ in
            req.url!.path.hasSuffix("/remote-consoles")
                ? (200, [:], #"{"data":{"spice_url":"wss://z/spice","spice_secret":"rs"}}"#)
                : (200, [:], #"{"data":{"id":"c9"}}"#)
        }
        let fallback = try await client.proxy.openSpiceConsole(proxy)
        XCTAssertEqual(fallback.uri, "wss://z/spice")
        XCTAssertEqual(fallback.secret, "rs")
        XCTAssertEqual(StubURLProtocol.count(path: "/2/c9/remote-consoles"), 1)
    }

    func testLogEntriesAreRedacted() async throws {
        let log = CollectingLog()
        StubURLProtocol.handler = { _, _ in (200, [:], #"{"data":[{"client_type":"launcher","token":"proxy-token-value-123"}]}"#) }
        _ = try await makeClient(InMemoryTokenStore(tokens("access-token-value-123")), log: log).launcher.proxyToken("vm-1")
        let e = try XCTUnwrap(log.entries.first)
        let dump = "\(e.requestHeaders) \(e.responseBody ?? "") \(e.curl)"
        XCTAssertFalse(dump.contains("access-token-value-123"))
        XCTAssertFalse(dump.contains("proxy-token-value-123"))
        XCTAssertEqual(e.status, 200)
    }
}
