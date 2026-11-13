import Foundation

/// Bills order (INT-11): an active priority ("In the news") first, then the priority rank, then the newest
/// (`storedAt`), then title and guid. Never by vote count: other users' votes show only in a bill's Results,
/// after the user votes or abstains on it.
nonisolated func rankBillsForBoard(_ bills: [Bill], now: Date = Date()) -> [Bill] {
    bills
        .map { (key: BillBoardRankingKey(bill: $0, now: now), bill: $0) }
        .sorted { $0.key.isOrdered(before: $1.key) }
        .map(\.bill)
}

private struct BillBoardRankingKey {
    let hasActivePriority: Bool
    let prioritySortRank: Int
    let boardSortDate: Date
    let title: String
    let guid: String

    nonisolated init(bill: Bill, now: Date = Date()) {
        let priorityExpiration = FlexibleISO8601.parse(bill.priorityExpiresAt)
        let priorityRank = bill.priorityRank ?? 0
        hasActivePriority = bill.isPriority && (priorityExpiration.map { $0 > now } ?? true)
        prioritySortRank = hasActivePriority && priorityRank > 0 ? priorityRank : Int.max
        boardSortDate = FlexibleISO8601.parse(bill.storedAt) ?? bill.lastVotedAt ?? .distantPast
        title = bill.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guid = bill.guid ?? ""
    }

    nonisolated func isOrdered(before other: BillBoardRankingKey) -> Bool {
        if hasActivePriority != other.hasActivePriority {
            return hasActivePriority
        }

        if prioritySortRank != other.prioritySortRank {
            return prioritySortRank < other.prioritySortRank
        }

        if boardSortDate != other.boardSortDate {
            return boardSortDate > other.boardSortDate
        }

        let titleComparison = title.localizedCaseInsensitiveCompare(other.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        return guid < other.guid
    }
}

enum BillStatus: String, Codable, Sendable {
    case new = "New"
    case updated = "Updated"
    case passed = "Passed"
    case failed = "Failed"
    case finalized = "Finalized"
}

extension BillStatus {
    /// Congress has decided the bill: Passed, Became law (`Finalized`, REL-44) or Failed. A decided
    /// bill is not on the Bills list; Updates lists it under Passed or Failed bills.
    nonisolated var isDecided: Bool {
        switch self {
        case .passed, .finalized, .failed:
            return true
        case .new, .updated:
            return false
        }
    }

    /// Passed, or became law (`Finalized`): the outcomes listed with passed bills (Updates' "Passed
    /// bills", the Passed tile in Search bills and its count, the Updates badge).
    nonisolated var isPassedOutcome: Bool {
        self == .passed || self == .finalized
    }

    /// The status as the app shows and reads it out: "Became law" for `Finalized` (the server's word
    /// is kept for the wire), else the status itself ("New", "Updated", "Passed", "Failed").
    nonisolated var displayLabel: String {
        switch self {
        case .finalized:
            return "Became law"
        case .new, .updated, .passed, .failed:
            return rawValue
        }
    }
}

enum UserVote: String, Codable, Sendable {
    case yea = "Yea"
    case nay = "Nay"
    case abstain = "Abstain"

    nonisolated var countsAsVote: Bool {
        switch self {
        case .yea, .nay:
            return true
        case .abstain:
            return false
        }
    }
}

struct BillBreakdown: Codable, Hashable, Sendable {
    let who: String?
    let what: String?
    let how: String?
    let when: String?
    let `where`: String?
    let why: String?

