import SwiftUI

// Trips and events — a named budget that stands outside the daily cap.
//
// The daily cap answers "am I overspending today". A flight and eight hotel
// nights are not that question: they are one decision, made once, that would
// blow any daily cap and fire an over-cap push the user can do nothing about.
// So spending assigned to a trip leaves `overspend_status()` entirely and is
// judged against the trip's own budget instead.
//
// Assignment is always explicit — see the header of 0010_trips.sql. A trip's
// dates suggest transactions; they never claim them. Excluding a whole date
// range automatically would switch the app's core feature off for the length of
// a holiday, which is when it matters most.

extension SpendStatus {
    /// The app's status colours in one place. Red and orange are already used
    /// this way on Months and Trends; naming them here keeps a trip from
    /// inventing a fourth shade of "nearly".
    var tint: Color {
        switch self {
        case .under: return .accentColor
        case .warn: return .orange
        case .over: return .red
        }
    }
}

@MainActor
final class TripsViewModel: ObservableObject {
    @Published var trips: [TripTotals] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var isEmpty: Bool { !isLoading && trips.isEmpty }

    /// Grouped for the list: what's happening now, what's next, what's done.
    func grouped(now: Date = Date()) -> [(phase: TripPhase, trips: [TripTotals])] {
        TripPhase.allCases.compactMap { phase in
            let matching = trips.filter {
                TripMath.phase(startsOn: $0.startsOn, endsOn: $0.endsOn, today: now) == phase
            }
            return matching.isEmpty ? nil : (phase, matching)
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            trips = try await SpendService.shared.trips()
        } catch {
            errorMessage = MonthsViewModel.isCancellation(error) ? nil : error.localizedDescription
        }
    }

