import XCTest
@testable import Spendcap

final class BudgetMathTests: XCTestCase {

    // MARK: - Threshold status (must mirror check_overspend server logic)

    func testUnderCap() {
        XCTAssertEqual(BudgetMath.status(spentCents: 0, limitCents: 5000, warnPct: 80), .under)
        XCTAssertEqual(BudgetMath.status(spentCents: 3999, limitCents: 5000, warnPct: 80), .under)
    }

    func testWarnBoundaryIsInclusive() {
        // 80% of $50.00 = $40.00 exactly → warn
        XCTAssertEqual(BudgetMath.status(spentCents: 4000, limitCents: 5000, warnPct: 80), .warn)
        XCTAssertEqual(BudgetMath.status(spentCents: 4999, limitCents: 5000, warnPct: 80), .warn)
    }

    func testOverBoundaryIsInclusive() {
        XCTAssertEqual(BudgetMath.status(spentCents: 5000, limitCents: 5000, warnPct: 80), .over)
        XCTAssertEqual(BudgetMath.status(spentCents: 12345, limitCents: 5000, warnPct: 80), .over)
    }

    func testZeroLimitNeverAlerts() {
        XCTAssertEqual(BudgetMath.status(spentCents: 99999, limitCents: 0, warnPct: 80), .under)
    }

    func testIntegerMathMatchesServerRounding() {
        // Server compares spent*100 >= limit*warn_pct with integers — no float
        // drift. 79.99% of a $33.33 cap must NOT warn.
        let limit = 3333
        let warnPct = 80
        let justUnder = (limit * warnPct - 1) / 100  // 26.66 → 2665 int division
        XCTAssertEqual(BudgetMath.status(spentCents: justUnder, limitCents: limit, warnPct: warnPct), .under)
        let atThreshold = Int((Double(limit) * 0.8).rounded(.up))
        XCTAssertEqual(BudgetMath.status(spentCents: atThreshold, limitCents: limit, warnPct: warnPct), .warn)
    }

    // MARK: - Progress + formatting

    func testProgressClamps() {
        XCTAssertEqual(BudgetMath.progress(spentCents: 0, limitCents: 5000), 0)
        XCTAssertEqual(BudgetMath.progress(spentCents: 2500, limitCents: 5000), 0.5)
        XCTAssertEqual(BudgetMath.progress(spentCents: 10000, limitCents: 5000), 1.0)
        XCTAssertEqual(BudgetMath.progress(spentCents: 100, limitCents: 0), 0)
    }

    func testRemaining() {
        XCTAssertEqual(BudgetMath.remainingCents(spentCents: 1200, limitCents: 5000), 3800)
        XCTAssertEqual(BudgetMath.remainingCents(spentCents: 6000, limitCents: 5000), -1000)
    }

    func testDollarsFormatting() {
        XCTAssertEqual(BudgetMath.dollars(5000), "$50.00")
        XCTAssertEqual(BudgetMath.dollars(123), "$1.23")
    }

    // MARK: - Model decoding (matches PostgREST JSON)

    func testTransactionDecoding() throws {
        let json = """
        {"id":"6a1f0e94-58f7-4d3a-9b1e-0a1b2c3d4e5f","date":"2026-07-18",
         "name":"UBER EATS","merchant_name":"Uber Eats","category":"FOOD_AND_DRINK",
         "amount_cents":2350,"pending":true,"is_removed":false}
        """
        let txn = try JSONDecoder().decode(BankTransaction.self, from: Data(json.utf8))
        XCTAssertEqual(txn.displayName, "Uber Eats")
        XCTAssertEqual(txn.amountCents, 2350)
        XCTAssertTrue(txn.pending)
    }

    func testTransactionDisplayNameFallsBackToName() throws {
        let json = """
        {"id":"6a1f0e94-58f7-4d3a-9b1e-0a1b2c3d4e5f","date":"2026-07-18",
         "name":"CHECK 1042","merchant_name":null,"category":null,
         "amount_cents":10000,"pending":false,"is_removed":false}
        """
        let txn = try JSONDecoder().decode(BankTransaction.self, from: Data(json.utf8))
        XCTAssertEqual(txn.displayName, "CHECK 1042")
    }

    func testBudgetDecoding() throws {
        let json = #"{"daily_limit_cents":7500,"warn_pct":90}"#
        let budget = try JSONDecoder().decode(Budget.self, from: Data(json.utf8))
        XCTAssertEqual(budget.dailyLimitCents, 7500)
        XCTAssertEqual(budget.warnPct, 90)
    }

    // MARK: - Local date (drives the "today" query)

    func testLocalDateStringUsesTimezone() {
        let utcMidnightPlus1 = Date(timeIntervalSince1970: 1_768_780_800 + 3600) // 2026-01-19 01:00 UTC
        let ny = TimeZone(identifier: "America/New_York")!
        // 01:00 UTC is still the previous evening in New York.
        XCTAssertEqual(SpendService.localDateString(now: utcMidnightPlus1, timeZone: ny), "2026-01-18")
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SpendService.localDateString(now: utcMidnightPlus1, timeZone: utc), "2026-01-19")
    }
}
