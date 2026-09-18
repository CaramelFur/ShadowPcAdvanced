import Foundation

public enum VMState: Sendable, Equatable, CustomStringConvertible {
    case stopped
    case starting
    case queued
    case running
    case stopping
    case maintenance
    case unknown(String)

    /// Maps the status vocabularies seen across the inventory, the proxy
    /// `/status` and the SSE events. `nil`/empty means not running.
    public init(status raw: String?) {
        switch (raw ?? "").lowercased() {
        case "", "stopped", "off", "disconnected", "vm_off": self = .stopped
        case "started", "running", "vm_started", "vm_ready": self = .running
        case "starting", "booting", "vm_start": self = .starting
        case "stopping", "vm_shutdown": self = .stopping
        case "queued", "vm_in_waiting_queue": self = .queued
        case "maintenance": self = .maintenance
        default: self = .unknown(raw ?? "")
        }
    }

    public var description: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .queued: return "queued"
        case .running: return "running"
        case .stopping: return "stopping"
        case .maintenance: return "maintenance"
        case .unknown(let s): return s
        }
    }
}

/// The proxy's readiness triple (`GET {proxy}/status`).
public struct VMStatusSignals: Sendable, Equatable {
    public var vmStatus: String?
    public var reachable: Bool
    public var streamerUp: Bool

    public init(vmStatus: String?, reachable: Bool, streamerUp: Bool) {
        self.vmStatus = vmStatus
        self.reachable = reachable
        self.streamerUp = streamerUp
    }

    public init?(json: JSONValue?) {
        guard let j = json, j.object != nil else { return nil }
        self.init(
            vmStatus: j["vm_status"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            reachable: j["reachable"]?.isTruthy ?? false,
            streamerUp: j["streamer_up"]?.isTruthy ?? false
        )
    }

    /// Header label, as the web console shows it.
    public var label: String? {
        guard let base = vmStatus ?? (reachable ? "reachable" : nil) else { return nil }
        return streamerUp ? "\(base) · streamer up" : base
    }
}

public struct VM: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    /// Inventory `status`: null when not running; string or object otherwise.
    public var status: String?
    public var signals: VMStatusSignals?
    public var datacenter: String?
    public var hardware: String?
    public var provider: String?
    public var maintenance: Bool
    public var raw: JSONValue

    public init?(json j: JSONValue) {
        guard let id = j["id"]?.stringified, !id.isEmpty else { return nil }
        self.id = id
        name = j["name"]?.string ?? id
        if let s = j["status"] {
            status = s.string ?? s["vm_status"]?.string
            signals = VMStatusSignals(json: s)
        }
        datacenter = j["datacenter"]?["name"]?.string ?? j["datacenter"]?.string ?? j["datacenterName"]?.string
        hardware = (j["hwconfig"] ?? j["hardwareConfiguration"]).flatMap { $0.string ?? $0["name"]?.string }
        provider = j["provider"]?.string
        maintenance = j["maintenance"]?.isTruthy ?? false
        raw = j
    }

    /// `{ pagination, entries: [...] }`, with defensive fallbacks.
    public static func list(from body: JSONValue) -> [VM] {
        let arr = body["entries"]?.array ?? body["data"]?.array ?? body["vms"]?.array ?? body.array ?? []
        return arr.compactMap(VM.init(json:))
    }

    /// shadow-cli's `fmtVm`: maintenance wins, a live address means running,
    /// otherwise the inventory status (null = stopped).
    public func state(address: VMAddress?, proxy: VMStatusSignals? = nil) -> VMState {
        if maintenance { return .maintenance }
        if address != nil {
            if let s = proxy?.vmStatus { return VMState(status: s) }
            return .running
        }
        return VMState(status: status)
    }
}

/// Live access info from `GET /shadow/vm/ip`.
public struct VMAddress: Sendable, Equatable {
    public let ip: String
    public let port: Int
    public let proximusURL: String?
    public let sessionID: String?

    public init?(json: JSONValue?) {
        guard let d = json?.unwrapped, let ip = d["ip"]?.string, !ip.isEmpty else { return nil }
        self.ip = ip
        port = d["port"]?.int ?? 0
        proximusURL = d["proximus_url"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        sessionID = (d["vm_session_id"] ?? d["vmSessionId"])?.stringified.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `proximus_url`, else `https://<ip>/<port÷1000>`; no trailing slash.
    public var proxyBase: URL? {
        var s = proximusURL ?? "https://\(ip)/\(port / 1000)"
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

public struct QueueInfo: Sendable, Equatable {
    public let position: Int?
    /// Seconds.
    public let estimatedTime: Int?
    public let queueName: String?

    public init?(json: JSONValue?) {
        guard let d = json?.unwrapped, d.object != nil else { return nil }
        position = d["position"]?.int.flatMap { $0 > 0 ? $0 : nil }
        estimatedTime = d["estimated_time"]?.int.flatMap { $0 > 0 ? $0 : nil }
        queueName = d["queue_name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if position == nil, estimatedTime == nil, queueName == nil { return nil }
    }
}

public enum StartProgress: Sendable, Equatable {
    case requested
    case waiting(elapsed: TimeInterval)
    case queued(QueueInfo, elapsed: TimeInterval)
    case ready(VMAddress)
}

/// Everything needed to open (and later tear down) one SPICE console.
public struct SpiceTicket: Sendable, Equatable {
    public let uri: String
    public let secret: String
    public let clientID: String
    public let proxy: ProxyContext
}

/// A VM-proxy base plus the launcher-scoped bearer for it.
public struct ProxyContext: Sendable, Equatable {
    public let base: URL
    public let token: String

    public init(base: URL, token: String) {
        self.base = base
        self.token = token
    }

    func url(_ path: String) -> URL { URL(string: base.absoluteString + path)! }
}
