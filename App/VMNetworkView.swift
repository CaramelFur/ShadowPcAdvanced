import ShadowAPI
import SwiftUI

/// What `GET /shadow/vm/ip` says about a running VM, plus a port probe.
struct VMNetworkView: View {
    let vm: VM
    let address: VMAddress
    @Environment(\.dismiss) private var dismiss
    @State private var resolved: String?
    @State private var portText = "8080"
    @State private var results: [(port: Int, outcome: PortProbe.Outcome)] = []
    @State private var probing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(vm.name) — network").font(.title3.bold())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Public host", address.ip)
                row("Resolves to", resolved ?? "…")
                row("Base port", address.port == 0 ? "—" : "\(address.port)  (proxy path /\(address.port / 1000))")
                row("VM proxy", address.proxyBase?.absoluteString ?? "—")
                row("Session", address.sessionID ?? "—")
            }
            .font(.callout)

            Text("Shadow's API only opens the HTTPS proxy (443) and the streamer's own channels on the base port. There is no call to forward another port, so whether something you host in the VM is reachable has to be tested.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("port", text: $portText).frame(width: 80).onSubmit { probe(ports: [Int(portText) ?? 0]) }
                Button("Probe") { probe(ports: [Int(portText) ?? 0]) }
                    .keyboardShortcut(.defaultAction)
                Button("Probe session range") { probe(ports: sessionPorts) }
                    .disabled(address.port == 0)
                    .help("443 plus base port … base port + 9")
                if probing { ProgressView().controlSize(.small) }
            }
            .disabled(probing)

            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(results, id: \.port) { r in
                            HStack {
                                Text("tcp/\(String(r.port))").monospacedDigit().frame(width: 90, alignment: .leading)
                                Text(r.outcome.label).foregroundStyle(r.outcome == .open ? Color.green : Color.secondary)
                            }
                            .font(.system(.callout, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { resolved = await PortProbe.resolve(address.ip) ?? "unresolved" }
    }

    private var sessionPorts: [Int] { [443] + (0..<10).map { address.port + $0 } }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func probe(ports: [Int]) {
        let wanted = ports.filter { (1...65535).contains($0) }
        guard !wanted.isEmpty else { return }
        probing = true
        Task {
            var fresh: [(Int, PortProbe.Outcome)] = []
            await withTaskGroup(of: (Int, PortProbe.Outcome).self) { group in
                for port in wanted { group.addTask { (port, await PortProbe.tcp(host: address.ip, port: port)) } }
                for await r in group { fresh.append(r) }
            }
            let kept = results.filter { old in !wanted.contains(old.port) }
            results = (kept + fresh.map { (port: $0.0, outcome: $0.1) }).sorted { $0.port < $1.port }
            probing = false
        }
    }
}
