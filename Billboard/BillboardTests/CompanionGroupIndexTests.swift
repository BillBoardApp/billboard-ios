import XCTest
@testable import Billboard

/// Companion bills (APPF-23): identical House and Senate bills shown as one. `CompanionGroupIndex`
/// looks groups up by guid and by bill identity, labels them, picks the status lead and applies the
/// vote matrix; `BillsStore` writes a group's vote to one member, and Home shows one card per group.
final class CompanionGroupIndexTests: XCTestCase {
    private static let house = "BILLS-119hr900"
    private static let senate = "BILLS-119s456"
    private let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")

    private func bill(
        _ guid: String,
        title: String = "A bill",
        status: BillStatus = .new,
        storedAt: String? = "2026-09-20T11:00:00.000Z",
        isPriority: Bool = false,
        priorityRank: Int? = nil,
        userVote: UserVote? = nil,
        congress: String? = nil,
        billType: String? = nil,
        billID: String? = nil
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: "Other",
            soWhat: "",
            storedAt: storedAt,
            billStatus: status,
            guid: guid,
            congress: congress,
            billType: billType,
            billID: billID,
            userVoted: userVote?.countsAsVote == true,
            userVote: userVote,
            isPriority: isPriority,
            priorityRank: priorityRank
        )
    }

    private var index: CompanionGroupIndex { CompanionGroupIndex(groups: [group]) }

    // MARK: - Groups and lookup

    func testContractGroupPutsThePrimaryFirstAndRejectsASingleMember() throws {
        let decoded = try JSONDecoder().decode(
            [UserAPIContractsV1.CompanionGroup].self,
            from: Data(#"""
            [{"primaryGuid":"BILLS-119hr900","memberGuids":["BILLS-119s456","BILLS-119hr900"],"relationship":"identical"},
             {"primaryGuid":"BILLS-119hr1","memberGuids":["BILLS-119hr1"],"relationship":"identical"},
             {"primaryGuid":"BILLS-119hr2","memberGuids":["BILLS-119hr2","BILLS-119s2"],"relationship":"textual"}]
            """#.utf8)
        )

        let groups = decoded.compactMap(BillCompanionGroup.init(dto:))

        XCTAssertEqual(groups.map(\.memberGuids), [[Self.house, Self.senate], ["BILLS-119hr2", "BILLS-119s2"]])
        XCTAssertTrue(groups[0].isIdentical)
        XCTAssertFalse(groups[1].isIdentical, "a new relationship still decodes")
        XCTAssertEqual(groups[0].otherGuids, [Self.senate])
        XCTAssertEqual(groups[0].primaryBillID, UUID.deterministic(from: Self.house))
    }

    func testLegacySuffixedGuidAndSlugTypedBillResolveToTheGroup() {
        let index = index

        XCTAssertEqual(index.group(forGUID: Self.senate), group)
        XCTAssertEqual(index.group(forGUID: "BILLS-119s456is"), group, "a text-version guid resolves to its group")
        XCTAssertEqual(index.group(forGUID: " bills-119HR900ih "), group)
        XCTAssertEqual(index.memberGuid(forGUID: "BILLS-119s456is"), Self.senate)
        XCTAssertNil(index.group(forGUID: "BILLS-119s4560"))
        XCTAssertNil(index.group(forGUID: "BILLS-119hres900"), "another type with the same number is another bill")

        let slugBill = bill("custom-id", congress: "119", billType: "senate-bill", billID: "0456")
        XCTAssertEqual(index.group(for: slugBill), group, "congress, type slug and number resolve through the identity key")
        XCTAssertEqual(index.memberGuid(for: slugBill), Self.senate)
        XCTAssertEqual(
            index.group(for: BillsStore.billIdentityKey(congress: "119", billType: "S", billID: "456")!),
            group
        )
        XCTAssertEqual(index.groupKey(for: bill("BILLS-119s456is")), Self.house)
        XCTAssertEqual(index.groupKey(for: bill("BILLS-119hr77ih")), "BILLS-119hr77")
        XCTAssertTrue(index.isPrimary(guid: "BILLS-119hr900ih"))
        XCTAssertFalse(index.isPrimary(guid: Self.senate))
    }

    func testEmptyIndexFindsNothingAndCollapsesNothing() {
        let bills = [bill(Self.house), bill(Self.senate)]

        XCTAssertTrue(CompanionGroupIndex.empty.isEmpty)
        XCTAssertNil(CompanionGroupIndex.empty.group(forGUID: Self.house))
        XCTAssertEqual(CompanionGroupIndex.empty.collapsed(bills).map(\.guid), bills.map(\.guid))
    }

    func testCollapsedKeepsOneBillPerGroupPreferringThePrimary() {
        let bills = [bill(Self.senate), bill("BILLS-119hr1"), bill(Self.house)]

        XCTAssertEqual(index.collapsed(bills).map(\.guid), [Self.house, "BILLS-119hr1"])
    }

    // MARK: - Labels

    func testNumbersAndAccessibilityLabels() {
        XCTAssertEqual(CompanionGroupIndex.numbersLabel(for: group), "H.R. 900 · S. 456")
        XCTAssertEqual(CompanionGroupIndex.accessibilityLabel(for: group), "Bill numbers H.R. 900 and S. 456, identical bills")
        let joint = BillCompanionGroup(primaryGuid: "BILLS-119hjres131", memberGuids: ["BILLS-119sjres91"], relationship: "identical")
        XCTAssertEqual(CompanionGroupIndex.numbersLabel(for: joint), "H.J.Res. 131 · S.J.Res. 91")
    }

    // MARK: - Status lead

    func testStatusLeadIsTheMemberFurthestAlong() {
        let lead = index.statusLead(for: group, memberBills: [bill(Self.house), bill(Self.senate, status: .failed)])

        XCTAssertEqual(lead.guid, Self.senate)
        XCTAssertFalse(lead.isPrimary)
        XCTAssertEqual(lead.label, "Failed · S. 456")
    }

    func testStatusLeadTiesGoToTheLaterUpdateThenThePrimary() {
        let later = index.statusLead(for: group, memberBills: [
            bill(Self.house, status: .passed, storedAt: "2026-09-01T00:00:00.000Z"),
            bill(Self.senate, status: .passed, storedAt: "2026-09-02T00:00:00.000Z")
        ])
        XCTAssertEqual(later.guid, Self.senate)

        let tie = index.statusLead(for: group, memberBills: [bill(Self.house, status: .passed), bill(Self.senate, status: .passed)])
        XCTAssertEqual(tie.guid, Self.house)
        XCTAssertEqual(tie.label, "Passed")

        let finalized = index.statusLead(for: group, memberBills: [bill(Self.house, status: .finalized), bill(Self.senate, status: .passed)])
        XCTAssertEqual(finalized.label, "Became law")
    }

    // MARK: - Vote matrix

    private func resolution(_ rows: [String: VoteType]) -> CompanionVoteResolution {
        CompanionGroupIndex.voteResolution(for: group) { member in
            rows[member].map { CompanionVoteRow(memberGuid: member, guid: member, vote: $0) }
        }
    }

    func testVoteMatrix() {
        // No vote yet: none counts; a new vote goes to the primary.
        let none = resolution([:])
        XCTAssertNil(none.countedRow)
        XCTAssertEqual(none.targetGuid, Self.house)
        XCTAssertFalse(none.isVoted)

        // Vote on the primary only.
        let primaryOnly = resolution([Self.house: .yea])
        XCTAssertEqual(primaryOnly.effectiveVote, .yea)
        XCTAssertEqual(primaryOnly.targetGuid, Self.house)
        XCTAssertTrue(primaryOnly.isVoted)

        // Vote on the other bill only: it counts, and changes go to it.
        let otherOnly = resolution([Self.senate: .nay])
        XCTAssertEqual(otherOnly.countedRow?.memberGuid, Self.senate)
        XCTAssertEqual(otherOnly.targetGuid, Self.senate)
        XCTAssertNil(otherOnly.conflict)

        // Votes on both: the primary's counts, and the different choice is a conflict.
        let both = resolution([Self.house: .yea, Self.senate: .nay])
        XCTAssertEqual(both.effectiveVote, .yea)
        XCTAssertEqual(both.targetGuid, Self.house)
        XCTAssertEqual(both.conflict?.other, CompanionVoteRow(memberGuid: Self.senate, guid: Self.senate, vote: .nay))
        XCTAssertNil(resolution([Self.house: .yea, Self.senate: .yea]).conflict)

        // An Abstain is a held row: it keeps the target, but is not a counted vote.
        let abstained = resolution([Self.senate: .abstain])
        XCTAssertEqual(abstained.targetGuid, Self.senate)
        XCTAssertFalse(abstained.isVoted)
    }

    // MARK: - Ranking

    func testRankValuesTakeAnyPriorityAndTheLatestDate() {
        let values = index.rankValues(
            for: bill(Self.house, storedAt: "2026-09-01T00:00:00.000Z"),
            memberBills: [bill(Self.senate, storedAt: "2026-09-05T00:00:00.000Z", isPriority: true, priorityRank: 2)]
        )

        XCTAssertTrue(values.hasActivePriority)
        XCTAssertEqual(values.prioritySortRank, 2)
        XCTAssertEqual(values.sortDate, FlexibleISO8601.parse("2026-09-05T00:00:00.000Z"))
    }

    // MARK: - Home (acceptance 3)

    private func recent(_ hoursAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 60 * 60))
    }

    private func priorityBill(_ guid: String, storedAt: String) -> Bill {
        // A priority bill is eligible for the queue whatever the profile follows.
        bill(guid, storedAt: storedAt, isPriority: true)
    }

    @MainActor
    func testHomeShowsOneCardPerGroupOnThePrimaryWhenOnlyTheOtherMemberIsInTheWindow() throws {
        let profile = UserProfile.placeholder()
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 24 * 60 * 60))
        let bills = [
            priorityBill(Self.senate, storedAt: recent(1)),
            priorityBill(Self.house, storedAt: old),
            priorityBill("BILLS-119hr1", storedAt: recent(2))
        ]
        let input = BillBoardDerivedCollections.Input(
            bills: bills,
            dismissedBillIDs: [],
            userProfile: profile,
            historyWindow: .oneWeek,
            voteStatesByBillID: [:],
            companions: index
        )

        let derived = BillBoardDerivedCollections.derive(from: input)

        XCTAssertEqual(derived.liveBoardItems.map(\.bill.guid), [Self.house, "BILLS-119hr1"], "the group ranks by its newest member")
        let card = try XCTUnwrap(derived.liveBoardItems.first)
        XCTAssertEqual(card.id, UUID.deterministic(from: Self.house))
        XCTAssertEqual(card.companionGroup, group)
        XCTAssertEqual(card.memberBills.map(\.guid), [Self.house, Self.senate])
        XCTAssertEqual(card.companionNumbersLabel, "H.R. 900 · S. 456")
        XCTAssertEqual(card.date, FlexibleISO8601.parse(bills[0].storedAt), "the card is dated by the member that moved")
        XCTAssertEqual(derived.snapshot.newCount, 2)

        // Without the index: one card per bill, and the out-of-window House bill is not shown.
        let perBill = BillBoardDerivedCollections.derive(from: BillBoardDerivedCollections.Input(
            bills: bills,
            dismissedBillIDs: [],
            userProfile: profile,
            historyWindow: .oneWeek,
            voteStatesByBillID: [:]
        ))
        XCTAssertEqual(Set(perBill.liveBoardItems.compactMap(\.bill.guid)), [Self.senate, "BILLS-119hr1"])
    }

    @MainActor
    func testHomeHidesAGroupWhenAnyMemberIsVotedOrDismissed() {
        let profile = UserProfile.placeholder()
        let bills = [priorityBill(Self.house, storedAt: recent(1)), priorityBill(Self.senate, storedAt: recent(1))]
        func items(dismissed: Set<UUID> = [], votes: [String: VoteState] = [:]) -> [String?] {
            BillBoardDerivedCollections.derive(from: BillBoardDerivedCollections.Input(
                bills: bills,
                dismissedBillIDs: dismissed,
                userProfile: profile,
                historyWindow: .oneWeek,
                voteStatesByBillID: votes,
                companions: index
            )).liveBoardItems.map(\.bill.guid)
        }

        XCTAssertEqual(items(), [Self.house])
        XCTAssertEqual(items(votes: [Self.senate: .voted(.nay)]), [], "a vote on the Senate bill hides the group")
        XCTAssertEqual(items(dismissed: [UUID.deterministic(from: Self.senate)]), [])
        XCTAssertEqual(items(votes: [Self.senate: .notVoted]), [Self.house])
    }

    // MARK: - Store: votes (acceptance 1, 5), deep links (6), updated pushes (7)

    @MainActor
    private func makeStore(
        bills: [Bill],
        votes: FakeBillVotesService? = nil
    ) async -> (store: BillsStore, voteStore: BillVoteStore, scope: String) {
        await makeCompanionStore(bills: bills, groups: [group], votes: votes)
    }

    @MainActor
    private func settle(scope: String) async {
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testStoreReadsTheCachedGroupsOnRestore() async {
        let (store, _, scope) = await makeStore(bills: [bill(Self.house), bill(Self.senate)])

        XCTAssertEqual(store.companionGroupIndex.groups, [group])
        XCTAssertEqual(store.companionGroup(forBillID: UUID.deterministic(from: Self.senate)), group)
        XCTAssertEqual(store.companionGroup(forBillID: UUID.deterministic(from: Self.house)), group)
        XCTAssertNil(store.companionGroup(forBillID: UUID.deterministic(from: "BILLS-119hr1")))
        _ = scope
    }

    @MainActor
    func testNewVoteOnAGroupGoesToThePrimary() async {
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(bills: [bill(Self.house), bill(Self.senate)], votes: votes)

        let stored = await store.vote(billID: UUID.deterministic(from: Self.senate), vote: .yea, watch: true)?.value

        XCTAssertEqual(stored, true)
        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [Self.house])
        XCTAssertEqual(voteStore.vote(for: Self.house), .voted(.yea))
        XCTAssertEqual(store.bill(forGUID: Self.house)?.userVote, .yea)
        XCTAssertNil(store.bill(forGUID: Self.senate)?.userVote)
        XCTAssertTrue(store.isVoted(billID: UUID.deterministic(from: Self.senate)))
        XCTAssertTrue(store.isWatched(billID: UUID.deterministic(from: Self.senate)))
        await settle(scope: scope)
    }

    @MainActor
    func testVoteOnlyOnTheOtherBillCountsAndReceivesChanges() async {
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(bills: [bill(Self.house), bill(Self.senate)], votes: votes)
        await voteStore.setVote(billId: Self.senate, vote: .nay)

        let resolution = store.companionVote(forBillID: UUID.deterministic(from: Self.house))
        XCTAssertEqual(resolution?.effectiveVote, .nay)
        XCTAssertEqual(store.voteTargetGUID(forBillID: UUID.deterministic(from: Self.house)), Self.senate)

        _ = await store.vote(billID: UUID.deterministic(from: Self.house), vote: .yea, watch: false)?.value

        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [Self.senate, Self.senate], "no second row on the primary")
        XCTAssertEqual(voteStore.vote(for: Self.senate), .voted(.yea))
        XCTAssertEqual(voteStore.vote(for: Self.house), .unknown)
        await settle(scope: scope)
    }

    @MainActor
    func testVotesOnBothBillsCountThePrimaryAndReportTheConflict() async {
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(bills: [bill(Self.house), bill(Self.senate)], votes: votes)
        await voteStore.setVote(billId: Self.house, vote: .yea)
        await voteStore.setVote(billId: Self.senate, vote: .nay)

        let resolution = store.companionVote(forBillID: UUID.deterministic(from: Self.senate))
        XCTAssertEqual(resolution?.effectiveVote, .yea)
        XCTAssertEqual(resolution?.targetGuid, Self.house)
        XCTAssertEqual(resolution?.conflict?.other.guid, Self.senate)
        XCTAssertEqual(resolution?.conflict?.other.vote, .nay)
        _ = scope
    }

    @MainActor
    func testVoteHeldOnALegacyTextVersionGuidStaysThere() async {
        let votes = FakeBillVotesService()
        let legacy = bill("BILLS-119s456is", userVote: .nay)
        let (store, _, scope) = await makeStore(bills: [bill(Self.house), legacy], votes: votes)

        XCTAssertEqual(store.companionVote(forBillID: UUID.deterministic(from: Self.house))?.targetGuid, "BILLS-119s456is")
        _ = await store.vote(billID: UUID.deterministic(from: Self.house), vote: .yea, watch: false)?.value

        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), ["BILLS-119s456is"])
        await settle(scope: scope)
    }

    // MARK: - Skip on Bills (spec D 2.1.1: a skip is never a vote)

    @MainActor
    func testSkipOnAGroupDismissesEveryMemberAndWritesNoVote() async {
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(bills: [bill(Self.house), bill(Self.senate)], votes: votes)
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())

        let receipt = store.skip(.openBill(UUID.deterministic(from: Self.house)), readState: readState)
        await Task.yield()

        XCTAssertEqual(votes.setFeedbackCalls, [], "a skip writes no vote, not even Abstain")
        XCTAssertEqual(voteStore.vote(for: Self.house), .unknown)
        XCTAssertEqual(readState.dismissedBillIDs, [UUID.deterministic(from: Self.house), UUID.deterministic(from: Self.senate)])
        XCTAssertEqual(Set(receipt.dismissedBillIDs), readState.dismissedBillIDs)
        XCTAssertEqual(receipt.pendingUnwatchBillIDs, [])
        XCTAssertFalse(store.isVoted(billID: UUID.deterministic(from: Self.house)))
        _ = scope
    }

    @MainActor
    func testSkipOnAGroupKeepsAYeaHeldOnALegacyGuid() async {
        // The Senate bill's Yea is stored under its text-version guid, which the Bills list does not see.
        let votes = FakeBillVotesService()
        let legacy = bill("BILLS-119s456is")
        let (store, voteStore, scope) = await makeStore(bills: [bill(Self.house), bill(Self.senate), legacy], votes: votes)
        await voteStore.setVote(billId: "BILLS-119s456is", vote: .yea)
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())

        store.skip(.openBill(UUID.deterministic(from: Self.house)), readState: readState)
        await Task.yield()

        XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea], "only the earlier Yea; the skip wrote nothing")
        XCTAssertEqual(voteStore.vote(for: "BILLS-119s456is"), .voted(.yea))
        XCTAssertTrue(readState.dismissedBillIDs.isSuperset(of: [
            UUID.deterministic(from: Self.house),
            UUID.deterministic(from: Self.senate),
            legacy.id
        ]))
        _ = scope
    }

    @MainActor
    func testUngroupedSkipDismissesOnlyThatBill() async {
        let votes = FakeBillVotesService()
        let (store, _, scope) = await makeStore(bills: [bill("BILLS-119hr1")], votes: votes)
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())

        store.skip(.openBill(UUID.deterministic(from: "BILLS-119hr1")), readState: readState)
        await Task.yield()

        XCTAssertEqual(readState.dismissedBillIDs, [UUID.deterministic(from: "BILLS-119hr1")])
        XCTAssertEqual(votes.setFeedbackCalls, [])
        _ = scope
    }

    // MARK: - Updates: Clear (spec D 2.1.3: Clear never votes; the unwatch waits for the commit)

    @MainActor
    func testClearingAPassedMemberFromUpdatesKeepsTheVoteOnTheOtherMember() async {
        // H.R. 900 is open and holds the group's Yea; S. 456 passed.
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(
            bills: [bill(Self.house, storedAt: recent(1)), bill(Self.senate, status: .passed, storedAt: recent(1))],
            votes: votes
        )
        _ = await store.vote(billID: UUID.deterministic(from: Self.house), vote: .yea, watch: true)?.value
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())

        let receipt = store.clearFromUpdates(billID: UUID.deterministic(from: Self.senate), readState: readState)

        XCTAssertEqual(votes.setFeedbackCalls, [.init(billId: Self.house, feedback: .yea, reasons: [])], "no Abstain")
        XCTAssertEqual(voteStore.vote(for: Self.house), .voted(.yea))
        XCTAssertEqual(store.bill(forGUID: Self.house)?.userVote, .yea)
        XCTAssertTrue(store.isVoted(billID: UUID.deterministic(from: Self.house)))
        XCTAssertEqual(readState.dismissedBillIDs, [UUID.deterministic(from: Self.senate), UUID.deterministic(from: Self.house)])
        XCTAssertTrue(store.isWatched(billID: UUID.deterministic(from: Self.house)), "the unwatch waits for the Undo window")

        store.commitSkip(receipt)

        XCTAssertFalse(store.isWatched(billID: UUID.deterministic(from: Self.house)), "the commit unwatches the group")
        XCTAssertEqual(votes.setFeedbackCalls.count, 1)
        await settle(scope: scope)
    }

    @MainActor
    func testClearingFromUpdatesKeepsAVoteHeldOnlyOnTheSenateBill() async {
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(
            bills: [bill(Self.house, status: .passed), bill(Self.senate)],
            votes: votes
        )
        await voteStore.setVote(billId: Self.senate, vote: .nay)
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())

        store.commitSkip(store.clearFromUpdates(billID: UUID.deterministic(from: Self.house), readState: readState))
        await Task.yield()

        XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.nay], "no Abstain on either member")
        XCTAssertEqual(voteStore.vote(for: Self.senate), .voted(.nay))
        XCTAssertEqual(voteStore.vote(for: Self.house), .unknown)
        _ = scope
    }

    @MainActor
    func testClearingAnUnvotedGroupFromUpdatesWritesNoVoteAndDismissesEveryMember() async {
        // R1 wrote Abstain to the group's vote target here; R2 writes nothing.
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(
            bills: [bill(Self.house), bill(Self.senate, status: .passed)],
            votes: votes
        )
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())

        let receipt = store.clearFromUpdates(billID: UUID.deterministic(from: Self.senate), readState: readState)
        store.commitSkip(receipt)
        await Task.yield()

        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertEqual(voteStore.vote(for: Self.house), .unknown)
        XCTAssertEqual(Set(readState.dismissedBillIDs), [UUID.deterministic(from: Self.house), UUID.deterministic(from: Self.senate)])
        XCTAssertEqual(receipt.pendingUnwatchBillIDs, [UUID.deterministic(from: Self.senate)])
        _ = scope
    }

    @MainActor
    func testClearingAnUngroupedBillFromUpdatesWritesNoVoteAndUnwatchesOnCommit() async {
        let votes = FakeBillVotesService()
        var passed = bill("BILLS-119hr1", status: .passed)
        passed.userWatched = true
        let (store, _, scope) = await makeCompanionStore(bills: [passed], groups: [], votes: votes)
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())

        let receipt = store.clearFromUpdates(billID: passed.id, readState: readState)

        XCTAssertEqual(readState.dismissedBillIDs, [passed.id])
        XCTAssertTrue(store.isWatched(billID: passed.id), "watched until the commit")

        store.commitSkip(receipt)
        await Task.yield()

        XCTAssertEqual(votes.setFeedbackCalls, [], "no Abstain")
        XCTAssertFalse(store.isWatched(billID: passed.id))
        await settle(scope: scope)
    }

    @MainActor
    func testUpdatesFeedHidesTheOtherMemberAfterAVote() async {
        // The vote is only in the vote store (cast on Home's group card, which writes H.R. 900).
        let house = bill(Self.house, storedAt: recent(1), isPriority: true)
        let senate = bill(Self.senate, status: .passed, storedAt: recent(1), isPriority: true)
        let senateAlert = BillAlert(
            id: UUID(),
            sponsorMemberID: nil,
            billID: senate.id,
            title: "S. 456 passed",
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
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())
        func feed(groups: [BillCompanionGroup]) async -> UpdatesFeedSnapshot {
            let (store, voteStore, scope) = await makeCompanionStore(bills: [house, senate], groups: groups)
            let unvoted = NotificationsView.updatesFeed(
                billsStore: store,
                alerts: [senateAlert],
                readState: readState,
                userProfile: .placeholder(),
                voteStore: voteStore,
                historyWindow: .oneWeek
            )
            XCTAssertEqual(unvoted.passedBills.map(\.guid), [Self.senate])
            await voteStore.setVote(billId: Self.house, vote: .yea)
            let voted = NotificationsView.updatesFeed(
                billsStore: store,
                alerts: [senateAlert],
                readState: readState,
                userProfile: .placeholder(),
                voteStore: voteStore,
                historyWindow: .oneWeek
            )
            _ = scope
            return voted
        }

        let grouped = await feed(groups: [group])
        XCTAssertEqual(grouped.passedBills.map(\.guid), [], "the vote on H.R. 900 covers S. 456")
        XCTAssertEqual(grouped.activeAlerts, [])

        let perBill = await feed(groups: [])
        XCTAssertEqual(perBill.passedBills.map(\.guid), [Self.senate], "without groups each bill stands alone")
        XCTAssertEqual(perBill.activeAlerts.map(\.id), [senateAlert.id])
    }

    @MainActor
    func testClearingAGroupHoldingAnAbstainRefreshesUpdatesFromThePublishedDismissals() async {
        // S. 456 holds an Abstain from before grouping (it does not count as a vote); H.R. 900 passed.
        // Neither is watched, so the dismissal is the only change the Updates screen hears about, and
        // `$dismissedBillIDs` publishes before the read state changes.
        let house = bill(Self.house, status: .passed, storedAt: recent(1), isPriority: true)
        let senate = bill(Self.senate, storedAt: recent(1), isPriority: true)
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeStore(bills: [house, senate], votes: votes)
        await voteStore.setVote(billId: Self.senate, vote: .abstain)
        let readState = AppReadState(scope: .user("companion-tests"), store: InMemoryReadStateStore())
        func feed(dismissedBillIDs: Set<UUID>? = nil) -> UpdatesFeedSnapshot {
            NotificationsView.updatesFeed(
                billsStore: store,
                alerts: [],
                readState: readState,
                userProfile: .placeholder(),
                voteStore: voteStore,
                historyWindow: .oneWeek,
                dismissedBillIDs: dismissedBillIDs
            )
        }
        XCTAssertEqual(feed().passedBills.map(\.guid), [Self.house])
        var refreshed: [UpdatesFeedSnapshot] = []
        let subscription = readState.$dismissedBillIDs.dropFirst().sink { ids in
            refreshed.append(feed(dismissedBillIDs: ids))
        }

        store.commitSkip(store.clearFromUpdates(billID: house.id, readState: readState))

        XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.abstain], "only the earlier Abstain; the Clear wrote nothing")
        XCTAssertEqual(refreshed.count, 1, "nothing else publishes")
        XCTAssertEqual(refreshed.last?.passedBills.map(\.guid), [], "the row leaves Updates")
        subscription.cancel()
        _ = scope
    }

    // MARK: - Push deep links

    @MainActor
    func testAPushNamingOneGroupOpensItsDetailAndOneNamingTwoBillsDoesNot() async {
        let other = "BILLS-119hr1"
        let (store, _, _) = await makeStore(bills: [bill(Self.house), bill(Self.senate), bill(other)])
        let houseID = UUID.deterministic(from: Self.house)

        XCTAssertEqual(store.pushDeepLinkBillID(forGUIDs: [Self.house, Self.senate]), houseID, "one bill's copy with its folded partner")
        XCTAssertEqual(store.pushDeepLinkBillID(forGUIDs: [Self.senate, Self.house]), houseID)
        XCTAssertEqual(store.pushDeepLinkBillID(forGUIDs: [Self.house, "BILLS-119s456is"]), houseID, "a text-version guid of a member")
        XCTAssertEqual(store.pushDeepLinkBillID(forGUIDs: [Self.senate]), houseID, "a member opens on the loaded primary")
        XCTAssertEqual(store.pushDeepLinkBillID(forGUIDs: [" \(other) "]), UUID.deterministic(from: other))
        XCTAssertNil(store.pushDeepLinkBillID(forGUIDs: [Self.house, other]), "two bills open the Board tab")
        XCTAssertNil(store.pushDeepLinkBillID(forGUIDs: []))

        let (ungrouped, _, _) = await makeCompanionStore(bills: [bill(Self.house), bill(Self.senate)], groups: [])
        XCTAssertNil(ungrouped.pushDeepLinkBillID(forGUIDs: [Self.house, Self.senate]), "without groups, two bills")
    }

    @MainActor
    func testInCongressFetchesAMemberThatGoesStaleWhileTheGroupIsOpen() async throws {
        // H.R. 900 and S. 456 were hydrated days ago. An "Updated" push for S. 456 opens the group on
        // H.R. 900, and the manifest load that marks S. 456 stale lands after the screen appeared (or a
        // foreground refresh does). The In Congress section fetches S. 456 again while it is open.
        let formatter = ISO8601DateFormatter()
        let hydratedAt = formatter.string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60))
        func hydrated(_ guid: String, _ type: String, _ number: String, storedAt: String? = nil) -> Bill {
            Bill(
                id: UUID.deterministic(from: guid),
                title: "A bill",
                category: "Other",
                soWhat: "",
                storedAt: storedAt ?? hydratedAt,
                link: "https://example.test/\(guid)",
                billStatus: .new,
                guid: guid,
                congress: "119",
                billType: type,
                billID: number,
                userVoted: false,
                isProcessedDetailHydrated: true
            )
        }
        func row(_ guid: String, _ type: String, _ number: String, _ updatedAt: String) -> BillsManifestItem {
            BillsManifestItem(
                guid: guid,
                congress: "119",
                billType: type,
                billID: number,
                updatedAt: updatedAt,
                subCategories: [],
                lifeAreas: [],
                sponsors: [],
                cosponsors: [],
                title: "A bill",
                billStatus: "Updated"
            )
        }
        let senateID = UUID.deterministic(from: Self.senate)
        let (store, _, scope) = await makeStore(bills: [hydrated(Self.house, "hr", "900"), hydrated(Self.senate, "s", "456")])
        let service = try XCTUnwrap(store.service as? FakeBillsService)
        let senateUpdatedAt = formatter.string(from: Date().addingTimeInterval(-24 * 60 * 60))
        service.manifestResults = [.success([
            row(Self.house, "hr", "900", hydratedAt),
            row(Self.senate, "s", "456", senateUpdatedAt)
        ])]
        let openedKey = BillCompanionMembersSection.loadTaskKey(for: group, in: store)

        await store.load(historyWindow: .oneWeek)

        let stale = try XCTUnwrap(store.bill(for: senateID))
        XCTAssertFalse(store.isBillDetailHydrated(stale), "the Senate bill changed after it was hydrated")
        XCTAssertTrue(store.isBillDetailHydrated(try XCTUnwrap(store.bill(forGUID: Self.house))))
        let staleKey = BillCompanionMembersSection.loadTaskKey(for: group, in: store)
        XCTAssertNotEqual(staleKey, openedKey, "the open section fetches the stale member again")

        // A failed fetch (offline) leaves the key, so the section does not retry in a loop.
        service.processedBillResult = .failure(APIServiceError.invalidPayload("processed-bill"))
        _ = await store.ensureHydrated(billID: senateID, reportsError: false)
        XCTAssertEqual(BillCompanionMembersSection.loadTaskKey(for: group, in: store), staleKey)

        // A fetch that succeeds makes it current once; the next run has nothing to fetch.
        service.processedBillResult = .success(hydrated(Self.senate, "s", "456", storedAt: senateUpdatedAt))
        _ = await store.ensureHydrated(billID: senateID, reportsError: false)
        XCTAssertEqual(BillCompanionMembersSection.loadTaskKey(for: group, in: store), openedKey)
        await settle(scope: scope)
    }

    @MainActor
    func testUnwatchingAGroupUnwatchesEveryMember() async {
        var house = bill(Self.house)
        house.userWatched = true
        var senate = bill(Self.senate)
        senate.userWatched = true
        let (store, _, scope) = await makeStore(bills: [house, senate])

        store.unwatch(billID: UUID.deterministic(from: Self.house))

        XCTAssertFalse(store.isWatched(billID: UUID.deterministic(from: Self.senate)))
        XCTAssertEqual(store.bills.filter(\.userWatched).count, 0)
        await settle(scope: scope)
    }

    // MARK: - Combined stats

    @MainActor
    func testCompanionStatsAskForTheCompanionScopeAndReadTheMembers() async throws {
        let totals = #"{"votes":3,"yea":2,"nay":1,"abstain":0,"decisionVotes":3,"yeaPct":0.67,"weightedVotes":3,"weightedYea":2,"weightedNay":1,"weightedAbstain":0,"weightedDecisionVotes":3,"weightedYeaPct":0.67}"#
        let body = #"{"billId":"BILLS-119s456","totals":\#(totals),"segments":{"verified":\#(totals),"selfAttested":\#(totals)},"rollups":{},"companionBillIds":["BILLS-119hr900","BILLS-119s456"]}"#
        let transport = RecordingTransport()
        transport.responses = [Data(body.utf8), Data(body.replacingOccurrences(of: #","companionBillIds":["BILLS-119hr900","BILLS-119s456"]"#, with: "").utf8)]

        let combined = try await APIClient.$current.withValue(transport.client) {
            try await BillStatsService.fetchBillStats(billId: Self.senate, scope: .companions)
        }
        let single = try await APIClient.$current.withValue(transport.client) {
            try await BillStatsService.fetchBillStats(billId: Self.senate)
        }

        XCTAssertEqual(transport.requests.map(\.queryParameters), [
            ["billId": Self.senate, "scope": "companions"],
            ["billId": Self.senate]
        ])
        XCTAssertEqual(combined.companionBillIds, [Self.house, Self.senate])
        XCTAssertTrue(combined.isCombinedCompanionStats)
        XCTAssertNil(single.companionBillIds)
        XCTAssertFalse(single.isCombinedCompanionStats)
    }

    // MARK: - Local weekly digest (acceptance 9)

    @MainActor
    func testLocalWeeklyDigestCollapsesAPairAndCountsAPartnerVote() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let formatter = ISO8601DateFormatter()
        let moved = window.start.addingTimeInterval(24 * 60 * 60)
        func item(_ guid: String, _ type: String, _ number: String, _ updatedAt: Date) -> BillsManifestItem {
            BillsManifestItem(
                guid: guid,
                congress: "119",
                billType: type,
                billID: number,
                updatedAt: formatter.string(from: updatedAt),
                subCategories: ["Energy"],
                lifeAreas: [],
                sponsors: [],
                cosponsors: [],
                title: "Bill \(number)",
                billStatus: "Updated"
            )
        }
        let bills = FakeBillsService()
        bills.manifestResults = [.success([
            item(Self.house, "hr", "900", moved),
            item(Self.senate, "s", "456", moved.addingTimeInterval(60 * 60)),
            item("BILLS-119hr900ih", "house-bill", "900", moved),
            item("BILLS-119hr1", "hr", "1", moved)
        ])]
        bills.cachedGroups = [group]
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.house: .voted(.init(vote: .yea, votedAt: Date()))])
        let suite = "companion-digest-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        let store = WeeklyDigestStore(
            scope: "companion-digest",
            defaults: defaults,
            digestService: EmptyWeeklyDigestService(),
            billsService: bills,
            votesService: votes,
            congressService: FakeCongressService()
        )
        // The pair matches a followed topic; the user voted on the House bill only.
        let profile = UserProfile.placeholder().updating(id: "user-1", subscribedSubCategories: ["Energy"])

        await store.refresh(profile: profile, forceRefresh: true)

        let digest = try XCTUnwrap(store.digest)
        let billItems = digest.sections.flatMap(\.items).filter { $0.kind == .bill }
        XCTAssertEqual(Set(billItems.compactMap(\.billGuid)), [Self.senate, "BILLS-119hr1"], "one item per pair: the member that moved last")
        XCTAssertEqual(billItems.count, 2)
        XCTAssertEqual(Set(votes.batchRequests.flatMap { $0 }), [Self.house, Self.senate, "BILLS-119hr1"])
        let pairItem = try XCTUnwrap(billItems.first { $0.billGuid == Self.senate })
        XCTAssertEqual(pairItem.reason, "You voted on this before", "a vote on the House bill counts for the pair")
    }
}

/// A published digest that is never available, so the store builds one on the device.
@MainActor
final class EmptyWeeklyDigestService: WeeklyDigestServicing {
    func fetchLatest() async throws -> WeeklyDigest? { nil }
}
