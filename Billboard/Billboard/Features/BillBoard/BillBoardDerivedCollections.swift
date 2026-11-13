import Foundation

/// The Bills list and the collections derived with it. `BillBoardTab` recomputes them off
/// the main actor whenever the bills, votes, dismissals (skips), profile or history window change.
struct BillBoardDerivedCollections: Sendable {
    let snapshot: BillboardQueueSnapshot
    let voteIdentityIndex: UpdatesDerivation.VoteIdentityIndex
    let liveBoardItems: [BillBoardItem]
    let watchList: [Bill]
    let votedRecent: [Bill]
    let passedSubscribed: [Bill]
    /// The list is the starter feed (spec D 2.5.4): ordered for it and capped at
    /// `StarterFeed.cardLimit` cards.
    var isStarterFeed: Bool = false

    static let empty = BillBoardDerivedCollections(
        snapshot: BillboardQueueSnapshot(pendingBills: [], newCount: 0, updatedCount: 0),
        voteIdentityIndex: UpdatesDerivation.VoteIdentityIndex(votedGuids: [], votedIdentityKeys: []),
        liveBoardItems: [],
        watchList: [],
        votedRecent: [],
        passedSubscribed: []
    )

    struct Input: Sendable {
        let bills: [Bill]
        let dismissedBillIDs: Set<UUID>
        let userProfile: UserProfile
        let historyWindow: BillboardHistoryWindow
        let voteStatesByBillID: [String: VoteState]
        /// `BillsStore.companionGroupIndex` (APPF-23). With groups, Home shows one card per group; empty
        /// (the default) keeps one card per bill.
        var companions: CompanionGroupIndex = .empty
        /// `FeatureFlags.starterFeed`; tests switch it.
        var starterFeedEnabled: Bool = FeatureFlags.starterFeed
        /// Guids whose vote row is an Abstain (`BillsStore.abstainedGuids(in:)`). An Abstain from bill
        /// detail also takes the bill off the list, but it is a vote, not a skip, so the Skipped list
        /// leaves it out. Only `skippedItems(from:)` reads it.
        var abstainedGuids: Set<String> = []
    }

    nonisolated static func derive(from input: Input) -> BillBoardDerivedCollections {
        let bills = input.bills
        let dismissedBillIDs = input.dismissedBillIDs
        let userProfile = input.userProfile
        let historyWindow = input.historyWindow
        let voteStatesByBillID = input.voteStatesByBillID
        let companions = input.companions

        #if DEBUG
        let startedAt = CFAbsoluteTimeGetCurrent()
        #endif

        let voteLookup = Self.voteLookup(for: voteStatesByBillID)
        let voteIndex = UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: voteLookup, companions: companions)
        let snapshot = BillboardQueueDerivation.snapshot(
            bills: bills,
            dismissedBillIDs: dismissedBillIDs,
            userProfile: userProfile,
            historyWindow: historyWindow,
            voteIndex: voteIndex,
            voteLookup: voteLookup,
            starterFeedEnabled: input.starterFeedEnabled
        )
        let isStarterFeed = StarterFeed.isActive(for: userProfile, isEnabled: input.starterFeedEnabled)
        let rankedItems = Self.boardItems(cards: snapshot.pendingBills, bills: bills, companions: companions)
        let liveBoardItems = isStarterFeed ? Self.starterFeedItems(rankedItems, profile: userProfile) : rankedItems
        let pendingBills = liveBoardItems.map(\.bill)
        let watchList = companions.collapsed(bills.filter { $0.userWatched }).sorted { a, b in
            let da = a.lastVotedAt ?? Date.distantPast
            let db = b.lastVotedAt ?? Date.distantPast
            return da > db
        }
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        let votedRecent = companions.collapsed(bills.filter { bill in
            guard UpdatesDerivation.isUserVoted(
                bill,
                voteIndex: voteIndex,
                voteLookup: voteLookup
            ) else {
                return false
            }
            if let last = bill.lastVotedAt, let cutoff = thirtyDaysAgo {
                return last >= cutoff
            }
            return false
        }).sorted { a, b in
            let da = a.lastVotedAt ?? Date.distantPast
            let db = b.lastVotedAt ?? Date.distantPast
            return da > db
        }
        let passedSubscribed = Self.passedSubscribed(bills: bills, profile: userProfile, companions: companions)
        let next = BillBoardDerivedCollections(
            snapshot: BillboardQueueSnapshot(
                pendingBills: pendingBills,
                // The starter feed's cap drops cards, so count the ones shown (the badge does too).
                newCount: isStarterFeed ? pendingBills.filter { $0.billStatus == .new }.count : snapshot.newCount,
                updatedCount: isStarterFeed ? pendingBills.filter { $0.billStatus == .updated }.count : snapshot.updatedCount
            ),
            voteIdentityIndex: voteIndex,
            liveBoardItems: liveBoardItems,
            watchList: watchList,
            votedRecent: votedRecent,
            passedSubscribed: passedSubscribed,
            isStarterFeed: isStarterFeed
        )