    func delete(_ trip: TripTotals) async {
        do {
            try await SpendService.shared.deleteTrip(id: trip.tripId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TripsView: View {
    /// Presented as a sheet from Settings rather than owning a tab, so it needs
    /// its own way out. Trips keeps its own NavigationStack — pushing this into
    /// Settings' stack would nest two of them and stack two nav bars.
    var isModal = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TripsViewModel()
    @State private var showingNew = false
    @State private var pendingDelete: TripTotals?
    /// Creating a trip pushes straight into it. Naming a trip and landing back
    /// on a list is a dead end — the next thing anyone wants is to put costs
    /// in it, and that lives one screen deeper.
    @State private var path: [Trip] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("trips.error")
                }

                if model.isEmpty {
                    TripsEmptyState { showingNew = true }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                ForEach(model.grouped(), id: \.phase) { group in
                    Section(group.phase.title) {
                        ForEach(group.trips) { trip in
                            NavigationLink(value: trip.trip) {
                                TripRow(trip: trip)
                            }
                            .accessibilityIdentifier("trips.row")
                            .swipeActions {
                                Button("Delete", role: .destructive) { pendingDelete = trip }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(for: Trip.self) { trip in
                TripDetailView(trip: trip) {
                    Task { await model.load() }
                }
            }
            .navigationTitle("Trips")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New trip", systemImage: "plus")
                    }
                    .accessibilityIdentifier("trips.new")
                }
                if isModal {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("trips.done")
                    }
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(isPresented: $showingNew) {
                TripEditorView(trip: nil) { created in
                    Task {
                        await model.load()
                        // Push after the reload, so the destination it lands on
                        // is backed by a row the list already knows about.
                        if let created { path.append(created) }
                    }
                }
            }
            .confirmationDialog(
                pendingDelete.map { "Delete \($0.name)? Its spending goes back to counting against your daily cap." } ?? "",
                isPresented: Binding(get: { pendingDelete != nil },
                                     set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let trip = pendingDelete {
                        Task { await model.delete(trip) }
                    }
                    pendingDelete = nil
                }
            }
        }
    }
}

/// One trip in the list: what it costs so far against what it is allowed to.
struct TripRow: View {
    let trip: TripTotals

    private var status: SpendStatus {
        TripMath.status(spentCents: trip.spentCents, capCents: trip.capCents)
    }

    private var subtitle: String {
        let range = TripMath.dateRangeLabel(startsOn: trip.startsOn, endsOn: trip.endsOn)
        let counted = trip.txnCount == 1 ? "1 charge" : "\(trip.txnCount) charges"
        return [range, counted].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: trip.kind.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: 34, height: 34)
                .background(status.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(trip.name)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(BudgetMath.dollars(trip.spentCents))
                    .font(.body.weight(.semibold).monospacedDigit())
                if let cap = trip.capCents {
                    Text("of \(BudgetMath.wholeDollars(cap))")
                        .font(.caption)
                        .foregroundStyle(status == .over ? .red : .secondary)
                } else {
                    // No plan and no budget: a total is all we can honestly say.
                    Text("no budget")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TripsEmptyState: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("No trips yet")
                .font(.headline)
            Text("A trip holds its own budget — flights, hotel, food, anything you add. Spending you put on a trip stops counting against your daily cap, so a hotel booking won't fire an over-cap alert.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create a trip", action: onCreate)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                .accessibilityIdentifier("trips.emptyCreate")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Create / edit a trip

struct TripEditorView: View {
    /// Nil creates; non-nil edits in place.
    let trip: Trip?
    /// Hands back the trip that was just created, so the caller can push
    /// straight into it. Nil on an edit — there is nowhere new to go.
    let onSave: (Trip?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var kind: TripKind
    @State private var hasDates: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var budgetText: String
    @State private var addStarters: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(trip: Trip?, onSave: @escaping (Trip?) -> Void) {
        self.trip = trip
        self.onSave = onSave
        _name = State(initialValue: trip?.name ?? "")
        _kind = State(initialValue: trip?.kind ?? .trip)
        let start = TripMath.date(from: trip?.startsOn)
        let end = TripMath.date(from: trip?.endsOn)
        _hasDates = State(initialValue: trip == nil || start != nil || end != nil)
        _startDate = State(initialValue: start ?? Date())
        _endDate = State(initialValue: end ?? start ?? Date())
        _budgetText = State(initialValue: trip?.budgetCents.map {
            String(format: "%.0f", Double($0) / 100)
        } ?? "")
        // Only a brand-new trip gets starter lines; adding them to an existing
        // one would duplicate whatever the user already built.
        _addStarters = State(initialValue: trip == nil)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Nil means the field is unparseable; `.some(nil)` means deliberately blank.
    private var budgetCents: Int?? {
        let cleaned = budgetText
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return .some(nil) }
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return .some(Int((value * 100).rounded()))
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && budgetCents != nil && !isSaving
            && (!hasDates || endDate >= startDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind == .trip ? "Tokyo" : "Sarah's wedding", text: $name)
                        .accessibilityIdentifier("trip.name")
                    Picker("Kind", selection: $kind) {
                        ForEach(TripKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("trip.kind")
                }

                Section {
                    Toggle("Set dates", isOn: $hasDates.animation())
                        .accessibilityIdentifier("trip.hasDates")
                    if hasDates {
                        DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                        DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                } footer: {
                    Text(hasDates
                         ? "Dates are how the app finds charges to suggest. Nothing is added to the trip until you pick it."
                         : "Without dates the app can't suggest charges — you can still add planned costs by hand.")
                }

                Section {
                    HStack {
                        Text("$")
                        TextField("optional", text: $budgetText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("trip.budget")
                    }
                } header: {
                    Text("Total budget")
                } footer: {
                    Text("Leave blank to let the planned costs below add up to the budget.")
                }

                if trip == nil {
                    Section {
                        Toggle("Add starter categories", isOn: $addStarters)
                            .accessibilityIdentifier("trip.addStarters")
                    } footer: {
                        Text(TripLineTemplate.starters(for: kind).map(\.name).joined(separator: ", ")
                             + " — each starts at $0, and you can add or remove any of them.")
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(trip == nil ? "New \(kind.label.lowercased())" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(trip == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("trip.save")
                }
            }
        }
    }

    private func save() async {
        guard let budget = budgetCents else { return }
        isSaving = true
        errorMessage = nil
        let starts = hasDates ? TripMath.string(from: startDate) : nil
        let ends = hasDates ? TripMath.string(from: endDate) : nil
        do {
            if let existing = trip {
                var updated = existing
                updated.name = trimmedName
                updated.kind = kind
                updated.startsOn = starts
                updated.endsOn = ends
                updated.budgetCents = budget
                try await SpendService.shared.updateTrip(updated)
                onSave(nil)
            } else {
                let created = try await SpendService.shared.createTrip(
                    name: trimmedName, kind: kind,
                    startsOn: starts, endsOn: ends, budgetCents: budget)
                if addStarters {
                    for (index, template) in TripLineTemplate.starters(for: kind).enumerated() {
                        try await SpendService.shared.addTripLine(
                            tripId: created.id, name: template.name, symbol: template.symbol,
                            plannedCents: 0,
                            // The flight is the one starter with an obvious
                            // date; the rest span the whole trip.
                            occursOn: index == 0 ? starts : nil)
                    }
                }
                onSave(created)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
