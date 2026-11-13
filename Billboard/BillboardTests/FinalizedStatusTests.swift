import XCTest
@testable import Billboard

/// REL-44: the server marks a bill that became law `Finalized`. The app treats it as a decided outcome,
/// like Passed: off the Bills list, listed (and cleared) with Updates' passed bills, counted in the
/// Updates badge and the Passed list, a `.passed` item on Bills that opens with the vote bar (Civic Record
/// project decision 1), ranked like Passed in the on-device weekly brief, and shown as "Became law".
@MainActor
final class FinalizedStatusTests: XCTestCase {
    private static let house = "BILLS-119hjres131"
    private static let senate = "BILLS-119sjres91"
    private static let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
    private let companions = CompanionGroupIndex(groups: [FinalizedStatusTests.group])
    private let noVotes: (String) -> VoteState = { _ in .unknown }

    /// A recent bill with an active priority, so it matches the placeholder profile's feed and
    /// subscriptions without topics.
    private func bill(_ guid: String, _ status: BillStatus, hoursAgo: Double = 1, lastVotedAt: Date? = nil) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: "Bill \(guid)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 60 * 60)),
            billStatus: status,
            guid: guid,
            userVoted: false,
            lastVotedAt: lastVotedAt,
            isPriority: true
        )
    }

    private func queue(_ bills: [Bill], companions: CompanionGroupIndex = .empty) -> BillboardQueueSnapshot {
        BillboardQueueDerivation.snapshot(
            bills: bills,
            dismissedBillIDs: [],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteIndex: UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: noVotes, companions: companions),
            voteLookup: noVotes,
            starterFeedEnabled: false
        )
    }

    private func feed(_ bills: [Bill], dismissed: Set<UUID> = [], companions: CompanionGroupIndex = .empty) -> UpdatesFeedSnapshot {
        UpdatesDerivation.feedSnapshot(
            bills: bills,
            alerts: [],
            dismissedBillIDs: dismissed,
            readBillAlertIDs: [],
            userProfile: .placeholder(),
            voteLookup: noVotes,
            billLookup: { _ in nil },
            companions: companions
        )
    }

    // MARK: - The status

    func testFinalizedIsADecidedPassedOutcomeShownAsBecameLaw() {
        XCTAssertEqual(BillStatus(rawValue: "Finalized"), .finalized, "the wire value is unchanged")
        XCTAssertEqual(BillStatus.finalized.displayLabel, "Became law")
        XCTAssertEqual(BillStatus.passed.displayLabel, "Passed")
        XCTAssertEqual(BillStatus.failed.displayLabel, "Failed")
        XCTAssertEqual(BillStatus.new.displayLabel, "New")
        XCTAssertEqual(BillStatus.updated.displayLabel, "Updated")

        XCTAssertEqual([BillStatus.new, .updated, .passed, .finalized, .failed].filter(\.isDecided), [.passed, .finalized, .failed])
        XCTAssertEqual([BillStatus.new, .updated, .passed, .finalized, .failed].filter(\.isPassedOutcome), [.passed, .finalized])
    }

    func testAStoredFinalizedStatusIsNeverLoweredToPassed() {
        XCTAssertEqual(BillsStore.preferredBillStatus(incoming: .passed, existing: .finalized), .finalized)
        XCTAssertEqual(BillsStore.preferredBillStatus(incoming: .finalized, existing: .passed), .finalized)
    }

    // MARK: 1. The Bills list (Home queue)

    func testALawIsNotQueuedWithoutGroups() {
        let law = bill("BILLS-119hr1", .finalized)
        let passed = bill("BILLS-119hr2", .passed)
        let open = bill("BILLS-119hr3", .new)

        let snapshot = queue([law, passed, open])

        XCTAssertEqual(snapshot.pendingBills.map(\.guid), ["BILLS-119hr3"])
        XCTAssertEqual(snapshot.badgeCount, 1)
    }

    func testALawInNoGroupIsNotQueuedWithGroups() {
        // With a companion index the queue takes the grouped path; a bill in no group is checked on its own.
        let law = bill("BILLS-119hr1", .finalized)
        let open = bill("BILLS-119hr3", .updated)

        let snapshot = queue([law, open], companions: companions)

        XCTAssertEqual(snapshot.pendingBills.map(\.guid), ["BILLS-119hr3"])
    }

    func testAGroupWhoseMembersAreDecidedIsHiddenAndALawDoesNotHideAnOpenMember() {
        let bothDecided = queue([bill(Self.house, .finalized), bill(Self.senate, .passed)], companions: companions)
        XCTAssertEqual(bothDecided.pendingBills.map(\.guid), [], "every member is decided")

        let lawAndOpen = queue([bill(Self.house, .finalized), bill(Self.senate, .new)], companions: companions)
        XCTAssertEqual(lawAndOpen.pendingBills.map(\.guid), [Self.senate], "the card is the open member's")
    }

    // MARK: 2. Updates' "Passed bills" and Clear all

    func testUpdatesListsALawWithThePassedBills() {
        let law = bill("BILLS-119hr1", .finalized)
        let passed = bill("BILLS-119hr2", .passed)
        let failed = bill("BILLS-119hr3", .failed)
        let open = bill("BILLS-119hr4", .new)

        let snapshot = feed([law, passed, failed, open])

        XCTAssertEqual(snapshot.passedBills.map(\.guid), ["BILLS-119hr1", "BILLS-119hr2"])
        XCTAssertEqual(snapshot.failedBills.map(\.guid), ["BILLS-119hr3"])
    }

    func testClearAllOnPassedBillsReachesALaw() async {
        let law = bill("BILLS-119hr1", .finalized)
        let passed = bill("BILLS-119hr2", .passed)
        let (store, _, scope) = await makeCompanionStore(bills: [law, passed], groups: [])
        let readState = AppReadState(scope: .user("finalized-tests"), store: InMemoryReadStateStore())

        // What Updates' Clear all does with the listed passed bills (one undoable action).
        let listed = feed(store.bills).passedBills
        var receipt = SkipReceipt()
        for target in listed.map({ SkipTarget.closedBill($0.id) }) {
            receipt.append(store.skip(target, readState: readState))
        }

        XCTAssertEqual(Set(receipt.dismissedBillIDs), [law.id, passed.id])
        XCTAssertEqual(Set(receipt.pendingUnwatchBillIDs), [law.id, passed.id], "the law's watch goes when Clear commits")
        XCTAssertEqual(feed(store.bills, dismissed: readState.dismissedBillIDs).passedBills.map(\.guid), [])
        await settleBillsCache(scope: scope)
    }

    // MARK: 3. The Updates badge

    func testTheUpdatesBadgeCountsALaw() {
        let bills = [bill("BILLS-119hr1", .finalized), bill("BILLS-119hr2", .passed), bill("BILLS-119hr3", .new)]

        let count = UpdatesDerivation.badgeCount(
            bills: bills,
            alerts: [],
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: .placeholder(),
            unreadDigestCount: 0,
            voteLookup: noVotes,
            billLookup: { _ in nil }
        )

        XCTAssertEqual(count, 2)
    }

    // MARK: 4. Passed in your subscriptions (Search bills' Passed list, a row in Your lists)

    func testThePassedListListsALaw() {
        let now = Date()
        let law = bill("BILLS-119hr1", .finalized, lastVotedAt: now)
        let passed = bill("BILLS-119hr2", .passed, lastVotedAt: now.addingTimeInterval(-60))
        let failed = bill("BILLS-119hr3", .failed)
        let bills = [passed, law, failed]

        let listed = BillBoardDerivedCollections.passedSubscribed(bills: bills, profile: .placeholder(), companions: .empty)
        XCTAssertEqual(listed.map(\.guid), ["BILLS-119hr1", "BILLS-119hr2"])

        let derived = BillBoardDerivedCollections.derive(from: BillBoardDerivedCollections.Input(
            bills: bills,
            dismissedBillIDs: [],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteStatesByBillID: [:],
            starterFeedEnabled: false
        ))
        XCTAssertEqual(derived.passedSubscribed.map(\.guid), ["BILLS-119hr1", "BILLS-119hr2"])
    }

    func testThePassedListShowsOneEntryForAGroupThatBecameLaw() {
        let listed = BillBoardDerivedCollections.passedSubscribed(
            bills: [bill(Self.senate, .finalized), bill(Self.house, .finalized)],
            profile: .placeholder(),
            companions: companions
        )

        XCTAssertEqual(listed.map(\.guid), [Self.house])
    }

    // MARK: 5. The board item type

    func testALawIsADecidedItemThatOpensWithTheVoteBar() {
        let law = bill("BILLS-119hr1", .finalized)

        guard case .passed = BillBoardDerivedCollections.boardItemType(for: law) else {
            return XCTFail("a law is a decided item, like a passed bill")
        }
        let item = BillBoardDerivedCollections.boardItems(cards: [law], bills: [law], companions: .empty).first
        guard let item, case .passed = item.type else { return XCTFail("the Bills item is a decided item") }
        XCTAssertEqual(item.skipTarget, .closedBill(law.id))
        XCTAssertEqual(BillDetail.Mode(opening: item.type), .full, "voting stays open on a law (project decision 1)")
        guard case .updated = BillBoardDerivedCollections.boardItemType(for: bill("BILLS-119hr2", .updated)) else {
            return XCTFail("updated")
        }
        guard case .bill = BillBoardDerivedCollections.boardItemType(for: bill("BILLS-119hr3", .new)) else {
            return XCTFail("new")
        }
    }

    // MARK: Companion groups: the status lead

    func testTheStatusLeadSaysBecameLaw() {
        let primaryLaw = companions.statusLead(for: Self.group, memberBills: [bill(Self.house, .finalized), bill(Self.senate, .passed)])
        XCTAssertEqual(primaryLaw.status, .finalized)
        XCTAssertEqual(primaryLaw.label, "Became law")

        let partnerLaw = companions.statusLead(for: Self.group, memberBills: [bill(Self.house, .passed), bill(Self.senate, .finalized)])
        XCTAssertEqual(partnerLaw.guid, Self.senate)
        XCTAssertEqual(partnerLaw.label, "Became law · S.J.Res. 91")

        let passedPartner = companions.statusLead(for: Self.group, memberBills: [bill(Self.house, .new), bill(Self.senate, .passed)])
        XCTAssertEqual(passedPartner.label, "Passed · S.J.Res. 91", "the Passed label rule is unchanged")
    }

    // MARK: 6. The on-device weekly brief

    func testTheWeeklyBriefRanksALawLikeAPassedBill() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let moved = ISO8601DateFormatter().string(from: window.start.addingTimeInterval(24 * 60 * 60))
        func item(_ number: String, _ status: String) -> BillsManifestItem {
            BillsManifestItem(
                guid: "BILLS-119hr\(number)",
                congress: "119",
                billType: "hr",
                billID: number,
                updatedAt: moved,
                subCategories: ["Energy"],
                lifeAreas: [],
                sponsors: [],
                cosponsors: [],
                title: "Bill \(number)",
                billStatus: status
            )
        }
        let bills = FakeBillsService()
        // The bills are not hydrated (`getProcessedBill` fails), so each item uses its manifest row.
        bills.manifestResults = [.success([
            item("1", "New"),
            item("2", "Updated"),
            item("3", "Finalized"),
            item("4", "Passed"),
            item("5", "New")
        ])]
        let suite = "finalized-digest-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        let store = WeeklyDigestStore(
            scope: "finalized-digest",
            defaults: defaults,
            digestService: EmptyWeeklyDigestService(),
            billsService: bills,
            votesService: FakeBillVotesService(),
            congressService: FakeCongressService()
        )
        let profile = UserProfile.placeholder().updating(id: "user-1", subscribedSubCategories: ["Energy"])

        await store.refresh(profile: profile, forceRefresh: true)

        let digest = try XCTUnwrap(store.digest)
        let attention = try XCTUnwrap(digest.sections.first { $0.kind == .needsAttention })
        XCTAssertEqual(
            attention.items.compactMap(\.billGuid),
            ["BILLS-119hr3", "BILLS-119hr4"],
            "the law and the passed bill need attention and rank first (equal score, then title)"
        )
        let movedSection = try XCTUnwrap(digest.sections.first { $0.kind == .movedThisWeek })
        XCTAssertEqual(movedSection.items.first?.billGuid, "BILLS-119hr2", "the updated bill ranks next")
        let law = try XCTUnwrap(attention.items.first)
        XCTAssertEqual(law.billState, .finalized)
        XCTAssertEqual(law.billState?.title, "Became law")
        XCTAssertTrue(law.eyebrow?.hasPrefix("Became law ") == true, law.eyebrow ?? "no eyebrow")
        XCTAssertEqual(law.detail, "Became law this week.")
        XCTAssertEqual(law.reason, "Matches your topic: Energy")
    }

    func testTheBriefsStateWordsMatchTheBillCards() {
        XCTAssertEqual(WeeklyDigestItem.BillState.finalized.title, "Became law")
        XCTAssertEqual(WeeklyDigestItem.BillState.passed.title, "Passed")
        XCTAssertEqual(WeeklyDigestItem.BillState.failed.title, "Failed")
    }
}
