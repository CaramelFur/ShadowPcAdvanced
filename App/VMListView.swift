import ShadowAPI
import SwiftUI

struct VMListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.rows.isEmpty {
                VStack(spacing: 8) {
                    if let error = model.listError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    } else if model.lastRefresh == nil {
                        ProgressView("Loading VMs…")
                    } else {
                        Text("No VMs on this account.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.rows) { row in
                    VMRowView(row: row)
                        .padding(.vertical, 6)
                }
                .safeAreaInset(edge: .bottom) {
                    if let error = model.listError {
                        Text(error).font(.callout).foregroundStyle(.red).padding(8)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                Button { openWindow(id: "debuglog") } label: { Label("API Log", systemImage: "list.bullet.rectangle") }
                Button { Task { await model.signOut() } } label: { Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") }
            }
        }
    }
}

struct VMRowView: View {
    @EnvironmentObject private var model: AppModel
    let row: VMRow

    private var busy: Bool { row.activity != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.vm.name).font(.headline)
                    StateBadge(state: row.state)
                    if row.signals?.streamerUp == true {
                        Text("streamer up").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text([row.vm.datacenter, row.vm.hardware, row.vm.provider].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let text = activityText {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(text).font(.callout)
                    }
                }
                if let error = row.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            Button("Start") { Task { await model.startVM(row.id) } }
                .disabled(busy || row.isRunning || row.state == .maintenance)
            Button("Stop") { Task { await model.stopVM(row.id) } }
                .disabled(busy || !row.isRunning)
            Button("Open Console") { Task { await model.openConsole(row.id) } }
                .disabled(busy || !row.isRunning)
        }
    }

    private var activityText: String? {
        switch row.activity {
        case .starting(let text): return text
        case .stopping: return "stopping…"
        case .openingConsole: return "opening console…"
        case nil: return nil
        }
    }
}

struct StateBadge: View {
    let state: VMState

    /// Same rule as the web console header: green running, red stopped, amber otherwise.
    static func color(for state: VMState) -> Color {
        switch state {
        case .running: return .green
        case .stopped: return .red
        default: return .orange
        }
    }

    var body: some View {
        Text(state.description)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Self.color(for: state).opacity(0.18), in: Capsule())
            .foregroundStyle(Self.color(for: state))
    }
}
