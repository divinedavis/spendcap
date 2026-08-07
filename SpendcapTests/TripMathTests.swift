import XCTest
@testable import Spendcap

/// The trip screens are mostly presentation, but two things in here are easy to
/// get quietly wrong and expensive to notice: the date-range label (which has a
/// timezone trap the Months tab already fell into once) and what a trip is
/// judged against when the user set no explicit budget.
final class TripMathTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = utc
        f.locale = posix
        return f.date(from: iso)!
    }

    private func label(_ start: String?, _ end: String?, today: String = "2026-08-06") -> String? {
        TripMath.dateRangeLabel(startsOn: start, endsOn: end,
                                today: date(today), timeZone: utc, locale: posix)
    }

    // MARK: - Date range labels

    func testRangeWithinOneMonthDoesNotRepeatTheMonth() {
        // "Mar 3–11", not "Mar 3 – Mar 11": repeating the month reads as two
        // unrelated dates rather than a span.
        XCTAssertEqual(label("2026-03-03", "2026-03-11"), "Mar 3–11")
    }

    func testRangeAcrossMonthsNamesBothMonths() {
        XCTAssertEqual(label("2026-03-28", "2026-04-02"), "Mar 28 – Apr 2")
    }

    func testSingleDayCollapsesToOneDate() {
        XCTAssertEqual(label("2026-03-03", "2026-03-03"), "Mar 3")
    }

    func testYearAppearsOnlyWhenItIsNotTheCurrentYear() {
        XCTAssertEqual(label("2026-03-03", "2026-03-11"), "Mar 3–11")
        XCTAssertEqual(label("2027-03-03", "2027-03-11", today: "2026-08-06"),
                       "Mar 3, 2027 – Mar 11, 2027")
    }

    func testRangeSpanningNewYearShowsBothYears() {
        XCTAssertEqual(label("2026-12-28", "2027-01-02", today: "2026-08-06"),
                       "Dec 28, 2026 – Jan 2, 2027")
    }

    func testOpenEndedRanges() {
        XCTAssertEqual(label("2026-03-03", nil), "from Mar 3")
        XCTAssertEqual(label(nil, "2026-03-11"), "until Mar 11")
    }

    func testNoDatesHasNoLabel() {
        // Nil, not "" — the screen renders its own wording for a trip with no
        // dates, and an empty string would leave a gap instead.
        XCTAssertNil(label(nil, nil))
    }

    /// The Months tab was relabelled by one month when a bucket built in one
    /// timezone was formatted in the device's. These labels are built from
    /// "yyyy-MM-dd" strings parsed and formatted in the *same* zone, so a
    /// device far from UTC must not shift the day.
    func testLabelIsStableAcrossTimezones() {
        for identifier in ["UTC", "Pacific/Kiritimati", "Pacific/Midway", "Asia/Tokyo"] {
            let zone = TimeZone(identifier: identifier)!
            let result = TripMath.dateRangeLabel(
                startsOn: "2026-03-03", endsOn: "2026-03-11",
                today: date("2026-08-06"), timeZone: zone, locale: posix)
            XCTAssertEqual(result, "Mar 3–11", "shifted in \(identifier)")
        }
    }

    func testDateStringRoundTrips() {
        for identifier in ["UTC", "Pacific/Kiritimati", "Pacific/Midway"] {
            let zone = TimeZone(identifier: identifier)!
            let parsed = TripMath.date(from: "2026-03-03", timeZone: zone)!
            XCTAssertEqual(TripMath.string(from: parsed, timeZone: zone), "2026-03-03",
                           "round trip broke in \(identifier)")
        }
    }

    // MARK: - Day count

    func testDayCountIsInclusive() {
        // Mar 3 to Mar 11 is a nine-day trip, not eight — you are away on both.
        XCTAssertEqual(TripMath.dayCount(startsOn: "2026-03-03", endsOn: "2026-03-11", timeZone: utc), 9)
        XCTAssertEqual(TripMath.dayCount(startsOn: "2026-03-03", endsOn: "2026-03-03", timeZone: utc), 1)
    }

    func testDayCountNeedsBothEnds() {
        XCTAssertNil(TripMath.dayCount(startsOn: "2026-03-03", endsOn: nil, timeZone: utc))
        XCTAssertNil(TripMath.dayCount(startsOn: nil, endsOn: nil, timeZone: utc))
    }

    // MARK: - Phase

    func testPhaseBoundariesAreInclusive() {
        let today = date("2026-08-06")
        // The last day of a trip is still the trip.
        XCTAssertEqual(TripMath.phase(startsOn: "2026-08-01", endsOn: "2026-08-06",
                                      today: today, timeZone: utc), .current)
        XCTAssertEqual(TripMath.phase(startsOn: "2026-08-06", endsOn: "2026-08-10",
                                      today: today, timeZone: utc), .current)
        XCTAssertEqual(TripMath.phase(startsOn: "2026-08-01", endsOn: "2026-08-05",
                                      today: today, timeZone: utc), .past)
        XCTAssertEqual(TripMath.phase(startsOn: "2026-09-01", endsOn: "2026-09-05",
                                      today: today, timeZone: utc), .upcoming)
    }

    func testUndatedTripIsUpcoming() {
        // A trip with no dates is one you are still planning, not one that is
        // somehow happening right now.
        XCTAssertEqual(TripMath.phase(startsOn: nil, endsOn: nil,
                                      today: date("2026-08-06"), timeZone: utc), .upcoming)
    }

    // MARK: - What a trip is judged against

    private func totals(budget: Int?, planned: Int, spent: Int) -> TripTotals {
        TripTotals(tripId: UUID(), name: "Tokyo", kind: .trip,
                   startsOn: "2026-03-03", endsOn: "2026-03-11",
                   budgetCents: budget, plannedCents: planned, spentCents: spent,
                   txnCount: 3, lineCount: 3)
    }

    func testExplicitBudgetBeatsThePlan() {
        XCTAssertEqual(totals(budget: 150_000, planned: 120_000, spent: 0).capCents, 150_000)
    }

    func testPlanIsTheBudgetWhenNoneIsSet() {
        XCTAssertEqual(totals(budget: nil, planned: 120_000, spent: 0).capCents, 120_000)
    }

    /// A trip with nothing planned and no budget has no yardstick. It must read
    /// as "no budget", not as 0% of zero — which would render as either
    /// permanently fine or permanently over depending on the rounding.
    func testNoBudgetAndNoPlanHasNoCap() {
        XCTAssertNil(totals(budget: nil, planned: 0, spent: 5_000).capCents)
    }

    func testZeroBudgetIsABudget() {
        // Distinct from nil: the user said "spend nothing on this".
        XCTAssertEqual(totals(budget: 0, planned: 120_000, spent: 100).capCents, 0)
    }

    func testStatusMatchesTheDailyCapThresholds() {
        XCTAssertEqual(TripMath.status(spentCents: 0, capCents: 100_000), .under)
        XCTAssertEqual(TripMath.status(spentCents: 79_999, capCents: 100_000), .under)
        XCTAssertEqual(TripMath.status(spentCents: 80_000, capCents: 100_000), .warn)
        XCTAssertEqual(TripMath.status(spentCents: 100_000, capCents: 100_000), .over)
        XCTAssertEqual(TripMath.status(spentCents: 100_001, capCents: 100_000), .over)
    }

    func testStatusWithoutACapIsNeverAWarning() {
        // Nothing to be over, so nothing to warn about.
        XCTAssertEqual(TripMath.status(spentCents: 999_999, capCents: nil), .under)
        XCTAssertEqual(TripMath.status(spentCents: 999_999, capCents: 0), .under)
    }

    // MARK: - Decoding

    /// PostgREST returns a Postgres bigint as a number or a string depending on
    /// magnitude. Guessing wrong drops the value to zero silently, which on
    /// this screen means a trip that looks free.
    func testBigintDecodesFromEitherNumberOrString() throws {
        let asNumber = """
        {"line_id":null,"name":null,"symbol":null,"planned_cents":0,
         "occurs_on":null,"sort_order":0,"spent_cents":123456,"txn_count":2}
        """
        let asString = """
        {"line_id":null,"name":null,"symbol":null,"planned_cents":"0",
         "occurs_on":null,"sort_order":0,"spent_cents":"123456","txn_count":2}
        """
        let decoder = JSONDecoder()
        let a = try decoder.decode(TripLineSpend.self, from: Data(asNumber.utf8))
        let b = try decoder.decode(TripLineSpend.self, from: Data(asString.utf8))
        XCTAssertEqual(a.spentCents, 123_456)
        XCTAssertEqual(b.spentCents, 123_456)
        XCTAssertEqual(a, b)
    }

    /// The null-id row from `trip_line_spend` is spending on the trip that is
    /// under no category. It must survive decoding as the unfiled row rather
    /// than failing the whole response.
    func testUnfiledRowDecodes() throws {
        let json = """
        {"line_id":null,"name":null,"symbol":null,"planned_cents":0,
         "occurs_on":null,"sort_order":2147483647,"spent_cents":4200,"txn_count":1}
        """
        let row = try JSONDecoder().decode(TripLineSpend.self, from: Data(json.utf8))
        XCTAssertTrue(row.isUnfiled)
        XCTAssertEqual(row.displayName, "Not filed yet")
        XCTAssertEqual(row.spentCents, 4_200)
        // Nothing was planned for it, so it can never be "over".
        XCTAssertFalse(row.isOver)
    }

    func testLineProgressIsClampedAndSafeWithNoPlan() {
        let unplanned = TripLineSpend(lineId: UUID(), name: "Food", symbol: nil,
                                      plannedCents: 0, occursOn: nil, sortOrder: 1,
                                      spentCents: 9_000, txnCount: 4)
        XCTAssertEqual(unplanned.progress, 0)
        XCTAssertFalse(unplanned.isOver)

        let over = TripLineSpend(lineId: UUID(), name: "Food", symbol: nil,
                                 plannedCents: 10_000, occursOn: nil, sortOrder: 1,
                                 spentCents: 25_000, txnCount: 4)
        XCTAssertEqual(over.progress, 1.0)
        XCTAssertTrue(over.isOver)
        XCTAssertEqual(over.remainingCents, -15_000)
    }

    // MARK: - Ticking a line off as paid

    /// The exact string the live PostgREST returned for a `timestamptz`,
    /// captured from the API rather than guessed: five fractional digits and a
    /// "+00:00" offset. ISO8601DateFormatter with .withFractionalSeconds wants
    /// exactly three and returns nil for this — which would have made every
    /// ticked line silently read as unticked.
    func testSettledAtDecodesThePostgrestWireFormat() throws {
        let json = """
        {"line_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Flights",
         "symbol":"airplane","planned_cents":80000,"occurs_on":null,
         "sort_order":1,"spent_cents":0,"txn_count":0,
         "settled_at":"2026-08-07T18:50:51.08808+00:00"}
        """
        let row = try JSONDecoder().decode(TripLineSpend.self, from: Data(json.utf8))
        XCTAssertTrue(row.isSettled, "a ticked line must decode as ticked")
        XCTAssertNotNil(row.settledAt)
    }

    /// Postgres trims trailing zeroes, so the digit count varies row to row.
    func testSettledAtDecodesEveryFractionalDigitCount() {
        let shapes = [
            "2026-08-07T18:50:51+00:00",
            "2026-08-07T18:50:51.1+00:00",
            "2026-08-07T18:50:51.088+00:00",
            "2026-08-07T18:50:51.08808+00:00",
            "2026-08-07T18:50:51.088080+00:00",
            "2026-08-07T18:50:51Z",
            "2026-08-07T18:50:51.08808Z",
        ]
        for shape in shapes {
            XCTAssertNotNil(TripDecoding.timestamp(shape), "failed to parse \(shape)")
        }
        XCTAssertNil(TripDecoding.timestamp("not a date"))
    }

    func testNullSettledAtIsOutstanding() throws {
        let json = """
        {"line_id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Hotel","symbol":null,
         "planned_cents":100000,"occurs_on":null,"sort_order":2,
         "spent_cents":0,"txn_count":0,"settled_at":null}
        """
        let row = try JSONDecoder().decode(TripLineSpend.self, from: Data(json.utf8))
        XCTAssertFalse(row.isSettled)
        XCTAssertTrue(row.isSettleable)
    }

    /// The unfiled rollup row is not something anyone created, so it must never
    /// offer a checkbox.
    func testUnfiledRowIsNotSettleable() throws {
        let json = """
        {"line_id":null,"name":null,"symbol":null,"planned_cents":0,"occurs_on":null,
         "sort_order":2147483647,"spent_cents":4200,"txn_count":1,"settled_at":null}
        """
        let row = try JSONDecoder().decode(TripLineSpend.self, from: Data(json.utf8))
        XCTAssertTrue(row.isUnfiled)
        XCTAssertFalse(row.isSettleable)
    }

    /// Ticking a line must not move money. The trip's spend means "we watched
    /// this leave the account"; a checkbox is an assertion about the world.
    func testTickingALineDoesNotChangeItsSpend() {
        let outstanding = TripLineSpend(lineId: UUID(), name: "Flights", symbol: nil,
                                        plannedCents: 80_000, occursOn: nil, sortOrder: 1,
                                        spentCents: 0, txnCount: 0, settledAt: nil)
        let ticked = TripLineSpend(lineId: outstanding.lineId, name: "Flights", symbol: nil,
                                   plannedCents: 80_000, occursOn: nil, sortOrder: 1,
                                   spentCents: 0, txnCount: 0, settledAt: Date())
        XCTAssertEqual(outstanding.spentCents, ticked.spentCents)
        XCTAssertEqual(outstanding.plannedCents, ticked.plannedCents)
        XCTAssertFalse(ticked.isOver, "a paid line with no charges is not over")
    }
}
