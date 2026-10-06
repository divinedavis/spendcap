import Foundation

// MARK: - Debt

// Recurring obligations, itemised and grouped — the Debt tab.
//
// The budget's single "Debts" line says whether the month went wrong; this says
// what is being paid, to whom, and what each bucket adds up to. Every figure on
// the screen is derived here rather than in the view so the subtotals, the
// grand total and the tests all read the same code.

/// One row of `debt_summary()`. A group the user made but has not filled comes
/// back with `itemId` nil, so an empty bucket still renders as itself rather
/// than vanishing.
struct DebtSummaryRow: Codable, Identifiable, Equatable {
    let groupId: UUID
    let groupName: String
    let groupSort: Int
    let itemId: UUID?
    let itemName: String?
    let note: String?
    let plannedCents: Int
    let paidCents: Int
    let txnCount: Int
    let matchValue: String?
    let matchAmountCents: Int?
    let itemSort: Int
    /// The median of the three full months before the viewed one, zeros
    /// included (0031). Nil from a server that predates it.
    let typicalCents: Int?
    /// How many of those three months charged at all.
    let monthsSeen: Int

    var id: String { itemId?.uuidString ?? "empty-\(groupId.uuidString)" }

    /// True when the monthly figure comes from the item's own charges rather
    /// than what was typed. A tracked row with any charge in the last three
    /// full months is measured; one with none — a bill added today, or one
    /// paid outside the linked account — still needs the typed number.
    var isAutoAmount: Bool { isTracked && monthsSeen > 0 && typicalCents != nil }

    /// What this obligation costs a month, as every total on the tab reads it.
    /// The typed plan was the weakest number on the screen — 17 of the owner's
    /// tracked rows sat at $0 while charging monthly — so the charges decide
    /// wherever there are charges to decide from.
    var monthlyCents: Int { isAutoAmount ? (typicalCents ?? plannedCents) : plannedCents }
    var isPlaceholder: Bool { itemId == nil }

    /// Nil means this obligation is not visible in the linked account at all —
    /// no match string, so "$0 paid" would be a claim the data cannot support.
    /// The screen says "not tracked" instead.
    var isTracked: Bool { matchValue?.isEmpty == false }

    enum CodingKeys: String, CodingKey {
        case note
        case groupId = "group_id"
        case groupName = "group_name"
        case groupSort = "group_sort"
        case itemId = "item_id"
        case itemName = "item_name"
        case plannedCents = "planned_cents"
        case paidCents = "paid_cents"
        case txnCount = "txn_count"
        case matchValue = "match_value"
        case matchAmountCents = "match_amount_cents"
        case itemSort = "item_sort"
        case typicalCents = "typical_cents"
        case monthsSeen = "months_seen"
    }

    init(groupId: UUID, groupName: String, groupSort: Int,
         itemId: UUID?, itemName: String?, note: String? = nil,
         plannedCents: Int = 0, paidCents: Int = 0, txnCount: Int = 0,
         matchValue: String? = nil, matchAmountCents: Int? = nil,
         itemSort: Int = 0, typicalCents: Int? = nil, monthsSeen: Int = 0) {
        self.typicalCents = typicalCents
        self.monthsSeen = monthsSeen
        self.groupId = groupId
        self.groupName = groupName
        self.groupSort = groupSort
        self.itemId = itemId
        self.itemName = itemName
        self.note = note
        self.plannedCents = plannedCents
        self.paidCents = paidCents
        self.txnCount = txnCount
        self.matchValue = matchValue
        self.matchAmountCents = matchAmountCents
        self.itemSort = itemSort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupId = try c.decode(UUID.self, forKey: .groupId)
        groupName = try c.decode(String.self, forKey: .groupName)
        groupSort = try c.decodeIfPresent(Int.self, forKey: .groupSort) ?? 0
        itemId = try c.decodeIfPresent(UUID.self, forKey: .itemId)
        itemName = try c.decodeIfPresent(String.self, forKey: .itemName)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        plannedCents = try c.decodeIfPresent(Int.self, forKey: .plannedCents) ?? 0
        // Postgres bigint can arrive as a JSON number or a string depending on
        // the aggregate — the same defensive read CategoryTransaction uses.
        if let value = try? c.decode(Int.self, forKey: .paidCents) {
            paidCents = value
        } else if let text = try? c.decode(String.self, forKey: .paidCents), let value = Int(text) {
            paidCents = value
        } else {
            paidCents = 0
        }
        txnCount = try c.decodeIfPresent(Int.self, forKey: .txnCount) ?? 0
        matchValue = try c.decodeIfPresent(String.self, forKey: .matchValue)
        matchAmountCents = try c.decodeIfPresent(Int.self, forKey: .matchAmountCents)
        itemSort = try c.decodeIfPresent(Int.self, forKey: .itemSort) ?? 0
        // bigint again: number or string depending on the aggregate.
        if let value = try? c.decode(Int.self, forKey: .typicalCents) {
            typicalCents = value
        } else if let text = try? c.decode(String.self, forKey: .typicalCents), let value = Int(text) {
            typicalCents = value
        } else {
            typicalCents = nil
        }
        monthsSeen = try c.decodeIfPresent(Int.self, forKey: .monthsSeen) ?? 0
    }
}

