import XCTest
@testable import Spendcap

/// The weekly buckets behind "free to spend this week".
///
/// Two fixtures do most of the work. **February 2027** is the clean case — it
/// opens on a Monday, closes on a Sunday and is exactly four Mon–Sun weeks, so
/// the arithmetic is readable by eye. **August 2026** is the awkward one and is
/// the month the feature actually shipped in: it opens with a two-day Sat–Sun
/// stub and closes with a lone Monday, six buckets in all, and the numbers here
/// are the user's real ones ($1,200 discretionary against live spending).
final class WeekMathTests: XCTestCase {

    /// Fixed timezone + fixed "now" so the buckets are deterministic wherever
    /// and whenever the suite runs.
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = utc
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: iso.count == 10 ? iso + " 12:00" : iso)!
    }

    private func day(_ iso: String, _ cents: Int) -> DiscretionaryDay {
        DiscretionaryDay(day: iso, spentCents: cents)
    }

    private func stats(_ month: String, planned: Int = 120_000,
                       daily: [DiscretionaryDay] = [], now: String) -> WeekStats {
        WeekMath.stats(month: date(month), discretionaryPlannedCents: planned,
                       daily: daily, now: date(now), timeZone: utc)
    }

    // MARK: - Bucket construction

    func testCleanMonthIsFourMondayToSundayWeeks() {
        let s = stats("2027-02-01", now: "2027-02-01")
        XCTAssertEqual(s.weeks.count, 4)
        XCTAssertEqual(s.weeks.map(\.dayCount), [7, 7, 7, 7])
        XCTAssertEqual(s.weeks.first?.start, date("2027-02-01 00:00"))
        XCTAssertEqual(s.weeks.last?.end, date("2027-02-28 00:00"))
    }

    /// August 2026 opens Saturday and closes Monday, so the first and last
    /// buckets are stubs. Handing either one a full week's money is the bug
    /// day-pro-rating exists to avoid.
    func testMonthEdgesProduceShortBuckets() {
        let s = stats("2026-08-01", now: "2026-08-01")
        XCTAssertEqual(s.weeks.count, 6)
        XCTAssertEqual(s.weeks.map(\.dayCount), [2, 7, 7, 7, 7, 1])
        // 2/31 of $1,200, not a week's worth.
        XCTAssertEqual(s.weeks[0].allowanceCents, 7_741)
    }

    /// Only the *opening* week is the budget over four. Spend nothing and every
    /// later bucket is larger, because the money that was not spent is still
    /// there to be spread over fewer remaining days — which is the whole point.
    /// A month untouched until its last week has all $1,200 available in it.
    func testUntouchedMonthRollsEverythingForward() {
        let s = stats("2027-02-01", now: "2027-02-01")
        XCTAssertEqual(s.weeks.map(\.allowanceCents), [30_000, 40_000, 60_000, 120_000])
    }

    // MARK: - Rollover

    /// The example the model was signed off on: $1,200 over four weeks, week
    /// one spends $380, and the $80 overspend comes off *every* remaining week
    /// rather than landing entirely on week two — $820 across 3 weeks = $273.
    func testOverspendIsSpreadAcrossTheRemainingWeeks() {
        let over = stats("2027-02-01", daily: [day("2027-02-03", 38_000)], now: "2027-02-01")
        XCTAssertEqual(over.weeks[0].allowanceCents, 30_000)
        XCTAssertEqual(over.weeks[0].spentCents, 38_000)
        XCTAssertEqual(over.weeks[0].leftCents, -8_000)
        XCTAssertEqual(over.weeks[1].allowanceCents, 27_333)   // 82_000 * 7 / 21

        // The $80 came off all three remaining weeks, not just the next one:
        // every later bucket is smaller than it would have been untouched.
        let clean = stats("2027-02-01", now: "2027-02-01")
        for i in 1...3 {
            XCTAssertLessThan(over.weeks[i].allowanceCents, clean.weeks[i].allowanceCents)
        }
    }

    /// The other direction, and the thing the old `/4` divisor never did: an
    /// underspent week banks its leftover into the weeks that follow.
    func testUnderspendRollsForward() {
        let s = stats("2027-02-01", daily: [day("2027-02-03", 20_000)], now: "2027-02-01")
        XCTAssertEqual(s.weeks[0].leftCents, 10_000)
        XCTAssertEqual(s.weeks[1].allowanceCents, 33_333)   // 100_000 * 7 / 21
        XCTAssertGreaterThan(s.weeks[1].allowanceCents, s.weeks[0].allowanceCents)
    }

    /// A week's bucket is cut from what was actually *spent* before it, never
    /// from what the earlier weeks were allowed. Two weeks that each underspend
    /// must both bank, not just the most recent one.
    func testLeftoversAccumulateAcrossSeveralWeeks() {
        let s = stats("2027-02-01",
                      daily: [day("2027-02-03", 10_000), day("2027-02-10", 10_000)],
                      now: "2027-02-01")
        XCTAssertEqual(s.weeks[2].allowanceCents, 50_000)   // 100_000 * 7 / 14
    }

    /// The last bucket is handed the entire remainder — `daysLeft` equals its
    /// own length there — so the month's budget is never left stranded.
    func testFinalWeekReceivesTheWholeRemainder() {
        let s = stats("2027-02-01", daily: [day("2027-02-03", 45_000)], now: "2027-02-01")
        let spentBefore = s.weeks.dropLast().reduce(0) { $0 + $1.spentCents }
        XCTAssertEqual(s.weeks[3].allowanceCents, 120_000 - spentBefore)
    }

    /// With no discretionary budget there is nothing to hand out, so spending
    /// puts every following week in the red rather than dividing by zero. The
    /// card is hidden entirely in this state — it needs a planned total — so
    /// this pins the arithmetic, not something the user ever sees.
    func testUnbudgetedMonthGoesNegativeRatherThanDividingByZero() {
        let s = stats("2027-02-01", planned: 0, daily: [day("2027-02-03", 5_000)],
                      now: "2027-02-03")
        XCTAssertEqual(s.weeks.map(\.allowanceCents), [0, -1_666, -2_500, -5_000])
        XCTAssertEqual(s.freeToSpendThisWeekCents, -5_000)
    }

    // MARK: - Which week is "this week"

    func testCurrentWeekIsTheOneContainingToday() {
        let s = stats("2027-02-01", now: "2027-02-17")
        XCTAssertEqual(s.currentIndex, 2)
        XCTAssertEqual(s.currentWeek?.start, date("2027-02-15 00:00"))
    }

    /// The week turns over at 6am Monday, not midnight — Sunday-night spending
    /// belongs to the week that is ending.
    func testWeekDoesNotFlipUntilSixOnMonday() {
        XCTAssertEqual(stats("2027-02-01", now: "2027-02-07 23:59").currentIndex, 0)
        XCTAssertEqual(stats("2027-02-01", now: "2027-02-08 03:00").currentIndex, 0)
        XCTAssertEqual(stats("2027-02-01", now: "2027-02-08 05:59").currentIndex, 0)
        XCTAssertEqual(stats("2027-02-01", now: "2027-02-08 06:00").currentIndex, 1)
    }

    /// The 6am window on a month that opens on a Monday is the only way to land
    /// before the month's first bucket. Last month's money is gone by then, so
    /// the answer is the first bucket rather than nothing.
    func testPreDawnOnTheFirstOfTheMonthClampsToTheFirstWeek() {
        XCTAssertEqual(stats("2027-02-01", now: "2027-02-01 03:00").currentIndex, 0)
    }

    /// A finished month has no bucket left to spend, so there is no figure to
    /// show — the card is current-month only for exactly this reason.
    func testFinishedMonthHasNoCurrentWeek() {
        let s = stats("2027-02-01", now: "2027-03-05")
        XCTAssertNil(s.currentIndex)
        XCTAssertEqual(s.freeToSpendThisWeekCents, 0)
    }

    // MARK: - The real month this shipped in

    /// August 2026 with the account's actual discretionary spending. On Sunday
    /// the 16th the week Aug 10–16 is $59.51 over its bucket — where the old
    /// flat `(120_000 - 79_309) / 4` reported a comfortable $101.72 free.
    func testAugust2026AgainstRealSpending() {
        let real = [
            day("2026-08-03", 26_071), day("2026-08-04", 9_564),
            day("2026-08-05", 3_717), day("2026-08-06", 5_031),
            day("2026-08-07", 7_209), day("2026-08-10", 6_298),
            day("2026-08-13", 6_544), day("2026-08-14", 2_801),
            day("2026-08-15", 12_074),
        ]
        let s = stats("2026-08-01", daily: real, now: "2026-08-16")

        XCTAssertEqual(s.currentIndex, 2)
        XCTAssertEqual(s.weeks[2].start, date("2026-08-10 00:00"))
        XCTAssertEqual(s.weeks[2].end, date("2026-08-16 00:00"))
        XCTAssertEqual(s.weeks[1].spentCents, 51_592)       // the week that overspent
        XCTAssertEqual(s.weeks[2].allowanceCents, 21_766)   // 68_408 * 7 / 22
        XCTAssertEqual(s.weeks[2].spentCents, 27_717)
        XCTAssertEqual(s.freeToSpendThisWeekCents, -5_951)

        // And Monday recuts it from what is genuinely left: 40_691 * 7 / 15.
        let monday = stats("2026-08-01", daily: real, now: "2026-08-17 06:00")
        XCTAssertEqual(monday.currentIndex, 3)
        XCTAssertEqual(monday.freeToSpendThisWeekCents, 18_989)
    }

    /// Every day the server reports has to land in exactly one bucket, or the
    /// weekly figures and the month's discretionary total describe different
    /// money.
    func testEveryDayOfSpendLandsInExactlyOneWeek() {
        let real = [
            day("2026-08-01", 1_000), day("2026-08-02", 1_000),
            day("2026-08-16", 1_000), day("2026-08-17", 1_000),
            day("2026-08-31", 1_000),
        ]
        let s = stats("2026-08-01", daily: real, now: "2026-08-16")
        XCTAssertEqual(s.weeks.reduce(0) { $0 + $1.spentCents }, 5_000)
        XCTAssertEqual(s.weeks.map(\.spentCents), [2_000, 0, 1_000, 1_000, 0, 1_000])
    }

    /// Spending dated outside the month is not this month's money. Plaid can
    /// hand back a day from either side of a boundary as pending rows settle.
    func testSpendOutsideTheMonthIsIgnored() {
        let s = stats("2027-02-01",
                      daily: [day("2027-01-31", 99_000), day("2027-03-01", 99_000)],
                      now: "2027-02-03")
        XCTAssertEqual(s.weeks.reduce(0) { $0 + $1.spentCents }, 0)
        XCTAssertEqual(s.freeToSpendThisWeekCents, 30_000)
    }
}