        #if DEBUG
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        if elapsedMs >= 50 {
            HomePerfTimeline.mark(
                "home_derived_collections_recalculated",
                detail: "bills=\(bills.count) queue=\(liveBoardItems.count) watch=\(watchList.count) voted=\(votedRecent.count) passed=\(passedSubscribed.count) elapsedMs=\(elapsedMs)"
            )
        }
        #endif

        return next
    }

    /// Bills that passed or became law (Finalized, REL-44) on topics, life areas or members `profile`
    /// follows (or with an active priority), one entry per companion group, latest vote first: the
    /// Passed tile in Search bills and its count.
    nonisolated static func passedSubscribed(bills: [Bill], profile: UserProfile, companions: CompanionGroupIndex) -> [Bill] {
        companions.collapsed(bills.filter { bill in
            bill.billStatus.isPassedOutcome && bill.matchesPriorityAwareSubscription(profile)
        }).sorted { a, b in
            let da = a.lastVotedAt ?? Date.distantPast
            let db = b.lastVotedAt ?? Date.distantPast
            return da > db
        }
    }

    /// Home items for the queue's cards in Home order. Without groups: one per bill, ranked by
    /// `rankBillsForBoard`. With groups: see `groupedBoardItems`.
    nonisolated static func boardItems(cards: [Bill], bills: [Bill], companions: CompanionGroupIndex) -> [BillBoardItem] {
        guard companions.isEmpty else {
            return groupedBoardItems(cards: cards, bills: bills, companions: companions)
        }
        return rankBillsForBoard(cards).map { bill in
            BillBoardItem(
                id: bill.id,
                bill: bill,
                date: bill.boardSortDate,
                type: Self.boardItemType(for: bill)
            )
        }
    }

    /// Home items for the queue's cards (one per group or ungrouped bill), in Home order: priority when
    /// any member has one (the lowest rank), then the latest member date, then title and guid
    /// (`CompanionRankValues`); never the vote count (INT-11). A group's item carries its members and
    /// status lead; its date is the latest member's.
    nonisolated static func groupedBoardItems(
        cards: [Bill],
        bills: [Bill],
        companions: CompanionGroupIndex
    ) -> [BillBoardItem] {
        var membersByPrimary: [String: [Bill]] = [:]
        for bill in bills {
            guard let group = companions.group(for: bill) else { continue }
            membersByPrimary[group.primaryGuid, default: []].append(bill)
        }

        let ranked = cards.map { card -> (values: CompanionRankValues, bill: Bill) in
            guard let group = companions.group(for: card) else {
                return (CompanionRankValues(bills: [card]), card)
            }
            return (companions.rankValues(for: card, memberBills: membersByPrimary[group.primaryGuid] ?? []), card)
        }
        .sorted(by: CompanionRankValues.ranksBefore)

        return ranked.map { entry in
            let card = entry.bill
            var item = BillBoardItem(
                id: card.id,
                bill: card,
                date: entry.values.sortDate,
                type: Self.boardItemType(for: card)
            )
            if let group = companions.group(for: card) {
                let loaded = membersByPrimary[group.primaryGuid] ?? []
                item.companionGroup = group
                item.memberBills = companions.memberBills(of: group, in: loaded + [card])
                item.statusLead = companions.statusLead(for: group, memberBills: loaded + [card])
            }
            return item
        }
    }

    /// The starter feed's list (spec D 2.5.4) from Home-ranked items: bills with an active priority
    /// first, then bills by members the profile follows (sponsor or cosponsor, any member of a group),
    /// then the rest, each part in Home order; at most `StarterFeed.cardLimit` cards.
    nonisolated static func starterFeedItems(_ items: [BillBoardItem], profile: UserProfile) -> [BillBoardItem] {
        func bills(of item: BillBoardItem) -> [Bill] {
            item.memberBills.isEmpty ? [item.bill] : item.memberBills
        }
        var priority: [BillBoardItem] = []
        var followedMember: [BillBoardItem] = []
        var rest: [BillBoardItem] = []
        for item in items {
            let itemBills = bills(of: item)
            if itemBills.contains(where: \.hasActivePriority) {
                priority.append(item)
            } else if itemBills.contains(where: { $0.matchesSubscribedMembers(profile) }) {
                followedMember.append(item)
            } else {
                rest.append(item)
            }
        }
        return Array((priority + followedMember + rest).prefix(StarterFeed.cardLimit))
    }

    /// Bills the user skipped that would be back on the Bills list if put back (the Skipped tile in
    /// Search bills, spec D 2.1.2): cards of the loaded window that are hidden only by a dismissal,
    /// in Home order, without the starter feed's cap. A card the user abstained on (any of its guids
    /// in `abstainedGuids`) is not a skip and is left out.
    nonisolated static func skippedItems(from input: Input) -> [BillBoardItem] {
        guard !input.dismissedBillIDs.isEmpty else { return [] }
        let voteLookup = Self.voteLookup(for: input.voteStatesByBillID)
        let voteIndex = UpdatesDerivation.voteIdentityIndex(for: input.bills, voteLookup: voteLookup, companions: input.companions)
        let undismissed = BillboardQueueDerivation.snapshot(
            bills: input.bills,
            dismissedBillIDs: [],
            userProfile: input.userProfile,
            historyWindow: input.historyWindow,
            voteIndex: voteIndex,
            voteLookup: voteLookup,
            starterFeedEnabled: input.starterFeedEnabled
        )
        let items = boardItems(cards: undismissed.pendingBills, bills: input.bills, companions: input.companions)
        return items.filter { item in
            var ids: Set<UUID> = [item.id, item.bill.id]
            ids.formUnion(item.memberBills.map(\.id))
            if let group = item.companionGroup {
                ids.formUnion(group.memberBillIDs)
            }
            guard !input.dismissedBillIDs.isDisjoint(with: ids) else { return false }
            return !isAbstained(item, abstainedGuids: input.abstainedGuids)
        }
    }

    /// Any guid of the card (its bill, its member bills, its group's members) holds an Abstain.
    nonisolated private static func isAbstained(_ item: BillBoardItem, abstainedGuids: Set<String>) -> Bool {
        guard !abstainedGuids.isEmpty else { return false }
        var guids = ([item.bill] + item.memberBills).compactMap { $0.guid?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guids.append(contentsOf: item.companionGroup?.memberGuids ?? [])
        return guids.contains(where: abstainedGuids.contains)
    }

    nonisolated static func voteLookup(for voteStatesByBillID: [String: VoteState]) -> @Sendable (String) -> VoteState {
        { guid in
            let cleaned = guid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return .unknown }
            return voteStatesByBillID[cleaned] ?? .unknown
        }
    }

    /// A decided bill (Passed, Became law or Failed) is a `.passed` item, an updated one asks for a new
    /// vote. Every item's bill opens with the vote bar (`BillDetail.Mode(opening:)`).
    nonisolated static func boardItemType(for bill: Bill) -> BillBoardItem.ItemType {
        switch bill.billStatus {
        case .passed, .finalized, .failed:
            return .passed
        case .updated:
            return .updated
        case .new:
            return .bill
        }
    }
}
