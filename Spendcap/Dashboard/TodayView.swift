import SwiftUI

@MainActor
final class TodayViewModel: ObservableObject {
    @Published var transactions: [BankTransaction] = []
    @Published var budget = Budget(dailyLimitCents: 5000, warnPct: 80)
    @Published var items: [PlaidItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var spentCents: Int {
        transactions.filter(\.countsTowardDailyCap).reduce(0) { $0 + $1.amountCents }
    }

    /// Whether any of today's rows are excluded from the ring, so the list can
    /// explain the gap instead of leaving it as an apparent bug.
    var hasUncountedBackfill: Bool {
        transactions.contains { $0.pending && $0.isBackfill && !$0.isRemoved }
    }

    var status: SpendStatus {
        BudgetMath.status(spentCents: spentCents, limitCents: budget.dailyLimitCents, warnPct: budget.warnPct)
    }

    var hasBank: Bool { items.contains { $0.status == "active" } }

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

struct TodayView: View {
    @StateObject private var model = TodayViewModel()
    @State private var showingLink = false
    @State private var showingBudget = false

    private var ringColor: Color {
        switch model.status {
        case .under: return .green
        case .warn: return .orange
        case .over: return .red
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    spendRing
                        .padding(.top, 12)

                    statusLine

                    if !model.hasBank {
                        connectCard
                    }

                    transactionsList
                }
                .padding(.horizontal)
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingBudget = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("today.editBudget")
                }
            }
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

    private var spendRing: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 18)
            Circle()
                .trim(from: 0, to: BudgetMath.progress(
                    spentCents: model.spentCents,
                    limitCents: model.budget.dailyLimitCents))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: model.spentCents)
            VStack(spacing: 4) {
                Text(BudgetMath.dollars(model.spentCents))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("today.spent")
                Text("of \(BudgetMath.dollars(model.budget.dailyLimitCents)) cap")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 220, height: 220)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spent \(BudgetMath.dollars(model.spentCents)) of \(BudgetMath.dollars(model.budget.dailyLimitCents)) daily cap")
    }

    private var statusLine: some View {
        Group {
            switch model.status {
            case .under:
                let remaining = BudgetMath.remainingCents(
                    spentCents: model.spentCents, limitCents: model.budget.dailyLimitCents)
                Label("\(BudgetMath.dollars(remaining)) left today", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warn:
                Label("Getting close to your cap", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .over:
                let over = model.spentCents - model.budget.dailyLimitCents
                Label("\(BudgetMath.dollars(over)) over your cap", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .font(.headline)
        .accessibilityIdentifier("today.status")
    }

    private var connectCard: some View {
        VStack(spacing: 12) {
            Text("Connect your bank")
                .font(.headline)
            Text("Spendcap uses Plaid to securely read your transactions. Credentials are never shared with us.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingLink = true
            } label: {
                Label("Connect with Plaid", systemImage: "building.columns")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("today.connectBank")
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var transactionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.transactions.isEmpty {
                Text("Today's transactions")
                    .font(.headline)
                if model.hasUncountedBackfill {
                    Text("Charges your bank hadn't posted when you connected don't count toward today — they'll count on the day they actually happened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.hasBank {
                Text("No transactions yet today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }

            ForEach(model.transactions) { txn in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(txn.displayName)
                            .font(.body)
                            .lineLimit(1)
                        if let category = txn.category {
                            Text(category.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(BudgetMath.dollars(abs(txn.amountCents)))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(txn.amountCents > 0 ? Color.primary : Color.green)
                        // A row excluded from the ring has to say so. Otherwise
                        // the list reads as $400 of charges under a $0 total
                        // and the app just looks broken.
                        if txn.pending && txn.isBackfill {
                            Text("Not counted")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if txn.pending {
                            Text("Pending")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
    }
}
