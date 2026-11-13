import XCTest
@testable import Billboard

/// INT-11: a user sees other users' votes on a bill (Results and Why people voted) only after voting
/// Yea, Nay or Abstain on it, here or anywhere else, and the server holds that row. Skip, Clear and
/// dismissal write nothing and never unlock; a refused vote never unlocks and drops what it showed; a
/// vote made on another device or before a reinstall unlocks once its row is read again.
@MainActor
final class ResultsGateTests: XCTestCase {
    private nonisolated static let guid = "BILLS-119hr4200"

    private func voteStore(_ service: any BillVotesServicing) -> BillVoteStore {
        BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: service)
    }

    private func openBill(_ guid: String = ResultsGateTests.guid) -> Bill {
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

    /// What bill detail's `hasVoted` reads, for a bill in no group: the bar's choice, a vote cast on the
    /// screen, and the rows the stores hold.
    private func unlocks(_ store: BillVoteStore, guid: String = ResultsGateTests.guid, pending: VoteChoice? = nil, didJustVote: Bool = false, mode: BillDetail.Mode = .full) -> Bool {
        let counted = BillVoteBarModel.storedCountedVote(voteStoreState: store.vote(for: guid), billVote: nil)
        let held = store.heldVote(for: guid)
        let choice = BillVoteBarModel.shownChoice(
            pending: pending,
            counted: counted.map { VoteChoice($0.voteType) },
            held: held,
            mode: mode,
            heldVotedAt: store.heldVoteDate(for: guid),
            billUpdatedAt: nil
        )
        return BillVoteBarModel.unlocksResults(choice: choice, didJustVote: didJustVote, holdsRow: held != nil || counted != nil)
    }

    /// What bill detail's Results show for a bill in no group (`resultsAccess`): its lock reason is the vote
    /// state not known yet (the store has no row and no answer), else not voted.
    private func access(
        _ store: BillVoteStore,
        guid: String = ResultsGateTests.guid,
        pending: VoteChoice? = nil,
        didJustVote: Bool = false
    ) -> BillResultsAccess {
        BillResultsAccess.make(
            unlocked: unlocks(store, guid: guid, pending: pending, didJustVote: didJustVote),
            awaitingSave: false,
            isChecking: store.vote(for: guid) == .unknown,
            canRetry: true
        )
    }

    /// Lets tasks started on the main actor run up to their first suspension.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // MARK: - The rule

    func testOnlyAYeaNayOrAbstainUnlocks() {
        for choice in VoteChoice.allCases {
            XCTAssertTrue(BillVoteBarModel.unlocksResults(choice: choice, didJustVote: false, holdsRow: false), "pending \(choice)")
        }
        XCTAssertTrue(BillVoteBarModel.unlocksResults(choice: nil, didJustVote: true, holdsRow: false), "just voted")
        XCTAssertTrue(BillVoteBarModel.unlocksResults(choice: nil, didJustVote: false, holdsRow: true), "a held row")
        XCTAssertFalse(BillVoteBarModel.unlocksResults(choice: nil, didJustVote: false, holdsRow: false), "no choice and no row")
    }

    func testAHeldYeaNayOrAbstainUnlocksAlsoFromBeforeABillsUpdate() async {
        for vote in [VoteType.yea, .nay, .abstain] {
            let service = FakeBillVotesService()
            service.singleResult = .success(.voted(.init(vote: vote, votedAt: Date().addingTimeInterval(-86_400))))
            let store = voteStore(service)
            await store.fetchVoteIfNeeded(for: Self.guid)
            XCTAssertTrue(unlocks(store), "\(vote) on a new bill")

            // An "updated" push clears only the local row; reopening reads the server's row again.
            store.clearVote(for: Self.guid)
            XCTAssertFalse(unlocks(store, mode: .updatedOnly), "\(vote): unknown until the row is read")
            await store.fetchVoteIfNeeded(for: Self.guid)
            XCTAssertTrue(unlocks(store, mode: .updatedOnly), "\(vote) from before the update (project question 1 default)")
        }
    }

    func testSkipClearAndDismissalNeverUnlock() async {
        let votes = FakeBillVotesService()
        let bill = openBill()
        var passed = openBill("BILLS-119hr4201")
        passed.billStatus = .passed
        let (store, voteStore, scope) = await makeCompanionStore(bills: [bill, passed], groups: [], votes: votes)
        let readState = AppReadState(scope: .user("results-gate-tests"), store: InMemoryReadStateStore())

        store.commitSkip(store.skip(.openBill(bill.id), readState: readState))
        store.commitSkip(store.clearFromUpdates(billID: passed.id, readState: readState))
        _ = store.dismiss(billID: bill.id, readState: readState)
        await Task.yield()

        XCTAssertEqual(votes.setFeedbackCalls, [], "no row is written")
        XCTAssertFalse(unlocks(voteStore))
        XCTAssertFalse(unlocks(voteStore, guid: "BILLS-119hr4201"), "a passed bill opens with the vote bar (.full)")
        await settleBillsCache(scope: scope)
    }

    /// Sign-up and sign-in promise other users' votes only after the user votes (or abstains).
    func testSignUpAndSignInSayResultsOpenAfterYouVote() {
        XCTAssertEqual(CreateAccountView.valueBullets.last, "See how other users voted after you vote, and how your representatives voted")
        XCTAssertEqual(
            LoginView.valueLine,
            "Plain-English summaries of real bills. Vote Yea, Nay or Abstain, then see how others and your representatives voted."
        )
    }

    // MARK: - Asking for stats

    func testStatsAreAskedForOnlyWhileUnlockedAndNoVoteIsBeingSent() {
        XCTAssertTrue(BillVoteBarModel.shouldFetchStats(unlocked: true, writeInFlight: false))
        XCTAssertFalse(BillVoteBarModel.shouldFetchStats(unlocked: false, writeInFlight: false), "locked")
        XCTAssertFalse(BillVoteBarModel.shouldFetchStats(unlocked: true, writeInFlight: true), "asked once the write is stored")
        XCTAssertFalse(BillVoteBarModel.shouldFetchStats(unlocked: false, writeInFlight: true))
    }

    func testARefusedVoteNeverAsksForStats() {
        for restored in [VoteState.unknown, .notVoted, .voted(.yea), .voted(.abstain)] {
            XCTAssertFalse(BillVoteBarModel.fetchesStatsAfterWrite(result: .rolledBack(restored: restored), stillUnlocked: true), "\(restored)")
        }
        XCTAssertFalse(BillVoteBarModel.fetchesStatsAfterWrite(result: .notSaved, stillUnlocked: false), "locked again")
        XCTAssertFalse(BillVoteBarModel.fetchesStatsAfterWrite(result: .stored, stillUnlocked: false))
        XCTAssertTrue(BillVoteBarModel.fetchesStatsAfterWrite(result: .notSaved, stillUnlocked: true), "kept after a failure: the server decides")
        XCTAssertTrue(BillVoteBarModel.fetchesStatsAfterWrite(result: .stored, stillUnlocked: true))
    }

    // MARK: - What shows (BillResultsAccess)

    func testAccessLocksWithItsReasonAndOpensOnlyWhenUnlocked() {
        XCTAssertEqual(BillResultsAccess.make(unlocked: false, awaitingSave: false, isChecking: false, canRetry: true), .locked(.notVoted))
        XCTAssertEqual(BillResultsAccess.make(unlocked: false, awaitingSave: false, isChecking: true, canRetry: true), .locked(.checking))
        XCTAssertEqual(BillResultsAccess.make(unlocked: true, awaitingSave: false, isChecking: false, canRetry: true), .open)
        XCTAssertEqual(BillResultsAccess.make(unlocked: true, awaitingSave: false, isChecking: true, canRetry: true), .open, "a vote cast here opens before the row is read")
        XCTAssertEqual(BillResultsAccess.make(unlocked: true, awaitingSave: true, isChecking: false, canRetry: true), .awaitingSave(canRetry: true))
        XCTAssertEqual(BillResultsAccess.make(unlocked: true, awaitingSave: true, isChecking: false, canRetry: false), .awaitingSave(canRetry: false), "no vote shown to send again")
        XCTAssertEqual(BillResultsAccess.make(unlocked: false, awaitingSave: true, isChecking: false, canRetry: true), .locked(.notVoted), "locked wins")
        XCTAssertEqual(BillResultsAccess.make(unlocked: false, awaitingSave: true, isChecking: true, canRetry: true), .locked(.checking), "locked wins")
        XCTAssertEqual(
            BillResultsAccess.make(unlocked: false, awaitingSave: false, isChecking: false, checkFailed: true, canRetry: true),
            .locked(.checkFailed)
        )
        XCTAssertEqual(
            BillResultsAccess.make(unlocked: true, awaitingSave: false, isChecking: false, checkFailed: true, canRetry: true),
            .open,
            "a vote cast here opens though the read failed"
        )
        XCTAssertEqual(
            BillResultsAccess.make(unlocked: false, awaitingSave: true, isChecking: false, checkFailed: true, canRetry: true),
            .locked(.checkFailed),
            "locked wins"
        )

        XCTAssertNil(BillResultsAccess.open.lockText)
        XCTAssertEqual(BillResultsAccess.locked(.notVoted).lockText, "Vote to see results")
        XCTAssertEqual(BillResultsAccess.locked(.checking).lockText, "Checking your vote…", "the vote bar's own caption")
        XCTAssertEqual(BillResultsAccess.awaitingSave(canRetry: true).lockText, "Results show once your vote is saved.")
        XCTAssertEqual(BillResultsAccess.locked(.checkFailed).lockText, "Couldn't check your vote on this bill.")

        // Try again: a vote to send again, or a failed vote read to make again. Nothing else.
        XCTAssertTrue(BillResultsAccess.awaitingSave(canRetry: true).offersTryAgain)
        XCTAssertTrue(BillResultsAccess.locked(.checkFailed).offersTryAgain)
        for access in [BillResultsAccess.open, .locked(.notVoted), .locked(.checking), .awaitingSave(canRetry: false)] {
            XCTAssertFalse(access.offersTryAgain, "\(access)")
        }
    }

    /// The locked Results as VoiceOver reads them (Civic Record spec 3.8.3): the heading "Results", then the
    /// sealed sheet as one element labelled "Sealed" (beside a spinner, the spinner's words) whose value is
    /// the line and the text under it. Replaces INT-11's single "Results, locked. Vote to see results."
    func testLockedResultsReadAsTheSealedSheet() {
        func sealed(_ access: BillResultsAccess) -> SealedTallyState? {
            SealedTallyState(access: access, opening: false)
        }
        let cases: [(BillResultsAccess, label: String, value: String?)] = [
            (.locked(.notVoted), "Sealed", "Vote to see results. They open after you vote Yea, Nay or Abstain, so other people's votes don't sway yours."),
            (.locked(.checking), "Checking your vote…", nil),
            (.locked(.checkFailed), "Sealed", "Couldn't check your vote on this bill."),
            (.awaitingSave(canRetry: true), "Sealed", "Results show once your vote is saved."),
            (.awaitingSave(canRetry: false), "Sealed", "Results show once your vote is saved.")
        ]
        for (access, label, value) in cases {
            guard let state = sealed(access) else { return XCTFail("\(access) is sealed") }
            XCTAssertEqual(VoteResultsFormatting.sealedAccessibilityLabel(state), label, "\(access)")
            XCTAssertEqual(VoteResultsFormatting.sealedAccessibilityValue(state), value, "\(access)")
            // Why people voted, sealed, says when reasons open; beside the checking spinner it says nothing, so
            // a returning voter is not told to vote.
            let reasons: String? = access == .locked(.checking) ? nil : "Reasons open after you vote."
            XCTAssertEqual(VoteResultsFormatting.sealedAccessibilityValue(state, reasons: true), reasons, "\(access)")
            // The main sentence is INT-11's lock text, as the sheet draws it.
            XCTAssertTrue(([state.line, state.text, state.spinnerText].compactMap { $0 }).contains(access.lockText ?? ""), "\(access)")
        }

        // Open Results are never sealed; after a vote here, before its stats, they show Opening.
        XCTAssertNil(sealed(.open))
        XCTAssertEqual(SealedTallyState(access: .open, opening: true), .opening)
        XCTAssertEqual(VoteResultsFormatting.sealedAccessibilityLabel(.opening), "Opening results…")
        XCTAssertNil(VoteResultsFormatting.sealedAccessibilityValue(.opening))
        XCTAssertNil(VoteResultsFormatting.sealedAccessibilityValue(.opening, reasons: true), "the user has just voted")
        // A locked access stays locked whatever the screen did: Opening is only for open Results.
        for access in [BillResultsAccess.locked(.notVoted), .locked(.checking), .locked(.checkFailed), .awaitingSave(canRetry: true)] {
            XCTAssertNotEqual(SealedTallyState(access: access, opening: true), .opening, "\(access)")
        }

        // The stamp sits over the sheet except while the vote is checked and in Opening (a spinner there).
        XCTAssertTrue(SealedTallyState.notVoted.showsStamp)
        XCTAssertFalse(SealedTallyState.checking.showsStamp)
        XCTAssertFalse(SealedTallyState.opening.showsStamp)
        // Try again exactly where the access offers it; "Go to vote buttons" only before a vote.
        for access in [BillResultsAccess.locked(.notVoted), .locked(.checking), .locked(.checkFailed), .awaitingSave(canRetry: true), .awaitingSave(canRetry: false)] {
            XCTAssertEqual(sealed(access)?.offersTryAgain, access.offersTryAgain, "\(access)")
            XCTAssertEqual(sealed(access)?.offersGoToVoteButtons, access == .locked(.notVoted), "\(access)")
        }
        XCTAssertFalse(SealedTallyState.opening.offersTryAgain)
        XCTAssertFalse(SealedTallyState.opening.offersGoToVoteButtons)
    }

    /// `.checking` is the vote state not known yet (a cold start, a new device, the store loading): Results
    /// stay locked until the row is read, then open for a held vote or ask for one.
    func testAnUnknownVoteStateLocksAsCheckingUntilTheRowIsRead() async {
        for held in [VoteType?.none, .yea, .nay, .abstain] {
            let service = FakeBillVotesService()
            service.singleResult = .success(held.map { .voted(.init(vote: $0, votedAt: Date().addingTimeInterval(-3_600))) } ?? .notVoted)
            let store = voteStore(service)
            XCTAssertEqual(access(store), .locked(.checking), "\(String(describing: held)): an empty cache")

            await store.fetchVoteIfNeeded(for: Self.guid, reportError: false, revalidateNotVoted: true)
            XCTAssertEqual(access(store), held == nil ? .locked(.notVoted) : .open, "\(String(describing: held)) once read")
        }
    }

    /// A vote read that fails (offline, a server error) leaves the vote state unknown and never unlocks. The
    /// store reports the failure, so bill detail says it couldn't check the vote (`.checkFailed`, with Try
    /// again) instead of "Checking your vote…" for a read that has ended; read again, Results open for a
    /// held vote or ask for one. A companion group's read, every member in one request, reports it too.
    func testAFailedVoteReadNeverUnlocksAndIsReported() async {
        for held in [VoteType?.none, .yea, .abstain] {
            let service = FakeBillVotesService()
            service.singleResult = .failure(URLError(.notConnectedToInternet))
            let store = voteStore(service)

            let failure = await store.fetchVoteIfNeeded(for: Self.guid, reportError: false, revalidateNotVoted: true)
            XCTAssertEqual(failure, BillVoteStore.checkVoteFailedMessage, "\(String(describing: held))")
            XCTAssertNil(store.lastError, "quiet: the page says it")
            XCTAssertEqual(store.vote(for: Self.guid), .unknown)
            XCTAssertFalse(unlocks(store), "a failed read never unlocks")
            XCTAssertEqual(
                BillResultsAccess.make(unlocked: unlocks(store), awaitingSave: false, isChecking: false, checkFailed: true, canRetry: false),
                .locked(.checkFailed)
            )

            service.singleResult = .success(held.map { .voted(.init(vote: $0, votedAt: Date().addingTimeInterval(-3_600))) } ?? .notVoted)
            let retried = await store.fetchVoteIfNeeded(for: Self.guid, reportError: false, revalidateNotVoted: true)
            XCTAssertNil(retried)
            XCTAssertEqual(access(store), held == nil ? .locked(.notVoted) : .open, "\(String(describing: held)) once read")
        }

        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let service = FakeBillVotesService()
        service.batchResult = .failure(URLError(.timedOut))
        let store = voteStore(service)
        let failure = await store.fetchVotes(for: [house, senate], revalidateNotVoted: true)
        XCTAssertEqual(failure, BillVoteStore.loadVotesFailedMessage)
        XCTAssertEqual(store.vote(for: house), .unknown)
        XCTAssertEqual(store.vote(for: senate), .unknown)

        service.batchResult = .success([house: .notVoted, senate: .voted(.init(vote: .nay, votedAt: Date()))])
        let retried = await store.fetchVotes(for: [house, senate], revalidateNotVoted: true)
        XCTAssertNil(retried)
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        XCTAssertEqual(store.companionVote(for: group).effectiveVote, .nay, "read again, the group's vote unlocks the pair")
    }

    /// A 1.1 Abstain on a decided bill that the server marked as a dismissal (`legacyDismiss`) is left out
    /// of what 1.2 reads, so the bill opens not voted and locked. Voting stays open on decided bills (Civic
    /// Record project decision 1), so the user can cast it again from the page; 1.2's Abstain is a vote,
    /// and Results open once it is stored, and again when the page is opened later.
    func testA11DismissalOnADecidedBillCanBeCastAgainAndThenUnlocks() async {
        var passed = openBill("BILLS-119hr4202")
        passed.billStatus = .passed
        let guid = "BILLS-119hr4202"
        let votes = FakeBillVotesService()
        // The server leaves the marked dismissal out of GET /feedback for 1.2.
        votes.singleResult = .success(.notVoted)
        let (store, voteStore, scope) = await makeCompanionStore(bills: [passed], groups: [], votes: votes)
        await voteStore.fetchVoteIfNeeded(for: guid, reportError: false, revalidateNotVoted: true)
        XCTAssertEqual(access(voteStore, guid: guid), .locked(.notVoted), "a dismissal never unlocks")

        // The Passed list opens it with the vote bar.
        let mode = BillDetail(billID: passed.id).mode
        let bar = BillVoteBarModel(mode: mode, choice: nil)
        XCTAssertTrue(bar.showsButtons)
        XCTAssertEqual(bar.result(ofTapping: .abstain), .vote(.abstain))

        let result = await store.submitVote(billID: passed.id, vote: .abstain, watch: nil)?.value
        XCTAssertEqual(result, .stored)
        XCTAssertEqual(votes.setFeedbackCalls.last, .init(billId: guid, feedback: .abstain, reasons: []), "1.2 sends the Abstain as a vote")
        XCTAssertEqual(access(voteStore, guid: guid, pending: .abstain, didJustVote: true), .open)
        XCTAssertTrue(BillVoteBarModel.shouldFetchStats(unlocked: unlocks(voteStore, guid: guid), writeInFlight: false))

        // Reopened later, with no choice made on the screen: the held Abstain shows and unlocks.
        XCTAssertEqual(voteStore.heldVote(for: guid), .abstain)
        XCTAssertEqual(access(voteStore, guid: guid), .open)
        await settleBillsCache(scope: scope)
    }

    // MARK: - Unlock transitions

    func testAVoteOnThisScreenUnlocksAtOnceAndAsksForStatsOnceStored() async {
        let gate = Gate()
        let votes = FakeBillVotesService()
        votes.holdSetFeedback = gate
        let store = voteStore(votes)
        await store.fetchVoteIfNeeded(for: Self.guid)
        XCTAssertFalse(unlocks(store), "precondition: not voted")
        XCTAssertEqual(BillResultsAccess.make(unlocked: unlocks(store), awaitingSave: false, isChecking: false, canRetry: true), .locked(.notVoted))

        var ledger = BillVoteCastLedger()
        let token = ledger.begin()
        let write = Task { await store.submitVote(billId: Self.guid, vote: .yea) }
        await settle()
        let unlocked = unlocks(store, pending: .yea, didJustVote: true)
        XCTAssertTrue(unlocked)
        XCTAssertEqual(BillResultsAccess.make(unlocked: unlocked, awaitingSave: false, isChecking: false, canRetry: true), .open)
        XCTAssertFalse(BillVoteBarModel.shouldFetchStats(unlocked: unlocked, writeInFlight: ledger.latest != nil), "not while it is sent")

        gate.open()
        let result = await write.value
        XCTAssertEqual(ledger.finish(token, result: result), .keep)
        XCTAssertEqual(result, .stored)
        XCTAssertTrue(BillVoteBarModel.shouldFetchStats(unlocked: unlocks(store), writeInFlight: ledger.latest != nil))
    }

    func testARefusedVoteRelocksAndDropsWhatItShowed() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = backendError("VOTE_DAILY_LIMIT")
        let store = voteStore(votes)
        await store.fetchVoteIfNeeded(for: Self.guid)

        var ledger = BillVoteCastLedger()
        let token = ledger.begin()
        XCTAssertTrue(unlocks(store, pending: .nay, didJustVote: true), "optimistic while it is sent")
        let result = await store.submitVote(billId: Self.guid, vote: .nay)

        XCTAssertEqual(result, .rolledBack(restored: .notVoted))
        XCTAssertEqual(ledger.finish(token, result: result), .rollBack(undismiss: []), "the screen drops its choice")
        let unlocked = unlocks(store)
        XCTAssertFalse(unlocked, "no row: locked again")
        XCTAssertEqual(BillResultsAccess.make(unlocked: unlocked, awaitingSave: true, isChecking: false, canRetry: true), .locked(.notVoted))
        XCTAssertFalse(BillVoteBarModel.fetchesStatsAfterWrite(result: result, stillUnlocked: unlocked), "no stats request after a refusal")
    }

    func testAnUnsavedVoteWaitsForTheServerThenOpens() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = URLError(.notConnectedToInternet)
        let store = voteStore(votes)
        await store.fetchVoteIfNeeded(for: Self.guid)

        let result = await store.submitVote(billId: Self.guid, vote: .yea)
        XCTAssertEqual(result, .notSaved, "kept on the device")
        let unlocked = unlocks(store, pending: .yea)
        XCTAssertTrue(BillVoteBarModel.fetchesStatsAfterWrite(result: result, stillUnlocked: unlocked))
        // The server answered RESULTS_LOCKED: the lock card asks to save the vote, with Try again.
        XCTAssertEqual(BillResultsAccess.make(unlocked: unlocked, awaitingSave: true, isChecking: false, canRetry: true), .awaitingSave(canRetry: true))
        // Try again stored it and the stats loaded: open.
        votes.setFeedbackError = nil
        let retried = await store.submitVote(billId: Self.guid, vote: .yea)
        XCTAssertEqual(retried, .stored)
        XCTAssertEqual(BillResultsAccess.make(unlocked: unlocks(store, pending: .yea), awaitingSave: false, isChecking: false, canRetry: true), .open)
    }

    // MARK: - Reading the rows again (BillVoteStore)

    func testACachedNotVotedIsReadAgainSoAVoteFromAnotherDeviceUnlocks() async {
        for vote in [VoteType.yea, .nay, .abstain] {
            let service = FakeBillVotesService()
            let store = voteStore(service)
            await store.fetchVoteIfNeeded(for: Self.guid)
            XCTAssertEqual(store.vote(for: Self.guid), .notVoted, "precondition: cached as not voted")

            // Voted on device B meanwhile.
            service.singleResult = .success(.voted(.init(vote: vote, votedAt: Date())))
            await store.fetchVoteIfNeeded(for: Self.guid)
            XCTAssertFalse(unlocks(store), "without revalidation the cached answer stands")
            XCTAssertEqual(service.singleRequests.count, 1)

            await store.fetchVoteIfNeeded(for: Self.guid, reportError: false, revalidateNotVoted: true)
            XCTAssertEqual(service.singleRequests.count, 2, "one GET /feedback per open of an unvoted bill")
            XCTAssertEqual(store.heldVote(for: Self.guid), vote)
            XCTAssertTrue(unlocks(store), "\(vote) from another device")

            // A held row is not read again.
            await store.fetchVoteIfNeeded(for: Self.guid, reportError: false, revalidateNotVoted: true)
            XCTAssertEqual(service.singleRequests.count, 2)
        }
    }

    func testAGroupsCachedNotVotedIsReadAgainInOneRequest() async {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let service = FakeBillVotesService()
        service.batchResult = .success([house: .notVoted, senate: .notVoted])
        let store = voteStore(service)
        await store.fetchVotes(for: [house, senate])

        service.batchResult = .success([house: .notVoted, senate: .voted(.init(vote: .abstain, votedAt: Date()))])
        await store.fetchVotes(for: [house, senate], revalidateNotVoted: true)

        XCTAssertEqual(service.batchRequests.last.map(Set.init), [house, senate])
        XCTAssertEqual(store.heldVote(for: senate), .abstain, "an Abstain on the other member is found")
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        XCTAssertEqual(store.companionVote(for: group).effectiveVote, .abstain, "and unlocks the pair")
    }

    func testAfterAReinstallTheVoteIsUnknownAndLockedUntilRead() async {
        let service = FakeBillVotesService()
        service.singleResult = .success(.voted(.init(vote: .nay, votedAt: Date().addingTimeInterval(-3_600))))
        let store = voteStore(service)
        XCTAssertEqual(store.vote(for: Self.guid), .unknown, "an empty cache")
        XCTAssertFalse(unlocks(store), "locked until the row is known")

        await store.fetchVoteIfNeeded(for: Self.guid, reportError: false, revalidateNotVoted: true)
        XCTAssertTrue(unlocks(store))
    }

    func testRevalidationNeverOverwritesAVoteBeingSent() async {
        let gate = Gate()
        let votes = FakeBillVotesService()
        votes.holdSetFeedback = gate
        let store = voteStore(votes)
        await store.fetchVoteIfNeeded(for: Self.guid)

        let write = Task { await store.submitVote(billId: Self.guid, vote: .yea) }
        await settle()
        XCTAssertEqual(store.vote(for: Self.guid), .voted(.yea), "precondition: optimistic")

        votes.batchResult = .success([Self.guid: .notVoted])
        await store.refreshVotes(for: [Self.guid])
        XCTAssertEqual(votes.batchRequests, [], "an id with a write in flight is not read")
        XCTAssertEqual(store.vote(for: Self.guid), .voted(.yea))

        gate.open()
        let stored = await write.value
        XCTAssertEqual(stored, .stored)
        XCTAssertEqual(store.vote(for: Self.guid), .voted(.yea))
    }

    func testAnAnswerThatLeftBeforeAVoteDoesNotOverwriteIt() async {
        let fetchGate = Gate()
        let service = HeldFeedbackService(fetchGate: fetchGate)
        service.single = .notVoted
        let store = voteStore(service)
        // Cached as not voted, then revalidated on open; the answer is slow.
        await store.fetchVoteIfNeeded(for: Self.guid)
        service.holds = true
        let open = Task { await store.fetchVoteIfNeeded(for: Self.guid, reportError: false, revalidateNotVoted: true) }
        await settle()

        // The user votes while the read is out; the server stores it.
        let stored = await store.submitVote(billId: Self.guid, vote: .abstain)
        XCTAssertEqual(stored, .stored)
        fetchGate.open()
        _ = await open.value

        XCTAssertEqual(store.heldVote(for: Self.guid), .abstain, "the older not-voted answer is dropped")
        XCTAssertTrue(unlocks(store))
    }

    func testRefreshAfterResultsLockedFollowsTheServersRows() async {
        let votes = FakeBillVotesService()
        votes.setFeedbackError = URLError(.timedOut)
        let store = voteStore(votes)
        await store.fetchVoteIfNeeded(for: Self.guid)
        let kept = await store.submitVote(billId: Self.guid, vote: .yea)
        XCTAssertEqual(kept, .notSaved)
        XCTAssertTrue(unlocks(store), "precondition: the kept vote shows")

        // RESULTS_LOCKED: the server holds no row, so the screen stops counting the kept vote as a row.
        votes.batchResult = .success([Self.guid: .notVoted])
        await store.refreshVotes(for: [Self.guid, " "])
        XCTAssertEqual(votes.batchRequests, [[Self.guid]])
        XCTAssertEqual(store.vote(for: Self.guid), .notVoted)
        XCTAssertFalse(unlocks(store))
        XCTAssertTrue(unlocks(store, pending: .yea), "the screen that cast it still shows it, awaiting save")

        // A failed read changes nothing and stays quiet.
        votes.batchResult = .failure(URLError(.notConnectedToInternet))
        store.lastError = nil
        await store.refreshVotes(for: [Self.guid])
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.vote(for: Self.guid), .notVoted)
    }
}

/// `GET /feedback` that can be held open (`holds`) until `fetchGate` opens.
@MainActor
private final class HeldFeedbackService: BillVotesServicing {
    let fetchGate: Gate
    var holds = false
    var single: BillVotesService.RemoteVoteState = .notVoted

    init(fetchGate: Gate) {
        self.fetchGate = fetchGate
    }

    func fetchFeedback(billIds: [String]) async throws -> [String: BillVotesService.RemoteVoteState] {
        if holds { await fetchGate.wait() }
        return Dictionary(uniqueKeysWithValues: billIds.map { ($0, single) })
    }

    func fetchFeedback(billId: String) async throws -> BillVotesService.RemoteVoteState {
        if holds { await fetchGate.wait() }
        return single
    }

    func setFeedback(billId: String, feedback: VoteType, reasons: [String]) async throws {}
}
