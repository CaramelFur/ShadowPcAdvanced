import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var login: LoginController
    @State private var pasted = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("FunkyShadow").font(.largeTitle.bold())
            Text("Sign in with your Shadow account to manage your cloud PCs.")
                .foregroundStyle(.secondary)

            switch login.phase {
            case .idle:
                Button("Sign in with Shadow…") { Task { await login.begin() } }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            case .preparing:
                ProgressView("Preparing sign-in…")
            case .waiting(let claimed):
                waiting(claimed: claimed)
            case .exchanging:
                ProgressView("Finishing sign-in…")
            }

            if let error = login.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func waiting(claimed: Bool) -> some View {
        ProgressView("Waiting for the browser sign-in…")
        Text(claimed
            ? "The redirect comes back here automatically. If it opens Shadow PC instead, paste it below."
            : "This build can't receive the tech.shadow:// redirect. After signing in, copy the tech.shadow://… URL (or just the code) and paste it below.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            TextField("tech.shadow://openidconnect/callback?code=…", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button("Use", action: submit)
                .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        HStack {
            if let url = login.authorizationURL {
                Button("Reopen browser") { NSWorkspace.shared.open(url) }
                Button("Copy sign-in link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Cancel", role: .cancel) { Task { await login.cancel() } }
        }
    }

    private func submit() {
        let text = pasted
        pasted = ""
        Task { await login.submitPasted(text) }
    }
}
