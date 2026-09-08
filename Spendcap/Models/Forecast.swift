import Foundation

// Forecast: where the checking balance lands at the end of the month, from
// what usually happens in one.
//
// The server (0029) says what recurred over the last few complete months and
// what the account holds right now; this file decides what counts as a
// regular, puts each expected occurrence on a day, prices the rest of the
// month at the everyday run-rate, and adds it up. Pure math over the rows so
// every rule here is unit-tested without a network — same split as
// monthly_spend()/YearMath and discretionary_daily()/WeekMath.

// MARK: - Rows from the server

/// One row of `forecast_recurring()`: a stable name that recurred, with the
/// shape of its typical month described rank by rank.
struct ForecastRecurringRow: Codable, Equatable {
    let who: String
    let isInflow: Bool
    let monthsSeen: Int
    let windowCount: Int
    let windowCents: Int
    /// `[r]` = how many window months had at least r+1 occurrences. Monotone
    /// non-increasing by construction, so the qualifying ranks are a prefix.
    let rankMonths: [Int]
    /// `[r]` = median day-of-month of the (r+1)-th occurrence.
    let rankDay: [Int]
    /// `[r]` = median amount of the (r+1)-th occurrence, always positive.
    let rankCents: [Int]
    let thisMonthCount: Int
    let thisMonthCents: Int

    enum CodingKeys: String, CodingKey {
        case who
        case isInflow = "is_inflow"
        case monthsSeen = "months_seen"
        case windowCount = "window_count"
        case windowCents = "window_cents"
        case rankMonths = "rank_months"
        case rankDay = "rank_day"
        case rankCents = "rank_cents"
        case thisMonthCount = "this_month_count"
        case thisMonthCents = "this_month_cents"
    }

    init(who: String, isInflow: Bool, monthsSeen: Int, windowCount: Int, windowCents: Int,
         rankMonths: [Int], rankDay: [Int], rankCents: [Int],
         thisMonthCount: Int, thisMonthCents: Int) {
        self.who = who
        self.isInflow = isInflow
        self.monthsSeen = monthsSeen
        self.windowCount = windowCount
        self.windowCents = windowCents
        self.rankMonths = rankMonths
        self.rankDay = rankDay
        self.rankCents = rankCents
        self.thisMonthCount = thisMonthCount
        self.thisMonthCents = thisMonthCents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        who = try c.decode(String.self, forKey: .who)
        isInflow = try c.decode(Bool.self, forKey: .isInflow)
        monthsSeen = try ForecastDecoding.int(c, .monthsSeen)
        windowCount = try ForecastDecoding.int(c, .windowCount)
        windowCents = try ForecastDecoding.int(c, .windowCents)
        rankMonths = try ForecastDecoding.ints(c, .rankMonths)
        rankDay = try ForecastDecoding.ints(c, .rankDay)
        rankCents = try ForecastDecoding.ints(c, .rankCents)
        thisMonthCount = try ForecastDecoding.int(c, .thisMonthCount)
        thisMonthCents = try ForecastDecoding.int(c, .thisMonthCents)
    }
}

/// One row of `forecast_flows()`: a month's checking totals. The balance and
/// the pending figures ride on every row; only the current month's pending
/// figures are non-zero.
struct ForecastFlowRow: Codable, Equatable {
    let period: String          // "yyyy-MM-dd", first day of the month
    let outflowCents: Int
    let inflowCents: Int
    let txnCount: Int
    let pendingOutCents: Int
    let pendingInCents: Int
    let balanceCents: Int

    enum CodingKeys: String, CodingKey {
        case period
        case outflowCents = "outflow_cents"
        case inflowCents = "inflow_cents"
        case txnCount = "txn_count"
        case pendingOutCents = "pending_out_cents"
        case pendingInCents = "pending_in_cents"
        case balanceCents = "balance_cents"
    }

    init(period: String, outflowCents: Int, inflowCents: Int, txnCount: Int,
         pendingOutCents: Int = 0, pendingInCents: Int = 0, balanceCents: Int) {
        self.period = period
        self.outflowCents = outflowCents
        self.inflowCents = inflowCents
        self.txnCount = txnCount
        self.pendingOutCents = pendingOutCents
        self.pendingInCents = pendingInCents
        self.balanceCents = balanceCents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decode(String.self, forKey: .period)
        outflowCents = try ForecastDecoding.int(c, .outflowCents)
        inflowCents = try ForecastDecoding.int(c, .inflowCents)
        txnCount = try ForecastDecoding.int(c, .txnCount)
        pendingOutCents = try ForecastDecoding.int(c, .pendingOutCents)
        pendingInCents = try ForecastDecoding.int(c, .pendingInCents)
        balanceCents = try ForecastDecoding.int(c, .balanceCents)
    }
}