/// Every row a company owns, collected under one heading.
///
/// Divine's list carries "Google · youtube tv" and "Google · workspace" as
/// separate obligations — they are separate obligations, at different prices,
/// and 0025 deliberately allows the repeated name. But reading them as two
/// unrelated rows twelve pixels apart is what the screenshot showed: the
/// company said twice, and no answer anywhere to "what am I paying Google".
/// The items stay whole; only their presentation nests.
struct DebtVendorSummary: Identifiable, Equatable {
    /// Case- and punctuation-insensitive, so "Digital Ocean" and
    /// "DigitalOcean" are one company rather than two.
    let key: String
    /// The parent company when one is recognised ("Google" over "YouTube TV"),
    /// otherwise the company as the user wrote it on the first of its rows.
    let name: String
    let items: [DebtSummaryRow]

    var id: String { key }

    /// One row is a company too — the nesting appears only when it earns its
    /// keep, so a single-item vendor renders exactly as it always did.
    var isMulti: Bool { items.count > 1 }

    var plannedCents: Int { items.reduce(0) { $0 + $1.monthlyCents } }
    var paidCents: Int { items.filter(\.isTracked).reduce(0) { $0 + $1.paidCents } }
    var txnCount: Int { items.filter(\.isTracked).reduce(0) { $0 + $1.txnCount } }
    var hasTrackedItems: Bool { items.contains(where: \.isTracked) }

    /// Which items can be asked for their charges. An untracked row has no
    /// match string, so there is nothing to look up for it.
    var trackedItemIds: [UUID] { items.filter(\.isTracked).compactMap(\.itemId) }
}

/// One bucket — "Subscriptions" — with its items and its own subtotals.
struct DebtGroupSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let sortOrder: Int
    let items: [DebtSummaryRow]

    /// The number on the right of the screenshot: the sum of the items, always
    /// — each at its measured monthly figure where it has one (`monthlyCents`).
    /// Divine's sheet had two buckets whose written total disagreed with its
    /// own rows ($500 for $498 of items, $350 for $1,350); deriving it means
    /// the screen cannot drift from what is in it.
    var plannedCents: Int { items.reduce(0) { $0 + $1.monthlyCents } }

    /// Only tracked items contribute. An untracked one has no evidence either
    /// way, and adding its zero would read as "not paid yet".
    var paidCents: Int { items.filter(\.isTracked).reduce(0) { $0 + $1.paidCents } }
    var trackedPlannedCents: Int { items.filter(\.isTracked).reduce(0) { $0 + $1.monthlyCents } }
    var hasTrackedItems: Bool { items.contains(where: \.isTracked) }
    var isEmpty: Bool { items.isEmpty }

    /// What the screen actually draws: the same items, collected by company.
    /// Derived rather than stored so it cannot fall out of step with `items`,
    /// which is what every subtotal on the card is summing.
    var vendors: [DebtVendorSummary] { DebtMath.vendors(items) }
}

