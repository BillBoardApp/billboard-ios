import XCTest
@testable import Billboard

/// `BillVoteStore` against a fake votes service: optimistic votes, reasons updates, the
/// per-bill write chain, fetch error handling, and the copy and rollback for server codes
/// (spec D 2.8.4). The cache does not persist.
final class BillVoteStoreTests: XCTestCase {
    private let billId = "BILLS-119hr1ih"

    @MainActor
    private func makeStore(_ service: FakeBillVotesService) -> BillVoteStore {
        let cache = BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil))
        return BillVoteStore(cache: cache, service: service)
    }

    // MARK: - Voting

    @MainActor
    func testSetVoteUpdatesStateAndSendsTheVoteWithReasons() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)

        let stored = await store.setVote(billId: " \(billId) ", vote: .yea, reasons: [.healthcare, .economicImpact])

        XCTAssertTrue(stored)
        XCTAssertEqual(store.vote(for: billId), .voted(.yea))
        XCTAssertEqual(
            service.setFeedbackCalls,
            [.init(billId: billId, feedback: .yea, reasons: ["healthcare", "economic_impact"])]
        )
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testFailedVoteKeepsTheOptimisticStateAndReportsIt() async {
        let service = FakeBillVotesService()
        service.setFeedbackError = FakeServiceError()
        let store = makeStore(service)

        let stored = await store.setVote(billId: billId, vote: .nay)

        XCTAssertFalse(stored)
        XCTAssertEqual(store.vote(for: billId), .voted(.nay))
        // Nothing retries a failed vote, so the copy no longer says it will.
        XCTAssertEqual(store.lastError, "Your vote may not have saved. Check your connection and vote again.")
    }

    @MainActor
    func testAbstainIsSentButDoesNotCountAsAVote() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)

        await store.setVote(billId: billId, vote: .abstain)

        XCTAssertEqual(store.vote(for: billId), .notVoted)
        XCTAssertEqual(service.setFeedbackCalls.map(\.feedback), [.abstain])
    }

    @MainActor
    func testBlankBillIdIsIgnored() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)

        let stored = await store.setVote(billId: "  ", vote: .yea)
        let updated = await store.updateReasons(billId: "", vote: .yea, reasons: [.healthcare])

        XCTAssertFalse(stored)
        XCTAssertFalse(updated)
        XCTAssertTrue(service.setFeedbackCalls.isEmpty)
    }

    // MARK: - Reasons

    @MainActor
    func testUpdateReasonsResendsTheVoteWithTheNewReasons() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)
        await store.setVote(billId: billId, vote: .nay)

        let updated = await store.updateReasons(billId: billId, vote: .nay, reasons: [.taxesSpending])

        XCTAssertTrue(updated)
        XCTAssertEqual(
            service.setFeedbackCalls,
            [
                .init(billId: billId, feedback: .nay, reasons: []),
                .init(billId: billId, feedback: .nay, reasons: ["taxes_spending"])
            ]
        )
        XCTAssertEqual(store.vote(for: billId), .voted(.nay))
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testFailedReasonsUpdateReportsItAndKeepsTheVote() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)
        await store.setVote(billId: billId, vote: .yea)
        service.setFeedbackError = FakeServiceError()

        let updated = await store.updateReasons(billId: billId, vote: .yea, reasons: [.education])

        XCTAssertFalse(updated)
        XCTAssertEqual(store.lastError, "Your reasons could not be saved. Try again in a moment.")
        XCTAssertEqual(store.vote(for: billId), .voted(.yea))
    }

    @MainActor
    func testReasonsRefusedForTheDailyLimitKeepTheVoteAndSaySo() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)
        await store.setVote(billId: billId, vote: .yea)
        service.setFeedbackError = backendError("VOTE_DAILY_LIMIT")

        let updated = await store.updateReasons(billId: billId, vote: .yea, reasons: [.education])

        XCTAssertFalse(updated)
        XCTAssertEqual(
            store.lastError,
            "You've reached today's limit of 200 votes, so your reasons weren't saved. You can add them after midnight UTC."
        )
        XCTAssertEqual(store.vote(for: billId), .voted(.yea), "the vote was stored before the reasons")
    }

    @MainActor
    func testReasonsUpdateWaitsForTheVoteItBelongsTo() async {
        let service = FakeBillVotesService()
        let gate = Gate()
        service.holdSetFeedback = gate
        let voteStarted = expectation(description: "vote write started")
        service.onSetFeedback = { call in
            if call.reasons.isEmpty { voteStarted.fulfill() }
        }
        let store = makeStore(service)

        let voteTask = Task { await store.setVote(billId: billId, vote: .yea) }
        await fulfillment(of: [voteStarted], timeout: 5)

        let reasonsTask = Task { await store.updateReasons(billId: billId, vote: .yea, reasons: [.publicSafety]) }
        for _ in 0..<20 { await Task.yield() }

        // The reasons write is queued behind the vote that is still in flight.
        XCTAssertEqual(service.setFeedbackCalls.count, 1)

        gate.open()
        let voteStored = await voteTask.value
        let reasonsStored = await reasonsTask.value

        XCTAssertTrue(voteStored)
        XCTAssertTrue(reasonsStored)
        XCTAssertEqual(service.setFeedbackCalls.map(\.reasons), [[], ["public_safety"]])
    }

    // MARK: - Fetching

    @MainActor
    func testFetchVotesAppliesRemoteStatesAndLeavesOmittedBillsUnknown() async {
        let service = FakeBillVotesService()
        let votedAt = Date(timeIntervalSince1970: 1_790_000_000)
        service.batchResult = .success([
            "A": .voted(.init(vote: .nay, votedAt: votedAt)),
            "B": .notVoted
        ])
        let store = makeStore(service)

        await store.fetchVotes(for: ["A", " B ", "C", "A"])

        XCTAssertEqual(service.batchRequests.count, 1)
        XCTAssertEqual(Set(service.batchRequests[0]), ["A", "B", "C"])
        XCTAssertEqual(store.vote(for: "A"), .voted(.nay))
        XCTAssertEqual(store.vote(for: "B"), .notVoted)
        XCTAssertEqual(store.vote(for: "C"), .unknown)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testFetchVotesSkipsBillsAlreadyKnown() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)
        await store.setVote(billId: "A", vote: .yea)

        await store.fetchVotes(for: ["A", "B"])

        XCTAssertEqual(service.batchRequests, [["B"]])
    }

    @MainActor
    func testFetchVotesFailureReportsIt() async {
        let service = FakeBillVotesService()
        service.batchResult = .failure(FakeServiceError())
        let store = makeStore(service)

        await store.fetchVotes(for: ["A"])

        XCTAssertEqual(store.lastError, "Couldn't check your votes. Pull down to try again.")
        XCTAssertEqual(store.vote(for: "A"), .unknown)
    }

    @MainActor
    func testFetchVoteIfNeededReturnsTheMessageWithoutReportingWhenAsked() async {
        let service = FakeBillVotesService()
        service.singleResult = .failure(FakeServiceError())
        let store = makeStore(service)

        let message = await store.fetchVoteIfNeeded(for: billId, reportError: false)

        XCTAssertEqual(message, "Couldn't check your vote on this bill.")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(service.singleRequests, [billId])
    }

    @MainActor
    func testFetchVoteIfNeededStoresTheRemoteVote() async {
        let service = FakeBillVotesService()
        service.singleResult = .success(.voted(.init(vote: .yea, votedAt: Date())))
        let store = makeStore(service)

        let message = await store.fetchVoteIfNeeded(for: billId)

        XCTAssertNil(message)
        XCTAssertEqual(store.vote(for: billId), .voted(.yea))
    }

    // MARK: - Server codes (spec D 2.8.4)

    @MainActor
    func testAVoteRefusedForTheDailyLimitRollsBackToNotVoted() async {
        let service = FakeBillVotesService()
        service.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let store = makeStore(service)
        service.singleResult = .success(.notVoted)
        await store.fetchVoteIfNeeded(for: billId)
        XCTAssertEqual(store.vote(for: billId), .notVoted, "precondition")

        let stored = await store.setVote(billId: billId, vote: .yea)

        XCTAssertFalse(stored)
        XCTAssertEqual(store.vote(for: billId), .notVoted)
        XCTAssertNil(store.heldVote(for: billId))
        XCTAssertEqual(
            store.lastError,
            "You've reached today's limit of 200 votes. This vote wasn't saved. You can vote again after midnight UTC."
        )
    }

    @MainActor
    func testARefusedVoteOnABillNeverCheckedLeavesItUnknown() async {
        let service = FakeBillVotesService()
        service.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let store = makeStore(service)

        await store.setVote(billId: billId, vote: .nay)

        XCTAssertEqual(store.vote(for: billId), .unknown, "the bill is checked again instead of showing a vote")
        XCTAssertNil(store.statesByBillId[billId])
    }

    @MainActor
    func testARefusedChangeRestoresTheVoteBeforeIt() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)
        await store.setVote(billId: billId, vote: .yea)
        service.setFeedbackError = backendError("VOTE_DAILY_LIMIT")

        await store.setVote(billId: billId, vote: .nay)

        XCTAssertEqual(store.vote(for: billId), .voted(.yea))
        XCTAssertEqual(service.setFeedbackCalls.map(\.feedback), [.yea, .nay])
    }

    @MainActor
    func testARefusedVoteRestoresAnAbstainRow() async {
        let service = FakeBillVotesService()
        let store = makeStore(service)
        await store.setVote(billId: billId, vote: .abstain)
        service.setFeedbackError = backendError("VOTE_DAILY_LIMIT")

        await store.setVote(billId: billId, vote: .yea)

        XCTAssertEqual(store.vote(for: billId), .notVoted)
        XCTAssertEqual(store.heldVote(for: billId), .abstain)
    }

    @MainActor
    func testARefusedVoteDoesNotUndoANewerVoteWaitingBehindIt() async {
        let service = FakeBillVotesService()
        let gate = Gate()
        service.holdSetFeedback = gate
        service.setFeedbackOutcomes = [backendError("VOTE_DAILY_LIMIT"), nil]
        let firstStarted = expectation(description: "first vote write started")
        service.onSetFeedback = { call in
            if call.feedback == .yea { firstStarted.fulfill() }
        }
        let store = makeStore(service)

        let first = Task { await store.setVote(billId: billId, vote: .yea) }
        await fulfillment(of: [firstStarted], timeout: 5)
        let second = Task { await store.setVote(billId: billId, vote: .nay) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.vote(for: billId), .voted(.nay), "the newer vote shows at once")

        gate.open()
        let firstStored = await first.value
        let secondStored = await second.value

        XCTAssertFalse(firstStored)
        XCTAssertTrue(secondStored)
        XCTAssertEqual(store.vote(for: billId), .voted(.nay))
        XCTAssertEqual(service.setFeedbackCalls.map(\.feedback), [.yea, .nay])
    }

    @MainActor
    func testWhenEveryQueuedVoteIsRefusedTheBillReturnsToItsFirstState() async {
        let service = FakeBillVotesService()
        service.setFeedbackOutcomes = [nil, backendError("VOTE_DAILY_LIMIT"), backendError("VOTE_DAILY_LIMIT")]
        let store = makeStore(service)
        let firstStored = await store.setVote(billId: billId, vote: .yea)
        XCTAssertTrue(firstStored, "precondition: the server holds Yea")
        let gate = Gate()
        service.holdSetFeedback = gate

        let started = expectation(description: "second write started")
        service.onSetFeedback = { call in
            if call.feedback == .nay { started.fulfill() }
        }
        let second = Task { await store.setVote(billId: billId, vote: .nay) }
        await fulfillment(of: [started], timeout: 5)
        let third = Task { await store.setVote(billId: billId, vote: .abstain) }
        for _ in 0..<20 { await Task.yield() }

        gate.open()
        _ = await second.value
        _ = await third.value

        XCTAssertEqual(store.vote(for: billId), .voted(.yea), "back to the vote the server holds")
        XCTAssertEqual(store.heldVote(for: billId), .yea)
    }

    @MainActor
    func testAStoredEarlierVoteBecomesTheRollbackForANewerRefusedOne() async {
        let service = FakeBillVotesService()
        let gate = Gate()
        service.holdSetFeedback = gate
        service.setFeedbackOutcomes = [nil, backendError("VOTE_DAILY_LIMIT")]
        let firstStarted = expectation(description: "first vote write started")
        service.onSetFeedback = { call in
            if call.feedback == .yea { firstStarted.fulfill() }
        }
        let store = makeStore(service)

        let first = Task { await store.setVote(billId: billId, vote: .yea) }
        await fulfillment(of: [firstStarted], timeout: 5)
        let second = Task { await store.setVote(billId: billId, vote: .nay) }
        for _ in 0..<20 { await Task.yield() }

        gate.open()
        let firstStored = await first.value
        let secondStored = await second.value

        XCTAssertTrue(firstStored)
        XCTAssertFalse(secondStored)
        XCTAssertEqual(store.vote(for: billId), .voted(.yea), "the server holds the first vote")
    }

    @MainActor
    func testAPushThatClearsTheVoteMeansARefusedVoteRollsBackToUnknown() async {
        let service = FakeBillVotesService()
        let gate = Gate()
        service.holdSetFeedback = gate
        service.setFeedbackOutcomes = [backendError("VOTE_DAILY_LIMIT")]
        let started = expectation(description: "vote write started")
        service.onSetFeedback = { _ in started.fulfill() }
        let store = makeStore(service)
        service.singleResult = .success(.voted(.init(vote: .nay, votedAt: Date())))
        await store.fetchVoteIfNeeded(for: billId)

        let vote = Task { await store.setVote(billId: billId, vote: .yea) }
        await fulfillment(of: [started], timeout: 5)
        store.clearVote(for: billId) // an "updated" push: the server cleared the Nay
        gate.open()
        _ = await vote.value

        XCTAssertEqual(store.vote(for: billId), .unknown)
    }

    @MainActor
    func testCodedRefusalsRollBackAndShowTheirCopy() async {
        // `POST /feedback` answers each of these before it stores the vote (APPF-27).
        let cases: [(code: String, message: String)] = [
            ("APP_ATTEST_REQUIRED", "We couldn't confirm this is the Billboard app on your iPhone. Update the app and try again."),
            ("APP_ATTEST_FAILED", "We couldn't confirm this is the Billboard app on your iPhone. Update the app and try again."),
            ("APP_ATTEST_UNKNOWN_KEY", "We couldn't confirm this is the Billboard app on your iPhone. Update the app and try again."),
            ("DEVICE_ACCOUNT_LIMIT", "This iPhone has reached the limit of 3 Billboard accounts."),
            ("APP_UPDATE_REQUIRED", "This version of Billboard can't vote or create accounts any more. Update to continue."),
            ("APP_ATTEST_UNAVAILABLE", "Your vote may not have saved. Check your connection and vote again."),
            ("ADULT_REQUIRED", "Confirm your age before doing that."),
            ("ACCOUNT_INELIGIBLE", "This account isn't eligible to do that."),
            ("ACCOUNT_DELETION_IN_PROGRESS", "This account is being deleted.")
        ]
        for (code, message) in cases {
            let service = FakeBillVotesService()
            service.setFeedbackError = backendError(code)
            let store = makeStore(service)
            service.singleResult = .success(.notVoted)
            await store.fetchVoteIfNeeded(for: billId)

            let result = await store.submitVote(billId: billId, vote: .nay)

            XCTAssertEqual(result, .rolledBack(restored: .notVoted), code)
            XCTAssertEqual(store.lastError, message, code)
            XCTAssertEqual(store.vote(for: billId), .notVoted, "the refused vote rolls back: \(code)")
        }
    }

    @MainActor
    func testFailuresThatMayHaveStoredTheVoteKeepItAndShowTheirCopy() async {
        let cases: [(error: Error, message: String)] = [
            (backendError("SOMETHING_NEW"), "Your vote may not have saved. Check your connection and vote again."),
            (httpStatusError(503), "Your vote may not have saved. Check your connection and vote again."),
            (httpStatusError(429), "Your vote may not have saved. Check your connection and vote again."),
            (URLError(.notConnectedToInternet), "Your vote may not have saved. Check your connection and vote again.")
        ]
        for (error, message) in cases {
            let service = FakeBillVotesService()
            service.setFeedbackError = error
            let store = makeStore(service)

            let result = await store.submitVote(billId: billId, vote: .nay)

            XCTAssertEqual(result, .notSaved, "\(error)")
            XCTAssertEqual(store.lastError, message, "\(error)")
            XCTAssertEqual(store.vote(for: billId), .voted(.nay), "an unknown outcome keeps the vote: \(error)")
        }
    }

    @MainActor
    func testACancelledVoteWriteStaysQuietAndKeepsTheVote() async {
        let service = FakeBillVotesService()
        service.setFeedbackError = CancellationError()
        let store = makeStore(service)

        let stored = await store.setVote(billId: billId, vote: .yea)

        XCTAssertFalse(stored)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.vote(for: billId), .voted(.yea))
    }

    @MainActor
    func testVoteFailureMappingRollsBackEveryCodedRefusal() {
        for code in ["VOTE_DAILY_LIMIT", "APP_ATTEST_REQUIRED", "APP_ATTEST_FAILED", "APP_ATTEST_UNKNOWN_KEY",
                     "DEVICE_ACCOUNT_LIMIT", "APP_UPDATE_REQUIRED", "APP_ATTEST_UNAVAILABLE", "ADULT_REQUIRED",
                     "ACCOUNT_INELIGIBLE", "ACCOUNT_DELETION_IN_PROGRESS"] {
            XCTAssertTrue(BillVoteStore.voteFailure(for: backendError(code)).rollsBack, code)
        }
        XCTAssertFalse(BillVoteStore.voteFailure(for: backendError("SOMETHING_NEW")).rollsBack, "an unknown code")
        XCTAssertFalse(BillVoteStore.voteFailure(for: httpStatusError(500)).rollsBack, "no code")
        XCTAssertFalse(BillVoteStore.voteFailure(for: URLError(.timedOut)).rollsBack, "offline or timed out")
        XCTAssertFalse(BillVoteStore.voteFailure(for: FakeServiceError()).rollsBack)
    }

    // MARK: - Companion groups (APPF-23)

    private let group = BillCompanionGroup(
        primaryGuid: "BILLS-119hr900",
        memberGuids: ["BILLS-119hr900", "BILLS-119s456"],
        relationship: "identical"
    )

    @MainActor
    func testHeldVoteIncludesAnAbstainThatVoteForReportsAsNotVoted() async {
        let store = makeStore(FakeBillVotesService())

        await store.setVote(billId: billId, vote: .abstain)

        XCTAssertEqual(store.vote(for: billId), .notVoted)
        XCTAssertEqual(store.heldVote(for: billId), .abstain)
        XCTAssertNil(store.heldVote(for: "BILLS-119s1"))

        store.clearVote(for: billId)
        XCTAssertNil(store.heldVote(for: billId))
    }

    @MainActor
    func testCompanionVoteFollowsTheVoteMatrix() async {
        let store = makeStore(FakeBillVotesService())
        XCTAssertEqual(store.companionVote(for: group).targetGuid, "BILLS-119hr900")
        XCTAssertFalse(store.isAnyMemberVoted(group))

        await store.setVote(billId: "BILLS-119s456", vote: .nay)
        XCTAssertEqual(store.companionVote(for: group).targetGuid, "BILLS-119s456")
        XCTAssertEqual(store.companionVote(for: group).effectiveVote, .nay)
        XCTAssertTrue(store.isAnyMemberVoted(group))

        await store.setVote(billId: "BILLS-119hr900", vote: .yea)
        let both = store.companionVote(for: group)
        XCTAssertEqual(both.effectiveVote, .yea)
        XCTAssertEqual(both.targetGuid, "BILLS-119hr900")
        XCTAssertEqual(both.conflict?.other.vote, .nay)
    }

    @MainActor
    func testFetchVotesForAGroupAsksForEveryMemberInOneRequest() async {
        let service = FakeBillVotesService()
        service.batchResult = .success(["BILLS-119s456": .voted(.init(vote: .yea, votedAt: Date())), "BILLS-119hr900": .notVoted])
        let store = makeStore(service)

        await store.fetchVotes(for: group)

        XCTAssertEqual(service.batchRequests.map(Set.init), [Set(group.memberGuids)])
        XCTAssertEqual(store.companionVote(for: group).effectiveVote, .yea)
    }
}
