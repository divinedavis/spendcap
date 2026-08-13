import SwiftUI
import Charts

// Trends template, modelled on Monzo's Trends screen:
//   account chip + period chip → segmented modes → chart card → prompt → Breakdown
//
// Label mapping (first pass — adjust freely):
//   Monzo "Balance/Spending" -> Spending / Daily
//   Monzo "Today's Balance"  -> month-to-date spend
//   Monzo balance line       -> cumulative spend
//   Monzo "Breakdown"        -> month cap, spent, left, average, days over
//
// A third "Target" mode (cumulative spend against a straight cap-pace line) was
// removed 2026-08-08. It drew the daily cap × day index, which stopped being the
// yardstick this screen is judged by once the monthly cap arrived in 0006 — the
// pace line and the Breakdown's "Cap for <month>" could disagree on the same
// card. Spending already shows the same cumulative curve.

enum TrendsMode: String, CaseIterable, Identifiable {
    case spending = "Spending"
    case daily = "Daily"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .spending: return "chart.line.uptrend.xyaxis"
        case .daily: return "chart.bar.fill"
        }
    }
}

@MainActor
final class TrendsViewModel: ObservableObject {
    @Published var stats = MonthStats(series: [], spentCents: 0, daysElapsed: 0,
                                      daysInMonth: 0, dailyLimitCents: 5000)
    /// This month and last, by budget line — the same rollup the Budget screen
    /// uses, shown under the chart. Moved here from Months 2026-08-12.
    @Published var categoryMonths: [CategoryMonth] = []
    @Published var selectedCategoryPeriod: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?

    var selectedCategoryMonth: CategoryMonth? {
        categoryMonths.first { $0.period == selectedCategoryPeriod } ?? categoryMonths.first
    }

    /// True once loaded and anything beyond the Uncategorized line came back,
    /// i.e. a budget has actually been set up.
    var hasCategoryBudget: Bool {
        categoryMonths.contains { month in month.rows.contains { !$0.isUncategorized } }
    }

    /// Seed the first frame from the last successful load, so opening the app
    /// shows the numbers as of the last visit instead of $0.00 that jumps
    /// when the network answers. The snapshot is raw rows, re-derived through
    /// the same math as a live load; the network refresh then lands quietly —
    /// on identical numbers unless something actually changed.
    init() {
        guard let snapshot = TrendsSnapshotStore.load(),
              snapshot.isUsable(for: SpendService.shared.currentUserId)
        else { return }
        apply(transactions: snapshot.transactions, budget: snapshot.budget,
              reference: Date())
        apply(categoryRows: snapshot.categoryRows, wireDiscretionary: true)
    }

    func load(period: TrendsPeriod = .thisMonth) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var loaded: (transactions: [BankTransaction], budget: Budget)?
        do {
            // One reference date drives the fetch and the math, so the rows
            // pulled and the days charted can never describe different months.
            let reference = period.referenceDate()
            async let txns = SpendService.shared.monthTransactions(now: reference)
            async let budg = SpendService.shared.budget()
            let (t, b) = try await (txns, budg)
            apply(transactions: t, budget: b, reference: reference)
            loaded = (t, b)
        } catch {
            errorMessage = error.localizedDescription
        }

        // Budget lines are a second read of the same months; a failure here
        // must not blank the chart above them. Always this month and last —
        // the card has its own picker and does not follow the period chip.
        let rows = try? await SpendService.shared.categorySpend(monthsBack: 2)
        if let rows {
            apply(categoryRows: rows, wireDiscretionary: period.isCurrent)
        }

