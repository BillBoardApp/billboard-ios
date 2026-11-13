import SwiftUI
import XCTest
@testable import Billboard

/// The pinned vote bar (spec D 2.1.4) and the Watch control's plan (2.1.5), as pure models: what the
/// bar shows for each mode and vote, what a tap does, the coach mark, and what a Watch tap writes.
/// `BillVoteWatchTests` checks the same against the stores.
@MainActor
final class BillVoteBarModelTests: XCTestCase {

    // MARK: - Layout

    /// Civic Record project decision 1: voting stays open after Congress decides a bill, so a Passed, Failed
    /// or Became law bill opens with the same bar as any bill, from every list that opens one by mode
    /// (Bills and Skipped cards, the tour, the Weekly Brief); an updated bill still asks again.
    func testADecidedBillOpensWithTheThreeButtonsFromEveryListThatPicksAMode() {
        let decidedCard = BillBoardDerivedCollections.boardItemType(for: Bill(title: "A law", category: "Other", soWhat: "", billStatus: .finalized, userVoted: false))
        let alert = BillAlert(
            id: UUID(), sponsorMemberID: nil, billID: UUID(), title: "Passed the House", category: "Other", summary: "",
            soWhat: "", lifeAreas: [], subCategory: nil, alertText: nil, actionDate: nil, actionCode: nil, actionType: nil, date: Date()
        )
        let modes: [(String, BillDetail.Mode)] = [
            ("a decided card", BillDetail.Mode(opening: decidedCard)),
            ("a Congress action card", BillDetail.Mode(opening: BillBoardItem.ItemType.alert(alert))),
            ("a new card", BillDetail.Mode(opening: BillBoardItem.ItemType.bill))
        ] + ([.passed, .failed, .finalized, .new] as [WeeklyDigestItem.BillState]).map { state in
            ("a \(state.rawValue) brief item", BillDetail.Mode(opening: state))
        }
            + [("a brief item with no state", BillDetail.Mode(opening: nil as WeeklyDigestItem.BillState?))]

        for (name, mode) in modes {
            XCTAssertEqual(mode, .full, name)
            let model = BillVoteBarModel(mode: mode, choice: nil)
            XCTAssertEqual(model.layout, .choose(caption: nil, selected: nil), name)
            XCTAssertTrue(model.showsButtons, name)
            XCTAssertEqual(BillVoteBarModel(mode: mode, choice: .yea).layout, .collapsed(.yea), "\(name): a vote collapses it as on any bill")
        }
        XCTAssertEqual(BillDetail.Mode(opening: BillBoardItem.ItemType.updated), .updatedOnly)
        XCTAssertEqual(BillDetail.Mode(opening: WeeklyDigestItem.BillState.updated), .updatedOnly)
    }

    func testNotVotedShowsTheThreeButtonsWithNoneSelected() {
        let model = BillVoteBarModel(mode: .full, choice: nil)
        XCTAssertEqual(model.layout, .choose(caption: nil, selected: nil))
        XCTAssertTrue(model.showsButtons)
        XCTAssertNil(model.selectedChoice, "no vote is pre-selected")
        XCTAssertNil(model.collapsedTitle)
    }

    func testAnUnknownVoteSaysItIsChecking() {
        let model = BillVoteBarModel(mode: .full, choice: nil, isChecking: true)
        XCTAssertEqual(model.layout, .choose(caption: "Checking your vote…", selected: nil))
    }

    func testAnUpdatedBillAsksForANewVoteWithAllThreeChoices() {
        for isChecking in [false, true] {
            let model = BillVoteBarModel(mode: .updatedOnly, choice: nil, isChecking: isChecking)
            XCTAssertEqual(model.layout, .choose(caption: "This bill's summary changed. Vote again:", selected: nil))
        }
    }

