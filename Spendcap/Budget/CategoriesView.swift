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

    /// Deleting a line cascades its rules, so the transactions it claimed fall
    /// back to Uncategorized on the next read. The transactions themselves are
    /// untouched — this removes a bucket, not history.
    func delete(_ row: CategorySpendRow) async {
        guard let id = row.categoryId else { return }
        do {
            try await SpendService.shared.deleteCategory(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
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
    @State private var sheet: Sheet?
    @State private var pendingDelete: CategorySpendRow?

    /// Add and edit share one modifier — several `.sheet(isPresented:)` on a
    /// view risks one that never presents.
    enum Sheet: Identifiable {
        case edit(CategorySpendRow)
        case add

        var id: String {
            switch self {
            case .edit(let row): return "edit-\(row.id)"
            case .add: return "add"
            }
        }
    }

    // A List, not the card stack the rest of the app uses: swipe-to-delete is
    // a List affordance, and this is the screen where lines are managed.
    var body: some View {
        List {
            if model.months.count > 1 {
                Section { monthPicker }
            }

            if model.isEmpty {
                Section { starterCard }
            } else if let month = model.selected {
                Section { summaryRows(month) } header: { Text(month.label) }

                Section {
                    ForEach(month.rows) { row in
                        Button {
                            sheet = .edit(row)
                        } label: {
                            CategoryLineRow(row: row, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("categories.row")
                        .swipeActions(edge: .trailing) {
                            // Uncategorized is not a line anyone created, so
                            // there is nothing there to delete.
                            if !row.isUncategorized {
                                Button(role: .destructive) {
                                    pendingDelete = row
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("By category")
                } footer: {
                    Text("Swipe a line to delete it. Its transactions are re-matched against your other rules, and land in Uncategorized if nothing else claims them. Nothing is removed from your history.")
                }

                Section {
                    Button {
                        sheet = .add
                    } label: {
                        Label("Add a line", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("categories.add")
                }
            } else if model.isLoading {
                Section { ProgressView() }
            }

            if let errorMessage = model.errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.callout) }
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
        .sheet(item: $sheet) { which in
            switch which {
            case .edit(let row):
                CategoryEditView(row: row) {
                    Task { await model.load() }
                }
            case .add:
                CategoryCreateView {
                    Task { await model.load() }
                }
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
                    Task { await model.delete(row) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let row = pendingDelete {
                // Deliberately not "they move to Uncategorized": deleting the
                // line drops its rules, and the transactions are then matched
                // against every remaining rule. A broad merchant rule on
                // another line will claim them — measured, not theorised.
                Text("The line and its rules go. Its \(row.txnCount) transaction\(row.txnCount == 1 ? "" : "s") this month are re-matched against your other rules, and land in Uncategorized if nothing else claims them. Nothing is deleted from your history.")
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    /// The month's totals, as List rows rather than a card.
    @ViewBuilder
    private func summaryRows(_ month: CategoryMonth) -> some View {
        LabeledContent(month.isCurrent ? "Spent so far" : "Spent") {
            Text(BudgetMath.wholeDollars(month.spentCents))
                .font(.body.weight(.semibold).monospacedDigit())
                .accessibilityIdentifier("categories.actual")
        }
        LabeledContent("Planned", value: BudgetMath.wholeDollars(month.plannedCents))
        if month.overCount > 0 {
            LabeledContent("Lines over") {
                Text("\(month.overCount)").foregroundStyle(.red)
            }
        }
        if month.uncategorizedCents > 0 {
            LabeledContent("Unbudgeted") {
                Text(BudgetMath.wholeDollars(month.uncategorizedCents)).foregroundStyle(.orange)
            }
        }
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
                // No kind icon here on purpose (user request, 2026-08-12):
                // the tag is data for finding lines by what they are, not
                // decoration on every row. It's visible in the edit sheet.
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

/// Rename a line or change what it plans to spend.
struct CategoryEditView: View {
    @Environment(\.dismiss) private var dismiss

    let row: CategorySpendRow
    let onSave: () -> Void

    @State private var name: String
    @State private var plannedText: String
    @State private var kind: CategoryKind?
    @State private var transactions: [CategoryTransaction] = []
    @State private var isLoadingTransactions = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(row: CategorySpendRow, onSave: @escaping () -> Void) {
        self.row = row
        self.onSave = onSave
        _name = State(initialValue: row.categoryName)
        _plannedText = State(initialValue: String(format: "%.0f", Double(row.plannedCents) / 100))
        _kind = State(initialValue: row.kind)
    }

    /// The Uncategorized line has no name or plan to edit — but its
    /// transactions are the whole reason to open it, so it still opens.
    private var isEditable: Bool { row.categoryId != nil }

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
                if isEditable {
                    Section("Name") {
                        TextField("Food", text: $name)
                            .accessibilityIdentifier("category.name")
                    }
                    // The name is whatever the user calls the line; the type
                    // says what it *is*, so rent or food is findable as a
                    // field rather than guessed from the wording.
                    Section {
                        Picker("Type", selection: $kind) {
                            Text("None").tag(CategoryKind?.none)
                            ForEach(CategoryKind.allCases) { option in
                                Label(option.label, systemImage: option.systemImage)
                                    .tag(CategoryKind?.some(option))
                            }
                        }
                        .accessibilityIdentifier("category.kind")
                    } footer: {
                        Text("Tags this line as rent, food, transportation and so on — in addition to its name.")
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
                }

                // The transactions behind the number, which is the only way to
                // see why a line is over and to spot a merchant filed wrongly.
                Section {
                    if isLoadingTransactions {
                        ProgressView()
                    } else if transactions.isEmpty {
                        Text("Nothing landed here this month.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transactions) { txn in
                            NavigationLink {
                                TransactionDetailView(transaction: txn, lineName: row.categoryName) {
                                    onSave()
                                    Task { await loadTransactions() }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(txn.displayName)
                                            .lineLimit(1)
                                        Text(txn.date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(BudgetMath.dollars(txn.amountCents))
                                            .font(.body.monospacedDigit())
                                        if txn.pending {
                                            Text("Pending")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .accessibilityIdentifier("category.transaction")
                        }
                    }
                } header: {
                    HStack {
                        Text(periodLabel)
                        Spacer()
                        Text(BudgetMath.dollars(row.spentCents))
                            .foregroundStyle(row.isOver ? .red : .secondary)
                    }
                } footer: {
                    if !transactions.isEmpty {
                        Text("Tap a transaction for its details, including what the bank actually called it.")
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(isEditable ? "Edit line" : row.categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isEditable ? "Cancel" : "Done") { dismiss() }
                }
                if isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .disabled(plannedCents == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                            .accessibilityIdentifier("category.save")
                    }
                }
            }
            .task { await loadTransactions() }
        }
    }

    private var periodLabel: String {
        row.periodDate?.formatted(.dateTime.month(.wide).year()) ?? "This month"
    }

    private func loadTransactions() async {
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        guard let period = row.periodDate else { return }
        do {
            transactions = try await SpendService.shared.categoryTransactions(
                categoryId: row.categoryId, period: period
            )
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
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
                plannedCents: cents,
                kind: kind
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

/// One transaction, in full.
///
/// The bank's own description is the point of this screen. Plaid's merchant
/// name is a tidy guess — "Amazon", "Microsoft" — and a tidy guess is exactly
/// what you cannot budget against when the charge is $5.00 and you have no
/// memory of it. `name` is what actually appeared on the statement.
struct TransactionDetailView: View {
    let transaction: CategoryTransaction
    let lineName: String
    let onChange: () -> Void

    @State private var showingMove = false

    var body: some View {
        List {
            Section {
                LabeledContent("Amount") {
                    Text(BudgetMath.dollars(transaction.amountCents))
                        .font(.body.weight(.semibold).monospacedDigit())
                }
                LabeledContent("Date", value: transaction.date)
                if transaction.authorizedDifferentFromPosted, let authorized = transaction.authorizedDate {
                    LabeledContent("Authorised", value: authorized)
                }
                LabeledContent("Status", value: transaction.pending ? "Pending" : "Posted")
            } footer: {
                if transaction.authorizedDifferentFromPosted {
                    Text("Authorised on one day, posted on another. Budgets count it on the posted date.")
                } else if transaction.pending {
                    Text("Still pending, so the amount can change before it posts.")
                }
            }

            Section("On the statement") {
                Text(transaction.name)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            Section("Filed as") {
                LabeledContent("Budget line", value: lineName)
                if let plaid = transaction.plaidCategoryLabel {
                    LabeledContent("Bank category", value: plaid)
                }
                if let merchant = transaction.merchantName, !merchant.isEmpty {
                    LabeledContent("Merchant", value: merchant)
                }
                if let account = transaction.accountLabel {
                    LabeledContent("Account", value: account)
                }
            }

            Section {
                Button {
                    showingMove = true
                } label: {
                    Label("Move \(transaction.displayName) to another line", systemImage: "arrow.right.arrow.left")
                }
                .accessibilityIdentifier("transaction.move")
            } footer: {
                Text("Moves every transaction from this merchant, in every month on record.")
            }
        }
        .navigationTitle(transaction.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingMove) {
            // The rule matches on the stable part of the descriptor, not the
            // exact string — a transfer's date/reference number is unique per
            // transaction, and a rule written from it dies with the month.
            MerchantRuleView(merchant: TransactionNaming.stableMatchValue(from: transaction.displayName)) {
                showingMove = false
                onChange()
            }
        }
    }
}

/// Add a budget line.
struct CategoryCreateView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: () -> Void

    @State private var name = ""
    @State private var plannedText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var plannedCents: Int? {
        let cleaned = plannedText
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Blank is a valid plan of zero — a line can exist to be watched
        // before it is budgeted.
        if cleaned.isEmpty { return 0 }
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Subscriptions", text: $name)
                        .accessibilityIdentifier("category.newName")
                }
                Section {
                    HStack {
                        Text("$")
                        TextField("0", text: $plannedText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("category.newPlanned")
                    }
                } header: {
                    Text("Planned each month")
                } footer: {
                    Text("Leave blank to start at zero. Nothing lands in a new line until you move a merchant into it.")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(trimmedName.isEmpty || plannedCents == nil || isSaving)
                        .accessibilityIdentifier("category.create")
                }
            }
        }
    }

    private func save() async {
        guard let cents = plannedCents, !trimmedName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await SpendService.shared.createCategory(name: trimmedName, plannedCents: cents)
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
