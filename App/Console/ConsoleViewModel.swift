import AppKit
import ShadowAPI
import SwiftUI

@MainActor
final class ConsoleViewModel: ObservableObject {
    static let spamDuration: TimeInterval = 5
    static let spamPeriod: TimeInterval = 0.1
    static let statusInterval: TimeInterval = 2

    let vm: VM
    let engine: ConsoleEngine
    private let model: AppModel
    private var address: VMAddress
    private var ticket: SpiceTicket?
    private var statusTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var closed = false

    /// Real VM status from the proxy — never the SPICE link state.
    @Published private(set) var statusLabel = "…"
    @Published private(set) var statusColor: Color = .orange
    @Published var logVisible = true
    @Published private(set) var logLines: [String] = []
    @Published var isFullScreen = false { didSet { Task { await engine.setBare(isFullScreen) } } }
    @Published var notice: String?

    init(vm: VM, address: VMAddress, model: AppModel, engine: ConsoleEngine? = nil) {
        self.vm = vm
        self.address = address
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
        Task { await engine.connect(fresh: false) }
    }

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
    private func provideTicket(fresh: Bool) async throws -> SpiceTicket? {
        if !fresh, let ticket { return ticket }
        guard let live = try await model.client.launcher.address(vm.id) else {
            notice = "The VM is not running."
            return nil
        }
        address = live
        let ctx = try await model.proxyContext(vmID: vm.id, address: live, forceNew: fresh)
        let minted = try await model.client.proxy.openSpiceConsole(ctx)
        ticket = minted
        notice = nil
        return minted
    }

    private func pollStatus() async {
        let signals = await model.proxySignals(vmID: vm.id, address: address)
        guard let label = signals?.label else {
            statusLabel = "unreachable"
            statusColor = .orange
            return
        }
        statusLabel = label
        statusColor = StateBadge.color(for: VMState(status: signals?.vmStatus ?? "reachable"))
    }

    // MARK: - toolbar actions

    private func act(_ body: @escaping () async -> Void) {
        Task {
            await body()
            engine.focus()
        }
    }

    func ctrlAltDel() { act { await self.engine.sendCtrlAltDel() } }
    func spamEscape() { act { await self.engine.spamEscape(duration: Self.spamDuration, period: Self.spamPeriod) } }
    func send(_ key: ConsoleKey) { act { await self.engine.send(key) } }
    func reconnect() { act { await self.engine.connect(fresh: true) } }

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
        statusTask?.cancel()
        eventTask?.cancel()
        await engine.disconnect()
        if let ticket { await model.client.proxy.deleteClient(ticket.proxy, clientID: ticket.clientID) }
    }
}
