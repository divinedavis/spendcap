import Foundation

struct BankTransaction: Codable, Identifiable, Equatable {
    let id: UUID
    let date: String            // "yyyy-MM-dd" from Postgres date column
    let name: String
    let merchantName: String?
    let category: String?
    let amountCents: Int        // > 0 = money out (Plaid convention)
    let pending: Bool
    let isRemoved: Bool

    enum CodingKeys: String, CodingKey {
        case id, date, name, pending, category
        case merchantName = "merchant_name"
        case amountCents = "amount_cents"
        case isRemoved = "is_removed"
    }

    var displayName: String {
        let merchant = merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
        return merchant.isEmpty ? name : merchant
    }
}

struct BankAccount: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let mask: String?
    let subtype: String?

    enum CodingKeys: String, CodingKey {
        case id, name, mask, subtype
    }
}

struct PlaidItem: Codable, Identifiable, Equatable {
    let id: UUID
    let institutionName: String?
    let status: String
    let lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case institutionName = "institution_name"
        case lastSyncedAt = "last_synced_at"
    }
}

struct Budget: Codable, Equatable {
    var dailyLimitCents: Int
    var warnPct: Int

    enum CodingKeys: String, CodingKey {
        case dailyLimitCents = "daily_limit_cents"
        case warnPct = "warn_pct"
    }
}

enum SpendStatus: Equatable {
    case under
    case warn
    case over
}

/// Mirrors the server-side threshold logic in check_overspend so the UI and
/// pushes always agree.
enum BudgetMath {
    static func status(spentCents: Int, limitCents: Int, warnPct: Int) -> SpendStatus {
        guard limitCents > 0 else { return .under }
        if spentCents >= limitCents { return .over }
        if spentCents * 100 >= limitCents * warnPct { return .warn }
        return .under
    }

    static func remainingCents(spentCents: Int, limitCents: Int) -> Int {
        limitCents - spentCents
    }

    /// Ring fill fraction, clamped to [0, 1].
    static func progress(spentCents: Int, limitCents: Int) -> Double {
        guard limitCents > 0 else { return 0 }
        return min(1.0, max(0.0, Double(spentCents) / Double(limitCents)))
    }

    static func dollars(_ cents: Int) -> String {
        let value = Double(cents) / 100.0
        return value.formatted(.currency(code: "USD"))
    }
}