/// The whole screen: every group, plus the totals across all of them.
struct DebtSummary: Equatable {
    let groups: [DebtGroupSummary]

    var plannedCents: Int { groups.reduce(0) { $0 + $1.plannedCents } }
    var paidCents: Int { groups.reduce(0) { $0 + $1.paidCents } }
    var trackedPlannedCents: Int { groups.reduce(0) { $0 + $1.trackedPlannedCents } }
    var hasTrackedItems: Bool { groups.contains(where: \.hasTrackedItems) }
    var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    var isEmpty: Bool { groups.isEmpty }

    /// What is still expected out of the tracked obligations this month.
    /// Clamped at zero: an overpaid item does not create room somewhere else.
    var outstandingCents: Int { max(0, trackedPlannedCents - paidCents) }

    static let empty = DebtSummary(groups: [])
}

enum DebtMath {
    /// Fold the flat rollup into groups, keeping the user's order and dropping
    /// the placeholder row that only existed to carry an empty group's name.
    static func summary(rows: [DebtSummaryRow]) -> DebtSummary {
        var order: [UUID] = []
        var byGroup: [UUID: [DebtSummaryRow]] = [:]
        var names: [UUID: (String, Int)] = [:]

        for row in rows {
            if names[row.groupId] == nil {
                names[row.groupId] = (row.groupName, row.groupSort)
                order.append(row.groupId)
            }
            guard !row.isPlaceholder else { continue }
            byGroup[row.groupId, default: []].append(row)
        }

        let groups = order.compactMap { id -> DebtGroupSummary? in
            guard let (name, sort) = names[id] else { return nil }
            let items = (byGroup[id] ?? []).sorted {
                $0.itemSort == $1.itemSort
                    ? (($0.itemName ?? "") < ($1.itemName ?? ""))
                    : $0.itemSort < $1.itemSort
            }
            return DebtGroupSummary(id: id, name: name, sortOrder: sort, items: items)
        }
        .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }

        return DebtSummary(groups: groups)
    }

    /// Collect a group's items by the company they are paid to, keeping the
    /// user's arrangement: a company sits where its first item sat, and its
    /// products stay in the order they were listed. Grouping must never
    /// reorder the list under someone who spent time arranging it.
    static func vendors(_ items: [DebtSummaryRow]) -> [DebtVendorSummary] {
        var order: [String] = []
        var byKey: [String: [DebtSummaryRow]] = [:]
        var labels: [String: String] = [:]

        for item in items {
            let name = item.itemName ?? "—"
            let parent = Self.company(for: item)
            let key = vendorKey(parent ?? name, fallback: item.id)
            if byKey[key] == nil {
                order.append(key)
                labels[key] = parent ?? name
            }
            byKey[key, default: []].append(item)
        }

        return order.map { key in
            DebtVendorSummary(key: key, name: labels[key] ?? "—", items: byKey[key] ?? [])
        }
    }

    /// The parent company a product is paid to, when it is not the name on the
    /// row. "YouTube TV", "Google Workspace" and "Google Cloud" are all Google
    /// money, and the owner asked for them to collect under Google without
    /// having to type "Google" into each one. Read from the item's name first,
    /// then from the text it matches on (a row named "Haircut" that matches
    /// APPLE CASH is still paid through Apple).
    ///
    /// Matched on whole words, so "pineapple" is not Apple and "Metamucil" is
    /// not Meta. Nil means "no known parent" and the row groups by its own
    /// name, as before.
    static func company(for item: DebtSummaryRow) -> String? {
        for text in [item.itemName, item.matchValue].compactMap({ $0 }) {
            if let parent = company(named: text) { return parent }
        }
        return nil
    }

    static func company(named text: String) -> String? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        // Every run of whole words, joined, so "SP+AFF" and "Digital Ocean"
        // compare as "spaff" and "digitalocean".
        var runs = Set<String>()
        for start in words.indices {
            var joined = ""
            for word in words[start...] {
                joined += word
                runs.insert(joined)
            }
        }
        return companyAliases.first { _, aliases in
            aliases.contains(where: runs.contains)
        }?.0
    }

    /// Brands whose products bill under their own names, as casefolded runs
    /// of whole words.
    static let companyAliases: [(String, [String])] = [
        ("Google", ["google", "youtube", "gsuite"]),
        ("Apple", ["apple", "icloud", "itunes"]),
        ("Amazon", ["amazon", "amzn", "primevideo", "audible", "aws", "kindle"]),
        ("Microsoft", ["microsoft", "xbox", "msft", "github", "linkedin"]),
        ("Sony", ["playstation", "sony"]),
        ("Meta", ["facebook", "instagram", "meta", "whatsapp"]),
        ("Disney", ["disney", "hulu", "espn"]),
        ("Warner Bros.", ["hbo", "hbomax", "warnerbros"]),
        ("Anthropic", ["anthropic", "claude"]),
        ("OpenAI", ["openai", "chatgpt"]),
        ("Affirm", ["affirm", "spaff"]),
        ("PayPal", ["paypal", "venmo", "pypl"]),
        ("Block", ["cashapp", "squareup", "afterpay"]),
        ("Digital Ocean", ["digitalocean"]),
    ]

    /// Casefolded, stripped of spaces and punctuation. A name that survives
    /// none of that — an emoji-only row — keeps its own identity rather than
    /// merging with every other unnameable row into one bogus company.
    static func vendorKey(_ name: String, fallback: String) -> String {
        let folded = name.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return folded.isEmpty ? "unnamed-\(fallback)" : folded
    }
}

