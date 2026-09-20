import AppKit
import MetalKit
import ShadowAPI

/// Console on UTM's CocoaSpice (ThirdParty/CocoaSpice): spice-client-glib fed
/// through the WebSocket splice, the guest framebuffer uploaded to a Metal
/// texture without a CPU copy and drawn by CSMetalRenderer, input captured the
/// way UTM does it (see SpiceMetalView).
///
/// SPICE decoding itself (QUIC/LZ/GLZ/JPEG) stays on the CPU inside
/// spice-client-glib; what Metal takes over is every pixel after that.
@MainActor
final class CocoaSpiceEngine: NSObject, ConsoleEngine {
    let metalView: SpiceMetalView
    var view: NSView { metalView }
    let events: AsyncStream<ConsoleEvent>
    var ticketProvider: ((_ fresh: Bool) async throws -> SpiceTicket?)?

    private let continuation: AsyncStream<ConsoleEvent>.Continuation
    private let renderer: CSMetalRenderer?
    private var connection: CSConnection?
    private var transport: Transport?
    private var relay: Relay?
    private var display: CSDisplay?
    private var input: CSInput?
    private var spamTask: Task<Void, Never>?

    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    override init() {
        let stream = AsyncStream<ConsoleEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        // A textured quad needs no discrete GPU; don't wake it on dual-GPU Macs.
        let device = MTLCopyAllDevices().first { $0.isLowPower } ?? MTLCreateSystemDefaultDevice()
        metalView = SpiceMetalView(frame: NSRect(x: 0, y: 0, width: 1024, height: 700), device: device)
        renderer = device == nil ? nil : CSMetalRenderer(metalKitView: metalView)
        super.init()
        renderer?.changeUpscaler(.linear, downscaler: .linear)
        metalView.delegate = renderer
        metalView.renderer = renderer
        _ = Self.installLogHandler
        logObserver = NotificationCenter.default.addObserver(forName: Self.glibLog, object: nil, queue: .main) { [weak self] note in
            guard let line = note.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connection != nil else { return }
                self.continuation.yield(.log(line))
            }
        }
        metalView.onCaptureChanged = { [weak self] captured in
            self?.continuation.yield(.notice(captured ? "Keyboard and mouse captured — press ⌃⌥ to release" : nil))
        }
    }

    /// spice-glib's warnings, process-wide, into every open console's log pane.
    private static let glibLog = Notification.Name("CocoaSpiceEngine.glibLog")
    private static let installLogHandler: Void = {
        CSMain.shared.logHandler = { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { NotificationCenter.default.post(name: glibLog, object: text) }
        }
    }()
    private var logObserver: NSObjectProtocol?

    deinit {
        if let logObserver { NotificationCenter.default.removeObserver(logObserver) }
        continuation.finish()
        transport?.closeSplices()
        relay?.engine = nil
    }

    fileprivate func log(_ message: String) { continuation.yield(.log(message)) }

    // MARK: - ConsoleEngine

    func connect(fresh: Bool) async {
        await disconnect()
        guard renderer != nil else {
            log("This Mac has no Metal device; pick another console engine in Settings.")
            continuation.yield(.link(.error, message: "Metal is not available"))
            return
        }
        do {
            guard let ticket = try await ticketProvider?(fresh), let url = URL(string: ticket.uri) else {
                return log("no console available")
            }
            log("Connecting: \(ticket.uri)  (CocoaSpice + Metal on \(metalView.device?.name ?? "?"), spice-glib \(NativeSpiceEngine.libraryVersion))")
            continuation.yield(.link(.connecting, message: nil))
            guard CSMain.shared.spiceStart() else {
                log("could not start the SPICE thread")
                continuation.yield(.link(.error, message: "SPICE thread failed to start"))
                return
            }

            let relay = Relay(engine: self)
            let transport = Transport(url: url) { [weak relay] line in relay?.onMain { $0.log(line) } }
            let connection = CSConnection(fileDescriptorProvider: { [transport] type, id in
                transport.openFD(type: type, id: id)
            })
            connection.password = ticket.secret
            connection.session.shareClipboard = false
            connection.delegate = relay
            self.relay = relay
            self.transport = transport
            self.connection = connection
            _ = connection.connect()
        } catch {
            log("could not get a SPICE ticket: \(error.localizedDescription)")
            continuation.yield(.link(.error, message: error.localizedDescription))
        }
    }

    func disconnect() async {
        spamTask?.cancel()
        metalView.letGo()
        detachDisplay()
        input = nil
        metalView.spiceInput = nil
        // Callbacks from a connection that is being torn down are not ours anymore.
        relay?.engine = nil
        relay = nil
        if let old = connection {
            connection = nil
            old.disconnect()
            // CSConnection's dealloc waits for the SPICE thread, which can itself
            // be waiting for the main thread (display teardown): never let the
            // last reference die here.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { withExtendedLifetime(old) {} }
        }
        transport?.closeSplices()
        transport = nil
    }

    func send(_ key: ConsoleKey) async {
        let code: UInt32?
        switch key {
        case .delete: code = MacKeyMap.delete
        case .backspace: code = MacKeyMap.backspace
        case .function(let n): code = MacKeyMap.function(n)
        }
        guard let code else { return }
        await tap(code)
        log("sent \(key.dom.code)")
    }

    func sendCtrlAltDel() async {
        let combo = [MacKeyMap.leftControl, MacKeyMap.leftAlt, MacKeyMap.delete]
        combo.forEach { key($0, down: true) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        combo.reversed().forEach { key($0, down: false) }
        log("sent Ctrl+Alt+Del")
    }

    /// Esc spam — the only spam. Runs only when triggered, for `duration`.
    func spamEscape(duration: TimeInterval, period: TimeInterval) async {
        spamTask?.cancel()
        log("Spamming Esc for \(Int(duration))s …")
        spamTask = Task { [weak self] in
            let end = Date().addingTimeInterval(duration)
            while Date() < end, !Task.isCancelled {
                await self?.tap(MacKeyMap.escape, hold: 0.012)
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
            }
            if !Task.isCancelled { self?.log("Esc spam done") }
        }
    }

    /// US-layout ASCII only; anything else is skipped and reported.
    func typeText(_ text: String) async throws -> TypeResult {
        var result = TypeResult(typed: 0, skipped: [], aborted: false)
        log("typing \(text.count) chars into guest")
        for ch in text.replacingOccurrences(of: "\r\n", with: "\n") {
            if Task.isCancelled { result.aborted = true; break }
            guard let stroke = MacKeyMap.stroke(for: ch) else {
                result.skipped.append(String(ch))
                continue
            }
            if stroke.shift {
                key(MacKeyMap.leftShift, down: true)
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
            await tap(stroke.scancode, hold: 0.012)
            if stroke.shift { key(MacKeyMap.leftShift, down: false) }
            result.typed += 1
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        log("typed \(result.typed)" + (result.skipped.isEmpty ? "" : ", skipped \(result.skipped.count)"))
        return result
    }

    func screenshotPNG() async throws -> Data {
        guard let display else { throw ShadowError.decoding("no display yet") }
        let png: Data? = await withCheckedContinuation { done in
            display.screenshot { shot in
                // The image still points into the live canvas: encode it right here.
                let data = shot?.image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
                done.resume(returning: data)
            }
        }
        guard let png else { throw ShadowError.decoding("no display yet") }
        return png
    }

    func setBare(_ bare: Bool) async { metalView.bare = bare }

    func focus() { metalView.window?.makeFirstResponder(metalView) }

    var supportsCapture: Bool { true }
    func toggleCapture() { metalView.toggleCapture() }

    private func key(_ scancode: UInt32, down: Bool) {
        input?.send(down ? .press : .release, code: Int32(scancode))
    }

    private func tap(_ scancode: UInt32, hold: TimeInterval = 0.03) async {
        key(scancode, down: true)
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        key(scancode, down: false)
    }

    // MARK: - connection events (main thread, via Relay)

    private func detachDisplay() {
        if let display, let renderer { display.removeRenderer(renderer) }
        display = nil
        metalView.spiceDisplay = nil
    }

    fileprivate func connected() {
        log("main channel up")
        continuation.yield(.link(.connected, message: nil))
    }

    fileprivate func disconnected() {
        log("SPICE session closed")
        detachDisplay()
        transport?.closeSplices()
        continuation.yield(.link(.error, message: "disconnected"))
    }

    fileprivate func failed(code: CSConnectionError, message: String?) {
        let text = message ?? "connection error"
        if code == .authentication {
            log("SPICE: permission denied (bad or expired ticket): \(text)")
            continuation.yield(.link(.badTicket, message: "Permission denied."))
        } else {
            log("SPICE: \(text)")
            continuation.yield(.link(.error, message: text))
        }
    }

    fileprivate func inputAvailable(_ input: CSInput) {
        self.input = input
        metalView.spiceInput = input
        log("inputs channel up — mouse mode: \(input.serverModeCursor ? "server (relative; click or ⌃⌥ to capture)" : "client (absolute)")")
        continuation.yield(.inputsReady)
    }

    fileprivate func inputUnavailable(_ input: CSInput) {
        guard self.input === input else { return }
        self.input = nil
        metalView.spiceInput = nil
    }

    fileprivate func displayCreated(_ display: CSDisplay) {
        guard self.display == nil || self.display === display, let renderer else { return }
        self.display = display
        display.addRenderer(renderer)
        metalView.spiceDisplay = display
        metalView.updateViewport()
        log("display \(Int(display.displaySize.width))×\(Int(display.displaySize.height))")
    }

    fileprivate func displayUpdated(_ display: CSDisplay) {
        guard self.display === display else { return displayCreated(display) }
        metalView.needsLayout = true
        metalView.updateViewport()
        log("display now \(Int(display.displaySize.width))×\(Int(display.displaySize.height))")
    }

    fileprivate func displayDestroyed(_ display: CSDisplay) {
        guard self.display === display else { return }
        detachDisplay()
    }

    /// Headless smoke test, no VM needed: Metal device, shader library and
    /// renderer come up, the SPICE thread starts, and the main channel asks for
    /// its transport through the patched CSConnection.
    static func selfTest() async -> Bool {
        let engine = CocoaSpiceEngine()
        guard engine.renderer != nil else { print("cocoaspice: FAILED (no Metal device / renderer)"); return false }
        print("cocoaspice: Metal renderer ok on \(engine.metalView.device?.name ?? "?")")
        engine.ticketProvider = { _ in
            SpiceTicket(uri: "ws://127.0.0.1:9/spice", secret: "selftest", clientID: "", proxy: ProxyContext(base: URL(string: "https://127.0.0.1")!, token: ""))
        }
        var lines: [String] = []
        let collector = Task { for await e in engine.events { if case .log(let l) = e { lines.append(l); print("  \(l)") } } }
        await engine.connect(fresh: false)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await engine.disconnect()
        try? await Task.sleep(nanoseconds: 500_000_000)
        collector.cancel()
        let askedForTransport = lines.contains { $0.hasPrefix("ch1.0:") }
        print(askedForTransport ? "cocoaspice: ok" : "cocoaspice: FAILED (main channel never asked for a transport)")
        return askedForTransport
    }
}

/// CSConnection's delegate. Its methods arrive on the SPICE thread; everything
/// is handed to the engine on the main thread, and nothing once the engine has
/// let go of this connection.
private final class Relay: NSObject, CSConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private weak var _engine: CocoaSpiceEngine?
    var engine: CocoaSpiceEngine? {
        get { lock.withLock { _engine } }
        set { lock.withLock { _engine = newValue } }
    }

    init(engine: CocoaSpiceEngine) { _engine = engine }

    func onMain(_ body: @escaping @MainActor (CocoaSpiceEngine) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let engine = self?.engine else { return }
            body(engine)
        }
    }

    func spiceConnected(_ connection: CSConnection) { onMain { $0.connected() } }
    func spiceDisconnected(_ connection: CSConnection) { onMain { $0.disconnected() } }
    func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) { onMain { $0.failed(code: code, message: message) } }
    func spiceInputAvailable(_ connection: CSConnection, input: CSInput) { onMain { $0.inputAvailable(input) } }
    func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) { onMain { $0.inputUnavailable(input) } }
    func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) { onMain { $0.displayCreated(display) } }
    func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) { onMain { $0.displayUpdated(display) } }
    func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) { onMain { $0.displayDestroyed(display) } }
    func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) { onMain { $0.log("guest agent connected") } }
    func spiceAgentDisconnected(_ connection: CSConnection) {}
    func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}

