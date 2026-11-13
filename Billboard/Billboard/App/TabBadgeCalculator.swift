import Foundation

/// Badge counts for the tab bar: the new and updated bills on the Bills tab and unread items on
/// Updates. `TabsBar` computes them off the main actor from a snapshot of its stores. For a profile
/// that follows no topics or life areas the Bills badge counts the starter feed (spec D 2.5.4): at
/// most `StarterFeed.cardLimit` cards, the same ones the list shows.
nonisolated enum TabBadgeCalculator {
    struct Snapshot: Sendable {
        let activeManifestBills: [Bill]
        let allBills: [Bill]
        let alerts: [BillAlert]
        let dismissedBillIDs: Set<UUID>
        let readBillAlertIDs: Set<UUID>
        let userProfile: UserProfile
        let unreadDigestCount: Int
        let historyWindow: BillboardHistoryWindow
        let voteStatesByBillID: [String: VoteState]
        /// `BillsStore.companionGroupIndex` (APPF-23). With groups the Home badge counts one per
        /// group card, and a vote on one member clears the others from the Updates badge. Empty: per bill.
        var companions: CompanionGroupIndex = .empty
    }

    struct Counts: Sendable {
        let home: Int
        let updates: Int
    }

    static func counts(for snapshot: Snapshot) -> Counts {
        #if DEBUG
        let startedAt = CFAbsoluteTimeGetCurrent()
        #endif

        let homeBadgeCount = computeHomeBadgeCount(for: snapshot)
        let updatesBadgeCount = computeUpdatesBadgeCount(for: snapshot)

        #if DEBUG
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        if elapsedMs >= 40 {
            HomePerfTimeline.mark(
                "tab_badges_recalculated",
                detail: "home=\(homeBadgeCount) updates=\(updatesBadgeCount) manifest=\(snapshot.activeManifestBills.count) " +
                    "bills=\(snapshot.allBills.count) alerts=\(snapshot.alerts.count) elapsedMs=\(elapsedMs)"
            )
        }
        #endif

        return Counts(home: homeBadgeCount, updates: updatesBadgeCount)
    }

    private static func voteLookup(for voteStatesByBillID: [String: VoteState]) -> @Sendable (String) -> VoteState {
        { guid in
            let cleaned = guid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return .unknown }
            return voteStatesByBillID[cleaned] ?? .unknown
        }
    }

    /// The Bills badge, through `BillboardQueueDerivation.badgeCount`, which applies the starter
    /// feed's eligibility, order and cap exactly as `BillBoardDerivedCollections` does for the list.
    private static func computeHomeBadgeCount(for snapshot: Snapshot) -> Int {
        let bills = snapshot.activeManifestBills
        let voteLookup = voteLookup(for: snapshot.voteStatesByBillID)
        let voteIndex = UpdatesDerivation.voteIdentityIndex(
            for: bills,
            voteLookup: voteLookup,
            companions: snapshot.companions
        )

        return BillboardQueueDerivation.badgeCount(
            bills: bills,
            dismissedBillIDs: snapshot.dismissedBillIDs,
            userProfile: snapshot.userProfile,
            historyWindow: snapshot.historyWindow,
            voteIndex: voteIndex,
            voteLookup: voteLookup
        )
    }

    /// The Updates badge, through `UpdatesDerivation.badgeCount`, which counts the rows
    /// `UpdatesDerivation.feedSnapshot` gives the list (feature review N5), plus an unread Weekly Brief. The bill
    /// lookup keeps the first bill for an id, as `BillsStore.bill(for:)` does for the list.
    private static func computeUpdatesBadgeCount(for snapshot: Snapshot) -> Int {
        let bills = snapshot.allBills
        let voteLookup = voteLookup(for: snapshot.voteStatesByBillID)
        let billsByID = Dictionary(bills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return UpdatesDerivation.badgeCount(
            bills: bills,
            alerts: snapshot.alerts,
            dismissedBillIDs: snapshot.dismissedBillIDs,
            readBillAlertIDs: snapshot.readBillAlertIDs,
            userProfile: snapshot.userProfile,
            unreadDigestCount: snapshot.unreadDigestCount,
            voteLookup: voteLookup,
            billLookup: { billID in billsByID[billID] },
            companions: snapshot.companions,
            historyWindow: snapshot.historyWindow
        )
    }
}
