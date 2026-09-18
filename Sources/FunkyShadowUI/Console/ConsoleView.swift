import SwiftUI

struct ConsoleView: View {
    @ObservedObject var viewModel: ConsoleViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Fullscreen shows only the display, edge to edge.
            if !viewModel.isFullScreen {
                ConsoleToolbar(viewModel: viewModel)
                Divider()
            }
            EngineView(view: viewModel.engine.view)
        }
        .background(Color.black)
    }
}

private struct EngineView: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Order is fixed: Ctrl+Alt+Del · Spam Esc · Del · Backspace · F1–F12 · Paste ·
/// Screenshot · Fullscreen · Power off.
private struct ConsoleToolbar: View {
    @ObservedObject var viewModel: ConsoleViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(viewModel.statusColor).frame(width: 8, height: 8)
                    Text(viewModel.statusLabel).font(.callout.weight(.semibold)).foregroundStyle(viewModel.statusColor)
                }
                .padding(.trailing, 6)

                Button("Ctrl+Alt+Del") { viewModel.ctrlAltDel() }
                Button("Spam Esc (5s)") { viewModel.spamEscape() }
                separator
                Button("Del") { viewModel.send(.delete) }
                Button("Backspace") { viewModel.send(.backspace) }
                ForEach(1...12, id: \.self) { n in
                    Button("F\(n)") { viewModel.send(.function(n)) }
                }
                separator
                Button("Paste text") { viewModel.pasteText() }
                Button("Screenshot") { viewModel.screenshot() }
                Button("Fullscreen") { viewModel.toggleFullScreen() }
                Button("Power off VM", role: .destructive) { viewModel.powerOff() }
                    .tint(.red)
                separator
                Toggle("Log", isOn: $viewModel.logVisible).toggleStyle(.button)
                Button("Reconnect") { viewModel.reconnect() }

                if let notice = viewModel.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // Toolbar clicks must not take keyboard focus away from the guest.
            .focusable(false)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var separator: some View { Divider().frame(height: 16).padding(.horizontal, 2) }
}
