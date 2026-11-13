import Combine
import Foundation
import UIKit
import XCTest
@testable import Billboard

/// Skip on Bills and Clear on Updates (spec D 2.1.1-2.1.3): a skip or Clear never writes a vote or a
/// preference; Undo puts back exactly what it changed (dismissals, read flags, removed alerts); the
/// commit runs the deferred unwatch once, on the timer, a newer action, or the app going to the
/// background.
@MainActor
final class SkipUndoTests: XCTestCase {
    private static let house = "BILLS-119hr900"
    private static let senate = "BILLS-119s456"
    private static let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")

    // MARK: - Harness

    /// A timer the test fires by hand.
    @MainActor
    private final class ManualScheduler: UndoTimerScheduling {
        final class Entry {
            let fire: @MainActor @Sendable () -> Void
            var isCancelled = false
            init(fire: @escaping @MainActor @Sendable () -> Void) { self.fire = fire }
        }

        private(set) var entries: [Entry] = []

        func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> UndoTimerCancellation {
            let entry = Entry(fire: fire)
            entries.append(entry)
            return UndoTimerCancellation { entry.isCancelled = true }
        }

        /// Fires the latest timer, as it would after 4 seconds, unless it was cancelled.
        func fireLatest() {
            guard let entry = entries.last, !entry.isCancelled else { return }
            entry.fire()
        }
    }

    /// A bills store on fake services, its vote store, a read state that is never persisted, an alerts
    /// store with its own cache scope, and an undo center on a manual timer.
    @MainActor
    private final class Harness {
        let votes: FakeBillVotesService
        let preferences: FakePreferencesService
        let readStateStore: InMemoryReadStateStore
        let readState: AppReadState
        let alerts: BillAlertsStore
        let alertsScope: String
        let billsScope: String
        let scheduler: ManualScheduler
        let notificationCenter: NotificationCenter
        let center: UndoCenter
        private(set) var store: BillsStore!
        private(set) var voteStore: BillVoteStore!

        init(alerts initialAlerts: [BillAlert] = []) {
            let readStateStore = InMemoryReadStateStore()
            let alertsScope = "skip-undo-alerts-\(UUID().uuidString)"
            let alertsStore = BillAlertsStore(scope: alertsScope, alerts: [])
            let scheduler = ManualScheduler()
            let notificationCenter = NotificationCenter()
            // `ingest` sorts newest first and writes the cache, as alerts arrive in the app.
            initialAlerts.forEach(alertsStore.ingest)

            self.votes = FakeBillVotesService()
            self.preferences = FakePreferencesService()
            self.readStateStore = readStateStore
            self.readState = AppReadState(scope: .user("skip-undo-tests"), store: readStateStore)
            self.alerts = alertsStore
            self.alertsScope = alertsScope
            self.billsScope = "skip-undo-tests-\(UUID().uuidString)"
            self.scheduler = scheduler
            self.notificationCenter = notificationCenter
            self.center = UndoCenter(
                scheduler: scheduler,
                notificationCenter: notificationCenter,
                isVoiceOverRunning: { false },
                isSwitchControlRunning: { false },
                announce: { _ in }
            )
        }

        func load(bills: [Bill], groups: [BillCompanionGroup] = []) async {
            let service = FakeBillsService()
            service.cachedGroups = groups
            service.cachedManifest = []
            let store = BillsStore(bills: bills, cacheScope: billsScope, service: service, preferencesService: preferences)
            let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
            store.connect(voteStore: voteStore)
            await store.restoreCachedStateIfNeeded()
            self.store = store
            self.voteStore = voteStore
        }

        @discardableResult
        func skipWithUndo(_ targets: [SkipTarget], message: SkipUndoMessage = .skipped(numbers: ["H.R. 1"])) -> SkipReceipt {
            store.skipWithUndo(targets, message: message, readState: readState, alertsStore: alerts, undoCenter: center)
        }

        var persistedReadState: ReadStateSnapshot {
            readStateStore.load(scope: .user("skip-undo-tests"))
        }

