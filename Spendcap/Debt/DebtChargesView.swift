import SwiftUI

// The charges behind a Debt row.
//
// The tab has always claimed "$174.22 paid · 4 charges" against an item and
// given no way to see the four. That total is the number on the screen most
// likely to be wrong: a match value is a substring, so a row can quietly be
// claiming a charge that belongs to something else, and a usage-priced service
// drifts past its plan for reasons only the individual debits explain. Tapping
// a row now opens the debits; editing moved to a button in here and the row's
// context menu, because "what did I actually pay" is the question asked of this
// screen a hundred times more often than "rename this".
//
// The window matters. This month is what the row that opened this asserts, and
// the sheet defaults to it so the two agree. Six months answers the different
// question a row sitting at zero raises — has this stopped charging, or has it
// simply not billed yet this month — which was previously unanswerable in the
// app at all.

/// What the sheet was opened on: one obligation, or every obligation owed to
/// one company. Both cases are a list of items, so there is one screen.
struct DebtChargesTarget: Identifiable {
    let title: String
    let items: [DebtSummaryRow]

    var id: String { items.map(\.id).joined(separator: "+") }
    var isMulti: Bool { items.count > 1 }
    var trackedItemIds: [UUID] { items.filter(\.isTracked).compactMap(\.itemId) }
    var plannedCents: Int { items.reduce(0) { $0 + $1.plannedCents } }
    var hasTrackedItems: Bool { items.contains(where: \.isTracked) }

    init(title: String, items: [DebtSummaryRow]) {
        self.title = title
        self.items = items
    }

    init(vendor: DebtVendorSummary) {
        self.init(title: vendor.name, items: vendor.items)
    }

    init(row: DebtSummaryRow) {
        self.init(title: row.itemName ?? "Item", items: [row])
    }
}

/// A month's worth of charges — how a six-month window is read.
struct DebtChargeMonth: Identifiable {
    let key: String
    let label: String
    let charges: [DebtCharge]

    var id: String { key }
    var totalCents: Int { charges.reduce(0) { $0 + $1.transaction.amountCents } }
}

enum DebtChargeMath {
    /// Group charges into months, newest first, keeping the server's order
    /// inside each month. The server already sorts by date desc, so the first
    /// time a month is seen is its correct position.
    static func months(_ charges: [DebtCharge], timeZone: TimeZone = .current) -> [DebtChargeMonth] {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        let label = DateFormatter()
        label.timeZone = timeZone
        label.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        var order: [String] = []
        var byMonth: [String: [DebtCharge]] = [:]
        for charge in charges {
            let key = String(charge.transaction.date.prefix(7))
            if byMonth[key] == nil { order.append(key) }
            byMonth[key, default: []].append(charge)
        }

        return order.map { key in
            let first = byMonth[key]?.first?.transaction.date ?? key
            return DebtChargeMonth(
                key: key,
                label: parser.date(from: first).map { label.string(from: $0) } ?? key,
                charges: byMonth[key] ?? []
            )
        }
    }

    /// "15 Aug" — the day, without the year the section header already carries.
    static func dayLabel(_ date: String, timeZone: TimeZone = .current) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        let label = DateFormatter()
        label.timeZone = timeZone
        label.setLocalizedDateFormatFromTemplate("d MMM")

        return parser.date(from: date).map { label.string(from: $0) } ?? date
    }
}

struct DebtChargesView: View {
    @Environment(\.dismiss) private var dismiss

    let target: DebtChargesTarget
    let groups: [DebtGroup]
    let onChange: () async -> Void

    @State private var charges: [DebtCharge] = []
    @State private var window: DebtChargeWindow = .thisMonth
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var editing: DebtSummaryRow?

    private var totalCents: Int { charges.reduce(0) { $0 + $1.transaction.amountCents } }

