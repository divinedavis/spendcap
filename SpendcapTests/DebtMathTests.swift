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

    // MARK: - Measured monthly amount (0031)

    /// The owner's ask: the monthly figure is the charges, not what was typed.
    /// A tracked row with history reads its typical month; the totals follow.
    func testTrackedItemWithHistoryUsesItsTypicalMonth() {
        let measured = DebtSummaryRow(
            groupId: subscriptions, groupName: "Subscriptions", groupSort: 0,
            itemId: UUID(), itemName: "Claude", plannedCents: 10_000,
            matchValue: "ANTHROPIC", typicalCents: 13_066, monthsSeen: 3)
        let typed = DebtSummaryRow(
            groupId: subscriptions, groupName: "Subscriptions", groupSort: 0,
            itemId: UUID(), itemName: "401k loan", plannedCents: 20_000,
            itemSort: 1)
        XCTAssertTrue(measured.isAutoAmount)
        XCTAssertEqual(measured.monthlyCents, 13_066)
        XCTAssertFalse(typed.isAutoAmount, "no match string, nothing to measure")
        XCTAssertEqual(typed.monthlyCents, 20_000)

        let summary = DebtMath.summary(rows: [measured, typed])
        XCTAssertEqual(summary.plannedCents, 33_066)
        XCTAssertEqual(summary.groups[0].vendors.reduce(0) { $0 + $1.plannedCents },
                       summary.plannedCents)
    }

    /// A bill added today has a match and no history yet; $0 would be a lie,
    /// so the typed figure stands until there is something to measure.
    func testTrackedItemWithNoHistoryKeepsTheTypedAmount() {
        let r = DebtSummaryRow(
            groupId: subscriptions, groupName: "Subscriptions", groupSort: 0,
            itemId: UUID(), itemName: "New gym", plannedCents: 4_500,
            matchValue: "GYM", typicalCents: 0, monthsSeen: 0)
        XCTAssertFalse(r.isAutoAmount)
        XCTAssertEqual(r.monthlyCents, 4_500)
    }

    /// Postgres bigint arrives as a number or a string; both must decode, and
    /// an older server with no column must not fail the tab.
    func testTypicalCentsDecodesFromNumberStringOrAbsent() throws {
        let group = UUID().uuidString
        func decode(_ extra: String) throws -> DebtSummaryRow {
            let json = """
            {"group_id":"\(group)","group_name":"G","item_id":"\(UUID().uuidString)",
             "item_name":"X","planned_cents":100,"paid_cents":"0","match_value":"X"\(extra)}
            """
            return try JSONDecoder().decode(DebtSummaryRow.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#","typical_cents":2744,"months_seen":3"#).monthlyCents, 2_744)
        XCTAssertEqual(try decode(#","typical_cents":"2744","months_seen":3"#).monthlyCents, 2_744)
        let old = try decode("")
        XCTAssertNil(old.typicalCents)
        XCTAssertEqual(old.monthlyCents, 100)
    }

    // MARK: - Finished months count only what was seen

    /// The owner's screenshots: September still added a $49.90 row that never
    /// charged, and Transfers read $377 when $692 was actually paid. A finished
    /// month totals what was paid; this month an unseen row is still expected.
    func testAFinishedMonthTotalsWhatWasPaid() {
        let other = UUID()
        let rows = [
            DebtSummaryRow(groupId: other, groupName: "Other", groupSort: 0,
                           itemId: UUID(), itemName: "Cubesmart", paidCents: 33_374, txnCount: 1,
                           matchValue: "CUBESMART", itemSort: 0, typicalCents: 33_374, monthsSeen: 3),
            DebtSummaryRow(groupId: other, groupName: "Other", groupSort: 0,
                           itemId: UUID(), itemName: "Mollys Suds", matchValue: "MOLLYS SUDS",
                           itemSort: 1, typicalCents: 4_990, monthsSeen: 1),
            DebtSummaryRow(groupId: other, groupName: "Other", groupSort: 0,
                           itemId: UUID(), itemName: "401k loan", plannedCents: 10_000, itemSort: 2),
        ]
        let september = DebtMath.summary(rows: rows, monthIsOver: true)
        XCTAssertEqual(september.plannedCents, 33_374,
                       "a finished month totals what was paid — nothing for the unseen row or the typed-only loan")
        XCTAssertEqual(september.plannedCents, september.paidCents)
        XCTAssertEqual(september.unseenCents, 14_990)
        XCTAssertEqual(september.unseenCount, 2)
        XCTAssertEqual(september.groups[0].vendors.reduce(0) { $0 + $1.plannedCents },
                       september.plannedCents)

        let october = DebtMath.summary(rows: rows)
        XCTAssertEqual(october.plannedCents, 48_364, "this month an unseen row is still expected")
        XCTAssertEqual(october.unseenCents, 0)
    }

    // MARK: - Company detection

    /// "auto categorize these by the company I'm paying": YouTube products
    /// and Workspace are all Google, with no one typing "Google" into each.
    func testProductsCollectUnderTheirParentCompany() {
        let rows = [
            row(subscriptions, "Subscriptions", item: "Google", note: "workspace",
                match: "GOOGLE WORKSPACE", itemSort: 0),
            row(subscriptions, "Subscriptions", item: "Liberty Mutual", itemSort: 1),
            row(subscriptions, "Subscriptions", item: "YouTube TV", note: "add-ons",
                match: "YOUTUBE TV", itemSort: 2),
            row(subscriptions, "Subscriptions", item: "YouTube Premium",
                match: "YOUTUBE PREMIUM", itemSort: 3),
        ]
        let vendors = DebtMath.summary(rows: rows).groups[0].vendors
        XCTAssertEqual(vendors.map(\.name), ["Google", "Liberty Mutual"])
        XCTAssertEqual(vendors[0].items.count, 3)
    }

    func testCompanyIsReadFromTheMatchWhenTheNameIsPersonal() {
        let haircut = row(subscriptions, "Transfers", item: "Haircut", match: "APPLE CASH")
        XCTAssertEqual(DebtMath.company(for: haircut), "Apple")
        XCTAssertEqual(DebtMath.company(named: "SP+AFF"), "Affirm")
        XCTAssertEqual(DebtMath.company(named: "HBOMAX"), "Warner Bros.")
    }

    /// Whole words only — a brand inside another word is not that brand.
    func testCompanyAliasesMatchWholeWordsOnly() {
        XCTAssertNil(DebtMath.company(named: "Pineapple Express"))
        XCTAssertNil(DebtMath.company(named: "Metamucil"))
        XCTAssertNil(DebtMath.company(named: "Liberty Mutual"))
        XCTAssertEqual(DebtMath.company(named: "Apple Card"), "Apple")
    }

    // MARK: - Previous month

    func testPreviousMonthStartsOnTheFirstEvenFromThe31st() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let oct31 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23))!
        let sep1 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let oct1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        XCTAssertEqual(DebtMonth.previous.start(now: oct31, calendar: calendar), sep1)
        XCTAssertEqual(DebtMonth.current.start(now: oct31, calendar: calendar), oct1)
        let jan5 = calendar.date(from: DateComponents(year: 2027, month: 1, day: 5))!
        let dec1 = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        XCTAssertEqual(DebtMonth.previous.start(now: jan5, calendar: calendar), dec1)
        XCTAssertEqual(DebtMonth.current.label(now: jan5, calendar: calendar), "This month")
    }

    private func charge(_ date: String, _ cents: Int, item: UUID = UUID()) -> DebtCharge {
        DebtCharge(
            itemId: item,
            transaction: CategoryTransaction(
                id: UUID(), date: date, name: "VENDOR A", amountCents: cents))
    }
}
