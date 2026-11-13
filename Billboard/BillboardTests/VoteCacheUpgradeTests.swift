import XCTest
@testable import Billboard

/// INT-11: an install that updates from 1.1 to 1.2 keeps no Abstain row from 1.1. 1.1 stored every Updates
/// Dismiss and Dismiss All as an Abstain in the vote cache (`BillVoteCache.v1`, 90 days), and 1.2 shows a
/// held Abstain as "You abstained" with Results open. So the first time 1.2 opens that cache it drops every
/// Abstain row, and the vote store reads those bills from the server (which leaves the dismissals out and
/// returns the user's own Abstains) without waiting for the bill to be opened.
@MainActor
final class VoteCacheUpgradeTests: XCTestCase {
    private static let dismissed = "BILLS-119hr1"
    private static let yea = "BILLS-119hr2"
    private static let nay = "BILLS-119hr3"
    private static let notVoted = "BILLS-119hr4"
    private static let ownAbstain = "BILLS-119hr5"

    private let suiteName = "VoteCacheUpgradeTests.\(UUID().uuidString)"
    private let key = "BillVoteCache.v1.upgrade-tests-\(UUID().uuidString)"

    /// A throwaway suite, so no test touches the host app's `UserDefaults.standard`.
    private lazy var defaults: UserDefaults = {
        let suiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }()

    // MARK: - The cache 1.1 left

    private func openCache(key: String? = nil) -> BillVoteCache {
        BillVoteCache(config: BillVoteCache.Config(persistenceKey: key ?? self.key), defaults: defaults)
    }

    /// The vote cache as 1.1 wrote it: written with the same code (1.2 did not change the format), and
    /// without the mark that only 1.2 sets.
    private func writeCacheOf11(key: String? = nil, now: Date = Date()) {
        let key = key ?? self.key
        let cache = openCache(key: key)
        let fiveDaysAgo = now.addingTimeInterval(-5 * 24 * 60 * 60)
        cache.setVoted(billId: Self.dismissed, vote: .abstain, votedAt: fiveDaysAgo, now: fiveDaysAgo)
        cache.setVoted(billId: Self.ownAbstain, vote: .abstain, votedAt: fiveDaysAgo, now: fiveDaysAgo)
        cache.setVoted(billId: Self.yea, vote: .yea, votedAt: fiveDaysAgo, now: fiveDaysAgo)
        cache.setVoted(billId: Self.nay, vote: .nay, votedAt: fiveDaysAgo, now: fiveDaysAgo)
        cache.setNotVoted(billId: Self.notVoted, now: fiveDaysAgo)
        defaults.removeObject(forKey: BillVoteCache.earlierAbstainsDroppedKey(for: key))
    }

    private func voteStore(_ cache: BillVoteCache, _ service: FakeBillVotesService) -> BillVoteStore {
        BillVoteStore(cache: cache, service: service)
    }

    /// What bill detail's `hasVoted` reads, for a bill in no group: the bar's choice and the rows the
    /// stores hold (`BillDetail.hasVoted`).
    private func unlocks(_ store: BillVoteStore, _ guid: String) -> Bool {
        let counted = BillVoteBarModel.storedCountedVote(voteStoreState: store.vote(for: guid), billVote: nil)
        let held = store.heldVote(for: guid)
        let choice = BillVoteBarModel.shownChoice(
            pending: nil,
            counted: counted.map { VoteChoice($0.voteType) },
            held: held,
            mode: .full,
            heldVotedAt: store.heldVoteDate(for: guid),
            billUpdatedAt: nil
        )
        return BillVoteBarModel.unlocksResults(choice: choice, didJustVote: false, holdsRow: held != nil || counted != nil)
    }

    // MARK: - Dropped at the first launch of 1.2

    func testAnUpgradedInstallHoldsNoDismissalAsAnAbstainBeforeAnyBillIsOpened() {
        writeCacheOf11()
        let service = FakeBillVotesService()
        let store = voteStore(openCache(), service)

        XCTAssertNil(store.heldVote(for: Self.dismissed), "the bill's unlock input is empty")
        XCTAssertNil(store.heldVoteDate(for: Self.dismissed))
        XCTAssertEqual(store.vote(for: Self.dismissed), .unknown)
        XCTAssertFalse(unlocks(store, Self.dismissed), "Results stay locked on a bill nobody opened")
        XCTAssertNil(store.heldVote(for: Self.ownAbstain), "an Abstain made in 1.1 waits for the server's answer too")
        XCTAssertTrue(service.batchRequests.isEmpty && service.singleRequests.isEmpty, "nothing is requested until the launch asks")
    }

    func testTheDismissalStaysLockedWhenTheServerLeavesItOut() async {
        writeCacheOf11()
        let service = FakeBillVotesService()
        service.batchResult = .success([:])
        let store = voteStore(openCache(), service)

        await store.recheckEarlierAbstains()

        XCTAssertEqual(service.batchRequests.count, 1, "one request for every dropped Abstain")
        XCTAssertEqual(Set(service.batchRequests.first ?? []), [Self.dismissed, Self.ownAbstain])
        XCTAssertTrue(service.singleRequests.isEmpty)
        XCTAssertNil(store.heldVote(for: Self.dismissed))
        XCTAssertFalse(unlocks(store, Self.dismissed))
        XCTAssertNil(store.lastError, "the check is quiet")
    }

