import Foundation

/// How a transaction introduces itself, shared by every screen so a row
/// cannot change identity between Activity and a budget drill-down.
///
/// The interesting case is bank fees. Wells Fargo names an overdraft fee
/// after the purchase that overdrew the account, and Plaid extracts that
/// merchant ("Affirm", "Lyft") into merchant_name — so a $35 fee masquerades
/// as another charge from the merchant. A BANK_FEES row therefore never takes
/// a merchant's name: it is "Overdraft fee" when the bank's own text says so,
/// and "Bank fee" when Plaid erased the text entirely — the category alone
/// cannot prove "overdraft" (a monthly service fee is BANK_FEES too).
///
/// Mirrored exactly by `txn_display_name()` server-side (0018), where the
/// same string is what category rules match — so reassigning a row named
/// "Overdraft fee" writes a rule that actually fires.
enum TransactionNaming {
    static func displayName(name: String, merchantName: String?, category: String?) -> String {
        if category == "BANK_FEES" {
            return name.range(of: "overdraft fee", options: .caseInsensitive) != nil
                ? "Overdraft fee"
                : "Bank fee"
        }
        let merchant = merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
        return merchant.isEmpty ? name : merchant
    }

    /// What a reassignment rule should match on, so filing a transaction once
    /// keeps working next month.
    ///
    /// Bank-transfer descriptors carry a date and a reference number that are
    /// unique per transaction — "PAYPAL INST XFER 260805 PYPL PAYMTHLY …",
    /// "ZELLE TO CARLO CHAMAINE ON 07/30 REF # WFCT22GS4599" — so a rule
    /// written from the whole string can never match the next month's copy,
    /// and the same payment had to be refiled every month (three one-shot
    /// rules for three months of one PayPal payment, weekly ones for
    /// haircuts). This keeps the longest run of *stable* tokens instead:
    /// dates, long numbers, mixed letter–digit reference codes, and dollar
    /// amounts are volatile; what survives is the phrase that recurs
    /// ("PYPL PAYMTHLY DIVINE DAVIS", "ZELLE TO CARLO CHAMAINE").
    ///
    /// A candidate shorter than 8 characters falls back to the exact string:
    /// a too-short contains-match would claim strangers, and a one-shot rule
    /// is the lesser wrong. Short clean merchant names ("Lyft", "Coqodaq")
    /// pass through unchanged either way — they contain nothing volatile.
    static func stableMatchValue(from name: String) -> String {
        func isVolatile(_ token: Substring) -> Bool {
            let s = String(token)
            // Dates: 07/09, 07/30/26.
            if s.range(of: #"^\d{1,2}/\d{1,2}(/\d{2,4})?$"#, options: .regularExpression) != nil {
                return true
            }
            // Long pure numbers (compact dates, account refs). Four digits or
            // fewer stay — "CARD 9424" is the stable part of a descriptor.
            if s.range(of: #"^\d{5,}$"#, options: .regularExpression) != nil { return true }
            // Reference codes: letters and digits mixed, long enough not to
            // be a word ("S466190338974488", "IB0Z59K433", "WAY2SAVE" too —
            // an acceptable loss, the surrounding phrase still identifies it).
            if s.count >= 6, s.contains(where: \.isNumber), s.contains(where: \.isLetter) {
                return true
            }
            // Amounts and bare reference markers.
            if s.hasPrefix("$") || s.hasPrefix("#") { return true }
            return false
        }

        let tokens = name.split(separator: " ")
        var best: [Substring] = []
        var run: [Substring] = []
        for token in tokens {
            if isVolatile(token) {
                if run.joined(separator: " ").count > best.joined(separator: " ").count { best = run }
                run = []
            } else {
                run.append(token)
            }
        }
        if run.joined(separator: " ").count > best.joined(separator: " ").count { best = run }

        // A run often ends on the connective that introduced the volatile bit
        // ("… ON 07/30", "… REF #…") — the connective carries no identity.
        let connectives: Set<String> = ["ON", "REF", "TO", "FROM"]
        while let last = best.last, connectives.contains(String(last).uppercased()) {
            best.removeLast()
        }

        let candidate = best.joined(separator: " ")
        return candidate.count >= 8 ? candidate : name
    }
}

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
        TransactionNaming.displayName(name: name, merchantName: merchantName, category: category)
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
    /// The account the statement belongs to, embedded by PostgREST.
    struct Account: Codable, Equatable {
        let name: String?
        let mask: String?
    }

