import SwiftUI

// The Debt tab — every recurring obligation, grouped, with a subtotal per
// group and a total across all of them.
//
// This is the spreadsheet Divine kept by hand, with one difference that
// matters: the subtotals are derived from the rows, never typed. His sheet had
// two groups whose written total disagreed with its own items, and a figure
// that can drift from what it is summing is the one number on the screen that
// cannot be trusted.
//
// Planned and actual sit side by side. "Paid" is what actually posted against
// the item this month, matched by the same display name the budget rollups use.
// An item with no match string reads **not tracked**, never "$0 paid" — some of
// these (a 401k loan, a payroll-deducted repayment) may never move through the
// checking account, and a zero there would be a claim the data cannot support.

@MainActor
final class DebtViewModel: ObservableObject {
    @Published var summary: DebtSummary = .empty
    @Published var groups: [DebtGroup] = []
    @Published var isLoading = false
    @Published var isSeeding = false
    @Published var errorMessage: String?
    /// This month or last. Everything on the tab — paid, charges, and the
    /// measured monthly figure (three full months before this one) — reads it.
    @Published var month: DebtMonth = .current

    /// Loaded, and the user has no groups at all — the only state that offers
    /// to seed the starter buckets.
    var isEmpty: Bool { !isLoading && summary.isEmpty }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Pull anything new off the budget first, so a lender that started
            // charging this month is on screen the first time it is opened
            // rather than the second. A failure here must not blank the tab —
            // the sync is an enrichment, the summary below is the screen.
            _ = try? await SpendService.shared.syncDebtItemsFromBudget()

