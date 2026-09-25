import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var login: LoginController
    @AppStorage(URLSchemeClaimer.enabledKey) private var claimEnabled = true
    @AppStorage(ConsoleEngineKind.defaultsKey) private var engine = ConsoleEngineKind.metal.rawValue
    @AppStorage(InputTrace.defaultsKey) private var inputTrace = false
    @State private var handler = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                Picker("Console engine", selection: $engine) {
                    ForEach(ConsoleEngineKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Applies to consoles opened from now on. Both native engines use spice-glib \(NativeSpiceEngine.libraryVersion) (no audio); Metal draws with the GPU and can capture ⌘Tab, ⌘Space and the pointer (⌃⌥).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Log input sent to the VM", isOn: $inputTrace)
                Text("Native engines: one line in the console's Log window per key, click and wheel step sent to the guest (pointer moves at most four a second), with the time and how long each key was held. For tracking down doubled or stuck input; takes effect at once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Claim tech.shadow:// while signing in", isOn: $claimEnabled)
                Text("ShadowPcAdvanced borrows the URL scheme only during sign-in and gives it back afterwards. When off, paste the redirect URL into the sign-in dialog instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Current handler", value: handler)
                HStack {
                    Button("Restore Shadow PC.app handler") {
                        Task {
                            let ok = await login.claimer.restoreShadowPC()
                            note = ok ? "Restored." : "Shadow PC.app was not found."
                            reload()
                        }
                    }
                    Text(note).foregroundStyle(.secondary)
                }
                if !login.claimer.isBundled {
                    Text("Running unbundled (swift run): the scheme can't be claimed; sign-in is paste-only.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear(perform: reload)
    }

    private func reload() { handler = login.claimer.currentHandler()?.path ?? "(none)" }
}
