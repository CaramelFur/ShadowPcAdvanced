import AppKit
import ShadowAPI

/// Interactive PKCE login: open the browser, receive the `tech.shadow://`
/// redirect (or a pasted one), exchange the code.
@MainActor
final class LoginController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        /// Browser is open; `claimed` says whether the redirect will reach us.
        case waiting(claimed: Bool)
        case exchanging
    }

    @Published private(set) var phase: Phase = .idle
    @Published var errorMessage: String?

    let claimer = URLSchemeClaimer()
    private let client: ShadowClient
    private var pending: AuthorizationRequest?
    private var timeoutTask: Task<Void, Never>?
    static let loginTimeout: TimeInterval = 300

    init(client: ShadowClient) { self.client = client }

    var authorizationURL: URL? { pending?.url }

    func begin() async {
        guard phase == .idle else { return }
        errorMessage = nil
        phase = .preparing
        do {
            let request = try await client.oauth.makeAuthorizationRequest()
            pending = request
            let claimed = await claimer.claim()
            phase = .waiting(claimed: claimed)
            NSWorkspace.shared.open(request.url)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.loginTimeout * 1_000_000_000))
                if !Task.isCancelled { await self?.finish(error: "Sign-in timed out.") }
            }
        } catch {
            await finish(error: error.localizedDescription)
        }
    }

    func cancel() async { await finish(error: nil) }

    /// A `tech.shadow://…` URL delivered by Launch Services.
    func handleCallback(_ url: URL) async {
        guard pending != nil else {
            errorMessage = "Received a sign-in redirect, but no sign-in is in progress. Please try again."
            return
        }
        await complete(with: url.absoluteString)
    }

    /// Manual fallback: the whole redirect URL, or just the code.
    func submitPasted(_ text: String) async {
        guard pending != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await complete(with: text)
    }

    private func complete(with input: String) async {
        guard let request = pending, phase != .exchanging else { return }
        do {
            let code = try OAuthClient.parseCallback(input, expectedState: request.state)
            // The state is single-use from here on.
            pending = nil
            phase = .exchanging
            let tokens = try await client.oauth.exchange(code: code, verifier: request.verifier)
            try await client.auth.adopt(tokens)
            await finish(error: nil)
        } catch ShadowError.stateMismatch {
            // Could be a stale redirect from an earlier attempt; keep waiting.
            errorMessage = ShadowError.stateMismatch.localizedDescription
        } catch {
            await finish(error: error.localizedDescription)
        }
    }

    private func finish(error: String?) async {
        timeoutTask?.cancel()
        timeoutTask = nil
        pending = nil
        phase = .idle
        errorMessage = error
        await claimer.restore()
        NSApp.activate(ignoringOtherApps: true)
    }
}
