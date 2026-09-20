import AppKit
import SwiftUI

@main
struct FunkyShadowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // `Window`, not `WindowGroup`: an incoming tech.shadow:// URL must never
        // spawn a second main window.
        Window("FunkyShadow", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.login)
                .frame(minWidth: 620, minHeight: 380)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("API Log", id: "debuglog") {
            DebugLogView()
                .environmentObject(model.logStore)
                .frame(minWidth: 760, minHeight: 420)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Settings {
            SettingsView()
                .environmentObject(model.login)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Catches the redirect even when it cold-launches the app.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        // Held keys must repeat in the console, not open the accent popup.
        UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unbundled (`swift run`) processes start as background apps.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        // `FunkyShadow --selftest-native`: exercise the spice-glib thread, the
        // open-fd path and the splice against a dead endpoint, then exit.
        if CommandLine.arguments.contains("--selftest-native") {
            Task { @MainActor in exit(await NativeSpiceEngine.selfTest() ? 0 : 1) }
            return
        }
        AppModel.shared.start()
        // `FunkyShadow --bench-splice ws://127.0.0.1:8765/`: splice throughput (diagnostics).
        if let i = CommandLine.arguments.firstIndex(of: "--bench-splice"), i + 1 < CommandLine.arguments.count,
           let url = URL(string: CommandLine.arguments[i + 1]) {
            DispatchQueue.global().async { SpiceSplice.benchmark(url: url) }
            return
        }
        // `FunkyShadow --dump-windows`: print window/modal state after launch (diagnostics).
        if CommandLine.arguments.contains("--dump-windows") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppDelegate.dumpWindows() }
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: s) else { return }
        deliver(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(deliver)
    }

    private func deliver(_ url: URL) {
        guard url.scheme?.lowercased() == URLSchemeClaimer.scheme else { return }
        Task { @MainActor in await AppModel.shared.login.handleCallback(url) }
    }

    static func dumpWindows() {
        func print(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        print("modalWindow: \(NSApp.modalWindow?.title ?? "none")")
        for w in NSApp.windows where w.isVisible {
            let close = w.standardWindowButton(.closeButton)
            print("window '\(w.title)' closable=\(w.styleMask.contains(.closable)) closeEnabled=\(close?.isEnabled ?? false) sheet=\(w.attachedSheet != nil) key=\(w.isKeyWindow) class=\(type(of: w))")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Release proxy clients so the single-client SPICE console isn't left held.
        guard AppModel.shared.consoles.hasOpenConsoles else { return .terminateNow }
        Task { @MainActor in
            await AppModel.shared.consoles.closeAllAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.login.claimer.restoreBlocking()
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.authState {
        case .none:
            ProgressView()
        case .loggedOut:
            LoginView()
        case .loggedIn:
            VMListView()
        }
    }
}