    func testTheServerDecidesWhichDroppedAbstainIsTheUsersOwn() async {
        writeCacheOf11()
        let ownVotedAt = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        let service = FakeBillVotesService()
        service.batchResult = .success([
            Self.dismissed: .notVoted,
            Self.ownAbstain: .voted(.init(vote: .abstain, votedAt: ownVotedAt))
        ])
        let store = voteStore(openCache(), service)

        await store.recheckEarlierAbstains()

        XCTAssertNil(store.heldVote(for: Self.dismissed))
        XCTAssertFalse(unlocks(store, Self.dismissed))
        XCTAssertEqual(store.heldVote(for: Self.ownAbstain), .abstain, "the user's own Abstain comes back")
        XCTAssertEqual(store.heldVoteDate(for: Self.ownAbstain), ownVotedAt, "with the server's time")
        XCTAssertTrue(unlocks(store, Self.ownAbstain))
        XCTAssertEqual(store.vote(for: Self.ownAbstain), .notVoted, "an Abstain is still not a counted vote")
    }

    func testTheBatchDecoderAnswersNotVotedForABillTheServerLeavesOut() throws {
        let states = try BillVotesService.decodeBatchVoteStates(
            from: Data("[]".utf8),
            requestedBillIds: [Self.dismissed, Self.ownAbstain]
        )
        XCTAssertEqual(states, [Self.dismissed: .notVoted, Self.ownAbstain: .notVoted])
    }

    func testYeaNayAndNotVotedRowsAreKeptAndNotRequested() async {
        writeCacheOf11()
        let service = FakeBillVotesService()
        let store = voteStore(openCache(), service)

        XCTAssertEqual(store.heldVote(for: Self.yea), .yea)
        XCTAssertEqual(store.heldVote(for: Self.nay), .nay)
        XCTAssertEqual(store.vote(for: Self.yea), .voted(.yea))
        XCTAssertEqual(store.vote(for: Self.notVoted), .notVoted)
        XCTAssertTrue(unlocks(store, Self.yea))
        XCTAssertTrue(unlocks(store, Self.nay))

        await store.recheckEarlierAbstains()
        XCTAssertFalse(service.batchRequests.joined().contains(Self.yea))
        XCTAssertFalse(service.batchRequests.joined().contains(Self.nay))
        XCTAssertFalse(service.batchRequests.joined().contains(Self.notVoted))
        XCTAssertEqual(store.heldVote(for: Self.yea), .yea)
    }

    func testAGroupWhoseOnlyRowIsADismissalHoldsNoVote() {
        writeCacheOf11()
        let group = BillCompanionGroup(
            primaryGuid: Self.dismissed,
            memberGuids: [Self.dismissed, "BILLS-119s1"],
            relationship: "identical"
        )
        let store = voteStore(openCache(), FakeBillVotesService())

        let resolution = store.companionVote(for: group)
        XCTAssertNil(resolution.countedRow, "the group's vote matrix finds no row")
        XCTAssertNil(resolution.effectiveVote)
        XCTAssertFalse(resolution.isVoted)
    }

    // MARK: - The check fails

    func testACheckThatFailsLeavesNoRowAndTheBillIsReadWhenOpened() async {
        writeCacheOf11()
        let service = FakeBillVotesService()
        service.batchResult = .failure(FakeServiceError())
        let store = voteStore(openCache(), service)

        await store.recheckEarlierAbstains()

        XCTAssertEqual(service.batchRequests.count, 1)
        XCTAssertNil(store.lastError, "a failed check shows no banner")
        XCTAssertNil(store.heldVote(for: Self.dismissed), "no row until the server has answered")
        XCTAssertFalse(unlocks(store, Self.dismissed))

        // Opening the bill reads its row (`.unknown` is fetched), and a dismissal comes back not voted.
        service.singleResult = .success(.notVoted)
        await store.fetchVoteIfNeeded(for: Self.dismissed, reportError: false, revalidateNotVoted: true)
        XCTAssertEqual(service.singleRequests, [Self.dismissed])
        XCTAssertFalse(unlocks(store, Self.dismissed))

        // ...and the user's own Abstain comes back too.
        service.singleResult = .success(.voted(.init(vote: .abstain, votedAt: Date().addingTimeInterval(-86_400))))
        await store.fetchVoteIfNeeded(for: Self.ownAbstain, reportError: false, revalidateNotVoted: true)
        XCTAssertEqual(store.heldVote(for: Self.ownAbstain), .abstain)
    }

    func testTheCheckRunsOncePerLaunch() async {
        writeCacheOf11()
        let service = FakeBillVotesService()
        let store = voteStore(openCache(), service)

        await store.recheckEarlierAbstains()
        await store.recheckEarlierAbstains()

        XCTAssertEqual(service.batchRequests.count, 1)
    }

    // MARK: - Only once

