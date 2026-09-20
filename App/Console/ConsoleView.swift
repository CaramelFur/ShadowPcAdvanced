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
            HStack(spacing: 0) {
                if viewModel.logVisible, !viewModel.isFullScreen {
                    ConsoleLogPane(lines: viewModel.logLines)
                    Divider()
                }
                // The engine view stays mounted underneath (a web engine keeps
                // loading its page); without a session the placeholder covers it.
                ZStack {
                    EngineView(view: viewModel.engine.view)
                        .allowsHitTesting(viewModel.hasSession)
                    if let placeholder = viewModel.placeholder {
                        ConsolePlaceholderView(viewModel: viewModel, placeholder: placeholder)
                    }
                }
            }
        }
        .background(Color.black)
    }
}

/// Stands in for the display while the VM is stopped, starting, queued or
/// stopping; the console connects by itself once there is a session.
private struct ConsolePlaceholderView: View {
    @ObservedObject var viewModel: ConsoleViewModel
    let placeholder: ConsolePlaceholder

    var body: some View {
        VStack(spacing: 12) {
            Text(viewModel.vm.name).font(.title2.weight(.semibold))
            StateBadge(state: placeholder.state)
            Text(placeholder.message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let progress = placeholder.progress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout)
                }
            }
            if let error = placeholder.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if placeholder.canStart {
                Button("Start VM") { viewModel.startVM() }
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque, and it takes the clicks: nothing reaches the idle engine view below.
        .background(Color.black)
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
    }
}

/// SPICE link messages live here, never in the header.
private struct ConsoleLogPane: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: lines.count) { count in proxy.scrollTo(count - 1, anchor: .bottom) }
        }
        .frame(width: 260)
        .background(Color(nsColor: .underPageBackgroundColor))
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

                // Same buttons in the same order with or without a session; the
                // ones that need a guest are just off while the placeholder is up.
                Group {
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
                }
                .disabled(!viewModel.hasSession)
                Button("Fullscreen") { viewModel.toggleFullScreen() }
                Button("Power off VM", role: .destructive) { viewModel.powerOff() }
                    .tint(.red)
                    .disabled(!viewModel.hasSession)
                separator
                Toggle("Log", isOn: $viewModel.logVisible).toggleStyle(.button)
                Group {
                    Button("Reconnect") { viewModel.reconnect() }
                    if viewModel.engine.supportsCapture {
                        Button("Capture input") { viewModel.engine.toggleCapture() }
                            .help("Send every key (⌘Tab, ⌘Space, ⌘Q…) and the pointer to the VM. ⌃⌥ toggles it.")
                    }
                }
                .disabled(!viewModel.hasSession)

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
