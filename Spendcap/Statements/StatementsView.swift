import SwiftUI
import QuickLook

/// The past year of bank statements, newest first.
///
/// Statements are a separate Plaid consent from transactions, so a first visit
/// usually has nothing to show and the job of this screen is to explain why and
/// offer the approval — not to look broken.
struct StatementsView: View {
    @State private var statements: [BankStatement] = []
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var needsConsent = false
    @State private var errorMessage: String?
    @State private var showingConsentFlow = false
    @State private var previewURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        List {
            if needsConsent {
                consentSection
            }

            if !statements.isEmpty {
                Section {
                    ForEach(statements) { statement in
                        row(for: statement)
                    }
                } header: {
                    Text("Past year")
                } footer: {
                    if let statusMessage {
                        Text(statusMessage)
                    }
                }
            } else if !isLoading && !needsConsent {
                Section {
                    ContentUnavailableView(
                        "No statements yet",
                        systemImage: "doc.text",
                        description: Text("Pull down to fetch them from your bank.")
                    )
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("Statements")
        .toolbar {
            if !needsConsent {
                Button {
                    Task { await sync() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isSyncing)
                .accessibilityIdentifier("statements.refresh")
            }
        }
        .refreshable { await sync() }
        .task { await load() }
        .sheet(isPresented: $showingConsentFlow) {
            PlaidLinkFlow(mode: .statementsConsent) {
                needsConsent = false
                Task { await load() }
            }
        }
        .quickLookPreview($previewURL)
    }

    private var consentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Approve statements")
                    .font(.headline)
                Text("Your bank shares transactions with Spendcap, but statements need their own approval. This reuses your existing connection — it won't add a second bank.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Approve with your bank") {
                    showingConsentFlow = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("statements.approve")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func row(for statement: BankStatement) -> some View {
        Button {
            Task { await open(statement) }
        } label: {
            HStack {
                Image(systemName: statement.isAvailable ? "doc.text.fill" : "doc.text")
                    .foregroundStyle(statement.isAvailable ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statement.periodLabel)
                        .foregroundStyle(.primary)
                    if let sizeLabel = statement.sizeLabel, statement.isAvailable {
                        Text(sizeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !statement.isAvailable {
                        Text("Couldn't download — pull to retry")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if statement.isAvailable {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(!statement.isAvailable)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            statements = try await SpendService.shared.statements()
            // Nothing stored yet is the normal first-run state, and the most
            // likely reason is the missing consent — so probe for it rather
            // than leaving the user on an empty list with no next step.
            if statements.isEmpty { await sync() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        errorMessage = nil
        do {
            let ack = try await SpendService.shared.syncStatements()
            needsConsent = false
            statements = try await SpendService.shared.statements()
            statusMessage = ack.capped
                ? "Showing the most recent \(ack.downloaded). Pull down again for older ones."
                : nil
        } catch SpendService.StatementsError.consentRequired {
            needsConsent = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ statement: BankStatement) async {
        do {
            // Signed URLs are short-lived, so mint one per tap rather than
            // caching a link that would quietly rot.
            previewURL = try await SpendService.shared.statementURL(statement)
        } catch {
            errorMessage = "Couldn't open that statement: \(error.localizedDescription)"
        }
    }
}
