import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var items: [PlaidItem] = []
    @State private var showingDeleteConfirm = false
    @State private var showingLink = false
    @State private var showingTrips = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Email", value: auth.userEmail)

                    ForEach(auth.identities, id: \.provider) { identity in
                        HStack {
                            Text(identity.socialProvider?.displayName
                                 ?? identity.provider.capitalized)
                            Spacer()
                            if let email = identity.email, email != auth.userEmail {
                                Text(email)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .accessibilityIdentifier("settings.identity.\(identity.provider)")
                        .swipeActions {
                            if let provider = identity.socialProvider,
                               IdentityRules.canUnlink(provider, from: auth.identities) {
                                Button("Unlink", role: .destructive) {
                                    Task { await auth.unlink(provider) }
                                }
                            }
                        }
                    }

                    ForEach(IdentityRules.linkable(from: auth.identities)) { provider in
                        if provider != .google || GoogleSignInService.isConfigured {
                            Button {
                                Task { await auth.link(provider) }
                            } label: {
                                Label("Link \(provider.displayName)",
                                      systemImage: "link")
                            }
                            .accessibilityIdentifier("settings.link.\(provider.key)")
                        }
                    }
                } header: {
                    Text("Account")
                } footer: {
                    // The reason this screen exists rather than leaving people
                    // to sign in with whichever provider they like.
                    Text("Linking adds another way to sign in to this same account. Signing in with a provider you haven't linked — especially Apple with Hide My Email — creates a separate, empty account.")
                }

                Section {
                    if items.isEmpty {
                        Text("No banks connected")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack {
                            Text(item.institutionName ?? "Bank")
                            Spacer()
                            if item.status != "active" {
                                Text(item.status.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        Task { await disconnect(indexSet) }
                    }

                    // The only way into Plaid Link now that Home is gone.
                    Button {
                        showingLink = true
                    } label: {
                        Label(items.isEmpty ? "Connect a bank" : "Connect another bank",
                              systemImage: "building.columns")
                    }
                    .accessibilityIdentifier("settings.addBank")
                } header: {
                    Text("Connected banks")
                } footer: {
                    Text("Spendcap reads transactions through Plaid. Your bank credentials are never shared with the app.")
                }

                Section("Budget") {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Budget by category", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("settings.categories")

                    // Trips lost its tab to Debt on 2026-08-18 and lives here
                    // now — same screen, one tap deeper. A sheet, not a push:
                    // Trips owns a NavigationStack of its own and nesting it
                    // inside this one stacks two navigation bars.
                    Button {
                        showingTrips = true
                    } label: {
                        Label("Trips and events", systemImage: "airplane")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("settings.trips")
                }

                Section("Documents") {
                    NavigationLink {
                        StatementsView()
                    } label: {
                        Label("Statements", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("settings.statements")
                }

                Section {
                    Button("Sign Out") {
                        Task { await auth.signOut() }
                    }
                    .accessibilityIdentifier("settings.signOut")

                    Button("Delete Account", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                    .accessibilityIdentifier("settings.deleteAccount")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                        VStack(spacing: 8) {
                            SpendcapIcon(size: 52)
                            Text("Spendcap")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationTitle("Settings")
            .task { await load() }
            .confirmationDialog(
                "Delete your account? This permanently removes your bank connections, transactions, and budget.",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task { await auth.deleteAccount() }
                }
            }
            .sheet(isPresented: $showingLink) {
                PlaidLinkFlow { Task { await load() } }
            }
            .sheet(isPresented: $showingTrips) {
                TripsView(isModal: true)
            }
        }
    }

    private func load() async {
        items = (try? await SpendService.shared.plaidItems()) ?? []
        await auth.loadIdentities()
    }

    private func disconnect(_ indexSet: IndexSet) async {
        for index in indexSet {
            do {
                try await SpendService.shared.disconnectItem(items[index].id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await load()
    }
}
