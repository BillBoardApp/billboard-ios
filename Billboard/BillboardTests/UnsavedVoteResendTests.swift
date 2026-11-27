import SwiftUI
import XCTest
@testable import Billboard

/// APPF-30 step 2, outside bill detail: once the phone is back online a vote not saved yet is sent once more on its own
/// (project decision 2026-11-23), after a read of the rows, and through the bills store so the refusal rules hold
/// (APPF-27); a later vote from another device replaces it in both stores; and the phone counts as back online on its
/// first online report and after an offline one.
@MainActor
final class UnsavedVoteResendTests: XCTestCase {
    private nonisolated static let guid = "BILLS-119hr4100"

    private func bill(_ guid: String = UnsavedVoteResendTests.guid) -> Bill {
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

    /// A throwaway defaults suite and the key the vote cache is saved under: stores made again on them are the next
    /// launch.
    private struct Disk {
        let defaults: UserDefaults
        let key: String
        let scope: String
    }

    private func makeDisk() throws -> Disk {
        let suiteName = "UnsavedVoteResendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let scope = "unsaved-resend-tests-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
            BillsStore.clearCachedBills(scope: scope)
        }
        return Disk(defaults: defaults, key: "BillVoteCache.v1.\(scope)", scope: scope)
    }

    /// A launch: both stores, connected, on `disk`, holding `bills`.
    private func launch(
        _ disk: Disk,
        bills: [Bill],
        votes: FakeBillVotesService,
        preferences: FakePreferencesService
    ) -> (store: BillsStore, voteStore: BillVoteStore) {
        let cache = BillVoteCache(config: BillVoteCache.Config(persistenceKey: disk.key), defaults: disk.defaults)
        let voteStore = BillVoteStore(cache: cache, service: votes)
        let service = FakeBillsService()
        service.cachedManifest = []
        let store = BillsStore(bills: bills, cacheScope: disk.scope, service: service, preferencesService: preferences)
        store.connect(voteStore: voteStore)
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        return (store, voteStore)
    }

    /// A Yea whose write failed offline, on a launch of its own that is then left.
    private func voteOffline(
        _ disk: Disk,
        _ vote: UserVote = .yea,
        reasons: [VoteReason] = [],
        on bill: Bill
    ) async -> Bill {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = URLError(.notConnectedToInternet)
        let (store, _) = launch(disk, bills: [bill], votes: votes, preferences: FakePreferencesService())
        let result = await store.submitVote(billID: bill.id, vote: vote, watch: nil, reasons: reasons)?.value
        XCTAssertEqual(result, .unconfirmed, "precondition")
        await settleBillsCache(scope: disk.scope)
        return store.bill(for: bill.id) ?? bill
    }

    // MARK: - The one automatic resend

