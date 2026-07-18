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
            supabaseKey: Secrets.supabaseAnonKey
        )
    }
}