    /// True when at least one field has non-empty content.
    var hasContent: Bool {
        [who, what, how, when, `where`, why].contains { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    /// Flattened searchable text for filtering.
    var searchableText: String {
        [who, what, how, when, `where`, why].compactMap { $0 }.joined(separator: " ")
    }
}

struct Bill: Identifiable, Codable, Sendable {
    struct OfficialVoteMember: Codable, Hashable, Sendable, Identifiable {
        var id: String { bioguideId }
        let bioguideId: String
        let displayName: String
        let party: String?
        let state: String?
        let district: String?
        let votePosition: String
    }

    struct OfficialChamberVote: Codable, Hashable, Sendable {
        let yea: Int
        let nay: Int
        let present: Int
        let notVoting: Int
        let totalCounted: Int
        let actionCode: String?
        let actionDate: String?
        let resultText: String?
        let memberDataAvailable: Bool
        let members: [OfficialVoteMember]
    }

    struct OfficialVotesBreakdown: Codable, Hashable, Sendable {
        let house: OfficialChamberVote?
        let senate: OfficialChamberVote?
        let lastSyncedAt: String?
        let source: String?
        let completeness: String?
    }

    let id: UUID
    /// Generated plain-language headline.
    let title: String
    /// The bill's official title (from its text, or Congress's title when the text has none).
    /// Nil for manifest-only bills and for bills processed before it was stored.
    let officialTitle: String?
    let category: String
    let summary: String
    let soWhat: String
    let billBreakdown: BillBreakdown?
    /// Timestamp (ISO-8601 string) for when the processed bill was stored/updated.
    let storedAt: String?
    /// Canonical URL to the bill (from processed-bill payload).
    let link: String?
    /// Congressional actions timeline (from processed-bill payload).
    let actions: [BillAction]
    /// Committee involvement summary (from processed-bill payload).
    let committees: [BillCommittee]
    let lifeAreas: [String]
    let subCategory: String?
    var billStatus: BillStatus
    // Source metadata (used to re-fetch processed bill details on demand)
    var guid: String?
    var congress: String?
    var billType: String?
    var billID: String?
    // Optional attribution for Congress stats (used in Congress info views)
    var sponsorMemberID: UUID?
    // Sponsor and cosponsor attribution used for followed-member subscriptions.
    var relatedMemberIDs: [UUID]?
    // Chamber outcomes (used in Congress info views)
    var passedHouse: Bool
    var passedSenate: Bool
    var userVoted: Bool
    var userWatched: Bool
    var userVote: UserVote?
    var lastVotedAt: Date?
    // Counts of the local user's own interactions. Bills carry no other users' vote counts (INT-11); an
    // old cached bill that still has `voteCount` decodes, and the key is ignored.
    var userYeaCount: Int
    var userNayCount: Int
    var isPriority: Bool
    var priorityRank: Int?
    var priorityReason: String?
    var priorityExpiresAt: String?
    // Separate official counts for House and Senate (optional)
    var congressHouseYeaCount: Int?
    var congressHouseNayCount: Int?
    var congressSenateYeaCount: Int?
    var congressSenateNayCount: Int?
    var officialVotes: OfficialVotesBreakdown?
    var isProcessedDetailHydrated: Bool?

    struct BillAction: Codable, Hashable, Sendable {
        let actionCode: String?
        /// Typically yyyy-mm-dd (as returned by the backend).
        let actionDate: String?
        let text: String?
        let type: String?
        let sourceSystem: SourceSystem?
        let committees: [CommitteeRef]?

        struct SourceSystem: Codable, Hashable, Sendable {
            let code: Int?
            let name: String?
        }

        struct CommitteeRef: Codable, Hashable, Sendable {
            let name: String?
            let systemCode: String?
            let url: String?
        }
    }

    struct BillCommittee: Codable, Hashable, Sendable {
        let chamber: String?
        let name: String?
        let systemCode: String?
        let type: String?
        let url: String?
        let activities: [Activity]?

        struct Activity: Codable, Hashable, Sendable {
            let date: String?
            let name: String?
        }
    }

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        officialTitle: String? = nil,
        category: String,
        subCategory: String? = nil,
        summary: String = "",
        soWhat: String,
        billBreakdown: BillBreakdown? = nil,
        storedAt: String? = nil,
        link: String? = nil,
        actions: [BillAction] = [],
        committees: [BillCommittee] = [],
        lifeAreas: [String] = [],
        billStatus: BillStatus,
        guid: String? = nil,
        congress: String? = nil,
        billType: String? = nil,
        billID: String? = nil,
        sponsorMemberID: UUID? = nil,
        relatedMemberIDs: [UUID]? = nil,
        passedHouse: Bool = false,
        passedSenate: Bool = false,
        userVoted: Bool,
        userWatched: Bool = false,
        userVote: UserVote? = nil,
        lastVotedAt: Date? = nil,
        userYeaCount: Int = 0,
        userNayCount: Int = 0,
        isPriority: Bool = false,
        priorityRank: Int? = nil,
        priorityReason: String? = nil,
        priorityExpiresAt: String? = nil,
        congressYeaCount: Int? = nil,
        congressNayCount: Int? = nil,
        congressHouseYeaCount: Int? = nil,
        congressHouseNayCount: Int? = nil,
        congressSenateYeaCount: Int? = nil,
        congressSenateNayCount: Int? = nil,
        officialVotes: OfficialVotesBreakdown? = nil,
        isProcessedDetailHydrated: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.officialTitle = officialTitle
        self.subCategory = subCategory
        self.category = category
        self.summary = summary
        self.soWhat = soWhat
        self.billBreakdown = billBreakdown
        self.storedAt = storedAt
        self.link = link
        self.actions = actions
        self.committees = committees
        self.lifeAreas = lifeAreas
        self.billStatus = billStatus
        self.guid = guid
        self.congress = congress
        self.billType = billType
        self.billID = billID
        self.sponsorMemberID = sponsorMemberID
        self.relatedMemberIDs = relatedMemberIDs
        self.passedHouse = passedHouse
        self.passedSenate = passedSenate
        self.userVoted = userVoted
        self.userWatched = userWatched
        self.userVote = userVote
        self.lastVotedAt = lastVotedAt
        self.userYeaCount = userYeaCount
        self.userNayCount = userNayCount
        self.isPriority = isPriority
        self.priorityRank = priorityRank
        self.priorityReason = priorityReason
        self.priorityExpiresAt = priorityExpiresAt
        self.officialVotes = officialVotes
        let officialHouse = officialVotes?.house
        let officialSenate = officialVotes?.senate
        // Backwards-compatible mapping: if old aggregated fields are provided, map them to House totals by default
        self.congressHouseYeaCount = congressHouseYeaCount ?? congressYeaCount ?? officialHouse?.yea
        self.congressHouseNayCount = congressHouseNayCount ?? congressNayCount ?? officialHouse?.nay
        self.congressSenateYeaCount = congressSenateYeaCount ?? officialSenate?.yea
        self.congressSenateNayCount = congressSenateNayCount ?? officialSenate?.nay
        self.isProcessedDetailHydrated = isProcessedDetailHydrated
    }
}

extension Bill {
    nonisolated var hasActivePriority: Bool {
        guard isPriority else { return false }
        guard let priorityExpiresAt else { return true }
        guard let expiresAt = FlexibleISO8601.parse(priorityExpiresAt) else { return true }
        return expiresAt > Date()
    }

