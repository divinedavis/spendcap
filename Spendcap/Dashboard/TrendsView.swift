import SwiftUI
import Charts

// Cumulative spending, with the previous month behind the current month.

@MainActor
final class TrendsViewModel: ObservableObject {
    @Published var stats = MonthStats(series: [], spentCents: 0, daysElapsed: 0,
                                      daysInMonth: 0, dailyLimitCents: 5000)
    @Published var previousMonthStats: MonthStats?
    /// This month and last, by budget line — the same rollup the Budget screen
    /// uses, shown under the chart. Moved here from Months 2026-08-12.
    @Published var categoryMonths: [CategoryMonth] = []
    @Published var selectedCategoryPeriod: Date?
    /// Where the checking balance lands at month end. Nil until both forecast
    /// reads have answered and there are two complete months to read from;
    /// the card hides itself rather than forecast from one month.
    @Published var forecast: ForecastStats?
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Failures the user caused, kept apart from `errorMessage`: a load that
    /// fails is silent here (the card just doesn't change), but a delete that
    /// fails has to say so or the line looks like it survived on purpose.
    @Published var actionError: String?

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
        applyPreviousMonth(transactions: snapshot.previousMonthTransactions,
                           budget: snapshot.budget, reference: Date())
        apply(categoryRows: snapshot.categoryRows,
              daily: snapshot.dailyDiscretionary,
              wireDiscretionary: true)
        if let recurring = snapshot.forecastRecurring, let flows = snapshot.forecastFlows {
            forecast = ForecastMath.stats(recurring: recurring, flows: flows)
        }
    }

    /// Deleting a line cascades its rules, so the transactions it claimed fall
    /// back to Uncategorized on the next read. The transactions themselves are
    /// untouched — this removes a bucket, not history. Same call the Budget
    /// screen's swipe makes; the two must not diverge.
    func delete(_ row: CategorySpendRow, period: TrendsPeriod) async {
        guard let id = row.categoryId else { return }
        do {
            try await SpendService.shared.deleteCategory(id: id)
            await load(period: period)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func load(period: TrendsPeriod = .thisMonth) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var loaded: (transactions: [BankTransaction], budget: Budget, previous: [BankTransaction]?)?
        do {
            // One reference date drives the fetch and the math, so the rows
            // pulled and the days charted can never describe different months.
            let reference = period.referenceDate()
            async let txns = SpendService.shared.monthTransactions(now: reference)
            async let previous = period.isCurrent
                ? try? await SpendService.shared.monthTransactions(
                    now: TrendsPeriod.lastMonth.referenceDate(now: reference))
                : nil
            async let budg = SpendService.shared.budget()
            let (t, b) = try await (txns, budg)
            apply(transactions: t, budget: b, reference: reference)
            let previousTransactions = await previous
            applyPreviousMonth(transactions: previousTransactions, budget: b, reference: reference)
            loaded = (t, b, previousTransactions)
        } catch {
            errorMessage = error.localizedDescription
        }

        // Budget lines are a second read of the same months; a failure here
        // must not blank the chart above them. Always this month and last —
        // the card has its own picker and does not follow the period chip.
        // The per-day discretionary rows ride along: they feed the weekly
        // buckets, and only the current month has weeks left to spend.
        async let rowsTask = try? await SpendService.shared.categorySpend(monthsBack: 2)
        async let dailyTask = period.isCurrent
            ? try? await SpendService.shared.discretionaryDaily()
            : nil
        // The forecast only means anything for the month still in progress,
        // and both halves are needed: the regulars without the balance is a
        // list with nothing to subtract from.
        async let recurringTask = period.isCurrent
            ? try? await SpendService.shared.forecastRecurring()
            : nil
        async let flowsTask = period.isCurrent
            ? try? await SpendService.shared.forecastFlows()
            : nil
        let (rows, daily, recurring, flows) = await (rowsTask, dailyTask, recurringTask, flowsTask)
        if let rows {
            apply(categoryRows: rows, daily: daily, wireDiscretionary: period.isCurrent)
        }
        if let recurring, let flows {
            forecast = ForecastMath.stats(recurring: recurring, flows: flows)
        }

        // Persist what the next cold launch should open on: the current
        // month, fully loaded. A partial load must not overwrite a complete
        // snapshot from an earlier visit — and the daily rows are part of
        // "complete" now, or the restored frame would open with no weekly
        // figure and pop one in when the network answered. The forecast rows
        // ride along for the same reason, but are not part of "complete":
        // an account with no checking balance has none to save, and that must
        // not stop the chart from being remembered.
        if period.isCurrent, let loaded, let rows, let daily,
           let userId = SpendService.shared.currentUserId {
            TrendsSnapshotStore.save(TrendsSnapshot(
                userId: userId, savedAt: Date(),
                transactions: loaded.transactions, budget: loaded.budget,
                categoryRows: rows, dailyDiscretionary: daily,
                forecastRecurring: recurring, forecastFlows: flows,
                previousMonthTransactions: loaded.previous))
        }
    }

    private func applyPreviousMonth(transactions: [BankTransaction]?, budget: Budget,
                                    reference: Date) {
        previousMonthStats = transactions.map {
            MonthMath.stats(
                transactions: $0,
                dailyLimitCents: budget.dailyLimitCents,
                monthlyLimitCents: budget.monthlyLimitCents,
                now: TrendsPeriod.lastMonth.referenceDate(now: reference))
        }
    }

    /// Resolve the same spending and caps as the Months screen.
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
    private func apply(categoryRows: [CategorySpendRow], daily: [DiscretionaryDay]?,
                       wireDiscretionary: Bool) {
        categoryMonths = CategoryMath.months(rows: categoryRows)
        if selectedCategoryPeriod == nil
            || !categoryMonths.contains(where: { $0.period == selectedCategoryPeriod }) {
            selectedCategoryPeriod = categoryMonths.first?.period
        }
        if wireDiscretionary, let current = categoryMonths.first(where: \.isCurrent) {
            stats.discretionaryPlannedCents = current.discretionaryPlannedCents
            stats.discretionarySpentCents = current.discretionarySpentCents
            // Both halves or neither: the weekly buckets are cut from the
            // planned total, so a bucket built without it would read as a
            // whole month overspent.
            stats.weekStats = daily.map {
                WeekMath.stats(month: Date(),
                               discretionaryPlannedCents: current.discretionaryPlannedCents,
                               daily: $0)
            }
        }
    }
}

