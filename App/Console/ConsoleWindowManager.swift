import AppKit
import ShadowAPI
import SwiftUI

/// One console window per VM — SPICE is single-client, so a second window for
/// the same VM would only kick the first.
@MainActor
final class ConsoleWindowManager {
    private unowned let model: AppModel
    private var controllers: [String: ConsoleWindowController] = [:]

    init(model: AppModel) { self.model = model }

    var hasOpenConsoles: Bool { !controllers.isEmpty }

    /// No address needed: the view model follows the VM's row, shows a
    /// placeholder while there is no session and connects once there is one.
    func open(vm: VM) {
        if let existing = controllers[vm.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let viewModel = ConsoleViewModel(vm: vm, model: model)
        let controller = ConsoleWindowController(viewModel: viewModel) { [weak self] in self?.controllers[vm.id] = nil }
        controllers[vm.id] = controller
        controller.showWindow(nil)
        viewModel.start()
    }

    func closeAll() { controllers.values.forEach { $0.close() } }

    /// For app termination: wait until every proxy client has been released.
    func closeAllAndWait() async {
        let open = Array(controllers.values)
        controllers = [:]
        // Bounded: quitting must never hang on an unreachable proxy.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for controller in open { await controller.viewModel.close() }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            await group.next()
            group.cancelAll()
        }
        open.forEach { $0.close() }
    }
}

final class ConsoleWindowController: NSWindowController, NSWindowDelegate {
    let viewModel: ConsoleViewModel
    private let onClose: () -> Void

    init(viewModel: ConsoleViewModel, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "\(viewModel.vm.name) — Console"
        window.minSize = NSSize(width: 760, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConsoleView(viewModel: viewModel))
        window.setFrameAutosaveName("console-\(viewModel.vm.id)")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowDidBecomeKey(_ notification: Notification) { viewModel.engine.focus() }
    func windowDidEnterFullScreen(_ notification: Notification) { viewModel.isFullScreen = true; viewModel.engine.focus() }
    func windowDidExitFullScreen(_ notification: Notification) { viewModel.isFullScreen = false; viewModel.engine.focus() }

    func windowWillClose(_ notification: Notification) {
        onClose()
        Task { await viewModel.close() }
    }
}