/// Postgres bigints reach us as JSON numbers through PostgREST and as quoted
/// strings through other serialisers — the same tolerance MonthlySpendRow has,
/// extended to the bigint arrays these rows carry.
enum ForecastDecoding {
    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Int {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let text = try? c.decode(String.self, forKey: key), let value = Int(text) { return value }
        if let value = try? c.decode(Double.self, forKey: key) { return Int(value) }
        return 0
    }

    static func ints<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> [Int] {
        if let values = try? c.decode([Int].self, forKey: key) { return values }
        if let texts = try? c.decode([String].self, forKey: key) { return texts.compactMap { Int($0) } }
        if let values = try? c.decode([Double].self, forKey: key) { return values.map { Int($0) } }
        return []
    }
}

// MARK: - Derived

/// One transaction the forecast expects before the month ends.
struct PredictedTransaction: Identifiable, Equatable {
    let who: String
    /// The day it is expected on, at start of day in the forecast's timezone.
    let date: Date
    /// Positive; direction is `isInflow`.
    let amountCents: Int
    let isInflow: Bool
    /// Its usual day has already passed this month without it posting. It is
    /// still counted — a bill that is late is not a bill that is cancelled —
    /// and placed on today so the list says "any day now" rather than a date
    /// in the past.
    let isOverdue: Bool
    /// "Sep 15", rendered in the forecast's timezone.
    let dateLabel: String

    var id: String { "\(who)|\(isInflow)|\(date.timeIntervalSince1970)" }

    var signedCents: Int { isInflow ? amountCents : -amountCents }
}

/// The forecast for the month in progress. Nil fields mean "cannot say yet";
/// the card hides itself on a nil stats value rather than showing a number
/// built on too little history.
struct ForecastStats: Equatable {
    /// Checking balance now, as the bank last reported it (posted money).
    let balanceCents: Int
    /// Authorised but not yet posted. The balance above does not reflect
    /// these; the forecast must.
    let pendingOutCents: Int
    let pendingInCents: Int
    /// Regular money in and out still expected this month, soonest first.
    let predicted: [PredictedTransaction]
    /// What a day of everything-else spending has cost over the window.
    let everydayPerDayCents: Int
    /// Days from today through the last day of the month, today included:
    /// bank data lags a day or two, so today's spending is usually not in yet.
    let daysLeft: Int
    /// Complete months the run-rate and the regulars were read from.
    let windowMonths: Int
    /// "Jun–Aug", the months behind the numbers.
    let windowLabel: String
    /// "Sep 30".
    let monthEndLabel: String

    var predictedInCents: Int { predicted.filter(\.isInflow).reduce(0) { $0 + $1.amountCents } }
    var predictedOutCents: Int { predicted.filter { !$0.isInflow }.reduce(0) { $0 + $1.amountCents } }
    var predictedInCount: Int { predicted.filter(\.isInflow).count }
    var predictedOutCount: Int { predicted.filter { !$0.isInflow }.count }
    var everydayCents: Int { everydayPerDayCents * daysLeft }

    /// Where the balance lands: what is there, less what is already spoken
    /// for, plus what regularly arrives, less the everyday days still to come.
    var projectedCents: Int {
        balanceCents - pendingOutCents + pendingInCents
            - predictedOutCents + predictedInCents
            - everydayCents
    }

    /// The balance the month effectively starts from once pending charges
    /// clear — what "today" really holds.
    var availableCents: Int { balanceCents - pendingOutCents + pendingInCents }
}

enum ForecastMath {
    /// A name that recurs more than this many times a month is everyday
    /// spending, not a set of bills — Lyft rides and grocery runs recur, but
    /// nothing about their fourth occurrence is a scheduled event. Three
    /// leaves room for twice-monthly payroll and a bill with an add-on.
    static let maxRegularOccurrences = 3

    /// The server returns nothing seen in fewer than two months, and the
    /// forecast is not attempted on fewer than two complete months of
    /// history: one month's bills are not yet a pattern.
    static let minWindowMonths = 2

    /// How many of the window months a rank must appear in to be expected:
    /// most of them. Two of three, two of two, four of six.
    static func requiredMonths(windowMonths: Int) -> Int {
        max(2, Int((Double(windowMonths) * 2 / 3).rounded(.up)))
    }