    let id: UUID
    let year: Int
    let month: Int
    let storagePath: String?
    let byteSize: Int?
    let accounts: Account?

    var isAvailable: Bool { storagePath != nil }

    /// "Everyday Checking ...1395". Nil only for rows written before the
    /// account was known, which the UI then simply omits.
    var accountLabel: String? {
        let name = accounts?.name?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty { return name }
        if let mask = accounts?.mask, !mask.isEmpty { return "\u{2022}\u{2022}\u{2022}\u{2022} \(mask)" }
        return nil
    }

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
        case id, year, month, accounts
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
    /// Calendar weekday, 1 = Sunday … 7 = Saturday — resolved when the series
    /// is built, where the timezone is known. Deriving it from `date` at
    /// display time would use the device timezone and can shift a midnight
    /// bucket onto the wrong day of the week.
    let weekday: Int

    var id: Date { date }

    /// Monday through Thursday — the days the breakdown averages. There is no
    /// weekend counterpart on purpose: Wells Fargo dates weekend purchases to
    /// Monday (zero Sat/Sun rows across the whole history, and authorized_date
    /// mirrors the post date), so a Sat+Sun bucket would always read $0.
    var isMonToThu: Bool { (2...5).contains(weekday) }
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

    /// The discretionary budget and what has already come out of it, filled in
    /// from the category rollup once it loads (zero until then, which hides
    /// the figure rather than showing a wrong one).
    ///
    /// Divine's model: the untagged budget lines — Food and Socializing,
    /// $1,200/month between them — are the money that is actually free;
    /// everything tagged with a committed kind (rent, debts, hair, transport,
    /// savings) was spoken for before the month started. Spending outside the
    /// committed lines, Uncategorized included, draws the budget down. Note
    /// the month cap and the committed lines play no part here — a debt
    /// payment can neither shrink nor free up food money.
    var discretionaryPlannedCents: Int = 0
    var discretionarySpentCents: Int = 0

    /// The month's Monday–Sunday buckets, filled in once `discretionary_daily`
    /// lands. Nil until then, which hides the figure rather than showing a
    /// wrong one — the same rule the discretionary totals above follow.
    ///
    /// This replaced a flat `(planned - spent) / 4` on 2026-08-16. That figure
    /// re-spread the whole month's remaining money over four equal weeks every
    /// time it was read, so an underspent week never banked anything and an
    /// overspent one was quietly forgiven by a quarter of the shortfall. See
    /// `WeekMath` for the rule that replaced it.
    var weekStats: WeekStats?

    /// "Free to spend this week": this week's bucket less what this week has
    /// already spent. Negative means the week is over its bucket, and it stays
    /// negative until Monday recuts it.
    var freeToSpendThisWeekCents: Int {
        weekStats?.freeToSpendThisWeekCents ?? 0
    }

    /// The week the figure above describes, for the caption under it. A bucket
    /// whose edges you cannot see is hard to argue with.
    var currentWeek: SpendWeek? { weekStats?.currentWeek }

    /// Mean spend across the Monday–Thursday days elapsed.
    var monToThuAverageCents: Int {
        let days = series.filter(\.isMonToThu)
        guard !days.isEmpty else { return 0 }
        return days.reduce(0) { $0 + $1.spentCents } / days.count
    }

    var monToThuDaysElapsed: Int { series.filter(\.isMonToThu).count }

    var daysOverCap: Int { series.filter { $0.spentCents > dailyLimitCents }.count }

    /// Fraction of the month's cap already spent, clamped to [0, 1].
    var capProgress: Double {
        guard monthCapCents > 0 else { return 0 }
        return min(1.0, max(0.0, Double(spentCents) / Double(monthCapCents)))
    }
}

