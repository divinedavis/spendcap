import XCTest
@testable import Spendcap

/// Pins the display-name rule shared with the server's `txn_display_name()`
/// (0018) — the two must agree or the name a screen shows stops being the
/// name a reassignment rule matches.
final class TransactionNamingTests: XCTestCase {

    /// The real Wells Fargo shape: the fee is named after the purchase that
    /// overdrew the account, and Plaid extracts that merchant. The fee must
    /// not masquerade as an Affirm charge.
    func testOverdraftFeeNeverWearsTheMerchantsName() {
        let name = "OVERDRAFT FEE FOR A TRANSACTION POSTED ON 07/27 $50.50 "
            + "AFFIRM.COM PAYME AFFIRM.COM ST-A6O5T1Z2O7Y2 DIVINE DAVIS"
        XCTAssertEqual(
            TransactionNaming.displayName(name: name, merchantName: "Affirm", category: "BANK_FEES"),
            "Overdraft fee"
        )
    }

    /// Plaid sometimes rewrites the fee's *name* to just the merchant,
    /// leaving BANK_FEES as the only signal (two real rows named "Lyft").
    /// The category alone cannot prove "overdraft" — a monthly service fee
    /// is BANK_FEES too — so the label is the honest "Bank fee".
    func testBankFeeWithErasedTextIsABankFeeNotAMerchant() {
        XCTAssertEqual(
            TransactionNaming.displayName(name: "Lyft", merchantName: "Lyft", category: "BANK_FEES"),
            "Bank fee"
        )
    }

    func testNonFeeRowsPreferTheMerchantName() {
        XCTAssertEqual(
            TransactionNaming.displayName(name: "LYFT *RIDE THU 6PM", merchantName: "Lyft",
                                          category: "TRANSPORTATION"),
            "Lyft"
        )
    }

    func testNonFeeRowsFallBackToTheBankTextWhenMerchantIsBlank() {
        XCTAssertEqual(
            TransactionNaming.displayName(name: "SAVE AS YOU GO TRANSFER DEBIT",
                                          merchantName: "  ", category: "TRANSFER_OUT"),
            "SAVE AS YOU GO TRANSFER DEBIT"
        )
        XCTAssertEqual(
            TransactionNaming.displayName(name: "CHECK 1042", merchantName: nil, category: nil),
            "CHECK 1042"
        )
    }
}
