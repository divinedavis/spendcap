import AuthenticationServices
import Foundation
import UIKit

/// Runs the native Sign in with Apple sheet and hands back the pieces
/// Supabase's `signInWithIdToken` needs.
///
/// `ASAuthorizationController` is delegate-driven and holds its delegate
/// *weakly*, so the controller and this coordinator both have to stay alive for
/// the length of the sheet. The continuation is resumed exactly once from
/// whichever delegate callback fires; `self` is held by the retain cycle
/// through `activeCoordinator` until then.
@MainActor
final class AppleSignInService: NSObject {
    struct Credential {
        let idToken: String
        /// The raw nonce, to be compared against the token's hashed claim.
        let nonce: String
        /// Apple sends the name only on the very first authorization, ever.
        let fullName: PersonNameComponents?
        let email: String?
    }

    enum Failure: LocalizedError {
        case cancelled
        case missingIdentityToken

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Sign in with Apple was cancelled."
            case .missingIdentityToken:
                return "Apple did not return an identity token. Try again."
            }
        }
    }

    private var continuation: CheckedContinuation<Credential, Error>?
    private var rawNonce: String?
    /// Keeps the coordinator alive while the system sheet is up.
    private static var active: AppleSignInService?

    /// Shared by both entry points: `SignInWithAppleButton` on the sign-in
    /// screen (which owns its own presentation, and is used there because App
    /// Review expects Apple's own button) and `authorize()` for the Settings
    /// link row (which has no button to hang a request off).
    static func configure(_ request: ASAuthorizationAppleIDRequest, rawNonce: String) {
        request.requestedScopes = [.fullName, .email]
        // Hashed here, raw to Supabase — see AuthNonce.
        request.nonce = AuthNonce.sha256(rawNonce)
    }

    static func credential(
        from authorization: ASAuthorization,
        rawNonce: String
    ) throws -> Credential {
        guard
            let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = appleCredential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            throw Failure.missingIdentityToken
        }
        return Credential(
            idToken: idToken,
            nonce: rawNonce,
            fullName: appleCredential.fullName,
            email: appleCredential.email
        )
    }

    /// Maps a thrown authorization error, treating a user cancel as such.
    static func normalize(_ error: Error) -> Error {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            return Failure.cancelled
        }
        return error
    }

    static func authorize() async throws -> Credential {
        let service = AppleSignInService()
        active = service
        defer { active = nil }
        return try await service.start()
    }

    private func start() async throws -> Credential {
        let nonce = AuthNonce.random()
        rawNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        Self.configure(request, rawNonce: nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Credential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension AppleSignInService: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let nonce = rawNonce else {
            finish(.failure(Failure.missingIdentityToken))
            return
        }
        finish(Result { try Self.credential(from: authorization, rawNonce: nonce) })
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        // A cancel is a normal outcome, not something to show in red.
        finish(.failure(Self.normalize(error)))
    }
}

extension AppleSignInService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
