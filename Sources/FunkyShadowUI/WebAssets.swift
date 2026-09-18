import Foundation

/// Locates the bundled `web/` directory (console page + vendored spice-html5).
///
/// SwiftPM's generated `Bundle.module` looks at the .app root, which is not a
/// legal place for a resource bundle in a signed app, so resolve it by hand.
enum WebAssets {
    static let resourceBundleName = "FunkyShadow_FunkyShadowUI.bundle"

    static let rootURL: URL? = {
        let fm = FileManager.default
        // 1. Live-edit override.
        if let dir = ProcessInfo.processInfo.environment["FUNKYSHADOW_WEB_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            if fm.fileExists(atPath: url.appendingPathComponent("console.html").path) { return url }
        }
        // 2. Inside the .app, 3. next to the binary (`swift run`).
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for base in candidates.compactMap({ $0 }) {
            let bundleURL = base.appendingPathComponent(resourceBundleName)
            if let web = webDir(in: bundleURL) { return web }
        }
        // 4. SwiftPM's own lookup (absolute .build path baked in at compile time).
        return webDir(in: Bundle.module.bundleURL)
    }()

    private static func webDir(in bundleURL: URL) -> URL? {
        let fm = FileManager.default
        // Flat layout (SwiftPM) and Contents/Resources layout both occur.
        for sub in ["web", "Contents/Resources/web"] {
            let url = bundleURL.appendingPathComponent(sub, isDirectory: true)
            if fm.fileExists(atPath: url.appendingPathComponent("console.html").path) { return url }
        }
        return nil
    }
}
