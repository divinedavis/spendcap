import Foundation

struct BankTransaction: Codable, Identifiable, Equatable {
    let id: UUID
    let date: String            // "yyyy-MM-dd" from Postgres date column
    let name: String
    let merchantName: String?
    let category: String?
    let amountCents: Int        // > 0 = money out (Plaid convention)
    let pending: Bool
    let isRemoved: Bool
    /// Arrived in the item's first sync — see `countsTowardDailyCap`.
    /// Defaults to false so older cached rows and test fixtures still decode.
    let isBackfill: Bool

    enum CodingKeys: String, CodingKey {
        case id, date, name, pending, category
        case merchantName = "merchant_name"
        case amountCents = "amount_cents"
        case isRemoved = "is_removed"
        case isBackfill = "is_backfill"
    }

    init(
        id: UUID,
        date: String,
        name: String,
        merchantName: String? = nil,
        category: String? = nil,
        amountCents: Int,
        pending: Bool = false,
        isRemoved: Bool = false,
        isBackfill: Bool = false
    ) {
        self.id = id
        self.date = date
        self.name = name
        self.merchantName = merchantName
        self.category = category
        self.amountCents = amountCents
        self.pending = pending
        self.isRemoved = isRemoved
        self.isBackfill = isBackfill
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        name = try c.decode(String.self, forKey: .name)
        merchantName = try c.decodeIfPresent(String.self, forKey: .merchantName)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        amountCents = try c.decode(Int.self, forKey: .amountCents)
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        isRemoved = try c.decodeIfPresent(Bool.self, forKey: .isRemoved) ?? false
        isBackfill = try c.decodeIfPresent(Bool.self, forKey: .isBackfill) ?? false
    }

    var displayName: String {
        let merchant = merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
        return merchant.isEmpty ? name : merchant
    }

    /// Whether this row should count toward a day's spending.
    ///
    /// Must mirror `overspend_status()` exactly — the server sends the push and
    /// the client draws the ring, and the two disagreeing is worse than either
    /// being wrong. A row inherited in the item's first sync while still
    /// pending carries the *link* date rather than a purchase date, because
    /// banks report unposted charges with no authorized_date. It starts
    /// counting on its real day once it posts.
    var countsTowardDailyCap: Bool {
        !isRemoved && amountCents > 0 && !(pending && isBackfill)
    }
}

struct BankAccount: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let mask: String?
    let subtype: String?

    enum CodingKeys: String, CodingKey {
        case id, name, mask, subtype
    }
}

struct PlaidItem: Codable, Identifiable, Equatable {
    let id: UUID
    let institutionName: String?
    let status: String
    let lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case institutionName = "institution_name"
        case lastSyncedAt = "last_synced_at"
    }
}

/// One monthly bank statement. The PDF itself lives in the private
/// `statements` Storage bucket — this is only where to find it.
/// `storagePath` is nil when Plaid listed the statement but the download
/// failed, which the UI shows as unavailable rather than hiding the month.
struct BankStatement: Codable, Identifiable, Equatable {
    let id: UUID
    let year: Int
    let month: Int
    let storagePath: String?
    let byteSize: Int?

    var isAvailable: Bool { storagePath != nil }

