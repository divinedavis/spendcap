import Foundation
import UIKit
import UserNotifications
import Supabase

/// Requests notification permission, registers with APNs, and mirrors the
/// device token into device_push_tokens (self-only RLS). Skipped entirely
/// under UI-test launch flags so the permission alert can't block taps.
@MainActor
final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()

    private let client = SupabaseManager.shared.client
    private var currentToken: String?

    static var isUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestMode")
    }

    func requestAndRegister() async {
        guard !Self.isUITest else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        currentToken = token
        Task { await upload(token: token) }
    }

    private func upload(token: String) async {
        guard let userId = client.auth.currentUser?.id else { return }
        _ = try? await client
            .from("device_push_tokens")
            .upsert([
                "device_token": AnyJSON.string(token),
                "user_id": AnyJSON.string(userId.uuidString.lowercased()),
                "platform": AnyJSON.string("ios"),
                "updated_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
            ])
            .execute()
    }

    /// Called on sign-out / account deletion so a shared device can't keep
    /// receiving the previous user's alerts.
    func unregisterCurrentToken() async {
        guard let token = currentToken else { return }
        _ = try? await client
            .from("device_push_tokens")
            .delete()
            .eq("device_token", value: token)
            .execute()
        currentToken = nil
    }
}
