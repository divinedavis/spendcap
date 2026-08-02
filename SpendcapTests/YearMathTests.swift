import XCTest
@testable import Spendcap

final class YearMathTests: XCTestCase {

    /// Fixed timezone + fixed "now" so the 12-month window is deterministic
    /// regardless of where or when the suite runs.
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)!
    }

    private func row(_ period: String, _ cents: Int, _ count: Int = 10) -> MonthlySpendRow {
        MonthlySpendRow(period: period, spentCents: cents, txnCount: count)
    }

    /// What `monthly_spend(12)` returns on 2026-08-02 for a bank that started
    /// sharing history in May: nine empty months, then three months and a
    /// partial one.
    private func mayOnwards() -> [MonthlySpendRow] {
        [
            row("2025-09-01", 0, 0), row("2025-10-01", 0, 0), row("2025-11-01", 0, 0),
            row("2025-12-01", 0, 0), row("2026-01-01", 0, 0), row("2026-02-01", 0, 0),
            row("2026-03-01", 0, 0), row("2026-04-01", 0, 0),
            row("2026-05-01", 800_000, 147),
            row("2026-06-01", 700_000, 143),
            row("2026-07-01", 1_100_000, 204),
            row("2026-08-01", 40_000, 22),
        ]
    }

    private func stats(_ rows: [MonthlySpendRow], limit: Int = 5000,
                       now: String = "2026-08-02") -> YearStats {
        YearMath.stats(rows: rows, dailyLimitCents: limit, now: date(now), timeZone: utc)
    }

    // MARK: - Series construction

    func testEveryReturnedMonthBecomesARow() {
        XCTAssertEqual(stats(mayOnwards()).months.count, 12)
    }

    /// A month with no transactions on record before the bank's history starts
    /// is "no data", not "spent nothing" — the two claims look identical in a
    /// total and mean opposite things to the user.
    func testMonthsBeforeTheBanksHistoryAreNotTreatedAsZeroSpend() {
        let result = stats(mayOnwards())
        XCTAssertEqual(result.withData.count, 4)
        XCTAssertEqual(result.months.prefix(8).filter(\.hasData).count, 0)
        XCTAssertEqual(result.monthsCovered, 4)
    }

    /// A genuinely quiet month *inside* the shared history still counts.
    func testEmptyMonthAfterHistoryStartsStillCounts() {
        var rows = mayOnwards()
        rows[9] = row("2026-06-01", 0, 0)      // June: nothing spent, but on record
        let result = stats(rows)
        XCTAssertEqual(result.withData.count, 4)
        XCTAssertTrue(result.months[9].hasData)
    }

    func testCapIsDailyLimitTimesDaysInThatMonth() {
        let result = stats(mayOnwards(), limit: 5000)
        let may = result.months.first { $0.shortLabel == "May" }
        let june = result.months.first { $0.shortLabel == "Jun" }
        XCTAssertEqual(may?.capCents, 5000 * 31)
        XCTAssertEqual(june?.capCents, 5000 * 30)
    }

    func testFebruaryLeapYearCap() {
        let result = YearMath.stats(
            rows: [row("2028-02-01", 1000)], dailyLimitCents: 5000,
            now: date("2028-03-05"), timeZone: utc
        )
        XCTAssertEqual(result.months.first?.capCents, 5000 * 29)
    }

    // MARK: - Change between months

    func testChangeIsAgainstThePreviousMonth() {
        let result = stats(mayOnwards())
        // June $7,000 against May $8,000 = −12.5%.
        let june = result.months.first { $0.shortLabel == "Jun" }
        XCTAssertEqual(june?.changeFraction ?? 0, -0.125, accuracy: 0.0001)
        XCTAssertEqual(june?.changeLabel, "\u{2212}13%")
    }

    func testFirstMonthWithHistoryHasNoChangeFigure() {
        let result = stats(mayOnwards())
        XCTAssertNil(result.months.first { $0.shortLabel == "May" }?.changeFraction)
    }

    /// The month in progress is a partial total. Comparing it to a full month
    /// reads as a collapse on the 2nd and a surge on the 31st.
    func testCurrentMonthGetsNoChangeFigure() {
        let result = stats(mayOnwards())
        let august = result.months.last
        XCTAssertEqual(august?.isCurrent, true)
        XCTAssertNil(august?.changeFraction)
        XCTAssertNil(august?.changeLabel)
    }

    // MARK: - Rollups

    func testTotalIncludesThePartialCurrentMonth() {
        XCTAssertEqual(stats(mayOnwards()).totalCents, 800_000 + 700_000 + 1_100_000 + 40_000)
    }

    /// $400 on the 2nd of the month must not pull the monthly average down to
    /// something the user never spent.
    func testAverageExcludesTheCurrentMonth() {
        XCTAssertEqual(stats(mayOnwards()).averageCents, (800_000 + 700_000 + 1_100_000) / 3)
    }

    func testAverageFallsBackToTheCurrentMonthWhenItIsAllThereIs() {
        let result = stats([row("2026-08-01", 40_000, 22)])
        XCTAssertEqual(result.averageCents, 40_000)
    }

    func testHighestAndLowestSkipTheCurrentMonth() {
        let result = stats(mayOnwards())
        XCTAssertEqual(result.highest?.spentCents, 1_100_000)
        XCTAssertEqual(result.lowest?.spentCents, 700_000)   // not August's $400
    }

    func testMonthsOverCapCountsSettledMonthsOnly() {
        // $50/day → roughly $1,550 a month; every settled month here is over.
        let result = stats(mayOnwards(), limit: 5000)
        XCTAssertEqual(result.monthsOverCap, 3)
    }

    func testMonthsOverCapIsZeroWhenTheCapIsGenerous() {
        XCTAssertEqual(stats(mayOnwards(), limit: 100_000).monthsOverCap, 0)
    }

    // MARK: - Trend

    func testTrendNeedsFourSettledMonths() {
        // Three settled months plus the partial one — not enough to call.
        XCTAssertNil(stats(mayOnwards()).trendFraction)
    }

    func testTrendComparesTheLaterHalfToTheEarlier() {
        let rows = [
            row("2026-03-01", 100_000), row("2026-04-01", 100_000),
            row("2026-05-01", 150_000), row("2026-06-01", 150_000),
            row("2026-07-01", 0, 0),
        ]
        let result = YearMath.stats(rows: rows, dailyLimitCents: 5000,
                                    now: date("2026-07-15"), timeZone: utc)
        XCTAssertEqual(result.trendFraction ?? 0, 0.5, accuracy: 0.0001)
    }

    // MARK: - Edge cases

    func testNoHistoryAtAllIsEmptyRatherThanZeroed() {
        let result = stats((0..<12).map { row("2026-0\(($0 % 9) + 1)-01", 0, 0) })
        XCTAssertTrue(result.withData.isEmpty)
        XCTAssertEqual(result.totalCents, 0)
        XCTAssertEqual(result.averageCents, 0)
        XCTAssertNil(result.highest)
        XCTAssertNil(result.trendFraction)
    }

    func testUnparseablePeriodIsDroppedRatherThanCrashing() {
        let result = stats([row("not-a-date", 5000), row("2026-07-01", 5000)])
        XCTAssertEqual(result.months.count, 1)
    }

    func testZeroCapDoesNotMarkMonthsAsOver() {
        let result = stats(mayOnwards(), limit: 0)
        XCTAssertEqual(result.monthsOverCap, 0)
        XCTAssertFalse(result.months.contains { $0.isOverCap })
    }

    // MARK: - Decoding

    /// Postgres bigint arrives as a JSON number through PostgREST and as a
    /// quoted string through other serialisers; a year of totals must not fail
    /// to decode over that.
    func testRowDecodesBigintAsNumberOrString() throws {
        let json = """
        [{"period":"2026-07-01","spent_cents":1100565,"txn_count":204},
         {"period":"2026-08-01","spent_cents":"44751","txn_count":"22"}]
        """.data(using: .utf8)!
        let rows = try JSONDecoder().decode([MonthlySpendRow].self, from: json)
        XCTAssertEqual(rows.map(\.spentCents), [1_100_565, 44_751])
        XCTAssertEqual(rows.map(\.txnCount), [204, 22])
    }
}
