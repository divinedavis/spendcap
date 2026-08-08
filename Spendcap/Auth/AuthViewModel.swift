import AuthenticationServices
import Foundation
import Supabase

/// What the app should be showing, which on a cold start is a three-way
/// question and not a two-way one.
///
/// Treating "no session yet" as "signed out" is what made the sign-in screen
/// appear for a moment on every launch of an already-signed-in app: `session`
/// starts nil and is only filled in once the auth stream reports what is in
/// local storage. Until we have heard, the honest answer is "restoring", and
/// the honest thing to draw is the launch screen.
enum AuthPhase: Equatable {
    case restoring
    case signedIn
    case signedOut

    static func resolve(hasSession: Bool, didResolveInitialSession: Bool) -> AuthPhase {
        if hasSession { return .signedIn }
        return didResolveInitialSession ? .signedOut : .restoring
    }
}

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var session: Session?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Non-error feedback, e.g. "account made, go confirm your email".
    @Published var noticeMessage: String?
    /// False until the auth stream has told us whether a stored session exists.
    @Published private(set) var didResolveInitialSession = false
    /// Every way into this account — email, Apple, Google. Loaded on demand by
    /// Settings; empty until then, so never read it as "nothing is linked".
    @Published private(set) var identities: [LinkedIdentity] = []

    private let client = SupabaseManager.shared.client

    var phase: AuthPhase {
        .resolve(hasSession: session != nil, didResolveInitialSession: didResolveInitialSession)
    }
    var isSignedIn: Bool { session != nil }
    var userEmail: String { session?.user.email ?? "" }

    init() {
        // The stored session is readable synchronously, so an already-signed-in
        // launch can render the tabs on the very first frame rather than
        // waiting for the stream to start. `currentSession` may be expired;
        // that is fine, the background refresh sorts it out and requests await
        // a valid token regardless.
        if ProcessInfo.processInfo.arguments.contains("-UITestForceSignOut") {
            // The sweep wants a signed-out start, and the sign-out below is a
            // network call — without this the tabs would show while it ran.
            didResolveInitialSession = true
        } else if let stored = client.auth.currentSession {
            session = stored
            didResolveInitialSession = true
        }
    }

    func listenForAuthChanges() async {
        // Deterministic signed-out start for the XCUITest sweep.
        if ProcessInfo.processInfo.arguments.contains("-UITestForceSignOut") {
            try? await client.auth.signOut()
        }
        // Widens the window this whole file exists to close. The stream
        // answering slowly is the real-world condition — a token refresh over
        // a bad connection — but it answers in milliseconds on a simulator,
        // which is faster than XCUITest can observe, so a test cannot see the
        // sign-in screen flash without it. Used by
        // testColdRelaunchWithStoredSessionNeverShowsAuthScreen.
        if ProcessInfo.processInfo.arguments.contains("-UITestSlowAuthRestore") {
            try? await Task.sleep(nanoseconds: 4 * NSEC_PER_SEC)
        }
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed:
                self.session = session
            case .signedOut, .userDeleted:
                self.session = nil
            default:
                break
            }
            didResolveInitialSession = true
        }
    }

    func signIn(email: String, password: String) async {
        await run {
            try await self.client.auth.signIn(email: email, password: password)
        }
    }

    func signUp(email: String, password: String) async {
        await run {
            let response = try await self.client.auth.signUp(email: email, password: password)
            // With email confirmation required, signUp creates the account but
            // returns no session — authStateChanges never fires, so without
            // this the user taps Create Account and the screen just sits there
            // with no error and no progress. Say what happened.
            if response.session == nil {
                self.noticeMessage = """
                    Account created. Check \(email) for a confirmation link, \
                    then come back and sign in.
                    """
            }
        }
    }

    // MARK: - Third-party sign-in

    /// Nonce for an in-flight `SignInWithAppleButton` request. Held between
    /// `onRequest` and `onCompletion`, which are two separate callbacks.
    private var pendingAppleNonce: String?

    /// `SignInWithAppleButton`'s `onRequest`. The sign-in screen uses Apple's
    /// own button rather than `signInWithApple()` below, because App Review
    /// expects that button's exact appearance and behaviour.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = AuthNonce.random()
        pendingAppleNonce = nonce
        AppleSignInService.configure(request, rawNonce: nonce)
    }

    /// `SignInWithAppleButton`'s `onCompletion`.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        let nonce = pendingAppleNonce
        pendingAppleNonce = nil
        await runIgnoringCancellation {
            guard let nonce else { throw AppleSignInService.Failure.missingIdentityToken }
            let authorization: ASAuthorization
            do {
                authorization = try result.get()
            } catch {
                // Turns a user backing out into .cancelled, which
                // runIgnoringCancellation then swallows.
                throw AppleSignInService.normalize(error)
            }
            let credential = try AppleSignInService.credential(
                from: authorization, rawNonce: nonce
            )
            try await self.client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken: credential.idToken,
                    nonce: credential.nonce
                )
            )
        }
    }

    /// Sign in (or sign up — Supabase creates the user on first sight of a
    /// provider identity) with Apple, presenting the sheet ourselves.
    func signInWithApple() async {
        await runIgnoringCancellation {
            let credential = try await AppleSignInService.authorize()
            try await self.client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken: credential.idToken,
                    nonce: credential.nonce
                )
            )
        }
    }

    func signInWithGoogle() async {
        await runIgnoringCancellation {
            let credential = try await GoogleSignInService.authorize()
            try await self.client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .google,
                    idToken: credential.idToken,
                    accessToken: credential.accessToken
                )
            )
        }
    }

    // MARK: - Linking providers to the account you are already in

    /// Reads `auth.identities` for the signed-in user.
    func loadIdentities() async {
        guard isSignedIn else { return }
        let rows = (try? await client.auth.userIdentities()) ?? []
        identities = rows.map {
            LinkedIdentity(provider: $0.provider, email: $0.identityData?["email"]?.stringValue)
        }
    }

    /// Attaches another provider to the *current* user rather than creating a
    /// second one. This is the only safe route for an account that already
    /// holds data: Apple's Hide My Email issues a relay address that will
    /// never match the account's email, so signing in with Apple cold would
    /// mint a fresh empty user instead.
    func link(_ provider: SocialProvider) async {
        await runIgnoringCancellation {
            switch provider {
            case .apple:
                let credential = try await AppleSignInService.authorize()
                try await self.client.auth.linkIdentityWithIdToken(
                    credentials: .init(
                        provider: .apple,
                        idToken: credential.idToken,
                        nonce: credential.nonce
                    )
                )
            case .google:
                let credential = try await GoogleSignInService.authorize()
                try await self.client.auth.linkIdentityWithIdToken(
                    credentials: .init(
                        provider: .google,
                        idToken: credential.idToken,
                        accessToken: credential.accessToken
                    )
                )
            }
            await self.loadIdentities()
        }
    }

    /// Detaches a provider. Refuses to remove the last one — that would leave
    /// an account with real bank history that nobody can ever sign into.
    func unlink(_ provider: SocialProvider) async {
        guard IdentityRules.canUnlink(provider, from: identities) else {
            errorMessage = "That's the only way into this account, so it can't be removed."
            return
        }
        await run {
            let rows = try await self.client.auth.userIdentities()
            guard let match = rows.first(where: { $0.provider == provider.key }) else { return }
            try await self.client.auth.unlinkIdentity(match)
            await self.loadIdentities()
        }
    }

    func signOut() async {
        await PushNotificationManager.shared.unregisterCurrentToken()
        try? await client.auth.signOut()
        session = nil
        identities = []
    }

    /// App Store 5.1.1(v): full server-side deletion via the delete_account RPC
    /// (cascades every public table), then local sign-out.
    func deleteAccount() async {
        await run {
            await PushNotificationManager.shared.unregisterCurrentToken()
            try await self.client.rpc("delete_account").execute()
            try? await self.client.auth.signOut()
            self.session = nil
        }
    }

    /// `run`, but a user backing out of a system sheet is not an error.
    ///
    /// Both providers report a cancel as a thrown error. Surfacing it paints
    /// the sign-in screen red for someone who simply changed their mind, and
    /// the message then sticks around behind the next attempt.
    private func runIgnoringCancellation(_ block: @escaping () async throws -> Void) async {
        await run(block)
        if errorMessage == AppleSignInService.Failure.cancelled.errorDescription
            || errorMessage == GoogleSignInService.Failure.cancelled.errorDescription {
            errorMessage = nil
        }
    }

    private func run(_ block: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        noticeMessage = nil
        defer { isLoading = false }
        do {
            try await block()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