        // Persist what the next cold launch should open on: the current
        // month, fully loaded. A partial load must not overwrite a complete
        // snapshot from an earlier visit.
        if period.isCurrent, let loaded, let rows,
           let userId = SpendService.shared.currentUserId {
            TrendsSnapshotStore.save(TrendsSnapshot(
                userId: userId, savedAt: Date(),
                transactions: loaded.transactions, budget: loaded.budget,
                categoryRows: rows))
        }
    }

    /// Both caps: the daily one colours the per-day bars, the monthly one
    /// (when set) is what the month is judged against — Months uses the same
    /// resolution, and the two screens must not disagree.
    private func apply(transactions: [BankTransaction], budget: Budget, reference: Date) {
        stats = MonthMath.stats(
            transactions: transactions,
            dailyLimitCents: budget.dailyLimitCents,
            monthlyLimitCents: budget.monthlyLimitCents,
            now: reference
        )
    }

    /// The discretionary budget feeds the chart card's free-to-spend figure —
    /// current month only, which is the only month that has money left. When
    /// the rollup is missing the fields stay zero, which hides the figure
    /// rather than showing a wrong one.
    private func apply(categoryRows: [CategorySpendRow], wireDiscretionary: Bool) {
        categoryMonths = CategoryMath.months(rows: categoryRows)
        if selectedCategoryPeriod == nil
            || !categoryMonths.contains(where: { $0.period == selectedCategoryPeriod }) {
            selectedCategoryPeriod = categoryMonths.first?.period
        }
        if wireDiscretionary, let current = categoryMonths.first(where: \.isCurrent) {
            stats.discretionaryPlannedCents = current.discretionaryPlannedCents
            stats.discretionarySpentCents = current.discretionarySpentCents
        }
    }
}

struct TrendsView: View {
    @StateObject private var model = TrendsViewModel()
    @State private var mode: TrendsMode = .spending
    @State private var period: TrendsPeriod = .thisMonth
    @State private var editingLine: CategorySpendRow?

