import AppKit

/// Borrows the `tech.shadow://` URL scheme for the duration of a login and
/// hands it back to whoever had it (normally Shadow PC.app).
///
/// The previous handler is persisted *before* switching, so a crash or kill
/// mid-login is repaired at next launch.
@MainActor
final class URLSchemeClaimer {
    static let scheme = "tech.shadow"
    static let shadowPCBundleID = "com.electron.shadow"

    private let defaults = UserDefaults.standard
    private let previousPathKey = "schemeClaim.previousHandlerPath"
    private let activeKey = "schemeClaim.active"
    static let enabledKey = "schemeClaim.enabled"

    private var probe: URL { URL(string: "\(Self.scheme)://probe")! }

    /// Without a real .app bundle Launch Services can't deliver URLs to us.
    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) == nil ? true : defaults.bool(forKey: Self.enabledKey)
    }

    var claimIsActive: Bool { defaults.bool(forKey: activeKey) }

    func currentHandler() -> URL? { NSWorkspace.shared.urlForApplication(toOpen: probe) }

    var weAreHandler: Bool {
        currentHandler()?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Returns true once Launch Services reports this app as the handler.
    func claim() async -> Bool {
        guard isBundled, isEnabled else { return false }
        if weAreHandler { return true }
        if let previous = currentHandler() { defaults.set(previous.path, forKey: previousPathKey) }
        defaults.set(true, forKey: activeKey)
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: Self.scheme)
        } catch {
            if let id = Bundle.main.bundleIdentifier {
                LSSetDefaultHandlerForURLScheme(Self.scheme as CFString, id as CFString)
            }
        }
        // Launch Services applies the change asynchronously.
        for _ in 0..<10 {
            if weAreHandler { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return weAreHandler
    }

    /// Give the scheme back to the handler recorded by `claim()`.
    func restore() async {
        guard claimIsActive else { return }
        defer { defaults.set(false, forKey: activeKey) }
        if let path = defaults.string(forKey: previousPathKey), FileManager.default.fileExists(atPath: path) {
            if await setHandler(URL(fileURLWithPath: path)) { return }
        }
        _ = await restoreShadowPC()
    }

    /// Crash recovery: a claim that was never released.
    func recoverIfNeeded() async {
        if claimIsActive { await restore() }
    }

    /// Explicitly hand the scheme to the official client, preferring /Applications.
    @discardableResult
    func restoreShadowPC() async -> Bool {
        let candidates = NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .filter { Bundle(url: $0)?.bundleIdentifier == Self.shadowPCBundleID }
            .sorted { a, _ in a.path.hasPrefix("/Applications/") }
        if let app = candidates.first, await setHandler(app) { return true }
        return LSSetDefaultHandlerForURLScheme(Self.scheme as CFString, Self.shadowPCBundleID as CFString) == noErr
    }

    private func setHandler(_ app: URL) async -> Bool {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: Self.scheme)
            return true
        } catch {
            return false
        }
    }

    /// Synchronous best effort for `applicationWillTerminate`.
    func restoreBlocking() {
        guard claimIsActive else { return }
        let id = defaults.string(forKey: previousPathKey).flatMap { Bundle(path: $0)?.bundleIdentifier } ?? Self.shadowPCBundleID
        LSSetDefaultHandlerForURLScheme(Self.scheme as CFString, id as CFString)
        defaults.set(false, forKey: activeKey)
    }
}
