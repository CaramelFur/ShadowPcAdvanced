import AppKit
import ShadowAPI

struct VMRow: Identifiable, Equatable {
    enum Activity: Equatable {
        case starting(String)
        case stopping
    }

    var vm: VM
    var address: VMAddress?
    var signals: VMStatusSignals?
    var activity: Activity?
    var error: String?

    var id: String { vm.id }
    /// A stop we asked for wins: the proxy isn't polled anymore by then.
    var state: VMState { activity == .stopping ? .stopping : vm.state(address: address, proxy: signals) }
    var isRunning: Bool { address != nil }
    /// A VM we are shutting down still has an address, but no console URL worth using.
    var consoleAddress: VMAddress? { activity == .stopping ? nil : address }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var authState: AuthState?
    @Published private(set) var rows: [VMRow] = []
    @Published private(set) var listError: String?
    @Published private(set) var lastRefresh: Date?

    let client: ShadowClient
    let logStore = APILogStore()
    let login: LoginController
    private(set) lazy var consoles = ConsoleWindowManager(model: self)

    private var refreshLoop: Task<Void, Never>?
    /// Proxy tokens are minted per (VM, session); re-minting on every 10 s
    /// refresh would be far too heavy.
    private var proxyContexts: [String: (key: String, context: ProxyContext)] = [:]
    private var proxyMints: [String: (key: String, task: Task<ProxyContext, Error>)] = [:]
    private var statusUnavailableUntil: [String: Date] = [:]
    static let refreshInterval: TimeInterval = 10

    private init() {
        client = ShadowClient(store: AppModel.makeTokenStore(), logSink: logStore)
        login = LoginController(client: client)
    }

    /// Keychain inside the .app; a 0600 file for unbundled dev runs (where the
    /// Keychain ACL would prompt on every build anyway).
    static func makeTokenStore() -> TokenStore {
        let env = ProcessInfo.processInfo.environment
        if let path = env["FUNKYSHADOW_TOKEN_FILE"], !path.isEmpty {
            return FileTokenStore(url: URL(fileURLWithPath: path))
        }
        if Bundle.main.bundleURL.pathExtension == "app" { return KeychainTokenStore() }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileTokenStore(url: dir.appendingPathComponent("FunkyShadow/oauth_tokens.json"))
    }

    func start() {
        Task {
            await login.claimer.recoverIfNeeded()
            for await state in await client.auth.states() {
                authState = state
                if state == .loggedIn { startRefreshing() } else { stopRefreshing() }
            }
        }
    }

    func signOut() async {
        consoles.closeAll()
        await client.auth.logout()
    }

    // MARK: - VM list

