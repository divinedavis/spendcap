import SwiftUI

// Activity: this month's transactions, newest first, grouped by day.
//
// The screen a bank app opens on. It answers "what did I actually spend" with
// no interpretation layered on top — every row is a thing that happened, in the
// order it happened, with the budget line it landed in so the categorisation is
// visible where it can be checked rather than only where it is summed.

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var days: [ActivityDay] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var outflowCents: Int { days.reduce(0) { $0 + $1.outflowCents } }

    var count: Int { days.reduce(0) { $0 + $1.rows.count } }

    /// Rows the bank has not settled yet — their amounts can still change.
    var pendingCount: Int {
        days.reduce(0) { $0 + $1.rows.filter { $0.transaction.pending }.count }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            days = ActivityMath.days(rows: try await SpendService.shared.monthActivity())
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
        }
    }
}

struct ActivityView: View {
    @StateObject private var model = ActivityViewModel()

    private var monthLabel: String {
        Date().formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Spent") {
                        Text(BudgetMath.wholeDollars(model.outflowCents))
                            .font(.body.weight(.semibold).monospacedDigit())
                            .accessibilityIdentifier("activity.total")
                    }
                    LabeledContent("Transactions", value: "\(model.count)")
                    if model.pendingCount > 0 {
                        LabeledContent("Still pending") {
                            Text("\(model.pendingCount)").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(monthLabel)
                } footer: {
                    if model.pendingCount > 0 {
                        Text("Pending amounts can change before they post, so this month's total is not final.")
                    }
                }

                ForEach(model.days) { day in
                    Section {
                        ForEach(day.rows) { row in
                            NavigationLink {
                                TransactionDetailView(
                                    transaction: row.transaction,
                                    lineName: row.categoryName ?? "Money in"
                                ) {
                                    Task { await model.load() }
                                }
                            } label: {
                                activityRow(row)
                            }
                            .accessibilityIdentifier("activity.row")
                        }
                    } header: {
                        HStack {
                            Text(day.label)
                            Spacer()
                            if day.outflowCents > 0 {
                                Text(BudgetMath.dollars(day.outflowCents))
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                if model.days.isEmpty && !model.isLoading {
                    Section {
                        ContentUnavailableView(
                            "Nothing yet this month",
                            systemImage: "list.bullet",
                            description: Text("Transactions appear here as your bank reports them.")
                        )
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task { await model.load() }
        }
    }

    private func activityRow(_ row: ActivityRow) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.transaction.displayName)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let line = row.categoryName {
                        Text(line)
                    } else {
                        Text("Money in")
                    }
                    if row.transaction.pending {
                        Text("\u{00B7} Pending")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text((row.isInflow ? "+" : "") + BudgetMath.dollars(abs(row.transaction.amountCents)))
                .font(.body.monospacedDigit())
                .foregroundStyle(row.isInflow ? Color.green : Color.primary)
        }
    }
}
