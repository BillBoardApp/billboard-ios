import Foundation

// MARK: - Companion group (APPF-23)

/// Identical bills introduced in both chambers of one Congress (H.R. 900 and S. 456), shown as one
/// bill. The server resolves the groups; every `GET /bills-manifest` response lists all of them
/// (`companionGroups`), and the app keeps the latest list in `BillsManifestCache`.
///
/// Each member keeps its own manifest item and `Bill`: member pages, official votes and deep links
/// stay per bill, and only the surfaces that show "a bill" (Home, search, the digest) collapse a group.
/// The app's copy of `UserAPIContractsV1.CompanionGroup`, which is Decodable only.
nonisolated struct BillCompanionGroup: Codable, Hashable, Sendable {
    /// The House member's plain guid: the card id (`UUID.deterministic(primaryGuid)`), the share guid
    /// and the default vote target. Always `memberGuids[0]`.
    let primaryGuid: String
    /// Plain guids (`BILLS-<congress><type><number>`, no text-version suffix), primary first.
    let memberGuids: [String]
    /// Why the bills are grouped: "identical" today.
    let relationship: String

    /// Trims the guids, puts the primary first and drops repeated members.
    init(primaryGuid: String, memberGuids: [String], relationship: String) {
        let primary = primaryGuid.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = [primary]
        var members = [primary]
        for guid in memberGuids {
            let cleaned = guid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            members.append(cleaned)
        }
        self.primaryGuid = primary
        self.memberGuids = members
        self.relationship = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The contract group, or nil when it is unusable (no primary, or fewer than two distinct members).
    init?(dto: UserAPIContractsV1.CompanionGroup) {
        let group = BillCompanionGroup(primaryGuid: dto.primaryGuid, memberGuids: dto.memberGuids, relationship: dto.relationship)
        guard !group.primaryGuid.isEmpty, group.memberGuids.count >= 2 else { return nil }
        self = group
    }

    /// The members other than the primary, in group order.
    var otherGuids: [String] { Array(memberGuids.dropFirst()) }

    var isIdentical: Bool { relationship.lowercased() == "identical" }

    /// The id of the group's card: the primary's bill id.
    var primaryBillID: UUID { UUID.deterministic(from: primaryGuid) }

    /// Each member's bill id, primary first.
    var memberBillIDs: [UUID] { memberGuids.map { UUID.deterministic(from: $0) } }

    func contains(guid: String) -> Bool {
        guard let plain = CompanionGroupIndex.plainGuid(guid) else { return false }
        return memberGuids.contains(plain)
    }
}

// MARK: - Votes

/// A vote row the user holds on one member of a group ("holding a vote" includes Abstain).
nonisolated struct CompanionVoteRow: Equatable, Sendable {
    /// The member's plain guid.
    let memberGuid: String
    /// The guid the row is stored under: the member guid, or a legacy text-version guid of the same
    /// bill (`BILLS-119hr900is`) for votes cast before the manifest dropped the suffixes.
    let guid: String
    let vote: VoteType
}

/// Votes on two members that differ (cast before the bills were combined, or from another device).
/// Only `counted` counts; `other` stays on the server and is ignored.
nonisolated struct CompanionVoteConflict: Equatable, Sendable {
    let counted: CompanionVoteRow
    let other: CompanionVoteRow
}

/// A group's vote under the vote matrix (design section 5):
///
/// | Situation                    | Which vote counts | Where a new vote or change is written |
/// |------------------------------|-------------------|---------------------------------------|
/// | No vote yet                  | none              | the primary                           |
/// | Vote on the primary only     | primary           | primary                               |
/// | Vote on the other bill only  | other             | other                                 |
/// | Votes on both                | primary           | primary                               |
nonisolated struct CompanionVoteResolution: Equatable, Sendable {
    let group: BillCompanionGroup
    /// The row that counts: the primary's, else the first other member's that has one.
    let countedRow: CompanionVoteRow?
    /// Where a new vote, a change or its reasons go: the counted row's guid, else the primary. Never
    /// more than one member, so no second row appears.
    let targetGuid: String
    /// Set when another member holds a row with a different choice than the counted one.
    let conflict: CompanionVoteConflict?
    /// True when any member holds a counted (Yea or Nay) vote: the group shows as voted.
    let isVoted: Bool

    /// The vote to show for the group (the counted row's), or nil when no member holds one.
    var effectiveVote: VoteType? { countedRow?.vote }
}

// MARK: - Status lead

/// What a group card's status chip shows (display only): the member furthest along.
nonisolated struct CompanionStatusLead: Equatable, Sendable {
    /// The lead member's plain guid.
    let guid: String
    let status: BillStatus
    let isPrimary: Bool
    /// The lead member's official number, e.g. "S. 456".
    let billNumber: String

    /// "Passed" when the primary leads, else the status naming the member: "Passed · S. 456". A
    /// member that became law (Finalized, REL-44) reads "Became law" ("Became law · S. 456").
    var label: String {
        isPrimary ? status.displayLabel : "\(status.displayLabel) · \(billNumber)"
    }
}

// MARK: - Ranking

/// Home ranking values for one card: a single bill's own, or a group's combined.
nonisolated struct CompanionRankValues: Equatable, Sendable {
    /// Any member has an active priority.
    let hasActivePriority: Bool
    /// The lowest active priority rank, `Int.max` when none.
    let prioritySortRank: Int
    /// The latest member's board date (`storedAt`, else when the user voted).
    let sortDate: Date

    /// One bill per member (a group) or a single bill.
    init(bills: [Bill]) {
        hasActivePriority = bills.contains { $0.hasActivePriority }
        prioritySortRank = bills.map(\.prioritySortRank).min() ?? Int.max
        sortDate = bills.map(\.boardSortDate).max() ?? .distantPast
    }

    /// Home order: active priority first, then the lower priority rank, the later date, then `title` and
    /// `guid` (the card bill's); never the vote count (INT-11). Matches `rankBillsForBoard` for single bills.
    static func ranksBefore(
        _ lhs: (values: CompanionRankValues, bill: Bill),
        _ rhs: (values: CompanionRankValues, bill: Bill)
    ) -> Bool {
        if lhs.values.hasActivePriority != rhs.values.hasActivePriority { return lhs.values.hasActivePriority }
        if lhs.values.prioritySortRank != rhs.values.prioritySortRank {
            return lhs.values.prioritySortRank < rhs.values.prioritySortRank
        }
        if lhs.values.sortDate != rhs.values.sortDate { return lhs.values.sortDate > rhs.values.sortDate }
        let lhsTitle = lhs.bill.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTitle = rhs.bill.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleComparison = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return (lhs.bill.guid ?? "") < (rhs.bill.guid ?? "")
    }
}

// MARK: - Index

/// Lookup of companion groups by member guid and by `BillsStore.BillIdentityKey`, so a legacy
/// text-version guid (`BILLS-119s456is`) or a bill with only congress, type and number resolves to its
/// group. Built off the main actor with the manifest (`BillsStore.manifestUpdate`). An empty index
/// (no groups, the feature disabled, or a server that predates it) gives today's behaviour everywhere.
nonisolated struct CompanionGroupIndex: Sendable, Equatable {
    static let empty = CompanionGroupIndex(groups: [])

    /// The groups, sorted by primary guid, each member in at most one group.
    let groups: [BillCompanionGroup]
    private let groupIndexByGuid: [String: Int]
    private let groupIndexByIdentity: [BillsStore.BillIdentityKey: Int]

    init(groups: [BillCompanionGroup]) {
        var kept: [BillCompanionGroup] = []
        var byGuid: [String: Int] = [:]
        var byIdentity: [BillsStore.BillIdentityKey: Int] = [:]
        // A member listed in two groups keeps the first (by primary guid); the server never sends that.
        for group in groups.sorted(by: { $0.primaryGuid < $1.primaryGuid }) {
            let members = group.memberGuids.compactMap(Self.plainGuid)
            guard members.count >= 2, Set(members).count == members.count,
                  members.allSatisfy({ byGuid[$0] == nil }) else { continue }
            let normalized = BillCompanionGroup(primaryGuid: members[0], memberGuids: members, relationship: group.relationship)
            let position = kept.count
            kept.append(normalized)
            for member in members {
                byGuid[member] = position
                if let key = Self.identityKey(forGUID: member) { byIdentity[key] = position }
            }
        }
        self.groups = kept
        self.groupIndexByGuid = byGuid
        self.groupIndexByIdentity = byIdentity
    }

    static func == (lhs: CompanionGroupIndex, rhs: CompanionGroupIndex) -> Bool {
        lhs.groups == rhs.groups
    }

    var isEmpty: Bool { groups.isEmpty }
    var count: Int { groups.count }

    // MARK: Lookup

    /// The group of `guid`, a member's plain guid or a text-version guid of a member (`BILLS-119s456is`).
    func group(forGUID guid: String?) -> BillCompanionGroup? {
        guard !groups.isEmpty, let guid, let plain = Self.plainGuid(guid) else { return nil }
        if let position = groupIndexByGuid[plain] { return groups[position] }
        guard let key = Self.identityKey(forGUID: plain), let position = groupIndexByIdentity[key] else { return nil }
        return groups[position]
    }

    /// The group of the bill with this congress, type (code or slug) and number.
    func group(for key: BillsStore.BillIdentityKey) -> BillCompanionGroup? {
        guard !groups.isEmpty, let position = groupIndexByIdentity[key] else { return nil }
        return groups[position]
    }

    /// The group of `bill`: by its guid, else by its congress, type and number.
    func group(for bill: Bill) -> BillCompanionGroup? {
        guard !groups.isEmpty else { return nil }
        if let group = group(forGUID: bill.guid) { return group }
        guard let key = BillsStore.billIdentityKey(congress: bill.congress, billType: bill.billType, billID: bill.billID) else {
            return nil
        }
        return group(for: key)
    }

    /// The member guid (plain) that `guid` belongs to, or nil when it is in no group.
    func memberGuid(forGUID guid: String?) -> String? {
        guard let group = group(forGUID: guid), let plain = guid.flatMap(Self.plainGuid) else { return nil }
        if group.memberGuids.contains(plain) { return plain }
        let key = Self.identityKey(forGUID: plain)
        return group.memberGuids.first { Self.identityKey(forGUID: $0) == key }
    }

    /// The member guid (plain) of `bill`, or nil when it is in no group.
    func memberGuid(for bill: Bill) -> String? {
        guard let group = group(for: bill) else { return nil }
        if let member = memberGuid(forGUID: bill.guid) { return member }
        let key = BillsStore.billIdentityKey(congress: bill.congress, billType: bill.billType, billID: bill.billID)
        return group.memberGuids.first { Self.identityKey(forGUID: $0) == key }
    }

    /// The key one card stands for: the group's primary guid, else the bill's own plain guid (else its
    /// trimmed guid, else its id). Server dedupe uses the same key (`companionKey`).
    func groupKey(for bill: Bill) -> String {
        if let group = group(for: bill) { return group.primaryGuid }
        if let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            return Self.plainGuid(guid) ?? guid
        }
        return "id:\(bill.id.uuidString)"
    }

    /// The group's primary guid for a grouped `guid`, else `guid` itself (trimmed).
    func groupKey(forGUID guid: String) -> String {
        group(forGUID: guid)?.primaryGuid ?? guid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `guid` is the primary of its group; false when it is another member or in no group.
    func isPrimary(guid: String) -> Bool {
        guard let group = group(forGUID: guid) else { return false }
        return memberGuid(forGUID: guid) == group.primaryGuid
    }

    /// The loaded bills of `group` in group order (primary first), one per member: the bill with the
    /// member's plain guid when loaded, else a legacy text-version bill of it.
    func memberBills(of group: BillCompanionGroup, in bills: [Bill]) -> [Bill] {
        var byMember: [String: Bill] = [:]
        for bill in bills {
            guard let member = memberGuid(for: bill), group.memberGuids.contains(member) else { continue }
            let isPlain = Self.plainGuid(bill.guid ?? "") == bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
            if byMember[member] == nil || isPlain {
                byMember[member] = bill
            }
        }
        return group.memberGuids.compactMap { byMember[$0] }
    }

    /// `bills` with one entry per group, at the position of the group's first bill: the primary's bill
    /// when it is in `bills`, else that first bill. Ungrouped bills pass through. With no groups the
    /// input is returned as it is.
    func collapsed(_ bills: [Bill]) -> [Bill] {
        guard !groups.isEmpty else { return bills }
        var positionByKey: [String: Int] = [:]
        var result: [Bill] = []
        result.reserveCapacity(bills.count)
        for bill in bills {
            guard let group = group(for: bill) else {
                result.append(bill)
                continue
            }
            let isPrimary = memberGuid(for: bill) == group.primaryGuid
            if let position = positionByKey[group.primaryGuid] {
                if isPrimary, memberGuid(for: result[position]) != group.primaryGuid {
                    result[position] = bill
                }
            } else {
                positionByKey[group.primaryGuid] = result.count
                result.append(bill)
            }
        }
        return result
    }

    // MARK: Labels

    /// The official number of a member guid ("H.R. 900"), else the guid itself.
    static func billNumber(forGUID guid: String) -> String {
        BillDisplayFormatting.officialBillNumber(billType: nil, billNumber: nil, guid: guid)
            ?? guid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every member's number, primary first: "H.R. 900 · S. 456".
    static func numbersLabel(for group: BillCompanionGroup) -> String {
        group.memberGuids.map(billNumber(forGUID:)).joined(separator: " · ")
    }

    /// "Bill numbers H.R. 900 and S. 456, identical bills".
    static func accessibilityLabel(for group: BillCompanionGroup) -> String {
        let numbers = group.memberGuids.map(billNumber(forGUID:))
        let list: String
        if numbers.count <= 2 {
            list = numbers.joined(separator: " and ")
        } else {
            list = numbers.dropLast().joined(separator: ", ") + " and " + (numbers.last ?? "")
        }
        return "Bill numbers \(list), \(group.isIdentical ? "identical bills" : "companion bills")"
    }

    // MARK: Status lead

    /// The member with the highest status (Finalized 4 > Passed 3 > Failed 2 > Updated 1 > New or not
    /// loaded 0); ties go to the later `storedAt`, then to the primary. `memberBills` are the loaded
    /// members' bills (any order; legacy text-version bills count for their member).
    func statusLead(for group: BillCompanionGroup, memberBills: [Bill]) -> CompanionStatusLead {
        var best: (guid: String, status: BillStatus, rank: Int, date: Date)?
        for member in group.memberGuids {
            let bills = memberBills.filter { memberGuid(for: $0) == member }
            let candidates = bills.map { bill in
                (status: bill.billStatus, rank: Self.statusRank(bill.billStatus), date: FlexibleISO8601.parse(bill.storedAt) ?? .distantPast)
            }
            let top = candidates.max { lhs, rhs in
                lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.date < rhs.date
            } ?? (status: BillStatus.new, rank: 0, date: Date.distantPast)
            // Strictly greater: an equal status and date keeps the earlier member (the primary first).
            if let current = best, !(top.rank > current.rank || (top.rank == current.rank && top.date > current.date)) {
                continue
            }
            best = (member, top.status, top.rank, top.date)
        }
        let lead = best ?? (group.primaryGuid, .new, 0, .distantPast)
        return CompanionStatusLead(
            guid: lead.guid,
            status: lead.status,
            isPrimary: lead.guid == group.primaryGuid,
            billNumber: Self.billNumber(forGUID: lead.guid)
        )
    }

    nonisolated static func statusRank(_ status: BillStatus) -> Int {
        switch status {
        case .finalized: return 4
        case .passed: return 3
        case .failed: return 2
        case .updated: return 1
        case .new: return 0
        }
    }

    // MARK: Votes

    /// The group's vote under the vote matrix. `heldVote` returns the row the user holds on a member
    /// (by its plain guid), Abstain included, or nil.
    static func voteResolution(
        for group: BillCompanionGroup,
        heldVote: (String) -> CompanionVoteRow?
    ) -> CompanionVoteResolution {
        let rows = group.memberGuids.compactMap(heldVote)
        let counted = rows.first { $0.memberGuid == group.primaryGuid } ?? rows.first
        let conflict = counted.flatMap { counted in
            rows.first { $0.memberGuid != counted.memberGuid && $0.vote != counted.vote }
                .map { CompanionVoteConflict(counted: counted, other: $0) }
        }
        return CompanionVoteResolution(
            group: group,
            countedRow: counted,
            targetGuid: counted?.guid ?? group.primaryGuid,
            conflict: conflict,
            isVoted: rows.contains { $0.vote.countsAsVote }
        )
    }

    // MARK: Rank

    /// The Home rank values of a card: `CompanionRankValues` over one bill per member (a group) or the
    /// bill alone.
    func rankValues(for card: Bill, memberBills: [Bill]) -> CompanionRankValues {
        guard let group = group(for: card) else { return CompanionRankValues(bills: [card]) }
        let members = self.memberBills(of: group, in: memberBills + [card])
        return CompanionRankValues(bills: members.isEmpty ? [card] : members)
    }

    // MARK: Guids

    /// `guid` without its text-version suffix (`BILLS-119hr900is` -> `BILLS-119hr900`), with the prefix
    /// upper-cased and the rest lower-cased; nil when it is not a GovInfo bill guid.
    static func plainGuid(_ guid: String) -> String? {
        guard let parts = guidParts(guid) else { return nil }
        return "BILLS-\(parts.congress)\(parts.billType)\(parts.billNumber)"
    }

    static func identityKey(forGUID guid: String) -> BillsStore.BillIdentityKey? {
        guard let parts = guidParts(guid) else { return nil }
        return BillsStore.billIdentityKey(congress: parts.congress, billType: parts.billType, billID: parts.billNumber)
    }

    /// Splits `BILLS-<congress><type><number><suffix>` without a regular expression (it runs per bill).
    private static func guidParts(_ guid: String) -> (congress: String, billType: String, billNumber: String)? {
        let trimmed = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 6, trimmed.prefix(6).uppercased() == "BILLS-" else { return nil }
        let rest = Array(trimmed.dropFirst(6).lowercased())

        var index = 0
        while index < rest.count, rest[index].isASCII, rest[index].isNumber { index += 1 }
        guard index > 0 else { return nil }
        let congress = String(rest[0..<index])

        let typeStart = index
        while index < rest.count, rest[index].isASCII, rest[index].isLetter { index += 1 }
        guard index > typeStart else { return nil }
        let billType = String(rest[typeStart..<index])

        let numberStart = index
        while index < rest.count, rest[index].isASCII, rest[index].isNumber { index += 1 }
        guard index > numberStart else { return nil }
        let billNumber = String(rest[numberStart..<index])

        guard rest[index...].allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return (congress, billType, billNumber)
    }
}