    /// The ranks of a row that count as regular occurrences — a prefix, since
    /// `rankMonths` is monotone. Empty when the name is everyday spending.
    static func regularRanks(_ row: ForecastRecurringRow, windowMonths: Int) -> Range<Int> {
        let needed = requiredMonths(windowMonths: windowMonths)
        let qualifying = row.rankMonths.prefix { $0 >= needed }.count
        guard qualifying >= 1, qualifying <= maxRegularOccurrences,
              row.rankDay.count >= qualifying, row.rankCents.count >= qualifying
        else { return 0..<0 }
        return 0..<qualifying
    }

    static func stats(
        recurring: [ForecastRecurringRow],
        flows: [ForecastFlowRow],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> ForecastStats? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        guard let interval = calendar.dateInterval(of: .month, for: now),
              let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count,
              let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end)
        else { return nil }
        let today = calendar.startOfDay(for: now)
        let todayDay = calendar.component(.day, from: today)
        let monthStart = calendar.startOfDay(for: interval.start)

        // The window is every flow row before this month; the current month's
        // row carries the anchor and the pending figures.
        let parsed = flows.compactMap { row -> (date: Date, row: ForecastFlowRow)? in
            guard let d = parser.date(from: row.period) else { return nil }
            return (calendar.startOfDay(for: d), row)
        }.sorted { $0.date < $1.date }
        let window = parsed.filter { $0.date < monthStart }
        guard window.count >= minWindowMonths, let anchor = parsed.last else { return nil }
        let windowMonths = window.count

        // Regulars: put each still-expected occurrence on a day.
        var predicted: [PredictedTransaction] = []
        var regularWindowOutCents = 0
        let dayLabel = DateFormatter()
        dayLabel.timeZone = timeZone
        dayLabel.setLocalizedDateFormatFromTemplate("MMM d")

        for row in recurring {
            let ranks = regularRanks(row, windowMonths: windowMonths)
            guard !ranks.isEmpty else { continue }
            if !row.isInflow { regularWindowOutCents += row.windowCents }
            // The first `thisMonthCount` occurrences have happened; the rest
            // of the regular ranks are still to come.
            for rank in ranks where rank >= row.thisMonthCount {
                let day = min(max(row.rankDay[rank], 1), daysInMonth)
                let overdue = day < todayDay
                guard let expected = calendar.date(byAdding: .day, value: (overdue ? todayDay : day) - 1,
                                                   to: monthStart) else { continue }
                predicted.append(PredictedTransaction(
                    who: row.who,
                    date: expected,
                    amountCents: row.rankCents[rank],
                    isInflow: row.isInflow,
                    isOverdue: overdue,
                    dateLabel: dayLabel.string(from: expected)
                ))
            }
        }
        predicted.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.amountCents != $1.amountCents { return $0.amountCents > $1.amountCents }
            return $0.who < $1.who
        }

        // Everyday: everything that left the account over the window that was
        // not a regular, per day. Money in that is not a regular is not
        // projected at all — refunds and loan disbursements are not income.
        let windowOut = window.reduce(0) { $0 + $1.row.outflowCents }
        let windowDays = window.reduce(0) { total, entry in
            total + (calendar.range(of: .day, in: .month, for: entry.date)?.count ?? 30)
        }
        let everydayPerDay = windowDays > 0
            ? max(0, windowOut - regularWindowOutCents) / windowDays
            : 0

        let monthLabel = DateFormatter()
        monthLabel.timeZone = timeZone
        monthLabel.setLocalizedDateFormatFromTemplate("MMM")
        let windowLabel: String
        if let first = window.first, let last = window.last, window.count > 1 {
            windowLabel = "\(monthLabel.string(from: first.date))\u{2013}\(monthLabel.string(from: last.date))"
        } else {
            windowLabel = window.first.map { monthLabel.string(from: $0.date) } ?? ""
        }

        return ForecastStats(
            balanceCents: anchor.row.balanceCents,
            pendingOutCents: anchor.date == monthStart ? anchor.row.pendingOutCents : 0,
            pendingInCents: anchor.date == monthStart ? anchor.row.pendingInCents : 0,
            predicted: predicted,
            everydayPerDayCents: everydayPerDay,
            daysLeft: daysInMonth - todayDay + 1,
            windowMonths: windowMonths,
            windowLabel: windowLabel,
            monthEndLabel: dayLabel.string(from: calendar.startOfDay(for: lastDay))
        )
    }
}
