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

            async let rows = SpendService.shared.debtSummary()
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

        var id: String {
            switch self {
            case .add(let groupId): return "add-\(groupId)"
            case .edit(let row): return "edit-\(row.id)"
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
            .task { await model.load() }
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

    private var totalCard: some View {
        SurfaceCard {
            Text("Every month")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(BudgetMath.dollars(model.summary.plannedCents))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .accessibilityIdentifier("debt.total")
            Text("across \(model.summary.itemCount) item\(model.summary.itemCount == 1 ? "" : "s") in \(model.summary.groups.count) group\(model.summary.groups.count == 1 ? "" : "s")")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if model.summary.hasTrackedItems {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paid so far this month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(BudgetMath.dollars(model.summary.paidCents))
                            .font(.headline)
                            .accessibilityIdentifier("debt.paid")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Still expected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(BudgetMath.dollars(model.summary.outstandingCents))
                            .font(.headline)
                    }
                }
                Text("Paid counts only the items with a match set, so it can be smaller than the total above.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    .accessibilityIdentifier("debt.groupTotal")
            }

            if group.isEmpty {
                Text("Nothing in this group yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(group.items) { row in
                    Button {
                        sheet = .edit(row)
                    } label: {
                        DebtItemRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit") { sheet = .edit(row) }
                        Button("Delete", role: .destructive) { pendingItemDelete = row }
                    }

                    if row.id != group.items.last?.id {
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
                }
                .accessibilityIdentifier("debt.addItem")
                Spacer()
                Button(role: .destructive) {
                    pendingGroupDelete = group
                } label: {
                    Text("Delete group")
                        .font(.caption)
                }
            }
        }
        // Identifiers go on the controls, never on the card: SwiftUI pushes a
        // container's identifier onto every descendant and would rename the
        // buttons inside this one.
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
                .foregroundStyle(.secondary)
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

/// One obligation: what it is, what it costs, and — when it can be seen in the
/// linked account — what has actually posted this month.
struct DebtItemRow: View {
    let row: DebtSummaryRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.itemName ?? "—")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if let note = row.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 8)
            Text(BudgetMath.dollars(row.plannedCents))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var statusText: String {
        guard row.isTracked else { return "Not tracked" }
        if row.txnCount == 0 { return "Not seen yet this month" }
        let paid = BudgetMath.dollars(row.paidCents)
        return row.txnCount == 1 ? "\(paid) paid" : "\(paid) paid · \(row.txnCount) charges"
    }

    private var statusColor: Color {
        guard row.isTracked else { return .secondary }
        return row.txnCount == 0 ? .secondary : .green
    }
}
