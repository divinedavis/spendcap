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

    /// Lowercased UUID of the signed-in user, from the locally stored session
    /// — synchronous on purpose, so first-frame code (the Trends snapshot
    /// check) can use it without waiting on a network round trip.
    var currentUserId: String? {
        client.auth.currentSession?.user.id.uuidString.lowercased()
    }

    // MARK: - Reads

    func todayTransactions() async throws -> [BankTransaction] {
        let today = Self.localDateString()
        return try await client
            .from("transactions")
            .select("id, date, name, merchant_name, category, amount_cents, pending, is_removed, is_backfill")
            .eq("date", value: today)
            .eq("is_removed", value: false)
            .order("amount_cents", ascending: false)
            .execute()
            .value
    }

    func recentTransactions(limit: Int = 100) async throws -> [BankTransaction] {
        try await client
            .from("transactions")
            .select("id, date, name, merchant_name, category, amount_cents, pending, is_removed, is_backfill")
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
            .select("id, date, name, merchant_name, category, amount_cents, pending, is_removed, is_backfill")
            .gte("date", value: Self.localDateString(now: start, timeZone: timeZone))
            .lte("date", value: Self.localDateString(now: end, timeZone: timeZone))
            .eq("is_removed", value: false)
            .order("date", ascending: true)
            .execute()
            .value
    }

    /// Monthly outflow totals for the last `monthsBack` calendar months, oldest
    /// first, one row per month whether or not it has activity.
    ///
    /// Aggregated in Postgres (`monthly_spend()`): a year of transactions is
    /// thousands of rows, past PostgREST's 1000-row default cap, and the client
    /// only ever needs the twelve sums.
    func monthlySpend(monthsBack: Int = 12) async throws -> [MonthlySpendRow] {
        try await client
            .rpc("monthly_spend", params: ["months_back": monthsBack])
            .execute()
            .value
    }

    /// Checking balance at the start and end of each month, derived in
    /// Postgres (`monthly_balances()`) from the current balance and posted
    /// transactions. Empty when no checking account is on record.
    func monthlyBalances(monthsBack: Int = 12) async throws -> [MonthlyBalanceRow] {
        try await client
            .rpc("monthly_balances", params: ["months_back": monthsBack])
            .execute()
            .value
    }

    // MARK: - Category budgets

    /// Planned vs actual per category for the last `monthsBack` months, newest
    /// month first, including an Uncategorized line per month.
    func categorySpend(monthsBack: Int = 2) async throws -> [CategorySpendRow] {
        try await client
            .rpc("category_spend", params: ["months_back": monthsBack])
            .execute()
            .value
    }

    /// Discretionary outflow day by day for one month — the input to the
    /// weekly buckets on Trends. Only days with spending come back, so an
    /// empty result is a month with no discretionary spending yet, not a
    /// failure. Summing it equals `category_spend`'s discretionary total for
    /// the same month; `WeekMath` relies on that to keep the weekly card and
    /// the budget card describing the same money.
    func discretionaryDaily(period: Date = Date()) async throws -> [DiscretionaryDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.dateInterval(of: .month, for: period)?.start ?? period
        return try await client
            .rpc("discretionary_daily", params: ["period": Self.localDateString(now: start)])
            .execute()
            .value
    }

    /// Every transaction that landed in one category in one month. Pass a nil
    /// id for the Uncategorized line.
    func categoryTransactions(categoryId: UUID?, period: Date) async throws -> [CategoryTransaction] {
        try await client
            .rpc("category_transactions", params: [
                "category": categoryId.map { AnyJSON.string($0.uuidString.lowercased()) } ?? AnyJSON.null,
                "period": AnyJSON.string(Self.localDateString(now: period)),
            ])
            .execute()
            .value
    }

    /// Every transaction in a month, newest first, with its budget line.
    /// Includes money in, which the budget rollups exclude.
    func monthActivity(period: Date = Date()) async throws -> [ActivityRow] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.dateInterval(of: .month, for: period)?.start ?? period
        return try await client
            .rpc("month_activity", params: ["period": Self.localDateString(now: start)])
            .execute()
            .value
    }

    /// Creates the starter set of lines. Server-side no-op once any category
    /// exists, so a double tap can't duplicate the budget.
    @discardableResult
    func seedStarterBudget() async throws -> Int {
        try await client.rpc("seed_starter_budget").execute().value
    }

    func categories() async throws -> [BudgetCategory] {
        try await client
            .from("budget_categories")
            .select("id, name, planned_cents, sort_order, kind")
            .order("sort_order", ascending: true)
            .execute()
            .value
    }

    /// Route every transaction from a merchant into a category, from now on and
    /// retroactively — the rollups apply rules at read time, so past months
    /// re-bucket too. Upsert on the match value: one merchant, one home.
    func assignMerchant(_ merchant: String, to categoryId: UUID) async throws {
        guard let userId = client.auth.currentUser?.id else { return }
        try await client
            .from("category_rules")
            .upsert([
                "user_id": AnyJSON.string(userId.uuidString.lowercased()),
                "category_id": AnyJSON.string(categoryId.uuidString.lowercased()),
                "match_type": AnyJSON.string("merchant_contains"),
                "match_value": AnyJSON.string(merchant),
            ], onConflict: "user_id,match_type,match_value")
            .execute()
    }

    /// Drop a merchant rule, letting the transaction fall back to whatever its
    /// Plaid category maps to — or to Uncategorized.
    func clearMerchantRule(_ merchant: String) async throws {
        try await client
            .from("category_rules")
            .delete()
            .eq("match_type", value: "merchant_contains")
            .eq("match_value", value: merchant)
            .execute()
    }

    /// The merchant rule currently claiming this exact name, if any.
    func merchantRule(_ merchant: String) async throws -> CategoryRule? {
        let rules: [CategoryRule] = try await client
            .from("category_rules")
            .select("id, category_id, match_type, match_value")
            .eq("match_type", value: "merchant_contains")
            .eq("match_value", value: merchant)
            .limit(1)
            .execute()
            .value
        return rules.first
    }

    /// Adds a line at the end of the budget. Sort order is max + 1 so a new
    /// line does not jump into the middle of an order the user arranged.
    func createCategory(name: String, plannedCents: Int) async throws {
        guard let userId = client.auth.currentUser?.id else { return }
        let existing = try await categories()
        let nextOrder = (existing.map(\.sortOrder).max() ?? 0) + 1
        try await client
            .from("budget_categories")
            .insert([
                "user_id": AnyJSON.string(userId.uuidString.lowercased()),
                "name": AnyJSON.string(name),
                "planned_cents": AnyJSON.integer(plannedCents),
                "sort_order": AnyJSON.integer(nextOrder),
            ])
            .execute()
    }

    /// Removes a line. Its rules cascade, and the transactions it claimed are
    /// then matched against every *remaining* rule — so they land in
    /// Uncategorized only if nothing else claims them. Verified against live
    /// data: deleting a line whose transactions also matched a broad `Apple`
    /// merchant rule on another line sent them there, not to Uncategorized.
    /// Nothing is deleted from the transactions themselves.
    func deleteCategory(id: UUID) async throws {
        try await client
            .from("budget_categories")
            .delete()
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    func updateCategory(id: UUID, name: String, plannedCents: Int, kind: CategoryKind?) async throws {
        try await client
            .from("budget_categories")
            .update([
                "name": AnyJSON.string(name),
                "planned_cents": AnyJSON.integer(plannedCents),
                // Explicit null clears the tag — "no kind" is a choice the
                // sheet can save, not just an absence.
                "kind": kind.map { AnyJSON.string($0.rawValue) } ?? AnyJSON.null,
                "updated_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
            ])
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    func budget() async throws -> Budget {
        try await client
            .from("budgets")
            .select("daily_limit_cents, warn_pct, monthly_limit_cents")
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
                // Explicit null clears a monthly cap back to the derived one —
                // omitting the key would silently keep the old value on upsert.
                "monthly_limit_cents": budget.monthlyLimitCents.map(AnyJSON.integer) ?? AnyJSON.null,
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
            // The account is not decoration: a bank with a checking and a
            // savings account issues one statement each per month, and two
            // rows labelled "July 2026" with nothing to tell them apart read
            // as a duplication bug.
            .select("id, year, month, storage_path, byte_size, accounts(name, mask)")
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

    /// Removes every statement PDF this user owns, and reports how many went.
    ///
    /// Account deletion has to do this from the client. `storage.objects` does
    /// not cascade from `auth.users`, and it cannot be cleaned up in SQL
    /// either: Supabase guards the table with a BEFORE DELETE trigger that
    /// raises 42501 on any direct delete, which is what silently broke
    /// `delete_account()` for every build between 0003 and 0014 — the RPC threw
    /// and rolled back, so no account was ever deleted. The Storage API is the
    /// only supported route.
    ///
    /// Listing the bucket rather than reading `statements.storage_path` is
    /// deliberate: a failed download leaves a row with a null path, and a row
    /// could be missing for a file that exists. The bucket is the thing we are
    /// promising to empty, so the bucket is what gets enumerated.
    @discardableResult
    func deleteStoredStatements() async throws -> Int {
        guard let uid = client.auth.currentSession?.user.id.uuidString.lowercased() else {
            throw TripError.notSignedIn
        }
        // Objects live at "<uid>/<plaid_statement_id>.pdf"; the RLS policy
        // matches on that first path segment, so list and remove both scope
        // themselves to this user without us filtering.
        let files = try await client.storage.from("statements").list(path: uid)
        let paths = files.map { "\(uid)/\($0.name)" }
        guard !paths.isEmpty else { return 0 }
        _ = try await client.storage.from("statements").remove(paths: paths)
        return paths.count
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

    // MARK: - Trips

    enum TripError: LocalizedError {
        case notSignedIn
        case notCreated

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "You need to be signed in to change a trip."
            case .notCreated:
                return "The trip couldn't be created. Try again."
            }
        }
    }

    func trips() async throws -> [TripTotals] {
        try await client.rpc("trip_totals").execute().value
    }

    func tripLines(tripId: UUID) async throws -> [TripLineSpend] {
        try await client
            .rpc("trip_line_spend", params: ["trip": tripId.uuidString.lowercased()])
            .execute()
            .value
    }

    /// Transactions inside a trip's dates that no trip has claimed. Suggestions
    /// only — nothing is assigned until the user taps.
    func tripCandidates(tripId: UUID, limit: Int = 200) async throws -> [TripTransaction] {
        try await client
            .rpc("trip_candidates", params: [
                "trip": AnyJSON.string(tripId.uuidString.lowercased()),
                "max_rows": AnyJSON.integer(limit),
            ])
            .execute()
            .value
    }

    func tripAssigned(tripId: UUID) async throws -> [TripTransaction] {
        try await client
            .rpc("trip_assigned", params: ["trip": tripId.uuidString.lowercased()])
            .execute()
            .value
    }

    @discardableResult
    func createTrip(name: String, kind: TripKind, startsOn: String?, endsOn: String?,
                    budgetCents: Int?) async throws -> Trip {
        guard let userId = client.auth.currentUser?.id else { throw TripError.notSignedIn }
        var payload: [String: AnyJSON] = [
            "user_id": .string(userId.uuidString.lowercased()),
            "name": .string(name),
            "kind": .string(kind.rawValue),
        ]
        payload["starts_on"] = startsOn.map { AnyJSON.string($0) } ?? .null
        payload["ends_on"] = endsOn.map { AnyJSON.string($0) } ?? .null
        payload["budget_cents"] = budgetCents.map { AnyJSON.integer($0) } ?? .null
        let rows: [Trip] = try await client
            .from("trips")
            .insert(payload)
            .select("id, name, kind, starts_on, ends_on, budget_cents")
            .execute()
            .value
        guard let trip = rows.first else { throw TripError.notCreated }
        return trip
    }

    func updateTrip(_ trip: Trip) async throws {
        var payload: [String: AnyJSON] = [
            "name": .string(trip.name),
            "kind": .string(trip.kind.rawValue),
        ]
        payload["starts_on"] = trip.startsOn.map { AnyJSON.string($0) } ?? .null
        payload["ends_on"] = trip.endsOn.map { AnyJSON.string($0) } ?? .null
        payload["budget_cents"] = trip.budgetCents.map { AnyJSON.integer($0) } ?? .null
        try await client
            .from("trips")
            .update(payload)
            .eq("id", value: trip.id.uuidString.lowercased())
            .execute()
    }

    /// Deletes the trip, its lines, and its assignments. The transactions
    /// themselves are untouched — they go back to counting against the daily
    /// cap, which is where they were before the trip claimed them.
    func deleteTrip(id: UUID) async throws {
        try await client
            .from("trips")
            .delete()
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    func addTripLine(tripId: UUID, name: String, symbol: String?,
                     plannedCents: Int, occursOn: String?) async throws {
        guard let userId = client.auth.currentUser?.id else { throw TripError.notSignedIn }
        let existing = try await tripLines(tripId: tripId)
        let nextOrder = (existing.filter { !$0.isUnfiled }.map(\.sortOrder).max() ?? 0) + 1
        var payload: [String: AnyJSON] = [
            "trip_id": .string(tripId.uuidString.lowercased()),
            "user_id": .string(userId.uuidString.lowercased()),
            "name": .string(name),
            "planned_cents": .integer(plannedCents),
            "sort_order": .integer(nextOrder),
        ]
        payload["symbol"] = symbol.map { AnyJSON.string($0) } ?? .null
        payload["occurs_on"] = occursOn.map { AnyJSON.string($0) } ?? .null
        try await client.from("trip_lines").insert(payload).execute()
    }

    func updateTripLine(id: UUID, name: String, symbol: String?,
                        plannedCents: Int, occursOn: String?) async throws {
        var payload: [String: AnyJSON] = [
            "name": .string(name),
            "planned_cents": .integer(plannedCents),
        ]
        payload["symbol"] = symbol.map { AnyJSON.string($0) } ?? .null
        payload["occurs_on"] = occursOn.map { AnyJSON.string($0) } ?? .null
        try await client
            .from("trip_lines")
            .update(payload)
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    /// Tick a cost line off as paid or done, or untick it.
    ///
    /// This records an assertion, not a payment: plenty of a trip gets paid on
    /// a card the app can't see, months ahead, or by someone else. It never
    /// touches a spend total — the trip's spend still means "money we watched
    /// leave the account".
    func setTripLineSettled(id: UUID, settled: Bool) async throws {
        let value: AnyJSON = settled
            ? .string(ISO8601DateFormatter().string(from: Date()))
            : .null
        try await client
            .from("trip_lines")
            .update(["settled_at": value])
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    /// Removing a line does not remove its spending from the trip: the
    /// assignments' `line_id` is nulled by the FK and those transactions land
    /// in the trip's unfiled row. Deleting a plan should never quietly delete
    /// the record of money that was actually spent.
    func deleteTripLine(id: UUID) async throws {
        try await client
            .from("trip_lines")
            .delete()
            .eq("id", value: id.uuidString.lowercased())
            .execute()
    }

    /// Puts a transaction on a trip — which is also what takes it out of the
    /// daily cap. Upserted on the transaction id, so re-assigning moves it
    /// rather than failing or double-counting it.
    func assignTransaction(_ transactionId: UUID, toTrip tripId: UUID, line lineId: UUID?) async throws {
        guard let userId = client.auth.currentUser?.id else { throw TripError.notSignedIn }
        var payload: [String: AnyJSON] = [
            "transaction_id": .string(transactionId.uuidString.lowercased()),
            "trip_id": .string(tripId.uuidString.lowercased()),
            "user_id": .string(userId.uuidString.lowercased()),
        ]
        payload["line_id"] = lineId.map { AnyJSON.string($0.uuidString.lowercased()) } ?? .null
        try await client
            .from("trip_transactions")
            .upsert(payload, onConflict: "transaction_id")
            .execute()
    }

    /// Takes a transaction off its trip. It counts against the daily cap again
    /// from the next `check_overspend` run.
    func unassignTransaction(_ transactionId: UUID) async throws {
        try await client
            .from("trip_transactions")
            .delete()
            .eq("transaction_id", value: transactionId.uuidString.lowercased())
            .execute()
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
