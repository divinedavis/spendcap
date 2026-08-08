import CryptoKit
import Foundation

/// The third-party sign-in providers Spendcap supports.
///
/// `key` is the string Supabase stores in `auth.identities.provider`, so it is
/// what every "is this linked?" check compares against. It is deliberately the
/// raw value rather than a separate constant — the two drifting apart would
/// make a linked account render as unlinked, and the fix for *that* looks like
/// a broken link button.
enum SocialProvider: String, CaseIterable, Identifiable, Sendable {
    case apple
    case google

    var id: String { rawValue }
    var key: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

/// One row of `auth.identities`, narrowed to what the UI needs.
///
/// Kept separate from the SDK's `UserIdentity` so the rules below can be unit
/// tested without constructing SDK types (which need a session).
struct LinkedIdentity: Equatable, Sendable {
    let provider: String
    let email: String?

    var socialProvider: SocialProvider? { SocialProvider(rawValue: provider) }
}

/// Rules about a user's set of identities.
///
/// The one that matters is `canUnlink`. Supabase will happily remove a user's
/// only identity, which leaves an account nobody — including its owner — can
/// ever sign into again, holding real bank history and a Plaid Item that
/// permanently consumed one of ten Trial slots. The account is not recoverable
/// from the app at that point. So the last identity is not removable, and the
/// UI must not offer it rather than offering it and failing.
enum IdentityRules {
    static func isLinked(_ provider: SocialProvider, in identities: [LinkedIdentity]) -> Bool {
        identities.contains { $0.provider == provider.key }
    }

    /// Providers not yet attached, in a stable order for the UI.
    static func linkable(from identities: [LinkedIdentity]) -> [SocialProvider] {
        SocialProvider.allCases.filter { !isLinked($0, in: identities) }
    }

    /// False when this is the only way into the account, or is not linked.
    static func canUnlink(_ provider: SocialProvider, from identities: [LinkedIdentity]) -> Bool {
        guard isLinked(provider, in: identities) else { return false }
        return identities.count > 1
    }

    /// What Settings shows next to the account: "Email, Apple" etc.
    static func summary(_ identities: [LinkedIdentity]) -> String {
        guard !identities.isEmpty else { return "None" }
        return identities.map { identity in
            identity.socialProvider?.displayName ?? identity.provider.capitalized
        }.joined(separator: ", ")
    }
}

/// Nonce plumbing for Sign in with Apple.
///
/// Apple signs the SHA-256 of the nonce into the ID token's `nonce` claim, and
/// Supabase compares that claim against the hash of the raw value we hand it.
/// So the request gets the *hashed* nonce and `signInWithIdToken` gets the
/// *raw* one; sending the same form to both fails verification, which surfaces
/// as a flat "invalid token" with nothing pointing at the nonce.
enum AuthNonce {
    /// Unreserved URL characters only — the value travels in a JWT claim.
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    static func random(length: Int = 32) -> String {
        precondition(length > 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes only fails if the RNG itself is unavailable;
            // continuing with a predictable nonce would defeat the point.
            fatalError("unable to generate a secure nonce (OSStatus \(status))")
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
