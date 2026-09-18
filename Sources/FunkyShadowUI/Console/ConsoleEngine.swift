import AppKit
import ShadowAPI

enum ConsoleKey: Equatable {
    case delete
    case backspace
    case function(Int)

    /// DOM `code` and legacy `keyCode`, which spice-html5 maps to a scancode.
    var dom: (code: String, keyCode: Int) {
        switch self {
        case .delete: return ("Delete", 46)
        case .backspace: return ("Backspace", 8)
        case .function(let n): return ("F\(n)", 111 + n) // F1=112 … F12=123
        }
    }
}

enum ConsoleLinkState: String {
    case connecting, connected, error, badTicket
}

enum ConsoleEvent {
    case pageReady
    case log(String)
    case link(ConsoleLinkState, message: String?)
    case inputsReady
}

struct TypeResult: Equatable {
    var typed: Int
    var skipped: [String]
    var aborted: Bool
}

/// The seam between the console window and whatever renders SPICE. Today that
/// is spice-html5 in a WKWebView; a native engine could replace it later.
@MainActor
protocol ConsoleEngine: AnyObject {
    var view: NSView { get }
    var events: AsyncStream<ConsoleEvent> { get }
    /// Asked for a ticket on every (re)connect; `fresh` forces a new one.
    var ticketProvider: ((_ fresh: Bool) async throws -> SpiceTicket?)? { get set }

    func connect(fresh: Bool) async
    func disconnect() async
    func send(_ key: ConsoleKey) async
    func sendCtrlAltDel() async
    func spamEscape(duration: TimeInterval, period: TimeInterval) async
    func typeText(_ text: String) async throws -> TypeResult
    func screenshotPNG() async throws -> Data
    func setLogVisible(_ visible: Bool) async
    func setBare(_ bare: Bool) async
    func focus()
}
