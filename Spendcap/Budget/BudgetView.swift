import SwiftUI

struct BudgetView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var dailyLimitText: String
    @State private var warnPct: Int
    @State private var isSaving = false
    @State private var errorMessage: String?

    let onSave: (Budget) -> Void

    init(budget: Budget, onSave: @escaping (Budget) -> Void) {
        _dailyLimitText = State(initialValue: String(format: "%.2f", Double(budget.dailyLimitCents) / 100))
        _warnPct = State(initialValue: budget.warnPct)
        self.onSave = onSave
    }

    private var parsedCents: Int? {
        guard let value = Double(dailyLimitText.replacingOccurrences(of: "$", with: "")),
              value > 0 else { return nil }
        return Int((value * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Daily spending cap") {
                    HStack {
                        Text("$")
                        TextField("50.00", text: $dailyLimitText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("budget.dailyLimit")
                    }
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
            .navigationTitle("Daily Cap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(parsedCents == nil || isSaving)
                        .accessibilityIdentifier("budget.save")
                }
            }
        }
    }

    private func save() async {
        guard let cents = parsedCents else { return }
        isSaving = true
        errorMessage = nil
        let budget = Budget(dailyLimitCents: cents, warnPct: warnPct)
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
