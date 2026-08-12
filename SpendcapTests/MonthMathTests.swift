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

    /// Rent never posts through the linked account, so "left excluding rent"
    /// is the cap minus the $2,000 reserve minus the spend — all month, with
    /// no double-count when rent is paid, because it never lands in spend.
    func testRemainingExcludingRentReservesTwoThousand() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 183_184)],
            dailyLimitCents: 5000,
            monthlyLimitCents: 650_000,
            now: date("2026-04-12"), timeZone: utc
        )
        // $6,500 cap − $2,000 rent − $1,831.84 spent = $2,668.16. No debt
        // lines tagged, so the commitments figure is rent-only.
        XCTAssertEqual(stats.remainingExcludingCommitmentsCents, 266_816)
        XCTAssertFalse(stats.hasDebtLines)
    }

    func testRemainingExcludingRentGoesNegativeBeforeTheCapDoes() {
        let stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 500_000)],
            dailyLimitCents: 5000,
            monthlyLimitCents: 650_000,
            now: date("2026-04-12"), timeZone: utc
        )
        // $1,500 nominally left, but rent claims $2,000 of it.
        XCTAssertEqual(stats.remainingCents, 150_000)
        XCTAssertEqual(stats.remainingExcludingCommitmentsCents, -50_000)
    }

    /// Debt payments post *through* the linked account, so only the unpaid
    /// remainder of the plan is reserved — the paid part already sits in the
    /// spend and reserving the full plan would count it twice.
    func testDebtReserveIsOnlyTheUnpaidRemainderOfThePlan() {
        var stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 183_184)],
            dailyLimitCents: 5000,
            monthlyLimitCents: 650_000,
            now: date("2026-04-12"), timeZone: utc
        )
        // $2,500 planned, $1,151.76 already paid (and inside the spend above).
        stats.debtPlannedCents = 250_000
        stats.debtSpentCents = 115_176
        XCTAssertEqual(stats.debtReserveCents, 134_824)
        XCTAssertTrue(stats.hasDebtLines)
        // $6,500 − $2,000 rent − $1,348.24 unpaid debt − $1,831.84 spent.
        XCTAssertEqual(stats.remainingExcludingCommitmentsCents, 131_992)
    }

    /// Debt paid beyond its plan is not subtracted twice: the overage is in
    /// the spend already, so the reserve clamps to zero instead of going
    /// negative and handing the overage back.
    func testDebtPaidBeyondThePlanClampsTheReserveToZero() {
        var stats = MonthMath.stats(
            transactions: [txn("2026-04-01", 183_184)],
            dailyLimitCents: 5000,
            monthlyLimitCents: 650_000,
            now: date("2026-04-12"), timeZone: utc
        )
        stats.debtPlannedCents = 100_000
        stats.debtSpentCents = 115_176
        XCTAssertEqual(stats.debtReserveCents, 0)
        // Identical to the rent-only figure — the debt is fully paid.
        XCTAssertEqual(stats.remainingExcludingCommitmentsCents, 266_816)
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
