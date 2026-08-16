import XCTest
@testable import Spendcap

final class MonthMathTests: XCTestCase {

    /// Fixed timezone + fixed "now" so the series is deterministic regardless of
    /// where or when the suite runs.
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)!
    }

    private func txn(_ day: String, _ cents: Int) -> BankTransaction {
        BankTransaction(
            id: UUID(), date: day, name: "Test", merchantName: nil,
            category: nil, amountCents: cents, pending: false, isRemoved: false
        )
    }

    // MARK: - Series construction

    func testSeriesCoversEveryDayThroughToday() {
        // 10 April, so 10 rows — 1st through 10th inclusive.
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-03", 1000)],
            dailyLimitCents: 5000,
            now: date("2026-04-10"),
            timeZone: utc
        )
        XCTAssertEqual(stats.series.count, 10)
        XCTAssertEqual(stats.daysElapsed, 10)
        XCTAssertEqual(stats.daysInMonth, 30)
    }

    func testSeriesStopsAtTodayNotMonthEnd() {
        let stats = MonthMath.stats(
            transactions: [], dailyLimitCents: 5000,
            now: date("2026-04-02"), timeZone: utc
        )
        // An empty tail to the 30th would read as "spent nothing" rather than
        // "hasn't happened yet".
        XCTAssertEqual(stats.series.count, 2)
    }

    func testCumulativeIsRunningTotalAndCarriesAcrossEmptyDays() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 1000), txn("2026-04-03", 2500)],
            dailyLimitCents: 5000,
            now: date("2026-04-04"),
            timeZone: utc
        )
        XCTAssertEqual(stats.series.map(\.cumulativeCents), [1000, 1000, 3500, 3500])
        XCTAssertEqual(stats.series.map(\.spentCents), [1000, 0, 2500, 0])
        XCTAssertEqual(stats.spentCents, 3500)
    }

    func testMultipleTransactionsSameDayAreSummed() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 1000), txn("2026-04-01", 250)],
            dailyLimitCents: 5000,
            now: date("2026-04-01"), timeZone: utc
        )
        XCTAssertEqual(stats.series.first?.spentCents, 1250)
    }

    /// Money in is negative under the Plaid convention and must not offset the
    /// day's outflow — the cap tracks spending, not net position.
    func testInflowsAreIgnored() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 1000), txn("2026-04-01", -5000)],
            dailyLimitCents: 5000,
            now: date("2026-04-01"), timeZone: utc
        )
        XCTAssertEqual(stats.spentCents, 1000)
    }

    // MARK: - Rollups

    func testMonthCapAndRemaining() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 10_000)],
            dailyLimitCents: 5000,
            now: date("2026-04-05"), timeZone: utc
        )
        XCTAssertEqual(stats.monthCapCents, 5000 * 30)
        XCTAssertEqual(stats.remainingCents, 150_000 - 10_000)
    }

    /// Trends and Months must resolve a month's allowance identically, or the
    /// two screens disagree about whether the month is over budget.
    func testExplicitMonthlyCapReplacesTheDerivedOne() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 10_000)],
            dailyLimitCents: 5000,
            monthlyLimitCents: 900_000,
            now: date("2026-04-05"), timeZone: utc
        )
        XCTAssertEqual(stats.monthCapCents, 900_000)
        XCTAssertEqual(stats.remainingCents, 890_000)
        // The daily cap still colours the per-day bars.
        XCTAssertEqual(stats.dailyLimitCents, 5000)
    }

    /// "Free to spend this week" is the discretionary budget minus what has
    /// come out of it, over the weeks left in the month — the month cap plays
    /// no part, and committed spending (rent, debts, hair, transport, savings)
    /// can neither shrink nor free up the figure.
    func testFreeToSpendThisWeekPacesTheRemainderOverTheWeeksLeft() {
        var stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 183_184)],
            dailyLimitCents: 5000,
            monthlyLimitCents: 650_000,
            now: date("2026-04-12"), timeZone: utc
        )
        // $1,200 budget (Food + Socializing), $680 of it already spent.
        stats.discretionaryPlannedCents = 120_000
        stats.discretionarySpentCents = 68_000
        // April 12 of 30: the 12th through the 30th is 19 days, 19/7 weeks.
        XCTAssertEqual(stats.daysRemainingInMonth, 19)
        // $520 / (19/7) = $191.57 a week.
        XCTAssertEqual(stats.freeToSpendThisWeekCents, 19_157)
    }

    /// The same remainder is worth more per week the earlier it is asked
    /// about — the whole point of moving off a flat divisor.
    func testFreeToSpendThisWeekRisesAsTheMonthRunsOut() {
        func free(on day: String) -> Int {
            var stats = MonthMath.stats(
                transactions: [], dailyLimitCents: 5000,
                now: date(day), timeZone: utc
            )
            stats.discretionaryPlannedCents = 120_000
            stats.discretionarySpentCents = 68_000
            return stats.freeToSpendThisWeekCents
        }
        // $520 over 30, 19 and 8 days left: /(30/7), /(19/7), /(8/7).
        XCTAssertEqual(free(on: "2026-04-01"), 12_133)
        XCTAssertEqual(free(on: "2026-04-12"), 19_157)
        XCTAssertEqual(free(on: "2026-04-23"), 45_500)
    }

    /// Inside the last week the divisor floors at 1: the rest of the month is
    /// this week, so the figure is the whole remainder and never more. A
    /// fractional divisor below 1 would multiply the money up instead.
    func testFreeToSpendThisWeekNeverExceedsWhatIsActuallyLeft() {
        for day in ["2026-04-24", "2026-04-28", "2026-04-30"] {
            var stats = MonthMath.stats(
                transactions: [], dailyLimitCents: 5000,
                now: date(day), timeZone: utc
            )
            stats.discretionaryPlannedCents = 120_000
            stats.discretionarySpentCents = 68_000
            XCTAssertLessThanOrEqual(stats.daysRemainingInMonth, 7, "on \(day)")
            XCTAssertEqual(stats.freeToSpendThisWeekCents, 52_000, "on \(day)")
        }
    }

    func testFreeToSpendThisWeekGoesNegativeWhenTheBudgetIsOverspent() {
        var stats = MonthMath.stats(
            transactions: [],
            dailyLimitCents: 5000,
            now: date("2026-04-12"), timeZone: utc
        )
        stats.discretionaryPlannedCents = 120_000
        stats.discretionarySpentCents = 140_000
        // −$200 / (19/7), truncated toward zero like the positive side.
        XCTAssertEqual(stats.freeToSpendThisWeekCents, -7_368)
    }

    func testRemainingGoesNegativeWhenOverMonthlyCap() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 200_000)],
            dailyLimitCents: 5000,
            now: date("2026-04-02"), timeZone: utc
        )
        XCTAssertLessThan(stats.remainingCents, 0)
    }

    /// April 2026 starts on a Wednesday, so the first week has every kind of
    /// day: Wed/Thu/Mon/Tue count toward the Mon–Thu average, Fri/Sat/Sun do
    /// not — though everything still lands in the month total.
    func testMonToThuAverageExcludesFridayAndTheWeekend() {
        let stats = MonthMath.stats(
            transactions: [
                txn("2026-04-01", 1000),   // Wednesday — counts
                txn("2026-04-03", 2000),   // Friday — excluded
                txn("2026-04-04", 3000),   // Saturday — excluded
                txn("2026-04-05", 4000),   // Sunday — excluded
                txn("2026-04-06", 500),    // Monday — counts
            ],
            dailyLimitCents: 5000,
            now: date("2026-04-07"), timeZone: utc
        )
        // Mon–Thu days elapsed by Tue the 7th: Wed 1, Thu 2, Mon 6, Tue 7.
        XCTAssertEqual(stats.monToThuDaysElapsed, 4)
        XCTAssertEqual(stats.monToThuAverageCents, 1500 / 4)
        // Fri/Sat/Sun spending is in the month total, just not the average.
        XCTAssertEqual(stats.spentCents, 10_500)
    }

    /// The weekday is resolved in the series' own timezone. Midnight Monday in
    /// Auckland is still Sunday in UTC — a UTC-derived weekday would drop this
    /// Monday spend out of the Mon–Thu average entirely.
    func testWeekdayResolvesInTheSeriesTimezone() {
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        let aucklandDate = { (iso: String) -> Date in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = auckland
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: iso)!
        }
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-06", 1000)],   // Monday
            dailyLimitCents: 5000,
            now: aucklandDate("2026-04-07"),
            timeZone: auckland
        )
        // Wed 1, Thu 2, Mon 6, Tue 7 have elapsed; only Monday has spend.
        XCTAssertEqual(stats.monToThuDaysElapsed, 4)
        XCTAssertEqual(stats.monToThuAverageCents, 250)
    }

    func testDaysOverCapCountsStrictlyGreater() {
        let stats = MonthMath.stats(
            transactions: [
                txn("2026-04-01", 5001),   // over
                txn("2026-04-02", 5000),   // exactly at cap — not "over"
                txn("2026-04-03", 100),    // under
            ],
            dailyLimitCents: 5000,
            now: date("2026-04-03"), timeZone: utc
        )
        XCTAssertEqual(stats.daysOverCap, 1)
    }

    // MARK: - Edge cases

    func testEmptyMonthIsAllZeros() {
        let stats = MonthMath.stats(
            transactions: [], dailyLimitCents: 5000,
            now: date("2026-04-15"), timeZone: utc
        )
        XCTAssertEqual(stats.spentCents, 0)
        XCTAssertEqual(stats.monToThuAverageCents, 0)
        XCTAssertEqual(stats.daysOverCap, 0)
        XCTAssertEqual(stats.capProgress, 0)
    }

    func testZeroLimitDoesNotDivideByZero() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 1000)],
            dailyLimitCents: 0,
            now: date("2026-04-01"), timeZone: utc
        )
        XCTAssertEqual(stats.monthCapCents, 0)
        XCTAssertEqual(stats.capProgress, 0)
    }

    func testCapProgressClampsToOne() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 999_999)],
            dailyLimitCents: 5000,
            now: date("2026-04-01"), timeZone: utc
        )
        XCTAssertEqual(stats.capProgress, 1.0)
    }

    func testTransactionsOutsideTheMonthAreExcludedFromTheSeries() {
        // The query filters by month, but the math must not mis-bucket a stray
        // row if one arrives (e.g. a timezone edge on the 1st).
        let stats = MonthMath.stats(
            transactions: [txn("2026-03-31", 9999), txn("2026-04-02", 1000)],
            dailyLimitCents: 5000,
            now: date("2026-04-03"), timeZone: utc
        )
        XCTAssertEqual(stats.spentCents, 1000)
    }

    func testFebruaryLeapYearDayCount() {
        let stats = MonthMath.stats(
            transactions: [], dailyLimitCents: 5000,
            now: date("2028-02-10"), timeZone: utc
        )
        XCTAssertEqual(stats.daysInMonth, 29)
    }
}
