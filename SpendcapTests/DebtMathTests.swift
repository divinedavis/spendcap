import XCTest
@testable import Spendcap

final class DebtMathTests: XCTestCase {

    private let subscriptions = UUID()
    private let loans = UUID()
    private let empty = UUID()

    private func row(_ group: UUID, _ groupName: String, groupSort: Int = 0,
                     item: String?, note: String? = nil, planned: Int = 0,
                     paid: Int = 0, txns: Int = 0, match: String? = nil,
                     matchAmount: Int? = nil, itemSort: Int = 0) -> DebtSummaryRow {
        DebtSummaryRow(
            groupId: group, groupName: groupName, groupSort: groupSort,
            itemId: item == nil ? nil : UUID(), itemName: item, note: note,
            plannedCents: planned, paidCents: paid, txnCount: txns,
            matchValue: match, matchAmountCents: matchAmount, itemSort: itemSort)
    }

    /// The bug the screen exists to prevent: a hand-kept sheet whose written
    /// subtotal had drifted from the rows under it. Subtotals here are derived,
    /// so they cannot disagree with what they sum — including when the items
    /// share a name and are told apart only by their note, which is the shape
    /// that made a unique-name constraint impossible.
    func testGroupTotalIsTheSumOfItsItems() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "video", planned: 8_800, itemSort: 0),
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "music", planned: 3_000, itemSort: 1),
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "office", planned: 3_000, itemSort: 2),
            row(subscriptions, "Subscriptions", item: "Vendor B", note: "insurance", planned: 10_000, itemSort: 3),
            row(subscriptions, "Subscriptions", item: "Vendor C", note: "server", planned: 10_000, itemSort: 4),
            row(subscriptions, "Subscriptions", item: "Vendor D", note: "AI", planned: 10_000, itemSort: 5),
            row(subscriptions, "Subscriptions", item: "Vendor E", note: "database", planned: 5_000, itemSort: 6),
        ]
        let summary = DebtMath.summary(rows: rows)
        XCTAssertEqual(summary.groups.count, 1)
        XCTAssertEqual(summary.groups[0].plannedCents, 49_800,
                       "the subtotal is the sum of the rows, never a typed figure")
        XCTAssertEqual(summary.plannedCents, 49_800)
        XCTAssertEqual(summary.groups[0].items.filter { $0.itemName == "Vendor A" }.count, 3,
                       "three rows may share a name")
    }

    func testGrandTotalAddsEveryGroup() {
        let rows = [
            row(subscriptions, "Subscriptions", groupSort: 0, item: "Vendor D", planned: 10_000),
            row(loans, "Personal loans", groupSort: 1, item: "Loan A", planned: 10_000, itemSort: 0),
            row(loans, "Personal loans", groupSort: 1, item: "Loan B", planned: 45_000, itemSort: 1),
            row(loans, "Personal loans", groupSort: 1, item: "Loan C", planned: 30_000, itemSort: 2),
        ]
        let summary = DebtMath.summary(rows: rows)
        XCTAssertEqual(summary.groups.map(\.name), ["Subscriptions", "Personal loans"])
        XCTAssertEqual(summary.groups[1].plannedCents, 85_000)
        XCTAssertEqual(summary.plannedCents, 95_000)
        XCTAssertEqual(summary.itemCount, 4)
    }

    /// An empty group arrives as one row with a nil item id. It has to survive
    /// as a group and contribute no item.
    func testEmptyGroupSurvivesWithoutAPhantomItem() {
        let rows = [
            row(subscriptions, "Subscriptions", groupSort: 0, item: "Vendor D", planned: 10_000),
            row(empty, "BNPL", groupSort: 1, item: nil),
        ]
        let summary = DebtMath.summary(rows: rows)
        XCTAssertEqual(summary.groups.count, 2)
        XCTAssertTrue(summary.groups[1].isEmpty)
        XCTAssertEqual(summary.groups[1].plannedCents, 0)
        XCTAssertEqual(summary.itemCount, 1)
    }

    /// Untracked items must not drag the paid figure down. An item with no
    /// match string has no evidence either way; counting its zero would read as
    /// "not paid yet" for money that simply never moves through this account.
    func testPaidIgnoresUntrackedItems() {
        let rows = [
            row(loans, "Personal loans", item: "Loan B", planned: 45_000,
                paid: 45_000, txns: 1, match: "LOAN B", itemSort: 0),
            row(loans, "Personal loans", item: "Loan C", planned: 30_000,
                match: nil, itemSort: 1),
        ]
        let summary = DebtMath.summary(rows: rows)
        XCTAssertEqual(summary.plannedCents, 75_000, "the plan counts both")
        XCTAssertEqual(summary.trackedPlannedCents, 45_000, "only the tracked loan can be checked")
        XCTAssertEqual(summary.paidCents, 45_000)
        XCTAssertEqual(summary.outstandingCents, 0, "nothing left on what can be seen")
    }

    func testOutstandingNeverGoesNegative() {
        let rows = [
            row(loans, "Personal loans", item: "Loan B", planned: 45_000,
                paid: 90_000, txns: 2, match: "LOAN B"),
        ]
        let summary = DebtMath.summary(rows: rows)
        XCTAssertEqual(summary.paidCents, 90_000)
        XCTAssertEqual(summary.outstandingCents, 0,
                       "an overpaid month does not create room elsewhere")
    }

    func testItemsKeepTheirOrderAndGroupsKeepTheirs() {
        let rows = [
            row(loans, "Personal loans", groupSort: 1, item: "Zeta", itemSort: 2),
            row(loans, "Personal loans", groupSort: 1, item: "Alpha", itemSort: 0),
            row(subscriptions, "Subscriptions", groupSort: 0, item: "Vendor D", itemSort: 0),
        ]
        let summary = DebtMath.summary(rows: rows)
        XCTAssertEqual(summary.groups.map(\.name), ["Subscriptions", "Personal loans"])
        XCTAssertEqual(summary.groups[1].items.map { $0.itemName }, ["Alpha", "Zeta"])
    }

    func testTrackedItemWithNoChargesYetIsStillTracked() {
        let r = row(subscriptions, "Subscriptions", item: "Vendor D",
                    planned: 10_000, paid: 0, txns: 0, match: "CLAUDE")
        XCTAssertTrue(r.isTracked)
        let summary = DebtMath.summary(rows: [r])
        XCTAssertTrue(summary.hasTrackedItems)
        XCTAssertEqual(summary.outstandingCents, 10_000)
    }

    func testEmptyInputIsAnEmptySummary() {
        let summary = DebtMath.summary(rows: [])
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.plannedCents, 0)
        XCTAssertEqual(summary.paidCents, 0)
    }
}
