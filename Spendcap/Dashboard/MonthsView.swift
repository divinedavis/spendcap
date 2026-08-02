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
    @Published var stats = YearStats(months: [], dailyLimitCents: 5000)
    /// Statements keyed by year * 100 + month, so a row can find its own PDF.
    @Published var statementsByMonth: [Int: BankStatement] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    var hasStatements: Bool { !statementsByMonth.isEmpty }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let rows = SpendService.shared.monthlySpend(monthsBack: 12)
            async let budg = SpendService.shared.budget()
            let (r, b) = try await (rows, budg)
            stats = YearMath.stats(rows: r, dailyLimitCents: b.dailyLimitCents)
        } catch {
            errorMessage = error.localizedDescription
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

    func statement(for month: MonthlySpend) -> BankStatement? {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month], from: month.date)
        guard let year = parts.year, let m = parts.month else { return nil }
        return statementsByMonth[year * 100 + m]
    }
}

struct MonthsView: View {
    @StateObject private var model = MonthsViewModel()
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                DashboardBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        summaryCard
                        if !model.stats.withData.isEmpty {
                            statementsCard
                            breakdownCard
                        }
                        monthsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Months")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task { await model.load() }
            .quickLookPreview($previewURL)
        }
    }

    // MARK: - Summary + chart

    private var summaryCard: some View {
        SurfaceCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last 12 months")
                        .font(.title3.weight(.bold))
                    Text(coverageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(BudgetMath.dollars(model.stats.totalCents))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .accessibilityIdentifier("months.total")
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
                        Text("Avg \(BudgetMath.dollars(model.stats.averageCents))")
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
                    : "Across \(model.stats.settled.count) complete month\(model.stats.settled.count == 1 ? "" : "s")",
                value: BudgetMath.dollars(model.stats.averageCents)
            )
            if let highest = model.stats.highest {
                Divider()
                DashboardRow(
                    icon: "arrow.up.right",
                    tint: .red,
                    title: "Highest month",
                    subtitle: highest.label,
                    value: BudgetMath.dollars(highest.spentCents)
                )
            }
            if let lowest = model.stats.lowest {
                Divider()
                DashboardRow(
                    icon: "arrow.down.right",
                    tint: .green,
                    title: "Lowest month",
                    subtitle: lowest.label,
                    value: BudgetMath.dollars(lowest.spentCents)
                )
            }
            Divider()
            DashboardRow(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Months over cap",
                subtitle: "At \(BudgetMath.dollars(model.stats.dailyLimitCents)) a day",
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
                    Text(BudgetMath.dollars(month.spentCents))
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
            parts.append("over the \(BudgetMath.dollars(month.capCents)) month cap")
        }
        if statement?.isAvailable == true {
            parts.append("statement")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Statements

    /// Points at the Statements screen rather than fetching here: Plaid bills
    /// per statement request, so that call stays behind a deliberate tap.
    @ViewBuilder
    private var statementsCard: some View {
        NavigationLink {
            StatementsView()
        } label: {
            SurfaceCard {
                HStack(alignment: .top, spacing: 12) {
                    RowIcon(systemName: "doc.text.fill", tint: .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.hasStatements ? "Statements" : "Add your statements")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(model.hasStatements
                             ? "\(model.statementsByMonth.count) on file. Tap any month below to open its PDF."
                             : "Your bank can share the PDF for each month. It needs its own approval, one time.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("months.statements")
    }

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
