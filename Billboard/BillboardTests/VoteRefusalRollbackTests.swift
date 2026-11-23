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

        XCTAssertEqual(result, .unconfirmed)
        XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.yea))
        XCTAssertEqual(store.bill(for: bill.id)?.userVote, .yea)
        XCTAssertNil(voteStore.lastError, "the bill page says it (UX-49)")
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
        XCTAssertEqual(run.voteStore.lastError, BillVoteBarModel.refusalFallbackText)
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

        XCTAssertEqual(run.vote, .unconfirmed)
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

    /// A companion group whose vote row is held under a member's legacy text-version guid: votes and reasons from the
    /// other member's page go to that guid, and the vote store files their errors there. The page still finds them: a
    /// failed reasons update shows in the banner, and a refused change's strip has the daily limit's words, not the
    /// fallback.
    func testAGroupPageFindsAnErrorFiledUnderTheLegacyGuidItVotedOn() {
        let house = "BILLS-119hr900"
        let legacy = "BILLS-119s456is"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, "BILLS-119s456"], relationship: "identical")
        let houseBill = Bill(
            id: UUID.deterministic(from: house),
            title: "Bill \(house)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            link: "https://www.govinfo.gov/app/details/BILLS-119hr900ih",
            billStatus: .new,
            guid: house,
            userVoted: false,
            isPriority: true
        )
        let votes = FakeBillVotesService()
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let scope = "legacy-guid-page-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedGroups = [group]
        service.cachedManifest = []
        let store = BillsStore(
            bills: [houseBill, companionTestBill(legacy, userVote: .nay)],
            cacheScope: scope,
            service: service,
            preferencesService: FakePreferencesService()
        )
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        store.connect(voteStore: voteStore)
        // The groups come from the cache; the hosted page needs the main run loop, which an async test holds.
        Task { await store.restoreCachedStateIfNeeded() }
        let deadline = Date().addingTimeInterval(5)
        while store.companionVote(forBillID: houseBill.id) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.companionVote(forBillID: houseBill.id)?.targetGuid, legacy, "precondition: the row sits on the legacy guid")
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        APIClient.$current.withValue(transport.client) {
            let host = AccessibilityTreeText.Host(
                page(houseBill, store: store, voteStore: voteStore, size: .large),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            votes.setFeedbackOutcomes = [URLError(.timedOut)]
            Task { await voteStore.updateReasons(billId: legacy, vote: .nay, reasons: [.education]) }
            XCTAssertTrue(host.run(until: { host.strings().contains(BillVoteStore.reasonsNotSavedMessage) }), "in the banner: \(host.text())")
            voteStore.lastError = nil
            host.run(0.3)

            XCTAssertTrue(host.activate("Change your vote", settle: 0.6), host.text())
            XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), host.text())
            XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [legacy, legacy], "the change went to the row's guid")
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier) != nil }), host.text())
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: \(AuthErrorMessages.voteDailyLimit)")
        }
        withExtendedLifetime(voteStore) {}
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

    // MARK: - A vote not saved yet (UX-49)

    /// The page's stores, built here and not with the async `makeCompanionStore`: the hosted page needs the main
    /// run loop, which an async test holds. The bills store writes preferences to `preferences`.
    private func pageStores(
        _ bill: Bill,
        votes: FakeBillVotesService,
        preferences: FakePreferencesService? = nil
    ) -> (store: BillsStore, voteStore: BillVoteStore) {
        let scope = "not-saved-strip-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedManifest = []
        let store = BillsStore(bills: [bill], cacheScope: scope, service: service, preferencesService: preferences ?? FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        store.connect(voteStore: voteStore)
        return (store, voteStore)
    }

    /// A Yea whose write failed with its outcome unknown (offline): the stamp stays, and the refusal strip says
    /// "Not saved yet. Check your connection." with Try again; no 4 s banner asking to "vote again", which the
    /// panel ignores. Change and the same vote send nothing, and the strip comes back when the buttons close. Try
    /// again sends the shown vote again, and the strip stays, its Try again disabled, until the answer; once the
    /// vote is stored the strip goes and the stamp stays. At xxxLarge the strip is the first row of Your vote, with
    /// its Try again.
    func testAVoteNotSavedStaysWithItsStripAndTryAgain() {
        for size in [DynamicTypeSize.large, .xxxLarge] {
            let votes = FakeBillVotesService()
            votes.singleResult = .success(.notVoted)
            votes.setFeedbackError = URLError(.notConnectedToInternet)
            let bill = pageBill()
            let (store, voteStore) = pageStores(bill, votes: votes)
            let transport = RecordingTransport()
            transport.failure = { _ in URLError(.notConnectedToInternet) }
            APIClient.$current.withValue(transport.client) {
                let host = AccessibilityTreeText.Host(
                    page(bill, store: store, voteStore: voteStore, size: size),
                    size: CGSize(width: 390, height: 9000),
                    settle: 0.6
                )
                defer { host.close() }
                XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), "\(size): \(host.text())")
                XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea], "\(size)")

                XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier) != nil }), "\(size): \(host.text())")
                XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.", "\(size)")
                XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier), "Try again", "\(size)")
                XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "\(size): the stamp stays")
                XCTAssertFalse(host.strings().contains("Vote Nay"), "\(size): the vote is not undone")
                let strings = host.strings()
                XCTAssertEqual(strings.filter { $0.contains(AuthErrorMessages.voteNotSaved) }.count, 1, "\(size): once, in the strip, not the banner: \(strings)")
                XCTAssertFalse(strings.contains { $0.localizedCaseInsensitiveContains("vote again") }, "\(size): \(strings)")
                XCTAssertNil(voteStore.lastError, "\(size): nothing app-wide")

                // Change, then the same vote: nothing is sent, and the vote is still not saved.
                XCTAssertTrue(host.activate("Change your vote", settle: 0.6), "\(size)")
                XCTAssertNil(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "\(size): \"Change your vote\" while the buttons are open")
                XCTAssertTrue(host.activate("Vote Yea, your current vote", settle: 0.6), "\(size): \(host.text())")
                XCTAssertEqual(votes.setFeedbackCalls.count, 1, "\(size): the same vote sends nothing")
                XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.", "\(size): back")
                XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier), "\(size)")

                // Try again sends the shown vote again; this time it is stored. While it is out the strip stays, its
                // Try again disabled, so VoiceOver's focus on it is kept.
                votes.setFeedbackError = nil
                let gate = Gate()
                votes.holdSetFeedback = gate
                XCTAssertTrue(host.activate(identifier: BillVoteBarModel.refusalTryAgainIdentifier, settle: 1.2), "\(size)")
                XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea, .yea], "\(size)")
                XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.", "\(size): kept while it sends")
                let busy = host.traits(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier)
                XCTAssertEqual(busy?.contains(.notEnabled), true, "\(size): Try again is disabled while it sends")
                gate.open()
                XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier) == nil }), "\(size): \(host.text())")
                XCTAssertNil(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier), "\(size)")
                XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "\(size): the stamp stays")
                XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.yea), "\(size)")
            }
            withExtendedLifetime(voteStore) {}
        }
    }

    /// A reason picked after a vote not saved yet sends the whole row again (the vote with the reason). Once that is
    /// stored the vote is saved, so the strip and its Try again go; the stamp stays. The vote then gets the Bill row
    /// a stored vote gets, once, so the server follows the bill for this voter (UX-49b).
    func testAReasonSavedAfterAVoteNotSavedYetEndsTheStrip() throws {
        let votes = FakeBillVotesService()
        votes.singleResult = .success(.notVoted)
        votes.setFeedbackError = URLError(.notConnectedToInternet)
        let preferences = FakePreferencesService()
        let bill = pageBill()
        let (store, voteStore) = pageStores(bill, votes: votes, preferences: preferences)
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        try APIClient.$current.withValue(transport.client) {
            let host = AccessibilityTreeText.Host(
                page(bill, store: store, voteStore: voteStore, size: .large),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier) != nil }), host.text())
            XCTAssertEqual(preferences.putCalls, [], "no Bill row for a vote not saved yet")

            votes.setFeedbackError = nil
            let reason = try XCTUnwrap(
                host.identifiers().sorted().first { $0.hasPrefix("bill.feedback.") && $0 != VoteReasonPicker.moreIdentifier },
                host.text()
            )
            XCTAssertTrue(host.activate(identifier: reason), host.text())
            XCTAssertTrue(host.run(until: { votes.setFeedbackCalls.count == 2 }), "the reasons update: \(votes.setFeedbackCalls)")
            XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea, .yea])
            XCTAssertEqual(votes.setFeedbackCalls.last?.reasons.count, 1, "with the reason")

            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier) == nil }), host.text())
            XCTAssertNil(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier))
            XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "the stamp stays")
            assertOneBillRow(preferences, guid: Self.guid, host: host)
        }
        withExtendedLifetime(voteStore) {}
    }

    /// A write that timed out after the server stored it: Results open on the follow-up stats, and the server's row,
    /// read back, is the shown vote, so the strip goes. The vote gets its Bill row, once (UX-49b).
    func testResultsThatOpenOnTheShownVoteEndTheStrip() {
        let votes = FakeBillVotesService()
        votes.singleResult = .success(.notVoted)
        votes.setFeedbackError = URLError(.timedOut)
        votes.batchResult = .success([Self.guid: .voted(BillVotesService.RemoteVote(vote: .yea, votedAt: Date()))])
        let preferences = FakePreferencesService()
        let bill = pageBill()
        let (store, voteStore) = pageStores(bill, votes: votes, preferences: preferences)
        let transport = statsTransport(responses: [Self.statsBody])
        APIClient.$current.withValue(transport.client) {
            let host = AccessibilityTreeText.Host(
                page(bill, store: store, voteStore: voteStore, size: .large),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), host.text())
            XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea])

            XCTAssertTrue(host.run(until: { votes.batchRequests == [[Self.guid]] }), "the row is read back: \(votes.batchRequests)")
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier) == nil }), host.text())
            XCTAssertNil(host.label(ofIdentifier: SealedTally.resultsIdentifier), "Results are open")
            XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "the stamp stays")
            XCTAssertEqual(votes.setFeedbackCalls.count, 1, "nothing sent again")
            assertOneBillRow(preferences, guid: Self.guid, host: host)
        }
        withExtendedLifetime(voteStore) {}
    }

    /// A change from Nay to Yea that timed out, on a page whose first stats load failed: the follow-up stats come back
    /// for the Nay the server still holds, so the strip and its Try again stay, and no Bill row is written for the Yea
    /// (UX-49b).
    func testResultsThatOpenOnTheVoteBeforeAChangeKeepTheStrip() {
        let votes = FakeBillVotesService()
        votes.singleResult = .success(.voted(BillVotesService.RemoteVote(vote: .nay, votedAt: Date().addingTimeInterval(-60))))
        votes.setFeedbackError = URLError(.timedOut)
        votes.batchResult = .success([Self.guid: .voted(BillVotesService.RemoteVote(vote: .nay, votedAt: Date().addingTimeInterval(-60)))])
        let preferences = FakePreferencesService()
        let bill = pageBill()
        let (store, voteStore) = pageStores(bill, votes: votes, preferences: preferences)
        // The first stats load fails (a body that does not decode); the one after the change works.
        let transport = statsTransport(responses: [Data("not stats".utf8), Self.statsBody])
        APIClient.$current.withValue(transport.client) {
            let host = AccessibilityTreeText.Host(
                page(bill, store: store, voteStore: voteStore, size: .large),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertTrue(host.run(until: { host.strings().contains { $0.contains(VoteResultsFormatting.unavailableText) } }), "precondition: no stats: \(host.text())")
            XCTAssertTrue(host.activate("Change your vote", settle: 0.6), host.text())
            XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), host.text())
            XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea])

            XCTAssertTrue(host.run(until: { votes.batchRequests == [[Self.guid]] }), "the row is read back: \(votes.batchRequests)")
            host.run(0.5)
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.", host.text())
            XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier))
            XCTAssertEqual(preferences.putCalls, [], "the Yea is not saved: no Bill row")
        }
        withExtendedLifetime(voteStore) {}
    }

    /// A companion group whose vote row is held under a member's legacy text-version guid: a change from the other
    /// member's page goes to that guid, and when its write fails and a reason saved after it confirms it, the Bill row
    /// goes under that same guid, where the vote is (UX-49b), as it does for a stored vote.
    func testAGroupVoteNotSavedYetGetsItsBillRowUnderTheGuidItWentTo() throws {
        let house = "BILLS-119hr900"
        let legacy = "BILLS-119s456is"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, "BILLS-119s456"], relationship: "identical")
        let houseBill = Bill(
            id: UUID.deterministic(from: house),
            title: "Bill \(house)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            link: "https://www.govinfo.gov/app/details/BILLS-119hr900ih",
            billStatus: .new,
            guid: house,
            userVoted: false,
            isPriority: true
        )
        let votes = FakeBillVotesService()
        votes.setFeedbackError = URLError(.timedOut)
        let preferences = FakePreferencesService()
        let scope = "legacy-guid-bill-row-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedGroups = [group]
        service.cachedManifest = []
        let store = BillsStore(
            bills: [houseBill, companionTestBill(legacy, userVote: .nay)],
            cacheScope: scope,
            service: service,
            preferencesService: preferences
        )
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        store.connect(voteStore: voteStore)
        // The groups come from the cache; the hosted page needs the main run loop, which an async test holds.
        Task { await store.restoreCachedStateIfNeeded() }
        let deadline = Date().addingTimeInterval(5)
        while store.companionVote(forBillID: houseBill.id) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(store.companionVote(forBillID: houseBill.id)?.targetGuid, legacy, "precondition: the row sits on the legacy guid")
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        try APIClient.$current.withValue(transport.client) {
            let host = AccessibilityTreeText.Host(
                page(houseBill, store: store, voteStore: voteStore, size: .large),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertTrue(host.activate("Change your vote", settle: 0.6), host.text())
            XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier) != nil }), host.text())
            XCTAssertEqual(preferences.putCalls, [], "no Bill row for a vote not saved yet")

            votes.setFeedbackError = nil
            let reason = try XCTUnwrap(
                host.identifiers().sorted().first { $0.hasPrefix("bill.feedback.") && $0 != VoteReasonPicker.moreIdentifier },
                host.text()
            )
            XCTAssertTrue(host.activate(identifier: reason), host.text())
            XCTAssertTrue(host.run(until: { votes.setFeedbackCalls.count == 2 }), "the reasons update: \(votes.setFeedbackCalls)")
            XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [legacy, legacy], "the change and its reasons went to the row's guid")
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier) == nil }), host.text())
            assertOneBillRow(preferences, guid: legacy, host: host)
        }
        withExtendedLifetime(voteStore) {}
    }

    // MARK: - A vote not saved yet, when its page opens again (APPF-30 step 2)

    /// Counts the strip's alerts (`voteStripAlert`): the error haptic and VoiceOver's focus on the strip.
    @MainActor
    private final class StripAlerts {
        var count = 0
    }

    private func page(_ bill: Bill, store: BillsStore, voteStore: BillVoteStore, alerts: StripAlerts) -> some View {
        page(bill, store: store, voteStore: voteStore, size: .large)
            .environment(\.voteStripAlert, { alerts.count += 1 })
    }

    /// A write's result, set from the task that waits for it.
    @MainActor
    private final class WriteOutcome {
        var result: VoteWriteResult?
    }

    /// Runs the main run loop until `condition` holds (5 s at most): the hosted page needs it, which an async test holds.
    private func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// A vote cache saved in a throwaway defaults suite: one made again on it is the next launch's.
    private func savedVoteCache() throws -> @MainActor () -> BillVoteCache {
        let suiteName = "VoteRefusalRollbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let key = "BillVoteCache.v1.not-saved-relaunch-\(UUID().uuidString)"
        return { BillVoteCache(config: BillVoteCache.Config(persistenceKey: key), defaults: defaults) }
    }

    /// A Yea whose write failed offline, then the page is left and opened again: the stamp shows with the strip "Not
    /// saved yet. Check your connection." and Try again, read again on open, quietly: the write that failed on the page
    /// brought the error haptic and VoiceOver's focus, the page opened again brings neither.
    func testAPageReopenedOnAVoteNotSavedYetShowsTheStripQuietly() {
        let votes = FakeBillVotesService()
        votes.singleResult = .success(.notVoted)
        votes.setFeedbackError = URLError(.notConnectedToInternet)
        let bill = pageBill()
        let (store, voteStore) = pageStores(bill, votes: votes)
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        APIClient.$current.withValue(transport.client) {
            let failedHere = StripAlerts()
            do {
                let host = AccessibilityTreeText.Host(
                    page(bill, store: store, voteStore: voteStore, alerts: failedHere),
                    size: CGSize(width: 390, height: 9000),
                    settle: 0.6
                )
                defer { host.close() }
                XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), host.text())
                XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier) != nil }), host.text())
                XCTAssertTrue(host.run(until: { failedHere.count == 1 }), "the failure on the page alerts")
            }
            XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea], "precondition")
            let readsBefore = votes.singleRequests.count

            let reopened = StripAlerts()
            let host = AccessibilityTreeText.Host(
                page(bill, store: store, voteStore: voteStore, alerts: reopened),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier) != nil }), host.text())
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.")
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier), "Try again")
            XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "the stamp shows the vote")
            XCTAssertTrue(host.run(until: { votes.singleRequests.count > readsBefore }), "the vote is read again on open")
            host.run(0.6)
            XCTAssertEqual(reopened.count, 0, "no error haptic and no VoiceOver focus on open")
            XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier), "the read that found no vote keeps it")
            XCTAssertEqual(votes.setFeedbackCalls.count, 1, "nothing is sent on open")
        }
        withExtendedLifetime(voteStore) {}
    }

    /// A relaunch (fresh stores on the same saved cache) after a Yea whose write failed: the page shows the stamp with the
    /// strip and Try again, quietly. Try again that the server stores ends the strip, clears the mark on disk, and writes
    /// the Bill row once, so the server follows the bill for this voter.
    func testARelaunchKeepsTheVoteNotSavedYetAndTryAgainSavesIt() throws {
        let openCache = try savedVoteCache()
        let votes = FakeBillVotesService()
        votes.singleResult = .success(.notVoted)
        votes.setFeedbackError = URLError(.notConnectedToInternet)
        let bill = pageBill()

        // The launch that voted, with no page: the write fails.
        let (earlierStore, _) = pageStores(bill, votes: votes)
        let earlierVotes = BillVoteStore(cache: openCache(), service: votes)
        earlierStore.connect(voteStore: earlierVotes)
        let outcome = WriteOutcome()
        Task { outcome.result = await earlierStore.submitVote(billID: bill.id, vote: .yea, watch: nil)?.value }
        spin(until: { outcome.result != nil })
        XCTAssertEqual(outcome.result, .unconfirmed, "precondition")
        let votedBill = try XCTUnwrap(earlierStore.bill(for: bill.id))

        // The next launch.
        let preferences = FakePreferencesService()
        let (store, _) = pageStores(votedBill, votes: votes, preferences: preferences)
        let voteStore = BillVoteStore(cache: openCache(), service: votes)
        store.connect(voteStore: voteStore)
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea], "kept across the relaunch")
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        APIClient.$current.withValue(transport.client) {
            let alerts = StripAlerts()
            let host = AccessibilityTreeText.Host(
                page(votedBill, store: store, voteStore: voteStore, alerts: alerts),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier) != nil }), host.text())
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.")
            XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier))
            host.run(0.6)
            XCTAssertEqual(alerts.count, 0, "no error haptic and no VoiceOver focus on open")
            XCTAssertEqual(preferences.putCalls, [])

            votes.setFeedbackError = nil
            XCTAssertTrue(host.activate(identifier: BillVoteBarModel.refusalTryAgainIdentifier, settle: 1.2), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier) == nil }), host.text())
            XCTAssertNotNil(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "the stamp stays")
            XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea, .yea])
            XCTAssertEqual(voteStore.unsavedVotes, [:])
            XCTAssertEqual(openCache().unsavedVotes, [:], "cleared on disk")
            assertOneBillRow(preferences, guid: Self.guid, host: host)
            XCTAssertEqual(alerts.count, 0)
        }
        withExtendedLifetime((earlierVotes, voteStore)) {}
    }

    /// A companion group whose vote row sits on a member's legacy text-version guid: a change made on the group that
    /// failed is marked under that guid, and after a relaunch the group's page shows the strip and Try again quietly.
    /// Try again goes to that guid, and once stored the Bill row goes there too.
    func testARelaunchKeepsAGroupVoteNotSavedYetOnTheLegacyGuid() throws {
        let house = "BILLS-119hr900"
        let legacy = "BILLS-119s456is"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, "BILLS-119s456"], relationship: "identical")
        let houseBill = Bill(
            id: UUID.deterministic(from: house),
            title: "Bill \(house)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            link: "https://www.govinfo.gov/app/details/BILLS-119hr900ih",
            billStatus: .new,
            guid: house,
            userVoted: false,
            isPriority: true
        )
        let openCache = try savedVoteCache()
        let votes = FakeBillVotesService()
        votes.setFeedbackError = URLError(.timedOut)
        func launch(_ bills: [Bill], preferences: FakePreferencesService) -> (BillsStore, BillVoteStore) {
            let scope = "legacy-guid-relaunch-tests-\(UUID().uuidString)"
            addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
            let service = FakeBillsService()
            service.cachedGroups = [group]
            service.cachedManifest = []
            let store = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: preferences)
            let voteStore = BillVoteStore(cache: openCache(), service: votes)
            store.connect(voteStore: voteStore)
            Task { await store.restoreCachedStateIfNeeded() }
            spin(until: { store.companionVote(forBillID: houseBill.id) != nil })
            return (store, voteStore)
        }

        // The launch that changed the Nay to a Yea: it goes to the legacy guid, and fails.
        let (earlierStore, earlierVotes) = launch([houseBill, companionTestBill(legacy, userVote: .nay)], preferences: FakePreferencesService())
        XCTAssertEqual(earlierStore.companionVote(forBillID: houseBill.id)?.targetGuid, legacy, "precondition")
        let outcome = WriteOutcome()
        Task { outcome.result = await earlierStore.submitVote(billID: houseBill.id, vote: .yea, watch: nil)?.value }
        spin(until: { outcome.result != nil })
        XCTAssertEqual(outcome.result, .unconfirmed, "precondition")
        XCTAssertEqual(earlierVotes.unsavedVotes, [legacy: .yea])

        // The next launch.
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch([houseBill, companionTestBill(legacy, userVote: .yea)], preferences: preferences)
        XCTAssertEqual(voteStore.unsavedVotes, [legacy: .yea])
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        APIClient.$current.withValue(transport.client) {
            let alerts = StripAlerts()
            let host = AccessibilityTreeText.Host(
                page(houseBill, store: store, voteStore: voteStore, alerts: alerts),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier) != nil }), host.text())
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.")
            host.run(0.6)
            XCTAssertEqual(alerts.count, 0, "quiet on open")

            votes.setFeedbackError = nil
            XCTAssertTrue(host.activate(identifier: BillVoteBarModel.refusalTryAgainIdentifier, settle: 1.2), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier) == nil }), host.text())
            XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [legacy, legacy], "Try again went where the vote is")
            XCTAssertEqual(voteStore.unsavedVotes, [:])
            assertOneBillRow(preferences, guid: legacy, host: host)
        }
        withExtendedLifetime((earlierVotes, voteStore)) {}
    }

    /// Exactly one `PUT /preferences` once the page has run a little longer: the Bill row for `guid` (type "bill",
    /// category "", the backend contract), which makes the server follow the bill for this voter.
    private func assertOneBillRow(
        _ preferences: FakePreferencesService,
        guid: String,
        host: AccessibilityTreeText.Host,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(host.run(until: { !preferences.putCalls.isEmpty }), "the Bill row is written", file: file, line: line)
        host.run(0.3)
        XCTAssertEqual(preferences.putCalls.count, 1, "once: \(preferences.putCalls)", file: file, line: line)
        let saved = preferences.putCalls.flatMap { $0 }
        XCTAssertEqual(saved.map(\.preference), [guid], file: file, line: line)
        XCTAssertEqual(saved.map(\.type), ["bill"], file: file, line: line)
        XCTAssertEqual(saved.map(\.category), [""], file: file, line: line)
    }

    /// Stats for `guid`, over the floor.
    private static let statsBody = Data(#"""
    {"billId":"BILLS-119hr4100","totals":{"votes":46,"yea":25,"nay":15,"abstain":6,"decisionVotes":40,"yeaPct":62.5},
     "segments":{"verified":{"votes":12,"yea":7,"nay":5,"abstain":0,"decisionVotes":12,"yeaPct":58.3},
                 "selfAttested":{"votes":34,"yea":18,"nay":10,"abstain":6,"decisionVotes":28,"yeaPct":64.3}},
     "rollups":{"byState":{},"byDistrict":{}}}
    """#.utf8)

    /// The page's requests fail as offline, except `GET /bill-stats`, which takes `responses` in turn.
    private func statsTransport(responses: [Data]) -> RecordingTransport {
        let transport = RecordingTransport()
        transport.responses = responses
        transport.failure = { request in request.path == "bill-stats" ? nil : URLError(.notConnectedToInternet) }
        return transport
    }

    /// The strip's Try again, in the panel and as a row of Your vote, beside the words and under them at the
    /// accessibility sizes. A refused vote's strip has none: its vote is gone and the buttons are back.
    func testTheNotSavedStripOffersTryAgain() throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            for placement in [VoteStrip.Placement.panel, .page] {
                var tries = 0
                let strip = VoteStrip(kind: .refusal(AuthErrorMessages.voteNotSaved), placement: placement, onTryAgain: { tries += 1 })
                let host = AccessibilityTreeText.Host(strip.environment(\.dynamicTypeSize, size), size: CGSize(width: 351, height: 600))
                defer { host.close() }
                XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: Not saved yet. Check your connection.", "\(size) \(placement)")
                XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier), "Try again", "\(size) \(placement)")
                let words = try XCTUnwrap(host.frame(ofIdentifier: BillVoteBarModel.refusalIdentifier))
                let button = try XCTUnwrap(host.frame(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier))
                if size.isAccessibilitySize {
                    XCTAssertGreaterThanOrEqual(button.minY, words.maxY - 1, "\(placement): under the words")
                } else {
                    XCTAssertGreaterThanOrEqual(button.minX, words.maxX - 1, "\(placement): beside the words")
                }
                XCTAssertTrue(host.activate(identifier: BillVoteBarModel.refusalTryAgainIdentifier))
                XCTAssertEqual(tries, 1, "\(size) \(placement)")
            }
        }
        let refused = AccessibilityTreeText.Host(VoteStrip(kind: .refusal(AuthErrorMessages.voteDailyLimit)), size: CGSize(width: 351, height: 300))
        defer { refused.close() }
        XCTAssertNil(refused.label(ofIdentifier: BillVoteBarModel.refusalTryAgainIdentifier))
    }

    /// An error about another bill never shows on this bill's page, also when it arrives while the page is open
    /// (a reasons update sent as that bill's page was left); one about this bill does. A bill-list error left from
    /// before the page opened is cleared, not shown.
    func testThePagesBannerShowsOnlyItsOwnBillsErrors() {
        let votes = FakeBillVotesService()
        votes.singleResult = .success(.notVoted)
        let bill = pageBill()
        let (store, voteStore) = pageStores(bill, votes: votes)
        store.errorMessage = BillsStore.loadFailedBanner
        let transport = RecordingTransport()
        transport.failure = { _ in URLError(.notConnectedToInternet) }
        APIClient.$current.withValue(transport.client) {
            let host = AccessibilityTreeText.Host(
                page(bill, store: store, voteStore: voteStore, size: .large),
                size: CGSize(width: 390, height: 9000),
                settle: 0.6
            )
            defer { host.close() }
            XCTAssertNil(store.errorMessage, "cleared when the page opened")
            XCTAssertFalse(host.strings().contains(BillsStore.loadFailedBanner), host.text())

            votes.setFeedbackError = URLError(.timedOut)
            Task { await voteStore.updateReasons(billId: "BILLS-119s4200", vote: .yea, reasons: [.education]) }
            XCTAssertTrue(host.run(until: { voteStore.lastError != nil }))
            host.run(0.3)
            XCTAssertFalse(host.strings().contains(BillVoteStore.reasonsNotSavedMessage), "about another bill: \(host.text())")

            Task { await voteStore.updateReasons(billId: Self.guid, vote: .yea, reasons: [.education]) }
            XCTAssertTrue(host.run(until: { host.strings().contains(BillVoteStore.reasonsNotSavedMessage) }), "about this bill: \(host.text())")
        }
        withExtendedLifetime(voteStore) {}
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
        XCTAssertEqual(ledger.finish(kept, result: .notSaved), .keep, "cancelled, or overtaken")

        // A write whose outcome is unknown keeps the vote and says it is not saved yet (UX-49); an Abstain keeps
        // its bills off the Bills list.
        let unsaved = ledger.begin(dismissing: [first])
        XCTAssertEqual(ledger.finish(unsaved, result: .unconfirmed), .unsaved)
        XCTAssertEqual(ledger.dismissedBillIDs, [])
        let overtaken = ledger.begin()
        let newer = ledger.begin()
        XCTAssertEqual(ledger.finish(overtaken, result: .unconfirmed), .keep, "the newer vote decides")
        XCTAssertEqual(ledger.finish(newer, result: .stored), .keep)
    }
}