/// Which month Trends is showing: this one, or one of the previous two.
///
/// Three months is what the period chip offers because it is what the data
/// supports — Plaid shares only what the bank gives, and the whole year already
/// has a screen of its own in Months. Everything here is pure so the awkward
/// parts (year boundaries, month lengths, which day a past month should be read
/// as of) are testable without a network.
enum TrendsPeriod: Int, CaseIterable, Identifiable {
    case thisMonth = 0
    case lastMonth = 1
    case twoMonthsAgo = 2

    var id: Int { rawValue }

    /// How many whole months back from the current one.
    var monthsBack: Int { rawValue }

    var isCurrent: Bool { self == .thisMonth }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// First day of this period's month.
    ///
    /// Walks back a day at a time into the previous month rather than adding
    /// `-1 month`, which has to clamp on the 31st and makes the answer depend
    /// on today's day-of-month.
    func startOfMonth(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        let calendar = Self.calendar(timeZone)
        var start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        for _ in 0..<monthsBack {
            guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: start),
                  let previous = calendar.dateInterval(of: .month, for: dayBefore)?.start
            else { return start }
            start = previous
        }
        return start
    }

    /// Last day of this period's month — the right edge of the chart's axis,
    /// which is month end even for the current month, where the series itself
    /// stops today.
    func lastDayOfMonth(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        let calendar = Self.calendar(timeZone)
        let start = startOfMonth(now: now, timeZone: timeZone)
        guard let end = calendar.dateInterval(of: .month, for: start)?.end,
              let lastDay = calendar.date(byAdding: .day, value: -1, to: end)
        else { return start }
        return calendar.startOfDay(for: lastDay)
    }

    /// The date this period should be read as of.
    ///
    /// For the current month that is now, so the series stops today — an empty
    /// tail through to month end would read as "spent nothing" rather than
    /// "hasn't happened yet". A finished month has no such tail, so it is read
    /// as of its last day and the series covers all of it.
    func referenceDate(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        isCurrent ? now : lastDayOfMonth(now: now, timeZone: timeZone)
    }

    /// "August", and "November 2025" when the month is in a different year —
    /// bare month names would be ambiguous the moment the window crosses one.
    ///
    /// Built with an explicit-timezone formatter, not `.formatted()`, which
    /// silently uses the device timezone and can name the wrong month.
    func monthName(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let calendar = Self.calendar(timeZone)
        let start = startOfMonth(now: now, timeZone: timeZone)
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = .autoupdatingCurrent
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM y")
        return formatter.string(from: start)
    }

    /// What the period chip and the chart card call this month.
    func label(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        isCurrent ? "This month" : monthName(now: now, timeZone: timeZone)
    }

    /// A finished month is not still accumulating, so "so far" would be a lie.
    var spentCaption: String { isCurrent ? "Spent so far" : "Spent" }
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
            series.append(DailySpend(
                date: cursor,
                spentCents: spent,
                cumulativeCents: running,
                weekday: calendar.component(.weekday, from: cursor)
            ))
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

    /// Headline for the summary card.
    ///
    /// It has to be derived, not written down. A fixed "Last 12 months" sat
    /// above `totalCents`, which sums only the months actually on record — so
    /// an account with four months of history reported a four-month total
    /// under a twelve-month heading, and the subtitle underneath contradicted
    /// it in the same breath.
    var coverageTitle: String {
        switch monthsCovered {
        case 0: return "Monthly spending"
        case 1: return "1 month on record"
        default: return "Last \(monthsCovered) months"
        }
    }

    /// Says why the window is short, which the title no longer needs to.
    var coverageSubtitle: String {
        switch monthsCovered {
        case 0: return "Nothing on record yet"
        case 12...: return "A full year on record"
        default: return "All your bank shared"
        }
    }

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

// MARK: - Monthly balances

/// One row of `monthly_balances()` — the checking balance going into and out of
/// a calendar month, derived server-side from the current balance and the
/// posted transactions after each boundary.
struct MonthlyBalanceRow: Codable, Equatable {
    let period: String          // "yyyy-MM-dd", first day of the month
    let startCents: Int
    let endCents: Int

