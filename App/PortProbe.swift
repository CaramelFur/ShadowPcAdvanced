import Foundation
import Network

/// TCP reachability test against a running VM's public address. Shadow's API
/// has no way to open ports, so this is how to find out what actually answers.
enum PortProbe {
    enum Outcome: Equatable {
        /// Something accepted the connection.
        case open
        /// Actively refused: the address is reachable, nothing listens/forwards there.
        case refused
        /// No answer at all: dropped by a firewall / not forwarded.
        case filtered
        case failed(String)

        var label: String {
            switch self {
            case .open: return "open"
            case .refused: return "refused"
            case .filtered: return "no answer (filtered)"
            case .failed(let why): return why
            }
        }
    }

    static func tcp(host: String, port: Int, timeout: TimeInterval = 3) async -> Outcome {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return .failed("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "port-probe")
        return await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ outcome: Outcome) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.open)
                case .failed(let error), .waiting(let error):
                    if case .posix(let code) = error, code == .ECONNREFUSED { finish(.refused) }
                    else if case .failed = state { finish(.failed(error.localizedDescription)) }
                    // .waiting with anything else: keep waiting until the timeout.
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.filtered) }
            connection.start(queue: queue)
        }
    }

    /// First address the name resolves to (the `ip` field is usually a hostname).
    static func resolve(_ host: String) async -> String? {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
            defer { freeaddrinfo(result) }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }.value
    }
}
