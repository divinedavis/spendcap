import XCTest
@testable import Spendcap

/// `countsTowardDailyCap` must mirror `overspend_status()` in
/// 0004_pending_backfill.sql exactly. The server sends the push and the client
/// draws the ring; the two disagreeing is worse than either being wrong on its
/// own, so these cases are written to match the SQL predicate term for term:
///
///   is_removed = false AND amount_cents > 0 AND NOT (pending AND is_backfill)
final class PendingBackfillTests: XCTestCase {

    private func txn(
        _ day: String = "2026-08-01",
        _ cents: Int = 1000,
        pending: Bool = false,
        isBackfill: Bool = false,
        isRemoved: Bool = false
    ) -> BankTransaction {
        BankTransaction(
            id: UUID(), date: day, name: "Test",
            amountCents: cents, pending: pending,
            isRemoved: isRemoved, isBackfill: isBackfill
        )
    }

    // MARK: - The predicate, term by term

    func testPostedTransactionCounts() {
        XCTAssertTrue(txn(pending: false, isBackfill: false).countsTowardDailyCap)
    }

    /// A charge made *after* linking is pending but not backfill — real
    /// spending the user just did, and the whole point of a daily cap.
    func testNewPendingCounts() {
        XCTAssertTrue(txn(pending: true, isBackfill: false).countsTowardDailyCap)
    }

    /// The bug this fixes: unposted charges inherited at link time carry the
    /// link date, not a purchase date.
    func testBackfilledPendingIsExcluded() {
        XCTAssertFalse(txn(pending: true, isBackfill: true).countsTowardDailyCap)
    }

    /// Once it posts, the date is real — so it counts again, on its true day.
    /// This is why the flag alone must not exclude a row.
    func testBackfilledButPostedCounts() {
        XCTAssertTrue(txn(pending: false, isBackfill: true).countsTowardDailyCap)
    }

    func testRemovedIsExcluded() {
        XCTAssertFalse(txn(isRemoved: true).countsTowardDailyCap)
    }

    /// Inflows are money in, not spending (Plaid convention: > 0 is outflow).
    func testInflowIsExcluded() {
        XCTAssertFalse(txn("2026-08-01", -2500).countsTowardDailyCap)
        XCTAssertFalse(txn("2026-08-01", 0).countsTowardDailyCap)
    }

    // MARK: - Day totals

    /// The live case that motivated this: linking on 2026-08-01 pulled in a
    /// backlog of unposted charges all stamped with the link date, which read
    /// as $428.38 of spending against a $50 cap and fired an "over" push
    /// seconds after linking.
    func testLinkDayBacklogDoesNotBlowTheCap() {
        let backlog = [9516, 7430, 7080, 3386, 2859].map {
            txn("2026-08-01", $0, pending: true, isBackfill: true)
        }
        let realPurchase = txn("2026-08-01", 1200, pending: true, isBackfill: false)

        let counted = (backlog + [realPurchase])
            .filter(\.countsTowardDailyCap)
            .reduce(0) { $0 + $1.amountCents }

        XCTAssertEqual(counted, 1200, "only the post-link purchase should count")
        XCTAssertEqual(
            BudgetMath.status(spentCents: counted, limitCents: 5000, warnPct: 80),
            .under,
            "a $12 purchase against a $50 cap is under, not over"
        )
    }

    // MARK: - MonthMath agreement

    /// MonthMath buckets by the same predicate, so the Trends chart and the
    /// ring cannot drift apart.
    func testMonthMathSkipsBackfilledPending() {
        let stats = MonthMath.stats(
            transactions: [
                txn("2026-08-01", 9516, pending: true, isBackfill: true),
                txn("2026-08-01", 1200, pending: true, isBackfill: false),
            ],
            dailyLimitCents: 5000,
            now: {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")!
                f.locale = Locale(identifier: "en_US_POSIX")
                return f.date(from: "2026-08-01")!
            }(),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(stats.spentCents, 1200)
        XCTAssertEqual(stats.series.last?.spentCents, 1200)
    }

    // MARK: - Decoding

    /// Rows written before 0004 have no is_backfill key at all; they must
    /// decode as not-backfill rather than throwing.
    func testDecodesWithoutIsBackfillKey() throws {
        let json = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "date": "2026-08-01",
          "name": "Legacy row",
          "amount_cents": 500,
          "pending": true,
          "is_removed": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BankTransaction.self, from: json)
        XCTAssertFalse(decoded.isBackfill)
        XCTAssertTrue(decoded.countsTowardDailyCap)
    }

    func testDecodesIsBackfillTrue() throws {
        let json = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "date": "2026-08-01",
          "name": "Inherited",
          "amount_cents": 9516,
          "pending": true,
          "is_removed": false,
          "is_backfill": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BankTransaction.self, from: json)
        XCTAssertTrue(decoded.isBackfill)
        XCTAssertFalse(decoded.countsTowardDailyCap)
    }
}
