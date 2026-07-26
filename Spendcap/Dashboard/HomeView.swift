import SwiftUI

// Home template, modelled on Monzo's home screen:
//   announcement strip → coloured account card → Activity list → Suggested actions
//
// Label mapping (first pass — adjust freely):
//   Monzo "Balance"        -> "Left today"      (cap minus today's spend)
//   Monzo account name     -> connected institution
//   Monzo "Add money"/"Card" -> "Adjust cap" / "Add bank"
//   Monzo Activity         -> today's transactions
//   Monzo Suggested actions-> contextual nudges

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var transactions: [BankTransaction] = []
    @Published var budget = Budget(dailyLimitCents: 5000, warnPct: 80)
    @Published var items: [PlaidItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var spentCents: Int {
        transactions.filter { $0.amountCents > 0 }.reduce(0) { $0 + $1.amountCents }
    }

    var remainingCents: Int {
        BudgetMath.remainingCents(spentCents: spentCents, limitCents: budget.dailyLimitCents)
    }

    var status: SpendStatus {
        BudgetMath.status(spentCents: spentCents,
                          limitCents: budget.dailyLimitCents,
                          warnPct: budget.warnPct)
    }

    var hasBank: Bool { items.contains { $0.status == "active" } }

    var institutionName: String {
        items.first(where: { $0.status == "active" })?.institutionName ?? "No bank connected"
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let txns = SpendService.shared.todayTransactions()
            async let budg = SpendService.shared.budget()
            async let itms = SpendService.shared.plaidItems()
            let (t, b, i) = try await (txns, budg, itms)
            transactions = t
            budget = b
            items = i
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @State private var showingLink = false
    @State private var showingBudget = false
    @State private var showAnnouncement = true

    /// Hero card colour tracks cap status, so the screen reads at a glance.
    private var heroColor: Color {
        switch model.status {
        case .under: return Color(red: 0.13, green: 0.63, blue: 0.36)
        case .warn:  return Color(red: 0.90, green: 0.55, blue: 0.09)
        case .over:  return Color(red: 0.89, green: 0.26, blue: 0.20)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DashboardBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        if showAnnouncement {
                            AnnouncementCard(
                                icon: "sparkles",
                                tint: .blue,
                                title: "Your cap, at a glance",
                                message: "Home now leads with what's left today.",
                                onDismiss: { withAnimation { showAnnouncement = false } }
                            )
                        }

                        heroCard

                        activityCard

                        suggestedActions
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(isPresented: $showingLink) {
                PlaidLinkFlow { Task { await model.load() } }
            }
            .sheet(isPresented: $showingBudget) {
                BudgetView(budget: model.budget) { updated in
                    model.budget = updated
                    Task { await model.load() }
                }
            }
        }
    }

    // MARK: - Hero card (Monzo's coloured account card)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spendcap")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(BudgetMath.dollars(max(0, model.remainingCents)))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("home.remaining")
            }

            HStack(alignment: .firstTextBaseline) {
                Label(model.institutionName, systemImage: "building.columns.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                Text(model.status == .over ? "Over cap" : "Left today")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 10) {
                HeroPillButton(title: "Adjust cap") { showingBudget = true }
                    .accessibilityIdentifier("home.adjustCap")
                HeroPillButton(title: model.hasBank ? "Banks" : "Add bank") { showingLink = true }
                    .accessibilityIdentifier("home.addBank")
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroColor, in: RoundedRectangle(cornerRadius: 18))
        .animation(.easeOut(duration: 0.3), value: model.status)
    }

    // MARK: - Activity

    private var activityCard: some View {
        SurfaceCard {
            SectionHeader(title: "Activity") {}

            if model.transactions.isEmpty {
                Text(model.hasBank ? "Nothing spent yet today." : "Connect a bank to see activity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(model.transactions.prefix(4).enumerated()), id: \.element.id) { index, txn in
                    DashboardRow(
                        icon: icon(for: txn),
                        tint: txn.amountCents > 0 ? .primary.opacity(0.7) : .green,
                        title: txn.displayName,
                        subtitle: txn.category?
                            .replacingOccurrences(of: "_", with: " ")
                            .capitalized,
                        value: (txn.amountCents > 0 ? "" : "+")
                            + BudgetMath.dollars(abs(txn.amountCents)),
                        valueColor: txn.amountCents > 0 ? .primary : .green,
                        valueCaption: txn.pending ? "Pending" : nil
                    )
                    if index < min(4, model.transactions.count) - 1 {
                        Divider()
                    }
                }

                if model.transactions.count > 4 {
                    Button("See all") {}
                        .font(.body.weight(.medium))
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Rough category → glyph mapping; extend as categories firm up.
    private func icon(for txn: BankTransaction) -> String {
        guard txn.amountCents > 0 else { return "arrow.down.left" }
        switch txn.category?.lowercased() {
        case let c? where c.contains("food") || c.contains("restaurant"): return "fork.knife"
        case let c? where c.contains("transport") || c.contains("travel"): return "car.fill"
        case let c? where c.contains("shop") || c.contains("merchandise"): return "bag.fill"
        case let c? where c.contains("entertain"): return "music.note"
        case let c? where c.contains("service") || c.contains("utilit"): return "bolt.fill"
        default: return "creditcard.fill"
        }
    }

    // MARK: - Suggested actions

    private var suggestedActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested actions")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 2)

            // A horizontal ScrollView renders reliably here because it's inside
            // the outer vertical ScrollView with an explicit height.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if !model.hasBank {
                        SuggestionCard(
                            icon: "building.columns.fill",
                            tint: .blue,
                            title: "Connect a bank",
                            message: "Spendcap needs a linked account to track the day."
                        ) { showingLink = true }
                    }
                    SuggestionCard(
                        icon: "slider.horizontal.3",
                        tint: .purple,
                        title: "Tune your cap",
                        message: "Currently \(BudgetMath.dollars(model.budget.dailyLimitCents)) a day."
                    ) { showingBudget = true }
                    SuggestionCard(
                        icon: "bell.badge.fill",
                        tint: .orange,
                        title: "Check alerts",
                        message: "Warned at \(model.budget.warnPct)% of your cap."
                    ) { showingBudget = true }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 168)
        }
    }
}
