import Foundation

/// Settings → "Log input sent to the VM": one console-log line per key,
/// button and wheel event that goes to the guest; pointer moves at most a few
/// per second. Off by default. For chasing doubled, missing or stuck input:
/// the log then shows exactly what one keystroke became.
@MainActor
final class InputTrace {
    nonisolated static let defaultsKey = "console.inputTrace"
    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The engine's console log.
    var sink: ((String) -> Void)?

    private static let pointerInterval: TimeInterval = 0.25
    private var lastPointerLine: TimeInterval = -.infinity
    private var pointerSkipped = 0

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ text: @autoclosure () -> String) {
        guard Self.isOn, let sink else { return }
        sink("\(Self.clock.string(from: Date())) \(text())")
    }

    /// Pointer position/motion: at most 4 lines a second; the next shown line
    /// says how many were left out.
    func pointer(_ text: @autoclosure () -> String) {
        guard Self.isOn, sink != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerLine >= Self.pointerInterval else {
            pointerSkipped += 1
            return
        }
        lastPointerLine = now
        let skipped = pointerSkipped
        pointerSkipped = 0
        log(skipped > 0 ? "\(text()) (\(skipped) more not shown)" : text())
    }

    /// A set-1 scancode as the guest gets it: `0x1e`, or `0xe053` for an
    /// 0xE0-prefixed key (passed around as `0x100 | code`).
    nonisolated static func key(_ code: UInt32) -> String {
        code >= 0x100 ? String(format: "0xe0%02x", code & 0xFF) : String(format: "0x%02x", code)
    }

    nonisolated static func milliseconds(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