/// One charge behind a debt row, with the item that claimed it.
///
/// The item id is carried because the company sheet lists several products'
/// charges together, and a $30 Google debit means nothing until it says which
/// Google it was.
struct DebtCharge: Codable, Identifiable, Equatable {
    let itemId: UUID
    let transaction: CategoryTransaction

    var id: UUID { transaction.id }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
    }

    init(from decoder: Decoder) throws {
        transaction = try CategoryTransaction(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decode(UUID.self, forKey: .itemId)
    }

    init(itemId: UUID, transaction: CategoryTransaction) {
        self.itemId = itemId
        self.transaction = transaction
    }

    func encode(to encoder: Encoder) throws {
        try transaction.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(itemId, forKey: .itemId)
    }
}

/// How far back the charge sheet is looking. This month is the window the row
/// that opened it describes; the longer one answers the different question a
/// row sitting at zero raises — has this ever charged, and when did it stop.
enum DebtChargeWindow: Int, CaseIterable, Identifiable {
    case thisMonth = 1
    case sixMonths = 6

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .thisMonth: return "This month"
        case .sixMonths: return "6 months"
        }
    }
}

/// Which month the Debt tab is reading. Two, not a picker of twelve: the
/// question is "did last month's bills all go out", and Months already owns
/// the year.
enum DebtMonth: Int, CaseIterable, Identifiable {
    case current = 0
    case previous = 1

    var id: Int { rawValue }

    /// The first day of the month this reads, in the device's calendar. The
    /// walk is by month start, never `now - 1 month`, which clamps on the 31st.
    func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        guard self == .previous else { return thisMonth }
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: thisMonth) ?? thisMonth
        return calendar.dateInterval(of: .month, for: dayBefore)?.start ?? dayBefore
    }

    /// "This month" / "September".
    func label(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard self == .previous else { return "This month" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter.string(from: start(now: now, calendar: calendar))
    }
}

/// A bucket as stored — what the group editor reads and writes.
struct DebtGroup: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortOrder = "sort_order"
    }
}

/// An obligation as stored — what the item editor reads and writes.
struct DebtItem: Codable, Identifiable, Equatable {
    let id: UUID
    var groupId: UUID
    var name: String
    var note: String?
    var plannedCents: Int
    var matchValue: String?
    var matchAmountCents: Int?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, note
        case groupId = "group_id"
        case plannedCents = "planned_cents"
        case matchValue = "match_value"
        case matchAmountCents = "match_amount_cents"
        case sortOrder = "sort_order"
    }
}
