import XCTest
@testable import Spendcap

/// The Trends period chip: this month and the previous two.
///
/// Every case fixes `now` and the timezone. The awkward parts are all here —
/// year boundaries, month lengths, and which day a finished month should be
/// read as of — and none of them are observable on a screenshot taken in
/// August.
final class TrendsPeriodTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func ymd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private func txn(_ day: String, _ cents: Int) -> BankTransaction {
        BankTransaction(id: UUID(), date: day, name: "Test", amountCents: cents)
    }

    // MARK: - Which month

    func testThreePeriodsAreOfferedNewestFirst() {
        XCTAssertEqual(TrendsPeriod.allCases.map(\.monthsBack), [0, 1, 2])
    }

    func testStartOfMonthWalksBackTheRightNumberOfMonths() {
        let now = date(2026, 8, 5)
        XCTAssertEqual(ymd(TrendsPeriod.thisMonth.startOfMonth(now: now, timeZone: utc)), "2026-08-01")
        XCTAssertEqual(ymd(TrendsPeriod.lastMonth.startOfMonth(now: now, timeZone: utc)), "2026-07-01")
        XCTAssertEqual(ymd(TrendsPeriod.twoMonthsAgo.startOfMonth(now: now, timeZone: utc)), "2026-06-01")
    }

    /// `date(byAdding: .month, value: -1)` from the 31st has to clamp, which
    /// makes the answer depend on today's day-of-month. Stepping back a day at
    /// a time does not.
    func testTheThirtyFirstStillWalksBackOneMonthAtATime() {
        let now = date(2026, 8, 31)
        XCTAssertEqual(ymd(TrendsPeriod.lastMonth.startOfMonth(now: now, timeZone: utc)), "2026-07-01")
        XCTAssertEqual(ymd(TrendsPeriod.twoMonthsAgo.startOfMonth(now: now, timeZone: utc)), "2026-06-01")
    }

    func testMarchThirtyFirstReachesJanuaryNotFebruaryTwice() {
        let now = date(2026, 3, 31)
        XCTAssertEqual(ymd(TrendsPeriod.lastMonth.startOfMonth(now: now, timeZone: utc)), "2026-02-01")
        XCTAssertEqual(ymd(TrendsPeriod.twoMonthsAgo.startOfMonth(now: now, timeZone: utc)), "2026-01-01")
    }

    func testWindowCrossesTheYearBoundary() {
        let now = date(2027, 1, 15)
        XCTAssertEqual(ymd(TrendsPeriod.lastMonth.startOfMonth(now: now, timeZone: utc)), "2026-12-01")
        XCTAssertEqual(ymd(TrendsPeriod.twoMonthsAgo.startOfMonth(now: now, timeZone: utc)), "2026-11-01")
    }

    // MARK: - Reference date

    func testCurrentMonthIsReadAsOfNow() {
        let now = date(2026, 8, 5)
        XCTAssertEqual(TrendsPeriod.thisMonth.referenceDate(now: now, timeZone: utc), now,
                       "the current month must stop at today, not run to month end")
    }

    func testFinishedMonthIsReadAsOfItsLastDay() {
        let now = date(2026, 8, 5)
        XCTAssertEqual(ymd(TrendsPeriod.lastMonth.referenceDate(now: now, timeZone: utc)), "2026-07-31")
        XCTAssertEqual(ymd(TrendsPeriod.twoMonthsAgo.referenceDate(now: now, timeZone: utc)), "2026-06-30")
    }

    func testFebruaryLeapYearLastDay() {
        XCTAssertEqual(ymd(TrendsPeriod.lastMonth.referenceDate(now: date(2028, 3, 10), timeZone: utc)),
                       "2028-02-29")
        XCTAssertEqual(ymd(TrendsPeriod.lastMonth.referenceDate(now: date(2027, 3, 10), timeZone: utc)),
                       "2027-02-28")
    }

    func testLastDayOfMonthIsMonthEndEvenForTheCurrentMonth() {
        // The chart's right edge is month end whatever the series covers.
        XCTAssertEqual(ymd(TrendsPeriod.thisMonth.lastDayOfMonth(now: date(2026, 8, 5), timeZone: utc)),
                       "2026-08-31")
    }

    // MARK: - Labels

    func testCurrentMonthIsLabelledThisMonth() {
        XCTAssertEqual(TrendsPeriod.thisMonth.label(now: date(2026, 8, 5), timeZone: utc), "This month")
    }

    func testPastMonthsAreLabelledByName() {
        let now = date(2026, 8, 5)
        XCTAssertEqual(TrendsPeriod.lastMonth.label(now: now, timeZone: utc), "July")
        XCTAssertEqual(TrendsPeriod.twoMonthsAgo.label(now: now, timeZone: utc), "June")
    }

    /// A bare "December" in January would not say which December.
    func testMonthInAnotherYearCarriesTheYear() {
        let now = date(2027, 1, 15)
        XCTAssertTrue(TrendsPeriod.lastMonth.label(now: now, timeZone: utc).contains("2026"),
                      "a month in a different year must name it")
        XCTAssertTrue(TrendsPeriod.lastMonth.label(now: now, timeZone: utc).contains("December"))
        XCTAssertEqual(TrendsPeriod.thisMonth.monthName(now: now, timeZone: utc), "January",
                       "the current year is not worth repeating")
    }

    func testSpentCaptionDropsSoFarForAFinishedMonth() {
        XCTAssertEqual(TrendsPeriod.thisMonth.spentCaption, "Spent so far")
        XCTAssertEqual(TrendsPeriod.lastMonth.spentCaption, "Spent")
    }

    // MARK: - What the chart actually gets

    /// The point of the reference date: a finished month must chart all of
    /// itself. Read as of "now" it would stop on the 5th and report a month
    /// that ended five days in.
    func testAFinishedMonthChartsEveryDayOfIt() {
        let now = date(2026, 8, 5)
        let july = TrendsPeriod.lastMonth.referenceDate(now: now, timeZone: utc)
        let stats = MonthMath.stats(
            transactions: [txn("2026-07-02", 500), txn("2026-07-30", 120_000)],
            dailyLimitCents: 5000,
            now: july,
            timeZone: utc
        )
        XCTAssertEqual(stats.daysInMonth, 31)
        XCTAssertEqual(stats.daysElapsed, 31, "a finished month is fully elapsed")
        XCTAssertEqual(stats.spentCents, 120_500)
        XCTAssertEqual(ymd(stats.series.first!.date), "2026-07-01")
        XCTAssertEqual(ymd(stats.series.last!.date), "2026-07-31")
    }

    /// August rows must not turn up in July's chart. The fetch is bounded by
    /// the same reference date, but the math has to hold the line too.
    func testOtherMonthsAreExcludedFromAFinishedMonth() {
        let july = TrendsPeriod.lastMonth.referenceDate(now: date(2026, 8, 5), timeZone: utc)
        let stats = MonthMath.stats(
            transactions: [
                txn("2026-07-15", 1000),
                txn("2026-08-01", 9999),
                txn("2026-06-30", 8888),
            ],
            dailyLimitCents: 5000,
            now: july,
            timeZone: utc
        )
        XCTAssertEqual(stats.spentCents, 1000)
    }

    func testCurrentMonthStillStopsAtToday() {
        let now = date(2026, 8, 5)
        let stats = MonthMath.stats(
            transactions: [],
            dailyLimitCents: 5000,
            now: TrendsPeriod.thisMonth.referenceDate(now: now, timeZone: utc),
            timeZone: utc
        )
        XCTAssertEqual(stats.daysElapsed, 5)
        XCTAssertEqual(stats.daysInMonth, 31)
    }
}
