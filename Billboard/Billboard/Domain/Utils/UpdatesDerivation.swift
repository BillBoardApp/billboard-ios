import Foundation

/// The rows the Updates list shows (`UpdatesDerivation.feedSnapshot`). The Updates tab badge counts these
/// same rows, so it never counts one the list leaves out (feature review N5).
nonisolated struct UpdatesFeedSnapshot: Sendable {
    /// Passed bills and bills that became law (Finalized, REL-44).
    let passedBills: [Bill]
    let failedBills: [Bill]
    let activeAlerts: [BillAlert]

    static let empty = UpdatesFeedSnapshot(passedBills: [], failedBills: [], activeAlerts: [])

    /// Every row in Recent actions, Passed bills and Failed bills.
    var rowCount: Int { passedBills.count + failedBills.count + activeAlerts.count }
}

struct BillboardQueueSnapshot: Sendable {
    let pendingBills: [Bill]
    let newCount: Int
    let updatedCount: Int

    nonisolated var badgeCount: Int { newCount + updatedCount }
}

/// The starter feed (spec D 2.5.4): when the profile follows no topics and no life areas (followed
/// members do not count), the Bills list shows new bills instead of an empty list (in the news first, then
/// newest; never by vote count, INT-11).
nonisolated enum StarterFeed {
    /// At most this many cards; the Bills badge counts the same list.
    static let cardLimit = 15

    /// True when `profile` gets the starter feed: a signed-in profile (a non-empty id; the
    /// placeholder used before the profile loads keeps the topic feed) that follows no topics and no
    /// life areas, with `FeatureFlags.starterFeed` on.
    static func isActive(for profile: UserProfile, isEnabled: Bool = FeatureFlags.starterFeed) -> Bool {
        guard isEnabled else { return false }
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !profile.subscribedSubCategories.contains(where: isMeaningful)
            && !profile.subscribedLifeAreas.contains(where: isMeaningful)
    }

    /// Starter eligibility (the window and vote checks are the queue's): every bill with an active
    /// priority ("In the news"), plus every bill the bill-type setting allows.
    static func isEligible(_ bill: Bill, profile: UserProfile) -> Bool {
        bill.hasActivePriority || bill.matchesContentPreferences(profile.effectiveSelectedBillContentTypes)
    }

    private static func isMeaningful(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BillboardQueueDerivation {
    /// The pending bills for the Bills list: in the history window, not voted, not skipped, open (not
    /// Passed, Became law or Failed: `BillStatus.isDecided`), and eligible for the profile (topics, life areas and members it follows, or an active priority;
    /// for a profile that follows no topics or life areas, the starter feed's eligibility). The
    /// starter feed's order and 15-card cap are applied by `BillBoardDerivedCollections`.
    nonisolated static func snapshot(
        bills: [Bill],
        dismissedBillIDs: Set<UUID>,
        userProfile: UserProfile,
        historyWindow: BillboardHistoryWindow,
        voteIndex: UpdatesDerivation.VoteIdentityIndex,
        voteLookup: (String) -> VoteState,
        starterFeedEnabled: Bool = FeatureFlags.starterFeed
    ) -> BillboardQueueSnapshot {
        let recencyCutoff = Date(timeIntervalSinceNow: -historyWindow.timeInterval)
        let isEligible = eligibility(for: userProfile, starterFeedEnabled: starterFeedEnabled)
        if !voteIndex.companions.isEmpty {
            return withoutActuallyEscaping(voteLookup) { voteLookup in
                groupedSnapshot(bills: bills, filter: QueueFilter(
                    dismissedBillIDs: dismissedBillIDs,
                    isEligible: isEligible,
                    recencyCutoff: recencyCutoff,
                    voteIndex: voteIndex,
                    voteLookup: voteLookup
                ))
            }
        }

        var pendingBills: [Bill] = []
        var newCount = 0
        var updatedCount = 0

        for bill in bills {
            guard let storedAt = FlexibleISO8601.parse(bill.storedAt), storedAt >= recencyCutoff else {
                continue
            }
            guard !UpdatesDerivation.isUserVoted(bill, voteIndex: voteIndex, voteLookup: voteLookup) else {
                continue
            }
            guard !dismissedBillIDs.contains(bill.id) else { continue }
            guard isEligible(bill) else { continue }
            if bill.billStatus.isDecided { continue }

            pendingBills.append(bill)

            switch bill.billStatus {
            case .new:
                newCount += 1
            case .updated:
                updatedCount += 1
            default:
                break
            }
        }

        return BillboardQueueSnapshot(
            pendingBills: pendingBills,
            newCount: newCount,
            updatedCount: updatedCount
        )
    }

    /// Whether a bill may be on the Bills list for `profile`: the topic feed's check
    /// (`matchesPriorityAwareFeedEligibility`), or the starter feed's when it applies.
    nonisolated static func eligibility(
        for profile: UserProfile,
        starterFeedEnabled: Bool = FeatureFlags.starterFeed
    ) -> @Sendable (Bill) -> Bool {
        if StarterFeed.isActive(for: profile, isEnabled: starterFeedEnabled) {
            return { StarterFeed.isEligible($0, profile: profile) }
        }
        return { $0.matchesPriorityAwareFeedEligibility(profile) }
    }

    /// The queue's checks, for the grouped queue.
    nonisolated private struct QueueFilter {
        let dismissedBillIDs: Set<UUID>
        let isEligible: (Bill) -> Bool
        let recencyCutoff: Date
        let voteIndex: UpdatesDerivation.VoteIdentityIndex
        let voteLookup: (String) -> VoteState

        func isRecent(_ bill: Bill) -> Bool {
            guard let storedAt = FlexibleISO8601.parse(bill.storedAt) else { return false }
            return storedAt >= recencyCutoff
        }

        func isVoted(_ bill: Bill) -> Bool {
            UpdatesDerivation.isUserVoted(bill, voteIndex: voteIndex, voteLookup: voteLookup)
        }

        /// Passed, Became law (Finalized, REL-44) or Failed.
        func isClosed(_ bill: Bill) -> Bool {
            bill.billStatus.isDecided
        }

        /// A bill in no group, checked as without groups.
        func queues(_ bill: Bill) -> Bool {
            isRecent(bill)
                && !isVoted(bill)
                && !dismissedBillIDs.contains(bill.id)
                && isEligible(bill)
                && !isClosed(bill)
        }

        /// A group's card, or nil when the group is not queued. A group is shown when any member is
        /// in the history window, and hidden when any member is voted or dismissed or every member is
        /// decided (Passed, Became law or Failed). Its card is an open member's bill: the primary's when it is open and among
        /// `members` (the store adds each visible bill's partner), else the first recent open member's,
        /// else the first open member's. So a closed House bill does not hide its open Senate companion,
        /// just as a closed Senate bill does not hide its open House companion.
        func card(for group: BillCompanionGroup, members: [Bill], companions: CompanionGroupIndex) -> Bill? {
            let memberIDs = Set(members.map(\.id)).union(group.memberBillIDs)
            guard members.contains(where: isRecent),
                  !members.contains(where: isVoted),
                  dismissedBillIDs.isDisjoint(with: memberIDs),
                  members.contains(where: isEligible) else { return nil }
            let open = members.filter { !isClosed($0) }
            return open.first(where: { companions.memberGuid(for: $0) == group.primaryGuid })
                ?? open.first(where: isRecent)
                ?? open.first
        }
    }

    /// The queue with one card per companion group (APPF-23); bills in no group are filtered as
    /// without groups.
    nonisolated private static func groupedSnapshot(bills: [Bill], filter: QueueFilter) -> BillboardQueueSnapshot {
        let companions = filter.voteIndex.companions
        var order: [String] = []
        var membersByKey: [String: [Bill]] = [:]
        for bill in bills {
            let key = companions.groupKey(for: bill)
            if membersByKey[key] == nil { order.append(key) }
            membersByKey[key, default: []].append(bill)
        }

        var pendingBills: [Bill] = []
        for key in order {
            guard let members = membersByKey[key], let first = members.first else { continue }
            if let group = companions.group(for: first) {
                if let card = filter.card(for: group, members: members, companions: companions) {
                    pendingBills.append(card)
                }
            } else {
                pendingBills.append(contentsOf: members.filter(filter.queues))
            }
        }

        return BillboardQueueSnapshot(
            pendingBills: pendingBills,
            newCount: pendingBills.filter { $0.billStatus == .new }.count,
            updatedCount: pendingBills.filter { $0.billStatus == .updated }.count
        )
    }

    /// The Bills badge: the new and updated cards the list shows. With the starter feed, only the
    /// cards within its 15-card cap count, in the list's order (`BillBoardDerivedCollections`).
    nonisolated static func badgeCount(
        bills: [Bill],
        dismissedBillIDs: Set<UUID>,
        userProfile: UserProfile,
        historyWindow: BillboardHistoryWindow,
        voteIndex: UpdatesDerivation.VoteIdentityIndex,
        voteLookup: (String) -> VoteState,
        starterFeedEnabled: Bool = FeatureFlags.starterFeed
    ) -> Int {
        let queue = snapshot(
            bills: bills,
            dismissedBillIDs: dismissedBillIDs,
            userProfile: userProfile,
            historyWindow: historyWindow,
            voteIndex: voteIndex,
            voteLookup: voteLookup,
            starterFeedEnabled: starterFeedEnabled
        )
        guard StarterFeed.isActive(for: userProfile, isEnabled: starterFeedEnabled) else { return queue.badgeCount }
        let items = BillBoardDerivedCollections.boardItems(
            cards: queue.pendingBills,
            bills: bills,
            companions: voteIndex.companions
        )
        return BillBoardDerivedCollections.starterFeedItems(items, profile: userProfile)
            .filter { $0.bill.billStatus == .new || $0.bill.billStatus == .updated }
            .count
    }
}

enum UpdatesDerivation {
    struct VoteIdentityIndex: Sendable {
        let votedGuids: Set<String>
        let votedIdentityKeys: Set<String>
        /// The companion groups (APPF-23) the index was built with. A vote on any member marks every
        /// member voted, and the queue shows one card per group. Empty: today's per-bill behaviour.
        var companions: CompanionGroupIndex = .empty
    }

    /// The bill a vote belongs to: its `BillsStore.BillIdentityKey` (congress, normalized type and
    /// number, taken from the guid when a field is missing), or nil when that is unknown.
    ///
    /// APPF-24 (R1): this used to be congress plus number, which ignored the type, so a vote on
    /// H.R. 4500 also hid S. 4500; and it fell back to the generated title, which distinct bills share.
    nonisolated static func logicalVoteIdentityKey(for bill: Bill) -> String? {
        BillsStore.billIdentityKey(
            congress: bill.congress,
            billType: bill.billType,
            billID: bill.billID,
            guid: bill.guid
        )?.stringValue
    }

    nonisolated static func hasDirectUserVote(
        _ bill: Bill,
        voteLookup: (String) -> VoteState
    ) -> Bool {
        if bill.userVoted { return true }
        if bill.userVote?.countsAsVote == true { return true }
        guard let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty else {
            return false
        }
        return voteLookup(guid).countsAsVote
    }

    /// The votes in `bills`, by guid and by bill. With `companions`, a vote on one member of a group
    /// counts for every member (the group shows as voted when any member has a counted vote).
    nonisolated static func voteIdentityIndex(
        for bills: [Bill],
        voteLookup: (String) -> VoteState,
        companions: CompanionGroupIndex = .empty
    ) -> VoteIdentityIndex {
        var votedGuids = Set<String>()
        var votedIdentityKeys = Set<String>()

        for bill in bills {
            guard hasDirectUserVote(bill, voteLookup: voteLookup) else { continue }
            if let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
                votedGuids.insert(guid)
            }
            if let key = logicalVoteIdentityKey(for: bill) {
                votedIdentityKeys.insert(key)
            }
            if let group = companions.group(for: bill) {
                for member in group.memberGuids {
                    votedGuids.insert(member)
                    if let key = CompanionGroupIndex.identityKey(forGUID: member) {
                        votedIdentityKeys.insert(key.stringValue)
                    }
                }
            }
        }

        return VoteIdentityIndex(votedGuids: votedGuids, votedIdentityKeys: votedIdentityKeys, companions: companions)
    }

    nonisolated static func isUserVoted(
        _ bill: Bill,
        voteIndex: VoteIdentityIndex,
        voteLookup: (String) -> VoteState
    ) -> Bool {
        if hasDirectUserVote(bill, voteLookup: voteLookup) { return true }
        if let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty,
           voteIndex.votedGuids.contains(guid) {
            return true
        }

        if let key = logicalVoteIdentityKey(for: bill), voteIndex.votedIdentityKeys.contains(key) {
            return true
        }

        // A member voted from another screen (its bill is not in `bills`): the vote store knows it.
        guard let group = voteIndex.companions.group(for: bill) else { return false }
        return group.memberGuids.contains { voteLookup($0).countsAsVote }
    }

    /// The history window's start for `isOutOfWindowPartner`, or nil when nothing is skipped (no
    /// groups, or no window given).
    nonisolated private static func outOfWindowPartnerCutoff(
        companions: CompanionGroupIndex,
        historyWindow: BillboardHistoryWindow?
    ) -> Date? {
        guard !companions.isEmpty, let historyWindow else { return nil }
        return Date(timeIntervalSinceNow: -historyWindow.timeInterval)
    }

    /// True for a companion bill (APPF-23) that is outside the history window and not watched. The
    /// store loads such a bill only as the partner of an in-window member, so Home can build the
    /// group's card; without groups it would not be loaded, so the Updates feed and badge skip it
    /// instead of listing a months-old Passed or Failed partner. Always false when `cutoff` is nil.
    nonisolated private static func isOutOfWindowPartner(_ bill: Bill, companions: CompanionGroupIndex, cutoff: Date?) -> Bool {
        guard let cutoff, !bill.userWatched, companions.group(for: bill) != nil else { return false }
        guard let storedAt = FlexibleISO8601.parse(bill.storedAt) else { return true }
        return storedAt < cutoff
    }

    /// The Updates tab badge: the rows the Updates list shows (`feedSnapshot`, with the same filters: the
    /// bill-type setting, the topics, life areas and members followed, votes, Clear and the history window),
    /// plus `unreadDigestCount` for an unread Weekly Brief, which the list shows as its UNREAD front page
    /// (feature review N5). It used to filter on its own: it ignored the bill-type setting for Passed and
    /// Failed bills and counted alerts on bills outside the user's topics, so it could say 5 over a list
    /// that showed less.
    nonisolated static func badgeCount(
        bills: [Bill],
        alerts: [BillAlert],
        dismissedBillIDs: Set<UUID>,
        readBillAlertIDs: Set<UUID>,
        userProfile: UserProfile,
        unreadDigestCount: Int,
        voteLookup: (String) -> VoteState,
        billLookup: (UUID) -> Bill?,
        companions: CompanionGroupIndex = .empty,
        historyWindow: BillboardHistoryWindow? = nil
    ) -> Int {
        let feed = feedSnapshot(
            bills: bills,
            alerts: alerts,
            dismissedBillIDs: dismissedBillIDs,
            readBillAlertIDs: readBillAlertIDs,
            userProfile: userProfile,
            voteLookup: voteLookup,
            billLookup: billLookup,
            companions: companions,
            historyWindow: historyWindow
        )
        return feed.rowCount + unreadDigestCount
    }

    nonisolated static func feedSnapshot(
        bills: [Bill],
        alerts: [BillAlert],
        dismissedBillIDs: Set<UUID>,
        readBillAlertIDs: Set<UUID>,
        userProfile: UserProfile,
        voteLookup: (String) -> VoteState,
        billLookup: (UUID) -> Bill?,
        companions: CompanionGroupIndex = .empty,
        historyWindow: BillboardHistoryWindow? = nil
    ) -> UpdatesFeedSnapshot {
        let voteIndex = voteIdentityIndex(for: bills, voteLookup: voteLookup, companions: companions)
        let partnerCutoff = outOfWindowPartnerCutoff(companions: companions, historyWindow: historyWindow)

        var passedBills: [Bill] = []
        var failedBills: [Bill] = []
        for bill in bills {
            guard !isUserVoted(bill, voteIndex: voteIndex, voteLookup: voteLookup) else { continue }
            guard !dismissedBillIDs.contains(bill.id) else { continue }
            guard !isOutOfWindowPartner(bill, companions: companions, cutoff: partnerCutoff) else { continue }
            guard bill.matchesPriorityAwareFeedEligibility(userProfile) else { continue }

            // A bill that became law (Finalized, REL-44) is listed with the passed bills, so their Clear
            // all reaches it too.
            switch bill.billStatus {
            case .passed, .finalized:
                passedBills.append(bill)
            case .failed:
                failedBills.append(bill)
            case .new, .updated:
                break
            }
        }

        let activeAlerts = alerts.filter { alert in
            guard !readBillAlertIDs.contains(alert.id) else { return false }
            guard let billID = alert.billID else { return true }
            guard let bill = billLookup(billID) else { return true }
            guard bill.matchesPriorityAwareFeedEligibility(userProfile) else { return false }
            return !isUserVoted(bill, voteIndex: voteIndex, voteLookup: voteLookup)
        }

        return UpdatesFeedSnapshot(
            passedBills: passedBills,
            failedBills: failedBills,
            activeAlerts: activeAlerts
        )
    }
}
