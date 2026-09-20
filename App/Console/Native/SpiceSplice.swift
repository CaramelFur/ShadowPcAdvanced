import Foundation

/// The "websocket splice": Shadow only exposes SPICE over WebSocket (one
/// `wss://` socket per channel, subprotocol `binary`), while spice-client-glib
/// speaks plain SPICE over a stream socket. Each channel gets a socketpair; one
/// end goes to the library, the other is pumped to and from a WebSocket here.
/// TLS is handled by the WebSocket layer, so the library side is plaintext.
final class SpiceSplice: @unchecked Sendable {
    private let fd: Int32
    private let socket: RawWebSocket
    private let label: String
    private let log: @Sendable (String) -> Void
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var closed = false

    /// Opens a splice and returns the descriptor to hand to spice-glib (which
    /// takes ownership of it), or nil if it couldn't be set up.
    static func open(url: URL, userAgent: String, label: String, log: @escaping @Sendable (String) -> Void) -> (splice: SpiceSplice, libraryFD: Int32)? {
        guard let socket = RawWebSocket(url: url, userAgent: userAgent, label: label) else {
            log("\(label): unsupported SPICE URL")
            return nil
        }
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            log("\(label): socketpair failed (errno \(errno))")
            return nil
        }
        for fd in fds {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Display updates arrive in bursts; a roomy buffer avoids stalls.
            var size: Int32 = 4 << 20
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        let splice = SpiceSplice(fd: fds[1], socket: socket, label: label, log: log)
        splice.start()
        return (splice, fds[0])
    }

    private init(fd: Int32, socket: RawWebSocket, label: String, log: @escaping @Sendable (String) -> Void) {
        self.fd = fd
        self.socket = socket
        self.label = label
        self.log = log
        readQueue = DispatchQueue(label: "spice-splice.read.\(label)")
        writeQueue = DispatchQueue(label: "spice-splice.write.\(label)")
    }

    private func start() {
        // server → library. `resume` is only called once the bytes are written,
        // so a library that isn't reading pushes back on the socket.
        socket.onData = { [self] payload, resume in
            writeQueue.async { [self] in
                if writeAll(payload) { resume() } else { close("write to the SPICE client failed (errno \(errno))") }
            }
        }
        socket.onClose = { [self] reason in close("websocket: \(reason)") }
        socket.start()
        readQueue.async { [self] in pumpSocketToWebSocket() }
    }

    // MARK: library → server

    private func pumpSocketToWebSocket() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let sent = DispatchSemaphore(value: 0)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return close(n == 0 ? "closed by the SPICE client" : nil) }
            var failure: Error?
            // One frame in flight at a time: that is the backpressure.
            socket.send(Data(buffer[0..<n])) { error in
                failure = error
                sent.signal()
            }
            sent.wait()
            if let failure { return close("send failed: \(failure.localizedDescription)") }
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                p += n
                left -= n
            }
            return true
        }
    }

    /// Reads the library end as fast as possible for 5 s and prints MB/s.
    static func benchmark(url: URL) {
        func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        guard let opened = open(url: url, userAgent: "bench", label: "bench", log: { say($0) }) else { exit(1) }
        if ProcessInfo.processInfo.environment["BENCH_UP"] != nil {
            // Upstream check: 5 MB of the pattern i % 251, verified by the test server.
            let pattern = (0..<5_000_000).map { UInt8($0 % 251) }
            var off = 0
            while off < pattern.count {
                let n = pattern[off...].withUnsafeBytes { write(opened.libraryFD, $0.baseAddress, min($0.count, 100_000)) }
                if n <= 0 { break }
                off += n
            }
            Thread.sleep(forTimeInterval: 1.5)
            opened.splice.close()
            Thread.sleep(forTimeInterval: 0.5)
            say("uploaded \(off) bytes")
            exit(0)
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            let n = read(opened.libraryFD, &buffer, buffer.count)
            if n <= 0 { break }
            total += n
        }
        let seconds = Date().timeIntervalSince(start)
        say(String(format: "splice: %.1f MB in %.1f s = %.1f MB/s", Double(total) / 1e6, seconds, Double(total) / 1e6 / seconds))
        exit(0)
    }

    // MARK: teardown

    func close(_ reason: String? = nil) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        if let reason { log("\(label): \(reason)") }
        socket.close()
        // shutdown() unblocks the pump's read() and fails any pending write();
        // the descriptor is closed only once both queues have let go of it.
        shutdown(fd, SHUT_RDWR)
        readQueue.async { [fd, writeQueue] in
            writeQueue.sync { _ = Darwin.close(fd) }
        }
    }
}
