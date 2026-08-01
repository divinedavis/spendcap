import Foundation
import Supabase

struct LinkTokenResponse: Codable {
    let linkToken: String
    enum CodingKeys: String, CodingKey { case linkToken = "link_token" }
}

struct ExchangeRequest: Codable {
    let publicToken: String
    let institutionName: String?
    enum CodingKeys: String, CodingKey {
        case publicToken = "public_token"
        case institutionName = "institution_name"
    }
}

/// All reads go straight to Postgres (RLS-scoped to the signed-in user);
/// anything involving Plaid goes through the edge functions.
final class SpendService {
    static let shared = SpendService()
    private let client = SupabaseManager.shared.client

    private init() {}

    // MARK: - Reads

    func todayTransactions() async throws -> [BankTransaction] {
        let today = Self.localDateString()
        return try await client
            .from("transactions")
            .select("id, date, name, merchant_name, category, amount_cents, pending, is_removed")
            .eq("date", value: today)
            .eq("is_removed", value: false)
            .order("amount_cents", ascending: false)
            .execute()
            .value
    }

    func recentTransactions(limit: Int = 100) async throws -> [BankTransaction] {
        try await client
            .from("transactions")
            .select("id, date, name, merchant_name, category, amount_cents, pending, is_removed")
            .eq("is_removed", value: false)
            .order("date", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Every transaction in the calendar month containing `now`, oldest first —
    /// the series the Trends chart and breakdown are built from.
    func monthTransactions(now: Date = Date(), timeZone: TimeZone = .current) async throws -> [BankTransaction] {
        let (start, end) = Self.monthBounds(now: now, timeZone: timeZone)
        return try await client
            .from("transactions")
            .select("id, date, name, merchant_name, category, amount_cents, pending, is_removed")
            .gte("date", value: Self.localDateString(now: start, timeZone: timeZone))
            .lte("date", value: Self.localDateString(now: end, timeZone: timeZone))
            .eq("is_removed", value: false)
            .order("date", ascending: true)
            .execute()
            .value
    }

    func budget() async throws -> Budget {
        try await client
            .from("budgets")
            .select("daily_limit_cents, warn_pct")
            .single()
            .execute()
            .value
    }

    func plaidItems() async throws -> [PlaidItem] {
        try await client
            .from("plaid_items")
            .select("id, institution_name, status, last_synced_at")
            .execute()
            .value
    }

    // MARK: - Writes

    func updateBudget(_ budget: Budget) async throws {
        guard let userId = client.auth.currentUser?.id else { return }
        try await client
            .from("budgets")
            .upsert([
                "user_id": AnyJSON.string(userId.uuidString.lowercased()),
                "daily_limit_cents": AnyJSON.integer(budget.dailyLimitCents),
                "warn_pct": AnyJSON.integer(budget.warnPct),
                "updated_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
            ])
            .execute()
    }

    /// Disconnecting deletes the item row; plaid_item_secrets, accounts, and
    /// transactions all cascade server-side.
    func disconnectItem(_ id: UUID) async throws {
        try await client
            .from("plaid_items")
            .delete()
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    // MARK: - Plaid edge functions

    func createLinkToken() async throws -> String {
        let response: LinkTokenResponse = try await client.functions
            .invoke("plaid_create_link_token")
        return response.linkToken
    }

    func exchangePublicToken(_ publicToken: String, institutionName: String?) async throws {
        let body = ExchangeRequest(publicToken: publicToken, institutionName: institutionName)
        _ = try await client.functions.invoke(
            "plaid_exchange_public_token",
            options: FunctionInvokeOptions(body: body)
        ) as ExchangeAck
    }

    struct ExchangeAck: Codable {
        let ok: Bool
        let accounts: Int?
    }

    // MARK: - Statements

    /// Statements for the past year, newest first.
    func statements() async throws -> [BankStatement] {
        try await client
            .from("statements")
            .select("id, year, month, storage_path, byte_size")
            .order("year", ascending: false)
            .order("month", ascending: false)
            .execute()
            .value
    }

    /// Link token for the *additional consent* flow — re-opens Link against the
    /// bank the user already connected to add the statements product. Does not
    /// create a second connection.
    func createStatementsConsentToken() async throws -> String {
        let response: LinkTokenResponse = try await client.functions
            .invoke("plaid_create_update_link_token")
        return response.linkToken
    }

    /// Pulls statements from Plaid into Storage. Throws `.consentRequired` when
    /// the user has not been through the consent flow yet, which the UI turns
    /// into a prompt instead of an error.
    @discardableResult
    func syncStatements() async throws -> StatementSyncAck {
        do {
            return try await client.functions.invoke("plaid_statements_sync") as StatementSyncAck
        } catch let error as FunctionsError {
            if case .httpError(let code, _) = error, code == 409 {
                throw StatementsError.consentRequired
            }
            throw error
        }
    }

    struct StatementSyncAck: Codable {
        let ok: Bool
        let found: Int
        let downloaded: Int
        let skipped: Int
        let capped: Bool
    }

    enum StatementsError: LocalizedError {
        case consentRequired

        var errorDescription: String? {
            switch self {
            case .consentRequired:
                return "Your bank needs to approve access to statements."
            }
        }
    }

    /// Short-lived signed URL for one statement PDF. The bucket is private, so
    /// this is the only way to read a file — and the link expires, so it can't
    /// be forwarded around.
    func statementURL(_ statement: BankStatement, expiresIn: Int = 300) async throws -> URL {
        guard let path = statement.storagePath else {
            throw StatementsError.consentRequired
        }
        return try await client.storage
            .from("statements")
            .createSignedURL(path: path, expiresIn: expiresIn)
    }

    // MARK: - Helpers

    /// Today's date in the device's local timezone, matching the server-side
    /// (now() at time zone profiles.timezone)::date computation.
    static func localDateString(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: now)
    }

    /// First and last instant-bearing days of the calendar month containing
    /// `now`, in the given timezone. Falls back to `now` for both if the
    /// calendar can't resolve the interval (it always can for Gregorian).
    static func monthBounds(now: Date = Date(), timeZone: TimeZone = .current) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return (now, now) }
        // dateInterval's end is the first instant of the next month; step back a
        // day so the inclusive `lte` query doesn't pull in the 1st.
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? now
        return (interval.start, lastDay)
    }

    /// Keep the server-side timezone in sync with the device so "today" and
    /// alert boundaries match what the user sees.
    func syncTimezone() async {
        guard let userId = client.auth.currentUser?.id else { return }
        _ = try? await client
            .from("profiles")
            .upsert([
                "user_id": AnyJSON.string(userId.uuidString.lowercased()),
                "timezone": AnyJSON.string(TimeZone.current.identifier),
            ])
            .execute()
    }
}
