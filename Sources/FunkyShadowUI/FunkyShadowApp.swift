import AppKit
import SwiftUI

public struct FunkyShadowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        // `Window`, not `WindowGroup`: an incoming tech.shadow:// URL must never
        // spawn a second main window.
        Window("FunkyShadow", id: "main") {
            RootView()
                .frame(minWidth: 560, minHeight: 360)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbundled (`swift run`) processes start as background apps.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("FunkyShadow").font(.largeTitle.bold())
            Text(WebAssets.rootURL == nil ? "web assets: missing" : "web assets: ok")
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
