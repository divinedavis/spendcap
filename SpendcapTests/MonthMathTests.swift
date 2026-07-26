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

    func testRemainingGoesNegativeWhenOverMonthlyCap() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 200_000)],
            dailyLimitCents: 5000,
            now: date("2026-04-02"), timeZone: utc
        )
        XCTAssertLessThan(stats.remainingCents, 0)
    }

    func testAverageAndProjection() {
        // $30 over 3 elapsed days = $10/day → projects to $300 across 30 days.
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 1000), txn("2026-04-02", 1000), txn("2026-04-03", 1000)],
            dailyLimitCents: 5000,
            now: date("2026-04-03"), timeZone: utc
        )
        XCTAssertEqual(stats.averagePerDayCents, 1000)
        XCTAssertEqual(stats.projectedCents, 30_000)
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
        XCTAssertEqual(stats.averagePerDayCents, 0)
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
