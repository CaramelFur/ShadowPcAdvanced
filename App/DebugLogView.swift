import ShadowAPI
import SwiftUI

/// Every request/response the app makes, secrets already redacted.
struct DebugLogView: View {
    @EnvironmentObject private var store: APILogStore
    @State private var filter = ""
    @State private var selection: APILogEntry.ID?

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
                Button("Clear") { store.clear(); selection = nil }
            }
        }
    }

    private var selected: APILogEntry? { store.entries.first { $0.id == selection } }

    private var detail: String {
        guard let e = selected else { return "Select a request. Tokens, tickets and codes are redacted before they reach this log." }
        var out = "\(e.method) \(e.url)\n"
        out += e.requestHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        if let b = e.requestBody { out += "\n\n\(b)" }
        out += "\n\n← \(e.status.map(String.init) ?? "error")  (\(Int(e.duration * 1000)) ms)\n"
        if let err = e.error { out += err + "\n" }
        out += e.responseHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        if let b = e.responseBody { out += "\n\n\(b)" }
        return out
    }
}