        /// The alerts as the store cached them (decoded: the encoder's key order is not stable).
        var cachedAlerts: [BillAlert]? {
            guard let data = UserDefaults.standard.data(forKey: ScopedStorageKey.make(base: "BillAlertsStore.alerts.data", scope: alertsScope)) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode([BillAlert].self, from: data)
        }

        /// Lets any task a write would have started run, so a write that should not happen would show.
        func drain() async {
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func makeHarness(bills: [Bill], groups: [BillCompanionGroup] = [], alerts: [BillAlert] = []) async -> Harness {
        let harness = Harness(alerts: alerts)
        await harness.load(bills: bills, groups: groups)
        let billsScope = harness.billsScope
        let alertsScope = harness.alertsScope
        addTeardownBlock {
            BillsStore.clearCachedBills(scope: billsScope)
            BillAlertsStore.clearCache(scope: alertsScope)
        }
        // The bills store holds the vote store weakly; keep everything for the whole test.
        addTeardownBlock { withExtendedLifetime(harness) {} }
        return harness
    }

    private func bill(
        _ guid: String,
        status: BillStatus = .new,
        watched: Bool = false,
        billType: String? = nil,
        number: String? = nil
    ) -> Bill {
        var bill = Bill(
            id: UUID.deterministic(from: guid),
            title: "A bill",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            billStatus: status,
            guid: guid,
            congress: "119",
            billType: billType,
            billID: number,
            userVoted: false,
            isPriority: true
        )
        bill.userWatched = watched
        return bill
    }

    private func alert(_ title: String, billID: UUID? = nil, minutesAgo: Double) -> BillAlert {
        BillAlert(
            id: UUID(),
            sponsorMemberID: nil,
            billID: billID,
            title: title,
            category: "Other",
            summary: "",
            soWhat: "",
            lifeAreas: [],
            subCategory: nil,
            alertText: nil,
            actionDate: nil,
            actionCode: nil,
            actionType: nil,
            date: Date().addingTimeInterval(-minutesAgo * 60)
        )
    }

    // MARK: - No vote, no preference (2.1.1 proof)

    func testASkipOfEveryCardTypeWritesNoVoteAndNoPreference() async {
        let newBill = bill("BILLS-119hr1")
        let updated = bill("BILLS-119hr2", status: .updated, watched: true)
        let passed = bill("BILLS-119hr3", status: .passed, watched: true)
        let action = alert("Referred to committee", billID: newBill.id, minutesAgo: 5)
        let harness = await makeHarness(
            bills: [newBill, updated, passed, bill(Self.house), bill(Self.senate)],
            groups: [Self.group],
            alerts: [action]
        )

        let items = [
            BillBoardItem(id: newBill.id, bill: newBill, date: Date(), type: .bill),
            BillBoardItem(id: updated.id, bill: updated, date: Date(), type: .updated),
            BillBoardItem(id: passed.id, bill: passed, date: Date(), type: .passed),
            BillBoardItem(id: newBill.id, bill: newBill, date: Date(), type: .alert(action)),
            BillBoardItem(id: Self.group.primaryBillID, bill: bill(Self.house), date: Date(), type: .bill, companionGroup: Self.group)
        ]
        for item in items {
            harness.skipWithUndo([item.skipTarget], message: item.skipUndoMessage)
        }
        // Each skip committed the one before; commit the last one too.
        harness.center.commitPending()
        await harness.drain()

        XCTAssertEqual(harness.votes.setFeedbackCalls, [], "no Abstain or any vote from a skip")
        XCTAssertEqual(harness.preferences.putCalls.count, 0, "no PUT /preferences (bill or watch)")
        XCTAssertEqual(harness.preferences.deleteCalls.count, 0)
        XCTAssertEqual(harness.voteStore.vote(for: Self.house), .unknown)
        XCTAssertTrue(harness.readState.dismissedBillIDs.isSuperset(of: [
            newBill.id, updated.id, passed.id, UUID.deterministic(from: Self.house), UUID.deterministic(from: Self.senate)
        ]))
        XCTAssertTrue(harness.readState.readBillAlertIDs.contains(action.id))
        XCTAssertEqual(harness.alerts.alerts, [])
        XCTAssertTrue(harness.store.isWatched(billID: updated.id), "skipping an updated bill keeps its watch")
        XCTAssertFalse(harness.store.isWatched(billID: passed.id), "a passed bill is unwatched once the skip commits")
    }

    func testClearOnUpdatesWritesNoVoteAndNoPreference() async {
        let passed = bill("BILLS-119hr3", status: .passed)
        let failed = bill("BILLS-119s9", status: .failed)
        let harness = await makeHarness(bills: [passed, failed, bill(Self.house), bill(Self.senate, status: .passed)], groups: [Self.group])

        harness.skipWithUndo([.closedBill(passed.id)], message: .cleared(numbers: ["H.R. 3"]))
        harness.skipWithUndo([.closedBill(failed.id), .closedBill(UUID.deterministic(from: Self.senate))], message: .clearedBills(count: 2))
        harness.center.commitPending()
        await harness.drain()

        XCTAssertEqual(harness.votes.setFeedbackCalls, [])
        XCTAssertEqual(harness.preferences.putCalls.count, 0)
        XCTAssertEqual(harness.voteStore.vote(for: Self.house), .unknown, "no Abstain on the group's vote target")
    }

    // MARK: - Undo restores exactly (2.1.2 proof)

    func testUndoRestoresTheReadStateAndTheAlertsStoreExactly() async throws {
        let newBill = bill("BILLS-119hr1")
        let older = alert("Older action", minutesAgo: 30)
        let target = alert("Passed the House", billID: newBill.id, minutesAgo: 10)
        let newest = alert("Newest action", minutesAgo: 1)
        let harness = await makeHarness(
            bills: [newBill, bill(Self.house), bill(Self.senate)],
            groups: [Self.group],
            alerts: [older, target, newest]
        )
        // Something already read and dismissed before, which Undo must leave alone.
        harness.readState.markBillAlertRead(older.id)
        harness.readState.dismissAllBills([UUID.deterministic(from: "BILLS-119hr77")])

        let readStateBefore = harness.readState.exportSnapshot()
        let persistedBefore = harness.persistedReadState
        let alertsBefore = harness.alerts.alerts
        let cachedAlertsBefore = try XCTUnwrap(harness.cachedAlerts)
        XCTAssertEqual(alertsBefore.map(\.id), [newest.id, target.id, older.id])

        let cases: [(String, SkipTarget)] = [
            ("new bill", .openBill(newBill.id)),
            ("group card", .openBill(Self.group.primaryBillID)),
            ("passed bill", .closedBill(newBill.id)),
            ("action in Congress", .alert(target.id)),
            ("read action", .alert(older.id))
        ]
        for (name, target) in cases {
            harness.skipWithUndo([target])
            XCTAssertFalse(
                harness.readState.exportSnapshot() == readStateBefore && harness.alerts.alerts == alertsBefore,
                "\(name): the skip changed something"
            )

            harness.center.undo()

            XCTAssertEqual(harness.readState.exportSnapshot(), readStateBefore, name)
            XCTAssertEqual(harness.persistedReadState, persistedBefore, "\(name): the saved read state")
            XCTAssertEqual(harness.alerts.alerts, alertsBefore, "\(name): same alerts in the same order")
            XCTAssertEqual(harness.cachedAlerts, cachedAlertsBefore, "\(name): the cached alerts")
        }
        XCTAssertTrue(harness.readState.readBillAlertIDs.contains(older.id), "an alert read before stays read")
        XCTAssertNil(harness.center.toast)
    }

    func testClearOnTheActionsSectionUndoesEveryAlertInOrder() async {
        let a = alert("A", minutesAgo: 3)
        let b = alert("B", minutesAgo: 2)
        let c = alert("C", minutesAgo: 1)
        let harness = await makeHarness(bills: [], alerts: [a, b, c])
        harness.readState.markBillAlertRead(b.id)
        let before = harness.alerts.alerts
        let readBefore = harness.readState.readBillAlertIDs

        // As the Updates screen does: mark the shown actions read and empty the store, as one action.
        let receipt = harness.store.clearAllAlerts(markingRead: [c.id, a.id], readState: harness.readState, alertsStore: harness.alerts)
        harness.store.registerUndo(
            for: receipt,
            message: .clearedActions(count: 2),
            readState: harness.readState,
            alertsStore: harness.alerts,
            undoCenter: harness.center
        )
        XCTAssertEqual(harness.alerts.alerts, [])
        XCTAssertEqual(harness.center.toast?.message, "Cleared 2 actions")

        harness.center.undo()

        XCTAssertEqual(harness.alerts.alerts, before)
        XCTAssertEqual(harness.readState.readBillAlertIDs, readBefore)
    }

    func testARestoredAlertThatArrivedAgainIsNotDuplicated() async {
        let action = alert("Action", minutesAgo: 1)
        let harness = await makeHarness(bills: [], alerts: [action])

        harness.skipWithUndo([.alert(action.id)])
        harness.alerts.ingest(action)
        harness.center.undo()

        XCTAssertEqual(harness.alerts.alerts.map(\.id), [action.id])
    }

    // MARK: - Commit (2.1.2 proof)

    func testThePassedUnwatchWaitsForTheTimerAndRunsOnce() async {
        let passed = bill("BILLS-119hr3", status: .passed, watched: true)
        let harness = await makeHarness(bills: [passed])

        harness.skipWithUndo([.closedBill(passed.id)])
        XCTAssertTrue(harness.store.isWatched(billID: passed.id), "still watched inside the Undo window")
        XCTAssertNotNil(harness.center.toast)

        harness.scheduler.fireLatest()

        XCTAssertFalse(harness.store.isWatched(billID: passed.id))
        XCTAssertNil(harness.center.toast)
        XCTAssertTrue(harness.readState.dismissedBillIDs.contains(passed.id))

        // Re-watched later (from bill detail, say): nothing commits the old skip again.
        harness.store.vote(billID: passed.id, vote: .yea, watch: true)
        harness.center.commitPending()
        harness.center.undo()
        harness.scheduler.fireLatest()
        XCTAssertTrue(harness.store.isWatched(billID: passed.id), "the skip committed once")
        XCTAssertTrue(harness.readState.dismissedBillIDs.contains(passed.id), "undo after the commit does nothing")
        await settleBillsCache(scope: harness.billsScope)
    }

    func testUndoOfAPassedSkipKeepsTheWatchForGood() async {
        let passed = bill("BILLS-119hr3", status: .passed, watched: true)
        let harness = await makeHarness(bills: [passed])

        harness.skipWithUndo([.closedBill(passed.id)])
        harness.center.undo()
        harness.scheduler.fireLatest()
        harness.center.commitPending()

        XCTAssertTrue(harness.store.isWatched(billID: passed.id))
        XCTAssertFalse(harness.readState.dismissedBillIDs.contains(passed.id))
    }

    func testASecondSkipCommitsTheFirstAndOnlyTheSecondCanBeUndone() async {
        let passed = bill("BILLS-119hr3", status: .passed, watched: true)
        let newBill = bill("BILLS-119hr1")
        let harness = await makeHarness(bills: [passed, newBill])

        harness.skipWithUndo([.closedBill(passed.id)], message: .skipped(numbers: ["H.R. 3"]))
        harness.skipWithUndo([.openBill(newBill.id)], message: .skipped(numbers: ["H.R. 1"]))

        XCTAssertFalse(harness.store.isWatched(billID: passed.id), "the first skip committed")
        XCTAssertEqual(harness.center.toast?.message, "Skipped H.R. 1")

        harness.center.undo()

        XCTAssertFalse(harness.readState.dismissedBillIDs.contains(newBill.id))
        XCTAssertTrue(harness.readState.dismissedBillIDs.contains(passed.id), "the first skip stays")
        await settleBillsCache(scope: harness.billsScope)
    }

    func testTheAppGoingToTheBackgroundCommits() async {
        let passed = bill("BILLS-119hr3", status: .passed, watched: true)
        let harness = await makeHarness(bills: [passed])

        harness.skipWithUndo([.closedBill(passed.id)])
        harness.notificationCenter.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertFalse(harness.store.isWatched(billID: passed.id))
        XCTAssertNil(harness.center.toast)
        harness.center.undo()
        XCTAssertTrue(harness.readState.dismissedBillIDs.contains(passed.id), "nothing left to undo")
        await settleBillsCache(scope: harness.billsScope)
    }

    func testClearAllIsOneUndoableAction() async {
        let first = bill("BILLS-119hr3", status: .passed, watched: true)
        let second = bill("BILLS-119hr4", status: .passed, watched: true)
        let harness = await makeHarness(bills: [first, second])

        let receipt = harness.skipWithUndo([.closedBill(first.id), .closedBill(second.id)], message: .clearedBills(count: 2))

        XCTAssertEqual(receipt.dismissedBillIDs, [first.id, second.id])
        XCTAssertEqual(receipt.pendingUnwatchBillIDs, [first.id, second.id])
        XCTAssertEqual(harness.center.toast?.message, "Cleared 2 bills")
        XCTAssertEqual(harness.scheduler.entries.count, 1, "one undo record for the batch")

        harness.center.undo()

        XCTAssertTrue(harness.readState.dismissedBillIDs.isDisjoint(with: [first.id, second.id]))
        XCTAssertTrue(harness.store.isWatched(billID: first.id))
        XCTAssertTrue(harness.store.isWatched(billID: second.id))
    }

    // MARK: - Receipts and the read state

    func testASkipRecordsOnlyWhatItChanged() async {
        let newBill = bill("BILLS-119hr1")
        let harness = await makeHarness(bills: [newBill, bill(Self.house), bill(Self.senate)], groups: [Self.group])
        harness.readState.dismissAllBills([UUID.deterministic(from: Self.senate)])

        let receipt = harness.store.skip(.openBill(Self.group.primaryBillID), readState: harness.readState)

        XCTAssertEqual(receipt.dismissedBillIDs, [UUID.deterministic(from: Self.house)], "the Senate bill was already dismissed")
        harness.store.restoreSkip(receipt, readState: harness.readState)
        XCTAssertEqual(harness.readState.dismissedBillIDs, [UUID.deterministic(from: Self.senate)])
    }

    func testReadStateBatchCallsPublishOnceAndReportNewIDs() {
        let readState = AppReadState(scope: .user("skip-undo-tests"), store: InMemoryReadStateStore())
        let a = UUID(), b = UUID()
        var publishes = 0
        let subscription = readState.$dismissedBillIDs.dropFirst().sink { _ in publishes += 1 }

        XCTAssertEqual(readState.dismissAllBills([a, b, a]), [a, b])
        XCTAssertEqual(readState.dismissAllBills([a]), [])
        readState.undismissBills([a, b, UUID()])
        readState.undismissBills([a])

        XCTAssertEqual(publishes, 2, "one dismissal and one undismissal publish; the no-ops do not")
        XCTAssertTrue(readState.markBillAlertRead(a))
        XCTAssertFalse(readState.markBillAlertRead(a))
        readState.markBillAlertsUnread([a, b])
        XCTAssertEqual(readState.readBillAlertIDs, [])
        subscription.cancel()
    }

    // MARK: - Items and toast copy

    func testEachCardTypeSkipsTheRightThing() {
        let newBill = bill("BILLS-119hr1")
        let action = alert("Action", billID: newBill.id, minutesAgo: 1)

        XCTAssertEqual(BillBoardItem(id: newBill.id, bill: newBill, date: Date(), type: .bill).skipTarget, .openBill(newBill.id))
        XCTAssertEqual(BillBoardItem(id: newBill.id, bill: newBill, date: Date(), type: .updated).skipTarget, .openBill(newBill.id))
        XCTAssertEqual(BillBoardItem(id: newBill.id, bill: newBill, date: Date(), type: .passed).skipTarget, .closedBill(newBill.id))
        XCTAssertEqual(BillBoardItem(id: newBill.id, bill: newBill, date: Date(), type: .alert(action)).skipTarget, .alert(action.id))
    }

    func testToastCopy() {
        let numbered = bill("BILLS-119hr1234", billType: "hr", number: "1234")
        let item = BillBoardItem(id: numbered.id, bill: numbered, date: Date(), type: .bill)
        XCTAssertEqual(item.skipUndoMessage.text, "Skipped H.R. 1234")
        XCTAssertEqual(item.skipUndoMessage.accessibilityText, "Skipped H.R. 1234. Undo available.")

        let card = BillBoardItem(id: Self.group.primaryBillID, bill: bill(Self.house), date: Date(), type: .bill, companionGroup: Self.group)
        XCTAssertEqual(card.skipUndoMessage.text, "Skipped H.R. 900 · S. 456")
        XCTAssertEqual(card.skipUndoMessage.accessibilityText, "Skipped H.R. 900 and S. 456. Undo available.")

        XCTAssertEqual(SkipUndoMessage.skipped(numbers: []).text, "Skipped a bill")
        XCTAssertEqual(SkipUndoMessage.cleared(numbers: ["S. 456"]).text, "Cleared S. 456")
        XCTAssertEqual(SkipUndoMessage.clearedBills(count: 3).text, "Cleared 3 bills")
        XCTAssertEqual(SkipUndoMessage.clearedBills(count: 1).text, "Cleared 1 bill")
        XCTAssertEqual(SkipUndoMessage.clearedActions(count: 1).text, "Cleared 1 action")
        XCTAssertEqual(SkipUndoMessage.clearedActions(count: 4).accessibilityText, "Cleared 4 actions. Undo available.")
        XCTAssertEqual(
            SkipUndoMessage.billNumbers(for: bill(Self.senate), companions: CompanionGroupIndex(groups: [Self.group])),
            ["H.R. 900", "S. 456"]
        )
        XCTAssertEqual(BillBoardQueueList.swipeActionName, "Skip")
    }

    func testTheToastShowsTheMessageAndVoiceOverHearsIt() async {
        let harness = await makeHarness(bills: [bill("BILLS-119hr1")])
        var announced: [String] = []
        let center = UndoCenter(
            scheduler: harness.scheduler,
            notificationCenter: harness.notificationCenter,
            isVoiceOverRunning: { true },
            announce: { announced.append($0) }
        )

        harness.store.skipWithUndo(
            [.openBill(UUID.deterministic(from: "BILLS-119hr1"))],
            message: .skipped(numbers: ["H.R. 1"]),
            readState: harness.readState,
            undoCenter: center
        )

        XCTAssertEqual(center.toast?.message, "Skipped H.R. 1")
        XCTAssertEqual(center.toast?.duration, UndoCenter.assistiveTechnologyDuration)
        XCTAssertEqual(announced, ["Skipped H.R. 1. Undo available."])
    }

    // MARK: - Skipped tile and Put back (2.1.2)

    func testSkippedListsHiddenCardsAndPutBackReturnsThem() async throws {
        let profile = UserProfile.placeholder()
        let one = bill("BILLS-119hr1")
        let two = bill("BILLS-119hr2")
        let closed = bill("BILLS-119hr3", status: .passed)
        let house = bill(Self.house)
        let senate = bill(Self.senate)
        let harness = await makeHarness(bills: [one, two, closed, house, senate], groups: [Self.group])
        let bills = [one, two, closed, house, senate]
        func input() -> BillBoardDerivedCollections.Input {
            BillBoardDerivedCollections.Input(
                bills: bills,
                dismissedBillIDs: harness.readState.dismissedBillIDs,
                userProfile: profile,
                historyWindow: .oneWeek,
                voteStatesByBillID: [:],
                companions: CompanionGroupIndex(groups: [Self.group])
            )
        }
        XCTAssertEqual(BillBoardDerivedCollections.skippedItems(from: input()).count, 0)

        harness.store.skip(.openBill(one.id), readState: harness.readState)
        harness.store.skip(.openBill(Self.group.primaryBillID), readState: harness.readState)
        harness.store.skip(.closedBill(closed.id), readState: harness.readState)

        let skipped = BillBoardDerivedCollections.skippedItems(from: input())
        XCTAssertEqual(Set(skipped.compactMap(\.bill.guid)), ["BILLS-119hr1", Self.house], "a cleared Passed bill is not a Bills card")
        XCTAssertEqual(skipped.first { $0.bill.guid == Self.house }?.companionGroup, Self.group)
        XCTAssertFalse(BillBoardDerivedCollections.derive(from: input()).liveBoardItems.contains { $0.bill.guid == Self.house })

        let groupCard = try XCTUnwrap(skipped.first { $0.bill.guid == Self.house })
        BillsSearchView.putBack(groupCard, billsStore: harness.store, readState: harness.readState)

        XCTAssertFalse(harness.readState.dismissedBillIDs.contains(UUID.deterministic(from: Self.senate)), "every member is put back")
        XCTAssertEqual(BillBoardDerivedCollections.skippedItems(from: input()).compactMap(\.bill.guid), ["BILLS-119hr1"])
        XCTAssertTrue(BillBoardDerivedCollections.derive(from: input()).liveBoardItems.contains { $0.bill.guid == Self.house })
        XCTAssertEqual(harness.votes.setFeedbackCalls, [])
    }

    func testAVotedBillIsNotListedAsSkipped() {
        let one = bill("BILLS-119hr1")
        let skipped = BillBoardDerivedCollections.skippedItems(from: BillBoardDerivedCollections.Input(
            bills: [one],
            dismissedBillIDs: [one.id],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteStatesByBillID: ["BILLS-119hr1": .voted(.yea)]
        ))
        XCTAssertEqual(skipped.count, 0, "putting it back would not show it")
    }

    /// An Abstain from bill detail also takes the bill off Bills (`BillsStore.dismiss`), but it is a
    /// vote: Skipped ("Skipping is never a vote") does not list it, so Put back cannot return it as
    /// a bill to vote on. A skipped bill beside it still is listed. The same for a companion group.
    func testAnAbstainFromBillDetailIsNotListedAsSkipped() async {
        let profile = UserProfile.placeholder()
        let abstained = bill("BILLS-119hr1")
        let skipped = bill("BILLS-119hr2")
        let house = bill(Self.house)
        let senate = bill(Self.senate)
        let bills = [abstained, skipped, house, senate]
        let harness = await makeHarness(bills: bills, groups: [Self.group])

        // What the bar's Abstain does: the vote, then the dismissal of every member.
        for billID in [abstained.id, senate.id] {
            _ = await harness.store.vote(billID: billID, vote: .abstain, watch: nil)?.value
            harness.store.dismiss(billID: billID, readState: harness.readState)
        }
        harness.store.skip(.openBill(skipped.id), readState: harness.readState)
        XCTAssertEqual(harness.votes.setFeedbackCalls.map(\.feedback), [.abstain, .abstain], "precondition: both Abstains were sent")

        func input(abstainedGuids: Set<String>) -> BillBoardDerivedCollections.Input {
            BillBoardDerivedCollections.Input(
                bills: bills,
                dismissedBillIDs: harness.readState.dismissedBillIDs,
                userProfile: profile,
                historyWindow: .oneWeek,
                voteStatesByBillID: harness.voteStore.statesByBillId,
                companions: CompanionGroupIndex(groups: [Self.group]),
                abstainedGuids: abstainedGuids
            )
        }
        XCTAssertEqual(
            Set(BillBoardDerivedCollections.skippedItems(from: input(abstainedGuids: [])).compactMap(\.bill.guid)),
            ["BILLS-119hr1", "BILLS-119hr2", Self.house],
            "precondition: by dismissals alone the abstained bills look skipped"
        )

        let abstainedGuids = harness.store.abstainedGuids(in: bills)
        XCTAssertTrue(abstainedGuids.isSuperset(of: ["BILLS-119hr1", Self.house, Self.senate]))
        XCTAssertFalse(abstainedGuids.contains("BILLS-119hr2"))
        XCTAssertEqual(BillBoardDerivedCollections.skippedItems(from: input(abstainedGuids: abstainedGuids)).compactMap(\.bill.guid), ["BILLS-119hr2"])
    }
}
