import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var items: [PlaidItem] = []
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Email", value: auth.userEmail)
                }

                Section("Connected banks") {
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
                }

                Section("Budget") {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Budget by category", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("settings.categories")
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
                        Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
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
        }
    }

    private func load() async {
        items = (try? await SpendService.shared.plaidItems()) ?? []
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
