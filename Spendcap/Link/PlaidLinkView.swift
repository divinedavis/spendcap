import SwiftUI
import LinkKit

/// Fetches a link token from the edge function, then presents Plaid Link.
/// The public token goes straight back to the exchange edge function — the
/// client never sees a Plaid access token.
struct PlaidLinkFlow: View {
    var onLinked: () -> Void
    /// Set when re-entering after an OAuth bank redirected back to us. Reuses
    /// the stored link token instead of minting a new one — Plaid requires the
    /// resumed handler to carry the *same* token the flow started with.
    var resumeFrom: URL?

    // LinkKit exports its own `Environment` type, so qualify SwiftUI's.
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var linkToken: String?
    @State private var errorMessage: String?
    @State private var isExchanging = false

    var body: some View {
        Group {
            if isExchanging {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting your bank…")
                        .foregroundStyle(.secondary)
                }
            } else if let token = linkToken {
                PlaidLinkController(
                    linkToken: token,
                    resumeFrom: resumeFrom,
                    onSuccess: { publicToken, institution in
                        Task { await exchange(publicToken: publicToken, institution: institution) }
                    },
                    onExit: {
                        PlaidLinkStore.shared.clear()
                        dismiss()
                    }
                )
                .ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Close") { dismiss() }
                }
            } else {
                ProgressView("Preparing secure connection…")
                    .task { await fetchToken() }
            }
        }
    }

    private func fetchToken() async {
        // Resuming an OAuth hand-off must reuse the original token; a new one
        // would not match the session the bank just approved.
        if resumeFrom != nil, let saved = PlaidLinkStore.shared.savedToken {
            linkToken = saved
            return
        }
        do {
            let token = try await SpendService.shared.createLinkToken()
            PlaidLinkStore.shared.remember(token: token)
            linkToken = token
        } catch {
            errorMessage = "Couldn't start the bank connection. If this is a fresh install, Plaid keys may not be configured yet.\n\n\(error.localizedDescription)"
        }
    }

    private func exchange(publicToken: String, institution: String?) async {
        isExchanging = true
        do {
            try await SpendService.shared.exchangePublicToken(publicToken, institutionName: institution)
            PlaidLinkStore.shared.clear()
            onLinked()
            dismiss()
        } catch {
            isExchanging = false
            errorMessage = "Connected to your bank, but saving the connection failed: \(error.localizedDescription)"
        }
    }
}

/// Thin UIKit bridge for LinkKit's handler-based presentation.
/// Link must be opened from viewDidAppear — presenting from a controller
/// that isn't in the window hierarchy yet fails silently, leaving a blank
/// sheet.
private struct PlaidLinkController: UIViewControllerRepresentable {
    let linkToken: String
    var resumeFrom: URL?
    let onSuccess: (_ publicToken: String, _ institutionName: String?) -> Void
    let onExit: () -> Void

    final class ContainerViewController: UIViewController {
        var handler: Handler?
        var resumeFrom: URL?
        var onFailure: (() -> Void)?
        private var didOpen = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !didOpen else { return }
            didOpen = true
            guard let handler else {
                onFailure?()
                return
            }
            // Hand the bank's redirect back to LinkKit before opening, so it
            // picks the flow up mid-OAuth instead of restarting it. Only needed
            // when iOS terminated us during the hand-off; if the app stayed
            // alive LinkKit resumes on its own.
            if let resumeFrom {
                handler.resumeAfterTermination(from: resumeFrom)
            }
            handler.open(presentUsing: .viewController(self))
        }
    }

    func makeUIViewController(context: Context) -> ContainerViewController {
        let container = ContainerViewController()
        container.view.backgroundColor = .systemBackground
        container.onFailure = onExit
        container.resumeFrom = resumeFrom

        var configuration = LinkTokenConfiguration(token: linkToken) { success in
            onSuccess(success.publicToken, success.metadata.institution.name)
        }
        configuration.onExit = { _ in onExit() }

        if case .success(let handler) = Plaid.create(configuration) {
            container.handler = handler
        }
        return container
    }

    func updateUIViewController(_ viewController: ContainerViewController, context: Context) {}
}
