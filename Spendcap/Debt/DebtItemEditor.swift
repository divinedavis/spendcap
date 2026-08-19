import SwiftUI

/// Add or edit one obligation. One sheet for both, because the fields are the
/// same and two near-identical forms drift apart.
///
/// The "seen in my account as" field is what turns a typed plan into a tracked
/// one: a case-insensitive substring of the transaction's display name, the
/// same name the budget rollups match on. Optional on purpose — a 401k loan
/// repaid out of payroll never appears in checking, and forcing a match string
/// would make the item lie about being unpaid.
///
/// The amount qualifier exists for the case that broke the first draft of this
/// screen: three Google rows (YouTube TV, YouTube Premium, Workspace) whose
/// descriptors are identical. Without it every Google charge piles onto
/// whichever row sorts first. With it, "GOOGLE" plus the price picks out one.
struct DebtItemEditor: View {
    @Environment(\.dismiss) private var dismiss

    let groups: [DebtGroup]
    let groupId: UUID
    /// Nil creates; non-nil edits that row.
    let row: DebtSummaryRow?
    let onSave: () async -> Void

    @State private var selectedGroupId: UUID
    @State private var name: String
    @State private var note: String
    @State private var plannedText: String
    @State private var matchValue: String
    @State private var qualifyByAmount: Bool
    @State private var matchAmountText: String
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    init(groups: [DebtGroup], groupId: UUID, row: DebtSummaryRow?, onSave: @escaping () async -> Void) {
        self.groups = groups
        self.groupId = groupId
        self.row = row
        self.onSave = onSave
        _selectedGroupId = State(initialValue: row?.groupId ?? groupId)
        _name = State(initialValue: row?.itemName ?? "")
        _note = State(initialValue: row?.note ?? "")
        _plannedText = State(initialValue: row.map { Self.editableAmount($0.plannedCents) } ?? "")
        _matchValue = State(initialValue: row?.matchValue ?? "")
        _qualifyByAmount = State(initialValue: row?.matchAmountCents != nil)
        _matchAmountText = State(initialValue: row?.matchAmountCents.map(Self.editableAmount) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What is it") {
                    TextField("Google", text: $name)
                        .accessibilityIdentifier("debtItem.name")
                    TextField("youtube tv", text: $note)
                        .accessibilityIdentifier("debtItem.note")
                }

                Section {
                    HStack {
                        Text("$")
                        TextField("0", text: $plannedText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("debtItem.planned")
                    }
                } header: {
                    Text("Every month")
                } footer: {
                    Text("Group and overall totals are the sum of these, so they can never disagree with the rows above them.")
                }

                if groups.count > 1 {
                    Section("Group") {
                        Picker("Group", selection: $selectedGroupId) {
                            ForEach(groups) { group in
                                Text(group.name).tag(group.id)
                            }
                        }
                        .accessibilityIdentifier("debtItem.group")
                    }
                }

                Section {
                    TextField("GOOGLE", text: $matchValue)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("debtItem.match")

                    if !trimmedMatch.isEmpty {
                        Toggle("Only this exact amount", isOn: $qualifyByAmount)
                            .accessibilityIdentifier("debtItem.qualify")
                        if qualifyByAmount {
                            HStack {
                                Text("$")
                                TextField("0", text: $matchAmountText)
                                    .keyboardType(.decimalPad)
                                    .accessibilityIdentifier("debtItem.matchAmount")
                            }
                        }
                    }
                } header: {
                    Text("Seen in my account as")
                } footer: {
                    Text("Any part of how the charge reads on your statement. Leave it blank if this never posts through the linked account — the item still counts toward the totals, it just won't show a paid figure. Turn on the amount when several items share a name, like three Google subscriptions.")
                }

                // Editing only: there is nothing to delete before the row
                // exists. A visible button rather than only the row's context
                // menu — a long press is not something anyone discovers, and
                // the cards on the Debt screen are not a List, so there is no
                // swipe-to-delete to fall back on.
                if row != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("Delete item")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(isDeleting || isSaving)
                        .accessibilityIdentifier("debtItem.delete")
                    } footer: {
                        Text("Removes this row and takes its amount out of the group's total. Nothing is removed from your transaction history.")
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .confirmationDialog("Delete \(row?.itemName ?? "this item")?",
                                isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) { }
            }
            .navigationTitle(row == nil ? "New item" : (row?.itemName ?? "Item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(row == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                        .accessibilityIdentifier("debtItem.save")
                }
            }
        }
    }

    // MARK: - Input

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedMatch: String { matchValue.trimmingCharacters(in: .whitespaces) }

    private var plannedCents: Int? { Self.cents(from: plannedText, blankIsZero: true) }

    /// Nil when the qualifier is off, or when it is on and the field is not yet
    /// a usable amount — the second case has to block saving, or the item would
    /// silently save as unqualified and quietly claim its siblings' charges.
    private var matchAmountCents: Int? {
        guard qualifyByAmount, !trimmedMatch.isEmpty else { return nil }
        return Self.cents(from: matchAmountText, blankIsZero: false)
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, plannedCents != nil else { return false }
        if qualifyByAmount && !trimmedMatch.isEmpty {
            guard let cents = matchAmountCents, cents > 0 else { return false }
        }
        return true
    }

    private static func cents(from text: String, blankIsZero: Bool) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return blankIsZero ? 0 : nil }
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }

    /// Plain digits for a text field — `BudgetMath.dollars` adds a currency
    /// symbol and separators the decimal pad cannot reproduce.
    private static func editableAmount(_ cents: Int) -> String {
        cents % 100 == 0 ? String(cents / 100) : String(format: "%.2f", Double(cents) / 100)
    }

    private func delete() async {
        guard let id = row?.itemId else { return }
        isDeleting = true
        errorMessage = nil
        do {
            try await SpendService.shared.deleteDebtItem(id: id, matchValue: row?.matchValue)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isDeleting = false
        }
    }

    private func save() async {
        guard let cents = plannedCents, !trimmedName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        let match = trimmedMatch.isEmpty ? nil : trimmedMatch
        let amount = matchAmountCents
        do {
            if let existing = row, let id = existing.itemId {
                try await SpendService.shared.updateDebtItem(
                    id: id, groupId: selectedGroupId, name: trimmedName,
                    note: note, plannedCents: cents,
                    matchValue: match, matchAmountCents: amount)
            } else {
                try await SpendService.shared.createDebtItem(
                    groupId: selectedGroupId, name: trimmedName,
                    note: note, plannedCents: cents,
                    matchValue: match, matchAmountCents: amount)
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
