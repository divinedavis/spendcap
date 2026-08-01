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
