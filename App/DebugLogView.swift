import AppKit
import ShadowAPI
import SwiftUI
import UniformTypeIdentifiers

/// Every request/response the app makes, secrets already redacted.
struct DebugLogView: View {
    @EnvironmentObject private var store: APILogStore
    @State private var filter = ""
    @State private var selection: APILogEntry.ID?
    @State private var exportError: String?

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var visible: [APILogEntry] {
        let all = Array(store.entries.reversed())
        guard !filter.isEmpty else { return all }
        return all.filter { e in
            e.url.localizedCaseInsensitiveContains(filter) || e.method.localizedCaseInsensitiveContains(filter)
                || String(e.status ?? 0).contains(filter)
        }
    }

    var body: some View {
        VSplitView {
            Table(visible, selection: $selection) {
                TableColumn("Time") { Text(Self.time.string(from: $0.date)).monospacedDigit() }.width(90)
                TableColumn("Method") { Text($0.method) }.width(60)
                TableColumn("Status") { e in
                    Text(e.status.map(String.init) ?? "ERR")
                        .foregroundStyle((e.status ?? 999) < 400 ? Color.primary : Color.red)
                }.width(50)
                TableColumn("ms") { Text(String(Int($0.duration * 1000))).monospacedDigit() }.width(50)
                TableColumn("URL") { Text($0.url).lineLimit(1).truncationMode(.middle) }
            }
            .frame(minHeight: 160)

            ScrollView {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120)
        }
        .toolbar {
            ToolbarItemGroup {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Copy cURL") {
                    guard let e = selected else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.curl, forType: .string)
                }
                .disabled(selected == nil)
                Button("Export…") { export() }
                    .disabled(store.entries.isEmpty)
                    .help("Write every request and response in the log to a text file (secrets stay redacted).")
                Button("Clear") { store.clear(); selection = nil }
            }
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Oldest first, one transcript per request, so the file reads like a session.
    private func export() {
        let entries = store.entries
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.title = "Export API log"
        panel.message = "\(entries.count) requests. Tokens, tickets and codes are redacted."
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "ShadowPcAdvanced-api-log-\(stamp.string(from: Date())).txt"
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            let rule = "\n\n" + String(repeating: "─", count: 78) + "\n\n"
            let text = entries.map(\.transcript).joined(separator: rule) + "\n"
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { exportError = error.localizedDescription }
        }
    }

    private var selected: APILogEntry? { store.entries.first { $0.id == selection } }

    private var detail: String {
        guard let e = selected else { return "Select a request. Tokens, tickets and codes are redacted before they reach this log." }
        return e.transcript
    }
}
