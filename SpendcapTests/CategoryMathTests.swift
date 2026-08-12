import XCTest
@testable import Spendcap

final class CategoryMathTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)!
    }

    private func row(_ period: String, _ name: String, planned: Int, spent: Int,
                     count: Int = 1, order: Int = 1, id: UUID? = UUID()) -> CategorySpendRow {
        CategorySpendRow(period: period, categoryId: id, categoryName: name,
                         plannedCents: planned, spentCents: spent,
                         txnCount: count, sortOrder: order)
    }

    private func uncategorized(_ period: String, spent: Int, count: Int = 3) -> CategorySpendRow {
        CategorySpendRow(period: period, categoryId: nil, categoryName: "Uncategorized",
                         plannedCents: 0, spentCents: spent, txnCount: count,
                         sortOrder: 2147483647)
    }

    private func months(_ rows: [CategorySpendRow], now: String = "2026-08-02") -> [CategoryMonth] {
        CategoryMath.months(rows: rows, now: date(now), timeZone: utc)
    }

    // MARK: - Grouping

    func testRowsGroupIntoMonthsNewestFirst() {
        let result = months([
            row("2026-07-01", "Food", planned: 60_000, spent: 100_878),
            row("2026-08-01", "Food", planned: 60_000, spent: 16_069),
        ])
        XCTAssertEqual(result.count, 2)
        // Abbreviated so the segment can never carry the same label as the
        // period menu's month items on Trends.
        XCTAssertEqual(result.first?.shortLabel, "Aug")
        XCTAssertEqual(result.last?.shortLabel, "Jul")
    }

    func testLinesKeepTheUsersOrderWithUncategorizedLast() {
        let result = months([
            uncategorized("2026-08-01", spent: 21_044),
            row("2026-08-01", "Debts", planned: 150_000, spent: 0, order: 7),
            row("2026-08-01", "Food", planned: 60_000, spent: 16_069, order: 1),
        ])
        XCTAssertEqual(result.first?.rows.map(\.categoryName),
                       ["Food", "Debts", "Uncategorized"])
    }

    func testCurrentMonthIsFlagged() {
        let result = months([
            row("2026-08-01", "Food", planned: 60_000, spent: 16_069),
            row("2026-07-01", "Food", planned: 60_000, spent: 100_878),
        ])
        XCTAssertEqual(result.first?.isCurrent, true)
        XCTAssertEqual(result.last?.isCurrent, false)
    }

    func testUnparseablePeriodIsDropped() {
        XCTAssertTrue(months([row("nonsense", "Food", planned: 1, spent: 1)]).isEmpty)
    }

    // MARK: - Totals

    /// Uncategorized has no plan by definition. Counting it in the planned
    /// total would make the budget look bigger than it is; leaving it out of
    /// the spent total would hide money that actually left the account.
    func testPlannedExcludesUncategorizedButSpentIncludesIt() {
        let month = months([
            row("2026-07-01", "Food", planned: 60_000, spent: 100_878, order: 1),
            row("2026-07-01", "Debts", planned: 150_000, spent: 438_102, order: 2),
            uncategorized("2026-07-01", spent: 412_882),
        ]).first!
        XCTAssertEqual(month.plannedCents, 210_000)
        XCTAssertEqual(month.spentCents, 100_878 + 438_102 + 412_882)
        XCTAssertEqual(month.uncategorizedCents, 412_882)
    }

    /// The debt totals feed the chart card's reserve, so they must count only
    /// lines *tagged* debt — a line merely named "Debts" is untagged and does
    /// not qualify, the same rule that makes rent a field, not a name-guess.
    func testDebtTotalsCountOnlyDebtTaggedLines() {
        let tagged = CategorySpendRow(
            period: "2026-08-01", categoryId: UUID(), categoryName: "Loans",
            plannedCents: 100_000, spentCents: 40_000, txnCount: 2,
            sortOrder: 3, kind: .debt)
        let month = months([
            row("2026-08-01", "Food", planned: 60_000, spent: 16_069, order: 1),
            // Named "Debts" but untagged (row() leaves kind nil) — must not count.
            row("2026-08-01", "Debts", planned: 250_000, spent: 115_176, order: 2),
            tagged,
        ]).first!
        XCTAssertEqual(month.debtPlannedCents, 100_000)
        XCTAssertEqual(month.debtSpentCents, 40_000)
    }

    func testOverCountCountsOnlyLinesPastTheirPlan() {
        let month = months([
            row("2026-07-01", "Food", planned: 60_000, spent: 100_878, order: 1),     // over
            row("2026-07-01", "Transport", planned: 30_000, spent: 25_702, order: 2), // under
            row("2026-07-01", "Haircuts", planned: 40_000, spent: 40_000, order: 3),  // exactly at plan
            uncategorized("2026-07-01", spent: 412_882),                              // no plan
        ]).first!
        XCTAssertEqual(month.overCount, 1)
    }

    // MARK: - Row arithmetic

    func testRemainingIsSignedAndProgressClamps() {
        let over = row("2026-07-01", "Food", planned: 60_000, spent: 100_878)
        XCTAssertTrue(over.isOver)
        XCTAssertEqual(over.remainingCents, -40_878)
        XCTAssertEqual(over.progress, 1.0)

        let under = row("2026-07-01", "Transport", planned: 30_000, spent: 25_702)
        XCTAssertFalse(under.isOver)
        XCTAssertEqual(under.remainingCents, 4_298)
        XCTAssertEqual(under.progress, 25_702.0 / 30_000.0, accuracy: 0.0001)
    }

    /// A line with no planned amount can't be "over" — there is nothing to be
    /// over — and must not divide by zero drawing its bar.
    func testUnplannedLineIsNeverOver() {
        let line = uncategorized("2026-07-01", spent: 412_882)
        XCTAssertFalse(line.isOver)
        XCTAssertEqual(line.progress, 0)
        XCTAssertTrue(line.isUncategorized)
    }

    // MARK: - Decoding

    func testRowDecodesNullCategoryAndBigintSpend() throws {
        let json = """
        [{"period":"2026-07-01","category_id":null,"category_name":"Uncategorized",
          "planned_cents":0,"spent_cents":412882,"txn_count":35,"sort_order":2147483647},
         {"period":"2026-07-01","category_id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301",
          "category_name":"Food","planned_cents":60000,"spent_cents":"100878",
          "txn_count":39,"sort_order":1}]
        """.data(using: .utf8)!
        let rows = try JSONDecoder().decode([CategorySpendRow].self, from: json)
        XCTAssertNil(rows[0].categoryId)
        XCTAssertTrue(rows[0].isUncategorized)
        XCTAssertEqual(rows[1].spentCents, 100_878)
        XCTAssertNotNil(rows[1].categoryId)
    }

    /// The kind tag decodes when known and reads as untagged when the server
    /// grows a value this build has never heard of — a whole screen of budget
    /// lines must not fail to decode over one new tag.
    func testKindDecodesAndToleratesUnknownValues() throws {
        let json = #"""
        [{"period":"2026-08-01","category_id":"11111111-1111-1111-1111-111111111111","category_name":"Rent / Wifi / Utilities","planned_cents":200000,"spent_cents":0,"txn_count":0,"sort_order":1,"kind":"rent"},
         {"period":"2026-08-01","category_id":"22222222-2222-2222-2222-222222222222","category_name":"Mystery","planned_cents":0,"spent_cents":0,"txn_count":0,"sort_order":2,"kind":"cryptozoology"},
         {"period":"2026-08-01","category_id":null,"category_name":"Uncategorized","planned_cents":0,"spent_cents":100,"txn_count":1,"sort_order":2147483647,"kind":null}]
        """#
        let rows = try JSONDecoder().decode([CategorySpendRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].kind, .rent)
        XCTAssertNil(rows[1].kind, "an unknown kind reads as untagged, not a decode failure")
        XCTAssertNil(rows[2].kind)
    }
}
