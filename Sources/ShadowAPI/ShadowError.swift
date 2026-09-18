import Foundation

public enum ShadowError: Error, LocalizedError, Equatable {
    /// No stored session.
    case notLoggedIn
    /// The stored session can no longer be refreshed.
    case loginRequired(String)
    case oauth(String)
    case stateMismatch
    case noAuthorizationCode
    case http(status: Int, message: String, endpoint: String)
    /// Cloudflare bot protection (error 1010 / browser_signature_banned).
    case cloudflareBlocked
    case rateLimited(endpoint: String)
    case noProxyToken
    case noSpiceConsole(String)
    case startTimeout
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not logged in."
        case .loginRequired(let why): return "Session expired — please sign in again. (\(why))"
        case .oauth(let m): return "Sign-in failed: \(m)"
        case .stateMismatch: return "State mismatch in the sign-in redirect — aborted (possible CSRF)."
        case .noAuthorizationCode: return "No authorization code found in the redirect."
        case .http(let status, let message, let endpoint): return "\(endpoint) failed (\(status)): \(message)"
        case .cloudflareBlocked:
            return "Cloudflare blocked the request (browser_signature_banned). The launcher API is bot-protected; try from the network the official app uses."
        case .rateLimited(let endpoint): return "\(endpoint) is rate limited (429)."
        case .noProxyToken: return "Could not mint a VM-proxy token."
        case .noSpiceConsole(let m): return "No SPICE console returned by the proxy: \(m)"
        case .startTimeout: return "The VM never returned an address within the timeout."
        case .transport(let m): return "Network error: \(m)"
        case .decoding(let m): return "Unexpected response: \(m)"
        }
    }
}
