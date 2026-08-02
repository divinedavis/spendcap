import SwiftUI
import Charts
import QuickLook

// Months: the statement-period view of spending — twelve calendar months of
// totals, the trend across them, and the bank statement behind each month.
//
// This is the screen for the question the daily cap can't answer: not "am I
// over today" but "is a month of my spending going up or down". Bank data
// settles over days, so month totals are the figure that can actually be
// trusted; the daily ring was removed for exactly that reason.

@MainActor
final class MonthsViewModel: ObservableObject {
    @Published var stats = YearStats(months: [], budget: Budget(dailyLimitCents: 5000, warnPct: 80))
    /// Statements keyed by year * 100 + month, so a row can find its own PDF.
    @Published var statementsByMonth: [Int: BankStatement] = [:]
    /// This month and last, by budget line — the same rollup the Budget screen
    /// uses, shown inline here.
    @Published var categoryMonths: [CategoryMonth] = []
    @Published var selectedCategoryPeriod: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?

    var selectedCategoryMonth: CategoryMonth? {
        categoryMonths.first { $0.period == selectedCategoryPeriod } ?? categoryMonths.first
    }

    /// True once loaded and nothing but the Uncategorized line came back, i.e.
    /// no budget has been set up yet.
    var hasCategoryBudget: Bool {
        categoryMonths.contains { month in month.rows.contains { !$0.isUncategorized } }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let rows = SpendService.shared.monthlySpend(monthsBack: 12)
            async let budg = SpendService.shared.budget()
            let (r, b) = try await (rows, budg)
            stats = YearMath.stats(rows: r, budget: b)
        } catch {
            // A pull-to-refresh that supersedes an in-flight load cancels it,
            // and "cancelled" printed in red under the chart reads as a real
            // failure. Nothing went wrong, so say nothing.
            errorMessage = Self.isCancellation(error) ? nil : error.localizedDescription
        }

        // Budget lines are a second read of the same months; a failure here
        // must not blank the totals above them.
        if let rows = try? await SpendService.shared.categorySpend(monthsBack: 2) {
            categoryMonths = CategoryMath.months(rows: rows)
            if selectedCategoryPeriod == nil
                || !categoryMonths.contains(where: { $0.period == selectedCategoryPeriod }) {
                selectedCategoryPeriod = categoryMonths.first?.period
            }
        }

        // Statements are context, not the point of the screen — reading the
        // table is free, but a failure here must not blank out the totals.
        // Nothing on this screen calls Plaid; fetching new statements stays on
        // the Statements screen, where the per-request cost is deliberate.
        if let statements = try? await SpendService.shared.statements() {
            statementsByMonth = Dictionary(
                statements.map { ($0.year * 100 + $0.month, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    /// Task cancellation surfaces in several shapes depending on how far the
    /// request got — Swift's own, URLSession's, and a plain "cancelled"
    /// description from the Supabase layer.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        return ns.localizedDescription.caseInsensitiveCompare("cancelled") == .orderedSame
    }

    func statement(for month: MonthlySpend) -> BankStatement? {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month], from: month.date)
        guard let year = parts.year, let m = parts.month else { return nil }
        return statementsByMonth[year * 100 + m]
    }
}

struct MonthsView: View {
    /// One sheet, one modifier. Two `.sheet(isPresented:)` on a single view is
    /// a silent bug — SwiftUI honours only one — so this stays item-driven even
    /// with a single case.
    private enum Sheet: Int, Identifiable {
        case caps
        var id: Int { rawValue }
    }

    @StateObject private var model = MonthsViewModel()
    @State private var previewURL: URL?
    @State private var sheet: Sheet?