    var body: some View {
        NavigationStack {
            List {
                summarySection

                if target.hasTrackedItems {
                    if isLoading && charges.isEmpty {
                        Section { ProgressView() }
                    } else if charges.isEmpty {
                        Section {
                            Text(window == .thisMonth
                                 ? "Nothing has posted against this yet this month."
                                 : "Nothing has posted against this in the last six months.")
                                .foregroundStyle(.secondary)
                        } footer: {
                            Text(window == .thisMonth
                                 ? "Widen the window above to see whether it charged in earlier months."
                                 : "A row with a plan and no charges for six months is the one to check — either the match text is wrong, or the service stopped billing.")
                        }
                    } else if target.isMulti {
                        ForEach(target.items) { item in
                            itemSection(item)
                        }
                    } else {
                        ForEach(DebtChargeMath.months(charges)) { month in
                            monthSection(month)
                        }
                    }
                }

                untrackedSection
                editSection

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("debtCharges.error")
                    }
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: window) { await load() }
            .sheet(item: $editing) { row in
                DebtItemEditor(groups: groups, groupId: row.groupId, row: row) {
                    await onChange()
                    // The row this sheet was opened on may no longer exist —
                    // the editor can delete it — so close rather than reload a
                    // list of charges for something that is gone.
                    dismiss()
                }
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            LabeledContent("Every month") {
                Text(BudgetMath.dollars(target.plannedCents))
                    .monospacedDigit()
            }
            if target.hasTrackedItems {
                LabeledContent(window == .thisMonth ? "Charged this month" : "Charged over six months") {
                    Text(BudgetMath.dollars(totalCents))
                        .monospacedDigit()
                        .foregroundStyle(charges.isEmpty ? Color.secondary : Color.green)
                }
                .accessibilityIdentifier("debtCharges.total")
                Picker("Window", selection: $window) {
                    ForEach(DebtChargeWindow.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("debtCharges.window")
            }
        } footer: {
            if target.hasTrackedItems {
                Text(target.isMulti
                     ? "Every charge matched to \(target.title), split by what it pays for. A charge is claimed by one item only, so these add up to the totals on the Debt tab."
                     : "The charges matched to this item. A charge is claimed by one item only, so these add up to the paid figure on the Debt tab.")
            }
        }
    }

    private func itemSection(_ item: DebtSummaryRow) -> some View {
        let owned = charges.filter { $0.itemId == item.itemId }
        return Section {
            if owned.isEmpty {
                Text(item.isTracked ? "Nothing this window." : "Not tracked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(owned) { charge in
                    chargeRow(charge, lineName: item.itemName ?? target.title)
                }
            }
        } header: {
            HStack {
                Text(item.note?.isEmpty == false ? item.note! : (item.itemName ?? "Item"))
                Spacer()
                Text(BudgetMath.dollars(owned.reduce(0) { $0 + $1.transaction.amountCents }))
                    .monospacedDigit()
            }
        }
    }

    private func monthSection(_ month: DebtChargeMonth) -> some View {
        Section {
            ForEach(month.charges) { charge in
                chargeRow(charge, lineName: target.title)
            }
        } header: {
            HStack {
                Text(month.label)
                Spacer()
                Text(BudgetMath.dollars(month.totalCents))
                    .monospacedDigit()
            }
        }
    }

    private func chargeRow(_ charge: DebtCharge, lineName: String) -> some View {
        NavigationLink {
            TransactionDetailView(transaction: charge.transaction, lineName: lineName) {
                Task {
                    await onChange()
                    await load()
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(charge.transaction.displayName)
                        .lineLimit(1)
                    Text(DebtChargeMath.dayLabel(charge.transaction.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(BudgetMath.dollars(charge.transaction.amountCents))
                        .font(.body.monospacedDigit())
                    if charge.transaction.pending {
                        Text("Pending")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("debtCharges.charge")
    }

    /// Says out loud why an item shows nothing. "Not tracked" on the tab is
    /// easy to miss; opening the row and finding an empty list is not the
    /// place to leave someone guessing.
    @ViewBuilder
    private var untrackedSection: some View {
        let untracked = target.items.filter { !$0.isTracked }
        if !untracked.isEmpty {
            Section {
                ForEach(untracked) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.note?.isEmpty == false ? item.note! : (item.itemName ?? "Item"))
                        Text("No match set, so nothing can be looked up for it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Not tracked")
            } footer: {
                Text("Add what the charge reads as on your statement to see its debits here. An obligation paid outside the linked account — payroll-deducted, say — has nothing to match and is fine left as it is.")
            }
        }
    }

    private var editSection: some View {
        Section {
            ForEach(target.items) { item in
                Button {
                    editing = item
                } label: {
                    Label(
                        target.isMulti
                            ? "Edit \(item.note?.isEmpty == false ? item.note! : (item.itemName ?? "item"))"
                            : "Edit item",
                        systemImage: "slider.horizontal.3"
                    )
                }
                .accessibilityIdentifier("debtCharges.edit")
            }
        } footer: {
            Text("The plan, the group and the text this matches on.")
        }
    }

    // MARK: - Data

    private func load() async {
        let ids = target.trackedItemIds
        guard !ids.isEmpty else {
            charges = []
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            charges = try await SpendService.shared.debtCharges(itemIds: ids, window: window)
        } catch {
            guard !MonthsViewModel.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