    private var monthLabel: String {
        period.monthName()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DashboardBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        chips
                        modePicker
                        chartCard
                        categoryBudgetCard
                    }
                    .padding(.horizontal, 16)
                    // The chips row used to sit flush against the navigation
                    // bar, whose scroll-edge effect on iOS 26 reaches into the
                    // top of the scroll content and swallows touches there.
                    // Nothing up here was interactive before the period menu,
                    // so nothing had caught it. 12pt cleared it only sometimes
                    // — the menu still went unhittable across runs — so this
                    // is deliberately more margin than it looks like it needs.
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load(period: period) }
            .task { await model.load(period: period) }
            .onChange(of: period) { _, newValue in
                Task { await model.load(period: newValue) }
            }
            .sheet(item: $editingLine) { row in
                CategoryEditView(row: row) {
                    Task { await model.load(period: period) }
                }
            }
        }
    }

    // MARK: - Chips (account + period)

    private var chips: some View {
        HStack(spacing: 10) {
            Label("All accounts", systemImage: "person.crop.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemBackground), in: Capsule())

            Spacer()

            // Three months, not twelve: Months already owns the year, and the
            // bank rarely shares much more history than this anyway.
            Menu {
                ForEach(TrendsPeriod.allCases) { option in
                    Button {
                        period = option
                    } label: {
                        if option == period {
                            Label(option.label(), systemImage: "checkmark")
                        } else {
                            Text(option.label())
                        }
                    }
                }
            } label: {
                Label(period.label(), systemImage: "line.3.horizontal.decrease")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground), in: Capsule())
            }
            .accessibilityIdentifier("trends.period")
        }
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(TrendsMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("trends.mode")
    }

    // MARK: - Chart

    private var chartCard: some View {
        SurfaceCard {
            HStack(alignment: .top) {
                Text(period.label())
                    .font(.title3.weight(.bold))
                    .accessibilityIdentifier("trends.periodTitle")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(BudgetMath.dollars(model.stats.spentCents))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .accessibilityIdentifier("trends.monthSpend")
                    // What remains of the discretionary budget — the untagged
                    // budget lines, everything committed (rent, debts, hair,
                    // transport, savings) fenced off — spread over the
                    // month's four weeks. The label names the answer, not the
                    // formula. Only the month in progress, and only once a
                    // budget exists: zero-planned means the rollup hasn't
                    // loaded or there is nothing to measure against.
                    if period.isCurrent && model.stats.discretionaryPlannedCents > 0 {
                        Text("\(BudgetMath.dollars(model.stats.freeToSpendThisWeekCents)) free to spend this week")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(model.stats.freeToSpendThisWeekCents >= 0 ? .green : .red)
                            .accessibilityIdentifier("trends.freeToSpend")
                    }
                    Text(period.spentCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.stats.series.isEmpty {
                Text(model.isLoading
                     ? "Loading\u{2026}"
                     : (period.isCurrent
                        ? "No spending recorded this month yet."
                        : "No spending recorded in \(monthLabel)."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                chart
                    .frame(height: 170)
                HStack {
                    Text(model.stats.series.first?.date.formatted(.dateTime.day().month(.abbreviated)) ?? "")
                    Spacer()
                    // Month end, formatted like the left edge rather than
                    // pasted together from a name and a day count — with a
                    // year in the name that read "November 2025 30".
                    Text(period.lastDayOfMonth().formatted(.dateTime.day().month(.abbreviated)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch mode {
        case .spending:
            Chart(model.stats.series) { day in
                AreaMark(
                    x: .value("Day", day.date),
                    y: .value("Spent", Double(day.cumulativeCents) / 100.0)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Day", day.date),
                    y: .value("Spent", Double(day.cumulativeCents) / 100.0)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .chartYAxis { AxisMarks(position: .trailing) }

        case .daily:
            Chart(model.stats.series) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Spent", Double(day.spentCents) / 100.0)
                )
                .foregroundStyle(day.spentCents > model.stats.dailyLimitCents ? Color.red : Color.accentColor)
                .cornerRadius(3)
            }
            .chartYAxis { AxisMarks(position: .trailing) }
        }
    }

    // MARK: - Category budget

    // The month's Breakdown card lived here until 2026-08-12; it moved to the
    // bottom of Months (user request), and the category budget moved up here
    // from Months in the same change.

    /// The chart says how much; the budget lines say where — directly under
    /// the chart they explain, not one tab away from it.
    @ViewBuilder
    private var categoryBudgetCard: some View {
        if model.hasCategoryBudget, let month = model.selectedCategoryMonth {
            SurfaceCard {
                HStack(alignment: .firstTextBaseline) {
                    Text("By category")
                        .font(.title3.weight(.bold))
                    Spacer(minLength: 8)
                    if month.overCount > 0 {
                        Text("\(month.overCount) over")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                // Two months is the comparison that matters: is this month
                // tracking better or worse than the one that just closed.
                if model.categoryMonths.count > 1 {
                    Picker("Month", selection: Binding(
                        get: { model.selectedCategoryPeriod ?? month.period },
                        set: { model.selectedCategoryPeriod = $0 }
                    )) {
                        ForEach(model.categoryMonths) { m in
                            Text(m.shortLabel).tag(m.period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("trends.categoryMonth")
                }

                ForEach(Array(month.rows.enumerated()), id: \.element.id) { index, row in
                    // Tapping a line opens what it plans to spend and the
                    // transactions behind it. Uncategorized opens too — it has
                    // nothing to plan, but routing those out of it is the whole
                    // point of being able to see them.
                    Button {
                        editingLine = row
                    } label: {
                        CategoryLineRow(row: row, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trends.line")
                    if index < month.rows.count - 1 { Divider() }
                }

                Text("Tap a line to change what it plans to spend. Settings \u{203A} Budget by category has the transactions behind each one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .accessibilityIdentifier("trends.budgetHint")
            }
        } else {
            // Nothing to break down yet.
            SurfaceCard {
                HStack(alignment: .top, spacing: 12) {
                    RowIcon(systemName: "list.bullet.rectangle", tint: .purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Budget by category")
                            .font(.headline)
                        Text("Set a planned amount per line in Settings \u{203A} Budget by category, and this month and last will be measured against it here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .accessibilityIdentifier("trends.categories")
        }
    }
}
