import CryptoKit
import Foundation
import IOKit

/// `X-Shadow-Uuid`: sha1(sha256(machine-uuid)), matching node-machine-id.
/// Required by the legacy-VM endpoints (start/ip/timeout).
public enum DeviceUUID {
    /// Empty when the platform UUID can't be read; the header is then omitted.
    public static let current: String = {
        if let mid = platformUUID() { return derive(fromMachineID: mid) }
        return ProcessInfo.processInfo.environment["SHADOW_DEVICE_UUID"] ?? ""
    }()

    public static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let prop = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return prop?.takeRetainedValue() as? String
    }

    /// The SHA-1 is taken over the lowercase *hex text* of the SHA-256, not its
    /// raw bytes — getting this wrong silently breaks the legacy endpoints.
    public static func derive(fromMachineID mid: String) -> String {
        let machineID = SHA256.hash(data: Data(mid.lowercased().utf8)).hex
        return Insecure.SHA1.hash(data: Data(machineID.utf8)).hex
    }
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