/// One WebSocket splice per SPICE channel; all channels share the one URI.
private final class Transport: @unchecked Sendable {
    // SPICE_CHANNEL_*: only what a KVM console needs gets a socket.
    private static let wanted: Set<Int> = [1, 2, 3, 4] // main, display, inputs, cursor

    private let url: URL
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var splices: [SpiceSplice] = []
    private var closed = false
    private let userAgent = ShadowConfig.fromEnvironment().userAgent

    init(url: URL, log: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.log = log
    }

    /// SPICE thread.
    func openFD(type: Int, id: Int) -> Int32 {
        guard Self.wanted.contains(type), type == 1 || id == 0, !lock.withLock({ closed }) else { return -1 }
        guard let opened = SpiceSplice.open(url: url, userAgent: userAgent, label: "ch\(type).\(id)", log: log) else { return -1 }
        let keep = lock.withLock { () -> Bool in
            if closed { return false }
            splices.append(opened.splice)
            return true
        }
        if !keep {
            opened.splice.close()
            close(opened.libraryFD)
            return -1
        }
        return opened.libraryFD
    }

    func closeSplices() {
        let old = lock.withLock { () -> [SpiceSplice] in
            closed = true
            defer { splices = [] }
            return splices
        }
        old.forEach { $0.close() }
    }
}
