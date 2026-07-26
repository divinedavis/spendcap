import Foundation
import Combine

/// Bridges the Plaid OAuth round trip.
///
/// OAuth banks hand the user off to their own app or to Safari. iOS is free to
/// terminate Spendcap while that happens, so the bank's redirect back to
/// `https://divinedavis.com/spendcap/oauth/` may arrive at a *cold* launch. In
/// that case LinkKit can't resume on its own — it needs a fresh handler built
/// from the **same** link token, followed by `resumeAfterTermination(from:)`.
///
/// So the token has to outlive the process: it's stashed in UserDefaults when
/// Link opens and cleared once the flow finishes. Link tokens are short-lived
/// (a few hours) and grant nothing on their own — the access token never
/// touches the client — so UserDefaults is an appropriate home. It is
/// deliberately *not* the Keychain: a stale token surviving a reinstall would
/// only produce a confusing resume attempt.
@MainActor
final class PlaidLinkStore: ObservableObject {
    static let shared = PlaidLinkStore()

    private static let tokenKey = "plaid.pendingLinkToken"

    /// Set when the bank redirects back to us; drives the resume presentation.
    @Published var pendingRedirect: URL?

    private init() {}

    var savedToken: String? {
        UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    func remember(token: String) {
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        pendingRedirect = nil
    }

    /// Accepts a universal-link URL if it's our Plaid OAuth redirect.
    /// Returns false for any other link so unrelated universal links (Hidden
    /// Gems shares live on the same domain) fall through untouched.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard Self.isOAuthRedirect(url), savedToken != nil else { return false }
        pendingRedirect = url
        return true
    }

    static func isOAuthRedirect(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // Anchor the host: a bare hasSuffix check would also admit
        // "notdivinedavis.com".
        let ours = host == "divinedavis.com" || host.hasSuffix(".divinedavis.com")
        guard ours else { return false }
        return url.path.hasPrefix("/spendcap/oauth")
    }
}
