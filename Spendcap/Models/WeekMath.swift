import Foundation

/// One day's discretionary outflow, straight from `discretionary_daily()`.
///
/// Discretionary is a server-side answer, not a client-side one: it depends on
/// which budget line the rules route a transaction into and what kind that
/// line carries, and the rules live in the database. The month transactions
/// Trends fetches carry no resolved line, so they cannot be bucketed here.
struct DiscretionaryDay: Codable, Equatable {
    /// "yyyy-MM-dd" from a Postgres date column — no time of day exists.
    let day: String
    let spentCents: Int

    enum CodingKeys: String, CodingKey {
        case day
        case spentCents = "spent_cents"
    }
}

/// One Monday–Sunday week of the month, clipped to the month's edges.
///
/// A month is 4–6 of these and the first and last are usually short — August
/// 2026 opens with a two-day Sat–Sun stub and closes with a lone Monday. Those
/// stubs are why an allowance cannot simply be the month's budget over four:
/// a one-day bucket handed a full week's money reads as a windfall on the 31st.
struct SpendWeek: Identifiable, Equatable {
    let start: Date
    /// Inclusive — the last day that spends this bucket.
    let end: Date
    let dayCount: Int
    /// What this week was given when it opened, from what the month had left
    /// at that moment. Frozen for the week's duration: recutting it mid-week
    /// would quietly refill a bucket the user had already emptied.
    let allowanceCents: Int
    let spentCents: Int

    /// Negative means this week is over its bucket. The sign is the answer and
    /// is shown as-is — the shortfall comes off the following weeks when they
    /// open, not out of this one retroactively.
    var leftCents: Int { allowanceCents - spentCents }

    var id: Date { start }
}

struct WeekStats: Equatable {
    var weeks: [SpendWeek]
    /// Index into `weeks` of the week the user is standing in, resolved
    /// against the 6am flip. Nil when the month holds no weeks at all.
    var currentIndex: Int?

    var currentWeek: SpendWeek? {
        guard let currentIndex, weeks.indices.contains(currentIndex) else { return nil }
        return weeks[currentIndex]
    }

    /// The one number the card shows.
    var freeToSpendThisWeekCents: Int { currentWeek?.leftCents ?? 0 }
}

/// Weekly buckets with rollover — the model behind "free to spend this week".
///
/// **The rule, in one line:** when a week opens, its bucket is what the month
/// has left divided across the days that remain, times the days in that week.
///
/// That single formula does both halves of what was asked for. Underspend a
/// week and the money it did not use is still in "what the month has left", so
/// the next Monday's bucket comes back bigger — the leftover rolls over.
/// Overspend and the excess is already missing from the same figure, so it
/// comes off *every* remaining week rather than landing entirely on the next
/// one. Nothing is recalculated while a week is under its bucket; the number
/// just counts down.
///
/// It replaced `(discretionaryPlanned - discretionarySpent) / 4`, which spread
/// the whole month's remaining money over a flat four weeks no matter which
/// week it was or how the earlier ones had gone.
///
/// Pro-rating by *days* rather than by whole weeks is what makes the month's
/// short first and last buckets behave. It also makes the final bucket exact:
/// on the last day of the month `daysLeft` equals `dayCount`, so that bucket
/// is handed the entire remainder, and the weeks always add back up to the
/// month's discretionary budget.
///
/// All of it is pure so the awkward parts — stub weeks, the 6am flip, a month
/// that opens mid-week — are testable without a network.
enum WeekMath {
    /// The week turns over at 6am Monday, not midnight: money spent late on a
    /// Sunday night belongs to the week that is ending, not to the one that
    /// has not started yet.
    ///
    /// This shifts *which bucket the user is looking at*, and nothing else. It
    /// cannot shift which bucket a transaction falls into, because bank
    /// transactions carry a date and no time of day — a charge dated Monday is
    /// Monday's, whatever hour it happened. So between midnight and 6am on a
    /// Monday the card still shows the outgoing week, and anything already
    /// dated the new Monday is sitting in the incoming week's bucket where it
    /// will be visible at 6am.
    static let flipHour = 6