    var body: some View {
        NavigationStack {
            ZStack {
                DashboardBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        capCard
                        summaryCard
                        categoryBudgetCard
                        // The month list is what the screen is for, so it sits
                        // above the year-level rollup rather than below it.
                        monthsCard
                        if !model.stats.withData.isEmpty {
                            breakdownCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Months")
            .navigationBarTitleDisplayMode(.inline)
            // Exactly one toolbar button, deliberately. A second one on this
            // bar is inert: with two present, the first never registers a tap,
            // as either a ToolbarItem pair or a ToolbarItemGroup. Proved by
            // giving both the same action — the second opened its sheet, the
            // first did nothing. Everything else opens from the cards, where
            // taps behave.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sheet = .caps
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("months.editCap")
                    .accessibilityLabel("Edit spending caps")
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .quickLookPreview($previewURL)
            .sheet(item: $sheet) { which in
                switch which {
                case .caps:
                    BudgetView(budget: model.stats.budget, focus: .monthly) { _ in
                        Task { await model.load() }
                    }
                }
            }
        }
    }

    // MARK: - This month against the cap

    /// The answer to "am I over budget", above everything else on the screen.
    private var capCard: some View {
        let month = model.stats.currentMonth
        let remaining = model.stats.currentRemainingCents
        let isOver = (remaining ?? 0) < 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(month?.label ?? "This month")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button {
                    sheet = .caps
                } label: {
                    Text(model.stats.budget.monthlyLimitCents == nil ? "Set cap" : "Edit")
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("months.setCap")
            }

            if let month, let remaining {
                Text(BudgetMath.wholeDollars(abs(remaining)))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("months.remaining")

                Text(isOver
                     ? "over your \(BudgetMath.wholeDollars(month.capCents)) cap for \(month.shortLabel)"
                     : "left of your \(BudgetMath.wholeDollars(month.capCents)) cap for \(month.shortLabel)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: model.stats.currentCapProgress)
                    .tint(.white)
                    .background(Color.white.opacity(0.25), in: Capsule())

                Text(capSourceLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No spending on record for this month yet.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(capColor, in: RoundedRectangle(cornerRadius: 18))
        .animation(.easeOut(duration: 0.3), value: model.stats.currentCapProgress)
    }

    private var capColor: Color {
        let progress = model.stats.currentCapProgress
        guard model.stats.currentMonth != nil else {
            return Color(red: 0.30, green: 0.33, blue: 0.38)
        }
        if progress >= 1.0 { return Color(red: 0.89, green: 0.26, blue: 0.20) }
        if progress >= 0.8 { return Color(red: 0.90, green: 0.55, blue: 0.09) }
        return Color(red: 0.13, green: 0.63, blue: 0.36)
    }

    /// Says out loud where the cap came from. A derived cap that nobody chose
    /// is the reason every month can read as over budget.
    private var capSourceLabel: String {
        if let monthly = model.stats.budget.monthlyLimitCents {
            return "Your monthly cap of \(BudgetMath.wholeDollars(monthly))."
        }
        return "No monthly cap set — this is your \(BudgetMath.dollars(model.stats.budget.dailyLimitCents)) daily cap across the month. Tap Set cap to use a real monthly figure."
    }

    // MARK: - Summary + chart

    private var summaryCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last 12 months")
                        .font(.title3.weight(.bold))
                    Spacer(minLength: 12)
                    // Six figures plus a currency symbol will not share a line
                    // with the title on a narrow phone, so it scales instead of
                    // wrapping mid-number.
                    Text(BudgetMath.wholeDollars(model.stats.totalCents))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .accessibilityIdentifier("months.total")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(coverageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text("Total spent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.stats.withData.isEmpty {
                Text(model.isLoading
                     ? "Loading\u{2026}"
                     : "No monthly history yet. Connect a bank on Home and your past months will fill in here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                chart
                    .frame(height: 190)

                HStack(spacing: 16) {
                    legendSwatch(color: .accentColor, label: "Within cap")
                    legendSwatch(color: .red, label: "Over cap")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var coverageLabel: String {
        let covered = model.stats.monthsCovered
        guard covered > 0 else { return "Nothing on record yet" }
        if covered < 12 {
            return "\(covered) month\(covered == 1 ? "" : "s") of history from your bank"
        }
        return "A full year on record"
    }

    private func legendSwatch(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(model.stats.withData) { month in
                BarMark(
                    x: .value("Month", month.date, unit: .month),
                    y: .value("Spent", Double(month.spentCents) / 100.0)
                )
                // The month in progress is a partial total, so it is drawn
                // faded — a short bar there means "not finished", not "cheap".
                .foregroundStyle(barColor(for: month).opacity(month.isCurrent ? 0.45 : 1))
                .cornerRadius(4)
            }

            if model.stats.averageCents > 0 {
                RuleMark(y: .value("Average", Double(model.stats.averageCents) / 100.0))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Avg \(BudgetMath.wholeDollars(model.stats.averageCents))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { value in
                AxisValueLabel(format: .dateTime.month(.narrow))
                if let date = value.as(Date.self),
                   Calendar(identifier: .gregorian).component(.month, from: date) == 1 {
                    AxisGridLine()
                }
            }
        }
        .chartYAxis { AxisMarks(position: .trailing) }
    }

    private func barColor(for month: MonthlySpend) -> Color {
        month.isOverCap ? .red : .accentColor
    }

    // MARK: - Breakdown

    private var breakdownCard: some View {
        SurfaceCard {
            SectionHeader(title: "Across the year", actionSystemImage: nil, action: nil)

            DashboardRow(
                icon: "chart.bar.fill",
                tint: .purple,
                title: "Average month",
                subtitle: model.stats.settled.isEmpty
                    ? "This month so far"
                    : "\(model.stats.settled.count) complete month\(model.stats.settled.count == 1 ? "" : "s")",
                value: BudgetMath.wholeDollars(model.stats.averageCents)
            )
            if let highest = model.stats.highest {
                Divider()
                DashboardRow(
                    icon: "arrow.up.right",
                    tint: .red,
                    title: "Highest month",
                    subtitle: highest.label,
                    value: BudgetMath.wholeDollars(highest.spentCents)
                )
            }
            if let lowest = model.stats.lowest {
                Divider()
                DashboardRow(
                    icon: "arrow.down.right",
                    tint: .green,
                    title: "Lowest month",
                    subtitle: lowest.label,
                    value: BudgetMath.wholeDollars(lowest.spentCents)
                )
            }
            Divider()
            DashboardRow(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Months over cap",
                subtitle: model.stats.budget.monthlyLimitCents
                    .map { "Against \(BudgetMath.wholeDollars($0)) a month" }
                    ?? "Against \(BudgetMath.dollars(model.stats.budget.dailyLimitCents)) a day",
                value: "\(model.stats.monthsOverCap)",
                valueColor: model.stats.monthsOverCap > 0 ? .orange : .primary
            )
            if let trend = model.stats.trendFraction {
                Divider()
                DashboardRow(
                    icon: trend >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                    tint: trend >= 0 ? .orange : .green,
                    title: "Trend",
                    subtitle: trend >= 0 ? "Recent months are running higher" : "Recent months are running lower",
                    value: (trend >= 0 ? "+" : "\u{2212}") + "\(abs(Int((trend * 100).rounded())))%",
                    valueColor: trend >= 0 ? .orange : .green
                )
            }
        }
    }

    // MARK: - Month list

    private var monthsCard: some View {
        SurfaceCard {
            SectionHeader(title: "Month by month", actionSystemImage: nil, action: nil)

            let rows = model.stats.months.reversed().filter(\.hasData)
            if rows.isEmpty {
                Text("Once a bank is connected, every month it shares shows up here with its statement.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, month in
                    monthRow(month)
                    if index < rows.count - 1 { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func monthRow(_ month: MonthlySpend) -> some View {
        let statement = model.statement(for: month)

        Button {
            if let statement { Task { await open(statement) } }
        } label: {
            HStack(spacing: 12) {
                RowIcon(
                    systemName: statement?.isAvailable == true ? "doc.text.fill" : "calendar",
                    tint: month.isOverCap ? .red : .accentColor
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(month.label)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(subtitle(for: month, statement: statement))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(BudgetMath.wholeDollars(month.spentCents))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(month.isOverCap ? Color.red : Color.primary)
                    if let changeLabel = month.changeLabel {
                        Text(changeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if month.isCurrent {
                        Text("so far")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if statement?.isAvailable == true {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(statement?.isAvailable != true)
        .accessibilityIdentifier("months.row")
    }

    private func subtitle(for month: MonthlySpend, statement: BankStatement?) -> String {
        var parts: [String] = ["\(month.txnCount) transaction\(month.txnCount == 1 ? "" : "s")"]
        if month.isOverCap {
            parts.append("over the \(BudgetMath.wholeDollars(month.capCents)) month cap")
        }
        if statement?.isAvailable == true {
            parts.append("statement")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Category budget

    /// A month total says the month went wrong; the budget lines say where —
    /// so they belong on this screen, not one tap away behind it.
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
                    .accessibilityIdentifier("months.categoryMonth")
                }

                ForEach(Array(month.rows.enumerated()), id: \.element.id) { index, row in
                    CategoryLineRow(row: row)
                    if index < month.rows.count - 1 { Divider() }
                }

                // Editing the lines lives in Settings > Budget by category.
                // Buttons this far down the scroll view do not receive taps —
                // measured, not assumed — so this points there rather than
                // pretending to be one.
                Text("Edit these lines in Settings \u{203A} Budget by category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityIdentifier("months.budgetHint")
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
            .accessibilityIdentifier("months.categories")
        }
    }

    // MARK: - Statements

    // There is no statements card here by design. Months links a month to its
    // PDF through the row itself; setting statements up lives in Settings →
    // Statements, which is also the only place that calls Plaid for them.

    private func open(_ statement: BankStatement) async {
        do {
            // Signed URLs are short-lived, so mint one per tap rather than
            // caching a link that would quietly rot.
            previewURL = try await SpendService.shared.statementURL(statement)
        } catch {
            model.errorMessage = "Couldn't open that statement: \(error.localizedDescription)"
        }
    }
}
