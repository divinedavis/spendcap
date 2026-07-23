import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushNotificationManager.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulator or denied permission — nothing to do; alerts still show in-app.
    }
}

@main
struct SpendcapApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var auth = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .task { await auth.listenForAuthChanges() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if auth.isSignedIn {
                MainTabView()
            } else {
                AuthView()
            }
        }
        .animation(.default, value: auth.isSignedIn)
        // Privacy: cover bank balances / transactions in the app-switcher
        // snapshot whenever the scene isn't active (backgrounded or inactive).
        .overlay {
            if scenePhase != .active {
                PrivacyRedactionView()
            }
        }
    }
}

/// Opaque cover shown over the app whenever the scene leaves the active state.
/// iOS snapshots the front-most view for the app-switcher when the app
/// backgrounds; this ensures that snapshot never captures the user's balances,
/// transactions, or daily-cap figures.
struct PrivacyRedactionView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Spendcap")
                    .font(.title.weight(.bold))
            }
        }
        .accessibilityIdentifier("privacyRedaction")
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "gauge.with.needle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            await SpendService.shared.syncTimezone()
            await PushNotificationManager.shared.requestAndRegister()
        }
    }
}