    enum CodingKeys: String, CodingKey {
        case period
        case startCents = "start_cents"
        case endCents = "end_cents"
    }

    init(period: String, startCents: Int, endCents: Int) {
        self.period = period
        self.startCents = startCents
        self.endCents = endCents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decode(String.self, forKey: .period)
        // Postgres bigint reaches us as a JSON number through PostgREST but as
        // a quoted string through some other serialisers — same tolerance as
        // MonthlySpendRow, and balances can legitimately be negative.
        startCents = try Self.flexibleInt(c, .startCents)
        endCents = try Self.flexibleInt(c, .endCents)
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

/// One month on the Months tab's checking-balance card.
struct MonthBalance: Identifiable, Equatable {
    /// First day of the month, in the user's timezone.
    let date: Date
    let startCents: Int
    let endCents: Int
    /// The month in progress — its "end" balance is the balance right now,
    /// not a closed figure.
    let isCurrent: Bool
    /// Rendered in the timezone the month was bucketed in, like MonthlySpend.
    let label: String

    var id: Date { date }

    /// What the month did to the balance: positive means the account grew.
    var diffCents: Int { endCents - startCents }
}

enum BalanceMath {
    /// Turn `monthly_balances()` rows into the card's series, oldest first.
    /// The function only emits months it can actually derive, so there is no
    /// has-data flag here — absence is the "no data" state.
    static func months(
        rows: [MonthlyBalanceRow],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [MonthBalance] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        let longLabel = DateFormatter()
        longLabel.timeZone = timeZone
        longLabel.setLocalizedDateFormatFromTemplate("MMMM y")

        let currentMonth = calendar.dateInterval(of: .month, for: now)?.start

        return rows.compactMap { row in
            guard let date = parser.date(from: row.period) else { return nil }
            let day = calendar.startOfDay(for: date)
            let isCurrent = currentMonth.map {
                calendar.isDate(day, equalTo: $0, toGranularity: .month)
            } ?? false
            return MonthBalance(
                date: day,
                startCents: row.startCents,
                endCents: row.endCents,
                isCurrent: isCurrent,
                label: longLabel.string(from: day)
            )
        }.sorted { $0.date < $1.date }
    }
}

// MARK: - Category budgets

/// A budget line's fixed type: what the line *is*, independent of whatever
/// the user named it. "Which line is rent?" has to be a field, not a guess
/// parsed out of "Rent / Wifi / Utilities". The raw values are the closed set
/// the `budget_categories_kind_check` constraint accepts (0016).
enum CategoryKind: String, CaseIterable, Codable, Identifiable {
    case rent
    case debt
    case food
    case transportation
    case utilities
    case subscriptions
    case entertainment
    case health
    case savings
    case personalCare = "personal_care"
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rent: return "Rent"
        case .debt: return "Debt"
        case .food: return "Food"
        case .transportation: return "Transportation"
        case .utilities: return "Utilities"
        case .subscriptions: return "Subscriptions"
        case .entertainment: return "Entertainment"
        case .health: return "Health"
        case .savings: return "Savings"
        case .personalCare: return "Personal care"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .rent: return "house.fill"
        case .debt: return "creditcard.fill"
        case .food: return "fork.knife"
        case .transportation: return "car.fill"
        case .utilities: return "bolt.fill"
        case .subscriptions: return "arrow.triangle.2.circlepath"
        case .entertainment: return "ticket.fill"
        case .health: return "heart.fill"
        case .savings: return "banknote.fill"
        case .personalCare: return "scissors"
        case .other: return "tag.fill"
        }
    }

    /// Committed money — spoken for before the month starts, so it is fenced
    /// off from the discretionary free-to-spend budget. The list is Divine's:
    /// rent, debts, hair, transport, savings. A line with no kind is
    /// discretionary; committed is opted into by tagging.
    var isCommitted: Bool {
        switch self {
        case .rent, .debt, .transportation, .savings, .personalCare: return true
        case .food, .utilities, .subscriptions, .entertainment, .health, .other: return false
        }
    }
}

