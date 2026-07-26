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

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let txns = SpendService.shared.monthTransactions()
            async let budg = SpendService.shared.budget()
            let (t, b) = try await (txns, budg)
            stats = MonthMath.stats(transactions: t, dailyLimitCents: b.dailyLimitCents)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TrendsView: View {
    @StateObject private var model = TrendsViewModel()
    @State private var mode: TrendsMode = .spending
    @State private var showingBudget = false

    private var monthLabel: String {
        Date().formatted(.dateTime.month(.wide))
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
                        if model.stats.dailyLimitCents > 0 {
                            PromptCard(
                                icon: "target",
                                tint: .blue,
                                title: "Want to track spending by category?",
                                message: "Set a separate cap for eating out, transport, and the rest.",
                                ctaTitle: "Create category caps"
                            ) { showingBudget = true }
                        }
                        breakdownCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(isPresented: $showingBudget) {
                BudgetView(budget: Budget(dailyLimitCents: model.stats.dailyLimitCents, warnPct: 80)) { _ in
                    Task { await model.load() }
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

            Label("This month", systemImage: "line.3.horizontal.decrease")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemBackground), in: Capsule())
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
                Text("This month")
                    .font(.title3.weight(.bold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(BudgetMath.dollars(model.stats.spentCents))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .accessibilityIdentifier("trends.monthSpend")
                    Text("Spent so far")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.stats.series.isEmpty {
                Text(model.isLoading ? "Loading\u{2026}" : "No spending recorded this month yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                chart
                    .frame(height: 170)
                HStack {
                    Text(model.stats.series.first?.date.formatted(.dateTime.day().month(.abbreviated)) ?? "")
                    Spacer()
                    Text("\(monthLabel) \(model.stats.daysInMonth)")
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
                subtitle: "\(BudgetMath.dollars(model.stats.dailyLimitCents)) a day \u{00D7} \(model.stats.daysInMonth) days",
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
