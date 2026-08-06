import Foundation

// MARK: - Trips and events

/// A trip or an event: a named budget that stands apart from the daily cap.
///
/// Dates are carried as "yyyy-MM-dd" strings, as everywhere else in the app.
/// A `Date` here would be a timestamp for a calendar day, and formatting one in
/// a timezone other than the one it was built in relabels it — the bug that
/// renamed every month on the Months tab.
struct Trip: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var kind: TripKind
    var startsOn: String?
    var endsOn: String?
    /// Nil means "no budget set": the planned lines are the budget. Zero is a
    /// different statement — budgeted nothing — so the two never collapse.
    var budgetCents: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case budgetCents = "budget_cents"
    }
}

enum TripKind: String, Codable, CaseIterable, Identifiable {
    case trip
    case event

    var id: String { rawValue }
    var label: String { self == .trip ? "Trip" : "Event" }
    var symbol: String { self == .trip ? "airplane" : "calendar" }
}

/// One trip as the list screen sees it: planned, spent, and enough context to
/// say whether that is fine. Comes from `trip_totals()`.
struct TripTotals: Codable, Identifiable, Equatable {
    let tripId: UUID
    let name: String
    let kind: TripKind
    let startsOn: String?
    let endsOn: String?
    let budgetCents: Int?
    let plannedCents: Int
    let spentCents: Int
    let txnCount: Int
    let lineCount: Int

    var id: UUID { tripId }

    /// What this trip is judged against: an explicit budget if the user set
    /// one, otherwise the sum of what they planned. Nil when neither exists —
    /// a trip with no budget is not a trip that is 0% spent.
    var capCents: Int? {
        if let budgetCents { return budgetCents }
        return plannedCents > 0 ? plannedCents : nil
    }

    var trip: Trip {
        Trip(id: tripId, name: name, kind: kind,
             startsOn: startsOn, endsOn: endsOn, budgetCents: budgetCents)
    }

    enum CodingKeys: String, CodingKey {
        case tripId = "trip_id"
        case name, kind
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case budgetCents = "budget_cents"
        case plannedCents = "planned_cents"
        case spentCents = "spent_cents"
        case txnCount = "txn_count"
        case lineCount = "line_count"
    }

    init(tripId: UUID, name: String, kind: TripKind, startsOn: String?, endsOn: String?,
         budgetCents: Int?, plannedCents: Int, spentCents: Int, txnCount: Int, lineCount: Int) {
        self.tripId = tripId
        self.name = name
        self.kind = kind
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.budgetCents = budgetCents
        self.plannedCents = plannedCents
        self.spentCents = spentCents
        self.txnCount = txnCount
        self.lineCount = lineCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tripId = try c.decode(UUID.self, forKey: .tripId)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decode(TripKind.self, forKey: .kind)) ?? .trip
        startsOn = try c.decodeIfPresent(String.self, forKey: .startsOn)
        endsOn = try c.decodeIfPresent(String.self, forKey: .endsOn)
        budgetCents = TripDecoding.bigint(c, .budgetCents)
        plannedCents = TripDecoding.bigint(c, .plannedCents) ?? 0
        spentCents = TripDecoding.bigint(c, .spentCents) ?? 0
        txnCount = (try? c.decode(Int.self, forKey: .txnCount)) ?? 0
        lineCount = (try? c.decode(Int.self, forKey: .lineCount)) ?? 0
    }
}

/// One line inside a trip, with what has actually landed against it. Comes
/// from `trip_line_spend()`. A nil `lineId` is the synthetic row for spending
/// assigned to the trip but filed under no line — the same shape the category
/// rollup uses for Uncategorized.
struct TripLineSpend: Codable, Identifiable, Equatable {
    let lineId: UUID?
    let name: String?
    let symbol: String?
    let plannedCents: Int
    let occursOn: String?
    let sortOrder: Int
    let spentCents: Int
    let txnCount: Int

    var id: String { lineId?.uuidString ?? "unfiled" }
    var isUnfiled: Bool { lineId == nil }
    var displayName: String { name ?? "Not filed yet" }
    var displaySymbol: String { symbol ?? (isUnfiled ? "tray" : "tag") }

    /// Positive means room left. Meaningless when nothing was planned, which
    /// is why the screen checks `plannedCents > 0` before showing it.
    var remainingCents: Int { plannedCents - spentCents }
    var isOver: Bool { plannedCents > 0 && spentCents > plannedCents }