/// One budget line. `id` nil is impossible here; the *rollup* row below uses a
/// nil category id for the synthetic Uncategorized line.
struct BudgetCategory: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var plannedCents: Int
    var sortOrder: Int
    /// Nil is untagged, a valid state — never defaulted to a guess.
    var kind: CategoryKind?

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case plannedCents = "planned_cents"
        case sortOrder = "sort_order"
    }

    init(id: UUID, name: String, plannedCents: Int, sortOrder: Int, kind: CategoryKind? = nil) {
        self.id = id
        self.name = name
        self.plannedCents = plannedCents
        self.sortOrder = sortOrder
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        plannedCents = try c.decode(Int.self, forKey: .plannedCents)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        // A kind this build doesn't know reads as untagged, not as a decode
        // failure for every category on the screen.
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind))
            .flatMap { $0 }.flatMap(CategoryKind.init(rawValue:))
    }
}

/// One transaction as the budget drill-down sees it: enough to explain itself
/// without a second round trip. The raw `name` is the bank's own description,
/// which is often the only thing that identifies what a $5.00 charge was.
struct CategoryTransaction: Codable, Identifiable, Equatable {
    let id: UUID
    let date: String
    let authorizedDate: String?
    let name: String
    let merchantName: String?
    let plaidCategory: String?
    let amountCents: Int
    let pending: Bool
    let isBackfill: Bool
    let accountName: String?
    let accountMask: String?

    enum CodingKeys: String, CodingKey {
        case id, date, name, pending
        case authorizedDate = "authorized_date"
        case merchantName = "merchant_name"
        case plaidCategory = "plaid_category"
        case amountCents = "amount_cents"
        case isBackfill = "is_backfill"
        case accountName = "account_name"
        case accountMask = "account_mask"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        authorizedDate = try c.decodeIfPresent(String.self, forKey: .authorizedDate)
        name = try c.decode(String.self, forKey: .name)
        merchantName = try c.decodeIfPresent(String.self, forKey: .merchantName)
        plaidCategory = try c.decodeIfPresent(String.self, forKey: .plaidCategory)
        if let value = try? c.decode(Int.self, forKey: .amountCents) {
            amountCents = value
        } else if let text = try? c.decode(String.self, forKey: .amountCents), let value = Int(text) {
            amountCents = value
        } else {
            amountCents = 0
        }
        pending = try c.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        isBackfill = try c.decodeIfPresent(Bool.self, forKey: .isBackfill) ?? false
        accountName = try c.decodeIfPresent(String.self, forKey: .accountName)
        accountMask = try c.decodeIfPresent(String.self, forKey: .accountMask)
    }

    init(id: UUID, date: String, authorizedDate: String? = nil, name: String,
         merchantName: String? = nil, plaidCategory: String? = nil, amountCents: Int,
         pending: Bool = false, isBackfill: Bool = false,
         accountName: String? = nil, accountMask: String? = nil) {
        self.id = id
        self.date = date
        self.authorizedDate = authorizedDate
        self.name = name
        self.merchantName = merchantName
        self.plaidCategory = plaidCategory
        self.amountCents = amountCents
        self.pending = pending
        self.isBackfill = isBackfill
        self.accountName = accountName
        self.accountMask = accountMask
    }

    var displayName: String {
        TransactionNaming.displayName(name: name, merchantName: merchantName, category: plaidCategory)
    }

    /// "General services" — Plaid's SCREAMING_SNAKE made readable.
    var plaidCategoryLabel: String? {
        guard let plaidCategory, !plaidCategory.isEmpty else { return nil }
        return plaidCategory
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .prefix(1).uppercased()
            + plaidCategory.replacingOccurrences(of: "_", with: " ").lowercased().dropFirst()
    }

    var accountLabel: String? {
        guard let accountName, !accountName.isEmpty else { return nil }
        return accountName
    }

    /// The date the purchase was authorised, when the bank supplied one and it
    /// differs from the posting date — the gap is why a charge can land on a
    /// day you did not spend anything.
    var authorizedDifferentFromPosted: Bool {
        guard let authorizedDate else { return false }
        return authorizedDate != date
    }
}

