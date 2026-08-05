import SwiftUI
import Charts

// Trends template, modelled on Monzo's Trends screen:
//   account chip + period chip → segmented modes → chart card → prompt → Breakdown
//
// Label mapping (first pass — adjust freely):
//   Monzo "Balance/Spending/Target" -> Spending / Daily / Target
//   Monzo "Today's Balance"         -> month-to-date spend
//   Monzo balance line              -> cumulative spend, with the cap pace line
//   Monzo "Breakdown"               -> month cap, spent, left, average, days over

enum TrendsMode: String, CaseIterable, Identifiable {
    case spending = "Spending"
    case daily = "Daily"
    case target = "Target"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .spending: return "chart.line.uptrend.xyaxis"
        case .daily: return "chart.bar.fill"
        case .target: return "target"
        }
    }
}

@MainActor
final class TrendsViewModel: ObservableObject {
    @Published var stats = MonthStats(series: [], spentCents: 0, daysElapsed: 0,
                                      daysInMonth: 0, dailyLimitCents: 5000)
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load(period: TrendsPeriod = .thisMonth) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // One reference date drives the fetch and the math, so the rows
            // pulled and the days charted can never describe different months.
            let reference = period.referenceDate()
            async let txns = SpendService.shared.monthTransactions(now: reference)
            async let budg = SpendService.shared.budget()
            let (t, b) = try await (txns, budg)
            // Both caps: the daily one colours the per-day bars, the monthly
            // one (when set) is what the month is judged against — Months uses
            // the same resolution, and the two screens must not disagree.
            stats = MonthMath.stats(
                transactions: t,
                dailyLimitCents: b.dailyLimitCents,
                monthlyLimitCents: b.monthlyLimitCents,
                now: reference
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TrendsView: View {
    @StateObject private var model = TrendsViewModel()
    @State private var mode: TrendsMode = .spending
    @State private var period: TrendsPeriod = .thisMonth

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
                        breakdownCard
                    }
                    .padding(.horizontal, 16)
                    // The chips row used to sit flush against the navigation
                    // bar, whose scroll-edge effect on iOS 26 reaches into the
                    // top of the scroll content and swallows touches there.
                    // Nothing up here was interactive before the period menu,
                    // so nothing had caught it.
                    .padding(.top, 12)
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

        case .target:
            Chart {
                ForEach(model.stats.series) { day in
                    LineMark(
                        x: .value("Day", day.date),
                        y: .value("Spent", Double(day.cumulativeCents) / 100.0),
                        series: .value("Series", "Actual")
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                // Straight-line pace: what spending exactly at the cap looks like.
                ForEach(model.stats.series) { day in
                    LineMark(
                        x: .value("Day", day.date),
                        y: .value("Spent", paceCents(through: day) / 100.0),
                        series: .value("Series", "Cap pace")
                    )
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
            }
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartForegroundStyleScale([
                "Actual": Color.accentColor,
                "Cap pace": Color.secondary,
            ])
        }
    }

    /// Cumulative cap allowance through the given day (day index × daily cap).
    private func paceCents(through day: DailySpend) -> Double {
        guard let first = model.stats.series.first else { return 0 }
        let calendar = Calendar(identifier: .gregorian)
        let index = calendar.dateComponents([.day], from: first.date, to: day.date).day ?? 0
        return Double((index + 1) * model.stats.dailyLimitCents)
    }

    // MARK: - Breakdown

    private var breakdownCard: some View {
        SurfaceCard {
            SectionHeader(title: "Breakdown", actionSystemImage: nil, action: nil)

            DashboardRow(
                icon: "calendar",
                tint: .blue,
                title: "Cap for \(monthLabel)",
                subtitle: model.stats.monthlyLimitCents != nil
                    ? "Your monthly cap"
                    : "\(BudgetMath.dollars(model.stats.dailyLimitCents)) a day \u{00D7} \(model.stats.daysInMonth) days",
                value: BudgetMath.dollars(model.stats.monthCapCents)
            )
            Divider()
            DashboardRow(
                icon: "arrow.up.right",
                tint: .red,
                title: "Spent so far",
                subtitle: "Across \(model.stats.daysElapsed) day\(model.stats.daysElapsed == 1 ? "" : "s")",
                value: "\u{2212}" + BudgetMath.dollars(model.stats.spentCents),
                valueColor: .red
            )
            Divider()
            DashboardRow(
                icon: "checkmark.circle",
                tint: model.stats.remainingCents >= 0 ? .green : .red,
                title: "Left this month",
                subtitle: model.stats.remainingCents >= 0 ? "At your current cap" : "Over the monthly cap",
                value: BudgetMath.dollars(abs(model.stats.remainingCents)),
                valueColor: model.stats.remainingCents >= 0 ? .green : .red
            )
            Divider()
            DashboardRow(
                icon: "chart.bar.fill",
                tint: .purple,
                title: "Average per day",
                subtitle: "Projects to \(BudgetMath.dollars(model.stats.projectedCents)) by month end",
                value: BudgetMath.dollars(model.stats.averagePerDayCents)
            )
            Divider()
            DashboardRow(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Days over cap",
                subtitle: "Out of \(model.stats.daysElapsed) so far",
                value: "\(model.stats.daysOverCap)",
                valueColor: model.stats.daysOverCap > 0 ? .orange : .primary
            )
        }
    }
}