    var progress: Double {
        guard plannedCents > 0 else { return 0 }
        return min(1.0, max(0.0, Double(spentCents) / Double(plannedCents)))
    }

    enum CodingKeys: String, CodingKey {
        case name, symbol
        case lineId = "line_id"
        case plannedCents = "planned_cents"
        case occursOn = "occurs_on"
        case sortOrder = "sort_order"
        case spentCents = "spent_cents"
        case txnCount = "txn_count"
    }

    init(lineId: UUID?, name: String?, symbol: String?, plannedCents: Int,
         occursOn: String?, sortOrder: Int, spentCents: Int, txnCount: Int) {
        self.lineId = lineId
        self.name = name
        self.symbol = symbol
        self.plannedCents = plannedCents
        self.occursOn = occursOn
        self.sortOrder = sortOrder
        self.spentCents = spentCents
        self.txnCount = txnCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineId = try c.decodeIfPresent(UUID.self, forKey: .lineId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        plannedCents = TripDecoding.bigint(c, .plannedCents) ?? 0
        occursOn = try c.decodeIfPresent(String.self, forKey: .occursOn)
        sortOrder = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
        spentCents = TripDecoding.bigint(c, .spentCents) ?? 0
        txnCount = (try? c.decode(Int.self, forKey: .txnCount)) ?? 0
    }
}

/// A transaction offered for assignment, or already assigned. `lineId` is only
/// populated by `trip_assigned()`.
struct TripTransaction: Codable, Identifiable, Equatable {
    let transactionId: UUID
    let lineId: UUID?
    let date: String
    let name: String
    let merchantName: String?
    let amountCents: Int
    let pending: Bool

    var id: UUID { transactionId }
    var title: String { merchantName ?? name }

    enum CodingKeys: String, CodingKey {
        case date, name, pending
        case transactionId = "transaction_id"
        case lineId = "line_id"
        case merchantName = "merchant_name"
        case amountCents = "amount_cents"
    }

    init(transactionId: UUID, lineId: UUID?, date: String, name: String,
         merchantName: String?, amountCents: Int, pending: Bool) {
        self.transactionId = transactionId
        self.lineId = lineId
        self.date = date
        self.name = name
        self.merchantName = merchantName
        self.amountCents = amountCents
        self.pending = pending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transactionId = try c.decode(UUID.self, forKey: .transactionId)
        lineId = try c.decodeIfPresent(UUID.self, forKey: .lineId)
        date = try c.decode(String.self, forKey: .date)
        name = try c.decode(String.self, forKey: .name)
        merchantName = try c.decodeIfPresent(String.self, forKey: .merchantName)
        amountCents = TripDecoding.bigint(c, .amountCents) ?? 0
        pending = (try? c.decode(Bool.self, forKey: .pending)) ?? false
    }
}

/// Postgres `bigint` comes back from PostgREST as a number or as a string
/// depending on magnitude, and guessing wrong drops the value silently. The
/// rest of the app decodes it the same way; this is that, generically.
enum TripDecoding {
    static func bigint<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }
}

// MARK: - Trip math

/// Pure functions behind the Trips screens. Kept out of the views so the date
/// labelling in particular can be tested — it is the part most likely to be
/// quietly wrong.
enum TripMath {
    /// A human range for a trip's dates: "Mar 3–11", "Mar 28 – Apr 2",
    /// "Dec 28, 2026 – Jan 2, 2027". Nil when the trip has no dates at all,
    /// which the screen renders as "No dates" rather than an empty gap.
    ///
    /// `today` decides whether the year is worth showing; a trip inside the
    /// current year doesn't need one.
    static func dateRangeLabel(startsOn: String?, endsOn: String?,
                               today: Date = Date(),
                               timeZone: TimeZone = .current,
                               locale: Locale = .current) -> String? {
        let start = date(from: startsOn, timeZone: timeZone)
        let end = date(from: endsOn, timeZone: timeZone)
        guard start != nil || end != nil else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let thisYear = calendar.component(.year, from: today)
        let years = [start, end].compactMap { $0 }.map { calendar.component(.year, from: $0) }
        let showYear = years.contains { $0 != thisYear }

        guard let start else {
            return "until " + format(end!, style: showYear ? .dayMonthYear : .dayMonth,
                                     timeZone: timeZone, locale: locale)
        }
        guard let end else {
            return "from " + format(start, style: showYear ? .dayMonthYear : .dayMonth,
                                    timeZone: timeZone, locale: locale)
        }
        if calendar.isDate(start, inSameDayAs: end) {
            return format(start, style: showYear ? .dayMonthYear : .dayMonth,
                          timeZone: timeZone, locale: locale)
        }
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
            && calendar.component(.year, from: start) == calendar.component(.year, from: end)
        if sameMonth && !showYear {
            // "Mar 3–11" — repeating the month reads as two separate dates.
            let day = format(end, style: .dayOnly, timeZone: timeZone, locale: locale)
            return format(start, style: .dayMonth, timeZone: timeZone, locale: locale) + "–" + day
        }
        let style: DateStyle = showYear ? .dayMonthYear : .dayMonth
        return format(start, style: style, timeZone: timeZone, locale: locale)
            + " – " + format(end, style: style, timeZone: timeZone, locale: locale)
    }

