import SwiftUI
import LinkKit

/// Fetches a link token from the edge function, then presents Plaid Link.
/// The public token goes straight back to the exchange edge function — the
/// client never sees a Plaid access token.
struct PlaidLinkFlow: View {
    var onLinked: () -> Void
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
                    onSuccess: { publicToken, institution in
                        Task { await exchange(publicToken: publicToken, institution: institution) }
                    },
                    onExit: { dismiss() }
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
        do {
            linkToken = try await SpendService.shared.createLinkToken()
        } catch {
            errorMessage = "Couldn't start the bank connection. If this is a fresh install, Plaid keys may not be configured yet.\n\n\(error.localizedDescription)"
        }
    }

    private func exchange(publicToken: String, institution: String?) async {
        isExchanging = true
        do {
            try await SpendService.shared.exchangePublicToken(publicToken, institutionName: institution)
            onLinked()
            dismiss()
        } catch {
            isExchanging = false
            errorMessage = "Connected to your bank, but saving the connection failed: \(error.localizedDescription)"
        }
    }
}

/// Thin UIKit bridge for LinkKit's handler-based presentation.
private struct PlaidLinkController: UIViewControllerRepresentable {
    let linkToken: String
    let onSuccess: (_ publicToken: String, _ institutionName: String?) -> Void
    let onExit: () -> Void

    final class Coordinator {
        var handler: Handler?
        var didOpen = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        guard !context.coordinator.didOpen else { return }
        context.coordinator.didOpen = true

        var configuration = LinkTokenConfiguration(token: linkToken) { success in
            onSuccess(success.publicToken, success.metadata.institution.name)
        }
        configuration.onExit = { _ in onExit() }

        switch Plaid.create(configuration) {
        case .success(let handler):
            context.coordinator.handler = handler
            handler.open(presentUsing: .viewController(viewController))
        case .failure:
            onExit()
        }
    }
}
