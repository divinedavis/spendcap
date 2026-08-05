import Foundation
import Supabase

enum Secrets {
    private static func plist(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    static var supabaseURL: URL {
        URL(string: "https://\(plist("SUPABASE_HOST"))")!
    }

    static var supabaseAnonKey: String {
        plist("SUPABASE_ANON_KEY")
    }
}

final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: Secrets.supabaseURL,
            supabaseKey: Secrets.supabaseAnonKey,
            options: SupabaseClientOptions(
                // Emit the stored session as `.initialSession` straight away
                // instead of refreshing it over the network first. Access
                // tokens last an hour, so on nearly every cold start the
                // legacy path spent a full round trip to /token before the
                // app was told it had a session — and until it was told, the
                // app rendered the sign-in screen. The refresh still happens,
                // just in the background, and every request waits on a valid
                // token anyway (`_getAccessToken` awaits `auth.session`).
                // A session the server has actually killed still lands the
                // user back on sign-in: the refresh's session-cleanup error
                // emits `.signedOut`.
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
    }
}
