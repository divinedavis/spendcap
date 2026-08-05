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
    @StateObject private var linkStore = PlaidLinkStore.shared

    var body: some View {
        Group {
            switch auth.phase {
            case .restoring:
                LaunchPlaceholderView()
            case .signedIn:
                MainTabView()
            case .signedOut:
                AuthView()
            }
        }
        .animation(.default, value: auth.phase)
        // Plaid OAuth banks redirect back to divinedavis.com/spendcap/oauth/.
        // Universal links arrive as a browsing user activity on a warm launch
        // and via onOpenURL in some cold-launch paths, so handle both. Links
        // that aren't ours are ignored — Hidden Gems shares the same domain.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { linkStore.handle(url: url) }
        }
        .onOpenURL { url in
            linkStore.handle(url: url)
        }
        .sheet(isPresented: Binding(
            get: { linkStore.pendingRedirect != nil },
            set: { if !$0 { linkStore.clear() } }
        )) {
            if let redirect = linkStore.pendingRedirect {
                PlaidLinkFlow(onLinked: {}, resumeFrom: redirect)
            }
        }
        // Privacy: cover bank balances / transactions in the app-switcher
        // snapshot whenever the scene isn't active (backgrounded or inactive).
        .overlay {
            if scenePhase != .active {
                PrivacyRedactionView()
            }
        }
    }
}

/// Held on screen for the moment between the app appearing and the auth stream
/// saying whether a session is stored.
///
/// It is deliberately identical to the launch screen — plain system background,
/// no spinner and no branding — so a signed-in cold start reads as the launch
/// screen simply staying up a beat longer. Anything drawn here would flash
/// instead, which is the bug this exists to fix.
struct LaunchPlaceholderView: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .accessibilityIdentifier("launchPlaceholder")
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
            // Trends takes the landing slot Home held: a month's shape is a
            // more useful opening question than a day's remainder, which was
            // always a partial figure anyway.
            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.bar.fill") }

            ActivityView()
                .tabItem { Label("Activity", systemImage: "list.bullet") }

            // Months replaced the Today ring: bank data settles over days, so a
            // live "spent today" figure was always a partial one. Month totals
            // are the number that can be trusted. The daily cap still drives
            // the pushes.
            MonthsView()
                .tabItem { Label("Months", systemImage: "calendar") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            await SpendService.shared.syncTimezone()
            await PushNotificationManager.shared.requestAndRegister()
        }
    }
}