    func testAVoteCollapsesTheBarToOneRowWithChange() {
        for mode in [BillDetail.Mode.full, .updatedOnly] {
            for choice in VoteChoice.allCases {
                let model = BillVoteBarModel(mode: mode, choice: choice)
                XCTAssertEqual(model.layout, .collapsed(choice))
                XCTAssertFalse(model.showsButtons)
            }
        }
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: .yea).collapsedTitle, "You voted Yea")
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: .nay).collapsedTitle, "You voted Nay")
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: .abstain).collapsedTitle, "You abstained")
    }

    func testChangeOpensTheButtonsWithTheCurrentChoiceFilled() {
        for choice in VoteChoice.allCases {
            let model = BillVoteBarModel(mode: .full, choice: choice, isChanging: true)
            XCTAssertEqual(model.layout, .choose(caption: nil, selected: choice))
            XCTAssertEqual(model.selectedChoice, choice)
        }
    }

    func testCheckingDoesNotHideAKnownVote() {
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: .nay, isChecking: true).layout, .collapsed(.nay))
    }

    // MARK: - The vote shown on re-entry

    func testShownChoicePrefersThisScreenThenACountedVoteThenAHeldAbstain() {
        XCTAssertEqual(BillVoteBarModel.shownChoice(pending: .nay, counted: .yea, held: .yea), .nay)
        XCTAssertEqual(BillVoteBarModel.shownChoice(pending: .abstain, counted: nil, held: nil), .abstain)
        XCTAssertEqual(BillVoteBarModel.shownChoice(pending: nil, counted: .yea, held: .yea), .yea)
        XCTAssertEqual(BillVoteBarModel.shownChoice(pending: nil, counted: nil, held: .abstain), .abstain)
        XCTAssertNil(BillVoteBarModel.shownChoice(pending: nil, counted: nil, held: nil))
        XCTAssertNil(BillVoteBarModel.shownChoice(pending: nil, counted: nil, held: .yea), "only an Abstain falls back to the held row")
        XCTAssertFalse(BillVoteBarModel.unlocksResults(choice: nil, didJustVote: false, holdsRow: false))
        XCTAssertTrue(BillVoteBarModel.unlocksResults(choice: .abstain, didJustVote: false, holdsRow: false))
        XCTAssertTrue(BillVoteBarModel.unlocksResults(choice: nil, didJustVote: true, holdsRow: false))
    }

    /// Spec D 2.1.4: an Abstain from the bar unlocks Results. Reopening the bill (a new screen, so no
    /// choice made on it) still shows "You abstained · Change" with Results open, from the vote
    /// store's row, both for an Abstain made on this device and for one the server returns.
    func testAnEarlierAbstainReopensAsYouAbstainedWithResultsOpen() async {
        let guid = "BILLS-119hr1"
        let service = FakeBillVotesService()
        let store = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: service)

        _ = await store.setVote(billId: guid, vote: .abstain)
        XCTAssertEqual(store.vote(for: guid), .notVoted, "precondition: the published state reports an Abstain as not voted")
        assertReopensAsAbstained(held: store.heldVote(for: guid), counted: store.vote(for: guid))

        let otherDevice = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: service)
        service.singleResult = .success(.voted(.init(vote: .abstain, votedAt: Date())))
        await otherDevice.fetchVoteIfNeeded(for: guid)
        assertReopensAsAbstained(held: otherDevice.heldVote(for: guid), counted: otherDevice.vote(for: guid))

        // An "updated" push clears the row: the bill asks for a vote again.
        otherDevice.clearVote(for: guid)
        let cleared = BillVoteBarModel.shownChoice(pending: nil, counted: nil, held: otherDevice.heldVote(for: guid))
        XCTAssertNil(cleared)
        XCTAssertEqual(BillVoteBarModel(mode: .updatedOnly, choice: cleared).layout, .choose(caption: BillVoteBarModel.updatedCaption, selected: nil))
        XCTAssertFalse(BillVoteBarModel.unlocksResults(choice: cleared, didJustVote: false, holdsRow: otherDevice.heldVote(for: guid) != nil))
    }

    /// An "updated" push clears only the local row; opening the bill (`.updatedOnly`) fetches the
    /// server's Abstain from before the update again. The bar still asks for a new vote, and a tap on
    /// Abstain records it (so the bill leaves Bills). Results stay open (INT-11, the default answer to
    /// project question 1): the server keeps the row, so a pre-update Abstain counts like a pre-update Yea.
    func testAnUpdatedBillAsksForAVoteAgainAfterTheServerReturnsTheAbstainFromBeforeTheUpdate() async throws {
        let guid = "BILLS-119hr2"
        let updatedAt = try XCTUnwrap(FlexibleISO8601.parse("2026-10-01T12:00:00Z"))
        let service = FakeBillVotesService()
        service.singleResult = .success(.voted(.init(vote: .abstain, votedAt: updatedAt.addingTimeInterval(-86_400))))
        let store = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: service)
        await store.fetchVoteIfNeeded(for: guid)

        store.clearVote(for: guid)
        // What bill detail runs on open: the cleared row is fetched again, and the server still holds it.
        await store.fetchVoteIfNeeded(for: guid)
        XCTAssertEqual(store.heldVote(for: guid), .abstain, "precondition: the refetched row is the old Abstain")

        let updated = BillVoteBarModel.shownChoice(
            pending: nil,
            counted: nil,
            held: store.heldVote(for: guid),
            mode: .updatedOnly,
            heldVotedAt: store.heldVoteDate(for: guid),
            billUpdatedAt: updatedAt
        )
        XCTAssertNil(updated)
        XCTAssertNil(
            BillVoteBarModel.shownChoice(pending: nil, counted: nil, held: .abstain, mode: .updatedOnly),
            "an Abstain of unknown age is taken as older than the update"
        )
        let model = BillVoteBarModel(mode: .updatedOnly, choice: updated)
        XCTAssertEqual(model.layout, .choose(caption: BillVoteBarModel.updatedCaption, selected: nil))
        XCTAssertEqual(model.result(ofTapping: .abstain), .vote(.abstain))
        XCTAssertTrue(
            BillVoteBarModel.unlocksResults(choice: updated, didJustVote: false, holdsRow: store.heldVote(for: guid) != nil),
            "the held row unlocks though the bar asks for a vote again"
        )

        XCTAssertEqual(
            BillVoteBarModel.shownChoice(pending: nil, counted: nil, held: .abstain, mode: .full),
            .abstain,
            "a new bill still reopens as You abstained"
        )
        XCTAssertEqual(
            BillVoteBarModel.shownChoice(pending: .abstain, counted: nil, held: .abstain, mode: .updatedOnly),
            .abstain,
            "an Abstain made on the updated screen shows"
        )
        XCTAssertEqual(BillVoteBarModel.shownChoice(pending: nil, counted: .nay, held: .nay, mode: .updatedOnly), .nay)
    }

    /// An updated bill opens in `.updatedOnly` from its status (Bills, Skipped, the weekly digest), not
    /// only after a push. An Abstain cast since the update, on the updated screen itself or on another
    /// device, answers the "Vote again" ask: reopening the bill shows "You abstained · Change" with
    /// Results open, as a Yea or Nay cast there would.
    func testAnAbstainCastSinceTheUpdateReopensAsYouAbstainedOnAnUpdatedBill() async {
        let guid = "BILLS-119hr5"
        let updatedAt = Date().addingTimeInterval(-3_600)
        let service = FakeBillVotesService()
        let store = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: service)

        // Abstain on the updated screen, then leave and reopen it (from the digest): no pending choice.
        _ = await store.setVote(billId: guid, vote: .abstain)
        XCTAssertEqual(store.vote(for: guid), .notVoted, "precondition: the published state reports an Abstain as not voted")
        assertUpdatedBillReopensAsAbstained(held: store.heldVote(for: guid), heldVotedAt: store.heldVoteDate(for: guid), updatedAt: updatedAt)

        // The same Abstain fetched on another device.
        let otherDevice = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: service)
        service.singleResult = .success(.voted(.init(vote: .abstain, votedAt: updatedAt.addingTimeInterval(60))))
        await otherDevice.fetchVoteIfNeeded(for: guid)
        assertUpdatedBillReopensAsAbstained(held: otherDevice.heldVote(for: guid), heldVotedAt: otherDevice.heldVoteDate(for: guid), updatedAt: updatedAt)

        // A later update makes that Abstain old again.
        XCTAssertNil(BillVoteBarModel.shownChoice(
            pending: nil,
            counted: nil,
            held: otherDevice.heldVote(for: guid),
            mode: .updatedOnly,
            heldVotedAt: otherDevice.heldVoteDate(for: guid),
            billUpdatedAt: updatedAt.addingTimeInterval(120)
        ))
    }

    private func assertUpdatedBillReopensAsAbstained(held: VoteType?, heldVotedAt: Date?, updatedAt: Date, file: StaticString = #filePath, line: UInt = #line) {
        let choice = BillVoteBarModel.shownChoice(
            pending: nil,
            counted: nil,
            held: held,
            mode: .updatedOnly,
            heldVotedAt: heldVotedAt,
            billUpdatedAt: updatedAt
        )
        XCTAssertEqual(choice, .abstain, file: file, line: line)
        let model = BillVoteBarModel(mode: .updatedOnly, choice: choice)
        XCTAssertEqual(model.layout, .collapsed(.abstain), "not the Vote again caption", file: file, line: line)
        XCTAssertEqual(model.collapsedTitle, "You abstained", file: file, line: line)
        XCTAssertTrue(BillVoteBarModel.unlocksResults(choice: choice, didJustVote: false, holdsRow: held != nil), file: file, line: line)
    }

    /// An Abstain held from another device, a reinstall or an R1 swipe, on a bill this device still
    /// lists (skips and dismissals stay on the device): Change, then Abstain records it, which takes
    /// the bill off Bills. Once dismissed here (or for an Abstain made on this screen), Abstain only
    /// closes the buttons.
    func testAHeldAbstainOnABillStillOnBillsIsRecordedWhenTapped() async {
        let guid = "BILLS-119hr3"
        let bill = companionTestBill(guid)
        let scope = "vote-bar-model-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let billsStore = BillsStore(bills: [bill], cacheScope: scope, service: FakeBillsService(), preferencesService: FakePreferencesService())
        let readState = AppReadState(scope: .user("vote-bar-model-tests"), store: InMemoryReadStateStore())

        func model(pending: VoteChoice?) -> BillVoteBarModel {
            let choice = BillVoteBarModel.shownChoice(pending: pending, counted: nil, held: .abstain)
            return BillVoteBarModel(
                mode: .full,
                choice: choice,
                isChanging: true,
                recordsHeldAbstain: BillVoteBarModel.recordsHeldAbstain(
                    pending: pending,
                    shown: choice,
                    isListedHere: !billsStore.isDismissed(billID: bill.id, readState: readState)
                )
            )
        }

        XCTAssertFalse(billsStore.isDismissed(billID: bill.id, readState: readState), "precondition: on Bills here")
        XCTAssertEqual(model(pending: nil).layout, .choose(caption: nil, selected: .abstain))
        XCTAssertEqual(model(pending: nil).result(ofTapping: .abstain), .vote(.abstain), "records it, so the bill leaves Bills")
        XCTAssertEqual(model(pending: nil).result(ofTapping: .yea), .vote(.yea))
        XCTAssertEqual(model(pending: .abstain).result(ofTapping: .abstain), .collapse, "made on this screen: already recorded and dismissed")

        // What recording an Abstain from the bar does on this device.
        billsStore.dismiss(billID: bill.id, readState: readState)
        XCTAssertTrue(billsStore.isDismissed(billID: bill.id, readState: readState))
        XCTAssertEqual(model(pending: nil).result(ofTapping: .abstain), .collapse)

        XCTAssertFalse(BillVoteBarModel.recordsHeldAbstain(pending: nil, shown: .yea, isListedHere: true), "only an Abstain")
        XCTAssertFalse(BillVoteBarModel.recordsHeldAbstain(pending: nil, shown: nil, isListedHere: true))
    }

    private func assertReopensAsAbstained(held: VoteType?, counted: VoteState, file: StaticString = #filePath, line: UInt = #line) {
        let countedChoice: VoteChoice? = {
            if case .voted(let type) = counted, type.countsAsVote { return VoteChoice(type) }
            return nil
        }()
        let choice = BillVoteBarModel.shownChoice(pending: nil, counted: countedChoice, held: held)
        XCTAssertEqual(choice, .abstain, file: file, line: line)
        let model = BillVoteBarModel(mode: .full, choice: choice)
        XCTAssertEqual(model.layout, .collapsed(.abstain), file: file, line: line)
        XCTAssertEqual(model.collapsedTitle, "You abstained", file: file, line: line)
        XCTAssertTrue(BillVoteBarModel.unlocksResults(choice: choice, didJustVote: false, holdsRow: held != nil), "no second vote is needed to see Results", file: file, line: line)
    }

    // MARK: - Taps

    func testTappingAChoiceVotes() {
        let model = BillVoteBarModel(mode: .full, choice: nil)
        for choice in VoteChoice.allCases {
            XCTAssertEqual(model.result(ofTapping: choice), .vote(choice))
        }
    }

    func testTappingTheCurrentVoteWhileChangingWritesNothing() {
        let model = BillVoteBarModel(mode: .full, choice: .yea, isChanging: true)
        XCTAssertEqual(model.result(ofTapping: .yea), .collapse)
        XCTAssertEqual(model.result(ofTapping: .nay), .vote(.nay))
        XCTAssertEqual(model.result(ofTapping: .abstain), .vote(.abstain))
    }

    // MARK: - Coach mark (spec D 2.5.5)

    func testTheCoachMarkShowsOnlyOverTheButtonsOfAnUnvotedBillWhilePending() {
        XCTAssertTrue(BillVoteBarModel(mode: .full, choice: nil).showsCoachMark(pending: true, featureEnabled: true))
        XCTAssertTrue(BillVoteBarModel(mode: .updatedOnly, choice: nil).showsCoachMark(pending: true, featureEnabled: true), "after the summary-changed caption")
        XCTAssertFalse(BillVoteBarModel(mode: .full, choice: nil).showsCoachMark(pending: false, featureEnabled: true))
        XCTAssertFalse(BillVoteBarModel(mode: .full, choice: nil).showsCoachMark(pending: true, featureEnabled: false), "the feature flag turns it off")
        XCTAssertFalse(BillVoteBarModel(mode: .full, choice: .abstain).showsCoachMark(pending: true, featureEnabled: true))
        XCTAssertFalse(BillVoteBarModel(mode: .full, choice: .yea, isChanging: true).showsCoachMark(pending: true, featureEnabled: true))
    }

    /// While the vote is checked the buttons are disabled, so the panel says "Checking your vote…", not the coach
    /// mark (spec 3.10 "Other states"); at the accessibility sizes Your vote holds nothing then. The tour's "Open
    /// this bill" sets the coach mark on a first run, when the vote is often not known yet. An updated bill's
    /// buttons stay enabled while checked, so its coach mark stays, after its caption (project decision of
    /// 2026-10-21): the panel's one strip is the caption.
    func testTheCoachMarkWaitsWhileTheVoteIsChecked() {
        let checking = BillVoteBarModel(mode: .full, choice: nil, isChecking: true)
        XCTAssertTrue(checking.isAwaitingVoteCheck, "the buttons are disabled")
        let shows = checking.showsCoachMark(pending: true, featureEnabled: true)
        XCTAssertFalse(shows, "no coach mark over disabled buttons")
        XCTAssertEqual(checking.panelStrip(in: .regular, refusal: nil, showsCoachMark: shows), .caption(BillVoteBarModel.checkingCaption))
        for sizeClass in [BillVoteBarModel.TextSizeClass.extraLarge, .accessibility] {
            XCTAssertEqual(checking.yourVoteRows(in: sizeClass, refusal: nil, showsCoachMark: shows), .none, "\(sizeClass)")
        }
        XCTAssertEqual(checking.accessibilityButton, .checking)

        let checked = BillVoteBarModel(mode: .full, choice: nil)
        XCTAssertTrue(checked.showsCoachMark(pending: true, featureEnabled: true), "once the check finds no vote")

        let updated = BillVoteBarModel(mode: .updatedOnly, choice: nil, isChecking: true)
        XCTAssertFalse(updated.isAwaitingVoteCheck)
        XCTAssertTrue(updated.showsCoachMark(pending: true, featureEnabled: true))
        XCTAssertEqual(updated.panelStrip(in: .regular, refusal: nil, showsCoachMark: true), .caption(BillVoteBarModel.updatedCaption))
    }

    /// An updated bill opened from the tour's "Open this bill", in the project's decision of 2026-10-21 (the refusal,
    /// Change your vote, the summary-changed caption, then the coach mark): the panel's one strip is "This
    /// bill's summary changed. Vote again:", and from xxxLarge up Your vote, which stacks every row that
    /// applies, shows the caption and then the coach mark, after a refusal when there is one. The coach mark
    /// does not wait for another bill there: only the panel's one strip leaves it out. Once the updated bill
    /// is voted on, neither shows.
    func testOnAnUpdatedBillOpenedFromTheTourTheCaptionComesBeforeTheCoachMark() {
        let updated = BillVoteBarModel(mode: .updatedOnly, choice: nil)
        XCTAssertTrue(updated.asksToVoteAgain)
        let shows = updated.showsCoachMark(pending: true, featureEnabled: true)
        XCTAssertTrue(shows, "pending, over the enabled buttons")
        XCTAssertEqual(updated.panelStrip(in: .regular, refusal: nil, showsCoachMark: shows), .caption(BillVoteBarModel.updatedCaption), "the caption before the coach mark")
        XCTAssertEqual(updated.panelStrip(in: .regular, refusal: AuthErrorMessages.voteDailyLimit, showsCoachMark: shows), .refusal(AuthErrorMessages.voteDailyLimit))
        XCTAssertEqual(
            updated.yourVoteRows(in: .extraLarge, refusal: nil, showsCoachMark: shows),
            BillVoteBarModel.YourVoteRows(caption: BillVoteBarModel.updatedCaption, coachMark: BillVoteBarModel.coachMarkText)
        )
        XCTAssertEqual(
            updated.yourVoteRows(in: .accessibility, refusal: AuthErrorMessages.voteDailyLimit, showsCoachMark: shows),
            BillVoteBarModel.YourVoteRows(
                refusal: AuthErrorMessages.voteDailyLimit,
                caption: BillVoteBarModel.updatedCaption,
                coachMark: BillVoteBarModel.accessibilityCoachMarkText
            ),
            "the refusal, the caption, the coach mark: the state testYourVoteTakesThePanelsRowsAtTheLargerSizes draws"
        )
        for sizeClass in [BillVoteBarModel.TextSizeClass.extraLarge, .accessibility] {
            XCTAssertEqual(
                updated.yourVoteRows(in: sizeClass, refusal: nil, showsCoachMark: false),
                BillVoteBarModel.YourVoteRows(caption: BillVoteBarModel.updatedCaption),
                "\(sizeClass): the caption alone once the coach mark is done"
            )
        }

        let votedSinceUpdate = BillVoteBarModel(mode: .updatedOnly, choice: .yea)
        XCTAssertFalse(votedSinceUpdate.asksToVoteAgain)
        XCTAssertFalse(votedSinceUpdate.showsCoachMark(pending: true, featureEnabled: true))
        XCTAssertNil(votedSinceUpdate.panelStrip(in: .regular, refusal: nil, showsCoachMark: false))
    }

    func testTheCoachMarkCopy() {
        XCTAssertEqual(BillVoteBarModel.coachMarkText, "Choose Yea, Nay or Abstain. You can change it later.")
        XCTAssertEqual(BillVoteBarModel.coachMarkDismissTitle, "Not now")
    }

    // MARK: - Accessibility and identifiers

    func testIdentifiersAndLabels() {
        XCTAssertEqual(VoteChoice.allCases.map(BillVoteBarModel.identifier(for:)), ["bill.vote.yea", "bill.vote.nay", "bill.vote.abstain"])
        XCTAssertEqual(BillVoteBarModel.changeIdentifier, "bill.vote.change")
        XCTAssertEqual(VoteChoice.allCases.map(\.accessibilityLabel), ["Vote Yea", "Vote Nay", "Abstain"])
        XCTAssertEqual(BillVoteBarModel.accessibilityLabel, "Vote")
        XCTAssertEqual(BillVoteBarModel.dialogTitle, "Your vote")
        for identifier in VoteChoice.allCases.map(BillVoteBarModel.identifier(for:)) {
            XCTAssertFalse(identifier.contains("watch"), "the _&_watch identifiers are gone")
        }
        XCTAssertEqual(BillWatchCopy.toolbarIdentifier, "bill.watch.toggle")
    }

    func testButtonsAreLeftToRightYeaNayAbstain() {
        XCTAssertEqual(VoteChoice.allCases, [.yea, .nay, .abstain])
        XCTAssertEqual(VoteChoice.allCases.map(\.symbolName), ["checkmark", "xmark", "minus"])
    }

    // MARK: - Watch

    func testWatchCopy() {
        XCTAssertEqual(BillWatchCopy.toolbarLabel(isWatching: false), "Watch")
        XCTAssertEqual(BillWatchCopy.toolbarLabel(isWatching: true), "Watching")
        XCTAssertEqual(BillWatchCopy.symbolName(isWatching: false), "binoculars")
        XCTAssertEqual(BillWatchCopy.symbolName(isWatching: true), "binoculars.fill")
        XCTAssertEqual(BillWatchCopy.rowTitle, "Watch this bill")
        XCTAssertEqual(BillWatchCopy.rowSubtitle, "Get notified when Congress acts on it.")
    }

    func testWatchingAddsOneWatchToTheVoteTarget() {
        let plan = BillWatchPlan.make(watch: true, targetGuid: " BILLS-119hr900 ", memberGuids: ["BILLS-119hr900", "BILLS-119s456"])
        XCTAssertEqual(plan, BillWatchPlan(addGuid: "BILLS-119hr900", unwatchBill: false, removeGuids: []))
    }

    func testStoppingRemovesEveryGuidTheWatchCanSitOn() {
        let plan = BillWatchPlan.make(
            watch: false,
            targetGuid: "BILLS-119hr900",
            memberGuids: ["BILLS-119hr900", " BILLS-119s456 ", "", "BILLS-119hr900"]
        )
        XCTAssertEqual(plan, BillWatchPlan(addGuid: nil, unwatchBill: true, removeGuids: ["BILLS-119hr900", "BILLS-119s456"]))
    }

    func testABillWithoutAGuidHasNothingToWatch() {
        XCTAssertNil(BillWatchPlan.make(watch: true, targetGuid: nil, memberGuids: []).addGuid)
        XCTAssertEqual(BillWatchPlan.make(watch: false, targetGuid: "  ", memberGuids: []).removeGuids, [])
    }

    // MARK: - The ballot (Civic Record spec 3.10, 3.11)

    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let enUS = Locale(identifier: "en_US")

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents(year: year, month: month, day: day, hour: 12)
        components.timeZone = newYork
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func stamp(_ choice: VoteChoice, votedAt: Date?, now: Date? = nil) -> BallotStampCopy {
        BallotStampCopy(choice: choice, votedAt: votedAt, now: now ?? Self.date(2026, 10, 21), locale: Self.enUS, timeZone: Self.newYork)
    }

    /// "YOU VOTED YEA · OCT 17" (the roles set the capitals); VoiceOver reads "You voted Yea on October 17".
    func testTheStampSaysTheVoteAndItsDate() {
        let yea = stamp(.yea, votedAt: Self.date(2026, 10, 17))
        XCTAssertEqual(yea.title, "You voted Yea")
        XCTAssertEqual(yea.printedDate, "Oct 17")
        XCTAssertEqual(yea.spokenDate, "October 17")
        XCTAssertEqual(yea.accessibilityLabel, "You voted Yea on October 17")
        XCTAssertEqual(stamp(.nay, votedAt: Self.date(2026, 10, 17)).accessibilityLabel, "You voted Nay on October 17")
        XCTAssertEqual(stamp(.abstain, votedAt: Self.date(2026, 10, 17)).accessibilityLabel, "You abstained on October 17")
        XCTAssertTrue(TextRole.stampLarge.isUppercase && TextRole.docket.isUppercase, "the capitals are a style, not the words")
    }

    /// No date known: the no-date form, read "You voted Yea". A vote from another year carries its year.
    func testTheNoDateFormAndAnotherYear() {
        let noDate = stamp(.yea, votedAt: nil)
        XCTAssertNil(noDate.printedDate)
        XCTAssertNil(noDate.spokenDate)
        XCTAssertEqual(noDate.accessibilityLabel, "You voted Yea")
        XCTAssertEqual(noDate.committedLabel(isChange: false), "You voted Yea.")

        let lastYear = stamp(.nay, votedAt: Self.date(2025, 3, 4))
        XCTAssertEqual(lastYear.printedDate, "Mar 4, 2025")
        XCTAssertEqual(lastYear.accessibilityLabel, "You voted Nay on March 4, 2025")
    }

    /// The first focus after a vote reads "You voted Yea on October 17."; after a change "Your vote is now Nay.".
    func testTheStampsOneTimeLabels() {
        XCTAssertEqual(stamp(.yea, votedAt: Self.date(2026, 10, 17)).committedLabel(isChange: false), "You voted Yea on October 17.")
        XCTAssertEqual(stamp(.nay, votedAt: Self.date(2026, 10, 17)).committedLabel(isChange: true), "Your vote is now Nay.")
        XCTAssertEqual(BillVoteBarModel.committedAnnouncement(.yea, isChange: false), "You voted Yea.")
        XCTAssertEqual(BillVoteBarModel.committedAnnouncement(.abstain, isChange: false), "You abstained.")
        XCTAssertEqual(BillVoteBarModel.committedAnnouncement(.abstain, isChange: true), "Your vote is now Abstain.")
    }

    /// Up to xxLarge three buttons and the strips in the panel; xxxLarge three buttons and the strips in Your
    /// vote; AX1 to AX5 one button (spec 3.10 "At large and accessibility sizes").
    func testTheTextSizeClasses() {
        for size in [DynamicTypeSize.xSmall, .large, .xLarge, .xxLarge] {
            XCTAssertEqual(BillVoteBarModel.TextSizeClass(size), .regular, "\(size)")
        }
        XCTAssertEqual(BillVoteBarModel.TextSizeClass(.xxxLarge), .extraLarge)
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            XCTAssertEqual(BillVoteBarModel.TextSizeClass(size), .accessibility, "\(size)")
        }
    }

    /// One strip at a time in the panel, in the project's decision of 2026-10-21: the refusal, then "Change your
    /// vote", the caption ("This bill's summary changed. Vote again:" or "Checking your vote…"), then the coach
    /// mark.
    func testThePanelShowsOneStripAtATime() {
        let notVoted = BillVoteBarModel(mode: .full, choice: nil)
        let refusal = AuthErrorMessages.voteDailyLimit
        XCTAssertNil(notVoted.panelStrip(in: .regular, refusal: nil, showsCoachMark: false))
        XCTAssertEqual(notVoted.panelStrip(in: .regular, refusal: refusal, showsCoachMark: true), .refusal(refusal))
        XCTAssertEqual(notVoted.panelStrip(in: .regular, refusal: nil, showsCoachMark: true), .coachMark)

        let updated = BillVoteBarModel(mode: .updatedOnly, choice: nil)
        XCTAssertEqual(updated.panelStrip(in: .regular, refusal: nil, showsCoachMark: false), .caption(BillVoteBarModel.updatedCaption))
        XCTAssertEqual(updated.panelStrip(in: .regular, refusal: nil, showsCoachMark: true), .caption(BillVoteBarModel.updatedCaption), "the caption before the coach mark")
        XCTAssertEqual(updated.panelStrip(in: .regular, refusal: refusal, showsCoachMark: true), .refusal(refusal), "the refusal before the caption")

        let checking = BillVoteBarModel(mode: .full, choice: nil, isChecking: true)
        XCTAssertEqual(checking.panelStrip(in: .regular, refusal: nil, showsCoachMark: false), .caption("Checking your vote…"))
        XCTAssertEqual(checking.panelStrip(in: .regular, refusal: nil, showsCoachMark: true), .caption("Checking your vote…"))

        let changing = BillVoteBarModel(mode: .full, choice: .nay, isChanging: true)
        XCTAssertEqual(changing.panelStrip(in: .regular, refusal: nil, showsCoachMark: false), .changing)
        XCTAssertEqual(changing.panelStrip(in: .regular, refusal: nil, showsCoachMark: true), .changing, "Change your vote before the coach mark")
        XCTAssertEqual(changing.panelStrip(in: .regular, refusal: refusal, showsCoachMark: true), .refusal(refusal), "the refusal before Change your vote")
        XCTAssertEqual(changing.panelStrip(in: .extraLarge, refusal: nil, showsCoachMark: false), .changing, "Cancel stays with the buttons")
        XCTAssertNil(changing.panelStrip(in: .accessibility, refusal: nil, showsCoachMark: false))

        let voted = BillVoteBarModel(mode: .full, choice: .yea)
        XCTAssertNil(voted.panelStrip(in: .regular, refusal: nil, showsCoachMark: false))
        XCTAssertEqual(voted.panelStrip(in: .regular, refusal: refusal, showsCoachMark: false), .refusal(refusal), "a refused change, over the stamp")

        for sizeClass in [BillVoteBarModel.TextSizeClass.extraLarge, .accessibility] {
            XCTAssertNil(notVoted.panelStrip(in: sizeClass, refusal: refusal, showsCoachMark: true), "\(sizeClass)")
            XCTAssertNil(updated.panelStrip(in: sizeClass, refusal: nil, showsCoachMark: false), "\(sizeClass)")
        }
    }

    /// From xxxLarge up the refusal, the `.updatedOnly` caption and the coach mark are rows of Your vote, each
    /// that applies, in the panel's order; "Checking your vote…" is Your vote's own first line; at the
    /// accessibility sizes the full stamp follows once voted, and the coach mark speaks of the Vote button.
    func testTheRowsThatMoveIntoYourVote() {
        let refusal = AuthErrorMessages.voteDailyLimit
        let updated = BillVoteBarModel(mode: .updatedOnly, choice: nil)
        XCTAssertEqual(updated.yourVoteRows(in: .regular, refusal: refusal, showsCoachMark: true), .none)
        XCTAssertEqual(
            updated.yourVoteRows(in: .extraLarge, refusal: refusal, showsCoachMark: true),
            BillVoteBarModel.YourVoteRows(refusal: refusal, caption: BillVoteBarModel.updatedCaption, coachMark: BillVoteBarModel.coachMarkText)
        )
        XCTAssertEqual(
            updated.yourVoteRows(in: .accessibility, refusal: nil, showsCoachMark: true),
            BillVoteBarModel.YourVoteRows(caption: BillVoteBarModel.updatedCaption, coachMark: "Tap Vote to choose Yea, Nay or Abstain. You can change it later.")
        )
        let notVoted = BillVoteBarModel(mode: .full, choice: nil)
        XCTAssertEqual(
            notVoted.yourVoteRows(in: .extraLarge, refusal: refusal, showsCoachMark: true),
            BillVoteBarModel.YourVoteRows(refusal: refusal, coachMark: BillVoteBarModel.coachMarkText)
        )
        XCTAssertEqual(
            notVoted.yourVoteRows(in: .accessibility, refusal: nil, showsCoachMark: true),
            BillVoteBarModel.YourVoteRows(coachMark: "Tap Vote to choose Yea, Nay or Abstain. You can change it later.")
        )
        let checking = BillVoteBarModel(mode: .full, choice: nil, isChecking: true)
        XCTAssertEqual(checking.yourVoteRows(in: .extraLarge, refusal: nil, showsCoachMark: false), .none)

        let voted = BillVoteBarModel(mode: .full, choice: .abstain)
        XCTAssertEqual(voted.yourVoteRows(in: .extraLarge, refusal: nil, showsCoachMark: false), .none, "the stamp stays in the panel at xxxLarge")
        XCTAssertEqual(voted.yourVoteRows(in: .accessibility, refusal: nil, showsCoachMark: false), BillVoteBarModel.YourVoteRows(stamp: .abstain))
    }

    /// The one button at the accessibility sizes: Vote, Checking… (disabled), or the voted capsule.
    func testTheOneButtonAtTheAccessibilitySizes() {
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: nil).accessibilityButton, .vote)
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: nil, isChecking: true).accessibilityButton, .checking)
        XCTAssertEqual(BillVoteBarModel(mode: .updatedOnly, choice: nil, isChecking: true).accessibilityButton, .vote, "an updated bill asks again")
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: .nay).accessibilityButton, .voted(.nay))
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: .nay, isChanging: true).accessibilityButton, .voted(.nay))
        XCTAssertEqual(BillVoteBarModel.checkingTitle, "Checking…")
        XCTAssertEqual(BillVoteBarModel.compactTitle, "Vote")
    }

    /// Checking disables the three buttons; an updated bill's stay enabled.
    func testCheckingDisablesTheButtons() {
        XCTAssertTrue(BillVoteBarModel(mode: .full, choice: nil, isChecking: true).isAwaitingVoteCheck)
        XCTAssertFalse(BillVoteBarModel(mode: .updatedOnly, choice: nil, isChecking: true).isAwaitingVoteCheck)
        XCTAssertFalse(BillVoteBarModel(mode: .full, choice: nil).isAwaitingVoteCheck)
        XCTAssertFalse(BillVoteBarModel(mode: .full, choice: .yea, isChecking: true).isAwaitingVoteCheck)
    }

    /// In the "Your vote" dialog the current vote ("Yea (your vote)") writes nothing; a held Abstain on a bill
    /// still on Bills is recorded again.
    func testTheDialogsCurrentVoteWritesNothing() {
        let voted = BillVoteBarModel(mode: .full, choice: .yea)
        XCTAssertEqual(voted.dialogResult(ofTapping: .yea), .collapse)
        XCTAssertEqual(voted.dialogResult(ofTapping: .nay), .vote(.nay))
        XCTAssertEqual(BillVoteBarModel(mode: .full, choice: nil).dialogResult(ofTapping: .abstain), .vote(.abstain))
        let held = BillVoteBarModel(mode: .full, choice: .abstain, recordsHeldAbstain: true)
        XCTAssertEqual(held.dialogResult(ofTapping: .abstain), .vote(.abstain))
    }

    /// Every control is `max(50, line height + 2 × 12)`: 50 pt at the default size, growing with the label
    /// (about 69 pt at AX3, about 85 at AX5 by the spec's table; `UIFontMetrics` ends about 10% under it).
    func testControlHeightsComeFromTheLabel() {
        XCTAssertEqual(BillVoteBarModel.controlHeight(lineHeight: 19), 50)
        XCTAssertEqual(BillVoteBarModel.controlHeight(lineHeight: 40), 64)
        XCTAssertEqual(BillVoteBarModel.controlHeight(for: .large), 50)
        let ax3 = BillVoteBarModel.controlHeight(for: .accessibility3)
        let ax5 = BillVoteBarModel.controlHeight(for: .accessibility5)
        XCTAssertGreaterThan(ax3, 55)
        XCTAssertLessThan(ax3, 75)
        XCTAssertGreaterThan(ax5, ax3)
        XCTAssertLessThan(ax5, 92, "not a 50 pt height scaled to about 160")
    }

    /// Voice Control: the visible word works as well as the spoken label; Change answers to both its words.
    func testVoiceControlInputLabels() {
        XCTAssertEqual(BillVoteBarModel.inputLabels(for: .yea), ["Yea", "Vote Yea"])
        XCTAssertEqual(BillVoteBarModel.inputLabels(for: .nay), ["Nay", "Vote Nay"])
        XCTAssertEqual(BillVoteBarModel.inputLabels(for: .abstain), ["Abstain"])
        XCTAssertEqual(BillVoteBarModel.changeInputLabels, ["Change", "Change your vote"])
        XCTAssertEqual(BillVoteBarModel.currentVoteAccessibilityLabel(.yea), "Vote Yea, your current vote")
        XCTAssertEqual(BillVoteBarModel.refusalAccessibilityLabel("Limit reached."), "Error: Limit reached.")
        XCTAssertEqual(BillVoteBarModel.summaryIdentifier, "bill.vote.summary")
        XCTAssertEqual(BillVoteBarModel.refusalIdentifier, "bill.vote.refusal")
        XCTAssertEqual(BillVoteBarModel.captionIdentifier, "bill.vote.caption")
    }

    /// The panel sits where the tab capsule would: 24 pt above the bottom edge with a home indicator (the
    /// `safeAreaBar` stands on the 34 pt area, so 10 pt into it), 12 pt with a Home button. The bottom safe area
    /// is measured, and with a Home button it can come back a hair off zero either way (seen at AX4 on a
    /// 375 x 667 window): that is still 12 pt, not the home indicator's 24.
    func testThePanelSits24PtAboveTheBottomEdge() {
        XCTAssertEqual(BillDetail.panelBottomPadding(safeAreaBottom: 34), -10)
        XCTAssertEqual(BillDetail.panelBottomPadding(safeAreaBottom: 0), 12)
        for noise in [CGFloat(1e-13), -1e-13, 0.000_1, 0.333_333] {
            XCTAssertEqual(TabCapsuleLayout.bottomMargin(safeAreaBottom: noise), TabCapsuleLayout.homeButtonMargin, "\(noise)")
            XCTAssertEqual(BillDetail.panelBottomPadding(safeAreaBottom: noise), 12, accuracy: 0.5, "\(noise)")
        }
        XCTAssertEqual(TabCapsuleLayout.bottomMargin(safeAreaBottom: 20), TabCapsuleLayout.homeIndicatorMargin, "a landscape home indicator")
        XCTAssertEqual(BillVoteBar.sideMargin, 12)
        XCTAssertEqual(BillVoteBar.panelPadding, 10)
    }

    // MARK: - Vote saved event (spec D 2.5.6)

    func testVoteSavedUserInfoCarriesTheGuidAndTheVote() {
        let info = BillVoteBarModel.voteSavedUserInfo(guid: "BILLS-119hr900", vote: .abstain)
        XCTAssertEqual(info["guid"] as? String, "BILLS-119hr900")
        XCTAssertEqual(info["vote"] as? String, VoteType.abstain.rawValue)
    }
}