    /// Back online after a relaunch: the rows are read first, in one request, and the vote the server does not hold is
    /// sent once more with its reasons. Stored, it is saved, its Bill row is written once, and nothing is sent again.
    func testAVoteNotSavedYetIsSentOnceMoreAndSavedWhenThePhoneIsBackOnline() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, reasons: [.education], on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: preferences)
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea], "precondition: kept across the relaunch")

        let sent = await store.resendUnsavedVotesOnce()

        XCTAssertEqual(votes.batchRequests, [[Self.guid]], "read first")
        XCTAssertEqual(sent, [Self.guid: .stored])
        XCTAssertEqual(votes.setFeedbackCalls, [.init(billId: Self.guid, feedback: .yea, reasons: ["education"])])
        XCTAssertEqual(voteStore.unsavedVotes, [:])
        XCTAssertEqual(store.bill(for: voted.id)?.userVote, .yea)
        await waitForPuts(preferences, count: 1)
        XCTAssertEqual(preferences.putCalls.flatMap { $0 }.map(\.preference), [Self.guid])
        XCTAssertEqual(preferences.putCalls.flatMap { $0 }.map(\.type), ["bill"])

        let again = await store.resendUnsavedVotesOnce()
        XCTAssertEqual(again, [:])
        XCTAssertEqual(votes.setFeedbackCalls.count, 1)
        await settleBillsCache(scope: disk.scope)
    }

    /// The read finds the vote on the server (its first write timed out after the server stored it): it is confirmed,
    /// gets its Bill row, and is not sent again.
    func testAVoteTheServerHoldsIsConfirmedNotSent() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, .nay, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .voted(.init(vote: .nay, votedAt: Date()))])
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: preferences)

        let sent = await store.resendUnsavedVotesOnce()

        XCTAssertEqual(sent, [:])
        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertEqual(voteStore.unsavedVotes, [:])
        await waitForPuts(preferences, count: 1)
        XCTAssertEqual(preferences.putCalls.flatMap { $0 }.map(\.preference), [Self.guid])
        await settleBillsCache(scope: disk.scope)
    }

    /// The read finds a vote cast later on another device: it replaces the vote not saved yet in both stores (an
    /// Abstain is no counted vote on the bill), and nothing is sent, so the later vote is never overwritten.
    func testALaterVoteFromAnotherDeviceIsTakenAndNotOverwritten() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, .yea, on: bill())
        XCTAssertEqual(voted.userVote, .yea, "precondition: the bills store shows the Yea")
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .voted(.init(vote: .abstain, votedAt: Date().addingTimeInterval(60)))])
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: preferences)

        let sent = await store.resendUnsavedVotesOnce()

        XCTAssertEqual(sent, [:])
        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertEqual(voteStore.unsavedVotes, [:])
        XCTAssertEqual(voteStore.heldVote(for: Self.guid), .abstain)
        let after = try XCTUnwrap(store.bill(for: voted.id))
        XCTAssertNil(after.userVote, "the bills store follows")
        XCTAssertFalse(after.userVoted)
        XCTAssertNil(after.lastVotedAt)
        XCTAssertEqual(after.userYeaCount, voted.userYeaCount - 1, "the Yea's local count goes")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(preferences.putCalls, [], "no Bill row: the vote was not this one")
        await settleBillsCache(scope: disk.scope)
    }

    /// When the read fails nothing is sent and the resend is not used up: the next return online reads and sends.
    func testNothingIsSentWhenTheReadFails() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .failure(URLError(.timedOut))
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())

        let failed = await store.resendUnsavedVotesOnce()
        XCTAssertEqual(failed, [:])
        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertNil(voteStore.lastError, "quiet")
        XCTAssertEqual(voteStore.votesAwaitingAutomaticResend().map { $0.guid }, [Self.guid], "not used up")

        votes.batchResult = .success([Self.guid: .notVoted])
        let sent = await store.resendUnsavedVotesOnce()
        XCTAssertEqual(sent, [Self.guid: .stored])
        await settleBillsCache(scope: disk.scope)
    }

    /// A resend the server refuses follows APPF-27: it rolls back in both stores to the vote it sent again, which is
    /// still not saved (the server may hold it from its first write), writes no Bill row, says why on the bill's page
    /// (`lastError` about the bill), and is never sent on its own again, also after a relaunch.
    func testARefusedResendRollsBackWritesNoBillRowAndIsNotSentAgain() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: preferences)

        let sent = await store.resendUnsavedVotesOnce()

        XCTAssertEqual(sent, [Self.guid: .rolledBack(restored: .voted(.yea))])
        XCTAssertEqual(voteStore.vote(for: Self.guid), .voted(.yea))
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea], "still not saved: Try again on its page")
        XCTAssertEqual(store.bill(for: voted.id)?.userVote, .yea, "the bills store rolled back to the same row")
        XCTAssertEqual(voteStore.lastError(about: [Self.guid]), AuthErrorMessages.voteDailyLimit)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(preferences.putCalls, [], "no Bill row for a refused vote")

        votes.setFeedbackError = nil
        let again = await store.resendUnsavedVotesOnce()
        await settleBillsCache(scope: disk.scope)
        let (relaunched, _) = launch(disk, bills: [voted], votes: votes, preferences: preferences)
        let afterRelaunch = await relaunched.resendUnsavedVotesOnce()
        XCTAssertEqual(again, [:])
        XCTAssertEqual(afterRelaunch, [:])
        XCTAssertEqual(votes.setFeedbackCalls.count, 1, "once")
        await settleBillsCache(scope: disk.scope)
    }

    /// An "updated" push that drops the app's copy of the vote while its resend is out, then a refusal: the rollback
    /// restores "unknown" (the dropped copy is not put back), and the bills store follows, so the bill holds no vote.
    func testARefusedResendAfterAPushDroppedTheVoteLeavesNoVote() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let sendGate = Gate()
        votes.holdSetFeedback = sendGate
        let started = expectation(description: "the resend is out")
        votes.onSetFeedback = { _ in started.fulfill() }
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())
        let resend = Task { await store.resendUnsavedVotesOnce() }
        await fulfillment(of: [started], timeout: 5)

        voteStore.clearVote(for: Self.guid)
        votes.setFeedbackError = backendError("APP_ATTEST_FAILED")
        sendGate.open()
        let sent = await resend.value

        XCTAssertEqual(sent, [Self.guid: .rolledBack(restored: .unknown)])
        XCTAssertEqual(voteStore.vote(for: Self.guid), .unknown)
        XCTAssertNil(store.bill(for: voted.id)?.userVote)
        XCTAssertEqual(store.bill(for: voted.id)?.userVoted, false)
        await settleBillsCache(scope: disk.scope)
    }

    /// A resend that fails again with its outcome unknown leaves the vote not saved, with Try again on its page, and
    /// the automatic resend used: Try again from the page is the person's choice from then on.
    func testAResendThatFailsAgainIsNotSentOnItsOwnAgain() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        votes.setFeedbackError = URLError(.timedOut)
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())

        let sent = await store.resendUnsavedVotesOnce()
        XCTAssertEqual(sent, [Self.guid: .unconfirmed])
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea])
        XCTAssertTrue(voteStore.votesAwaitingAutomaticResend().isEmpty)

        // Try again on the page sends the same vote; it fails again, and still nothing is sent on its own.
        _ = await store.submitVote(billID: voted.id, vote: .yea, watch: nil)?.value
        let again = await store.resendUnsavedVotesOnce()
        XCTAssertEqual(again, [:])
        XCTAssertEqual(votes.setFeedbackCalls.count, 2)

        // A different vote is a new vote, with its own resend.
        _ = await store.submitVote(billID: voted.id, vote: .nay, watch: nil)?.value
        XCTAssertEqual(voteStore.votesAwaitingAutomaticResend().map { $0.vote }, [.nay])
        await settleBillsCache(scope: disk.scope)
    }

    /// Two returns online close together (the network path drops and comes back while the read is out) each start a
    /// resend: the second joins the first one's read, and the vote is sent once.
    func testTwoReturnsOnlineCloseTogetherSendTheVoteOnce() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())

        let first = Task { await store.resendUnsavedVotesOnce() }
        for _ in 0..<500 where votes.batchRequests.isEmpty { await Task.yield() }
        let second = Task { await store.resendUnsavedVotesOnce() }
        for _ in 0..<50 { await Task.yield() }
        readGate.open()
        let results = await [first.value, second.value]

        XCTAssertEqual(votes.batchRequests, [[Self.guid]], "one read, which the second resend joined")
        XCTAssertEqual(results.filter { !$0.isEmpty }, [[Self.guid: .stored]], "one of the two sent it")
        XCTAssertEqual(votes.setFeedbackCalls.count, 1, "sent once")
        XCTAssertEqual(voteStore.unsavedVotes, [:])
        await settleBillsCache(scope: disk.scope)
    }

    /// The resend is used up on disk before it goes. When the app ends while it is out, the next launch shows the vote
    /// as not saved yet (Try again on its page) and, back online, sends nothing on its own; so does a launch after a
    /// resend that failed again with its outcome unknown.
    func testTheResendIsUsedUpAcrossARelaunch() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let sendGate = Gate()
        votes.holdSetFeedback = sendGate
        let started = expectation(description: "the resend is out")
        votes.onSetFeedback = { _ in started.fulfill() }
        let (store, _) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())
        let resend = Task { await store.resendUnsavedVotesOnce() }
        await fulfillment(of: [started], timeout: 5)
        votes.onSetFeedback = nil

        // The app ended while the resend was out: the next launch, on the same disk.
        let (relaunched, relaunchedVotes) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())
        XCTAssertEqual(relaunchedVotes.unsavedVotes, [Self.guid: .yea], "not saved yet at the next launch")
        XCTAssertTrue(relaunchedVotes.votesAwaitingAutomaticResend().isEmpty, "the resend is used up")
        let afterEndedResend = await relaunched.resendUnsavedVotesOnce()
        XCTAssertEqual(afterEndedResend, [:])

        // The resend fails again with its outcome unknown; the launch after that sends nothing on its own either.
        votes.setFeedbackError = URLError(.timedOut)
        sendGate.open()
        let sent = await resend.value
        XCTAssertEqual(sent, [Self.guid: .unconfirmed], "precondition")
        await settleBillsCache(scope: disk.scope)
        votes.setFeedbackError = nil
        let (lastLaunch, lastVotes) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())
        XCTAssertEqual(lastVotes.unsavedVotes, [Self.guid: .yea])
        let afterFailedResend = await lastLaunch.resendUnsavedVotesOnce()

        XCTAssertEqual(afterFailedResend, [:])
        XCTAssertEqual(votes.setFeedbackCalls.count, 1, "sent on its own once, across both relaunches")
        await settleBillsCache(scope: disk.scope)
    }

    /// A vote not saved yet on a guid the bills store has not loaded (a companion member's legacy text-version guid) is
    /// sent through the vote store alone, and gets its Bill row under that guid once stored.
    func testAVoteOnAGuidTheBillsStoreHasNotLoadedIsSentToo() async throws {
        let disk = try makeDisk()
        let legacy = "BILLS-119s456is"
        let failing = FakeBillVotesService()
        failing.setFeedbackError = URLError(.notConnectedToInternet)
        let (_, first) = launch(disk, bills: [], votes: failing, preferences: FakePreferencesService())
        _ = await first.submitVote(billId: legacy, vote: .nay)
        let votes = FakeBillVotesService()
        votes.batchResult = .success([legacy: .notVoted])
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch(disk, bills: [], votes: votes, preferences: preferences)

        let sent = await store.resendUnsavedVotesOnce()

        XCTAssertEqual(sent, [legacy: .stored])
        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [legacy])
        XCTAssertEqual(voteStore.unsavedVotes, [:])
        await waitForPuts(preferences, count: 1)
        XCTAssertEqual(preferences.putCalls.flatMap { $0 }.map(\.preference), [legacy])
    }

    /// A resend that joins a read already out (the launch read) sends only the votes that read judged. A vote whose write
    /// failed while that read was out was not in it: the server may hold it, so it is not sent unread, and waits for the
    /// next read, which sends it.
    func testAResendThatJoinsAReadSendsOnlyTheVotesThatReadJudged() async throws {
        let disk = try makeDisk()
        let other = "BILLS-119hr4200"
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted, other: .notVoted])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        let (store, voteStore) = launch(disk, bills: [voted, bill(other)], votes: votes, preferences: FakePreferencesService())
        let launchRead = Task { await voteStore.recheckUnsavedVotes() }
        for _ in 0..<500 where votes.batchRequests.isEmpty { await Task.yield() }

        votes.setFeedbackError = URLError(.notConnectedToInternet)
        let failed = await store.submitVote(billID: bill(other).id, vote: .nay, watch: nil)?.value
        XCTAssertEqual(failed, .unconfirmed, "precondition")
        votes.setFeedbackError = nil
        let resend = Task { await store.resendUnsavedVotesOnce() }
        for _ in 0..<50 { await Task.yield() }
        readGate.open()
        let sent = await resend.value
        _ = await launchRead.value

        XCTAssertEqual(votes.batchRequests, [[Self.guid]], "one read, which the resend joined")
        XCTAssertEqual(sent, [Self.guid: .stored])
        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [other, Self.guid], "the other vote was not sent unread")
        XCTAssertEqual(voteStore.votesAwaitingAutomaticResend().map { $0.guid }, [other])

        let next = await store.resendUnsavedVotesOnce()
        XCTAssertEqual(votes.batchRequests.last, [other], "read first")
        XCTAssertEqual(next, [other: .stored])
        await settleBillsCache(scope: disk.scope)
    }

    /// A resend cancelled while its read is out (sign-out takes the tabs down, which cancels it) spends and sends
    /// nothing once the read is back: the vote stays not saved, its resend not used, for this account's next launch.
    func testACancelledResendSendsNothingAndKeepsItsResend() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: FakePreferencesService())
        let resend = store.startUnsavedVoteResend()
        for _ in 0..<500 where votes.batchRequests.isEmpty { await Task.yield() }

        resend.cancel()
        readGate.open()
        let sent = await resend.value

        XCTAssertEqual(sent, [:])
        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea])
        XCTAssertEqual(voteStore.votesAwaitingAutomaticResend().map { $0.guid }, [Self.guid], "not used up")
        await settleBillsCache(scope: disk.scope)
    }

    /// Sign-out ends both stores while the resend's read is out: neither the read nor the resend keeps them, so once the
    /// read is back nothing is sent (under whatever session is current then) and nothing is written to the signed-out
    /// account's cache, though the answer would confirm the vote.
    func testStoresThatSignOutEndedAreNotKeptAndNothingIsSentOrWritten() async throws {
        let disk = try makeDisk()
        _ = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .voted(.init(vote: .yea, votedAt: Date()))])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        var voteStore: BillVoteStore? = BillVoteStore(
            cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: disk.key), defaults: disk.defaults),
            service: votes
        )
        let service = FakeBillsService()
        service.cachedManifest = []
        var store: BillsStore? = BillsStore(bills: [], cacheScope: disk.scope, service: service, preferencesService: FakePreferencesService())
        if let store, let voteStore {
            store.connect(voteStore: voteStore)
        }
        weak let endedVoteStore = voteStore
        weak let endedStore = store
        let resend = try XCTUnwrap(store?.startUnsavedVoteResend())
        for _ in 0..<500 where votes.batchRequests.isEmpty { await Task.yield() }
        let rows = disk.defaults.data(forKey: disk.key)
        let marks = disk.defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: disk.key))

        store = nil
        voteStore = nil
        XCTAssertNil(endedVoteStore, "the read does not keep the vote store")
        XCTAssertNil(endedStore, "the resend does not keep the bills store")
        readGate.open()
        let sent = await resend.value

        XCTAssertEqual(sent, [:])
        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertNotNil(marks, "precondition")
        XCTAssertEqual(disk.defaults.data(forKey: disk.key), rows, "no row written")
        XCTAssertEqual(disk.defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: disk.key)), marks, "the mark as it was")
    }

    /// A reasons update for the vote is still out when the resend's read comes back (the server has not stored it yet, so
    /// the read keeps the vote not saved): the vote is not sent a second time behind it, and its resend is not used. The
    /// update, once stored, saves the vote with its Bill row; nothing else is sent.
    func testAReasonsUpdateStillOutWhenTheReadIsBackSendsNoSecondWrite() async throws {
        let disk = try makeDisk()
        let voted = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let updateGate = Gate()
        votes.holdSetFeedback = updateGate
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch(disk, bills: [voted], votes: votes, preferences: preferences)
        let update = Task { await voteStore.updateReasons(billId: Self.guid, vote: .yea, reasons: [.education]) }
        for _ in 0..<500 where votes.setFeedbackCalls.isEmpty { await Task.yield() }

        let resend = Task { await store.resendUnsavedVotesOnce() }
        for _ in 0..<500 where votes.batchRequests.isEmpty { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(voteStore.votesAwaitingAutomaticResend().map { $0.guid }, [Self.guid], "its resend not used")
        updateGate.open()
        let sent = await resend.value
        let stored = await update.value

        XCTAssertEqual(votes.batchRequests, [[Self.guid]], "read first")
        XCTAssertEqual(sent, [:], "nothing sent behind the update")
        XCTAssertTrue(stored)
        XCTAssertEqual(votes.setFeedbackCalls, [.init(billId: Self.guid, feedback: .yea, reasons: ["education"])], "the update only")
        XCTAssertEqual(voteStore.unsavedVotes, [:], "the update saved the vote")
        await waitForPuts(preferences, count: 1)
        await settleBillsCache(scope: disk.scope)
    }

    // MARK: - Sign-out

    /// The tabs' launch read, as their `.task` holds it, when sign-out ends it while the request is out: the purge, then
    /// the tabs go, which cancels the task. The task ends at once, though the request has not answered, so it keeps the
    /// store no longer; and once the answer comes (it would confirm the vote) nothing is written back for that account.
    func testALaunchReadThatSignOutCancelsEndsAtOnceAndWritesNothing() async throws {
        let disk = try makeDisk()
        _ = await voteOffline(disk, on: bill())
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .voted(.init(vote: .yea, votedAt: Date()))])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        var voteStore: BillVoteStore? = BillVoteStore(
            cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: disk.key), defaults: disk.defaults),
            service: votes
        )
        weak let endedVoteStore = voteStore
        let launchRead = Task { [voteStore] in await voteStore?.recheckUnsavedVotes() }
        for _ in 0..<500 where votes.batchRequests.isEmpty { await Task.yield() }

        UserLocalDataPurge.purge(userId: disk.scope, defaults: disk.defaults)
        voteStore = nil
        launchRead.cancel()
        let read = await launchRead.value

        XCTAssertEqual(read, false, "ended without an answer")
        XCTAssertNil(endedVoteStore, "the launch read does not keep the vote store")
        readGate.open()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(votes.batchRequests.count, 1)
        XCTAssertNil(disk.defaults.data(forKey: disk.key), "no row written back after the purge")
        XCTAssertNil(disk.defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: disk.key)), "no mark written back")
    }

    /// A store something still holds after sign-out (a page going away, say): a launch read and a return read it joined,
    /// answered after the purge, write nothing for that account. Their answer confirms one vote and leaves the other not
    /// saved, which would save every row and the mark left; nothing changes on screen, and no Bill row is sent.
    func testReadsAnsweredAfterSignOutWriteNothingForThatAccount() async throws {
        let disk = try makeDisk()
        let other = "BILLS-119hr4101"
        let first = await voteOffline(disk, on: bill())
        let second = await voteOffline(disk, .nay, on: bill(other))
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .voted(.init(vote: .yea, votedAt: Date())), other: .notVoted])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        let preferences = FakePreferencesService()
        let (_, voteStore) = launch(disk, bills: [first, second], votes: votes, preferences: preferences)
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea, other: .nay], "precondition")

        let launchRead = Task { await voteStore.recheckUnsavedVotes() }
        for _ in 0..<500 where votes.batchRequests.isEmpty { await Task.yield() }
        let returnRead = Task { await voteStore.recheckUnsavedVotes() }
        for _ in 0..<50 { await Task.yield() }
        UserLocalDataPurge.purge(userId: disk.scope, defaults: disk.defaults)
        readGate.open()
        let reads = await [launchRead.value, returnRead.value]

        XCTAssertEqual(votes.batchRequests.count, 1, "the return read joined the launch read")
        XCTAssertEqual(reads, [false, false])
        XCTAssertNil(disk.defaults.data(forKey: disk.key), "no row written back after the purge")
        XCTAssertNil(disk.defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: disk.key)), "no mark written back")
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea, other: .nay], "the answer was not taken")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(preferences.putCalls, [], "no Bill row")
        XCTAssertEqual(votes.setFeedbackCalls, [])
        let afterSignOut = await voteStore.recheckUnsavedVotes()
        XCTAssertFalse(afterSignOut, "a read after sign-out asks nothing")
        XCTAssertEqual(votes.batchRequests.count, 1)
    }

    // MARK: - Back online

    func testThePhoneIsBackOnlineOnItsFirstOnlineReportAndAfterAnOfflineOne() {
        var launchedOnline = OnlineReturnDetector()
        XCTAssertTrue(launchedOnline.cameOnline(true), "the phone may have come back while the app was not running")
        XCTAssertFalse(launchedOnline.cameOnline(true), "Wi-Fi to cellular")
        XCTAssertFalse(launchedOnline.cameOnline(false))
        XCTAssertTrue(launchedOnline.cameOnline(true), "back online")

        var launchedOffline = OnlineReturnDetector()
        XCTAssertFalse(launchedOffline.cameOnline(false))
        XCTAssertFalse(launchedOffline.cameOnline(false))
        XCTAssertTrue(launchedOffline.cameOnline(true))
        XCTAssertFalse(launchedOffline.cameOnline(true))
    }

    // MARK: - The tabs' modifier (`rechecksUnsavedVotes`)

    /// The tabs' modifier reads the votes not saved yet at launch; then, on an offline report and an online one after
    /// it, starts the one automatic resend, which reads the row again and sends the vote. A further online report (Wi-Fi
    /// to cellular) starts none.
    func testTheTabsReadAtLaunchAndResendOnceThePhoneIsBackOnline() throws {
        let disk = try markedDisk()
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let (store, voteStore) = launch(disk, bills: [bill()], votes: votes, preferences: FakePreferencesService())
        let (reports, online) = AsyncStream.makeStream(of: Bool.self)
        let session = Session()
        let host = AccessibilityTreeText.Host(SignedInTabs(session: session, billsStore: store, voteStore: voteStore, onlineReports: { reports }))
        defer { host.close() }

        XCTAssertTrue(host.run(until: { votes.batchRequests == [[Self.guid]] }), "the launch read: \(votes.batchRequests)")
        online.yield(false)
        host.run(0.3)
        XCTAssertEqual(votes.setFeedbackCalls, [], "offline")
        online.yield(true)
        XCTAssertTrue(host.run(until: { voteStore.unsavedVotes.isEmpty }), "back online: \(votes.setFeedbackCalls)")
        XCTAssertEqual(votes.batchRequests, [[Self.guid], [Self.guid]], "read again first")
        XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea])
        online.yield(true)
        host.run(0.3)
        XCTAssertEqual(votes.batchRequests.count, 2, "no return online")
        XCTAssertEqual(votes.setFeedbackCalls.count, 1)
    }

    /// A UI-test launch stays off the network: no read at launch, and nothing sent when the phone is online.
    func testTheTabsOfAUITestLaunchReadAndSendNothing() throws {
        let disk = try markedDisk()
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let (store, voteStore) = launch(disk, bills: [bill()], votes: votes, preferences: FakePreferencesService())
        let (reports, online) = AsyncStream.makeStream(of: Bool.self)
        let session = Session()
        let host = AccessibilityTreeText.Host(
            SignedInTabs(session: session, billsStore: store, voteStore: voteStore, onlineReports: { reports }, staysOffline: true)
        )
        defer { host.close() }

        online.yield(false)
        online.yield(true)
        host.run(0.5)
        XCTAssertEqual(votes.batchRequests, [])
        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertEqual(voteStore.votesAwaitingAutomaticResend().map { $0.guid }, [Self.guid])
    }

    /// Sign-out takes the tabs down while a resend's read is out: the resend is cancelled with them, so once the read is
    /// back nothing is sent and the resend is not used.
    func testTabsTakenDownWhileTheReadIsOutSendNothing() throws {
        let disk = try markedDisk()
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .notVoted])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        let (store, voteStore) = launch(disk, bills: [bill()], votes: votes, preferences: FakePreferencesService())
        let (reports, online) = AsyncStream.makeStream(of: Bool.self)
        let session = Session()
        let host = AccessibilityTreeText.Host(SignedInTabs(session: session, billsStore: store, voteStore: voteStore, onlineReports: { reports }))
        defer { host.close() }

        online.yield(true)
        XCTAssertTrue(host.run(until: { !votes.batchRequests.isEmpty }), "the read is out")
        host.run(0.3)
        session.isSignedIn = false
        host.run(0.3)
        readGate.open()
        host.run(0.5)

        XCTAssertEqual(votes.batchRequests.count, 1, "the resend joined the launch read")
        XCTAssertEqual(votes.setFeedbackCalls, [])
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea])
        XCTAssertEqual(voteStore.votesAwaitingAutomaticResend().map { $0.guid }, [Self.guid], "not used up")
    }

    /// Sign-out clears the account's data, then takes the tabs down, while their launch read is out: the read is
    /// cancelled with them, and its answer, which would confirm the vote, writes nothing back for that account.
    func testTabsTakenDownAtSignOutWriteNothingWhenTheirReadAnswers() throws {
        let disk = try markedDisk()
        let votes = FakeBillVotesService()
        votes.batchResult = .success([Self.guid: .voted(.init(vote: .yea, votedAt: Date()))])
        let readGate = Gate()
        votes.holdBatchFetch = readGate
        let preferences = FakePreferencesService()
        let (store, voteStore) = launch(disk, bills: [bill()], votes: votes, preferences: preferences)
        let (reports, _) = AsyncStream.makeStream(of: Bool.self)
        let session = Session()
        let host = AccessibilityTreeText.Host(SignedInTabs(session: session, billsStore: store, voteStore: voteStore, onlineReports: { reports }))
        defer { host.close() }

        XCTAssertTrue(host.run(until: { !votes.batchRequests.isEmpty }), "the launch read is out")
        UserLocalDataPurge.purge(userId: disk.scope, defaults: disk.defaults)
        session.isSignedIn = false
        host.run(0.3)
        readGate.open()
        host.run(0.5)

        XCTAssertEqual(votes.batchRequests.count, 1)
        XCTAssertNil(disk.defaults.data(forKey: disk.key), "no row written back after the purge")
        XCTAssertNil(disk.defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: disk.key)), "no mark written back")
        XCTAssertEqual(voteStore.unsavedVotes, [Self.guid: .yea], "the answer was not taken")
        XCTAssertEqual(preferences.putCalls, [], "no Bill row")
    }

    /// Whether the tabs are up: sign-out takes them down.
    @MainActor
    private final class Session: ObservableObject {
        @Published var isSignedIn = true
    }

    /// The tabs' modifier on a view that is there while `session` is signed in, as `TabsBar` is.
    private struct SignedInTabs: View {
        @ObservedObject var session: Session
        let billsStore: BillsStore
        let voteStore: BillVoteStore
        let onlineReports: @Sendable () -> AsyncStream<Bool>
        var staysOffline = false

        var body: some View {
            if session.isSignedIn {
                Color.clear.rechecksUnsavedVotes(
                    billsStore: billsStore,
                    voteStore: voteStore,
                    onlineReports: onlineReports,
                    staysOffline: staysOffline
                )
            }
        }
    }

    // MARK: - Helpers

    /// A disk holding a Yea not saved yet, as a launch whose write failed offline leaves it.
    private func markedDisk() throws -> Disk {
        let disk = try makeDisk()
        let cache = BillVoteCache(config: BillVoteCache.Config(persistenceKey: disk.key), defaults: disk.defaults)
        let sentAt = Date()
        cache.setVoted(billId: Self.guid, vote: .yea, votedAt: sentAt, now: sentAt)
        cache.setUnsavedVote(BillVoteCache.UnsavedVote(vote: .yea, sentAt: sentAt, reasons: [], autoResent: false), for: Self.guid)
        return disk
    }

    private func waitForPuts(_ preferences: FakePreferencesService, count: Int) async {
        for _ in 0..<500 where preferences.putCalls.count < count { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(preferences.putCalls.count, count, "\(preferences.putCalls)")
    }
}