    nonisolated var prioritySortRank: Int {
        guard hasActivePriority else { return Int.max }
        guard let priorityRank, priorityRank > 0 else { return Int.max }
        return priorityRank
    }

    nonisolated var boardSortDate: Date {
        FlexibleISO8601.parse(storedAt) ?? lastVotedAt ?? .distantPast
    }

    nonisolated var subscriptionMemberIDs: [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []

        if let sponsorMemberID, seen.insert(sponsorMemberID).inserted {
            ids.append(sponsorMemberID)
        }

        for memberID in relatedMemberIDs ?? [] where seen.insert(memberID).inserted {
            ids.append(memberID)
        }

        return ids
    }

    nonisolated func matchesSubscribedMembers(_ profile: UserProfile) -> Bool {
        let followedMemberIDs = Set(profile.subscribedMemberIDs)
        guard !followedMemberIDs.isEmpty else { return false }
        return subscriptionMemberIDs.contains { followedMemberIDs.contains($0) }
    }

    nonisolated func matchesSubscribedInterests(_ profile: UserProfile) -> Bool {
        let userSubCats = Set(profile.subscribedSubCategories.map { $0.lowercased() })
        let userLife = Set(profile.subscribedLifeAreas.map { $0.lowercased() })

        let billTopic = (subCategory ?? category).lowercased()
        let matchesCategory = userSubCats.contains(billTopic)
        let matchesLife = lifeAreas.contains { userLife.contains($0.lowercased()) }
        return matchesCategory || matchesLife || matchesSubscribedMembers(profile)
    }

    nonisolated func matchesPriorityAwareFeedEligibility(_ profile: UserProfile) -> Bool {
        if hasActivePriority { return true }
        guard matchesContentPreferences(profile.effectiveSelectedBillContentTypes) else { return false }
        return matchesSubscribedInterests(profile)
    }

    nonisolated func matchesPriorityAwareSubscription(_ profile: UserProfile) -> Bool {
        if hasActivePriority { return true }
        return matchesSubscribedInterests(profile)
    }

    nonisolated var contentTypePreference: BillContentTypePreference? {
        BillContentTypePreference.from(rawBillType: billType)
    }

