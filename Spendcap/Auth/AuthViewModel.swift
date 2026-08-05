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

    func signOut() async {
        await PushNotificationManager.shared.unregisterCurrentToken()
        try? await client.auth.signOut()
        session = nil
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
