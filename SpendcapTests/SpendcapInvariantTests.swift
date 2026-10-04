import Foundation
import Testing
@testable import Spendcap

/// Swift Testing suites (2026-10-04), one of the four checks every TestFlight
/// ship must pass (scripts/ship.sh fails when none ran). Parameterized, so a
/// new case is one more row rather than one more test method, and a failure
/// names the row that broke.

@Suite("Push thresholds")
struct PushThresholdTests {
    /// The client mirror of `overspend_status()`'s integer comparison: 80%
    /// warns, 100% is over, and a zero cap never alerts.
    @Test(arguments: [
        (spent: 0, limit: 5_000, warn: 80, expected: SpendStatus.under),
        (spent: 3_999, limit: 5_000, warn: 80, expected: .under),
        (spent: 4_000, limit: 5_000, warn: 80, expected: .warn),
        (spent: 4_999, limit: 5_000, warn: 80, expected: .warn),
        (spent: 5_000, limit: 5_000, warn: 80, expected: .over),
        (spent: 9_000, limit: 5_000, warn: 80, expected: .over),
        (spent: 9_000, limit: 0, warn: 80, expected: .under),
    ])
    func status(spent: Int, limit: Int, warn: Int, expected: SpendStatus) {
        #expect(BudgetMath.status(spentCents: spent, limitCents: limit, warnPct: warn) == expected)
    }

    @Test(arguments: [(-500, 5_000), (0, 5_000), (2_500, 5_000), (5_000, 5_000), (20_000, 5_000), (100, 0)])
    func progressStaysInsideTheRing(spent: Int, limit: Int) {
        let p = BudgetMath.progress(spentCents: spent, limitCents: limit)
        #expect((0.0...1.0).contains(p))
    }
}

@Suite("Reassignment rules match next month's copy")
struct StableMatchValueTests {
    /// Each month's copy of the same payment carries a fresh date and
    /// reference code; the stable phrase is what a rule must be written from.
    @Test(arguments: [
        ("PAYPAL INST XFER 260805 PYPL PAYMTHLY DIVINE DAVIS", "PYPL PAYMTHLY DIVINE DAVIS"),
        ("ZELLE TO CARLO CHAMAINE ON 07/30 REF # WFCT22GS4599", "ZELLE TO CARLO CHAMAINE"),
        ("ONLINE TRANSFER TO DAVIS D EVERYDAY CHECKING XXXXXXXXX1395 REF #IB0Z59K433 ON 07/30/26",
         "ONLINE TRANSFER TO DAVIS D EVERYDAY CHECKING"),
        ("Coqodaq", "Coqodaq"),
        ("Lyft", "Lyft"),
    ])
    func stablePhrase(raw: String, expected: String) {
        #expect(TransactionNaming.stableMatchValue(from: raw) == expected)
    }

    /// Two months of the same payment must land on one rule.
    @Test(arguments: [
        ("PAYPAL INST XFER 260805 PYPL PAYMTHLY DIVINE DAVIS", "PAYPAL INST XFER 260905 PYPL PAYMTHLY DIVINE DAVIS"),
        ("ZELLE TO CARLO CHAMAINE ON 07/30 REF # WFCT22GS4599", "ZELLE TO CARLO CHAMAINE ON 08/30 REF # WFCT99XY1234"),
    ])
    func monthToMonthCopiesAgree(first: String, next: String) {
        #expect(TransactionNaming.stableMatchValue(from: first) == TransactionNaming.stableMatchValue(from: next))
    }
}

@Suite("Bank fees never wear a merchant's name")
struct FeeNamingTests {
    @Test(arguments: [
        ("OVERDRAFT FEE FOR A TRANSACTION POSTED ON 07/27 $50.50 AFFIRM.COM PAYME", "Affirm", "Overdraft fee"),
        ("Lyft", "Lyft", "Bank fee"),
        ("MONTHLY SERVICE FEE", nil, "Bank fee"),
    ] as [(String, String?, String)])
    func feeName(name: String, merchant: String?, expected: String) {
        #expect(TransactionNaming.displayName(name: name, merchantName: merchant, category: "BANK_FEES") == expected)
    }
}

@Suite("Budget line kinds")
struct CategoryKindTests {
    /// The server's `budget_categories_kind_check` holds these exact strings.
    @Test(arguments: CategoryKind.allCases)
    func roundTripsThroughItsRawValue(kind: CategoryKind) throws {
        let data = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(CategoryKind.self, from: data) == kind)
        #expect(!kind.label.isEmpty)
        #expect(!kind.systemImage.isEmpty)
    }

    /// The committed list is Divine's own: rent, debts, hair, transport, savings.
    @Test func committedKindsAreExactlyTheFive() {
        let committed = Set(CategoryKind.allCases.filter(\.isCommitted))
        #expect(committed == [.rent, .debt, .transportation, .savings, .personalCare])
    }
}
