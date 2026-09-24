import AppKit
import Combine
import ShadowAPI
import SwiftUI

/// What the console shows instead of a display while its VM has no session.
struct ConsolePlaceholder: Equatable {
    var state: VMState
    var message: String
    var progress: String?
    var error: String?
    var canStart: Bool
}

@MainActor
final class ConsoleViewModel: ObservableObject {
    static let spamDuration: TimeInterval = 5
    static let spamPeriod: TimeInterval = 0.1
    static let statusInterval: TimeInterval = 2

    let vm: VM
    let engine: ConsoleEngine
    private let model: AppModel
    /// The session this console is bound to, driven by the VM's row in AppModel.
    private var session = ConsoleSessionTracker()
    /// Only ever a ticket of the bound session: it is dropped together with it.
    private var ticket: SpiceTicket?
    /// Bumped whenever the bound session changes, so a ticket request that was
    /// in flight across the change is discarded instead of connecting to the past.
    private var epoch = 0
    private var engineQueue: Task<Void, Never>?
    private var rowWatch: AnyCancellable?
    private var statusTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var closed = false

    /// Real VM status from the proxy — never the SPICE link state.
    @Published private(set) var statusLabel = "…"
    @Published private(set) var statusColor: Color = .orange
    /// The log lives in its own window (ConsoleWindowController shows it).
    @Published var logVisible = false
    @Published private(set) var logLines: [String] = []
    @Published var isFullScreen = false { didSet { Task { await engine.setBare(isFullScreen) } } }
    @Published var notice: String?
    @Published private(set) var row: VMRow?
    /// False while the VM is stopped, starting, queued or stopping: the
    /// placeholder shows and everything that needs a guest is off.
    @Published private(set) var hasSession = false

    init(vm: VM, model: AppModel, engine: ConsoleEngine? = nil) {
        self.vm = vm
        self.model = model
        self.engine = engine ?? ConsoleEngineKind.current.make()
        self.engine.ticketProvider = { [weak self] fresh in try await self?.provideTicket(fresh: fresh) }
    }

