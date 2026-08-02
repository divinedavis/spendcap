import SwiftUI

// Budget by category — the spreadsheet view: a planned amount per line, what
// actually landed against it this month and last, and how far over each one is.
//
// The screen deliberately shows an Uncategorized line. Plaid's categories are a
// first pass, not an answer, so some spending will always be sitting outside
// the budget; a total that quietly excluded it would be the most misleading
// number on the screen.

@MainActor
final class CategoriesViewModel: ObservableObject {
    @Published var months: [CategoryMonth] = []
    @Published var selectedPeriod: Date?
    @Published var isLoading = false
    @Published var isSeeding = false
    @Published var errorMessage: String?

    /// True once loaded and the user has no categories at all — the only state
    /// where seeding a starter budget is offered.
    var isEmpty: Bool {
        !isLoading && months.allSatisfy { $0.rows.allSatisfy(\.isUncategorized) }
    }

    var selected: CategoryMonth? {
        months.first { $0.period == selectedPeriod } ?? months.first
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let rows = try await SpendService.shared.categorySpend(monthsBack: 2)
            months = CategoryMath.months(rows: rows)
            if selectedPeriod == nil || !months.contains(where: { $0.period == selectedPeriod }) {
                selectedPeriod = months.first?.period
            }
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
        }
    }

    func seed() async {
        isSeeding = true
        defer { isSeeding = false }
        do {
            _ = try await SpendService.shared.seedStarterBudget()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CategoriesView: View {
    /// Presented as a sheet rather than pushed, so it needs its own dismissal.
    var isModal = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CategoriesViewModel()

    var body: some View {
        ZStack {
            DashboardBackground()
            ScrollView {
                VStack(spacing: 14) {
                    if model.months.count > 1 { monthPicker }

                    if model.isEmpty {
                        starterCard
                    } else if let month = model.selected {
                        summaryCard(month)
                        categoriesCard(month)
                    } else if model.isLoading {
                        ProgressView().padding(.top, 40)
                    }

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("categories.done")
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    // MARK: - Month picker

    private var monthPicker: some View {
        Picker("Month", selection: Binding(
            get: { model.selectedPeriod ?? model.months.first?.period ?? Date() },
            set: { model.selectedPeriod = $0 }
        )) {
            ForEach(model.months) { month in
                Text(month.shortLabel).tag(month.period)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("categories.month")
    }

    // MARK: - Summary

    private func summaryCard(_ month: CategoryMonth) -> some View {
        SurfaceCard {
            HStack(alignment: .firstTextBaseline) {
                Text(month.label)
                    .font(.title3.weight(.bold))
                Spacer(minLength: 12)
                Text(BudgetMath.wholeDollars(month.spentCents))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("categories.actual")
            }

            HStack(alignment: .firstTextBaseline) {
                Text(month.isCurrent ? "So far this month" : "Spent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("of \(BudgetMath.wholeDollars(month.plannedCents)) planned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                verdictChip(
                    count: month.overCount,
                    label: month.overCount == 1 ? "line over" : "lines over",
                    tint: month.overCount > 0 ? .red : .green
                )
                if month.uncategorizedCents > 0 {
                    verdictChip(
                        count: nil,
                        label: "\(BudgetMath.wholeDollars(month.uncategorizedCents)) unbudgeted",
                        tint: .orange
                    )
                }
                Spacer()
            }
        }
    }

    private func verdictChip(count: Int?, label: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(count.map { "\($0) \(label)" } ?? label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Category rows

    private func categoriesCard(_ month: CategoryMonth) -> some View {
        SurfaceCard {
            SectionHeader(title: "By category", actionSystemImage: nil, action: nil)

            ForEach(Array(month.rows.enumerated()), id: \.element.id) { index, row in
                NavigationLink {
                    CategoryDetailView(row: row, period: month.period) {
                        Task { await model.load() }
                    }
                } label: {
                    categoryRow(row)
                }
                .buttonStyle(.plain)
                if index < month.rows.count - 1 { Divider() }
            }
        }
    }

    private func categoryRow(_ row: CategorySpendRow) -> some View {
        CategoryLineRow(row: row, showsChevron: true)
    }

    // MARK: - Empty state

    private var starterCard: some View {
        PromptCard(
            icon: "list.bullet.rectangle",
            tint: .blue,
            title: "Budget by category",
            message: "Start from a standard set of lines — food, transport, rent, debts — with your transactions already routed into them. Every amount is yours to change.",
            ctaTitle: model.isSeeding ? "Setting up\u{2026}" : "Create a starter budget"
        ) {
            Task { await model.seed() }
        }
        .disabled(model.isSeeding)
        .accessibilityIdentifier("categories.seed")
    }
}

// MARK: - Shared row

/// One budget line: spent against planned, with the bar carrying the verdict.
/// Shared by the Budget screen and the Months widget so the two can't drift
/// into showing the same line differently.
struct CategoryLineRow: View {
    let row: CategorySpendRow
    var showsChevron = false

    private var barTint: Color {
        if row.isOver { return .red }
        return row.progress >= 0.8 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.categoryName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(row.isUncategorized ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(BudgetMath.wholeDollars(row.spentCents))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(row.isOver ? Color.red : Color.primary)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if row.plannedCents > 0 {
                ProgressView(value: row.progress)
                    .tint(barTint)

                HStack {
                    Text("of \(BudgetMath.wholeDollars(row.plannedCents)) planned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.isOver
                         ? "\(BudgetMath.wholeDollars(-row.remainingCents)) over"
                         : "\(BudgetMath.wholeDollars(row.remainingCents)) left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.isOver ? .red : .secondary)
                }
            } else {
                Text(row.isUncategorized
                     ? "\(row.txnCount) transaction\(row.txnCount == 1 ? "" : "s") that no category claims"
                     : "No planned amount set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

/// One category in one month: what it planned, what landed, and every
/// transaction behind the number — which is the only way to spot a merchant
/// filed in the wrong place.
struct CategoryDetailView: View {
    let row: CategorySpendRow
    let period: Date
    let onChange: () -> Void

    /// One sheet modifier, several destinations — two `.sheet(isPresented:)`
    /// on one view silently leaves the second one dead.
    private enum Sheet: Identifiable {
        case editLine
        case merchant(String)

        var id: String {
            switch self {
            case .editLine: return "edit"
            case .merchant(let name): return "merchant-\(name)"
            }
        }
    }

    @State private var transactions: [BankTransaction] = []
    @State private var isLoading = true
    @State private var sheet: Sheet?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Spent", value: BudgetMath.dollars(row.spentCents))
                if row.plannedCents > 0 {
                    LabeledContent("Planned", value: BudgetMath.dollars(row.plannedCents))
                    LabeledContent(row.isOver ? "Over by" : "Left") {
                        Text(BudgetMath.dollars(abs(row.remainingCents)))
                            .foregroundStyle(row.isOver ? .red : .primary)
                    }
                }
            } header: {
                Text(period.formatted(.dateTime.month(.wide).year()))
            }

            Section {
                if isLoading {
                    ProgressView()
                } else if transactions.isEmpty {
                    Text("Nothing landed here this month.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transactions) { txn in
                        Button {
                            sheet = .merchant(txn.displayName)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(txn.displayName)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(txn.date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(BudgetMath.dollars(txn.amountCents))
                                    .font(.body.monospacedDigit())
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Text("Transactions")
            } footer: {
                if !transactions.isEmpty {
                    Text("Tap a transaction to move that merchant to another line. Past months move with it.")
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle(row.categoryName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let id = row.categoryId {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { sheet = .editLine }
                        .accessibilityIdentifier("category.edit")
                        .id(id)
                }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .editLine:
                CategoryEditView(row: row) {
                    onChange()
                    sheet = nil
                }
            case .merchant(let name):
                MerchantRuleView(merchant: name) {
                    sheet = nil
                    onChange()
                    Task { await load() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            transactions = try await SpendService.shared.categoryTransactions(
                categoryId: row.categoryId, period: period
            )
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
        }
    }
}

/// Rename a line or change what it plans to spend.
struct CategoryEditView: View {
    @Environment(\.dismiss) private var dismiss

    let row: CategorySpendRow
    let onSave: () -> Void

    @State private var name: String
    @State private var plannedText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(row: CategorySpendRow, onSave: @escaping () -> Void) {
        self.row = row
        self.onSave = onSave
        _name = State(initialValue: row.categoryName)
        _plannedText = State(initialValue: String(format: "%.0f", Double(row.plannedCents) / 100))
    }

    private var plannedCents: Int? {
        let cleaned = plannedText
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Food", text: $name)
                        .accessibilityIdentifier("category.name")
                }
                Section {
                    HStack {
                        Text("$")
                        TextField("600", text: $plannedText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("category.planned")
                    }
                } header: {
                    Text("Planned each month")
                } footer: {
                    Text("What this line is meant to cost. Months are measured against it.")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Edit line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(plannedCents == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                        .accessibilityIdentifier("category.save")
                }
            }
        }
    }

    private func save() async {
        guard let id = row.categoryId, let cents = plannedCents else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await SpendService.shared.updateCategory(
                id: id,
                name: name.trimmingCharacters(in: .whitespaces),
                plannedCents: cents
            )
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

/// Pick the budget line a merchant belongs to.
///
/// The rollups apply rules at read time, so choosing here re-buckets every
/// month on record, not just the one being looked at. That is the point: a
/// merchant filed wrongly was filed wrongly in April too.
struct MerchantRuleView: View {
    @Environment(\.dismiss) private var dismiss

    let merchant: String
    let onSave: () -> Void

    @State private var categories: [BudgetCategory] = []
    @State private var currentCategoryId: UUID?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading {
                        ProgressView()
                    } else {
                        ForEach(categories) { category in
                            Button {
                                Task { await assign(category.id) }
                            } label: {
                                HStack {
                                    Text(category.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if category.id == currentCategoryId {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .disabled(isSaving)
                        }
                    }
                } header: {
                    Text("Always put \(merchant) in")
                } footer: {
                    Text("Every month on record moves, not just this one.")
                }

                if currentCategoryId != nil {
                    Section {
                        Button("Use the bank's category instead", role: .destructive) {
                            Task { await clear() }
                        }
                        .disabled(isSaving)
                        .accessibilityIdentifier("merchant.clearRule")
                    } footer: {
                        Text("Drops the rule. \(merchant) falls back to however its bank category is mapped, or to Uncategorized.")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle(merchant)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            categories = try await SpendService.shared.categories()
            currentCategoryId = try await SpendService.shared.merchantRule(merchant)?.categoryId
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
        }
    }

    private func assign(_ categoryId: UUID) async {
        isSaving = true
        errorMessage = nil
        do {
            try await SpendService.shared.assignMerchant(merchant, to: categoryId)
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }

    private func clear() async {
        isSaving = true
        errorMessage = nil
        do {
            try await SpendService.shared.clearMerchantRule(merchant)
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
