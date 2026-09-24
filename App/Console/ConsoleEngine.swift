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
    /// A short hint for the toolbar; nil clears it.
    case notice(String?)
}

struct TypeResult: Equatable {
    var typed: Int
    var skipped: [String]
    var aborted: Bool
}

/// Which renderer a new console window uses.
enum ConsoleEngineKind: String, CaseIterable, Identifiable {
    /// UTM's CocoaSpice on spice-client-glib: Metal renderer, UTM-style input capture.
    case metal
    /// The first native engine: own C glue, CALayer/IOSurface presentation.
    case native
    /// spice-html5 in a WKWebView — the fallback.
    case web

    /// ".v2": the Metal engine became the default; an old stored choice doesn't pin the previous one.
    static let defaultsKey = "console.engine.v2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metal: return "Native — Metal (CocoaSpice)"
        case .native: return "Native — classic (CALayer)"
        case .web: return "Web (spice-html5)"
        }
    }

    static var current: ConsoleEngineKind {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ConsoleEngineKind.init(rawValue:)) ?? .metal
    }

    @MainActor
    func make() -> ConsoleEngine {
        switch self {
        case .metal:
            let engine = CocoaSpiceEngine()
            if engine.hasRenderer { return engine }
            // Never a crash, never a black window: say why and use the classic renderer.
            let classic = NativeSpiceEngine()
            classic.note("Metal renderer unavailable (\(CSMetalRenderer.lastInitializationError ?? "unknown reason")) — using the classic renderer for this console")
            return classic
        case .native: return NativeSpiceEngine()
        case .web: return WebSpiceEngine()
        }
    }
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
    func setBare(_ bare: Bool) async
    func focus()
    /// Whether keyboard + pointer can be captured for the guest (⌃⌥).
    var supportsCapture: Bool { get }
    func toggleCapture()
}

extension ConsoleEngine {
    var supportsCapture: Bool { false }
    func toggleCapture() {}
}
