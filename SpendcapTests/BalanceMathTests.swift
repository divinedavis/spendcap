import XCTest
@testable import Spendcap

/// `monthly_balances()` does the deriving in Postgres; BalanceMath only has to
/// parse, label and flag the rows without inventing anything — these pin that.
final class BalanceMathTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)!
    }

    /// The shape `monthly_balances(12)` emits: one row per derivable month,
    /// each month's end equal to the next month's start, and balances that can
    /// be negative at either end.
    private func fourMonths() -> [MonthlyBalanceRow] {
        [
            MonthlyBalanceRow(period: "2026-05-01", startCents: -20_000, endCents: 50_000),
            MonthlyBalanceRow(period: "2026-06-01", startCents: 50_000, endCents: 65_000),
            MonthlyBalanceRow(period: "2026-07-01", startCents: 65_000, endCents: 130_000),
            MonthlyBalanceRow(period: "2026-08-01", startCents: 130_000, endCents: -10_000),
        ]
    }

    func testDiffIsEndMinusStart() {
        let months = BalanceMath.months(rows: fourMonths(), now: date("2026-08-12"), timeZone: utc)
        XCTAssertEqual(months.count, 4)
        XCTAssertEqual(months[0].diffCents, 70_000)
        XCTAssertEqual(months[3].diffCents, -140_000)
    }

    func testOnlyTheMonthInProgressIsCurrent() {
        let months = BalanceMath.months(rows: fourMonths(), now: date("2026-08-12"), timeZone: utc)
        XCTAssertEqual(months.map(\.isCurrent), [false, false, false, true])
    }

    func testRowsSortOldestFirstRegardlessOfInputOrder() {
        let months = BalanceMath.months(
            rows: fourMonths().reversed(), now: date("2026-08-12"), timeZone: utc
        )
        XCTAssertEqual(months.map(\.startCents), [-20_000, 50_000, 65_000, 130_000])
    }

    func testLabelsRenderInTheBucketTimezone() {
        // Midnight UTC on the 1st is still the previous month in New York; a
        // device-timezone label would call May "April".
        let months = BalanceMath.months(rows: fourMonths(), now: date("2026-08-12"), timeZone: utc)
        XCTAssertEqual(months.first?.label, "May 2026")
    }

    func testUnparseablePeriodIsDroppedNotCrashed() {
        let rows = [MonthlyBalanceRow(period: "not-a-date", startCents: 0, endCents: 0)]
            + fourMonths()
        let months = BalanceMath.months(rows: rows, now: date("2026-08-12"), timeZone: utc)
        XCTAssertEqual(months.count, 4)
    }

    /// PostgREST serialises bigint as a number, but other layers quote it —
    /// and a balance, unlike a spend total, is legitimately negative.
    func testRowDecodesQuotedAndNegativeCents() throws {
        let json = #"[{"period":"2026-08-01","start_cents":"130000","end_cents":-10000}]"#
        let rows = try JSONDecoder().decode([MonthlyBalanceRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].startCents, 130_000)
        XCTAssertEqual(rows[0].endCents, -10_000)
    }
}
