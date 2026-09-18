import AppKit
import ShadowAPI
import WebKit

final class ConsoleWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }
}

/// spice-html5 (vendored, unmodified) inside a WKWebView, driven through
/// `window.funky` in console.js.
@MainActor
final class WebSpiceEngine: NSObject, ConsoleEngine {
    let webView: ConsoleWebView
    var view: NSView { webView }
    let events: AsyncStream<ConsoleEvent>
    var ticketProvider: ((_ fresh: Bool) async throws -> SpiceTicket?)?

    private let continuation: AsyncStream<ConsoleEvent>.Continuation
    private var pageReady = false
    private var pendingConnect: Bool?

    /// spice-html5 reads/writes `navigator.clipboard` by itself once a guest
    /// agent shows up, which pops paste-permission UI in a WKWebView. Paste is
    /// done natively (NSPasteboard → typeText), so neutralise it from outside
    /// the vendored tree.
    private static let clipboardStub = """
    (() => {
      const stub = { readText: async () => "", writeText: async () => {}, read: async () => [], write: async () => {} };
      try { Object.defineProperty(navigator, "clipboard", { value: stub, configurable: true }); } catch (e) {}
    })();
    """

    override init() {
        let stream = AsyncStream<ConsoleEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(WebAssetSchemeHandler(), forURLScheme: WebAssetSchemeHandler.scheme)
        config.userContentController.addUserScript(
            WKUserScript(source: Self.clipboardStub, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = ConsoleWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 700), configuration: config)
        super.init()
        // The content controller retains its handlers; go through a weak proxy.
        let proxy = WeakMessageHandler(self)
        config.userContentController.add(proxy, name: "funkyEvent")
        config.userContentController.addScriptMessageHandler(proxy, contentWorld: .page, name: "funkyTicket")
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.load(URLRequest(url: WebAssetSchemeHandler.pageURL))
    }

    deinit { continuation.finish() }

    // MARK: - ConsoleEngine

    func connect(fresh: Bool) async {
        guard pageReady else {
            pendingConnect = fresh
            return
        }
        _ = try? await call("return await window.funky.connect(fresh)", ["fresh": fresh])
    }

    func disconnect() async {
        pendingConnect = nil
        guard pageReady else { return }
        _ = try? await call("window.funky.disconnect()")
    }

    func send(_ key: ConsoleKey) async {
        _ = try? await call("return window.funky.sendKey(code, keyCode)", ["code": key.dom.code, "keyCode": key.dom.keyCode])
    }

    func sendCtrlAltDel() async {
        _ = try? await call("return window.funky.ctrlAltDel()")
    }

    func spamEscape(duration: TimeInterval, period: TimeInterval) async {
        _ = try? await call("return window.funky.spamEsc(ms, period)", ["ms": Int(duration * 1000), "period": Int(period * 1000)])
    }

    func typeText(_ text: String) async throws -> TypeResult {
        let r = try await call("return await window.funky.typeText(text)", ["text": text]) as? [String: Any]
        return TypeResult(
            typed: r?["typed"] as? Int ?? 0,
            skipped: r?["skipped"] as? [String] ?? [],
            aborted: r?["aborted"] as? Bool ?? false
        )
    }

    func screenshotPNG() async throws -> Data {
        if let dataURL = try? await call("return window.funky.screenshot()") as? String,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) {
            return data
        }
        // Canvas unreadable (or a <video> stream overlay is active): snapshot the view.
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ShadowError.decoding("could not encode the screenshot") }
        return png
    }

    func setLogVisible(_ visible: Bool) async { _ = try? await call("window.funky.setLogVisible(v)", ["v": visible]) }

    func setBare(_ bare: Bool) async { _ = try? await call("window.funky.setBare(v)", ["v": bare]) }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.funky && window.funky.focusCanvas()", completionHandler: nil)
    }

    /// Arguments are passed as values, never interpolated into the script.
    @discardableResult
    private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    // MARK: - bridge

    fileprivate func handleEvent(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "pageReady":
            pageReady = true
            continuation.yield(.pageReady)
            if let fresh = pendingConnect {
                pendingConnect = nil
                Task { await connect(fresh: fresh) }
            }
        case "log":
            continuation.yield(.log(msg["message"] as? String ?? ""))
        case "link":
            let state = (msg["state"] as? String).flatMap(ConsoleLinkState.init(rawValue:)) ?? .error
            continuation.yield(.link(state, message: msg["message"] as? String))
        case "inputsReady":
            continuation.yield(.inputsReady)
        default:
            break
        }
    }

    fileprivate func handleTicketRequest(_ body: Any, reply: @escaping (Any?, String?) -> Void) {
        let fresh = (body as? [String: Any])?["fresh"] as? Bool ?? false
        guard let provider = ticketProvider else { return reply(["stop": true], nil) }
        Task { @MainActor in
            do {
                guard let ticket = try await provider(fresh) else { return reply(["stop": true], nil) }
                reply(["uri": ticket.uri, "password": ticket.secret], nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
}

extension WebSpiceEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation.yield(.log("page load failed: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation.yield(.log("page load failed: \(error.localizedDescription)"))
    }

    /// Only the bundled page may ever load in this view.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == WebAssetSchemeHandler.scheme ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        continuation.yield(.log("web content process terminated — reloading"))
        pendingConnect = false
        webView.load(URLRequest(url: WebAssetSchemeHandler.pageURL))
    }
}

/// WebKit delivers script messages on the main thread, but this SDK doesn't
/// annotate the protocol, so hop explicitly (FIFO, keeps log lines ordered).
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    weak var engine: WebSpiceEngine?

    init(_ engine: WebSpiceEngine) { self.engine = engine }

    @MainActor
    private func isTrusted(_ message: WKScriptMessage) -> Bool {
        message.frameInfo.isMainFrame && message.frameInfo.securityOrigin.protocol == WebAssetSchemeHandler.scheme
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        DispatchQueue.main.async {
            guard self.isTrusted(message) else { return }
            self.engine?.handleEvent(message.body)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        DispatchQueue.main.async {
            guard self.isTrusted(message), message.name == "funkyTicket" else { return replyHandler(nil, "untrusted frame") }
            guard let engine = self.engine else { return replyHandler(["stop": true], nil) }
            engine.handleTicketRequest(message.body, reply: replyHandler)
        }
    }
}
