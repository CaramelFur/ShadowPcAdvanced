import Foundation

public enum AuthState: Sendable, Equatable {
    case loggedOut
    case loggedIn
}

/// Owns the stored session and hands out valid access tokens.
///
/// Refresh is single-flight: Hydra rotates refresh tokens, so two concurrent
/// refreshes with the same token would invalidate the whole chain.
public actor AuthSession {
    private let oauth: OAuthClient
    private let store: TokenStore
    private var tokens: TokenSet?
    private var loaded = false
    private var refreshTask: Task<TokenSet, Error>?
    private var observers: [UUID: AsyncStream<AuthState>.Continuation] = [:]

    public init(oauth: OAuthClient, store: TokenStore) {
        self.oauth = oauth
        self.store = store
    }

    private func current() -> TokenSet? {
        if !loaded {
            tokens = try? store.load()
            loaded = true
        }
        return tokens
    }

    public var state: AuthState { current() == nil ? .loggedOut : .loggedIn }

    /// Emits the current state, then every change.
    public func states() -> AsyncStream<AuthState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(self.state)
            self.observers[id] = continuation
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func publish() {
        let s = state
        for o in observers.values { o.yield(s) }
    }

    /// Store the result of an interactive login.
    public func adopt(_ newTokens: TokenSet) throws {
        try store.save(newTokens)
        tokens = newTokens
        loaded = true
        publish()
    }

    public func logout() {
        refreshTask?.cancel()
        refreshTask = nil
        try? store.clear()
        tokens = nil
        loaded = true
        publish()
    }

    /// A valid access token, refreshing first if the stored one has expired.
    public func validAccessToken() async throws -> String {
        guard let t = current() else { throw ShadowError.notLoggedIn }
        if t.isValid() { return t.accessToken }
        return try await refresh(from: t).accessToken
    }

    /// Called after a 401: refresh unless somebody already replaced `stale`.
    public func forceRefresh(stale: String) async throws -> String {
        guard let t = current() else { throw ShadowError.notLoggedIn }
        if t.accessToken != stale, t.isValid() { return t.accessToken }
        return try await refresh(from: t).accessToken
    }

    private func refresh(from old: TokenSet) async throws -> TokenSet {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.performRefresh(old) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ old: TokenSet) async throws -> TokenSet {
        do {
            let fresh = try await oauth.refresh(old)
            try store.save(fresh)
            tokens = fresh
            return fresh
        } catch let e as ShadowError {
            // A transport hiccup must not log the user out; a rejected refresh must.
            if case .transport = e { throw e }
            if case .cloudflareBlocked = e { throw e }
            try? store.clear()
            tokens = nil
            publish()
            throw ShadowError.loginRequired(e.localizedDescription)
        }
    }
}