struct TrendsView: View {
    @StateObject private var model = TrendsViewModel()
    @State private var period: TrendsPeriod = .thisMonth
    @State private var editingLine: CategorySpendRow?
    @State private var pendingDelete: CategorySpendRow?
    /// Which budget line is currently swiped open, so opening one closes the
    /// rest — the behaviour a List gives for free.
    @State private var openSwipeRow: String?
    /// The forecast card's list of expected transactions, folded by default —
    /// the number is the point, the list is how to argue with it.
    @State private var showsPredicted = false

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
                        chartCard
                        categoryBudgetCard
                        // Below the budget lines (user request, 2026-09-08):
                        // the month's plan first, the balance it leads to after.
                        if period.isCurrent, let forecast = model.forecast {
                            forecastCard(forecast)
                        }
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
                .accessibilityIdentifier("trends.scroll")
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
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.categoryName)?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let row = pendingDelete {
                        pendingDelete = nil
                        Task { await model.delete(row, period: period) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let row = pendingDelete {
                    // Word for word what the Budget screen says, because it is
                    // the same delete: the line and its rules go, and its
                    // transactions are re-matched — not moved wholesale to
                    // Uncategorized, which another broad rule may well claim.
                    Text("The line and its rules go. Its \(row.txnCount) transaction\(row.txnCount == 1 ? "" : "s") this month are re-matched against your other rules, and land in Uncategorized if nothing else claims them. Nothing is deleted from your history.")
                }
            }
            .alert("Couldn't delete that line",
                   isPresented: Binding(
                       get: { model.actionError != nil },
                       set: { if !$0 { model.actionError = nil } }
                   ),
                   presenting: model.actionError) { _ in
                Button("OK", role: .cancel) { model.actionError = nil }
            } message: { message in
                Text(message)
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
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .accessibilityIdentifier("trends.monthSpend")
                    // The weekly free-to-spend figure came off this card on
                    // 2026-08-19. The arithmetic was right, but the week it
                    // described was not one: Wells Fargo posts every weekend
                    // purchase on the following Monday — 240 Monday rows
                    // against one weekend row across the whole history — so a
                    // Mon–Sun bucket opens already carrying the weekend before
                    // it, and the card read deep red every Monday and Tuesday
                    // before recovering. A number that is only honest midweek
                    // is worse than no number. The same posting quirk took the
                    // weekend-spend row off Months in build 32.
                    //
                    // WeekMath and the daily fetch stay: they are unit-tested
                    // and cost nothing extra on a load that already happens,
                    // and bucketing Sat–Fri instead would make the figure
                    // truthful without rebuilding any of it.
                    Text(period.spentCaption)
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
            }

            if model.stats.series.isEmpty {
                Text(model.isLoading
                     ? "Loading\u{2026}"
                     : (period.isCurrent
                        ? "No spending recorded this month yet."
                        : "No spending recorded in \(monthLabel)."))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                chart
                    .frame(height: 170)
                if comparisonStats != nil {
                    HStack(spacing: 18) {
                        chartLegend("This month", color: .accentColor)
                        chartLegend("Last month", color: .secondary, dash: [4, 3])
                            .accessibilityIdentifier("trends.previousMonthLegend")
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var comparisonStats: MonthStats? {
        period.isCurrent ? model.previousMonthStats : nil
    }

    private var chartDayCount: Int {
        max(model.stats.daysInMonth, comparisonStats?.daysInMonth ?? 0, 2)
    }

    private func chartLegend(_ title: String, color: Color, dash: [CGFloat] = []) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 20, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash))
            .frame(width: 20, height: 2)
            .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Color.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        Chart {
            // Separate series prevent Charts from joining the two months.
            // Day indices retain every day even when the months differ in length.
            if let previous = comparisonStats {
                ForEach(Array(previous.series.enumerated()), id: \.element.id) { index, day in
                    LineMark(
                        x: .value("Day of month", index + 1),
                        y: .value("Spent", Double(day.cumulativeCents) / 100.0),
                        series: .value("Month", "Last month")
                    )
                    .foregroundStyle(Color.secondary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                    .accessibilityLabel("Last month, day \(index + 1)")
                    .accessibilityValue(BudgetMath.dollars(day.cumulativeCents))
                }
            }
            ForEach(Array(model.stats.series.enumerated()), id: \.element.id) { index, day in
                AreaMark(
                    x: .value("Day of month", index + 1),
                    y: .value("Spent", Double(day.cumulativeCents) / 100.0)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .accessibilityHidden(true)
                LineMark(
                    x: .value("Day of month", index + 1),
                    y: .value("Spent", Double(day.cumulativeCents) / 100.0),
                    series: .value("Month", "Selected month")
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .accessibilityLabel("\(period.label()), day \(index + 1)")
                .accessibilityValue(BudgetMath.dollars(day.cumulativeCents))
            }
        }
        .chartXScale(domain: 1...chartDayCount)
        .chartXAxis {
            AxisMarks(values: [1, 7, 14, 21, chartDayCount]) { value in
                AxisGridLine()
                AxisValueLabel(anchor: value.as(Int.self) == chartDayCount ? .topTrailing : .topLeading) {
                    if let day = value.as(Int.self) {
                        Text("Day \(day)")
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .trailing) }
        .accessibilityIdentifier("trends.spendingChart")
    }

    // MARK: - Forecast

    /// Where the checking balance lands at month end, and what gets it there:
    /// the balance now less pending charges, the regulars still to come in and
    /// out, and the everyday run-rate over the days left. Current month only —
    /// a finished month has nothing left to forecast.
    private func forecastCard(_ forecast: ForecastStats) -> some View {
        let projected = forecast.projectedCents
        let negative = projected < 0

        return SurfaceCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forecast")
                        .font(.title3.weight(.bold))
                    Text("Checking on \(forecast.monthEndLabel)")
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text((negative ? "\u{2212}" : "") + BudgetMath.dollars(abs(projected)))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(negative ? Color.red : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("trends.forecastBalance")
                    Text(negative ? "short at month end" : "left at month end")
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
            }

            DashboardRow(
                icon: "building.columns.fill",
                tint: .blue,
                title: "In checking today",
                subtitle: forecast.pendingOutCents > 0
                    ? "After \(BudgetMath.dollars(forecast.pendingOutCents)) still pending"
                    : "As your bank last reported it",
                value: (forecast.availableCents < 0 ? "\u{2212}" : "")
                    + BudgetMath.dollars(abs(forecast.availableCents)),
                valueColor: forecast.availableCents < 0 ? .red : .primary
            )
            Divider()
            DashboardRow(
                icon: "arrow.down.left.circle.fill",
                tint: .green,
                title: "Regular money in",
                subtitle: forecast.predictedInCount == 0
                    ? "Nothing more expected this month"
                    : "\(forecast.predictedInCount) expected",
                value: "+" + BudgetMath.dollars(forecast.predictedInCents),
                valueColor: .green
            )
            Divider()
            DashboardRow(
                icon: "calendar.badge.clock",
                tint: .orange,
                title: "Bills & regulars",
                subtitle: forecast.predictedOutCount == 0
                    ? "Nothing more expected this month"
                    : "\(forecast.predictedOutCount) still to come",
                value: "\u{2212}" + BudgetMath.dollars(forecast.predictedOutCents),
                valueColor: .red
            )
            Divider()
            DashboardRow(
                icon: "cart.fill",
                tint: .purple,
                title: "Everyday spending",
                subtitle: "\(forecast.daysLeft) day\(forecast.daysLeft == 1 ? "" : "s") \u{00D7} \(BudgetMath.dollars(forecast.everydayPerDayCents)) a day",
                value: "\u{2212}" + BudgetMath.dollars(forecast.everydayCents),
                valueColor: .red
            )

            if !forecast.predicted.isEmpty {
                Divider()
                Button {
                    withAnimation(.snappy) { showsPredicted.toggle() }
                } label: {
                    HStack {
                        Text(showsPredicted
                             ? "Hide the expected transactions"
                             : "Show the \(forecast.predicted.count) expected transaction\(forecast.predicted.count == 1 ? "" : "s")")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: showsPredicted ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trends.forecastToggle")

                if showsPredicted {
                    ForEach(forecast.predicted) { item in
                        HStack(spacing: 12) {
                            Text(item.dateLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(item.isOverdue ? Color.orange : Color.secondaryText)
                                .frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                // Two lines: a bank descriptor ("ACME CORP
                                // B PAYROLL DD") is the honest name and
                                // truncating it hides which regular this is.
                                Text(item.who)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if item.isOverdue {
                                    Text("Usually by now \u{00B7} any day")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            Text((item.isInflow ? "+" : "\u{2212}") + BudgetMath.dollars(item.amountCents))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(item.isInflow ? Color.green : Color.primary)
                        }
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("trends.forecastRow")
                    }
                }
            }

            Text("From \(forecast.windowLabel): a regular is anything that came in or went out most months, up to three times a month, on about the same day. Everything else is averaged into everyday spending. Money in only counts when it is regular.")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
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
                    // The whole budget in one pair: everything that actually
                    // left the account this month against everything the lines
                    // planned between them. The rows below already carry both
                    // figures line by line, but nowhere said what they came to.
                    //
                    // The two totals are not symmetrical and that is
                    // deliberate — planned excludes Uncategorized (it has no
                    // plan by definition) while spent includes it (the money
                    // left the account either way). So this pair can read over
                    // budget with no single line over, which is exactly the
                    // state worth surfacing: unclaimed spending.
                    //
                    // Identifiers go on each Text, never on the stacks. A
                    // container's identifier is pushed down onto every
                    // descendant and would make all three unfindable under one
                    // name.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(BudgetMath.wholeDollars(month.spentCents))
                            .font(.headline)
                            .foregroundStyle(month.spentCents > month.plannedCents
                                             ? Color.red : Color.primary)
                            .accessibilityIdentifier("trends.categoryTotalSpent")
                        HStack(spacing: 5) {
                            Text("of \(BudgetMath.wholeDollars(month.plannedCents)) planned")
                                .foregroundStyle(Color.secondaryText)
                                .accessibilityIdentifier("trends.categoryTotalPlanned")
                            if month.overCount > 0 {
                                Text("\(month.overCount) over")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("trends.categoryOverCount")
                            }
                        }
                        .font(.caption)
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
                    // Tap opens the editor, swiping left deletes the line
                    // (user request, 2026-08-23).
                    //
                    // Uncategorized opens too — it has nothing to plan, but
                    // routing those transactions out of it is the whole point
                    // of being able to see them. It does not swipe: there is no
                    // line there to delete.
                    SwipeToDeleteRow(
                        rowID: row.id,
                        openRowID: $openSwipeRow,
                        isDeletable: !row.isUncategorized,
                        deleteIdentifier: "trends.deleteLine",
                        onDelete: { pendingDelete = row }
                    ) {
                        Button {
                            editingLine = row
                        } label: {
                            CategoryLineRow(row: row, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("trends.line")
                    }
                    if index < month.rows.count - 1 { Divider() }
                }
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
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .accessibilityIdentifier("trends.categories")
        }
    }
}
