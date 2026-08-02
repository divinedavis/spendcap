import SwiftUI

struct BudgetView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var dailyLimitText: String
    @State private var monthlyLimitText: String
    @State private var warnPct: Int
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// Which cap the sheet opens focused on. Months opens it on the monthly
    /// one; Home on the daily one.
    let focus: Focus
    let onSave: (Budget) -> Void

    enum Focus { case daily, monthly }

    init(budget: Budget, focus: Focus = .daily, onSave: @escaping (Budget) -> Void) {
        _dailyLimitText = State(initialValue: String(format: "%.2f", Double(budget.dailyLimitCents) / 100))
        _monthlyLimitText = State(initialValue: budget.monthlyLimitCents
            .map { String(format: "%.2f", Double($0) / 100) } ?? "")
        _warnPct = State(initialValue: budget.warnPct)
        self.focus = focus
        self.onSave = onSave
    }

    private func cents(from text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else { return nil }
        return Int((value * 100).rounded())
    }

    private var parsedCents: Int? { cents(from: dailyLimitText) }

    /// Blank is a valid monthly cap — it means "go back to deriving it from the
    /// daily one" — so only a non-empty unparseable value blocks saving.
    private var monthlyIsValid: Bool {
        monthlyLimitText.trimmingCharacters(in: .whitespaces).isEmpty || cents(from: monthlyLimitText) != nil
    }

    /// What the daily cap works out to over an average month, for comparison
    /// against whatever monthly figure is being typed.
    private var derivedMonthlyLabel: String {
        let days = Calendar(identifier: .gregorian)
            .range(of: .day, in: .month, for: Date())?.count ?? 30
        let cents = (parsedCents ?? 0) * days
        return BudgetMath.dollars(cents)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("$")
                        TextField("50.00", text: $dailyLimitText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("budget.dailyLimit")
                    }
                } header: {
                    Text("Daily spending cap")
                } footer: {
                    Text("Drives the push alerts. Nothing else changes when you edit it.")
                }

                Section {
                    HStack {
                        Text("$")
                        TextField(derivedMonthlyLabel
                                    .replacingOccurrences(of: "$", with: "")
                                    .replacingOccurrences(of: ",", with: ""),
                                  text: $monthlyLimitText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("budget.monthlyLimit")
                        if !monthlyLimitText.isEmpty {
                            Button {
                                monthlyLimitText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("budget.clearMonthly")
                            .accessibilityLabel("Clear monthly cap")
                        }
                    }
                } header: {
                    Text("Monthly spending cap")
                } footer: {
                    // A month judged by daily-cap × days goes red the first time
                    // rent lands, which is why this is worth setting separately.
                    Text(monthlyLimitText.isEmpty
                         ? "Leave blank to use your daily cap across the month (\(derivedMonthlyLabel) this month). Set a figure to judge whole months against it on the Months tab."
                         : "Months are measured against this on the Months tab. Your daily cap works out to \(derivedMonthlyLabel) this month.")
                }

                Section {
                    Picker("Warn me at", selection: $warnPct) {
                        ForEach([50, 60, 70, 80, 90], id: \.self) { pct in
                            Text("\(pct)% of cap").tag(pct)
                        }
                    }
                    .accessibilityIdentifier("budget.warnPct")
                } footer: {
                    Text("You'll get one heads-up push when you cross this, and another if you go over the full cap.")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(focus == .monthly ? "Monthly Cap" : "Spending Caps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(parsedCents == nil || !monthlyIsValid || isSaving)
                        .accessibilityIdentifier("budget.save")
                }
            }
        }
    }

    private func save() async {
        guard let dailyCents = parsedCents else { return }
        isSaving = true
        errorMessage = nil
        let budget = Budget(
            dailyLimitCents: dailyCents,
            warnPct: warnPct,
            monthlyLimitCents: cents(from: monthlyLimitText)
        )
        do {
            try await SpendService.shared.updateBudget(budget)
            onSave(budget)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
