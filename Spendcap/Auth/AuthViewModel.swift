import Foundation
import Supabase

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var session: Session?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Non-error feedback, e.g. "account made, go confirm your email".
    @Published var noticeMessage: String?

    private let client = SupabaseManager.shared.client

    var isSignedIn: Bool { session != nil }
    var userEmail: String { session?.user.email ?? "" }

    func listenForAuthChanges() async {
        // Deterministic signed-out start for the XCUITest sweep.
        if ProcessInfo.processInfo.arguments.contains("-UITestForceSignOut") {
            try? await client.auth.signOut()
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