    static func stats(
        month: Date,
        discretionaryPlannedCents: Int,
        daily: [DiscretionaryDay],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> WeekStats {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        guard let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: month)),
              let range = calendar.range(of: .day, in: .month, for: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: range.count - 1, to: monthStart)
        else { return WeekStats(weeks: [], currentIndex: nil) }

        let spendByDay = dayIndex(daily, calendar: calendar, timeZone: timeZone)

        var weeks: [SpendWeek] = []
        var remainingCents = discretionaryPlannedCents
        var cursor = monthStart

        while cursor <= monthEnd {
            let end = min(sundayEnding(cursor, calendar: calendar), monthEnd)
            let dayCount = days(from: cursor, to: end, calendar: calendar)
            let daysLeft = days(from: cursor, to: monthEnd, calendar: calendar)

            // `daysLeft` is always at least `dayCount` here, so it can only be
            // zero if the month itself is empty — which the guard above rules
            // out. Belt and braces: a division by zero is worse than a $0 week.
            let allowance = daysLeft > 0 ? remainingCents * dayCount / daysLeft : 0

            var spent = 0
            var day = cursor
            while day <= end {
                spent += spendByDay[calendar.startOfDay(for: day)] ?? 0
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }

            weeks.append(SpendWeek(start: cursor, end: end, dayCount: dayCount,
                                   allowanceCents: allowance, spentCents: spent))

            // What the *next* week inherits is the month's budget less what was
            // actually spent, never less what was allowed. Subtracting the
            // allowance instead would make an underspent week vanish and a
            // overspent one free.
            remainingCents -= spent

            guard let next = calendar.date(byAdding: .day, value: 1, to: end) else { break }
            cursor = next
        }

        return WeekStats(weeks: weeks,
                         currentIndex: currentIndex(in: weeks, now: now, calendar: calendar))
    }

    // MARK: - Pieces

    /// The Sunday that closes `date`'s week. Gregorian weekdays run 1 = Sunday
    /// … 7 = Saturday, so the offset back to Monday is `(weekday + 5) % 7` —
    /// derived rather than read from `Calendar.firstWeekday`, which follows the
    /// device locale and would put the week boundary somewhere else entirely on
    /// a phone set to the US.
    static func sundayEnding(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let sinceMonday = (weekday + 5) % 7
        let start = calendar.date(byAdding: .day, value: -sinceMonday,
                                  to: calendar.startOfDay(for: date)) ?? date
        return calendar.date(byAdding: .day, value: 6, to: start) ?? date
    }

    private static func days(from: Date, to: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: from)
        let b = calendar.startOfDay(for: to)
        return (calendar.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }

    /// Which bucket the user is standing in, after the 6am flip is applied.
    ///
    /// Before the month's first week the answer is that first week rather than
    /// nothing: the only way to land there is the 6am window on a month that
    /// opens on a Monday, and last month's money is gone by then anyway.
    /// After the month's end there is no current week — a finished month has
    /// no bucket left to spend.
    private static func currentIndex(in weeks: [SpendWeek], now: Date,
                                     calendar: Calendar) -> Int? {
        guard !weeks.isEmpty else { return nil }
        let effective = calendar.startOfDay(
            for: now.addingTimeInterval(-Double(flipHour) * 3600))
        if effective < calendar.startOfDay(for: weeks[0].start) { return 0 }
        return weeks.firstIndex { effective <= calendar.startOfDay(for: $0.end) }
    }

    private static func dayIndex(_ daily: [DiscretionaryDay], calendar: Calendar,
                                 timeZone: TimeZone) -> [Date: Int] {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")

        var index: [Date: Int] = [:]
        for row in daily {
            guard let date = parser.date(from: row.day) else { continue }
            index[calendar.startOfDay(for: date), default: 0] += row.spentCents
        }
        return index
    }
}