    private func startRefreshing() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
            }
        }
    }

    private func stopRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = nil
        rows = []
        proxyContexts = [:]
        proxyMints = [:]
        statusUnavailableUntil = [:]
        listError = nil
    }

    func refresh() async {
        do {
            let vms = try await client.launcher.listVMs()
            var fresh: [VMRow] = []
            for vm in vms {
                var row = rows.first { $0.id == vm.id } ?? VMRow(vm: vm)
                row.vm = vm
                row.address = try await client.launcher.address(vm.id)
                // The live row, not the copy from before the await: startVM or a
                // console may have learned the new address meanwhile.
                let live = rows.first { $0.id == vm.id }
                if live?.address?.sessionKey != row.address?.sessionKey {
                    invalidateSession(vm.id, keeping: row.address?.sessionKey)
                }
                row.activity = live?.activity
                row.signals = await proxySignals(vmID: vm.id, address: row.consoleAddress)
                fresh.append(row)
            }
            // Keep activity/error set while the awaits above were in flight.
            rows = fresh.map { row in
                var row = row
                if let live = rows.first(where: { $0.id == row.id }) {
                    row.activity = live.activity
                    row.error = live.error
                }
                return row
            }
            listError = nil
            lastRefresh = Date()
        } catch is CancellationError {
        } catch ShadowError.loginRequired, ShadowError.notLoggedIn {
            // AuthSession already published .loggedOut.
        } catch {
            listError = error.localizedDescription
        }
    }

    /// Cached proxy context for a running VM, minted on demand. It belongs to
    /// one session (`VMAddress.sessionKey`): a restarted VM never gets the old one.
    func proxyContext(vmID: String, address: VMAddress, forceNew: Bool = false) async throws -> ProxyContext {
        let key = address.sessionKey
        if !forceNew, let cached = proxyContexts[vmID], cached.key == key { return cached.context }
        // The refresh loop and a console tend to ask at the same moment (VM just
        // came up): share one mint instead of racing two tokens.
        if let pending = proxyMints[vmID], pending.key == key { return try await pending.task.value }
        let task = Task { [client] in try await client.launcher.proxyContext(vmID, address: address) }
        proxyMints[vmID] = (key, task)
        let result = await task.result
        // Invalidated while minting (VM stopped or restarted): hand the token to
        // the caller, whose session check decides, but keep it out of the cache.
        let current = proxyMints[vmID]?.task == task
        if current { proxyMints[vmID] = nil }
        let ctx = try result.get()
        if current { proxyContexts[vmID] = (key, ctx) }
        return ctx
    }

    /// Nothing minted for a session survives it: called when the VM stops, is
    /// being stopped, or shows up with another session id or proxy. `keeping`:
    /// the session being switched to, which refresh(), startVM and a console can
    /// all announce within the same moment; its token (or the mint under way)
    /// must not be thrown away by whoever comes second.
    private func invalidateSession(_ vmID: String, keeping key: String? = nil) {
        if proxyContexts[vmID]?.key != key { proxyContexts[vmID] = nil }
        if proxyMints[vmID]?.key != key { proxyMints[vmID] = nil }
        statusUnavailableUntil[vmID] = nil
    }

    /// `consoleOpen`: a console registers the launcher client, which is what
    /// makes the proxy answer /status at all.
    func proxySignals(vmID: String, address: VMAddress?, consoleOpen: Bool = false) async -> VMStatusSignals? {
        guard let address else {
            invalidateSession(vmID)
            return nil
        }
        if consoleOpen {
            statusUnavailableUntil[vmID] = nil
        } else if let until = statusUnavailableUntil[vmID], Date() < until {
            return nil
        }
        guard let ctx = try? await proxyContext(vmID: vmID, address: address) else { return nil }
        let first = await client.proxy.statusResponse(ctx)
        if first.clientMissing {
            // Not an auth problem, so don't burn a token re-mint on it; ask again
            // in a minute (shadow-cli or a console may register the client meanwhile).
            statusUnavailableUntil[vmID] = Date().addingTimeInterval(60)
            return nil
        }
        guard first.code == 401 || first.code == 403 else { return first.signals }
        // Proxy token expired: mint once more.
        guard let renewed = try? await proxyContext(vmID: vmID, address: address, forceNew: true) else { return nil }
        return await client.proxy.statusResponse(renewed).signals
    }

    private func update(_ vmID: String, _ change: (inout VMRow) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == vmID }) else { return }
        change(&rows[i])
    }

    /// An address learned between refreshes (VM just started, or a console's
    /// Reconnect asked the API). Consoles watch the row, so it has to be current.
    func noteAddress(_ address: VMAddress?, for vmID: String) {
        guard let row = rows.first(where: { $0.id == vmID }), row.address != address else { return }
        if row.address?.sessionKey != address?.sessionKey { invalidateSession(vmID, keeping: address?.sessionKey) }
        update(vmID) {
            $0.address = address
            if address == nil { $0.signals = nil }
        }
    }

    // MARK: - actions

    func startVM(_ vmID: String) async {
        update(vmID) { $0.activity = .starting("requesting power-on…"); $0.error = nil }
        do {
            for try await step in client.launcher.startAndWait(vmID) {
                switch step {
                case .requested:
                    update(vmID) { $0.activity = .starting("power-on requested…") }
                case .waiting(let elapsed):
                    update(vmID) { $0.activity = .starting("waiting for VM address… \(Int(elapsed)) s") }
                case .queued(let q, _):
                    let parts = [q.position.map { "pos \($0)" }, q.estimatedTime.map { "eta \($0) s" }].compactMap { $0 }
                    update(vmID) { $0.activity = .starting("queued" + (parts.isEmpty ? "…" : " (\(parts.joined(separator: ", ")))")) }
                case .ready(let address):
                    noteAddress(address, for: vmID)
                }
            }
            update(vmID) { $0.activity = nil }
            await refresh()
        } catch {
            update(vmID) { $0.activity = nil; $0.error = error.localizedDescription }
        }
    }

    func stopVM(_ vmID: String) async {
        update(vmID) { $0.activity = .stopping; $0.error = nil }
        do {
            try await client.launcher.stop(vmID)
            invalidateSession(vmID)
            // The address disappears once the VM is really down.
            for _ in 0..<12 {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                await refresh()
                if rows.first(where: { $0.id == vmID })?.address == nil { break }
            }
            update(vmID) { $0.activity = nil }
        } catch {
            update(vmID) { $0.activity = nil; $0.error = error.localizedDescription }
        }
    }

    /// Works in any state: without a session the window shows a placeholder
    /// and connects by itself once the VM is up.
    func openConsole(_ vmID: String) {
        guard let row = rows.first(where: { $0.id == vmID }) else { return }
        consoles.open(vm: row.vm)
    }
}
