import Foundation

/// Locates the bundled `web/` directory (console page + vendored spice-html5),
/// which Xcode copies into Contents/Resources as a folder reference.
enum WebAssets {
    static let rootURL: URL? = {
        let fm = FileManager.default
        var candidates: [URL] = []
        // Live-edit override.
        if let dir = ProcessInfo.processInfo.environment["FUNKYSHADOW_WEB_DIR"], !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: dir, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("web", isDirectory: true)) }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("console.html").path) }
    }()
}
