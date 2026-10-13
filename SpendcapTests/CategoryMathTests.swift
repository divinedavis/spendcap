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

    /// The discretionary totals feed "free to spend this week": untagged
    /// lines are the budget, committed-tagged lines (rent, debt, hair,
    /// transport, savings) are fenced off entirely, and Uncategorized
    /// spending draws the budget down without adding a plan.
    func testDiscretionaryTotalsFenceOffCommittedLines() {
        let committed = [
            CategorySpendRow(period: "2026-08-01", categoryId: UUID(),
                             categoryName: "Debts", plannedCents: 250_000,
                             spentCents: 115_176, txnCount: 9, sortOrder: 3, kind: .debt),
            CategorySpendRow(period: "2026-08-01", categoryId: UUID(),
                             categoryName: "Haircuts", plannedCents: 40_000,
                             spentCents: 10_000, txnCount: 1, sortOrder: 4, kind: .personalCare),
            CategorySpendRow(period: "2026-08-01", categoryId: UUID(),
                             categoryName: "Rent / Wifi / Utilities", plannedCents: 200_000,
                             spentCents: 0, txnCount: 0, sortOrder: 5, kind: .rent),
        ]
        let month = months([
            // Untagged = discretionary (row() leaves kind nil).
            row("2026-08-01", "Food", planned: 60_000, spent: 16_069, order: 1),
            row("2026-08-01", "Socializing", planned: 60_000, spent: 30_000, order: 2),
            uncategorized("2026-08-01", spent: 5_000),
        ] + committed).first!
        XCTAssertEqual(month.discretionaryPlannedCents, 120_000)
        XCTAssertEqual(month.discretionarySpentCents, 16_069 + 30_000 + 5_000)
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

    // MARK: - Spill-over (0033)

    private func spill(food foodSpent: Int, social socialSpent: Int,
                       socialPlanned: Int = 60_000) -> (food: CategorySpendRow, social: CategorySpendRow, month: CategoryMonth) {
        let socialId = UUID()
        let food = CategorySpendRow(period: "2026-10-01", categoryId: UUID(), categoryName: "Food",
                                    plannedCents: 60_000, spentCents: foodSpent, txnCount: 1,
                                    sortOrder: 1, overflowCategoryId: socialId)
        let social = row("2026-10-01", "Socializing", planned: socialPlanned, spent: socialSpent,
                         order: 2, id: socialId)
        let month = months([food, social, uncategorized("2026-10-01", spent: 5_000)],
                           now: "2026-10-08").first!
        return (month.rows[0], month.rows[1], month)
    }

    func testOverageMovesToTheOverflowLine() {
        let (food, social, _) = spill(food: 65_000, social: 19_400)
        XCTAssertEqual(food.overflowOutCents, 5_000)
        XCTAssertEqual(food.overflowTargetName, "Socializing")
        XCTAssertEqual(food.shownSpentCents, 60_000)
        XCTAssertFalse(food.isOver, "a line that handed on its overage is full, not over")
        XCTAssertEqual(food.remainingCents, 0)
        XCTAssertEqual(social.overflowInCents, 5_000)
        XCTAssertEqual(social.remainingCents, 60_000 - 19_400 - 5_000)
        XCTAssertEqual(social.overflowInProgress, 5_000.0 / 60_000.0, accuracy: 0.0001)
    }

    func testNothingMovesUnderPlan() {
        let (food, social, _) = spill(food: 52_000, social: 19_400)
        XCTAssertEqual(food.overflowOutCents, 0)
        XCTAssertEqual(social.overflowInCents, 0)
        XCTAssertEqual(food.remainingCents, 8_000)
    }

    func testSpillNeverChangesMonthTotals() {
        let (_, _, month) = spill(food: 90_000, social: 40_000)
        XCTAssertEqual(month.spentCents, 90_000 + 40_000 + 5_000)
        XCTAssertEqual(month.discretionarySpentCents, 135_000,
                       "discretionary must stay equal to discretionary_daily, which knows nothing of spill")
    }

    func testReceivingLineGoesOverWhenItCannotAbsorb() {
        let (food, social, month) = spill(food: 90_000, social: 40_000)
        XCTAssertFalse(food.isOver)
        XCTAssertTrue(social.isOver)
        XCTAssertEqual(social.remainingCents, -10_000)
        XCTAssertEqual(month.overCount, 1)
    }

    func testFullReceiverPassesTheRestDownTheChain() {
        // Food → Socializing → Transportation → Cash, owner's 2026-10-13 ask.
        let social = UUID(), transport = UUID(), cash = UUID()
        let rows = CategoryMath.spillOver([
            CategorySpendRow(period: "2026-10-01", categoryId: UUID(), categoryName: "Food",
                             plannedCents: 60_000, spentCents: 90_000, txnCount: 1, sortOrder: 1,
                             overflowCategoryId: social),
            CategorySpendRow(period: "2026-10-01", categoryId: social, categoryName: "Socializing",
                             plannedCents: 60_000, spentCents: 50_000, txnCount: 1, sortOrder: 2,
                             overflowCategoryId: transport),
            CategorySpendRow(period: "2026-10-01", categoryId: transport, categoryName: "Transportation",
                             plannedCents: 20_000, spentCents: 15_000, txnCount: 1, sortOrder: 3,
                             overflowCategoryId: cash),
            CategorySpendRow(period: "2026-10-01", categoryId: cash, categoryName: "Cash",
                             plannedCents: 30_000, spentCents: 0, txnCount: 0, sortOrder: 4),
        ])
        // Food's $300 over: $100 fills Socializing, $50 fills Transportation,
        // the last $150 lands on Cash.
        XCTAssertEqual(rows[0].overflowOutCents, 30_000)
        XCTAssertEqual(rows[1].overflowInCents, 30_000)
        XCTAssertEqual(rows[1].overflowOutCents, 20_000)
        XCTAssertEqual(rows[1].overflowTargetName, "Transportation")
        XCTAssertEqual(rows[2].overflowInCents, 20_000)
        XCTAssertEqual(rows[2].overflowOutCents, 15_000)
        XCTAssertEqual(rows[3].overflowInCents, 15_000)
        XCTAssertEqual(rows[3].remainingCents, 15_000)
        XCTAssertEqual(rows.map(\.shownSpentCents), [60_000, 60_000, 20_000, 15_000])
        XCTAssertFalse(rows.contains(where: \.isOver))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.shownSpentCents }, 155_000, "spill moves money, never adds it")
    }

    func testChainStopsWhereThereIsRoom() {
        let social = UUID(), transport = UUID()
        let rows = CategoryMath.spillOver([
            CategorySpendRow(period: "2026-10-01", categoryId: UUID(), categoryName: "Food",
                             plannedCents: 60_000, spentCents: 76_200, txnCount: 1, sortOrder: 1,
                             overflowCategoryId: social),
            CategorySpendRow(period: "2026-10-01", categoryId: social, categoryName: "Socializing",
                             plannedCents: 60_000, spentCents: 14_400, txnCount: 1, sortOrder: 2,
                             overflowCategoryId: transport),
            CategorySpendRow(period: "2026-10-01", categoryId: transport, categoryName: "Transportation",
                             plannedCents: 20_000, spentCents: 0, txnCount: 0, sortOrder: 3),
        ])
        XCTAssertEqual(rows[1].overflowOutCents, 0, "Socializing still has room, nothing moves on")
        XCTAssertEqual(rows[1].remainingCents, 60_000 - 14_400 - 16_200)
        XCTAssertEqual(rows[2].overflowInCents, 0)
    }

    func testEndOfChainGoesOver() {
        let social = UUID()
        let rows = CategoryMath.spillOver([
            CategorySpendRow(period: "2026-10-01", categoryId: UUID(), categoryName: "Food",
                             plannedCents: 100, spentCents: 200, txnCount: 1, sortOrder: 1,
                             overflowCategoryId: social),
            CategorySpendRow(period: "2026-10-01", categoryId: social, categoryName: "Socializing",
                             plannedCents: 100, spentCents: 130, txnCount: 1, sortOrder: 2,
                             overflowCategoryId: UUID()),
        ])
        XCTAssertEqual(rows[1].overflowOutCents, 0, "a missing target ends the chain")
        XCTAssertTrue(rows[1].isOver)
        XCTAssertEqual(rows[1].remainingCents, -130)
    }

    func testCycleCannotLoop() {
        let a = UUID(), b = UUID()
        let rows = CategoryMath.spillOver([
            CategorySpendRow(period: "2026-10-01", categoryId: a, categoryName: "A",
                             plannedCents: 100, spentCents: 150, txnCount: 1, sortOrder: 1,
                             overflowCategoryId: b),
            CategorySpendRow(period: "2026-10-01", categoryId: b, categoryName: "B",
                             plannedCents: 100, spentCents: 120, txnCount: 1, sortOrder: 2,
                             overflowCategoryId: a),
        ])
        // Each walk stops before revisiting its start, so each line hands
        // on only its own overage and the received money stays put.
        XCTAssertEqual(rows[0].overflowOutCents, 50)
        XCTAssertEqual(rows[1].overflowOutCents, 20)
        XCTAssertEqual(rows[0].shownSpentCents + rows[1].shownSpentCents, 270)
    }

    func testMissingTargetJustGoesOver() {
        let rows = CategoryMath.spillOver([
            CategorySpendRow(period: "2026-10-01", categoryId: UUID(), categoryName: "Food",
                             plannedCents: 60_000, spentCents: 65_000, txnCount: 1, sortOrder: 1,
                             overflowCategoryId: UUID()),
        ])
        XCTAssertEqual(rows[0].overflowOutCents, 0)
        XCTAssertTrue(rows[0].isOver)
    }

    func testOverflowIdDecodesAndIsOptional() throws {
        let json = """
        [{"period":"2026-10-01","category_id":"56B662F3-7D79-403B-A7F3-4361231F5383","category_name":"Food",
          "planned_cents":60000,"spent_cents":1,"txn_count":1,"sort_order":1,"kind":"food",
          "overflow_category_id":"56B662F3-7D79-403B-A7F3-4361231F5384"},
         {"period":"2026-10-01","category_id":null,"category_name":"Uncategorized",
          "planned_cents":0,"spent_cents":1,"txn_count":1,"sort_order":2147483647}]
        """
        let rows = try JSONDecoder().decode([CategorySpendRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].overflowCategoryId?.uuidString, "56B662F3-7D79-403B-A7F3-4361231F5384")
        XCTAssertNil(rows[1].overflowCategoryId, "pre-0033 rows and snapshots carry no overflow")
    }
}
