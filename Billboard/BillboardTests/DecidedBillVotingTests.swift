import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Civic Record project decision 1: voting does not end when Congress decides a bill. A Passed, Failed or
/// Became law bill opens with the same vote bar as any bill from everywhere it opens (the Passed list,
/// Search, Updates rows, topic, life-area and member lists, the Weekly Brief, pushes and deep links, and
/// the Bills and Skipped cards and the tour, which never list one), and the decided status stays on the
/// page. INT-11 still holds: Results stay locked until the user votes or abstains, and a vote unlocks them.
@MainActor
final class DecidedBillVotingTests: XCTestCase {
    private static let decidedStatuses: [BillStatus] = [.passed, .failed, .finalized]
    /// The sealed Results' VoiceOver value before a vote (Civic Record spec 3.8.3; INT-11's lock).
    private static let sealedNotVoted = "Vote to see results. They open after you vote Yea, Nay or Abstain, so other people's votes don't sway yours."

    /// A decided bill with its details loaded, so its page shows at once.
    private func decidedBill(_ guid: String, _ status: BillStatus = .passed) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: "A decided bill \(guid)",
            category: "Other",
            soWhat: "It changes how a thing works.",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600)),
            billStatus: status,
            guid: guid,
            userVoted: false,
            isPriority: true,
            isProcessedDetailHydrated: true
        )
    }

    private func briefItem(for bill: Bill, state: WeeklyDigestItem.BillState) -> WeeklyDigestItem {
        WeeklyDigestItem(
            id: "brief-\(bill.guid ?? "")",
            kind: .bill,
            title: bill.title,
            eyebrow: nil,
            summary: "",
            detail: nil,
            reason: nil,
            accent: .movement,
            billState: state,
            billGuid: bill.guid,
            primaryMemberBioguideID: nil
        )
    }

    private static func briefState(for status: BillStatus) -> WeeklyDigestItem.BillState {
        switch status {
        case .new: return .new
        case .updated: return .updated
        case .passed: return .passed
        case .failed: return .failed
        case .finalized: return .finalized
        }
    }

    /// The lists that open a bill with no mode, each through its own `billPage(_:)`, which its rows use.
    private static let listNames = ["Search and its Passed list", "Updates rows", "a topic's list", "a life area's list"]

    /// Each place a bill page opens from, with the page as that place builds it.
    private func entryPoints(for bill: Bill, in store: BillsStore) -> [(name: String, detail: BillDetail)] {
        let guid = bill.guid ?? ""
        let card = BillBoardDerivedCollections.boardItems(cards: [bill], bills: [bill], companions: .empty)[0]
        let brief = briefItem(for: bill, state: Self.briefState(for: bill.billStatus))
        return [
            // Search results and its Watching, Voted and Passed lists (BillCollectionQuickScreen).
            ("Search and its Passed list", BillsSearchView.billPage(bill.id)),
            // Updates' Recent actions, Passed bills and Failed bills rows.
            ("Updates rows", NotificationsView.billPage(bill.id)),
            ("a topic's list", CongressCategoryDetailView.billPage(bill.id)),
            ("a life area's list", CongressLifeAreaDetailView.billPage(bill.id)),
            // WeeklyDigestBillDestinationView.
            ("the Weekly Brief", BillDetail(billID: bill.id, mode: brief.billDetailMode, linkGUID: brief.billGuid)),
            // PushDeepLinkRouter and app links push `.billDetail` on the Bills tab.
            ("a push, deep link or share link", TabsBar.AppRoute.billDetail(store.deepLinkTarget(forGUID: guid)).billDetail(in: store)),
            // BillBoardTab and SkippedBillsScreen open a card in its item's mode.
            ("a Bills or Skipped card", BillDetail(billID: bill.id, mode: BillDetail.Mode(opening: card.type), initialBill: bill)),
            // The tour's "Open this bill".
            ("the tour", TabsBar.AppRoute.queueBill(billID: bill.id, mode: BillDetail.Mode(opening: card.type)).billDetail(in: store))
        ]
    }

    private func stores(
        _ bills: [Bill],
        votes: (any BillVotesServicing)? = nil
    ) -> (billsStore: BillsStore, voteStore: BillVoteStore) {
        let votes = votes ?? FakeBillVotesService()
        let scope = "decided-bill-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedManifest = []
        let billsStore = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        billsStore.connect(voteStore: voteStore)
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        return (billsStore, voteStore)
    }

    /// `detail` as the app shows it: in a navigation stack with the stores it reads.
    private func page(_ detail: BillDetail, billsStore: BillsStore, voteStore: BillVoteStore) -> some View {
        NavigationStack { detail }
            .environmentObject(billsStore)
            .environmentObject(voteStore)
            .environmentObject(AppReadState(scope: .user("decided-bill-tests"), store: InMemoryReadStateStore()))
            .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
            .environmentObject(CongressMembersManifestStore(service: FakeCongressService()))
    }

    // MARK: - Every entry point

    func testEveryEntryPointOpensADecidedBillWithTheVoteBar() {
        for (index, status) in Self.decidedStatuses.enumerated() {
            let bill = decidedBill("BILLS-119hr48\(index)", status)
            let (billsStore, _) = stores([bill])
            for entry in entryPoints(for: bill, in: billsStore) {
                let name = "\(status.displayLabel) from \(entry.name)"
                XCTAssertEqual(entry.detail.mode, .full, name)
                let bar = BillVoteBarModel(mode: entry.detail.mode, choice: nil)
                XCTAssertEqual(bar.layout, .choose(caption: nil, selected: nil), "\(name): Yea, Nay and Abstain")
                for choice in VoteChoice.allCases {
                    XCTAssertEqual(bar.result(ofTapping: choice), .vote(choice), "\(name): \(choice) is recorded")
                }
            }
        }
        // An updated bill still asks again where it is listed as updated, and nowhere else.
        let updated = decidedBill("BILLS-119hr4890", .updated)
        let (billsStore, _) = stores([updated])
        let modes = Dictionary(uniqueKeysWithValues: entryPoints(for: updated, in: billsStore).map { ($0.name, $0.detail.mode) })
        XCTAssertEqual(modes["the Weekly Brief"], .updatedOnly)
        XCTAssertEqual(modes["a Bills or Skipped card"], .updatedOnly)
        XCTAssertEqual(modes["the tour"], .updatedOnly)
        XCTAssertEqual(modes["a push, deep link or share link"], .full)
        for list in Self.listNames {
            XCTAssertEqual(modes[list], .full, list)
        }
    }

    // MARK: - Voting on a passed bill

    /// A Yea on a Passed bill opened from the Passed list, Search, the Weekly Brief and a push is sent for
    /// that bill and opens Results once stored; before it, Results are locked (INT-11).
    func testAVoteOnAPassedBillFromThePassedListSearchTheBriefAndAPushOpensResults() async throws {
        let opened = [
            "Search and its Passed list",
            "Updates rows",
            "the Weekly Brief",
            "a push, deep link or share link"
        ]
        for (index, name) in opened.enumerated() {
            let guid = "BILLS-119hr49\(index)"
            let passed = decidedBill(guid)
            let votes = FakeBillVotesService()
            let (billsStore, voteStore, scope) = await makeCompanionStore(bills: [passed], groups: [], votes: votes)
            let detail = try XCTUnwrap(entryPoints(for: passed, in: billsStore).first { $0.name == name }?.detail, name)
            let mode = detail.mode
            XCTAssertEqual(mode, .full, name)

            await voteStore.fetchVoteIfNeeded(for: guid, reportError: false, revalidateNotVoted: true)
            XCTAssertEqual(access(voteStore, guid: guid), .locked(.notVoted), "\(name): locked before the vote")
            let bar = BillVoteBarModel(mode: mode, choice: nil)
            XCTAssertTrue(bar.showsButtons, name)
            guard case .vote(let choice) = bar.result(ofTapping: .yea) else { return XCTFail(name) }

            let result = await billsStore.submitVote(billID: passed.id, vote: UserVote(choice.voteType), watch: nil)?.value
            XCTAssertEqual(result, .stored, name)
            XCTAssertEqual(votes.setFeedbackCalls, [.init(billId: guid, feedback: .yea, reasons: [])], name)
            XCTAssertEqual(access(voteStore, guid: guid, pending: .yea, didJustVote: true), .open, "\(name): open after the vote")
            XCTAssertEqual(access(voteStore, guid: guid), .open, "\(name): open when the page is opened again")
            XCTAssertEqual(BillVoteBarModel(mode: mode, choice: .yea).collapsedTitle, "You voted Yea", name)
            XCTAssertEqual(billsStore.bill(for: passed.id)?.billStatus, .passed, "\(name): still decided")
            await settleBillsCache(scope: scope)
        }
    }

    /// What bill detail's Results show for a bill in no group (`resultsAccess`).
    private func access(_ store: BillVoteStore, guid: String, pending: VoteChoice? = nil, didJustVote: Bool = false) -> BillResultsAccess {
        let counted = BillVoteBarModel.storedCountedVote(voteStoreState: store.vote(for: guid), billVote: nil)
        let held = store.heldVote(for: guid)
        let choice = BillVoteBarModel.shownChoice(pending: pending, counted: counted.map { VoteChoice($0.voteType) }, held: held)
        return BillResultsAccess.make(
            unlocked: BillVoteBarModel.unlocksResults(choice: choice, didJustVote: didJustVote, holdsRow: held != nil || counted != nil),
            awaitingSave: false,
            isChecking: store.vote(for: guid) == .unknown,
            canRetry: true
        )
    }

    // MARK: - The page

    /// The decided bill's page, from every entry point: the vote bar's three buttons, the decided status,
    /// Results locked with "Vote to see results", and no "No vote needed". Light and dark snapshots of the
    /// Passed list's page are attached for review.
    func testADecidedBillPageShowsTheVoteBar() throws {
        for (index, status) in Self.decidedStatuses.enumerated() {
            let guid = "BILLS-119hr50\(index)"
            let bill = decidedBill(guid, status)
            let (billsStore, voteStore) = stores([bill])
            let entries = status == .passed ? entryPoints(for: bill, in: billsStore) : Array(entryPoints(for: bill, in: billsStore).prefix(1))
            for entry in entries {
                let name = "\(status.displayLabel) from \(entry.name)"
                let text = AccessibilityTreeText.text(of: page(entry.detail, billsStore: billsStore, voteStore: voteStore), settle: 0.4)
                for shown in ["Vote", "Vote Yea", "Vote Nay", "Abstain", status.displayLabel, "You haven't voted on this bill.", Self.sealedNotVoted] {
                    XCTAssertTrue(text.contains(shown), "\(name): \(shown) in: \(text)")
                }
                for gone in ["No vote needed", "Results show after you vote on this bill.", "Voting closed", "Not voted yet"] {
                    XCTAssertFalse(text.contains(gone), "\(name): \(gone) in: \(text)")
                }
            }
            if status == .passed {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let image = try snapshot(page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), style: style)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "decided-bill-page-\(style == .dark ? "dark" : "light")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    XCTAssertGreaterThan(try SnapshotContent.share(of: image), SnapshotContent.minimumShare)
                }
            }
        }
    }

    /// Until the vote row is read (cold start, new device), the page offers the vote bar and Results say
    /// "Checking your vote…" (`.locked(.checking)`); once the server answers not voted, "Vote to see results".
    func testTheDecidedPageSaysCheckingUntilTheVoteIsRead() {
        let guid = "BILLS-119hr5100"
        let bill = decidedBill(guid, .failed)
        let gate = Gate()
        let service = GatedFeedbackService(gate: gate)
        let (billsStore, voteStore) = stores([bill], votes: service)

        let host = AccessibilityTreeText.Host(page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), settle: 0.4)
        let checking = host.text()
        let sealedResults = host.label(ofIdentifier: SealedTally.resultsIdentifier)
        host.close()
        XCTAssertEqual(voteStore.vote(for: guid), .unknown, "precondition: the read is held")
        XCTAssertEqual(sealedResults, "Checking your vote…", "Results sealed with the spinner's words: \(checking)")
        for shown in ["Vote Yea", "Failed"] {
            XCTAssertTrue(checking.contains(shown), "\(shown) in: \(checking)")
        }
        XCTAssertFalse(checking.contains("Vote to see results"), checking)

        gate.open()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let read = AccessibilityTreeText.text(of: page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), settle: 0.4)
        XCTAssertTrue(read.contains(Self.sealedNotVoted), read)
        XCTAssertFalse(read.contains("Checking your vote…"), read)
    }

    // MARK: - Voting on the page

    /// The real page records a vote on a decided bill: a tap on Vote Yea on a Passed, Failed or Became law
    /// page sends that Yea for the bill and opens Results in place of the lock card (INT-11 opens on a vote).
    /// A guard in the page's vote path that drew the buttons but dropped the tap fails here.
    func testATapOnYeaOnADecidedPageRecordsTheVoteAndOpensResults() {
        // Results are asked for once the vote is stored: answered offline, with no network.
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        for (index, status) in Self.decidedStatuses.enumerated() {
            let guid = "BILLS-119hr53\(index)"
            let bill = decidedBill(guid, status)
            let votes = FakeBillVotesService()
            let (billsStore, voteStore) = stores([bill], votes: votes)
            let name = status.displayLabel
            APIClient.$current.withValue(offline) {
                let host = AccessibilityTreeText.Host(page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), settle: 0.4)
                defer { host.close() }
                let before = host.text()
                XCTAssertTrue(before.contains(Self.sealedNotVoted), "\(name): \(before)")

                XCTAssertTrue(host.activate("Vote Yea", settle: 0.6), "\(name): Vote Yea in: \(before)")
                XCTAssertEqual(votes.setFeedbackCalls, [.init(billId: guid, feedback: .yea, reasons: [])], name)
                XCTAssertEqual(voteStore.vote(for: guid), .voted(.yea), name)
                let after = host.text()
                XCTAssertFalse(after.contains(Self.sealedNotVoted), "\(name): \(after)")
                XCTAssertNil(host.label(ofIdentifier: SealedTally.resultsIdentifier), "\(name): Results opened: \(after)")
                XCTAssertTrue(after.contains("You voted Yea"), "\(name): \(after)")
                XCTAssertTrue(after.contains(name), "\(name): still decided: \(after)")
            }
        }
    }

    // MARK: - A vote read that fails

    /// A failed vote read (offline, a server error) ends "Checking your vote…" on the bar, in Your vote and on
    /// the Results lock card: the page says it couldn't check the vote, keeps Results locked and the vote
    /// buttons, and Try again reads the vote again.
    func testAFailedVoteReadSaysSoAndTryAgainReadsTheVoteAgain() {
        let guid = "BILLS-119hr5200"
        let bill = decidedBill(guid, .passed)
        let votes = FakeBillVotesService()
        votes.singleResult = .failure(URLError(.notConnectedToInternet))
        let (billsStore, voteStore) = stores([bill], votes: votes)
        let host = AccessibilityTreeText.Host(page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), settle: 0.4)
        defer { host.close() }

        let failed = host.text()
        XCTAssertEqual(votes.singleRequests, [guid], "the page read the vote")
        XCTAssertEqual(voteStore.vote(for: guid), .unknown, "precondition: the read failed")
        XCTAssertEqual(host.label(ofIdentifier: SealedTally.resultsIdentifier), VoteResultsFormatting.sealedLabel, failed)
        XCTAssertEqual(host.value(ofIdentifier: SealedTally.resultsIdentifier), "Couldn't check your vote on this bill.", failed)
        for shown in ["Try again", "Vote Yea", "Vote Nay", "Abstain"] {
            XCTAssertTrue(failed.contains(shown), "\(shown) in: \(failed)")
        }
        XCTAssertFalse(failed.contains("Checking your vote"), failed)
        XCTAssertFalse(failed.contains("Vote to see results"), "the vote is not known: \(failed)")

        votes.singleResult = .success(.notVoted)
        XCTAssertTrue(host.activate("Try again", settle: 0.4), "Try again in: \(failed)")
        let read = host.text()
        XCTAssertEqual(votes.singleRequests, [guid, guid], "Try again read the vote again")
        XCTAssertTrue(read.contains(Self.sealedNotVoted), read)
        for gone in ["Couldn't check your vote", "Try again", "Checking your vote"] {
            XCTAssertFalse(read.contains(gone), "\(gone) in: \(read)")
        }
    }

    /// A bill with no guid has no vote row to read: the page never waits on one ("Checking your vote…") and
    /// Results say "Vote to see results".
    func testABillWithNoGuidIsNotLeftChecking() {
        var bill = decidedBill("BILLS-119hr5201", .failed)
        bill.guid = nil
        let votes = FakeBillVotesService()
        let (billsStore, voteStore) = stores([bill], votes: votes)
        let text = AccessibilityTreeText.text(of: page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), settle: 0.4)
        XCTAssertTrue(votes.singleRequests.isEmpty && votes.batchRequests.isEmpty, "nothing to read")
        XCTAssertTrue(text.contains(Self.sealedNotVoted), text)
        XCTAssertFalse(text.contains("Checking your vote"), text)
        XCTAssertFalse(text.contains("Couldn't check your vote"), text)
    }

    // MARK: - Updates and the Bills list

    /// Updates' Recent actions lists Congress actions on bills the user has not voted on, and each row opens
    /// the bill with the vote bar, so its hint does not say that no vote is needed.
    func testTheRecentActionsHintDoesNotSayNoVoteIsNeeded() {
        XCTAssertEqual(NotificationsView.recentActionsHint, "Things Congress did on bills you watch.")
        for gone in ["No new vote needed", "No vote needed", "vote needed"] {
            XCTAssertFalse(NotificationsView.recentActionsHint.contains(gone), gone)
        }
        XCTAssertEqual(NotificationsView.billPage(UUID()).mode, .full, "its rows open with the vote bar")
    }

    /// Closing the page a Bills card opened changes nothing for any bill, a decided one included: its page has
    /// the vote bar and Watch, so closing it never skips the bill or undoes a Watch set there (the queue lists
    /// no decided bill today). Only a Congress action's card, which no list builds today, is marked read.
    func testClosingACardsPageNeverSkipsOrUnwatchesTheBill() {
        for (index, status) in (Self.decidedStatuses + [.new, .updated]).enumerated() {
            let bill = decidedBill("BILLS-119hr54\(index)", status)
            let item = BillBoardDerivedCollections.boardItems(cards: [bill], bills: [bill], companions: .empty)[0]
            XCTAssertNil(BillBoardTab.queueDetailReturnAction(for: item), status.displayLabel)
        }
        let bill = decidedBill("BILLS-119hr549")
        let action = BillAlert(
            id: UUID(),
            sponsorMemberID: nil,
            billID: bill.id,
            title: "Action",
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
        let alertItem = BillBoardItem(id: bill.id, bill: bill, date: Date(), type: .alert(action))
        XCTAssertEqual(BillBoardTab.queueDetailReturnAction(for: alertItem), .dismissAlert(action.id))
    }

    // MARK: - Helpers

    /// Hosts `view` in a window of the test app's scene with the given appearance and draws it.
    private func snapshot<Content: View>(_ view: Content, style: UIUserInterfaceStyle) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

/// `GET /feedback` held until `gate` opens, then not voted.
@MainActor
private final class GatedFeedbackService: BillVotesServicing {
    let gate: Gate

    init(gate: Gate) {
        self.gate = gate
    }

    func fetchFeedback(billIds: [String]) async throws -> [String: BillVotesService.RemoteVoteState] {
        await gate.wait()
        return Dictionary(uniqueKeysWithValues: billIds.map { ($0, .notVoted) })
    }

    func fetchFeedback(billId: String) async throws -> BillVotesService.RemoteVoteState {
        await gate.wait()
        return .notVoted
    }

    func setFeedback(billId: String, feedback: VoteType, reasons: [String]) async throws {}
}