    /// How many days a trip covers, inclusive. Nil unless both ends are known.
    static func dayCount(startsOn: String?, endsOn: String?,
                         timeZone: TimeZone = .current) -> Int? {
        guard let start = date(from: startsOn, timeZone: timeZone),
              let end = date(from: endsOn, timeZone: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, days + 1)
    }

    /// Whether a trip is ahead, underway, or done — the only grouping the list
    /// screen makes. A trip with no dates is treated as planning, since that is
    /// the state you are in when you haven't picked dates yet.
    static func phase(startsOn: String?, endsOn: String?,
                      today: Date = Date(), timeZone: TimeZone = .current) -> TripPhase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = date(from: startsOn, timeZone: timeZone)
        let end = date(from: endsOn, timeZone: timeZone)
        let now = calendar.startOfDay(for: today)
        if let end, calendar.startOfDay(for: end) < now { return .past }
        if let start, calendar.startOfDay(for: start) > now { return .upcoming }
        if start == nil && end == nil { return .upcoming }
        return .current
    }

    /// Status against the trip's own budget, reusing the app's thresholds so a
    /// trip turns amber at the same point everything else does.
    static func status(spentCents: Int, capCents: Int?, warnPct: Int = 80) -> SpendStatus {
        guard let capCents, capCents > 0 else { return .under }
        return BudgetMath.status(spentCents: spentCents, limitCents: capCents, warnPct: warnPct)
    }

    static func date(from string: String?, timeZone: TimeZone = .current) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        return parser.date(from: string)
    }

    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd"
        out.timeZone = timeZone
        out.locale = Locale(identifier: "en_US_POSIX")
        return out.string(from: date)
    }

    private enum DateStyle {
        case dayOnly, dayMonth, dayMonthYear
        var template: String {
            switch self {
            case .dayOnly: return "d"
            case .dayMonth: return "MMMd"
            case .dayMonthYear: return "MMMdy"
            }
        }
    }

    private static func format(_ date: Date, style: DateStyle,
                               timeZone: TimeZone, locale: Locale) -> String {
        let out = DateFormatter()
        out.locale = locale
        out.timeZone = timeZone
        out.setLocalizedDateFormatFromTemplate(style.template)
        return out.string(from: date)
    }
}

enum TripPhase: String, CaseIterable, Identifiable {
    case current, upcoming, past

    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: return "Happening now"
        case .upcoming: return "Coming up"
        case .past: return "Past"
        }
    }
}

/// The starter lines a new trip is offered, so the first screen isn't empty.
/// Planned amounts are zero on purpose — a suggested number would be a made-up
/// budget the user then has to notice and correct.
struct TripLineTemplate: Identifiable, Equatable {
    let name: String
    let symbol: String
    var id: String { name }

    static let trip: [TripLineTemplate] = [
        .init(name: "Flights", symbol: "airplane"),
        .init(name: "Hotel", symbol: "bed.double.fill"),
        .init(name: "Food", symbol: "fork.knife"),
        .init(name: "Transport", symbol: "tram.fill"),
        .init(name: "Activities", symbol: "ticket.fill"),
    ]

    static let event: [TripLineTemplate] = [
        .init(name: "Tickets", symbol: "ticket.fill"),
        .init(name: "Food", symbol: "fork.knife"),
        .init(name: "Transport", symbol: "car.fill"),
    ]

    static func starters(for kind: TripKind) -> [TripLineTemplate] {
        kind == .trip ? trip : event
    }

    /// Symbols offered when adding a line by hand.
    static let symbolChoices = [
        "airplane", "bed.double.fill", "fork.knife", "tram.fill", "car.fill",
        "ticket.fill", "bag.fill", "gift.fill", "cup.and.saucer.fill",
        "figure.hiking", "camera.fill", "creditcard.fill", "tag.fill",
    ]
}
