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

    enum CodingKeys: String, CodingKey {
        case dailyLimitCents = "daily_limit_cents"
        case warnPct = "warn_pct"
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

    var monthCapCents: Int { dailyLimitCents * daysInMonth }
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
                              daysInMonth: 0, dailyLimitCents: dailyLimitCents)
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
            dailyLimitCents: dailyLimitCents
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
    var dailyLimitCents: Int

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
        dailyLimitCents: Int,
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
                capCents: dailyLimitCents * days,
                changeFraction: change,
                hasData: hasData,
                isCurrent: isCurrent,
                label: longLabel.string(from: entry.date),
                shortLabel: shortLabel.string(from: entry.date)
            ))

            if hasData { previousWithData = entry.row.spentCents }
        }

        return YearStats(months: months, dailyLimitCents: dailyLimitCents)
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
}
