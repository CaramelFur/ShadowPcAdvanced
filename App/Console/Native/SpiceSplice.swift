import Foundation

/// The "websocket splice": Shadow only exposes SPICE over WebSocket (one
/// `wss://` socket per channel, subprotocol `binary`), while spice-client-glib
/// speaks plain SPICE over a stream socket. Each channel gets a socketpair; one
/// end goes to the library, the other is pumped to and from a WebSocket here.
/// TLS is handled by the WebSocket layer, so the library side is plaintext.
final class SpiceSplice: @unchecked Sendable {
    private let fd: Int32
    private let task: URLSessionWebSocketTask
    private let label: String
    private let log: @Sendable (String) -> Void
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var closed = false

    /// Opens a splice and returns the descriptor to hand to spice-glib (which
    /// takes ownership of it), or nil if the socketpair couldn't be made.
    static func open(url: URL, session: URLSession, userAgent: String, label: String, log: @escaping @Sendable (String) -> Void) -> (splice: SpiceSplice, libraryFD: Int32)? {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            log("\(label): socketpair failed (errno \(errno))")
            return nil
        }
        for fd in fds {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Display updates arrive in bursts; a roomy buffer avoids stalls.
            var size: Int32 = 1 << 20
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 << 20
        let splice = SpiceSplice(fd: fds[1], task: task, label: label, log: log)
        splice.start()
        return (splice, fds[0])
    }

    private init(fd: Int32, task: URLSessionWebSocketTask, label: String, log: @escaping @Sendable (String) -> Void) {
        self.fd = fd
        self.task = task
        self.label = label
        self.log = log
        readQueue = DispatchQueue(label: "spice-splice.read.\(label)")
        writeQueue = DispatchQueue(label: "spice-splice.write.\(label)")
    }

    private func start() {
        task.resume()
        receiveNext()
        readQueue.async { [self] in pumpSocketToWebSocket() }
    }

    // MARK: library → server

    private func pumpSocketToWebSocket() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let sent = DispatchSemaphore(value: 0)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return close(n == 0 ? "closed by the SPICE client" : "read failed (errno \(errno))") }
            var failure: Error?
            // One message in flight at a time: that is the backpressure.
            task.send(.data(Data(buffer[0..<n]))) { error in
                failure = error
                sent.signal()
            }
            sent.wait()
            if let failure { return close("send failed: \(failure.localizedDescription)") }
        }
    }

    // MARK: server → library

    private func receiveNext() {
        task.receive { [self] result in
            switch result {
            case .failure(let error):
                close("websocket closed: \(error.localizedDescription)")
            case .success(let message):
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                writeQueue.async { [self] in
                    // Blocks while the library isn't reading — backpressure again.
                    if writeAll(data) { receiveNext() } else { close("write to the SPICE client failed (errno \(errno))") }
                }
            }
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

    // MARK: teardown

    func close(_ reason: String? = nil) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        if let reason { log("\(label): \(reason)") }
        task.cancel(with: .normalClosure, reason: nil)
        // shutdown() unblocks the pump's read() and fails any pending write();
        // the descriptor is closed only once both queues have let go of it.
        shutdown(fd, SHUT_RDWR)
        readQueue.async { [fd, writeQueue] in
            writeQueue.sync { _ = Darwin.close(fd) }
        }
    }
}
