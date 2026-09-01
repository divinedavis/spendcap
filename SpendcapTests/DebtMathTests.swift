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

    // MARK: - Vendor grouping

    /// The screenshot's complaint: one company said twice, twelve pixels
    /// apart, with no answer to "what am I paying this company". Grouping is
    /// presentational — the items stay separate rows underneath, because they
    /// are separate obligations at separate prices.
    func testItemsForOneCompanyCollectUnderOneVendor() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "video",
                planned: 8_800, paid: 11_597, txns: 3, match: "VENDOR A TV", itemSort: 0),
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "office",
                planned: 3_000, paid: 2_744, txns: 2, match: "VENDOR A WORKSPACE", itemSort: 1),
            row(subscriptions, "Subscriptions", item: "Vendor B", note: "insurance",
                planned: 7_500, paid: 7_466, txns: 1, match: "VENDOR B", itemSort: 2),
        ]
        let vendors = DebtMath.summary(rows: rows).groups[0].vendors

        XCTAssertEqual(vendors.map(\.name), ["Vendor A", "Vendor B"])
        XCTAssertEqual(vendors[0].items.count, 2, "the two obligations stay separate rows")
        XCTAssertTrue(vendors[0].isMulti)
        XCTAssertFalse(vendors[1].isMulti, "one item is still a company, just not a nested one")
        XCTAssertEqual(vendors[0].plannedCents, 11_800)
        XCTAssertEqual(vendors[0].paidCents, 14_341)
        XCTAssertEqual(vendors[0].txnCount, 5)
    }

    /// The vendor totals are the sum of the same rows the group total sums, so
    /// a card cannot show headings that add up to something other than itself.
    func testVendorTotalsSumToTheGroupTotal() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "video", planned: 8_800, itemSort: 0),
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "music", planned: 3_000, itemSort: 1),
            row(subscriptions, "Subscriptions", item: "Vendor C", note: "server", planned: 10_000, itemSort: 2),
        ]
        let group = DebtMath.summary(rows: rows).groups[0]
        XCTAssertEqual(group.vendors.reduce(0) { $0 + $1.plannedCents }, group.plannedCents)
    }

    /// Case and punctuation are how the same company gets typed twice.
    func testVendorMatchIgnoresCaseAndPunctuation() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "Digital Ocean", planned: 10_000, itemSort: 0),
            row(subscriptions, "Subscriptions", item: "digitalocean", planned: 2_000, itemSort: 1),
        ]
        let vendors = DebtMath.summary(rows: rows).groups[0].vendors
        XCTAssertEqual(vendors.count, 1)
        XCTAssertEqual(vendors[0].name, "Digital Ocean", "the first spelling is the one shown")
        XCTAssertEqual(vendors[0].plannedCents, 12_000)
    }

    /// Grouping must not reorder a list someone arranged: a company sits where
    /// its first item sat, and its products keep their own order.
    func testVendorsKeepTheUsersArrangement() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "Vendor B", itemSort: 0),
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "video", itemSort: 1),
            row(subscriptions, "Subscriptions", item: "Vendor C", itemSort: 2),
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "office", itemSort: 3),
        ]
        let vendors = DebtMath.summary(rows: rows).groups[0].vendors
        XCTAssertEqual(vendors.map(\.name), ["Vendor B", "Vendor A", "Vendor C"])
        XCTAssertEqual(vendors[1].items.map { $0.note }, ["video", "office"])
    }

    /// An untracked row has no match string, so there is nothing to look up —
    /// it must not be asked for, and it must not drag a tracked sibling's
    /// paid figure down to zero.
    func testUntrackedItemsAreExcludedFromAVendorsPaidFigure() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "video",
                planned: 8_800, paid: 11_597, txns: 3, match: "VENDOR A TV", itemSort: 0),
            row(subscriptions, "Subscriptions", item: "Vendor A", note: "loan",
                planned: 5_000, itemSort: 1),
        ]
        let vendor = DebtMath.summary(rows: rows).groups[0].vendors[0]
        XCTAssertEqual(vendor.plannedCents, 13_800)
        XCTAssertEqual(vendor.paidCents, 11_597, "the untracked row contributes no zero")
        XCTAssertEqual(vendor.trackedItemIds.count, 1)
    }

    /// Two rows that fold to an empty key are two rows, not one company called
    /// nothing.
    func testUnnameableRowsDoNotAllMergeTogether() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "—", planned: 100, itemSort: 0),
            row(subscriptions, "Subscriptions", item: "…", planned: 200, itemSort: 1),
        ]
        let vendors = DebtMath.summary(rows: rows).groups[0].vendors
        XCTAssertEqual(vendors.count, 2)
    }

    // MARK: - Charge sheet

    func testChargesGroupIntoMonthsNewestFirst() {
        let charges = [
            charge("2026-08-20", 2_000),
            charge("2026-08-04", 3_000),
            charge("2026-07-19", 1_500),
        ]
        let months = DebtChargeMath.months(charges, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(months.count, 2)
        XCTAssertEqual(months[0].charges.count, 2)
        XCTAssertEqual(months[0].totalCents, 5_000)
        XCTAssertEqual(months[1].totalCents, 1_500)
    }

    /// A charge sheet's rows have to add up to the row that opened it.
    func testChargeMonthsCoverEveryCharge() {
        let charges = [charge("2026-08-20", 2_000), charge("2026-06-01", 900)]
        let months = DebtChargeMath.months(charges, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(months.reduce(0) { $0 + $1.totalCents }, 2_900)
    }

    private func charge(_ date: String, _ cents: Int, item: UUID = UUID()) -> DebtCharge {
        DebtCharge(
            itemId: item,
            transaction: CategoryTransaction(
                id: UUID(), date: date, name: "VENDOR A", amountCents: cents))
    }
}
