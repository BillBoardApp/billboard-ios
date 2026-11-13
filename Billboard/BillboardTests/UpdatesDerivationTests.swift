import XCTest
@testable import Billboard

/// Which bills a vote hides from the Home queue, the Updates feed and the badges. APPF-24 (R1): the
/// vote identity is the bill's `BillsStore.BillIdentityKey` (congress, type, number), so a vote on
/// H.R. 4500 no longer hides S. 4500, and there is no title fallback. With companion groups (APPF-23)
/// a vote on one member hides every member.
@MainActor
final class UpdatesDerivationTests: XCTestCase {
    private func bill(
        _ guid: String?,
        title: String = "Protecting Veterans Act",
        status: BillStatus = .new,
        congress: String? = "119",
        type: String?,
        number: String?,
        userVote: UserVote? = nil,
        hoursAgo: Double = 1
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid ?? title + (type ?? "") + (number ?? "")),
            title: title,
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 60 * 60)),
            billStatus: status,
            guid: guid,
            congress: congress,
            billType: type,
            billID: number,
            userVoted: userVote?.countsAsVote == true,
            userVote: userVote,
            isPriority: true
        )
    }

    private let noVotes: (String) -> VoteState = { _ in .unknown }

    // MARK: - Identity key (R1)

    func testIdentityKeyUsesTheBillTypeAndNeverTheTitle() {
        let house = bill("BILLS-119hr4500", type: "hr", number: "4500")
        let senate = bill("BILLS-119s4500", type: "s", number: "4500")
        let slug = bill("BILLS-119hr4500ih", type: "house-bill", number: "04500")
        let guidOnly = bill("BILLS-119hr4500", congress: nil, type: nil, number: nil)
        let untyped = bill(nil, type: nil, number: "4500")

        XCTAssertEqual(UpdatesDerivation.logicalVoteIdentityKey(for: house), "119|hr|4500")
        XCTAssertNotEqual(UpdatesDerivation.logicalVoteIdentityKey(for: house), UpdatesDerivation.logicalVoteIdentityKey(for: senate))
        XCTAssertEqual(UpdatesDerivation.logicalVoteIdentityKey(for: slug), "119|hr|4500", "a legacy text-version item is the same bill")
        XCTAssertEqual(UpdatesDerivation.logicalVoteIdentityKey(for: guidOnly), "119|hr|4500", "missing fields come from the guid")
        XCTAssertNil(UpdatesDerivation.logicalVoteIdentityKey(for: untyped), "no title fallback")
    }

    func testVoteOnHR4500NoLongerHidesS4500() {
        let house = bill("BILLS-119hr4500", type: "hr", number: "4500", userVote: .yea)
        let senate = bill("BILLS-119s4500", type: "s", number: "4500")
        let index = UpdatesDerivation.voteIdentityIndex(for: [house, senate], voteLookup: noVotes)

        XCTAssertTrue(UpdatesDerivation.isUserVoted(house, voteIndex: index, voteLookup: noVotes))
        XCTAssertFalse(UpdatesDerivation.isUserVoted(senate, voteIndex: index, voteLookup: noVotes))

        let queue = BillboardQueueDerivation.snapshot(
            bills: [house, senate],
            dismissedBillIDs: [],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteIndex: index,
            voteLookup: noVotes
        )
        XCTAssertEqual(queue.pendingBills.map(\.guid), ["BILLS-119s4500"])
    }

    func testBillsSharingATitleWithoutIdentityAreNotHiddenByEachOther() {
        let voted = bill(nil, title: "Same Title", congress: "119", type: nil, number: nil, userVote: .nay)
        let other = bill(nil, title: "same title ", congress: "119", type: nil, number: "12")
        let index = UpdatesDerivation.voteIdentityIndex(for: [voted, other], voteLookup: noVotes)

        XCTAssertFalse(UpdatesDerivation.isUserVoted(other, voteIndex: index, voteLookup: noVotes))
    }

    func testVoteOnALegacyTextVersionGuidHidesThePlainBill() {
        let legacy = bill("BILLS-119hr6512ih", type: "house-bill", number: "6512", userVote: .yea)
        let current = bill("BILLS-119hr6512", type: "hr", number: "6512")
        let index = UpdatesDerivation.voteIdentityIndex(for: [legacy, current], voteLookup: noVotes)

        XCTAssertTrue(UpdatesDerivation.isUserVoted(current, voteIndex: index, voteLookup: noVotes))
    }

    // MARK: - Companion groups

    private let companions = CompanionGroupIndex(groups: [
        BillCompanionGroup(primaryGuid: "BILLS-119hr900", memberGuids: ["BILLS-119hr900", "BILLS-119s456"], relationship: "identical")
    ])

    func testAVoteOnOneMemberHidesEveryMemberFromTheFeed() {
        let house = bill("BILLS-119hr900", status: .passed, type: "hr", number: "900")
        let senate = bill("BILLS-119s456", status: .passed, type: "s", number: "456", userVote: .yea)
        let other = bill("BILLS-119hr1", status: .passed, type: "hr", number: "1")
        let bills = [house, senate, other]
        let profile = UserProfile.placeholder()

        let grouped = UpdatesDerivation.feedSnapshot(
            bills: bills,
            alerts: [],
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: profile,
            voteLookup: noVotes,
            billLookup: { _ in nil },
            companions: companions
        )
        XCTAssertEqual(grouped.passedBills.map(\.guid), ["BILLS-119hr1"])

        // Without groups each bill stands alone.
        let perBill = UpdatesDerivation.feedSnapshot(
            bills: bills,
            alerts: [],
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: profile,
            voteLookup: noVotes,
            billLookup: { _ in nil }
        )
        XCTAssertEqual(perBill.passedBills.map(\.guid), ["BILLS-119hr900", "BILLS-119hr1"])
    }

    func testAVoteKnownOnlyToTheVoteStoreHidesTheGroup() {
        // The Senate bill is not in the list; its vote is in the vote store.
        let house = bill("BILLS-119hr900", type: "hr", number: "900")
        let lookup: (String) -> VoteState = { $0 == "BILLS-119s456" ? .voted(.nay) : .unknown }
        let index = UpdatesDerivation.voteIdentityIndex(for: [house], voteLookup: lookup, companions: companions)

        XCTAssertTrue(UpdatesDerivation.isUserVoted(house, voteIndex: index, voteLookup: lookup))
        let withoutGroups = UpdatesDerivation.voteIdentityIndex(for: [house], voteLookup: lookup)
        XCTAssertFalse(UpdatesDerivation.isUserVoted(house, voteIndex: withoutGroups, voteLookup: lookup))
    }

    func testGroupedQueueCountsOneCardPerGroup() {
        let bills = [
            bill("BILLS-119hr900", type: "hr", number: "900"),
            bill("BILLS-119s456", status: .updated, type: "s", number: "456"),
            bill("BILLS-119hr1", status: .updated, type: "hr", number: "1")
        ]
        let index = UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: noVotes, companions: companions)

        let queue = BillboardQueueDerivation.snapshot(
            bills: bills,
            dismissedBillIDs: [],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteIndex: index,
            voteLookup: noVotes
        )

        XCTAssertEqual(queue.pendingBills.map(\.guid), ["BILLS-119hr900", "BILLS-119hr1"])
        XCTAssertEqual(queue.newCount, 1, "the card's own status counts")
        XCTAssertEqual(queue.updatedCount, 1)
        XCTAssertEqual(queue.badgeCount, 2)
    }

    // MARK: - Closed members (the card is an open member)

    private func queue(_ bills: [Bill], votes: [String: VoteState] = [:], groups: CompanionGroupIndex? = nil) -> [String?] {
        let lookup: (String) -> VoteState = { votes[$0] ?? .unknown }
        let index = UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: lookup, companions: groups ?? companions)
        return BillboardQueueDerivation.snapshot(
            bills: bills,
            dismissedBillIDs: [],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteIndex: index,
            voteLookup: lookup
        ).pendingBills.map(\.guid)
    }

    func testAClosedHouseMemberDoesNotHideItsOpenSenateCompanion() {
        let monthAgo = 30.0 * 24
        // The House bill passed a month ago (loaded as the partner); the Senate bill is new this week.
        let houseClosed = bill("BILLS-119hr900", status: .passed, type: "hr", number: "900", hoursAgo: monthAgo)
        let senateOpen = bill("BILLS-119s456", type: "s", number: "456")
        XCTAssertEqual(queue([senateOpen, houseClosed]), ["BILLS-119s456"], "the open Senate bill is the card")
        XCTAssertEqual(queue([senateOpen]), ["BILLS-119s456"])

        // The reverse: the Senate bill passed this week and the open House bill is the partner.
        let houseOpen = bill("BILLS-119hr900", type: "hr", number: "900", hoursAgo: monthAgo)
        let senateClosed = bill("BILLS-119s456", status: .passed, type: "s", number: "456")
        XCTAssertEqual(queue([senateClosed, houseOpen]), ["BILLS-119hr900"])

        // Symmetric when the closed member is the one in the window.
        let houseClosedRecent = bill("BILLS-119hr900", status: .failed, type: "hr", number: "900")
        let senateOpenOld = bill("BILLS-119s456", type: "s", number: "456", hoursAgo: monthAgo)
        XCTAssertEqual(queue([houseClosedRecent, senateOpenOld]), ["BILLS-119s456"])

        // Every member closed: no card; a vote on any member still hides the group.
        XCTAssertEqual(queue([houseClosed, senateClosed]), [])
        XCTAssertEqual(queue([senateOpen, houseClosed], votes: ["BILLS-119hr900": .voted(.nay)]), [])

        // Without groups each bill stands alone: the closed House bill is not queued.
        XCTAssertEqual(queue([senateOpen, houseClosed], groups: .empty), ["BILLS-119s456"])
        XCTAssertEqual(queue([houseClosedRecent, senateOpenOld], groups: .empty), [])
    }

    // MARK: - Tab badges (TabBadgeCalculator)

    private func badgeSnapshot(
        bills: [Bill],
        alerts: [BillAlert] = [],
        votes: [String: VoteState] = [:],
        groups: CompanionGroupIndex
    ) -> TabBadgeCalculator.Snapshot {
        TabBadgeCalculator.Snapshot(
            activeManifestBills: bills,
            allBills: bills,
            alerts: alerts,
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: .placeholder(),
            unreadDigestCount: 0,
            historyWindow: .oneWeek,
            voteStatesByBillID: votes,
            companions: groups
        )
    }

    private func alert(on bill: Bill) -> BillAlert {
        BillAlert(
            id: UUID(),
            sponsorMemberID: nil,
            billID: bill.id,
            title: "Update",
            category: "Other",
            summary: "",
            soWhat: "",
            lifeAreas: [],
            subCategory: nil,
            alertText: nil,
            actionDate: nil,
            actionCode: nil,
            actionType: nil,
            date: Date()
        )
    }

    func testHomeBadgeCountsOneCardPerGroupLikeHome() {
        let house = bill("BILLS-119hr900", type: "hr", number: "900")
        let senate = bill("BILLS-119s456", type: "s", number: "456")
        let other = bill("BILLS-119hr1", type: "hr", number: "1")
        let bills = [house, senate, other]

        XCTAssertEqual(TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, groups: companions)).home, 2, "one per group")
        XCTAssertEqual(TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, groups: .empty)).home, 3, "without groups: per bill")

        // A vote on the group is written to the House bill only; the Senate bill no longer counts.
        let voted = ["BILLS-119hr900": VoteState.voted(.yea)]
        XCTAssertEqual(TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, votes: voted, groups: companions)).home, 1)
        XCTAssertEqual(TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, votes: voted, groups: .empty)).home, 2)

        // The Senate bill passed this week and the open House bill is its out-of-window partner: Home
        // shows the group's card, so the badge counts it.
        let monthAgo = 30.0 * 24
        let reverse = [
            bill("BILLS-119s456", status: .passed, type: "s", number: "456"),
            bill("BILLS-119hr900", type: "hr", number: "900", hoursAgo: monthAgo)
        ]
        XCTAssertEqual(TabBadgeCalculator.counts(for: badgeSnapshot(bills: reverse, groups: companions)).home, 1)
    }

    func testUpdatesBadgeDropsTheOtherMemberAfterAVote() {
        let house = bill("BILLS-119hr900", type: "hr", number: "900")
        let senate = bill("BILLS-119s456", status: .passed, type: "s", number: "456")
        let bills = [house, senate]
        let alerts = [alert(on: senate)]
        let voted = ["BILLS-119hr900": VoteState.voted(.yea)]

        XCTAssertEqual(TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, alerts: alerts, groups: companions)).updates, 2)
        XCTAssertEqual(
            TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, alerts: alerts, votes: voted, groups: companions)).updates,
            0,
            "the vote on H.R. 900 covers S. 456's Passed row and its alert"
        )
        XCTAssertEqual(
            TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, alerts: alerts, votes: voted, groups: .empty)).updates,
            2,
            "without groups each bill stands alone"
        )
    }

    // MARK: - Out-of-window partners in Updates

    func testUpdatesSkipsAnOutOfWindowPartnerUnlessWatched() {
        let monthAgo = 30.0 * 24
        // H.R. 900 moved this week; S. 456 passed a month ago and is loaded only as its partner.
        let house = bill("BILLS-119hr900", type: "hr", number: "900")
        let oldPartner = bill("BILLS-119s456", status: .passed, type: "s", number: "456", hoursAgo: monthAgo)
        let oldUngrouped = bill("BILLS-119hr1", status: .passed, type: "hr", number: "1", hoursAgo: monthAgo)
        let bills = [house, oldPartner, oldUngrouped]
        func passed(_ bills: [Bill], groups: CompanionGroupIndex) -> [String?] {
            UpdatesDerivation.feedSnapshot(
                bills: bills,
                alerts: [],
                dismissedBillIDs: [],
                readBillAlertIDs: [],
                userProfile: .placeholder(),
                voteLookup: noVotes,
                billLookup: { _ in nil },
                companions: groups,
                historyWindow: .oneWeek
            ).passedBills.map(\.guid)
        }

        XCTAssertEqual(passed(bills, groups: companions), ["BILLS-119hr1"], "the ungrouped bill is listed as before")
        XCTAssertEqual(TabBadgeCalculator.counts(for: badgeSnapshot(bills: bills, groups: companions)).updates, 1)
        XCTAssertEqual(passed(bills, groups: .empty), ["BILLS-119s456", "BILLS-119hr1"], "without groups: unchanged")

        var watchedPartner = oldPartner
        watchedPartner.userWatched = true
        XCTAssertEqual(passed([house, watchedPartner], groups: companions), ["BILLS-119s456"], "a watched partner is listed")
    }

    // MARK: - Starter feed (spec D 2.5.4) is a Bills-tab rule only

    func testTheStarterFeedWidensTheBillsQueueButNotUpdates() {
        let starter = UserProfile.placeholder().updating(id: "user-1")
        var open = bill("BILLS-119hr1", type: "hr", number: "1")
        open.isPriority = false
        var passed = bill("BILLS-119hr2", status: .passed, type: "hr", number: "2")
        passed.isPriority = false
        let bills = [open, passed]
        let index = UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: noVotes)
        func queue(_ profile: UserProfile, enabled: Bool = true) -> [String?] {
            BillboardQueueDerivation.snapshot(
                bills: bills,
                dismissedBillIDs: [],
                userProfile: profile,
                historyWindow: .oneWeek,
                voteIndex: index,
                voteLookup: noVotes,
                starterFeedEnabled: enabled
            ).pendingBills.map(\.guid)
        }

        XCTAssertEqual(queue(starter), ["BILLS-119hr1"], "a not-in-the-news bill reaches a no-topic profile")
        XCTAssertEqual(queue(starter, enabled: false), [], "R1 rule with the flag off")
        XCTAssertEqual(queue(.placeholder()), [], "the placeholder profile keeps the R1 rule")

        let feed = UpdatesDerivation.feedSnapshot(
            bills: bills,
            alerts: [],
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: starter,
            voteLookup: noVotes,
            billLookup: { _ in nil }
        )
        XCTAssertEqual(feed.passedBills.map(\.guid), [], "Updates still lists only bills the profile follows or in the news")
    }

    func testAClearedRowLeavesTheUpdatesFeedAndBadge() {
        let passed = bill("BILLS-119hr2", status: .passed, type: "hr", number: "2")
        let alerts = [alert(on: passed)]
        func snapshot(dismissed: Set<UUID>, read: Set<UUID>) -> (feed: UpdatesFeedSnapshot, badge: Int) {
            let feed = UpdatesDerivation.feedSnapshot(
                bills: [passed],
                alerts: alerts,
                dismissedBillIDs: dismissed,
                readBillAlertIDs: read,
                userProfile: .placeholder(),
                voteLookup: noVotes,
                billLookup: { $0 == passed.id ? passed : nil }
            )
            let badge = UpdatesDerivation.badgeCount(
                bills: [passed],
                alerts: alerts,
                dismissedBillIDs: dismissed,
                readBillAlertIDs: read,
                userProfile: .placeholder(),
                unreadDigestCount: 0,
                voteLookup: noVotes,
                billLookup: { $0 == passed.id ? passed : nil }
            )
            return (feed, badge)
        }

        let before = snapshot(dismissed: [], read: [])
        XCTAssertEqual(before.feed.passedBills.count, 1)
        XCTAssertEqual(before.feed.activeAlerts.count, 1)
        XCTAssertEqual(before.badge, 2)

        let cleared = snapshot(dismissed: [passed.id], read: [alerts[0].id])
        XCTAssertEqual(cleared.feed.passedBills.count, 0)
        XCTAssertEqual(cleared.feed.activeAlerts.count, 0)
        XCTAssertEqual(cleared.badge, 0)
    }

    // MARK: - The Updates badge counts the list's rows (feature review N5)

    /// The badge used to filter on its own: it ignored the bill-type setting for Passed and Failed bills and
    /// counted alerts on bills outside the user's topics, which the list hides, so it could say 5 over a list
    /// of NOTHING YET. It now counts exactly the list's rows, plus 1 for an unread Weekly Brief.
    func testTheUpdatesBadgeCountsExactlyTheRowsTheListShows() {
        // Follows Energy, with Other resolutions switched off.
        let profile = UserProfile.placeholder().updating(
            id: "user-1",
            subscribedSubCategories: ["Energy"],
            selectedBillContentTypes: [.bills, .jointResolutions]
        )
        func make(_ guid: String, _ status: BillStatus, type: String, number: String, topic: String = "Energy") -> Bill {
            Bill(
                id: UUID.deterministic(from: guid),
                title: "Bill \(number)",
                category: topic,
                subCategory: topic,
                soWhat: "",
                storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
                billStatus: status,
                guid: guid,
                congress: "119",
                billType: type,
                billID: number,
                userVoted: false
            )
        }
        let passedBill = make("BILLS-119hr1", .passed, type: "hr", number: "1")
        let passedResolution = make("BILLS-119hres2", .passed, type: "hres", number: "2")
        let failedBill = make("BILLS-119s3", .failed, type: "s", number: "3")
        let failedOtherTopic = make("BILLS-119hr4", .failed, type: "hr", number: "4", topic: "Health")
        let actedOn = make("BILLS-119hr5", .updated, type: "hr", number: "5")
        let actedOnOtherTopic = make("BILLS-119hr6", .updated, type: "hr", number: "6", topic: "Health")
        let actedOnResolution = make("BILLS-119hres7", .updated, type: "hres", number: "7")
        let bills = [passedBill, passedResolution, failedBill, failedOtherTopic, actedOn, actedOnOtherTopic, actedOnResolution]
        // An alert whose bill the app has not loaded is listed (and counted) as it is.
        let unloaded = BillAlert(
            id: UUID(), sponsorMemberID: nil, billID: nil, title: "Update", category: "Other", summary: "", soWhat: "",
            lifeAreas: [], subCategory: nil, alertText: nil, actionDate: nil, actionCode: nil, actionType: nil, date: Date()
        )
        let alerts = [alert(on: actedOn), alert(on: actedOnOtherTopic), alert(on: actedOnResolution), unloaded]
        let billsByID = Dictionary(uniqueKeysWithValues: bills.map { ($0.id, $0) })

        let feed = UpdatesDerivation.feedSnapshot(
            bills: bills,
            alerts: alerts,
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: profile,
            voteLookup: noVotes,
            billLookup: { billsByID[$0] },
            historyWindow: .oneWeek
        )
        XCTAssertEqual(feed.passedBills.map(\.guid), ["BILLS-119hr1"], "the resolution is off in the bill-type setting")
        XCTAssertEqual(feed.failedBills.map(\.guid), ["BILLS-119s3"], "Health is not followed")
        XCTAssertEqual(feed.activeAlerts.map(\.id), [alerts[0].id, unloaded.id], "alerts on hidden bills are not listed")
        XCTAssertEqual(feed.rowCount, 4)

        func badge(unreadDigestCount: Int) -> Int {
            let snapshot = TabBadgeCalculator.Snapshot(
                activeManifestBills: bills,
                allBills: bills,
                alerts: alerts,
                dismissedBillIDs: [],
                readBillAlertIDs: [],
                userProfile: profile,
                unreadDigestCount: unreadDigestCount,
                historyWindow: .oneWeek,
                voteStatesByBillID: [:]
            )
            return TabBadgeCalculator.counts(for: snapshot).updates
        }
        XCTAssertEqual(badge(unreadDigestCount: 0), feed.rowCount, "was 7: the resolution, the Health bill and their alerts")
        XCTAssertEqual(badge(unreadDigestCount: 1), feed.rowCount + 1, "an unread Weekly Brief adds 1")

        // With nothing listed, there is nothing to count: the badge is empty over NOTHING YET.
        let caughtUp = UpdatesDerivation.badgeCount(
            bills: [passedResolution, failedOtherTopic, actedOnOtherTopic],
            alerts: [alert(on: actedOnOtherTopic)],
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: profile,
            unreadDigestCount: 0,
            voteLookup: noVotes,
            billLookup: { billsByID[$0] }
        )
        XCTAssertEqual(caughtUp, 0)
    }
}
