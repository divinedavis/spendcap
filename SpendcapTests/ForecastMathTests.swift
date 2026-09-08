import XCTest
@testable import Spendcap

/// The server says what recurred and what the account holds; every rule about
/// what that *means* lives in ForecastMath, and these pin it. The fixtures are
/// the real shapes 0029 emits: a twice-monthly payroll as two ranks, a monthly
/// bill as one, and a ride-share that ran out of ranks at the cap.
final class ForecastMathTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso)!
    }

    /// Three complete months plus September in progress, checking at $2,500
    /// with $500 pending — the shape 0029 emits.
    private func flows(balance: Int = 250_000, pendingOut: Int = 50_000) -> [ForecastFlowRow] {
        [
            ForecastFlowRow(period: "2026-06-01", outflowCents: 700_000, inflowCents: 630_000,
                            txnCount: 135, balanceCents: balance),
            ForecastFlowRow(period: "2026-07-01", outflowCents: 1_100_000, inflowCents: 630_000,
                            txnCount: 187, balanceCents: balance),
            ForecastFlowRow(period: "2026-08-01", outflowCents: 800_000, inflowCents: 630_000,
                            txnCount: 227, balanceCents: balance),
            ForecastFlowRow(period: "2026-09-01", outflowCents: 100_000, inflowCents: 0,
                            txnCount: 34, pendingOutCents: pendingOut, pendingInCents: 0,
                            balanceCents: balance),
        ]
    }

    private let payroll = ForecastRecurringRow(
        who: "ACME PAYROLL DD", isInflow: true, monthsSeen: 3, windowCount: 6,
        windowCents: 1_890_000, rankMonths: [3, 3], rankDay: [15, 31], rankCents: [315_000, 315_000],
        thisMonthCount: 0, thisMonthCents: 0)

    private let rent = ForecastRecurringRow(
        who: "Rent", isInflow: false, monthsSeen: 3, windowCount: 3,
        windowCents: 600_000, rankMonths: [3], rankDay: [28], rankCents: [200_000],
        thisMonthCount: 0, thisMonthCents: 0)

    /// Already posted this month.
    private let insurance = ForecastRecurringRow(
        who: "Insurance", isInflow: false, monthsSeen: 3, windowCount: 3,
        windowCents: 22_500, rankMonths: [3], rankDay: [10], rankCents: [7_500],
        thisMonthCount: 1, thisMonthCents: 7_500)

    /// Usually the 3rd, not seen by the 8th.
    private let ngrok = ForecastRecurringRow(
        who: "Ngrok Inc.", isInflow: false, monthsSeen: 3, windowCount: 3,
        windowCents: 5_400, rankMonths: [3], rankDay: [3], rankCents: [1_800],
        thisMonthCount: 0, thisMonthCents: 0)

    /// Ran out of ranks at the cap: everyday spending, not six bills.
    private let lyft = ForecastRecurringRow(
        who: "Lyft", isInflow: false, monthsSeen: 2, windowCount: 28,
        windowCents: 35_300, rankMonths: [2, 2, 2, 2, 2, 2], rankDay: [10, 10, 12, 14, 16, 18],
        rankCents: [1_324, 789, 1_190, 945, 1_347, 1_079], thisMonthCount: 3, thisMonthCents: 3_459)

    /// Seen in one month of three: not a pattern yet.
    private let bestBuy = ForecastRecurringRow(
        who: "Best Buy", isInflow: false, monthsSeen: 1, windowCount: 1,
        windowCents: 135_026, rankMonths: [1], rankDay: [9], rankCents: [135_026],
        thisMonthCount: 0, thisMonthCents: 0)

    // MARK: - Which rows are regulars

    func testTwiceMonthlyPayrollIsTwoExpectedDeposits() {
        let stats = ForecastMath.stats(recurring: [payroll], flows: flows(),
                                       now: date("2026-09-08"), timeZone: utc)!
        let deposits = stats.predicted.filter(\.isInflow)
        XCTAssertEqual(deposits.map(\.dateLabel), ["Sep 15", "Sep 30"],
                       "day 31 clamps to the month's last day")
        XCTAssertEqual(stats.predictedInCents, 630_000)
        XCTAssertEqual(stats.predictedInCount, 2)
    }

    func testARegularAlreadyPostedThisMonthIsNotExpectedAgain() {
        let stats = ForecastMath.stats(recurring: [insurance, rent], flows: flows(),
                                       now: date("2026-09-08"), timeZone: utc)!
        XCTAssertEqual(stats.predicted.map(\.who), ["Rent"])
        XCTAssertEqual(stats.predictedOutCents, 200_000)
    }

    /// A late bill is still a bill. It lands on today so the list reads "any
    /// day now" instead of a date that has passed.
    func testAnOverdueRegularIsStillCountedAndPlacedOnToday() {
        let stats = ForecastMath.stats(recurring: [ngrok], flows: flows(),
                                       now: date("2026-09-08"), timeZone: utc)!
        XCTAssertEqual(stats.predicted.count, 1)
        XCTAssertTrue(stats.predicted[0].isOverdue)
        XCTAssertEqual(stats.predicted[0].dateLabel, "Sep 8")
        XCTAssertEqual(stats.predictedOutCents, 1_800)
    }

    func testANameThatRecursTooOftenIsEverydaySpendingNotBills() {
        XCTAssertTrue(ForecastMath.regularRanks(lyft, windowMonths: 3).isEmpty)
        let stats = ForecastMath.stats(recurring: [lyft], flows: flows(),
                                       now: date("2026-09-08"), timeZone: utc)!
        XCTAssertTrue(stats.predicted.isEmpty)
    }

    func testANameSeenInOnlyOneMonthIsNotARegular() {
        XCTAssertTrue(ForecastMath.regularRanks(bestBuy, windowMonths: 3).isEmpty)
    }

    /// Two of three months qualifies a rank; one of three does not. A bill
    /// with a usual add-on therefore expects the bill and not the add-on.
    func testOnlyRanksSeenInMostMonthsAreExpected() {
        let cloud = ForecastRecurringRow(
            who: "Cloud Host", isInflow: false, monthsSeen: 3, windowCount: 7,
            windowCents: 40_000, rankMonths: [3, 2, 1, 1], rankDay: [28, 22, 24, 31],
            rankCents: [2_000, 6_500, 2_000, 10_000], thisMonthCount: 0, thisMonthCents: 0)
        XCTAssertEqual(ForecastMath.regularRanks(cloud, windowMonths: 3), 0..<2)
        XCTAssertEqual(ForecastMath.requiredMonths(windowMonths: 3), 2)
        XCTAssertEqual(ForecastMath.requiredMonths(windowMonths: 2), 2)
        XCTAssertEqual(ForecastMath.requiredMonths(windowMonths: 6), 4)
    }

    // MARK: - Arithmetic

    /// The everyday rate is what the window spent that no regular explains,
    /// per day over the window's own days — 92 for Jun–Aug.
    func testEverydayRateExcludesTheRegularsAndUsesTheWindowsDays() {
        let stats = ForecastMath.stats(recurring: [payroll, rent, insurance], flows: flows(),
                                       now: date("2026-09-08"), timeZone: utc)!
        let windowOut = 700_000 + 1_100_000 + 800_000
        let regularsOut = 600_000 + 22_500        // payroll is money in, not subtracted
        XCTAssertEqual(stats.everydayPerDayCents, (windowOut - regularsOut) / 92)
        XCTAssertEqual(stats.daysLeft, 23, "the 8th through the 30th, today included")
        XCTAssertEqual(stats.everydayCents, stats.everydayPerDayCents * 23)
        XCTAssertEqual(stats.windowMonths, 3)
        XCTAssertEqual(stats.windowLabel, "Jun\u{2013}Aug")
        XCTAssertEqual(stats.monthEndLabel, "Sep 30")
    }

    func testProjectionStartsFromTheBalanceLessPendingAndAddsEverythingUp() {
        let stats = ForecastMath.stats(recurring: [payroll, rent], flows: flows(),
                                       now: date("2026-09-08"), timeZone: utc)!
        XCTAssertEqual(stats.availableCents, 250_000 - 50_000)
        XCTAssertEqual(
            stats.projectedCents,
            250_000 - 50_000 + 630_000 - 200_000 - stats.everydayCents
        )
    }

    /// The expected list is in date order — it is read as "what's coming".
    func testExpectedTransactionsAreSoonestFirst() {
        let stats = ForecastMath.stats(recurring: [rent, payroll, ngrok], flows: flows(),
                                       now: date("2026-09-08"), timeZone: utc)!
        XCTAssertEqual(stats.predicted.map(\.who),
                       ["Ngrok Inc.", "ACME PAYROLL DD", "Rent", "ACME PAYROLL DD"])
    }

    // MARK: - When not to forecast

    /// One complete month is a month, not a pattern: no forecast at all
    /// rather than one built on it.
    func testNoForecastWithFewerThanTwoCompleteMonths() {
        let short = [
            ForecastFlowRow(period: "2026-08-01", outflowCents: 800_000, inflowCents: 630_000,
                            txnCount: 227, balanceCents: 250_000),
            ForecastFlowRow(period: "2026-09-01", outflowCents: 100_000, inflowCents: 0,
                            txnCount: 34, balanceCents: 250_000),
        ]
        XCTAssertNil(ForecastMath.stats(recurring: [payroll], flows: short,
                                        now: date("2026-09-08"), timeZone: utc))
    }

    func testNoCheckingAccountMeansNoForecast() {
        XCTAssertNil(ForecastMath.stats(recurring: [payroll], flows: [],
                                        now: date("2026-09-08"), timeZone: utc))
    }

    // MARK: - Wire format

    /// Postgres bigint arrays can arrive quoted; a forecast that silently
    /// reads every amount as zero would be worse than no forecast.
    func testRowsDecodeQuotedBigintArrays() throws {
        let json = """
        {"who":"Rent","is_inflow":false,"months_seen":3,"window_count":3,
         "window_cents":"600000","rank_months":[3],"rank_day":[28],"rank_cents":["200000"],
         "this_month_count":0,"this_month_cents":"0"}
        """
        let row = try JSONDecoder().decode(ForecastRecurringRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.windowCents, 600_000)
        XCTAssertEqual(row.rankCents, [200_000])
        XCTAssertEqual(row.rankMonths, [3])
    }
}
