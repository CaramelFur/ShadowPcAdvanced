import AppKit
import ShadowAPI

/// Native console: spice-client-glib (ported from Linux, see
/// Scripts/build-spice.sh) over the WebSocket splice, drawn into a CALayer.
@MainActor
final class NativeSpiceEngine: NSObject, ConsoleEngine, SpiceDisplayInput {
    let displayView = SpiceDisplayView(frame: NSRect(x: 0, y: 0, width: 1024, height: 700))
    var view: NSView { displayView }
    let events: AsyncStream<ConsoleEvent>
    var ticketProvider: ((_ fresh: Bool) async throws -> SpiceTicket?)?

    private let continuation: AsyncStream<ConsoleEvent>.Continuation
    private let bridge: Bridge
    private var spice: OpaquePointer?
    private var spamTask: Task<Void, Never>?

    static var libraryVersion: String { String(cString: fs_spice_library_version()) }

    override init() {
        let stream = AsyncStream<ConsoleEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        bridge = Bridge()
        super.init()
        bridge.engine = self
        displayView.input = self

        var callbacks = FSSpiceCallbacks()
        // Released by fs_spice_free's on_freed, once no callback can fire again.
        callbacks.ctx = Unmanaged.passRetained(bridge).toOpaque()
        callbacks.open_fd = { ctx, type, id in Bridge.from(ctx).openFD(type: type, id: id) }
        callbacks.channel_event = { ctx, type, _, event in Bridge.from(ctx).channelEvent(type: type, event: event) }
        callbacks.display_create = { ctx, format, width, height, stride, data in
            let b = Bridge.from(ctx)
            b.framebuffer.create(format: format, width: Int(width), height: Int(height), stride: Int(stride), data: data)
            b.displayChanged()
        }
        callbacks.display_destroy = { ctx in
            let b = Bridge.from(ctx)
            b.framebuffer.destroy()
            b.displayChanged()
        }
        callbacks.display_invalidate = { ctx, x, y, w, h in
            let b = Bridge.from(ctx)
            b.framebuffer.invalidate(x: Int(x), y: Int(y), width: Int(w), height: Int(h))
            b.displayChanged()
        }
        callbacks.cursor_set = { ctx, w, h, hotX, hotY, rgba in
            let pixels = rgba.map { Data(bytes: $0, count: Int(w) * Int(h) * 4) }
            Bridge.from(ctx).onMain { $0.displayView.setGuestCursor(rgba: pixels, width: Int(w), height: Int(h), hotX: Int(hotX), hotY: Int(hotY)) }
        }
        callbacks.cursor_move = { ctx, x, y in
            Bridge.from(ctx).onMain { $0.displayView.moveGuestCursor(x: Int(x), y: Int(y)) }
        }
        callbacks.mouse_mode = { ctx, server in
            Bridge.from(ctx).onMain {
                $0.displayView.serverMouseMode = server
                $0.log("mouse mode: \(server ? "server (relative)" : "client (absolute)")")
            }
        }
        callbacks.log = { ctx, message in
            let text = message.map { String(cString: $0) } ?? ""
            Bridge.from(ctx).onMain { $0.log(text) }
        }
        spice = fs_spice_new(&callbacks)
    }

    deinit {
        continuation.finish()
        bridge.closeSplices()
        if let spice { fs_spice_free(spice) { ctx in Unmanaged<Bridge>.fromOpaque(ctx!).release() } }
    }

    fileprivate func log(_ message: String) { continuation.yield(.log(message)) }

    // MARK: - ConsoleEngine

    func connect(fresh: Bool) async {
        guard let spice else { return }
        await disconnect()
        do {
            guard let ticket = try await ticketProvider?(fresh), let url = URL(string: ticket.uri) else {
                return log("no console available")
            }
            log("Connecting: \(ticket.uri)  (spice-glib \(Self.libraryVersion))")
            continuation.yield(.link(.connecting, message: nil))
            bridge.setTarget(url)
            fs_spice_connect(spice, ticket.secret)
        } catch {
            log("could not get a SPICE ticket: \(error.localizedDescription)")
            continuation.yield(.link(.error, message: error.localizedDescription))
        }
    }

    func disconnect() async {
        spamTask?.cancel()
        displayView.letGo()
        if let spice { fs_spice_disconnect(spice) }
        bridge.closeSplices()
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
        bridge.framebuffer.flush()
        guard let png = bridge.framebuffer.pngData() else { throw ShadowError.decoding("no display yet") }
        return png
    }