    func start() {
        eventTask = Task { [weak self, events = engine.events] in
            for await event in events {
                self?.handle(event)
            }
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollStatus()
                try? await Task.sleep(nanoseconds: UInt64(Self.statusInterval * 1_000_000_000))
            }
        }
        // Emits the current rows right away: a running VM connects from here,
        // anything else shows the placeholder until it is up.
        rowWatch = model.$rows.sink { [weak self, id = vm.id] rows in
            self?.observe(rows.first { $0.id == id })
        }
    }

    // MARK: - session

    private func observe(_ row: VMRow?) {
        // A vanished row (signed out, list reloading) says nothing about the VM.
        guard !closed, let row else { return }
        if self.row != row { self.row = row }
        switch session.observe(address: row.address, stopping: row.activity == .stopping) {
        case .began(let address):
            // First start or restart: nothing of an earlier session applies.
            handle(.log("VM session \(address.sessionID ?? "?") is up — connecting"))
            ticket = nil
            epoch += 1
            hasSession = true
            notice = nil
            statusLabel = "…"
            statusColor = .orange
            // Once per session. If it fails the log says why, and Reconnect is the user's call.
            enqueue { await self.engine.connect(fresh: false) }
        case .ended:
            endSession()
        case .none:
            break
        }
        if !hasSession { showRowState(row) }
    }

    /// No DELETE for the launcher client here: it dies with the session, and a
    /// late one could hit the (deterministic) client of the VM's next session.
    private func endSession() {
        if hasSession { handle(.log("VM session ended — console disconnected")) }
        session.end()
        ticket = nil
        epoch += 1
        hasSession = false
        notice = nil
        enqueue { await self.engine.disconnect() }
        if let row { showRowState(row) }
    }

    /// One engine operation at a time: overlapping connects would each re-create
    /// the launcher client and kick one another.
    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = engineQueue
        engineQueue = Task {
            await previous?.value
            await operation()
        }
    }

    private func shownState(_ row: VMRow) -> VMState {
        if case .starting = row.activity { return .starting }
        return row.state
    }

    private func showRowState(_ row: VMRow) {
        let state = shownState(row)
        statusLabel = state.description
        statusColor = StateBadge.color(for: state)
    }

    var placeholder: ConsolePlaceholder? {
        guard !hasSession else { return nil }
        guard let row else {
            return ConsolePlaceholder(state: .unknown("…"), message: "Waiting for the VM list…", canStart: false)
        }
        let state = shownState(row)
        let auto = "the console connects automatically when the VM is up"
        let message: String
        switch state {
        case .stopped: message = "VM is stopped — start it to get a console"
        case .starting: message = "Starting… \(auto)"
        case .queued: message = "Queued… \(auto)"
        case .stopping: message = "VM is stopping…"
        case .maintenance: message = "VM is in maintenance — no console for now"
        case .running: message = "Waiting for the VM's address… \(auto)"
        case .unknown(let raw): message = "VM is \(raw) — \(auto)"
        }
        var progress: String?
        if case .starting(let text) = row.activity { progress = text }
        // Same rule as the Start button in the VM list.
        let canStart = row.activity == nil && !row.isRunning && state != .maintenance
        return ConsolePlaceholder(state: state, message: message, progress: progress, error: row.error, canStart: canStart)
    }

    func startVM() { Task { await model.startVM(vm.id) } }

    func clearLog() { logLines.removeAll() }

    private func handle(_ event: ConsoleEvent) {
        switch event {
        case .log(let line):
            logLines.append(line)
            if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        case .inputsReady:
            engine.focus()
        case .notice(let text):
            notice = text
        case .pageReady, .link:
            break
        }
    }

    /// Reuse the current ticket unless a fresh one is demanded: re-minting
    /// recreates the (deterministic) launcher client and can kick a live session.
    /// The ticket kept here is always one of the bound session, so neither path
    /// can hand out the URL or secret of a session that is gone.
    private func provideTicket(fresh: Bool) async throws -> SpiceTicket? {
        guard !closed else { return nil }
        if !fresh, let ticket { return ticket }
        let epoch = self.epoch
        do {
            var target = session.address
            if fresh {
                // Reconnect asks the API itself: the row can be a refresh behind.
                let live = try await model.client.launcher.address(vm.id)
                guard epoch == self.epoch, !closed else { return nil }
                guard let live else {
                    endSession()
                    model.noteAddress(nil, for: vm.id)
                    notice = "The VM is not running."
                    return nil
                }
                if live.sessionKey != target?.sessionKey {
                    // Restarted before the list noticed: bind here, and tell the
                    // list, so its next row isn't taken for yet another session.
                    handle(.log("VM session \(live.sessionID ?? "?") replaced the one this console had — new ticket"))
                    ticket = nil
                    session.adopt(live)
                    // A queued Reconnect can get here after the session it was pressed for ended.
                    hasSession = true
                    model.noteAddress(live, for: vm.id)
                    guard epoch == self.epoch else { return nil }
                }
                target = live
            }
            guard let target else { return nil }
            let minted = try await mintTicket(for: target, forceNew: fresh)
            guard !closed else {
                await model.client.proxy.deleteClient(minted.proxy, clientID: minted.clientID)
                return nil
            }
            guard epoch == self.epoch else { return nil }
            ticket = minted
            notice = nil
            return minted
        } catch {
            if epoch == self.epoch { notice = "No console ticket — see the log, then Reconnect." }
            throw error
        }
    }

    private func mintTicket(for address: VMAddress, forceNew: Bool) async throws -> SpiceTicket {
        let ctx = try await model.proxyContext(vmID: vm.id, address: address, forceNew: forceNew)
        do {
            return try await model.client.proxy.openSpiceConsole(ctx)
        } catch ShadowError.http(let status, _, _) where !forceNew && (status == 401 || status == 403) {
            // The cached proxy token expired: mint once more, as proxySignals does.
            let renewed = try await model.proxyContext(vmID: vm.id, address: address, forceNew: true)
            return try await model.client.proxy.openSpiceConsole(renewed)
        }
    }

    private func pollStatus() async {
        // Until the ticket exists the launcher client isn't registered and /status would 401.
        guard let ticket, let address = session.address else { return }
        // The list lost the address but the tracker still waits for the next
        // refresh to confirm: don't mint proxy tokens for a session that is probably over.
        guard row?.address?.sessionKey == address.sessionKey else {
            statusLabel = "unreachable"
            statusColor = .orange
            return
        }
        let signals = await model.proxySignals(vmID: vm.id, address: address, consoleOpen: true)
        // The session ended meanwhile: the header shows the row's state now.
        guard ticket == self.ticket else { return }
        guard let label = signals?.label else {
            statusLabel = "unreachable"
            statusColor = .orange
            return
        }
        statusLabel = label
        statusColor = StateBadge.color(for: VMState(status: signals?.vmStatus ?? "reachable"))
    }

    // MARK: - toolbar actions

    /// Everything here needs a guest: a no-op while the placeholder is up.
    private func act(_ body: @escaping () async -> Void) {
        guard hasSession else { return }
        Task {
            await body()
            engine.focus()
        }
    }

    func ctrlAltDel() { act { await self.engine.sendCtrlAltDel() } }
    func spamEscape() { act { await self.engine.spamEscape(duration: Self.spamDuration, period: Self.spamPeriod) } }
    func send(_ key: ConsoleKey) { act { await self.engine.send(key) } }
    func reconnect() {
        guard hasSession else { return }
        enqueue {
            await self.engine.connect(fresh: true)
            self.engine.focus()
        }
    }

    func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            notice = "The clipboard has no text."
            return
        }
        act {
            do {
                let r = try await self.engine.typeText(text)
                self.notice = r.skipped.isEmpty ? nil : "Typed \(r.typed); skipped \(r.skipped.count) character(s) not on a US keyboard."
            } catch {
                self.notice = "Paste failed: \(error.localizedDescription)"
            }
        }
    }

    func screenshot() {
        guard hasSession else { return }
        Task {
            do {
                let png = try await engine.screenshotPNG()
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                let stamp = DateFormatter()
                stamp.dateFormat = "yyyyMMdd-HHmmss"
                panel.nameFieldStringValue = "\(vm.name)-\(stamp.string(from: Date())).png"
                if await panel.begin() == .OK, let url = panel.url { try png.write(to: url) }
            } catch {
                notice = "Screenshot failed: \(error.localizedDescription)"
            }
            engine.focus()
        }
    }

    func toggleFullScreen() { engine.view.window?.toggleFullScreen(nil) }

    func powerOff() {
        guard hasSession else { return }
        let alert = NSAlert()
        alert.messageText = "Power off \(vm.name)?"
        alert.informativeText = "The VM is shut down immediately, like holding the power button."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Power Off")
        alert.addButton(withTitle: "Cancel")
        // A sheet on this window, never app-modal: a modal alert hidden behind a
        // fullscreen console would freeze every other window.
        guard let window = engine.view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { Task { await self.model.stopVM(self.vm.id) } }
            self.engine.focus()
        }
    }

    /// Disconnect and release the proxy client so the single-client SPICE
    /// console isn't left held by a closed window.
    func close() async {
        guard !closed else { return }
        closed = true
        rowWatch = nil
        statusTask?.cancel()
        eventTask?.cancel()
        await engine.disconnect()
        if let ticket { await model.client.proxy.deleteClient(ticket.proxy, clientID: ticket.clientID) }
    }
}
