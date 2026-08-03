import XCTest
@testable import Spendcap

final class BankStatementTests: XCTestCase {

    private func statement(
        year: Int = 2026,
        month: Int = 8,
        storagePath: String? = "uid/stmt.pdf",
        byteSize: Int? = 1024,
        accounts: BankStatement.Account? = nil
    ) -> BankStatement {
        BankStatement(
            id: UUID(),
            year: year,
            month: month,
            storagePath: storagePath,
            byteSize: byteSize,
            accounts: accounts
        )
    }

    // MARK: - Account label

    /// A bank with a checking and a savings account issues one statement each
    /// per month. Without the account, the list is two identical "July 2026"
    /// rows and looks like a duplication bug.
    func testAccountLabelPrefersTheName() {
        let named = statement(accounts: .init(name: "EVERYDAY CHECKING ...1395", mask: "1395"))
        XCTAssertEqual(named.accountLabel, "EVERYDAY CHECKING ...1395")
    }

    func testAccountLabelFallsBackToTheMask() {
        let masked = statement(accounts: .init(name: nil, mask: "7230"))
        XCTAssertEqual(masked.accountLabel, "\u{2022}\u{2022}\u{2022}\u{2022} 7230")
        let blank = statement(accounts: .init(name: "   ", mask: "7230"))
        XCTAssertEqual(blank.accountLabel, "\u{2022}\u{2022}\u{2022}\u{2022} 7230")
    }

    /// Rows written before the account was joined in must not crash or show an
    /// empty label — the UI simply omits the line.
    func testAccountLabelIsNilWhenNothingIsKnown() {
        XCTAssertNil(statement(accounts: nil).accountLabel)
        XCTAssertNil(statement(accounts: .init(name: nil, mask: nil)).accountLabel)
    }

    func testDecodesEmbeddedAccount() throws {
        let json = """
        {"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","year":2026,"month":7,
         "storage_path":"uid/x.pdf","byte_size":359713,
         "accounts":{"name":"EVERYDAY CHECKING ...1395","mask":"1395"}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BankStatement.self, from: json)
        XCTAssertEqual(decoded.accountLabel, "EVERYDAY CHECKING ...1395")
        XCTAssertTrue(decoded.isAvailable)
    }

    /// PostgREST omits the embed entirely when there is no related row.
    func testDecodesWithoutAnAccount() throws {
        let json = """
        {"id":"3f2504e0-4f89-11d3-9a0c-0305e82c3301","year":2026,"month":7,
         "storage_path":null,"byte_size":null}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BankStatement.self, from: json)
        XCTAssertNil(decoded.accountLabel)
        XCTAssertFalse(decoded.isAvailable)
    }

    // MARK: - Availability

    // A listed-but-undownloaded statement must stay visible. The edge function
    // deliberately writes a row with a null storage_path when the download
    // fails, so a missing month is never silently dropped from the list.
    func testUnavailableWhenStoragePathMissing() {
        XCTAssertFalse(statement(storagePath: nil).isAvailable)
        XCTAssertTrue(statement(storagePath: "uid/stmt.pdf").isAvailable)
    }

    // MARK: - Period label

    func testPeriodLabelUsesComponentsNotParsedDate() {
        // The row carries year/month integers; period_start/period_end are
        // nullable, so the label must never depend on them.
        XCTAssertEqual(statement(year: 2026, month: 8).periodLabel, "August 2026")
        XCTAssertEqual(statement(year: 2025, month: 12).periodLabel, "December 2025")
        XCTAssertEqual(statement(year: 2026, month: 1).periodLabel, "January 2026")
    }

    // MARK: - Size label

    func testSizeLabelNilWhenByteSizeMissing() {
        XCTAssertNil(statement(byteSize: nil).sizeLabel)
        XCTAssertNotNil(statement(byteSize: 1024).sizeLabel)
    }

    // MARK: - Decoding (must match the edge function's column names)

    func testDecodesSnakeCaseColumns() throws {
        let json = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "year": 2026,
          "month": 7,
          "storage_path": "uid/abc.pdf",
          "byte_size": 20480
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BankStatement.self, from: json)
        XCTAssertEqual(decoded.year, 2026)
        XCTAssertEqual(decoded.month, 7)
        XCTAssertEqual(decoded.storagePath, "uid/abc.pdf")
        XCTAssertEqual(decoded.byteSize, 20480)
        XCTAssertEqual(decoded.periodLabel, "July 2026")
    }

    // A failed download arrives as an explicit null, not a missing key.
    func testDecodesNullStoragePath() throws {
        let json = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "year": 2026,
          "month": 6,
          "storage_path": null,
          "byte_size": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BankStatement.self, from: json)
        XCTAssertFalse(decoded.isAvailable)
        XCTAssertNil(decoded.sizeLabel)
    }

    // MARK: - Ordering

    // The list query orders year desc, month desc. Sorting the decoded models
    // the same way guards against a December/January wraparound bug.
    func testNewestFirstOrderingAcrossYearBoundary() {
        let rows = [
            statement(year: 2025, month: 12),
            statement(year: 2026, month: 1),
            statement(year: 2025, month: 1),
            statement(year: 2026, month: 8),
        ]
        let sorted = rows.sorted { ($0.year, $0.month) > ($1.year, $1.month) }
        XCTAssertEqual(sorted.map(\.periodLabel), [
            "August 2026", "January 2026", "December 2025", "January 2025",
        ])
    }
}