    nonisolated func matchesContentPreferences(_ allowed: Set<BillContentTypePreference>) -> Bool {
        BillContentTypePreference.allows(rawBillType: billType, allowed: allowed)
    }
}

// MARK: - Renamed topics (LLM-10)

extension Bill {
    /// This bill with a legacy topic name in `subCategory` or `category` replaced by its current name
    /// (`SubscriptionsConfig.canonicalTopic`); every other field is kept as it is. Returns `self` when
    /// neither carries a legacy name. For bills that skip the processed-bill and manifest mappings, such
    /// as bills decoded from the disk cache (the synthesized `Codable` init keeps the stored labels).
    nonisolated func canonicalizingTopics() -> Bill {
        let canonicalSubCategory = subCategory.map(SubscriptionsConfig.canonicalTopic)
        let canonicalCategory = SubscriptionsConfig.canonicalTopic(category)
        guard canonicalSubCategory != subCategory || canonicalCategory != category else { return self }

        var copy = Bill(
            id: id,
            title: title,
            officialTitle: officialTitle,
            category: canonicalCategory,
            subCategory: canonicalSubCategory,
            summary: summary,
            soWhat: soWhat,
            billBreakdown: billBreakdown,
            storedAt: storedAt,
            link: link,
            actions: actions,
            committees: committees,
            lifeAreas: lifeAreas,
            billStatus: billStatus,
            guid: guid,
            congress: congress,
            billType: billType,
            billID: billID,
            sponsorMemberID: sponsorMemberID,
            relatedMemberIDs: relatedMemberIDs,
            passedHouse: passedHouse,
            passedSenate: passedSenate,
            userVoted: userVoted,
            userWatched: userWatched,
            userVote: userVote,
            lastVotedAt: lastVotedAt,
            userYeaCount: userYeaCount,
            userNayCount: userNayCount,
            isPriority: isPriority,
            priorityRank: priorityRank,
            priorityReason: priorityReason,
            priorityExpiresAt: priorityExpiresAt,
            officialVotes: officialVotes,
            isProcessedDetailHydrated: isProcessedDetailHydrated
        )
        // The init fills missing Congress counts from `officialVotes`; keep the stored ones exactly.
        copy.congressHouseYeaCount = congressHouseYeaCount
        copy.congressHouseNayCount = congressHouseNayCount
        copy.congressSenateYeaCount = congressSenateYeaCount
        copy.congressSenateNayCount = congressSenateNayCount
        return copy
    }
}

// MARK: - Processed-bill contract mapping

extension BillBreakdown {
    nonisolated init(dto: UserAPIContractsV1.ProcessedBillBreakdown) {
        self.init(who: dto.who, what: dto.what, how: dto.how, when: dto.when, where: dto.`where`, why: dto.why)
    }
}

extension Bill.BillAction {
    /// The contract lists only the fields the app reads, so `sourceSystem` and `committees` stay nil.
    nonisolated init(dto: UserAPIContractsV1.ProcessedBillAction) {
        self.init(
            actionCode: dto.actionCode,
            actionDate: dto.actionDate,
            text: dto.text,
            type: dto.type,
            sourceSystem: nil,
            committees: nil
        )
    }
}

extension Bill.BillCommittee {
    /// The contract lists only the fields the app reads, so `systemCode`, `type` and `url` stay nil.
    /// `activities` stays nil when the committee has none of its own (only its subcommittees acted),
    /// and an activity's `date` stays nil when Congress.gov gives none (Bills of Interest - Exchange of Letters).
    nonisolated init(dto: UserAPIContractsV1.ProcessedBillCommittee) {
        self.init(
            chamber: dto.chamber,
            name: dto.name,
            systemCode: nil,
            type: nil,
            url: nil,
            activities: dto.activities?.map { Activity(date: $0.date, name: $0.name) }
        )
    }
}

extension Bill.OfficialVotesBreakdown {
    nonisolated init(dto: UserAPIContractsV1.OfficialVotesBreakdown) {
        self.init(
            house: dto.house.map(Bill.OfficialChamberVote.init(dto:)),
            senate: dto.senate.map(Bill.OfficialChamberVote.init(dto:)),
            lastSyncedAt: dto.lastSyncedAt,
            source: dto.source,
            completeness: dto.completeness
        )
    }
}

extension Bill.OfficialChamberVote {
    nonisolated init(dto: UserAPIContractsV1.OfficialChamberVote) {
        self.init(
            yea: dto.yea,
            nay: dto.nay,
            present: dto.present,
            notVoting: dto.notVoting,
            totalCounted: dto.totalCounted,
            actionCode: dto.actionCode,
            actionDate: dto.actionDate,
            resultText: dto.resultText,
            memberDataAvailable: dto.memberDataAvailable,
            members: dto.members.map {
                Bill.OfficialVoteMember(
                    bioguideId: $0.bioguideId,
                    displayName: $0.displayName,
                    party: $0.party,
                    state: $0.state,
                    district: $0.district,
                    votePosition: $0.votePosition
                )
            }
        )
    }
}