/// One row of `month_activity()` — a transaction plus the budget line it
/// resolves to. `categoryName` is nil for money in, which belongs to no line.
struct ActivityRow: Codable, Identifiable, Equatable {
    let transaction: CategoryTransaction
    let categoryName: String?

    var id: UUID { transaction.id }

    /// Money out under the Plaid convention; money in is negative.
    var isInflow: Bool { transaction.amountCents < 0 }

    enum CodingKeys: String, CodingKey {
        case categoryName = "category_name"
    }

    init(from decoder: Decoder) throws {
        transaction = try CategoryTransaction(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categoryName = try c.decodeIfPresent(String.self, forKey: .categoryName)
    }

    init(transaction: CategoryTransaction, categoryName: String?) {
        self.transaction = transaction
        self.categoryName = categoryName
    }

    func encode(to encoder: Encoder) throws {
        try transaction.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(categoryName, forKey: .categoryName)
    }
}

/// A day's worth of activity, which is how a month is actually read.
struct ActivityDay: Identifiable, Equatable {
    let date: String
    let label: String
    let rows: [ActivityRow]

    var id: String { date }

    var outflowCents: Int { rows.filter { !$0.isInflow }.reduce(0) { $0 + $1.transaction.amountCents } }
}

enum ActivityMath {
    /// Group rows into days, newest first, preserving the server's ordering
    /// within each day.
    static func days(rows: [ActivityRow], timeZone: TimeZone = .current) -> [ActivityDay] {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        let label = DateFormatter()
        label.timeZone = timeZone
        label.setLocalizedDateFormatFromTemplate("EEEE d MMMM")

        var order: [String] = []
        var byDay: [String: [ActivityRow]] = [:]
        for row in rows {
            let key = row.transaction.date
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(row)
        }

        return order.map { key in
            ActivityDay(
                date: key,
                label: parser.date(from: key).map { label.string(from: $0) } ?? key,
                rows: byDay[key] ?? []
            )
        }
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
    /// The line's fixed type tag; nil for untagged lines and always nil for
    /// Uncategorized.
    let kind: CategoryKind?

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
        case period, kind
        case categoryId = "category_id"
        case categoryName = "category_name"
        case plannedCents = "planned_cents"
        case spentCents = "spent_cents"
        case txnCount = "txn_count"
        case sortOrder = "sort_order"
    }

    init(period: String, categoryId: UUID?, categoryName: String,
         plannedCents: Int, spentCents: Int, txnCount: Int, sortOrder: Int,
         kind: CategoryKind? = nil) {
        self.period = period
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.plannedCents = plannedCents
        self.spentCents = spentCents
        self.txnCount = txnCount
        self.sortOrder = sortOrder
        self.kind = kind
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
        // A kind this build doesn't know reads as untagged, not as a decode
        // failure that blanks every budget line on the screen.
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind))
            .flatMap { $0 }.flatMap(CategoryKind.init(rawValue:))
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

    /// The discretionary side of the month — what feeds the Trends card's
    /// "free to spend this week". A line is discretionary unless tagged with
    /// a committed kind, so the planned total is the untagged lines' plans
    /// (Uncategorized has no plan by definition) and the spent total includes
    /// Uncategorized: unclaimed spending came out of the free money, not out
    /// of rent.
    var discretionaryPlannedCents: Int {
        rows.filter { !$0.isUncategorized && $0.kind?.isCommitted != true }
            .reduce(0) { $0 + $1.plannedCents }
    }
    var discretionarySpentCents: Int {
        rows.filter { $0.kind?.isCommitted != true }
            .reduce(0) { $0 + $1.spentCents }
    }
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
        // Abbreviated on purpose, now that this card shares Trends with the
        // period menu: two controls both labeled "July" on one screen sent a
        // UI-test tap (and would send VoiceOver) to the wrong one. "Jul" the
        // segment and "July" the menu item can no longer be confused.
        shortLabel.setLocalizedDateFormatFromTemplate("MMM")

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
