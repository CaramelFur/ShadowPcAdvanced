import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var login: LoginController
    @AppStorage(URLSchemeClaimer.enabledKey) private var claimEnabled = true
    @AppStorage(ConsoleEngineKind.defaultsKey) private var engine = ConsoleEngineKind.native.rawValue
    @State private var handler = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                Picker("Console engine", selection: $engine) {
                    ForEach(ConsoleEngineKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Applies to consoles opened from now on. Native: \(NativeSpiceEngine.libraryVersion), no audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Claim tech.shadow:// while signing in", isOn: $claimEnabled)
                Text("FunkyShadow borrows the URL scheme only during sign-in and gives it back afterwards. When off, paste the redirect URL into the sign-in dialog instead.")
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
