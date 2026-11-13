import Foundation
import XCTest
@testable import Billboard

/// The starter feed (spec D 2.5.4): a profile that follows no topics and no life areas sees new bills
/// (in the window, allowed by the bill-type setting, plus every bill in the news),
/// in Home order with followed members' bills pulled forward after the news, capped at 15 cards;
/// the Bills badge counts the same list.
@MainActor
final class StarterFeedTests: XCTestCase {
    private let starter = UserProfile.placeholder().updating(id: "user-1")

    private func bill(
        _ guid: String,
        status: BillStatus = .new,
        hoursAgo: Double = 1,
        billType: String? = "hr",
        isPriority: Bool = false,
        priorityRank: Int? = nil,
        topic: String = "Energy",
        sponsor: UUID? = nil
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: "Bill \(guid)",
            category: "Other",
            subCategory: topic,
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 60 * 60)),
            billStatus: status,
            guid: guid,
            congress: "119",
            billType: billType,
            sponsorMemberID: sponsor,
            userVoted: false,
            isPriority: isPriority,
            priorityRank: priorityRank
        )
    }

    private func derive(
        _ bills: [Bill],
        profile: UserProfile,
        dismissed: Set<UUID> = [],
        votes: [String: VoteState] = [:],
        companions: CompanionGroupIndex = .empty,
        enabled: Bool = true
    ) -> BillBoardDerivedCollections {
        BillBoardDerivedCollections.derive(from: BillBoardDerivedCollections.Input(
            bills: bills,
            dismissedBillIDs: dismissed,
            userProfile: profile,
            historyWindow: .oneWeek,
            voteStatesByBillID: votes,
            companions: companions,
            starterFeedEnabled: enabled
        ))
    }

    private func homeBadge(
        _ bills: [Bill],
        profile: UserProfile,
        dismissed: Set<UUID> = [],
        companions: CompanionGroupIndex = .empty
    ) -> Int {
        TabBadgeCalculator.counts(for: TabBadgeCalculator.Snapshot(
            activeManifestBills: bills,
            allBills: bills,
            alerts: [],
            dismissedBillIDs: dismissed,
            readBillAlertIDs: [],
            userProfile: profile,
            unreadDigestCount: 0,
            historyWindow: .oneWeek,
            voteStatesByBillID: [:],
            companions: companions
        )).home
    }

    // MARK: - When it applies

    func testItAppliesOnlyToASignedInProfileWithNoTopicsAndNoLifeAreas() {
        XCTAssertTrue(StarterFeed.isActive(for: starter))
        XCTAssertTrue(StarterFeed.isActive(for: starter.updating(subscribedMemberIDs: [UUID()])), "members do not count")
        XCTAssertTrue(StarterFeed.isActive(for: starter.updating(subscribedSubCategories: [" "])), "a blank topic is no topic")
        XCTAssertFalse(StarterFeed.isActive(for: starter.updating(subscribedSubCategories: ["Energy"])))
        XCTAssertFalse(StarterFeed.isActive(for: starter.updating(subscribedLifeAreas: ["Health"])))
        XCTAssertFalse(StarterFeed.isActive(for: .placeholder()), "the profile has not loaded")
        XCTAssertFalse(StarterFeed.isActive(for: starter, isEnabled: false), "FeatureFlags.starterFeed off")
        XCTAssertEqual(StarterFeed.cardLimit, 15)
    }

    // MARK: - Eligibility

    func testEligibilityTruthTable() {
        let news = bill("BILLS-119sres1", billType: "sres", isPriority: true)
        let plain = bill("BILLS-119hr2")
        let resolution = bill("BILLS-119hres3", billType: "hres")
        let old = bill("BILLS-119hr4", hoursAgo: 10 * 24)
        let oldNews = bill("BILLS-119hr5", hoursAgo: 10 * 24, isPriority: true)
        let voted = bill("BILLS-119hr6")
        let skipped = bill("BILLS-119hr7")
        let passed = bill("BILLS-119hr8", status: .passed)
        let bills = [news, plain, resolution, old, oldNews, voted, skipped, passed]
        let billsOnly = starter.updating(selectedBillContentTypes: [.bills])

        let shown = derive(bills, profile: billsOnly, dismissed: [skipped.id], votes: ["BILLS-119hr6": .voted(.yea)])

        XCTAssertTrue(shown.isStarterFeed)
        XCTAssertEqual(
            Set(shown.liveBoardItems.compactMap(\.bill.guid)),
            ["BILLS-119sres1", "BILLS-119hr2"],
            "in the window, not voted, not skipped, open, and in the news or allowed by the bill types"
        )

        // Every bill type allowed (the default): the resolution shows too.
        XCTAssertEqual(
            Set(derive(bills, profile: starter, dismissed: [skipped.id], votes: ["BILLS-119hr6": .voted(.yea)]).liveBoardItems.compactMap(\.bill.guid)),
            ["BILLS-119sres1", "BILLS-119hr2", "BILLS-119hres3"]
        )
    }

    func testAProfileWithTopicsKeepsTheTopicFeed() {
        let matching = bill("BILLS-119hr1", topic: "Energy")
        let other = bill("BILLS-119hr2", topic: "Housing")
        let news = bill("BILLS-119hr3", isPriority: true, topic: "Housing")
        let following = starter.updating(subscribedSubCategories: ["Energy"])

        let derived = derive([matching, other, news], profile: following)

        XCTAssertFalse(derived.isStarterFeed)
        XCTAssertEqual(Set(derived.liveBoardItems.compactMap(\.bill.guid)), ["BILLS-119hr1", "BILLS-119hr3"])
        // With the flag off, a no-topic profile also keeps R1's list: only bills in the news.
        XCTAssertEqual(derive([matching, other, news], profile: starter, enabled: false).liveBoardItems.compactMap(\.bill.guid), ["BILLS-119hr3"])
    }

    // MARK: - Order and cap

    /// Never by vote count (INT-11): the starter feed is in the news, then followed members, then newest.
    func testOrderIsNewsThenFollowedMembersThenNewest() {
        let member = UUID()
        let bills = [
            bill("BILLS-119hr1", hoursAgo: 1),
            bill("BILLS-119hr2", hoursAgo: 2),
            bill("BILLS-119hr3", hoursAgo: 3, sponsor: member),
            bill("BILLS-119hr4", hoursAgo: 4, isPriority: true, priorityRank: 2),
            bill("BILLS-119hr5", hoursAgo: 5, isPriority: true, priorityRank: 1),
            bill("BILLS-119hr6", hoursAgo: 6, sponsor: member),
            bill("BILLS-119hr7", hoursAgo: 0.5)
        ]
        let profile = starter.updating(subscribedMemberIDs: [member])

        XCTAssertEqual(derive(bills, profile: profile).liveBoardItems.compactMap(\.bill.guid), [
            "BILLS-119hr5", "BILLS-119hr4",                  // in the news, by rank
            "BILLS-119hr3", "BILLS-119hr6",                  // followed members' bills, newest first
            "BILLS-119hr7", "BILLS-119hr1", "BILLS-119hr2"   // then the newest
        ])
        // Without the followed member, the member's bills take their usual place.
        XCTAssertEqual(derive(bills, profile: starter).liveBoardItems.compactMap(\.bill.guid), [
            "BILLS-119hr5", "BILLS-119hr4", "BILLS-119hr7", "BILLS-119hr1", "BILLS-119hr2", "BILLS-119hr3", "BILLS-119hr6"
        ])
    }

    func testTheListIsCappedAt15AndTheBadgeCountsTheSameCards() {
        // 20 eligible bills: 3 updated among the 15 newest, 2 more updated beyond the cap.
        let bills = (1...20).map { index in
            bill("BILLS-119hr\(index)", status: [3, 7, 11, 17, 19].contains(index) ? .updated : .new, hoursAgo: Double(index))
        }

        let derived = derive(bills, profile: starter)

        XCTAssertEqual(derived.liveBoardItems.count, 15)
        XCTAssertEqual(derived.liveBoardItems.first?.bill.guid, "BILLS-119hr1")
        XCTAssertEqual(derived.liveBoardItems.last?.bill.guid, "BILLS-119hr15")
        XCTAssertEqual(derived.snapshot.pendingBills.count, 15)
        XCTAssertEqual(derived.snapshot.updatedCount, 3)
        XCTAssertEqual(derived.snapshot.newCount, 12)
        XCTAssertEqual(homeBadge(bills, profile: starter), derived.snapshot.badgeCount)
        XCTAssertEqual(homeBadge(bills, profile: starter), 15)

        // Skipping a card brings the 16th in; the badge follows.
        let dismissed: Set<UUID> = [bills[0].id]
        let afterSkip = derive(bills, profile: starter, dismissed: dismissed)
        XCTAssertEqual(afterSkip.liveBoardItems.count, 15)
        XCTAssertEqual(afterSkip.liveBoardItems.last?.bill.guid, "BILLS-119hr16")
        XCTAssertEqual(homeBadge(bills, profile: starter, dismissed: dismissed), afterSkip.snapshot.badgeCount)

        // A topic feed is not capped.
        let topicFeed = starter.updating(subscribedSubCategories: ["Energy"])
        XCTAssertEqual(derive(bills, profile: topicFeed).liveBoardItems.count, 20)
        XCTAssertEqual(homeBadge(bills, profile: topicFeed), 20)
    }

    func testABadgeCountsOnlyNewAndUpdatedCardsWithinTheCap() {
        // A bill that became law (Finalized) is decided, like Passed (REL-44): off the list and out of
        // the badge, as on the topic feed. The new and updated cards fill the cap.
        let bills = (1...18).map { index in
            bill("BILLS-119hr\(index)", status: index <= 2 ? .finalized : (index == 3 ? .updated : .new), hoursAgo: Double(index))
        }
        let derived = derive(bills, profile: starter)

        XCTAssertEqual(derived.liveBoardItems.count, 15)
        XCTAssertFalse(derived.liveBoardItems.contains { $0.bill.billStatus.isDecided })
        XCTAssertEqual(derived.liveBoardItems.first?.bill.guid, "BILLS-119hr3")
        XCTAssertEqual(derived.snapshot.badgeCount, 15)
        XCTAssertEqual(homeBadge(bills, profile: starter), 15)
    }

    func testAGroupCardIsOneCardAndAFollowedMemberOnEitherBillPullsItForward() {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let member = UUID()
        let bills = [
            bill("BILLS-119hr1", hoursAgo: 1),
            bill(house, hoursAgo: 5),
            bill(senate, billType: "s", sponsor: member)
        ]
        let companions = CompanionGroupIndex(groups: [group])
        let profile = starter.updating(subscribedMemberIDs: [member])

        let derived = derive(bills, profile: profile, companions: companions)

        XCTAssertEqual(derived.liveBoardItems.compactMap(\.bill.guid), [house, "BILLS-119hr1"], "the Senate sponsor counts for the group")
        XCTAssertEqual(derived.liveBoardItems.first?.companionGroup, group)
        XCTAssertEqual(homeBadge(bills, profile: profile, companions: companions), 2)
    }

    // MARK: - Banner storage (FirstRunStorage, D0)

    func testTheBannerHidesForSevenDaysPerUser() throws {
        let suite = "starter-feed-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let now = Date()

        XCTAssertFalse(FirstRunStorage.isStarterBannerHidden(userID: "user-1", now: now, defaults: defaults))
        FirstRunStorage.hideStarterBanner(userID: "user-1", now: now, defaults: defaults)

        XCTAssertTrue(FirstRunStorage.isStarterBannerHidden(userID: "user-1", now: now.addingTimeInterval(6 * 24 * 60 * 60), defaults: defaults))
        XCTAssertFalse(FirstRunStorage.isStarterBannerHidden(userID: "user-1", now: now.addingTimeInterval(7 * 24 * 60 * 60 + 1), defaults: defaults))
        XCTAssertFalse(FirstRunStorage.isStarterBannerHidden(userID: "user-2", now: now, defaults: defaults))
    }
}