    func testTheNextLaunchKeepsTheAbstainsOf12AndAsksNothing() async {
        writeCacheOf11()
        // The first launch of 1.2 drops 1.1's rows. The user then abstains on a bill, which 1.2 stores.
        let session = voteStore(openCache(), FakeBillVotesService())
        let stored = await session.setVote(billId: Self.dismissed, vote: .abstain)
        XCTAssertTrue(stored)
        XCTAssertEqual(session.heldVote(for: Self.dismissed), .abstain)

        let launch = FakeBillVotesService()
        let cache = openCache()
        let next = voteStore(cache, launch)
        await next.recheckEarlierAbstains()

        XCTAssertEqual(cache.droppedAbstainIds, [])
        XCTAssertEqual(next.heldVote(for: Self.dismissed), .abstain, "a 1.2 Abstain is a real one")
        XCTAssertTrue(launch.batchRequests.isEmpty)
        XCTAssertEqual(next.heldVote(for: Self.yea), .yea)
    }

    func testAFreshInstallDropsNothingAndMarksTheCache() {
        let cache = openCache()
        XCTAssertEqual(cache.droppedAbstainIds, [])
        XCTAssertTrue(defaults.bool(forKey: BillVoteCache.earlierAbstainsDroppedKey(for: key)), "an Abstain written now is not 1.1's")

        cache.setVoted(billId: Self.ownAbstain, vote: .abstain, votedAt: Date(), now: Date())
        let reopened = openCache()
        XCTAssertEqual(reopened.droppedAbstainIds, [])
        XCTAssertEqual(reopened.getState(for: Self.ownAbstain), .voted(.abstain))
    }

    func testAnExpiredAbstainIsNotCheckedAgain() {
        let now = Date()
        let cache = openCache()
        let old = now.addingTimeInterval(-100 * 24 * 60 * 60)
        cache.setVoted(billId: Self.dismissed, vote: .abstain, votedAt: old, now: old)
        cache.setVoted(billId: Self.ownAbstain, vote: .abstain, votedAt: now, now: now)
        defaults.removeObject(forKey: BillVoteCache.earlierAbstainsDroppedKey(for: key))

        XCTAssertEqual(openCache().droppedAbstainIds, [Self.ownAbstain])
    }

    func testTheDroppedRowsAreGoneFromDiskNotOnlyFromMemory() {
        writeCacheOf11()
        XCTAssertEqual(openCache().droppedAbstainIds, [Self.dismissed, Self.ownAbstain].sorted())

        // Even when the mark were lost, the rows are not there to be dropped again or believed.
        defaults.removeObject(forKey: BillVoteCache.earlierAbstainsDroppedKey(for: key))
        let again = openCache()
        XCTAssertEqual(again.droppedAbstainIds, [])
        XCTAssertEqual(again.getState(for: Self.dismissed), .unknown)
        XCTAssertEqual(again.getState(for: Self.yea), .voted(.yea))
    }

    // MARK: - Per account

    func testEachAccountsCacheIsCheckedOnce() {
        let first = BillVoteCache.Config.legacyPersistenceKey + ".account-one"
        let second = BillVoteCache.Config.legacyPersistenceKey + ".account-two"
        writeCacheOf11(key: first)
        writeCacheOf11(key: second)

        XCTAssertEqual(openCache(key: first).droppedAbstainIds.count, 2)
        XCTAssertEqual(openCache(key: first).droppedAbstainIds, [])
        XCTAssertEqual(openCache(key: second).droppedAbstainIds.count, 2, "the other account's cache has its own mark")
    }

    func testScopedCachesUseTheKeysOf11() {
        let scope = "account-\(UUID().uuidString)"
        let cache = BillVoteCache(scope: scope, defaults: defaults)
        cache.setVoted(billId: Self.dismissed, vote: .abstain, votedAt: Date(), now: Date())
        XCTAssertNotNil(defaults.data(forKey: "BillVoteCache.v1.\(scope)"), "1.2 reads the key 1.1 wrote")
        defaults.removeObject(forKey: BillVoteCache.earlierAbstainsDroppedKey(for: "BillVoteCache.v1.\(scope)"))

        XCTAssertEqual(BillVoteCache(scope: scope, defaults: defaults).droppedAbstainIds, [Self.dismissed])
    }

    func testClearingAnAccountsCacheClearsItsMark() {
        let scope = "account-\(UUID().uuidString)"
        let markKey = BillVoteCache.earlierAbstainsDroppedKey(for: "BillVoteCache.v1.\(scope)")
        _ = BillVoteCache(scope: scope, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: markKey))

        BillVoteCache.clearPersistence(scope: scope, defaults: defaults)

        XCTAssertNil(defaults.object(forKey: markKey))
        XCTAssertNil(defaults.data(forKey: "BillVoteCache.v1.\(scope)"))
    }

    func testACacheThatIsNotSavedHasNothingToDrop() {
        let cache = BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil), defaults: defaults)
        cache.setVoted(billId: Self.dismissed, vote: .abstain, votedAt: Date(), now: Date())
        XCTAssertEqual(cache.droppedAbstainIds, [])
        XCTAssertEqual(cache.getState(for: Self.dismissed), .voted(.abstain))
    }
}