            async let rows = SpendService.shared.debtSummary(period: month.start())
            async let stored = SpendService.shared.debtGroups()
            summary = DebtMath.summary(rows: try await rows)
            groups = try await stored
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
        }
    }

    func seed() async {
        isSeeding = true
        defer { isSeeding = false }
        do {
            _ = try await SpendService.shared.seedStarterDebt()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ row: DebtSummaryRow) async {
        guard let id = row.itemId else { return }
        do {
            try await SpendService.shared.deleteDebtItem(id: id, matchValue: row.matchValue)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteGroup(_ group: DebtGroupSummary) async {
        do {
            try await SpendService.shared.deleteDebtGroup(id: group.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addGroup(named name: String) async {
        do {
            try await SpendService.shared.createDebtGroup(name: name)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DebtView: View {
    @StateObject private var model = DebtViewModel()
    @State private var sheet: Sheet?
    @State private var pendingItemDelete: DebtSummaryRow?
    @State private var pendingGroupDelete: DebtGroupSummary?
    @State private var newGroupName = ""
    @State private var showingAddGroup = false

    /// One sheet modifier, several cases — stacked `.sheet(isPresented:)`
    /// modifiers risk one that silently never presents.
    enum Sheet: Identifiable {
        case add(groupId: UUID)
        case edit(DebtSummaryRow)
        case charges(DebtChargesTarget)

        var id: String {
            switch self {
            case .add(let groupId): return "add-\(groupId)"
            case .edit(let row): return "edit-\(row.id)"
            case .charges(let target): return "charges-\(target.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DashboardBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        if model.isEmpty {
                            starterCard
                        } else {
                            monthPicker
                            totalCard
                            ForEach(model.summary.groups) { group in
                                groupCard(group)
                            }
                            addGroupButton
                        }

                        if let errorMessage = model.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("debt.error")
                        }
                    }
                    .padding(.horizontal, 16)
                    // The nav bar's scroll-edge effect reaches ~12pt past its
                    // own frame on iOS 26 and eats touches on whatever sits
                    // flush under it. 24 keeps the first card's controls real.
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
                .refreshable { await model.load() }

                if model.isLoading && model.summary.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Debt")
            .task(id: model.month) { await model.load() }
            .sheet(item: $sheet) { which in
                switch which {
                case .add(let groupId):
                    DebtItemEditor(groups: model.groups, groupId: groupId, row: nil) {
                        await model.load()
                    }
                case .edit(let row):
                    DebtItemEditor(groups: model.groups, groupId: row.groupId, row: row) {
                        await model.load()
                    }
                case .charges(let target):
                    DebtChargesView(target: target, groups: model.groups, month: model.month) {
                        await model.load()
                    }
                }
            }
            .alert("Add a group", isPresented: $showingAddGroup) {
                TextField("Name", text: $newGroupName)
                Button("Cancel", role: .cancel) { newGroupName = "" }
                Button("Add") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newGroupName = ""
                    guard !name.isEmpty else { return }
                    Task { await model.addGroup(named: name) }
                }
            }
            .confirmationDialog(
                "Delete \(pendingItemDelete?.itemName ?? "this item")?",
                isPresented: Binding(
                    get: { pendingItemDelete != nil },
                    set: { if !$0 { pendingItemDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let row = pendingItemDelete {
                        pendingItemDelete = nil
                        Task { await model.deleteItem(row) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingItemDelete = nil }
            } message: {
                Text("Removes the row from this list. Nothing is removed from your transaction history.")
            }
            .confirmationDialog(
                "Delete \(pendingGroupDelete?.name ?? "this group")?",
                isPresented: Binding(
                    get: { pendingGroupDelete != nil },
                    set: { if !$0 { pendingGroupDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let group = pendingGroupDelete {
                        pendingGroupDelete = nil
                        Task { await model.deleteGroup(group) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingGroupDelete = nil }
            } message: {
                Text("Deletes the group and the \(pendingGroupDelete?.items.count ?? 0) item(s) in it. Nothing is removed from your transaction history.")
            }
        }
    }

    // MARK: - Cards

    /// Last month is one tap away rather than a scroll through history: "did
    /// everything go out in September" is the question, and a summary pinned to
    /// today could not answer it once October started.
    private var monthPicker: some View {
        Picker("Month", selection: $model.month) {
            ForEach(DebtMonth.allCases) { month in
                Text(month.label()).tag(month)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("debt.month")
    }

    private var monthName: String {
        model.month == .current ? "this month" : "in \(model.month.label())"
    }

    private var totalCard: some View {
        SurfaceCard {
            Text("Every month")
                .font(.subheadline)
                .foregroundStyle(Color.secondaryText)
            Text(BudgetMath.dollars(model.summary.plannedCents))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .accessibilityLabel(BudgetMath.spoken(model.summary.plannedCents))
                .accessibilityIdentifier("debt.total")
            Text("across \(model.summary.itemCount) item\(model.summary.itemCount == 1 ? "" : "s") in \(model.summary.groups.count) group\(model.summary.groups.count == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundStyle(Color.secondaryText)

            if model.summary.hasTrackedItems {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.month == .current ? "Paid so far this month" : "Paid \(monthName)")
                            .font(.caption)
                            .foregroundStyle(Color.secondaryText)
                        Text(BudgetMath.dollars(model.summary.paidCents))
                            .font(.headline)
                            .accessibilityLabel(BudgetMath.spoken(model.summary.paidCents))
                            .accessibilityIdentifier("debt.paid")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.month == .current ? "Still expected" : "Didn't post")
                            .font(.caption)
                            .foregroundStyle(Color.secondaryText)
                        Text(BudgetMath.dollars(model.summary.outstandingCents))
                            .font(.headline)
                            .accessibilityLabel(BudgetMath.spoken(model.summary.outstandingCents))
                    }
                }
                Text("Each amount is worked out from its charges: the typical month of the three before \(model.month == .current ? "this one" : model.month.label()). Items with no charges use the amount you typed. Paid counts only items with a match set.")
                    .font(.caption2)
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

    /// No per-group "Paid this month" row: the total card at the top already
    /// answers paid for the month, and repeating it on every card cost a line
    /// each for a figure the reader had passed on the way in. The per-item
    /// paid line stays, because that one is not shown anywhere else.
    private func groupCard(_ group: DebtGroupSummary) -> some View {
        SurfaceCard {
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(.title3.weight(.bold))
                Spacer()
                Text(BudgetMath.dollars(group.plannedCents))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .accessibilityLabel(BudgetMath.spoken(group.plannedCents))
                    .accessibilityIdentifier("debt.groupTotal")
            }

            if group.isEmpty {
                Text("Nothing in this group yet.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
            } else {
                ForEach(group.vendors) { vendor in
                    vendorRows(vendor, monthName: monthName)

                    if vendor.id != group.vendors.last?.id {
                        Divider()
                    }
                }

            }

            HStack {
                Button {
                    sheet = .add(groupId: group.id)
                } label: {
                    Label("Add item", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("debt.addItem")
                Spacer()
                Button(role: .destructive) {
                    pendingGroupDelete = group
                } label: {
                    Text("Delete group")
                        .font(.caption)
                        .foregroundStyle(Color.dangerText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        // Identifiers go on the controls, never on the card: SwiftUI pushes a
        // container's identifier onto every descendant and would rename the
        // buttons inside this one.
    }

    /// A company and what it is owed. One product renders as the row it always
    /// was; several nest under a single heading with the company's own total,
    /// so "Google" is said once and can be read as one relationship instead of
    /// three unrelated lines that happen to share a word.
    @ViewBuilder
    private func vendorRows(_ vendor: DebtVendorSummary, monthName: String) -> some View {
        if vendor.isMulti {
            Button {
                sheet = .charges(DebtChargesTarget(vendor: vendor))
            } label: {
                DebtVendorHeaderRow(vendor: vendor, monthName: monthName)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("debt.vendor")

            ForEach(vendor.items) { row in
                Button {
                    sheet = .charges(DebtChargesTarget(row: row))
                } label: {
                    DebtItemRow(row: row, nested: true, vendorName: vendor.name, monthName: monthName)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { sheet = .edit(row) }
                    Button("Delete", role: .destructive) { pendingItemDelete = row }
                }
            }
        } else if let row = vendor.items.first {
            Button {
                sheet = .charges(DebtChargesTarget(row: row))
            } label: {
                DebtItemRow(row: row, monthName: monthName)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Edit") { sheet = .edit(row) }
                Button("Delete", role: .destructive) { pendingItemDelete = row }
            }
        }
    }

    private var addGroupButton: some View {
        Button {
            showingAddGroup = true
        } label: {
            Label("Add a group", systemImage: "folder.badge.plus")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("debt.addGroup")
    }

    private var starterCard: some View {
        SurfaceCard {
            Text("What are you paying every month?")
                .font(.title3.weight(.bold))
            Text("Group your subscriptions, loans and buy-now-pay-later plans, and Spendcap will total each group and show what has already posted this month.")
                .font(.subheadline)
                .foregroundStyle(Color.secondaryText)
            Button {
                Task { await model.seed() }
            } label: {
                if model.isSeeding {
                    ProgressView()
                } else {
                    Text("Start with four groups")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("debt.seed")

            Button("Add my own group") { showingAddGroup = true }
                .font(.subheadline)
                .accessibilityIdentifier("debt.addGroup")
        }
    }
}

/// A company with more than one obligation: its name, said once, and what it
/// costs in total. The products are listed under it — this is a heading, not a
/// row that can be edited, and tapping it opens every charge the company made.
struct DebtVendorHeaderRow: View {
    let vendor: DebtVendorSummary
    var monthName: String = "this month"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vendor.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(vendor.txnCount > 0 ? Color.green : Color.secondaryText)
            }
            Spacer(minLength: 8)
            Text(BudgetMath.dollars(vendor.plannedCents))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        // "items", not "subscriptions": a company heading now forms on its own
        // in any group, and Apple in Transfers is not two subscriptions.
        let plans = "\(vendor.items.count) items"
        guard vendor.hasTrackedItems else { return plans }
        guard vendor.txnCount > 0 else {
            return monthName == "this month"
                ? "\(plans) · nothing seen yet this month"
                : "\(plans) · nothing seen \(monthName)"
        }
        let paid = BudgetMath.dollars(vendor.paidCents)
        return "\(plans) · \(paid) paid · \(vendor.txnCount) charge\(vendor.txnCount == 1 ? "" : "s")"
    }
}

/// One obligation: what it is, what it costs, and — when it can be seen in the
/// linked account — what has actually posted this month.
///
/// Nested under a company heading the name is dropped, because the heading has
/// just said it: "Google / Google · youtube tv" is the repetition the grouping
/// exists to remove. The note carries the row on its own, and an item with no
/// note falls back to the name rather than rendering nameless.
struct DebtItemRow: View {
    let row: DebtSummaryRow
    var nested: Bool = false
    /// The heading this row sits under, when nested.
    var vendorName: String? = nil
    var monthName: String = "this month"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(nested ? .subheadline : .body.weight(.medium))
                    .foregroundStyle(nested ? Color.secondaryText : Color.primary)
                if let note = row.note, !note.isEmpty, note != title {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 8)
            Text(BudgetMath.dollars(row.monthlyCents))
                .font(nested ? .subheadline.weight(.medium) : .body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
        .padding(.leading, nested ? 12 : 0)
        .contentShape(Rectangle())
    }

    /// Nested under a company the row says what it is: its own name when
    /// that differs from the heading ("YouTube TV" under Google), otherwise
    /// its note ("workspace" on a row the user named "Google").
    private var title: String {
        let name = row.itemName ?? "—"
        guard nested else { return name }
        let sameAsHeading = vendorName.map {
            DebtMath.vendorKey($0, fallback: row.id) == DebtMath.vendorKey(name, fallback: row.id)
        } ?? true
        if sameAsHeading, let note = row.note, !note.isEmpty { return note }
        return name
    }

    private var statusText: String {
        guard row.isTracked else { return "Not tracked" }
        if row.txnCount == 0 {
            return monthName == "this month" ? "Not seen yet this month" : "Not seen \(monthName)"
        }
        let paid = BudgetMath.dollars(row.paidCents)
        return row.txnCount == 1 ? "\(paid) paid" : "\(paid) paid · \(row.txnCount) charges"
    }

    private var statusColor: Color {
        // Accent, not system green: #34C759 is 2.2:1 as text on a white card.
        guard row.isTracked else { return .secondaryText }
        return row.txnCount == 0 ? .secondaryText : .accentColor
    }
}