    func setBare(_ bare: Bool) async { displayView.bare = bare }

    func focus() { displayView.window?.makeFirstResponder(displayView) }

    private func tap(_ scancode: UInt32, hold: TimeInterval = 0.03) async {
        key(scancode, down: true)
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        key(scancode, down: false)
    }

    /// Headless smoke test: no VM needed. A channel must ask for its transport
    /// (proving the GLib thread, session and open-fd plumbing work) and the
    /// failed link must be reported rather than crash or hang.
    /// Deterministic 24-bit test pattern (split up to keep the type checker fast).
    private static func testPixel(_ index: Int) -> UInt32 {
        let hashed: Int = index &* 2_654_435_761
        let low = UInt32(truncatingIfNeeded: hashed)
        return low & 0x00FF_FFFF
    }

    /// Framebuffer copy: pixels intact, alpha forced opaque, and how long a
    /// full 2560×1440 frame takes.
    static func framebufferSelfTest() -> Bool {
        let w = 2560, h = 1440, stride = w * 4
        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * h)
        defer { source.deallocate() }
        source.withMemoryRebound(to: UInt32.self, capacity: w * h) { px in
            for i in 0..<(w * h) { px[i] = testPixel(i) } // alpha byte = 0
        }
        let fb = SpiceFramebuffer()
        fb.create(format: 32, width: w, height: h, stride: stride, data: source)
        let start = Date()
        let flushed = fb.flush()
        let ms = Date().timeIntervalSince(start) * 1000
        guard flushed, let surface = fb.currentSurface else { print("framebuffer: FAILED (no flush)"); return false }
        surface.lock(options: .readOnly, seed: nil)
        var ok = true
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(0, 0), (1, 0), (w - 1, 0), (1234, 777), (w - 1, h - 1)] {
            let got = UnsafeRawPointer(base + y * surface.bytesPerRow + x * 4).load(as: UInt32.self)
            let want: UInt32 = testPixel(y * w + x) | 0xFF00_0000
            if got != want { ok = false; print(String(format: "framebuffer: pixel (%d,%d) = %08x, want %08x", x, y, got, want)) }
        }
        surface.unlock(options: .readOnly, seed: nil)
        // A small dirty rect must not touch anything else.
        fb.invalidate(x: 10, y: 10, width: 5, height: 5)
        ok = ok && fb.flush() && !fb.flush() && fb.pngData() != nil
        print(String(format: "framebuffer: %@, full 2560x1440 copy %.1f ms", ok ? "ok" : "FAILED", ms))
        return ok
    }

    static func selfTest() async -> Bool {
        let engine = NativeSpiceEngine()
        engine.ticketProvider = { _ in
            SpiceTicket(uri: "ws://127.0.0.1:9/spice", secret: "selftest", clientID: "", proxy: ProxyContext(base: URL(string: "https://127.0.0.1")!, token: ""))
        }
        var lines: [String] = []
        let collector = Task { for await e in engine.events { if case .log(let l) = e { lines.append(l); print("  \(l)") } } }
        print("spice-glib \(libraryVersion)")
        guard framebufferSelfTest() else { return false }
        await engine.connect(fresh: false)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await engine.disconnect()
        try? await Task.sleep(nanoseconds: 500_000_000)
        collector.cancel()
        let askedForTransport = lines.contains { $0.hasPrefix("ch1.0:") }
        print(askedForTransport ? "selftest: ok" : "selftest: FAILED (main channel never asked for a transport)")
        return askedForTransport
    }

    // MARK: - SpiceDisplayInput

    func key(_ scancode: UInt32, down: Bool) {
        if let spice { fs_spice_key(spice, scancode, down) }
    }

    func mousePosition(x: Int, y: Int, buttons: Int) {
        if let spice { fs_spice_mouse_position(spice, Int32(x), Int32(y), Int32(buttons)) }
    }

    func mouseMotion(dx: Int, dy: Int, buttons: Int) {
        if let spice { fs_spice_mouse_motion(spice, Int32(dx), Int32(dy), Int32(buttons)) }
    }

    func mouseButton(_ button: Int, down: Bool, buttons: Int) {
        if let spice { fs_spice_mouse_button(spice, Int32(button), down, Int32(buttons)) }
    }

    func mouseGrabChanged(_ grabbed: Bool) {
        continuation.yield(.notice(grabbed ? "Mouse captured — press ⌃⌥ to release" : nil))
    }

    // MARK: - from the GLib thread (via Bridge)

    fileprivate func present() {
        displayView.present(surface: bridge.framebuffer.currentSurface, size: bridge.framebuffer.size)
    }

    fileprivate func handleChannelEvent(type: Int32, event: Int32) {
        let name: String
        switch Int(type) {
        case FS_CHANNEL_MAIN: name = "main"
        case FS_CHANNEL_DISPLAY: name = "display"
        case FS_CHANNEL_INPUTS: name = "inputs"
        case FS_CHANNEL_CURSOR: name = "cursor"
        default: name = "channel \(type)"
        }
        switch Int(event) {
        case FS_EVENT_OPENED:
            log("\(name) channel up")
            if Int(type) == FS_CHANNEL_MAIN { continuation.yield(.link(.connected, message: nil)) }
            if Int(type) == FS_CHANNEL_INPUTS { continuation.yield(.inputsReady) }
        case FS_EVENT_CLOSED:
            log("\(name) channel closed")
            if Int(type) == FS_CHANNEL_MAIN { continuation.yield(.link(.error, message: "main channel closed")) }
        case FS_EVENT_ERROR_AUTH:
            log("SPICE: \(name): permission denied (bad or expired ticket)")
            continuation.yield(.link(.badTicket, message: "Permission denied."))
        case FS_EVENT_ERROR_CONNECT, FS_EVENT_ERROR_TLS, FS_EVENT_ERROR_LINK, FS_EVENT_ERROR_IO:
            log("SPICE: \(name) channel error \(event)")
            if Int(type) == FS_CHANNEL_MAIN { continuation.yield(.link(.error, message: "channel error \(event)")) }
        default:
            break
        }
    }

}

