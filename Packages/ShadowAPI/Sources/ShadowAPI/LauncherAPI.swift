import Foundation

/// `api.eu.shadow.tech` launcher API. The OAuth access token is accepted
/// directly as the bearer; the app's `/shadow/auth_login` step is not needed.
public final class LauncherAPI: Sendable {
    private let http: HTTPClient
    private let auth: AuthSession

    public init(http: HTTPClient, auth: AuthSession) {
        self.http = http
        self.auth = auth
    }

    /// Authenticated call with one refresh-and-retry on 401.
    private func call(_ method: String, _ path: String, vmID: String? = nil, body: HTTPClient.Body = .none, retryOn429: Bool = false) async throws -> HTTPResponse {
        guard let url = URL(string: http.config.apiBase.absoluteString + path) else {
            throw ShadowError.decoding("bad path \(path)")
        }
        let headers = vmID.map { ["X-Vm-Id": $0] } ?? [:]
        let token = try await auth.validAccessToken()
        let first = try await http.api(method, url, bearer: token, headers: headers, body: body, retryOn429: retryOn429)
        guard first.status == 401 else { return first }
        let fresh = try await auth.forceRefresh(stale: token)
        let second = try await http.api(method, url, bearer: fresh, headers: headers, body: body, retryOn429: retryOn429)
        if second.status == 401 {
            await auth.logout()
            throw ShadowError.loginRequired("the launcher API rejected the refreshed token")
        }
        return second
    }

    private func fail(_ r: HTTPResponse, _ endpoint: String) -> ShadowError {
        .http(status: r.status, message: String(r.errorMessage.prefix(400)), endpoint: endpoint)
    }

    public func listVMs() async throws -> [VM] {
        let r = try await call("GET", "/vms?limit=100")
        guard r.isSuccess, let body = r.json else { throw fail(r, "GET /vms") }
        return VM.list(from: body)
    }

    public func vm(_ vmID: String) async throws -> VM? {
        let r = try await call("GET", "/vms/\(vmID)", vmID: vmID)
        return r.isSuccess ? r.json.flatMap { VM(json: $0.unwrapped) } : nil
    }

    public func capabilities(_ vmID: String) async throws -> JSONValue? {
        let r = try await call("GET", "/vms/\(vmID)/capabilities", vmID: vmID)
        return r.isSuccess ? r.json?.unwrapped : nil
    }

    /// Live access info; `nil` when the VM is not running (stopped VMs answer
    /// 400 here rather than an address).
    public func address(_ vmID: String) async throws -> VMAddress? {
        let r = try await call("GET", "/shadow/vm/ip", vmID: vmID, retryOn429: true)
        return r.isSuccess ? VMAddress(json: r.json) : nil
    }

    /// Idle auto-shutdown, in minutes.
    public func timeout(_ vmID: String) async throws -> Int? {
        let r = try await call("GET", "/shadow/vm/timeout", vmID: vmID)
        return r.isSuccess ? r.json?.unwrapped["timeout"]?.int : nil
    }

    public func queueTime(_ vmID: String) async throws -> QueueInfo? {
        let r = try await call("GET", "/shadow/vm/queue/time", vmID: vmID)
        return r.isSuccess ? QueueInfo(json: r.json) : nil
    }

    /// Already-on or accepted are both fine; only clear errors throw.
    public func start(_ vmID: String) async throws {
        let r = try await call("POST", "/shadow/vm/start", vmID: vmID)
        if r.isSuccess || r.status == 409 { return }
        // A VM that's already booting often 400s "already started".
        if r.errorMessage.range(of: "already|running|started", options: [.regularExpression, .caseInsensitive]) != nil { return }
        throw fail(r, "start")
    }

    public func stop(_ vmID: String) async throws {
        let r = try await call("POST", "/shadow/vm/stop", vmID: vmID)
        guard r.isSuccess || r.status == 409 else { throw fail(r, "stop") }
    }

    /// Mint a launcher-scoped VM-proxy token. The body is a bare array of
    /// client specs (not the `{clients:[…]}` the docs describe).
    public func proxyToken(_ vmID: String) async throws -> String {
        let spec: [[String: Any]] = [["client_type": "launcher", "ports": [Any]()]]
        let r = try await call("POST", "/shadow/vm/proximus-credentials", vmID: vmID, body: .json(spec))
        let list = r.json?["data"]?.array ?? r.json?.array ?? []
        guard let token = list.first(where: { $0["client_type"]?.string == "launcher" })?["token"]?.string, !token.isEmpty else {
            throw ShadowError.noProxyToken
        }
        return token
    }

    public func proxyContext(_ vmID: String, address: VMAddress) async throws -> ProxyContext {
        guard let base = address.proxyBase else { throw ShadowError.decoding("VM address has no usable proxy base") }
        return ProxyContext(base: base, token: try await proxyToken(vmID))
    }

    /// Power on, then poll `/shadow/vm/ip` until the VM has an address,
    /// surfacing the queue position while the datacenter is at capacity.
    public func startAndWait(_ vmID: String, pollEvery: TimeInterval = 5, timeout: TimeInterval = 180) -> AsyncThrowingStream<StartProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.start(vmID)
                    continuation.yield(.requested)
                    let began = Date()
                    while Date().timeIntervalSince(began) < timeout {
                        if let addr = try await self.address(vmID) {
                            continuation.yield(.ready(addr))
                            continuation.finish()
                            return
                        }
                        let elapsed = Date().timeIntervalSince(began)
                        if let q = try? await self.queueTime(vmID) {
                            continuation.yield(.queued(q, elapsed: elapsed))
                        } else {
                            continuation.yield(.waiting(elapsed: elapsed))
                        }
                        try await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
                    }
                    throw ShadowError.startTimeout
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
