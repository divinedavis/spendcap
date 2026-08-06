import SwiftUI

// The inside of one trip: what you planned, what has actually landed, and the
// charges in the trip's dates that nothing has claimed yet.
//
// Planned and spent are shown side by side rather than merged. A trip you
// haven't taken has plans and no spending; one you're on has both, and the gap
// between them is the only thing worth looking at.

@MainActor
final class TripDetailViewModel: ObservableObject {
    @Published var trip: Trip
    @Published var lines: [TripLineSpend] = []
    @Published var candidates: [TripTransaction] = []
    @Published var assigned: [TripTransaction] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    init(trip: Trip) {
        self.trip = trip
    }

    var plannedCents: Int { lines.reduce(0) { $0 + $1.plannedCents } }
    var spentCents: Int { lines.reduce(0) { $0 + $1.spentCents } }

    /// What the trip is judged against: the explicit budget if set, else the
    /// plan. Nil when neither exists — that is "no budget", not "budget zero".
    var capCents: Int? {
        if let budget = trip.budgetCents { return budget }
        return plannedCents > 0 ? plannedCents : nil
    }

    var status: SpendStatus {
        TripMath.status(spentCents: spentCents, capCents: capCents)
    }

    /// Real lines only — the unfiled row is a rollup, not something to edit.
    var editableLines: [TripLineSpend] { lines.filter { !$0.isUnfiled } }
    var unfiled: TripLineSpend? { lines.first(where: \.isUnfiled) }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let lines = SpendService.shared.tripLines(tripId: trip.id)
            async let candidates = SpendService.shared.tripCandidates(tripId: trip.id)
            async let assigned = SpendService.shared.tripAssigned(tripId: trip.id)
            self.lines = try await lines
            self.candidates = try await candidates
            self.assigned = try await assigned
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
        }
    }

    func assign(_ transaction: TripTransaction, to lineId: UUID?) async {
        do {
            try await SpendService.shared.assignTransaction(
                transaction.transactionId, toTrip: trip.id, line: lineId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unassign(_ transaction: TripTransaction) async {
        do {
            try await SpendService.shared.unassignTransaction(transaction.transactionId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteLine(_ line: TripLineSpend) async {
        guard let id = line.lineId else { return }
        do {
            try await SpendService.shared.deleteTripLine(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TripDetailView: View {
    @StateObject private var model: TripDetailViewModel
    /// Lets the list behind us refresh totals when something changes here.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?
    @State private var pendingDeleteLine: TripLineSpend?
    @State private var showingDeleteTrip = false

    init(trip: Trip, onChange: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TripDetailViewModel(trip: trip))
        self.onChange = onChange
    }

    /// One sheet modifier, several destinations — stacking
    /// `.sheet(isPresented:)` risks one that silently never presents.
    enum Sheet: Identifiable {
        case addLine
        case editLine(TripLineSpend)
        case review
        case editTrip

        var id: String {
            switch self {
            case .addLine: return "addLine"
            case .editLine(let line): return "editLine-\(line.id)"
            case .review: return "review"
            case .editTrip: return "editTrip"
            }
        }
    }

    var body: some View {
        List {
            Section {
                TripSummaryCard(model: model)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("trip.error")
            }

            if !model.candidates.isEmpty {
                Section {
                    Button {
                        sheet = .review
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tray.full")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.candidates.count == 1
                                     ? "1 charge in these dates"
                                     : "\(model.candidates.count) charges in these dates")
                                    .font(.body.weight(.medium))
                                Text("Not on this trip yet — review them")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("trip.review")
                }
            }

            Section {
                ForEach(model.editableLines) { line in
                    Button {
                        sheet = .editLine(line)
                    } label: {
                        TripLineRow(line: line)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trip.line")
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDeleteLine = line }
                    }
                }

                if let unfiled = model.unfiled {
                    TripLineRow(line: unfiled)
                        .accessibilityIdentifier("trip.unfiled")
                }

                Button {
                    sheet = .addLine
                } label: {
                    Label("Add a category", systemImage: "plus")
                }
                .accessibilityIdentifier("trip.addLine")
            } header: {
                Text("Costs")
            } footer: {
                if model.editableLines.isEmpty {
                    Text("Add what you expect to spend — flights, hotel, food. Charges you put on this trip stop counting against your daily cap.")
                } else if model.unfiled != nil {
                    Text("\"Not filed yet\" is spending on this trip that isn't under a category. It still counts toward the total.")
                }
            }

            if !model.assigned.isEmpty {
                Section("On this trip") {
                    ForEach(model.assigned) { transaction in
                        TripTransactionRow(transaction: transaction)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    Task {
                                        await model.unassign(transaction)
                                        onChange()
                                    }
                                }
                            }
                    }
                }
            }

            Section {
                Button("Delete trip", role: .destructive) { showingDeleteTrip = true }
                    .accessibilityIdentifier("trip.delete")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { sheet = .editTrip }
                    .accessibilityIdentifier("trip.edit")
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .addLine:
                TripLineEditorView(tripId: model.trip.id, line: nil) {
                    Task { await model.load(); onChange() }
                }
            case .editLine(let line):
                TripLineEditorView(tripId: model.trip.id, line: line) {
                    Task { await model.load(); onChange() }
                }
            case .review:
                TripReviewView(model: model) { onChange() }
            case .editTrip:
                TripEditorView(trip: model.trip) { _ in
                    Task {
                        // The header reads from `trip`, so pull the edited row
                        // back rather than trusting the local copy.
                        if let updated = try? await SpendService.shared.trips()
                            .first(where: { $0.tripId == model.trip.id }) {
                            model.trip = updated.trip
                        }
                        await model.load()
                        onChange()
                    }
                }
            }
        }
        .confirmationDialog(
            pendingDeleteLine.map { "Delete \($0.displayName)? Any spending filed under it stays on the trip." } ?? "",
            isPresented: Binding(get: { pendingDeleteLine != nil },
                                 set: { if !$0 { pendingDeleteLine = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let line = pendingDeleteLine {
                    Task { await model.deleteLine(line); onChange() }
                }
                pendingDeleteLine = nil
            }
        }
        .confirmationDialog(
            "Delete this trip? Its spending goes back to counting against your daily cap.",
            isPresented: $showingDeleteTrip,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await SpendService.shared.deleteTrip(id: model.trip.id)
                    onChange()
                    dismiss()
                }
            }
        }
    }
}

/// The header: spent against budget, and the plan behind it.
private struct TripSummaryCard: View {
    @ObservedObject var model: TripDetailViewModel

    private var subtitle: String {
        let range = TripMath.dateRangeLabel(startsOn: model.trip.startsOn, endsOn: model.trip.endsOn)
        let days = TripMath.dayCount(startsOn: model.trip.startsOn, endsOn: model.trip.endsOn)
            .map { $0 == 1 ? "1 day" : "\($0) days" }
        return [range, days].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.spentCents == 0 ? "Nothing spent yet" : "Spent so far")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(BudgetMath.dollars(model.spentCents))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(model.status.tint)
                    .accessibilityIdentifier("trip.spent")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let cap = model.capCents, cap > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: BudgetMath.progress(spentCents: model.spentCents, limitCents: cap))
                        .tint(model.status.tint)
                    HStack {
                        Text(model.trip.budgetCents == nil ? "Planned \(BudgetMath.wholeDollars(cap))"
                                                           : "Budget \(BudgetMath.wholeDollars(cap))")
                        Spacer()
                        let remaining = BudgetMath.remainingCents(spentCents: model.spentCents, limitCents: cap)
                        Text(remaining >= 0
                             ? "\(BudgetMath.dollars(remaining)) left"
                             : "\(BudgetMath.dollars(-remaining)) over")
                            .foregroundStyle(remaining >= 0 ? .secondary : Color.red)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("No budget set. Add planned costs below, or set a total in Edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

private struct TripLineRow: View {
    let line: TripLineSpend

    private var detail: String {
        var parts: [String] = []
        if let occursOn = line.occursOn,
           let label = TripMath.dateRangeLabel(startsOn: occursOn, endsOn: occursOn) {
            parts.append(label)
        }
        if line.plannedCents > 0 {
            parts.append("planned \(BudgetMath.wholeDollars(line.plannedCents))")
        }
        if line.txnCount > 0 {
            parts.append(line.txnCount == 1 ? "1 charge" : "\(line.txnCount) charges")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: line.displaySymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(line.isOver ? Color.red : Color.accentColor)
                .frame(width: 30, height: 30)
                .background((line.isOver ? Color.red : Color.accentColor).opacity(0.13),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(line.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text(BudgetMath.dollars(line.spentCents))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(line.isOver ? Color.red : .primary)
        }
        .padding(.vertical, 2)
    }
}

private struct TripTransactionRow: View {
    let transaction: TripTransaction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(TripMath.dateRangeLabel(startsOn: transaction.date, endsOn: transaction.date) ?? transaction.date)
                    if transaction.pending {
                        Text("· Pending")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(BudgetMath.dollars(transaction.amountCents))
                .font(.body.monospacedDigit())
        }
    }
}

// MARK: - Review suggested charges

/// The charges inside a trip's dates that no trip has claimed. Tapping one puts
/// it on the trip — which is also what takes it out of the daily cap, so it is
/// always a deliberate tap and never a background sweep.
struct TripReviewView: View {
    @ObservedObject var model: TripDetailViewModel
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.candidates) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title).font(.body).lineLimit(1)
                                Text(TripMath.dateRangeLabel(startsOn: candidate.date, endsOn: candidate.date) ?? candidate.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(BudgetMath.dollars(candidate.amountCents))
                                .font(.body.monospacedDigit())
                            Menu {
                                Button("On the trip, no category") {
                                    add(candidate, to: nil)
                                }
                                ForEach(model.editableLines) { line in
                                    if let id = line.lineId {
                                        Button(line.displayName) { add(candidate, to: id) }
                                    }
                                }
                            } label: {
                                Image(systemName: busy.contains(candidate.transactionId)
                                      ? "circle.dotted" : "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .disabled(busy.contains(candidate.transactionId))
                            .accessibilityIdentifier("trip.addCandidate")
                        }
                    }
                } footer: {
                    Text("Adding a charge to this trip stops it counting against your daily cap. Everything else in these dates keeps counting as normal.")
                }
            }
            .navigationTitle("In these dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if model.candidates.isEmpty {
                    ContentUnavailableView("Nothing left to review",
                                           systemImage: "checkmark.circle",
                                           description: Text("Every charge in these dates is either on the trip or deliberately left off it."))
                }
            }
        }
    }

    private func add(_ candidate: TripTransaction, to lineId: UUID?) {
        busy.insert(candidate.transactionId)
        Task {
            await model.assign(candidate, to: lineId)
            busy.remove(candidate.transactionId)
            onChange()
        }
    }
}

// MARK: - Add / edit a cost line

struct TripLineEditorView: View {
    let tripId: UUID
    /// Nil adds; non-nil edits.
    let line: TripLineSpend?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var symbol: String
    @State private var plannedText: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(tripId: UUID, line: TripLineSpend?, onSave: @escaping () -> Void) {
        self.tripId = tripId
        self.line = line
        self.onSave = onSave
        _name = State(initialValue: line?.name ?? "")
        _symbol = State(initialValue: line?.symbol ?? "tag.fill")
        _plannedText = State(initialValue: (line?.plannedCents).map {
            $0 > 0 ? String(format: "%.0f", Double($0) / 100) : ""
        } ?? "")
        let occurs = TripMath.date(from: line?.occursOn)
        _hasDate = State(initialValue: occurs != nil)
        _date = State(initialValue: occurs ?? Date())
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var plannedCents: Int? {
        let cleaned = plannedText
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Blank is a real answer: a line can exist to collect charges before
        // anyone decides what it should cost.
        if cleaned.isEmpty { return 0 }
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Flights", text: $name)
                        .accessibilityIdentifier("tripLine.name")
                }

                Section {
                    HStack {
                        Text("$")
                        TextField("0", text: $plannedText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("tripLine.planned")
                    }
                } header: {
                    Text("Planned")
                } footer: {
                    Text("What you expect this to cost. Leave blank to just track what lands here.")
                }

                Section {
                    Toggle("Has a date", isOn: $hasDate.animation())
                    if hasDate {
                        DatePicker("On", selection: $date, displayedComponents: .date)
                    }
                } footer: {
                    Text("For a flight or a booking on one day. Leave off for anything spread across the trip, like food.")
                }

                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(TripLineTemplate.symbolChoices, id: \.self) { choice in
                                Button {
                                    symbol = choice
                                } label: {
                                    Image(systemName: choice)
                                        .font(.system(size: 16))
                                        .frame(width: 40, height: 40)
                                        .foregroundStyle(symbol == choice ? Color.white : Color.accentColor)
                                        .background(symbol == choice ? Color.accentColor : Color.accentColor.opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(line == nil ? "Add a category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(line == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(trimmedName.isEmpty || plannedCents == nil || isSaving)
                        .accessibilityIdentifier("tripLine.save")
                }
            }
        }
    }

    private func save() async {
        guard let cents = plannedCents, !trimmedName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        let occursOn = hasDate ? TripMath.string(from: date) : nil
        do {
            if let existing = line, let id = existing.lineId {
                try await SpendService.shared.updateTripLine(
                    id: id, name: trimmedName, symbol: symbol,
                    plannedCents: cents, occursOn: occursOn)
            } else {
                try await SpendService.shared.addTripLine(
                    tripId: tripId, name: trimmedName, symbol: symbol,
                    plannedCents: cents, occursOn: occursOn)
            }
            onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
