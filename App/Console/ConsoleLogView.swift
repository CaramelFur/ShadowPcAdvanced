import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The console's own log (SPICE link, channels, input notes) in its own window,
/// laid out like the API Log window: filter, copy, export, clear.
struct ConsoleLogView: View {
    @ObservedObject var viewModel: ConsoleViewModel
    @State private var filter = ""
    @State private var exportError: String?

    private var visible: [String] {
        guard !filter.isEmpty else { return viewModel.logLines }
        return viewModel.logLines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Spacer()
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.logLines.joined(separator: "\n"), forType: .string)
                }
                Button("Export…") { export() }
                Button("Clear") { viewModel.clearLog() }
            }
            .disabled(viewModel.logLines.isEmpty)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: viewModel.logLines.count) { _ in
                    if filter.isEmpty, !visible.isEmpty { proxy.scrollTo(visible.count - 1, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 240)
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export() {
        let lines = viewModel.logLines
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.title = "Export console log"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "\(viewModel.vm.name)-console-log-\(stamp.string(from: Date())).txt"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do { try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) } catch { exportError = error.localizedDescription }
        }
    }
}
