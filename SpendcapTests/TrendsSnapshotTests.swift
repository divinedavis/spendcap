import XCTest
@testable import Spendcap

/// The snapshot exists so a cold launch can draw last-known numbers on its
/// first frame. The guards matter more than the caching: the wrong user's or
/// the wrong month's rows must never be the thing that flashes.
final class TrendsSnapshotTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)!
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    private func snapshot(savedAt: String, userId: String = "user-a") -> TrendsSnapshot {
        TrendsSnapshot(
            userId: userId,
            savedAt: date(savedAt),
            transactions: [BankTransaction(
                id: UUID(), date: "2026-08-10", name: "Coqodaq",
                merchantName: "Coqodaq", category: "FOOD_AND_DRINK",
                amountCents: 18_500)],
            budget: Budget(dailyLimitCents: 5000, warnPct: 80, monthlyLimitCents: 650_000),
            categoryRows: [CategorySpendRow(
                period: "2026-08-01", categoryId: UUID(), categoryName: "Food",
                plannedCents: 60_000, spentCents: 18_500, txnCount: 1, sortOrder: 1)]
        )
    }

    func testSnapshotIsUsableForTheSameUserInTheSameMonth() {
        XCTAssertTrue(snapshot(savedAt: "2026-08-10")
            .isUsable(for: "user-a", now: date("2026-08-13"), calendar: calendar))
    }

    /// One user's bank history must never flash on another user's screen —
    /// including when nobody is signed in at all.
    func testSnapshotIsRejectedForAnotherUserOrNoUser() {
        let snap = snapshot(savedAt: "2026-08-10")
        XCTAssertFalse(snap.isUsable(for: "user-b", now: date("2026-08-13"), calendar: calendar))
        XCTAssertFalse(snap.isUsable(for: nil, now: date("2026-08-13"), calendar: calendar))
    }

    /// Last month's rows rebuild into an empty chart — worse than the loading
    /// state the snapshot replaces — so a month boundary invalidates it.
    func testSnapshotIsRejectedAcrossAMonthBoundary() {
        XCTAssertFalse(snapshot(savedAt: "2026-08-31")
            .isUsable(for: "user-a", now: date("2026-09-01"), calendar: calendar))
    }

    /// The snapshot round-trips through JSON with every field the math needs —
    /// a lossy trip would make the cached frame disagree with the live one.
    func testSnapshotRoundTripsThroughJSON() throws {
        let original = snapshot(savedAt: "2026-08-10")
        let decoded = try JSONDecoder().decode(
            TrendsSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
