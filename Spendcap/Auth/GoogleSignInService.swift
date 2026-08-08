import Foundation
import GoogleSignIn
import UIKit

/// Runs the native Google account sheet and hands back the pieces Supabase's
/// `signInWithIdToken` needs.
///
/// Google's ID token carries an `at_hash` claim, so the access token has to go
/// along with it — Supabase hashes the access token and compares. Sending the
/// ID token alone is rejected, and the error says nothing about `at_hash`.
@MainActor
enum GoogleSignInService {
    struct Credential {
        let idToken: String
        let accessToken: String
    }

    enum Failure: LocalizedError {
        case notConfigured
        case cancelled
        case missingIdentityToken
        case noPresenter

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Google sign-in isn't set up in this build."
            case .cancelled:
                return "Google sign-in was cancelled."
            case .missingIdentityToken:
                return "Google did not return an identity token. Try again."
            case .noPresenter:
                return "Couldn't present the Google sign-in screen."
            }
        }
    }

    /// The iOS OAuth client id, injected through Secrets.xcconfig → Info.plist.
    ///
    /// Empty in a build where the client hasn't been created yet, which is the
    /// signal `isConfigured` uses to hide the button entirely rather than
    /// offer one that can only fail.
    static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_CLIENT_ID") as? String) ?? ""
    }

    static var isConfigured: Bool {
        !clientID.isEmpty && clientID.hasSuffix(".apps.googleusercontent.com")
    }

    static func authorize() async throws -> Credential {
        guard isConfigured else { throw Failure.notConfigured }
        guard let presenter = topViewController() else { throw Failure.noPresenter }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw Failure.missingIdentityToken
            }
            return Credential(
                idToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
        } catch let error as NSError
            where error.domain == kGIDSignInErrorDomain
            && error.code == GIDSignInError.canceled.rawValue {
            throw Failure.cancelled
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