    /// "August 2026" — built from components so it never depends on a parsed
    /// date the row may not carry.
    var periodLabel: String {
        var components = DateComponents()
        components.year = year
        components.month = month
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return "\(month)/\(year)" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    var sizeLabel: String? {
        guard let byteSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    enum CodingKeys: String, CodingKey {
        case id, year, month
        case storagePath = "storage_path"
        case byteSize = "byte_size"
    }
}

struct Budget: Codable, Equatable {
    var dailyLimitCents: Int
    var warnPct: Int
    /// Whole-month cap. Nil falls back to the daily cap × days in the month —
    /// which is the wrong yardstick for a month once rent or an annual bill
    /// lands on a single day, hence the option to set one directly. Unlike the
    /// daily cap this is not a push threshold; nothing server-side reads it.
    var monthlyLimitCents: Int?

    init(dailyLimitCents: Int, warnPct: Int, monthlyLimitCents: Int? = nil) {
        self.dailyLimitCents = dailyLimitCents
        self.warnPct = warnPct
        self.monthlyLimitCents = monthlyLimitCents
    }

    enum CodingKeys: String, CodingKey {
        case dailyLimitCents = "daily_limit_cents"
        case warnPct = "warn_pct"
        case monthlyLimitCents = "monthly_limit_cents"
    }

    /// This month's allowance: the explicit cap when set, otherwise the daily
    /// cap stretched over the month's own length.
    func capCents(daysInMonth: Int) -> Int {
        monthlyLimitCents ?? dailyLimitCents * daysInMonth
    }
}

enum SpendStatus: Equatable {
    case under
    case warn
    case over
}

/// One day on the Trends chart: the day's own outflow and the running
/// month-to-date total through that day.
struct DailySpend: Identifiable, Equatable {
    let date: Date
    let spentCents: Int
    let cumulativeCents: Int

    var id: Date { date }
}

/// Month-to-date rollup driving the Trends screen. All pure math on top of a
/// transaction list so it can be unit-tested without a network.
struct MonthStats: Equatable {
    var series: [DailySpend]
    var spentCents: Int
    var daysElapsed: Int
    var daysInMonth: Int
    var dailyLimitCents: Int
    /// Set when the user has chosen a whole-month cap. Trends and Months have
    /// to resolve the month's allowance the same way or the two screens
    /// disagree about whether the month is over budget.
    var monthlyLimitCents: Int?

    var monthCapCents: Int { monthlyLimitCents ?? dailyLimitCents * daysInMonth }
    var remainingCents: Int { monthCapCents - spentCents }
    var averagePerDayCents: Int { daysElapsed > 0 ? spentCents / daysElapsed : 0 }

    /// Straight-line projection to month end at the current daily average.
    var projectedCents: Int { averagePerDayCents * daysInMonth }

    var daysOverCap: Int { series.filter { $0.spentCents > dailyLimitCents }.count }

    /// Fraction of the month's cap already spent, clamped to [0, 1].
    var capProgress: Double {
        guard monthCapCents > 0 else { return 0 }
        return min(1.0, max(0.0, Double(spentCents) / Double(monthCapCents)))
    }
}

enum MonthMath {
    /// Build the day-by-day series for the calendar month containing `now`.
    /// Days with no transactions still get a row (flat cumulative line), and
    /// the series stops at today rather than running to month end — an empty
    /// tail would read as "spent nothing" instead of "hasn't happened yet".
    static func stats(
        transactions: [BankTransaction],
        dailyLimitCents: Int,
        monthlyLimitCents: Int? = nil,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> MonthStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        guard let interval = calendar.dateInterval(of: .month, for: now) else {
            return MonthStats(series: [], spentCents: 0, daysElapsed: 0,
                              daysInMonth: 0, dailyLimitCents: dailyLimitCents,
                              monthlyLimitCents: monthlyLimitCents)
        }
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let today = calendar.startOfDay(for: now)

        // Outflow only (> 0 is money out, Plaid convention), bucketed by day.
        // countsTowardDailyCap also drops pending rows inherited at link time,
        // whose date is the link date rather than a purchase date.
        var byDay: [Date: Int] = [:]
        for txn in transactions where txn.countsTowardDailyCap {
            guard let parsed = parser.date(from: txn.date) else { continue }
            let day = calendar.startOfDay(for: parsed)
            byDay[day, default: 0] += txn.amountCents
        }

        var series: [DailySpend] = []
        var running = 0
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor <= today, cursor < interval.end {
            let spent = byDay[cursor] ?? 0
            running += spent
            series.append(DailySpend(date: cursor, spentCents: spent, cumulativeCents: running))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return MonthStats(
            series: series,
            spentCents: running,
            daysElapsed: series.count,
            daysInMonth: daysInMonth,
            dailyLimitCents: dailyLimitCents,
            monthlyLimitCents: monthlyLimitCents
        )
    }
}

/// One row of `monthly_spend()` — a month's outflow total, aggregated in
/// Postgres so the client never pulls a year of transactions.
struct MonthlySpendRow: Codable, Equatable {
    let period: String          // "yyyy-MM-dd", first day of the month
    let spentCents: Int
    let txnCount: Int

    enum CodingKeys: String, CodingKey {
        case period
        case spentCents = "spent_cents"
        case txnCount = "txn_count"
    }

    init(period: String, spentCents: Int, txnCount: Int) {
        self.period = period
        self.spentCents = spentCents
        self.txnCount = txnCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decode(String.self, forKey: .period)
        // Postgres bigint reaches us as a JSON number through PostgREST but as
        // a quoted string through some other serialisers, and a year of totals
        // failing to decode over that is not a risk worth taking.
        spentCents = try Self.flexibleInt(c, .spentCents)
        txnCount = try Self.flexibleInt(c, .txnCount)
    }

    private static func flexibleInt(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> Int {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let text = try? c.decode(String.self, forKey: key), let value = Int(text) { return value }
        if let value = try? c.decode(Double.self, forKey: key) { return Int(value) }
        return 0
    }
}

/// One calendar month on the Months tab.
struct MonthlySpend: Identifiable, Equatable {
    /// First day of the month, in the user's timezone.
    let date: Date
    let spentCents: Int
    let txnCount: Int
    /// Daily cap × days in this month — the month's own allowance.
    let capCents: Int
    /// Change against the previous month with data, as a fraction (0.12 = +12%).
    /// Nil when there is no comparable month before it.
    let changeFraction: Double?
    /// False for months that predate the bank's shared history. A month with no
    /// transactions on record is not the same claim as "spent nothing", and the
    /// row has to say which one it is.
    let hasData: Bool
    /// The month still in progress — its total is partial by definition.
    let isCurrent: Bool
    /// "August 2026" and "Aug", rendered in the same timezone the month was
    /// bucketed in. Formatting `date` on demand would use the *device*
    /// timezone instead, which relabels every month by one whenever those two
    /// disagree.
    let label: String
    let shortLabel: String

    var id: Date { date }

    var isOverCap: Bool { hasData && capCents > 0 && spentCents > capCents }

    var changeLabel: String? {
        guard let changeFraction else { return nil }
        let pct = Int((changeFraction * 100).rounded())
        if pct == 0 { return "flat" }
        return (pct > 0 ? "+" : "\u{2212}") + "\(abs(pct))%"
    }
}

/// Twelve-month rollup driving the Months tab. Pure math over the aggregate
/// rows so it can be unit-tested without a network.
struct YearStats: Equatable {
    var months: [MonthlySpend]
    var budget: Budget

    /// The month in progress, when it is on record.
    var currentMonth: MonthlySpend? { months.last(where: { $0.isCurrent && $0.hasData }) }

    /// What's left of the current month's cap. Negative once it is blown
    /// through — the sign is the answer to "am I over".
    var currentRemainingCents: Int? {
        guard let month = currentMonth, month.capCents > 0 else { return nil }
        return month.capCents - month.spentCents
    }

    /// How far into the current month's cap the spending has gone, clamped to
    /// [0, 1] for a progress bar.
    var currentCapProgress: Double {
        guard let month = currentMonth, month.capCents > 0 else { return 0 }
        return min(1.0, max(0.0, Double(month.spentCents) / Double(month.capCents)))
    }

    /// Months carrying real history, oldest first.
    var withData: [MonthlySpend] { months.filter(\.hasData) }

    /// Complete months only — the month in progress would drag every average
    /// and "lowest month" toward whatever day of the month it is today.
    var settled: [MonthlySpend] { withData.filter { !$0.isCurrent } }

    /// Everything actually spent in the window, partial current month included.
    var totalCents: Int { withData.reduce(0) { $0 + $1.spentCents } }

    /// Mean over complete months, falling back to the current one when the bank
    /// has not shared a full month yet.
    var averageCents: Int {
        let basis = settled.isEmpty ? withData : settled
        guard !basis.isEmpty else { return 0 }
        return basis.reduce(0) { $0 + $1.spentCents } / basis.count
    }

    var highest: MonthlySpend? {
        (settled.isEmpty ? withData : settled).max { $0.spentCents < $1.spentCents }
    }

    var lowest: MonthlySpend? {
        (settled.isEmpty ? withData : settled).min { $0.spentCents < $1.spentCents }
    }

    /// Months of real history in the window — what the header counts, since
    /// "last 12 months" overstates a bank that only shared three.
    var monthsCovered: Int { withData.count }

    var monthsOverCap: Int { settled.filter(\.isOverCap).count }

    /// Trend across the settled months: the later half against the earlier
    /// half. Nil until there are four complete months, below which the swing
    /// between any two months says more about timing than direction.
    var trendFraction: Double? {
        let basis = settled
        guard basis.count >= 4 else { return nil }
        let half = basis.count / 2
        let older = Array(basis.prefix(half))
        let newer = Array(basis.suffix(basis.count - half))
        let olderAvg = Double(older.reduce(0) { $0 + $1.spentCents }) / Double(older.count)
        let newerAvg = Double(newer.reduce(0) { $0 + $1.spentCents }) / Double(newer.count)
        guard olderAvg > 0 else { return nil }
        return (newerAvg - olderAvg) / olderAvg
    }
}

enum YearMath {
    /// Turn `monthly_spend()` rows into the Months series.
    ///
    /// The function already emits one row per month including empty ones, so
    /// this fills in what only the client knows — the cap for each month, the
    /// month-over-month change, and which empty months are genuinely empty
    /// versus simply older than the history the bank shared.
    static func stats(
        rows: [MonthlySpendRow],
        budget: Budget,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> YearStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start

        let longLabel = DateFormatter()
        longLabel.timeZone = timeZone
        longLabel.setLocalizedDateFormatFromTemplate("MMMM y")
        let shortLabel = DateFormatter()
        shortLabel.timeZone = timeZone
        shortLabel.setLocalizedDateFormatFromTemplate("MMM")

        let parsed: [(date: Date, row: MonthlySpendRow)] = rows.compactMap { row in
            guard let date = parser.date(from: row.period) else { return nil }
            return (calendar.startOfDay(for: date), row)
        }.sorted { $0.date < $1.date }

        // History starts at the first month that has any transaction on record;
        // everything before it is "no data", not "no spending".
        let firstWithData = parsed.first(where: { $0.row.txnCount > 0 })?.date

        var months: [MonthlySpend] = []
        var previousWithData: Int?
        for entry in parsed {
            let hasData = firstWithData.map { entry.date >= $0 } ?? false
            let days = calendar.range(of: .day, in: .month, for: entry.date)?.count ?? 30
            let isCurrent = currentMonth.map {
                calendar.isDate(entry.date, equalTo: $0, toGranularity: .month)
            } ?? false

            // A month still in progress compared against a full month reads as
            // a collapse in spending on the 2nd and a surge on the 31st, so it
            // gets no change figure at all.
            var change: Double?
            if hasData, !isCurrent, let previous = previousWithData, previous > 0 {
                change = (Double(entry.row.spentCents) - Double(previous)) / Double(previous)
            }

            months.append(MonthlySpend(
                date: entry.date,
                spentCents: entry.row.spentCents,
                txnCount: entry.row.txnCount,
                capCents: budget.capCents(daysInMonth: days),
                changeFraction: change,
                hasData: hasData,
                isCurrent: isCurrent,
                label: longLabel.string(from: entry.date),
                shortLabel: shortLabel.string(from: entry.date)
            ))

            if hasData { previousWithData = entry.row.spentCents }
        }

        return YearStats(months: months, budget: budget)
    }
}

// MARK: - Category budgets

/// One budget line. `id` nil is impossible here; the *rollup* row below uses a
/// nil category id for the synthetic Uncategorized line.
struct BudgetCategory: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var plannedCents: Int
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case plannedCents = "planned_cents"
        case sortOrder = "sort_order"
    }
}

/// A rule routing transactions into a category. Merchant rules beat Plaid
/// category rules, and a longer merchant string beats a shorter one.
struct CategoryRule: Codable, Identifiable, Equatable {
    let id: UUID
    let categoryId: UUID
    let matchType: String
    let matchValue: String

    enum CodingKeys: String, CodingKey {
        case id
        case categoryId = "category_id"
        case matchType = "match_type"
        case matchValue = "match_value"
    }
}

/// One row of `category_spend()` — a category's planned and actual for a month.
struct CategorySpendRow: Codable, Identifiable, Equatable {
    let period: String              // "yyyy-MM-dd", first day of the month
    /// Nil for the Uncategorized line, which is spending no rule claimed.
    let categoryId: UUID?
    let categoryName: String
    let plannedCents: Int
    let spentCents: Int
    let txnCount: Int
    let sortOrder: Int

    var id: String { "\(period)-\(categoryId?.uuidString ?? "uncategorized")" }
    var isUncategorized: Bool { categoryId == nil }

    /// The month this row covers, for the queries that take a date. Parsed in
    /// the device timezone so it round-trips back to the same "yyyy-MM-01".
    var periodDate: Date? {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        parser.locale = Locale(identifier: "en_US_POSIX")
        return parser.date(from: period)
    }

    /// Positive means room left, negative means over. The sign is the answer.
    var remainingCents: Int { plannedCents - spentCents }
    var isOver: Bool { plannedCents > 0 && spentCents > plannedCents }

    var progress: Double {
        guard plannedCents > 0 else { return 0 }
        return min(1.0, max(0.0, Double(spentCents) / Double(plannedCents)))
    }

    enum CodingKeys: String, CodingKey {
        case period
        case categoryId = "category_id"
        case categoryName = "category_name"
        case plannedCents = "planned_cents"
        case spentCents = "spent_cents"
        case txnCount = "txn_count"
        case sortOrder = "sort_order"
    }

    init(period: String, categoryId: UUID?, categoryName: String,
         plannedCents: Int, spentCents: Int, txnCount: Int, sortOrder: Int) {
        self.period = period
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.plannedCents = plannedCents
        self.spentCents = spentCents
        self.txnCount = txnCount
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decode(String.self, forKey: .period)
        categoryId = try c.decodeIfPresent(UUID.self, forKey: .categoryId)
        categoryName = try c.decode(String.self, forKey: .categoryName)
        plannedCents = try c.decode(Int.self, forKey: .plannedCents)
        // spent_cents is a Postgres bigint — same string/number ambiguity as
        // MonthlySpendRow, and the same reason not to gamble on it.
        if let value = try? c.decode(Int.self, forKey: .spentCents) {
            spentCents = value
        } else if let text = try? c.decode(String.self, forKey: .spentCents), let value = Int(text) {
            spentCents = value
        } else {
            spentCents = 0
        }
        txnCount = try c.decode(Int.self, forKey: .txnCount)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
    }
}

/// A month's worth of budget lines, newest month first on the screen.
struct CategoryMonth: Identifiable, Equatable {
    let period: Date
    let label: String
    let shortLabel: String
    let isCurrent: Bool
    let rows: [CategorySpendRow]

    var id: Date { period }

    /// Planned totals exclude Uncategorized — it has no plan by definition,
    /// and counting its zero would make the budget look bigger than it is.
    var plannedCents: Int { rows.filter { !$0.isUncategorized }.reduce(0) { $0 + $1.plannedCents } }
    /// Spent totals include it: the money left the account either way.
    var spentCents: Int { rows.reduce(0) { $0 + $1.spentCents } }
    var overCount: Int { rows.filter(\.isOver).count }
    var uncategorizedCents: Int { rows.first(where: \.isUncategorized)?.spentCents ?? 0 }
}

enum CategoryMath {
    /// Group flat rollup rows into months, newest first, each month's lines in
    /// the user's own order with Uncategorized last.
    static func months(
        rows: [CategorySpendRow],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [CategoryMonth] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        let longLabel = DateFormatter()
        longLabel.timeZone = timeZone
        longLabel.setLocalizedDateFormatFromTemplate("MMMM y")
        let shortLabel = DateFormatter()
        shortLabel.timeZone = timeZone
        shortLabel.setLocalizedDateFormatFromTemplate("MMMM")

        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start

        var byPeriod: [Date: [CategorySpendRow]] = [:]
        for row in rows {
            guard let date = parser.date(from: row.period) else { continue }
            byPeriod[calendar.startOfDay(for: date), default: []].append(row)
        }

        return byPeriod.keys.sorted(by: >).map { period in
            CategoryMonth(
                period: period,
                label: longLabel.string(from: period),
                shortLabel: shortLabel.string(from: period),
                isCurrent: currentMonth.map {
                    calendar.isDate(period, equalTo: $0, toGranularity: .month)
                } ?? false,
                rows: (byPeriod[period] ?? []).sorted {
                    ($0.sortOrder, $0.categoryName) < ($1.sortOrder, $1.categoryName)
                }
            )
        }
    }
}

/// Mirrors the server-side threshold logic in check_overspend so the UI and
/// pushes always agree.
enum BudgetMath {
    static func status(spentCents: Int, limitCents: Int, warnPct: Int) -> SpendStatus {
        guard limitCents > 0 else { return .under }
        if spentCents >= limitCents { return .over }
        if spentCents * 100 >= limitCents * warnPct { return .warn }
        return .under
    }

    static func remainingCents(spentCents: Int, limitCents: Int) -> Int {
        limitCents - spentCents
    }

    /// Ring fill fraction, clamped to [0, 1].
    static func progress(spentCents: Int, limitCents: Int) -> Double {
        guard limitCents > 0 else { return 0 }
        return min(1.0, max(0.0, Double(spentCents) / Double(limitCents)))
    }

    static func dollars(_ cents: Int) -> String {
        let value = Double(cents) / 100.0
        return value.formatted(.currency(code: "USD"))
    }

    /// Rounded to the dollar. Month and year totals run to five figures, where
    /// the cents are noise that costs a line break on a narrow phone.
    static func wholeDollars(_ cents: Int) -> String {
        let value = (Double(cents) / 100.0).rounded()
        return value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}
