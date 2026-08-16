import Foundation

/// The inputs of the last Trends render, persisted so the next cold launch can
/// draw real numbers on its first frame instead of $0.00 that jumps once the
/// network answers. The snapshot stores the *fetched rows*, not the derived
/// stats — the same `MonthMath`/`CategoryMath` run on them at restore time, so
/// a cached frame can never disagree with what a live one would have shown.
struct TrendsSnapshot: Codable, Equatable {
    /// Lowercased UUID of the account the rows belong to. Checked before use:
    /// one user's bank history must never flash on another user's screen.
    let userId: String
    let savedAt: Date
    let transactions: [BankTransaction]
    let budget: Budget
    let categoryRows: [CategorySpendRow]
    /// Per-day discretionary spend, for the weekly buckets. Optional so a
    /// snapshot written before the weekly card shipped still decodes — an
    /// older file restores the chart and simply carries no weekly figure until
    /// the network answers, which is the state the card already handles.
    var dailyDiscretionary: [DiscretionaryDay]?

    /// Usable only for the same signed-in user in the same calendar month.
    /// Last month's rows would rebuild into an empty chart — worse than the
    /// loading state the snapshot exists to replace.
    func isUsable(for currentUserId: String?, now: Date = Date(),
                  calendar: Calendar = .current) -> Bool {
        guard let currentUserId, currentUserId == userId else { return false }
        return calendar.isDate(savedAt, equalTo: now, toGranularity: .month)
    }
}

/// One JSON file in Application Support. Written with complete file
/// protection — these are bank transactions at rest — and read synchronously
/// at view-model init, which is after first unlock by definition.
enum TrendsSnapshotStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("trends-snapshot.json")
    }

    static func load() -> TrendsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TrendsSnapshot.self, from: data)
    }

    static func save(_ snapshot: TrendsSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Called on sign-out and account deletion — the guard in `isUsable`
    /// already stops cross-user display, but the rows themselves must not
    /// outlive the session that fetched them.
    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