/// What the C callbacks see. Lives until fs_spice_free has finished, which can
/// be after the engine is gone, so it only holds the engine weakly.
private final class Bridge: @unchecked Sendable {
    let framebuffer = SpiceFramebuffer()
    // Set once on the main thread before any callback can fire.
    weak var engine: NativeSpiceEngine?

    private let lock = NSLock()
    private var target: URL?
    private var splices: [SpiceSplice] = []
    private var presentPending = false
    private let renderQueue = DispatchQueue(label: "spice-render", qos: .userInteractive)
    private let userAgent = ShadowConfig.fromEnvironment().userAgent

    static func from(_ ctx: UnsafeMutableRawPointer?) -> Bridge { Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue() }

    func setTarget(_ url: URL) { lock.withLock { target = url } }

    func closeSplices() {
        let old = lock.withLock { () -> [SpiceSplice] in
            defer { splices = [] }
            return splices
        }
        old.forEach { $0.close() }
    }

    func onMain(_ body: @escaping @MainActor (NativeSpiceEngine) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let engine = self?.engine else { return }
            body(engine)
        }
    }

    // GLib thread: all SPICE channels share the one URI.
    func openFD(type: Int32, id: Int32) -> Int32 {
        guard let url = lock.withLock({ target }) else { return -1 }
        let label = "ch\(type).\(id)"
        guard let opened = SpiceSplice.open(url: url, userAgent: userAgent, label: label, log: { [weak self] line in
            self?.onMain { $0.log(line) }
        }) else { return -1 }
        lock.withLock { splices.append(opened.splice) }
        return opened.libraryFD
    }

    func channelEvent(type: Int32, event: Int32) {
        onMain { $0.handleChannelEvent(type: type, event: event) }
    }

    /// Called for every dirty rectangle — thousands per second on a busy
    /// screen. At most ONE main-thread hop may be pending, and at most ~60 per
    /// second happen, or the UI starves.
    func displayChanged() {
        let first = lock.withLock { () -> Bool in
            if presentPending { return false }
            presentPending = true
            return true
        }
        guard first else { return }
        renderQueue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            guard let self else { return }
            // Cleared before copying, so a later invalidate is never lost.
            self.lock.withLock { self.presentPending = false }
            // The pixel copy happens here — not on the GLib thread (it would stall
            // decoding) and not on the main thread (it would stall the UI).
            self.framebuffer.flush()
            self.onMain { $0.present() }
        }
    }
}
