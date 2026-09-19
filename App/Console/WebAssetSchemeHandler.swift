import Foundation
import WebKit

/// Serves the bundled `web/` directory at `funky://console/…`.
///
/// ES-module imports fail on file:// (opaque origin), and a custom scheme is
/// not https, so the page may open `wss://` and `ws://127.0.0.1` sockets.
final class WebAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "funky"
    static let pageURL = URL(string: "funky://console/console.html")!
    static let origin = "funky://console"

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "png": "image/png", "svg": "image/svg+xml",
        "wasm": "application/wasm", "map": "application/json",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = WebAssets.rootURL?.standardizedFileURL else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let path = url.path.isEmpty || url.path == "/" ? "/console.html" : url.path
        let file = root.appendingPathComponent(path).standardizedFileURL
        // No traversal outside the web root.
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(resp)
            return task.didFinish()
        }
        let headers = [
            // Module scripts are MIME-checked strictly.
            "Content-Type": Self.mime[file.pathExtension.lowercased()] ?? "application/octet-stream",
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
