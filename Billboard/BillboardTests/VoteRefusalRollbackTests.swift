import SwiftUI
import XCTest
@testable import Billboard

/// APPF-27: a vote the server refuses (`VOTE_DAILY_LIMIT`, or any other coded refusal of
/// `POST /feedback`) rolls back everywhere the vote shows: the vote store, the bills store's copy of
/// the bill (which bill detail falls back to, and which the Bills list, Updates and Search read), and
/// bill detail's own choice. A vote the server stores stays optimistic.
@MainActor
final class VoteRefusalRollbackTests: XCTestCase {
    private nonisolated static let guid = "BILLS-119hr4100"

    private func openBill(_ guid: String = VoteRefusalRollbackTests.guid) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: "Bill \(guid)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            billStatus: .new,
            guid: guid,
            userVoted: false,
            isPriority: true
        )
    }

    /// The Bills list as Home derives it from both stores.
    private func listedGuids(_ store: BillsStore, _ voteStore: BillVoteStore) -> [String?] {
        BillBoardDerivedCollections.derive(from: BillBoardDerivedCollections.Input(
            bills: store.bills,
            dismissedBillIDs: [],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteStatesByBillID: voteStore.statesByBillId,
            starterFeedEnabled: false
        )).liveBoardItems.map(\.bill.guid)
    }

    // MARK: - Reproduction (the bills store kept the refused vote)

    func testADailyLimitRefusalRollsBackTheBillsStoreToo() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)
        XCTAssertEqual(listedGuids(store, voteStore), [Self.guid], "precondition: on the Bills list")

        let stored = await store.vote(billID: bill.id, vote: .yea, watch: nil)?.value

        XCTAssertEqual(stored, false)
        XCTAssertEqual(voteStore.vote(for: Self.guid), .unknown, "the vote store rolled back")
        XCTAssertEqual(voteStore.lastError, AuthErrorMessages.voteDailyLimit)
        let after = store.bill(for: bill.id)
        // Bill detail shows the bills store's vote when the vote store does not know the bill.
        XCTAssertNil(after?.userVote, "the vote bar would still show Yea")
        XCTAssertEqual(after?.userVoted, false)
        XCTAssertNil(after?.lastVotedAt, "Search's Voted list would still list it")
        XCTAssertFalse(store.isVoted(billID: bill.id))
        XCTAssertEqual(listedGuids(store, voteStore), [Self.guid], "back on the Bills list")
        await settleBillsCache(scope: scope)
    }

    func testAnAppAttestRefusalRollsBackTheBillsStoreToo() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = backendError("APP_ATTEST_FAILED")
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)

        let stored = await store.vote(billID: bill.id, vote: .nay, watch: nil)?.value

        XCTAssertEqual(stored, false)
        XCTAssertEqual(voteStore.vote(for: Self.guid), .unknown)
        XCTAssertNil(store.bill(for: bill.id)?.userVote)
        XCTAssertFalse(store.isVoted(billID: bill.id))
        await settleBillsCache(scope: scope)
    }

    // MARK: - The vote bar (bill detail)

    /// What bill detail's bar shows for a bill in no group after a vote cast on the screen ends:
    /// the screen's own choice unless the ledger rolled it back, else the stores' vote.
    private func barLayout(
        pending: UserVote?,
        store: BillsStore,
        voteStore: BillVoteStore,
        billID: UUID
    ) -> BillVoteBarModel.Layout {
        let counted = BillVoteBarModel.storedCountedVote(
            voteStoreState: voteStore.vote(for: Self.guid),
            billVote: store.bill(for: billID)?.userVote
        )
        let choice = BillVoteBarModel.shownChoice(
            pending: pending.map { VoteChoice($0.voteType) },
            counted: counted.map { VoteChoice($0.voteType) },
            held: voteStore.heldVote(for: Self.guid)
        )
        return BillVoteBarModel(mode: .full, choice: choice).layout
    }

    func testARefusedVoteLeavesTheBarOnTheThreeButtonsWithTheDailyLimitText() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)
        // Bill detail checks the vote when it opens.
        votes.singleResult = .success(.notVoted)
        await voteStore.fetchVoteIfNeeded(for: Self.guid)

        // What `castVote` does: the screen's choice, the write, and the ledger entry.
        var ledger = BillVoteCastLedger()
        var pending: UserVote? = .yea
        let write = store.submitVote(billID: bill.id, vote: .yea, watch: nil)
        let token = ledger.begin()
        XCTAssertEqual(barLayout(pending: pending, store: store, voteStore: voteStore, billID: bill.id), .collapsed(.yea), "optimistic")

        let result = await write?.value
        let outcome = ledger.finish(token, result: result ?? .notSaved)
        if case .rollBack = outcome { pending = nil }

        XCTAssertEqual(result, .rolledBack(restored: .notVoted))
        XCTAssertEqual(outcome, .rollBack(undismiss: []))
        XCTAssertEqual(
            barLayout(pending: pending, store: store, voteStore: voteStore, billID: bill.id),
            .choose(caption: nil, selected: nil),
            "the three buttons, not \"You voted Yea\""
        )
        XCTAssertEqual(
            voteStore.lastError,
            "You've reached today's limit of 200 votes. This vote wasn't saved. You can vote again after midnight UTC."
        )
        await settleBillsCache(scope: scope)
    }

    func testARefusedChangeShowsTheVoteBeforeIt() async {
        let votes = FakeBillVotesService()
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)
        let first = await store.submitVote(billID: bill.id, vote: .yea, watch: nil)?.value
        XCTAssertEqual(first, .stored, "precondition: the server holds Yea")
        let yeaVotedAt = voteStore.heldVoteDate(for: Self.guid)
        XCTAssertNotNil(yeaVotedAt)
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")

        let change = await store.submitVote(billID: bill.id, vote: .nay, watch: nil)?.value

        XCTAssertEqual(change, .rolledBack(restored: .voted(.yea)))
        XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.yea))
        let after = store.bill(for: bill.id)
        XCTAssertEqual(after?.userVote, .yea)
        XCTAssertEqual(after?.userVoted, true)
        XCTAssertEqual(after?.userYeaCount, 1)
        XCTAssertEqual(after?.userNayCount, 0)
        XCTAssertEqual(after?.lastVotedAt, yeaVotedAt, "the Yea keeps the time it was cast")
        XCTAssertEqual(voteStore.heldVoteDate(for: Self.guid), yeaVotedAt)
        XCTAssertEqual(barLayout(pending: nil, store: store, voteStore: voteStore, billID: bill.id), .collapsed(.yea))
        await settleBillsCache(scope: scope)
    }

    func testAStoredVoteStaysOptimistic() async {
        let votes = FakeBillVotesService()
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)
        var ledger = BillVoteCastLedger()

        let write = store.submitVote(billID: bill.id, vote: .nay, watch: nil)
        let token = ledger.begin()
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .nay, "shown before the server answers")
        let result = await write?.value

        XCTAssertEqual(result, .stored)
        XCTAssertEqual(ledger.finish(token, result: .stored), .keep)
        XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.nay))
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .nay)
        XCTAssertEqual(listedGuids(store, voteStore), [])
        XCTAssertNil(voteStore.lastError)
        await settleBillsCache(scope: scope)
    }

    func testAFailureThatMayHaveStoredTheVoteKeepsIt() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = URLError(.timedOut)
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)

        let result = await store.submitVote(billID: bill.id, vote: .yea, watch: nil)?.value

        XCTAssertEqual(result, .notSaved)
        XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.yea))
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .yea)
        XCTAssertEqual(voteStore.lastError, "Your vote may not have saved. Check your connection and vote again.")
        await settleBillsCache(scope: scope)
    }

    // MARK: - Abstain

    func testARefusedAbstainPutsTheBillBackOnTheBillsList() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)
        let readState = AppReadState(scope: .user("vote-refusal-tests"), store: InMemoryReadStateStore())
        var ledger = BillVoteCastLedger()

        // Abstain from bill detail also takes the bill off the Bills list.
        let write = store.submitVote(billID: bill.id, vote: .abstain, watch: nil)
        let dismissed = store.dismiss(billID: bill.id, readState: readState)
        let token = ledger.begin(dismissing: dismissed)
        XCTAssertEqual(dismissed, [bill.id])
        let result = await write?.value
        let outcome = ledger.finish(token, result: result ?? .notSaved)

        XCTAssertEqual(outcome, .rollBack(undismiss: [bill.id]))
        if case .rollBack(let undismiss) = outcome { readState.undismissBills(undismiss) }
        XCTAssertFalse(readState.dismissedBillIDs.contains(bill.id))
        XCTAssertNil(voteStore.heldVote(for: Self.guid), "no Abstain row")
        let listed = BillBoardDerivedCollections.derive(from: BillBoardDerivedCollections.Input(
            bills: store.bills,
            dismissedBillIDs: readState.dismissedBillIDs,
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteStatesByBillID: voteStore.statesByBillId,
            starterFeedEnabled: false
        )).liveBoardItems.map(\.bill.guid)
        XCTAssertEqual(listed, [Self.guid])
        await settleBillsCache(scope: scope)
    }

    // MARK: - Votes in flight

    func testARefusalOvertakenByANewerVoteRollsNothingBack() async {
        let votes = FakeBillVotesService()
        let gate = Gate()
        votes.holdSetFeedback = gate
        votes.setFeedbackOutcomes = [backendError("VOTE_DAILY_LIMIT"), nil]
        let firstStarted = expectation(description: "first write started")
        votes.onSetFeedback = { call in
            if call.feedback == .yea { firstStarted.fulfill() }
        }
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)
        var ledger = BillVoteCastLedger()

        let firstWrite = store.submitVote(billID: bill.id, vote: .yea, watch: nil)
        let firstToken = ledger.begin()
        await fulfillment(of: [firstStarted], timeout: 5)
        let secondWrite = store.submitVote(billID: bill.id, vote: .nay, watch: nil)
        let secondToken = ledger.begin()
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        let first = await firstWrite?.value
        let second = await secondWrite?.value

        XCTAssertEqual(first, .notSaved, "the newer vote decides")
        XCTAssertEqual(second, .stored)
        XCTAssertEqual(ledger.finish(firstToken, result: first ?? .notSaved), .keep)
        XCTAssertEqual(ledger.finish(secondToken, result: second ?? .notSaved), .keep)
        XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.nay))
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .nay)
        await settleBillsCache(scope: scope)
    }

    func testAnOlderWritesRollbackNeverUndoesANewerVoteInTheBillsStore() async {
        let bill = openBill()
        let (store, _, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: FakeBillVotesService())

        // The vote store can roll back an earlier write before a newer one reaches it; the bills store
        // applies a rollback only for its latest write on the guid.
        let write = store.submitVote(billID: bill.id, vote: .nay, watch: nil)
        store.voteWriteEnded(guid: Self.guid, billID: bill.id, token: UUID(), result: .rolledBack(restored: .notVoted))
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .nay)

        let result = await write?.value
        XCTAssertEqual(result, .stored)
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .nay)
        await settleBillsCache(scope: scope)
    }

    // MARK: - Reasons queued behind a refused vote

    /// What a run of bill detail's writes ended with (`castYeaAndQueueReasons`).
    private struct QueuedReasonsRun {
        let store: BillsStore
        let voteStore: BillVoteStore
        let votes: FakeBillVotesService
        let billID: UUID
        let scope: String
        let vote: VoteWriteResult?
        let reasonsSaved: Bool
    }

    /// Bill detail's writes: Yea from the bar (`castVote`), held while App Attest and the server answer,
    /// then a reason picked while it is in flight (`sendReasonUpdateIfNeeded`, after the debounce or on
    /// Done or Back), which queues behind it. `answers` answer the vote, then any later write (nil stores).
    private func castYeaAndQueueReasons(answers: [Error?]) async -> QueuedReasonsRun {
        let votes = FakeBillVotesService()
        let gate = Gate()
        votes.holdSetFeedback = gate
        votes.setFeedbackOutcomes = answers
        let voteSent = expectation(description: "the vote was sent")
        votes.onSetFeedback = { call in
            if call.feedback == .yea, call.reasons.isEmpty { voteSent.fulfill() }
        }
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)

        let write = store.submitVote(billID: bill.id, vote: .yea, watch: nil)
        await fulfillment(of: [voteSent], timeout: 5)
        let reasons = Task { await voteStore.updateReasons(billId: Self.guid, vote: .yea, reasons: [.publicSafety]) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(votes.setFeedbackCalls.count, 1, "precondition: the reasons wait for the vote")

        gate.open()
        let vote = await write?.value
        let reasonsSaved = await reasons.value
        return QueuedReasonsRun(
            store: store,
            voteStore: voteStore,
            votes: votes,
            billID: bill.id,
            scope: scope,
            vote: vote,
            reasonsSaved: reasonsSaved
        )
    }

    func testReasonsQueuedBehindAVoteRefusedForTheDailyLimitAreNotSent() async {
        // Sent, the reasons would be refused too, and their text says the vote stood.
        let run = await castYeaAndQueueReasons(answers: [backendError("VOTE_DAILY_LIMIT"), backendError("VOTE_DAILY_LIMIT")])

        XCTAssertEqual(run.vote, .rolledBack(restored: .unknown))
        XCTAssertFalse(run.reasonsSaved, "no \"Reasons saved\"")
        XCTAssertEqual(
            run.votes.setFeedbackCalls,
            [.init(billId: Self.guid, feedback: .yea, reasons: [])],
            "the refused Yea is not sent again with the reasons"
        )
        XCTAssertEqual(run.voteStore.lastError, AuthErrorMessages.voteDailyLimit, "not \(AuthErrorMessages.reasonsDailyLimit)")
        XCTAssertEqual(run.voteStore.vote(for: Self.guid), .unknown)
        XCTAssertNil(run.store.bill(for: run.billID)?.userVote)
        await settleBillsCache(scope: run.scope)
    }

    func testReasonsQueuedBehindAVoteRefusedByAppAttestAreNotSent() async {
        // Sent, the reasons write (with a fresh assertion) would be stored: the server would hold the Yea
        // that the app rolled back.
        let run = await castYeaAndQueueReasons(answers: [backendError("APP_ATTEST_UNAVAILABLE"), nil])

        XCTAssertEqual(run.vote, .rolledBack(restored: .unknown))
        XCTAssertFalse(run.reasonsSaved, "no \"Reasons saved\"")
        XCTAssertEqual(run.votes.setFeedbackCalls, [.init(billId: Self.guid, feedback: .yea, reasons: [])])
        XCTAssertEqual(run.voteStore.lastError, AuthErrorMessages.voteNotSaved)
        XCTAssertEqual(run.voteStore.vote(for: Self.guid), .unknown)
        XCTAssertNil(run.store.bill(for: run.billID)?.userVote)
        XCTAssertFalse(run.store.isVoted(billID: run.billID))
        await settleBillsCache(scope: run.scope)
    }

    func testReasonsForARefusedVoteThatArriveAfterItsWriteEndedAreNotSent() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackOutcomes = [backendError("VOTE_DAILY_LIMIT")]
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)

        // Bill detail drops its choice a few steps after the stores roll back; a debounced reasons update
        // (or Done) can still send in between.
        let refused = await store.submitVote(billID: bill.id, vote: .yea, watch: nil)?.value
        let late = await voteStore.updateReasons(billId: Self.guid, vote: .yea, reasons: [.publicSafety])

        XCTAssertEqual(refused, .rolledBack(restored: .unknown))
        XCTAssertFalse(late)
        XCTAssertEqual(votes.setFeedbackCalls.count, 1, "the refused Yea is not sent again")
        XCTAssertEqual(voteStore.lastError, AuthErrorMessages.voteDailyLimit)

        // A new vote takes its reasons as before.
        let stored = await store.submitVote(billID: bill.id, vote: .yea, watch: nil)?.value
        let reasonsSaved = await voteStore.updateReasons(billId: Self.guid, vote: .yea, reasons: [.publicSafety])

        XCTAssertEqual(stored, .stored)
        XCTAssertTrue(reasonsSaved)
        XCTAssertEqual(votes.setFeedbackCalls.map(\.reasons), [[], [], ["public_safety"]])
        await settleBillsCache(scope: scope)
    }

    func testReasonsQueuedBehindAVoteThatMayHaveBeenStoredAreStillSent() async {
        // A failure without a code keeps the vote (spec D 2.8.4), so its reasons go with it.
        let run = await castYeaAndQueueReasons(answers: [URLError(.timedOut), nil])

        XCTAssertEqual(run.vote, .notSaved)
        XCTAssertTrue(run.reasonsSaved)
        XCTAssertEqual(run.votes.setFeedbackCalls.map(\.reasons), [[], ["public_safety"]])
        XCTAssertEqual(run.voteStore.vote(for: Self.guid), .voted(.yea))
        await settleBillsCache(scope: run.scope)
    }

    func testReasonsQueuedBehindARefusedVoteThatANewerVoteOvertookAreNotSent() async {
        let votes = FakeBillVotesService()
        let gate = Gate()
        votes.holdSetFeedback = gate
        // The Yea is refused; every later write would be stored.
        votes.setFeedbackOutcomes = [backendError("VOTE_DAILY_LIMIT")]
        let yeaSent = expectation(description: "the Yea was sent")
        votes.onSetFeedback = { call in
            if call.feedback == .yea, call.reasons.isEmpty { yeaSent.fulfill() }
        }
        let bill = openBill()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes)

        // Yea, a reason for it, then Change to Nay, all before the server answers the Yea.
        let yea = store.submitVote(billID: bill.id, vote: .yea, watch: nil)
        await fulfillment(of: [yeaSent], timeout: 5)
        let reasons = Task { await voteStore.updateReasons(billId: Self.guid, vote: .yea, reasons: [.publicSafety]) }
        for _ in 0..<20 { await Task.yield() }
        let nay = store.submitVote(billID: bill.id, vote: .nay, watch: nil)
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        let yeaResult = await yea?.value
        let reasonsSaved = await reasons.value
        let nayResult = await nay?.value

        XCTAssertEqual(yeaResult, .notSaved, "the newer vote decides")
        XCTAssertFalse(reasonsSaved)
        XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea, .nay], "the refused Yea is not sent again")
        XCTAssertEqual(nayResult, .stored)
        XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.nay))
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .nay)
        await settleBillsCache(scope: scope)
    }

    // MARK: - The bill preference (PUT /preferences type=bill)

    /// The server follows a bill with a Bill row: it sends the bill's alerts and lists it under "You're
    /// watching this" in the weekly brief. A refused vote must leave none.
    func testARefusedVoteWritesNoBillPreference() async {
        for code in ["VOTE_DAILY_LIMIT", "APP_ATTEST_UNAVAILABLE"] {
            let votes = FakeBillVotesService()
            votes.setFeedbackError = backendError(code)
            let preferences = FakePreferencesService()
            let bill = openBill()
            let (store, _, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes, preferences: preferences)

            let result = await store.submitVote(billID: bill.id, vote: .yea, watch: nil)?.value
            for _ in 0..<50 { await Task.yield() }

            XCTAssertEqual(result, .rolledBack(restored: .unknown), code)
            XCTAssertEqual(preferences.putCalls, [], "\(code): no Bill row follows the bill")
            await settleBillsCache(scope: scope)
        }
    }

    func testTheBillPreferenceIsWrittenOnceTheServerStoresTheVote() async {
        let votes = FakeBillVotesService()
        let gate = Gate()
        votes.holdSetFeedback = gate
        let preferences = FakePreferencesService()
        let bill = openBill()
        let (store, _, scope) = await makeCompanionStore(bills: [bill], groups: [], votes: votes, preferences: preferences)

        let write = store.submitVote(billID: bill.id, vote: .yea, watch: nil)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(votes.setFeedbackCalls.count, 1, "precondition: the vote was sent")
        XCTAssertEqual(preferences.putCalls, [], "not before the server answers")

        gate.open()
        let result = await write?.value
        for _ in 0..<500 where preferences.putCalls.isEmpty { await Task.yield() }

        XCTAssertEqual(result, .stored)
        let saved = preferences.putCalls.flatMap { $0 }
        XCTAssertEqual(saved.map(\.preference), [Self.guid])
        XCTAssertEqual(saved.map(\.type), ["bill"])
        XCTAssertEqual(saved.map(\.category), [""])
        await settleBillsCache(scope: scope)
    }

    // MARK: - Companion groups

    func testARefusedVoteOnACompanionGroupRollsBackTheGroup() async throws {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let votes = FakeBillVotesService()
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let (store, voteStore, scope) = await makeCompanionStore(bills: [openBill(house), openBill(senate)], groups: [group], votes: votes)
        let senateID = UUID.deterministic(from: senate)

        let result = await store.submitVote(billID: senateID, vote: .yea, watch: nil)?.value

        XCTAssertEqual(result, .rolledBack(restored: .unknown))
        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [house], "the vote went to the primary")
        let resolution = try XCTUnwrap(store.companionVote(forBillID: senateID))
        XCTAssertFalse(resolution.isVoted)
        XCTAssertNil(resolution.effectiveVote)
        XCTAssertFalse(store.isVoted(billID: senateID))
        XCTAssertNil(store.bill(forGUID: house)?.userVote)
        XCTAssertEqual(voteStore.vote(for: house), .unknown)
        await settleBillsCache(scope: scope)
    }

    // MARK: - The refusal strip on the bill page (Civic Record spec 3.10.2)

    /// An open bill whose page is ready to show (its details are loaded).
    private func pageBill() -> Bill {
        Bill(
            id: UUID.deterministic(from: Self.guid),
            title: "Bill \(Self.guid)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            link: "https://www.govinfo.gov/app/details/BILLS-119hr4100ih",
            billStatus: .new,
            guid: Self.guid,
            userVoted: false,
            isPriority: true
        )
    }

    private func page(_ bill: Bill, store: BillsStore, voteStore: BillVoteStore, size: DynamicTypeSize) -> some View {
        NavigationStack { BillDetail(billID: bill.id) }
            .environmentObject(store)
            .environmentObject(voteStore)
            .environmentObject(AppReadState(scope: .user("refusal-strip-tests"), store: InMemoryReadStateStore()))
            .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
            .environmentObject(CongressMembersManifestStore(service: FakeCongressService()))
            .environment(\.dynamicTypeSize, size)
    }

    /// A Yea refused for the daily limit on the page: the panel goes back to the three buttons with the
    /// refusal's text in a strip above them ("Error: …", id `bill.vote.refusal`), not in the top banner;
    /// Results go back to sealed and no stats are asked for (INT-11, `fetchesStatsAfterWrite`). At xxxLarge the
    /// strip is the first row of Your vote instead. VoiceOver focus goes to the strip (`VoteFocusPlanner`,
    /// `.refusal`, bound to the strip's element). The strip goes with the next vote tap.
    func testARefusedVoteShowsItsReasonInAStripAndSealsResultsAgain() {
        // xxxLarge still has the three buttons, with the strip as a row of Your vote; at the accessibility sizes
        // the one Vote button opens a dialog a hosted test cannot tap (the moved rows are rendered elsewhere).
        for size in [DynamicTypeSize.large, .xxxLarge] {
            let votes = FakeBillVotesService()
            votes.singleResult = .success(.notVoted)
            votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
            let bill = pageBill()
            // Built here, not with the async `makeCompanionStore`: the hosted page needs the main run loop, which an
            // async test holds.
            let scope = "refusal-strip-tests-\(UUID().uuidString)"
            addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
            let service = FakeBillsService()
            service.cachedManifest = []
            let store = BillsStore(bills: [bill], cacheScope: scope, service: service, preferencesService: FakePreferencesService())
            let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
            store.connect(voteStore: voteStore)
            let transport = RecordingTransport()
            transport.failure = { _ in URLError(.notConnectedToInternet) }
            APIClient.$current.withValue(transport.client) {
                let host = AccessibilityTreeText.Host(
                    page(bill, store: store, voteStore: voteStore, size: size),
                    size: CGSize(width: 390, height: 9000),
                    settle: 0.6
                )
                defer { host.close() }
                XCTAssertNotNil(host.label(ofIdentifier: SealedTally.resultsIdentifier), "\(size): sealed before the vote")
                XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), "\(size): \(host.text())")
                XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea], "\(size)")

                let strip = host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier)
                XCTAssertEqual(strip, "Error: \(AuthErrorMessages.voteDailyLimit)", "\(size): \(host.text())")
                let strings = host.strings()
                XCTAssertEqual(strings.filter { $0.contains(AuthErrorMessages.voteDailyLimit) }.count, 1, "\(size): once, in the strip, not the banner: \(strings)")
                XCTAssertNil(voteStore.lastError, "\(size): the banner's message moved to the strip")
                XCTAssertTrue(strings.contains("Vote Yea"), "\(size): the three buttons are back: \(strings)")
                XCTAssertNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "\(size): no stamp")
                XCTAssertNotNil(host.label(ofIdentifier: SealedTally.resultsIdentifier), "\(size): Results sealed again")
                XCTAssertFalse(transport.requests.contains { $0.path == "bill-stats" }, "\(size): no stats asked for a refused vote")

                // The strip stays until the next vote tap.
                votes.setFeedbackError = nil
                XCTAssertTrue(host.activate("Vote Nay", settle: 1.2))
                XCTAssertNil(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "\(size): gone with the next vote")
            }
            withExtendedLifetime(voteStore) {}
        }
        var planner = VoteFocusPlanner()
        _ = planner.handle(.committed(BallotStampCopy(choice: .yea, votedAt: Date()), isChange: false, opensResults: true), voiceOverRunning: true)
        XCTAssertEqual(planner.handle(.refused, voiceOverRunning: true).focus, .refusal, "focus goes to the strip")
        XCTAssertEqual(BillDetail.refusalFocusDelay, 0.25, accuracy: 0.001, "after the 0.2 s cross-fade back")
    }

    /// The strip itself (in the panel and as a row of Your vote): the refusal's own text, read "Error: …".
    func testTheRefusalStripCarriesTheRefusalsText() {
        for placement in [VoteStrip.Placement.panel, .page] {
            let host = AccessibilityTreeText.Host(VoteStrip(kind: .refusal(AuthErrorMessages.voteDailyLimit), placement: placement), size: CGSize(width: 351, height: 300))
            defer { host.close() }
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: You've reached today's limit of 200 votes. This vote wasn't saved. You can vote again after midnight UTC.")
        }
        let rows = BillVoteBarModel(mode: .full, choice: nil).yourVoteRows(in: .extraLarge, refusal: AuthErrorMessages.voteDailyLimit, showsCoachMark: false)
        XCTAssertEqual(rows.refusal, AuthErrorMessages.voteDailyLimit, "from xxxLarge up the strip is a row of Your vote")
    }

    // MARK: - The pieces

    func testTheBarFallsBackToTheBillsStoresVoteOnlyWithoutAVoteStoreRow() {
        XCTAssertEqual(BillVoteBarModel.storedCountedVote(voteStoreState: .voted(.nay), billVote: .yea), .nay)
        XCTAssertNil(BillVoteBarModel.storedCountedVote(voteStoreState: .voted(.abstain), billVote: .yea))
        XCTAssertEqual(BillVoteBarModel.storedCountedVote(voteStoreState: .notVoted, billVote: .yea), .yea)
        XCTAssertEqual(BillVoteBarModel.storedCountedVote(voteStoreState: .unknown, billVote: .nay), .nay)
        XCTAssertNil(BillVoteBarModel.storedCountedVote(voteStoreState: .unknown, billVote: .abstain))
        XCTAssertNil(BillVoteBarModel.storedCountedVote(voteStoreState: .unknown, billVote: nil))
    }

    func testTheLedgerActsOnlyOnTheLatestCast() {
        let first = UUID.deterministic(from: "first")
        let second = UUID.deterministic(from: "second")
        var ledger = BillVoteCastLedger()

        let abstain = ledger.begin(dismissing: [first, second])
        let yea = ledger.begin()
        XCTAssertEqual(ledger.finish(abstain, result: .rolledBack(restored: .notVoted)), .keep, "overtaken by the Yea")
        XCTAssertEqual(ledger.finish(yea, result: .rolledBack(restored: .notVoted)), .rollBack(undismiss: [first, second]))
        XCTAssertEqual(ledger.dismissedBillIDs, [])
        XCTAssertNil(ledger.latest)

        let again = ledger.begin(dismissing: [first])
        XCTAssertEqual(ledger.finish(again, result: .rolledBack(restored: .voted(.abstain))), .rollBack(undismiss: []), "an Abstain row stays off the list")

        let stored = ledger.begin(dismissing: [first])
        XCTAssertEqual(ledger.finish(stored, result: .stored), .keep)
        XCTAssertEqual(ledger.dismissedBillIDs, [], "a stored Abstain keeps its dismissal")

        let kept = ledger.begin()
        XCTAssertEqual(ledger.finish(kept, result: .notSaved), .keep)
    }
}
