import CryptoKit
import Foundation
import Network

/// A WebSocket client reduced to what a byte-stream tunnel needs, on a plain
/// NWConnection (TCP or TLS).
///
/// URLSessionWebSocketTask hands over one message per callback (~80 µs each),
/// which caps a stream of small frames at a few MB/s. Here one TCP read of up
/// to 1 MiB is parsed in a loop and payload bytes are passed on as they arrive;
/// message boundaries are irrelevant to SPICE, so fragments need no reassembly.
final class RawWebSocket: @unchecked Sendable {
    /// Payload bytes, in order. Call `resume` when ready for more (backpressure).
    var onData: ((_ payload: Data, _ resume: @escaping () -> Void) -> Void)?
    var onClose: ((_ reason: String) -> Void)?

    private let url: URL
    private let userAgent: String
    private let subprotocol: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let key: String
    private var buffer = Data()
    private var handshakeDone = false
    private var finished = false

    // Frame parser state.
    private var payloadLeft = 0
    private var opcode: UInt8 = 0
    private var maskKey: [UInt8]?
    private var maskOffset = 0
    private var control = Data()

    init?(url: URL, userAgent: String, subprotocol: String = "binary", label: String) {
        guard let host = url.host, let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else { return nil }
        let secure = scheme == "wss"
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (secure ? 443 : 80))) else { return nil }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)
        self.url = url
        self.userAgent = userAgent
        self.subprotocol = subprotocol
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        queue = DispatchQueue(label: "raw-websocket.\(label)")
        var nonce = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce)
        key = Data(nonce).base64EncodedString()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.sendHandshake()
            case .failed(let error): self?.finish("connection failed: \(error.localizedDescription)")
            case .waiting(let error): self?.finish("cannot connect: \(error.localizedDescription)")
            case .cancelled: self?.finish("cancelled")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Sends one binary frame. `completion` runs on the socket's queue.
    func send(_ payload: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: Self.frame(opcode: 0x2, payload: payload), completion: .contentProcessed { completion($0) })
    }

    func close() {
        queue.async { [self] in
            guard !finished else { return }
            // Cancel only after the close frame is out, or it is dropped.
            connection.send(content: Self.frame(opcode: 0x8, payload: Data([0x03, 0xE8])), completion: .contentProcessed { [weak self] _ in
                self?.finish(nil)
            })
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish(nil) }
        }
    }

    // MARK: - handshake

    private func sendHandshake() {
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?\(query)" }
        let hostHeader = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        let request = [
            "GET \(path) HTTP/1.1", "Host: \(hostHeader)", "Upgrade: websocket", "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)", "Sec-WebSocket-Version: 13", "Sec-WebSocket-Protocol: \(subprotocol)",
            "User-Agent: \(userAgent)", "", "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish("handshake send failed: \(error.localizedDescription)") }
        })
        receive()
    }

    private func finishHandshake() -> Bool {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 16 * 1024 { finish("oversized handshake response") }
            return false
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        guard let status = lines.first, status.split(separator: " ").dropFirst().first == "101" else {
            finish("websocket upgrade refused: \(lines.first ?? "no status line")")
            return false
        }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let accept = lines.first { $0.lowercased().hasPrefix("sec-websocket-accept:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        guard accept == expected else {
            finish("websocket upgrade: bad Sec-WebSocket-Accept")
            return false
        }
        handshakeDone = true
        return true
    }

    // MARK: - receive

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if !self.handshakeDone, !self.finishHandshake() {
                if isComplete || error != nil { self.finish("closed during handshake") } else if !self.finished { self.receive() }
                return
            }
            let payload = self.parse()
            let next = { [weak self] in
                guard let self else { return }
                self.queue.async {
                    if let error { return self.finish("receive failed: \(error.localizedDescription)") }
                    if isComplete { return self.finish("closed by server") }
                    if !self.finished { self.receive() }
                }
            }
            if payload.isEmpty { next() } else if let onData = self.onData { onData(payload, next) } else { next() }
        }
    }

    /// Consumes `buffer`, returning all data-frame payload bytes found in it.
    private func parse() -> Data {
        var out = Data()
        var i = buffer.startIndex
        let end = buffer.endIndex
        parsing: while i < end, !finished {
            if payloadLeft == 0 {
                // Frame header: 2 bytes + extended length + optional mask.
                guard end - i >= 2 else { break }
                let b0 = buffer[i], b1 = buffer[i + 1]
                var length = Int(b1 & 0x7F)
                var header = 2
                if length == 126 { header += 2 } else if length == 127 { header += 8 }
                let masked = b1 & 0x80 != 0
                if masked { header += 4 }
                guard end - i >= header else { break }
                if length == 126 {
                    length = Int(buffer[i + 2]) << 8 | Int(buffer[i + 3])
                } else if length == 127 {
                    length = (0..<8).reduce(0) { $0 << 8 | Int(buffer[i + 2 + $1]) }
                }
                maskKey = masked ? Array(buffer[(i + header - 4)..<(i + header)]) : nil
                maskOffset = 0
                opcode = b0 & 0x0F
                payloadLeft = length
                control = Data()
                i += header
                if length == 0 {
                    if opcode >= 0x8 { handleControl() }
                    continue
                }
            }
            let take = min(payloadLeft, end - i)
            let slice = buffer[i..<(i + take)]
            i += take
            payloadLeft -= take
            if maskKey == nil, opcode < 0x8 {
                // The hot path: servers never mask. 0x0/0x1/0x2 are all just stream bytes.
                out.append(slice)
                continue
            }
            var chunk = Data(slice)
            if let maskKey {
                for k in 0..<chunk.count { chunk[k] ^= maskKey[(maskOffset + k) & 3] }
                maskOffset += take
            }
            if opcode >= 0x8 {
                control.append(chunk)
                if payloadLeft == 0 { handleControl() }
            } else {
                out.append(chunk)
            }
        }
        buffer = i < end ? Data(buffer[i..<end]) : Data()
        return out
    }

    private func handleControl() {
        switch opcode {
        case 0x9: // ping → pong with the same payload
            connection.send(content: Self.frame(opcode: 0xA, payload: control), completion: .idempotent)
        case 0x8:
            var reason = "closed by server"
            if control.count >= 2 {
                let code = Int(control[control.startIndex]) << 8 | Int(control[control.startIndex + 1])
                let text = String(decoding: control.dropFirst(2), as: UTF8.self)
                reason += " (\(code)\(text.isEmpty ? "" : " \(text)"))"
            }
            connection.send(content: Self.frame(opcode: 0x8, payload: control.prefix(2)), completion: .idempotent)
            finish(reason)
        default:
            break // pong
        }
    }

    private func finish(_ reason: String?) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let reason { onClose?(reason) }
        onData = nil
        onClose = nil
    }

    // MARK: - framing

    /// Client frames must be masked (RFC 6455 §5.3).
    static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data(capacity: payload.count + 14)
        out.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n < 65536 {
            out.append(contentsOf: [UInt8(0x80 | 126), UInt8(n >> 8), UInt8(n & 0xFF)])
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((n >> shift) & 0xFF)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        out.append(contentsOf: mask)
        let start = out.count
        out.append(payload)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for k in 0..<n { p[start + k] ^= mask[k & 3] }
        }
        return out
    }
}
