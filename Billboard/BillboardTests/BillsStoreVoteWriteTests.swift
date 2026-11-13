import Combine
import XCTest
@testable import Billboard

/// How often `BillsStore` writes `bills`. Every write fires the `bills` didSet, which rebuilds both
/// lookup dictionaries, so `reconcileVotesFromCache()` writing each of n bills in turn took time
/// quadratic in n on the main thread (about 0.75 s at 1,000 bills and 3.8 s at 2,000). The tests count
/// the writes through the `$bills` publisher, which emits once per write.
final class BillsStoreVoteWriteTests: XCTestCase {
    private func guid(_ number: Int) -> String {
        "BILLS-119hr\(number)ih"
    }

    private func bill(_ number: Int, userVote: UserVote? = nil) -> Bill {
        Bill(
            id: UUID.deterministic(from: "bill-\(number)"),
            title: "Bill \(number)",
            category: "Other",
            soWhat: "",
            billStatus: .new,
            guid: guid(number),
            congress: "119",
            billType: "hr",
            billID: String(number),
            userVoted: userVote?.countsAsVote == true,
            userVote: userVote
        )
    }

    /// A store holding `bills`, connected to a vote store whose cache holds `votes` by bill number.
    @MainActor
    private func makeStore(
        bills: [Bill],
        votes: [Int: VoteType] = [:]
    ) -> (store: BillsStore, voteStore: BillVoteStore, scope: String) {
        let scope = "bills-store-vote-write-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let cache = BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil))
        for (number, vote) in votes {
            cache.setVoted(billId: guid(number), vote: vote, votedAt: Date())
        }
        let voteStore = BillVoteStore(cache: cache, service: FakeBillVotesService())
        let store = BillsStore(
            bills: bills,
            cacheScope: scope,
            service: FakeBillsService(),
            preferencesService: FakePreferencesService()
        )
        store.connect(voteStore: voteStore)
        // The bills store holds the vote store weakly; keep it for the whole test.
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        return (store, voteStore, scope)
    }

    /// How many times `work` writes `store.bills`.
    @MainActor
    private func billsWrites(of store: BillsStore, during work: () -> Void) -> Int {
        var writes = 0
        let subscription = store.$bills.dropFirst().sink { _ in writes += 1 }
        work()
        subscription.cancel()
        return writes
    }

    @MainActor
    private func timestampKey(scope: String) -> String {
        // Mirrors BillsStore's private timestamp key.
        ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope)
    }

    /// True when the store wrote its bills cache (it writes from a detached task, so this waits for the
    /// timestamp), and removes the timestamp so no write lands after the teardown clears the scope.
    @MainActor
    private func billsCacheWasWritten(scope: String, waiting seconds: Double = 1) async -> Bool {
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        let key = timestampKey(scope: scope)
        let deadline = Date().addingTimeInterval(seconds)
        while UserDefaults.standard.object(forKey: key) == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let written = UserDefaults.standard.object(forKey: key) != nil
        UserDefaults.standard.removeObject(forKey: key)
        return written
    }

    // MARK: - reconcileVotesFromCache()

    @MainActor
    func testReconcilingWithNothingToChangeWritesNothingAndCachesNothing() async {
        let bills = (1...300).map { bill($0) }
        let (store, _, scope) = makeStore(bills: bills, votes: [:])

        let writes = billsWrites(of: store) { store.reconcileVotesFromCache() }

        XCTAssertEqual(writes, 0, "no write, so no lookup rebuild and no recalculation")
        XCTAssertEqual(store.bills.map(\.id), bills.map(\.id))
        XCTAssertTrue(store.bills.allSatisfy { !$0.userVoted })
        let written = await billsCacheWasWritten(scope: scope, waiting: 0.3)
        XCTAssertFalse(written, "an unchanged reconcile does not rewrite the bills cache")
    }

    @MainActor
    func testReconcilingWithOnlyVotedAndNonCountingRowsWritesNothing() async {
        // Bill 1 is already voted, bill 2 has an Abstain row (not a counted vote), the rest have no row.
        let bills = [bill(1, userVote: .yea)] + (2...50).map { bill($0) }
        let (store, _, scope) = makeStore(bills: bills, votes: [1: .yea, 2: .abstain])

        let writes = billsWrites(of: store) { store.reconcileVotesFromCache() }

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(store.bill(for: bills[0].id)?.userVote, .yea)
        XCTAssertEqual(store.bill(for: bills[1].id)?.userVoted, false, "an Abstain row is not a vote")
        let written = await billsCacheWasWritten(scope: scope, waiting: 0.3)
        XCTAssertFalse(written)
    }

    @MainActor
    func testReconcilingMarksCachedVotesAndWritesTheBillsOnce() async {
        let bills = (1...300).map { bill($0) }
        let (store, _, scope) = makeStore(bills: bills, votes: [5: .yea, 120: .nay, 300: .yea, 7: .abstain])

        let writes = billsWrites(of: store) { store.reconcileVotesFromCache() }

        XCTAssertEqual(writes, 1, "the changes go into a copy that is assigned once")
        let votedNumbers = Set(store.bills.enumerated().filter { $0.element.userVoted }.map { $0.offset + 1 })
        XCTAssertEqual(votedNumbers, [5, 120, 300], "only counted votes are applied, each to its own bill")
        XCTAssertEqual(store.bills.map(\.id), bills.map(\.id), "order and identity are kept")
        XCTAssertEqual(store.bill(for: bills[6].id)?.userVoted, false, "bill 7 has only an Abstain row")
        // The lookups follow the new array.
        XCTAssertEqual(store.bill(forGUID: guid(120))?.userVoted, true)
        XCTAssertEqual(store.bill(for: bills[119].id)?.userVoted, true)
        let written = await billsCacheWasWritten(scope: scope)
        XCTAssertTrue(written, "a changed reconcile caches the bills")
    }

    @MainActor
    func testReconcilingClearsAnAbstainOnABillWithAGuidAndCachesIt() async {
        let bills = (1...20).map { bill($0) }
        let (store, _, scope) = makeStore(bills: bills)
        // `init` normalizes abstain rows, so this one arrives later (a cache or merge that still holds it).
        store.bills[3].userVoted = true
        store.bills[3].userVote = .abstain
        store.bills[3].lastVotedAt = Date()

        let writes = billsWrites(of: store) { store.reconcileVotesFromCache() }

        XCTAssertEqual(writes, 1)
        let cleared = store.bills[3]
        XCTAssertFalse(cleared.userVoted)
        XCTAssertNil(cleared.userVote)
        XCTAssertNil(cleared.lastVotedAt)
        let written = await billsCacheWasWritten(scope: scope)
        XCTAssertTrue(written)
    }

    @MainActor
    func testAnAbstainOnABillWithoutAGuidIsClearedButNotCachedByItself() async {
        // As before: the cache write is decided only for bills that have a guid to look up.
        var withoutGuid = bill(1)
        withoutGuid.guid = nil
        let (store, _, scope) = makeStore(bills: [withoutGuid, bill(2)])
        store.bills[0].userVoted = true
        store.bills[0].userVote = .abstain
        store.bills[0].lastVotedAt = Date()

        let writes = billsWrites(of: store) { store.reconcileVotesFromCache() }

        XCTAssertEqual(writes, 1)
        XCTAssertFalse(store.bills[0].userVoted)
        XCTAssertNil(store.bills[0].userVote)
        let written = await billsCacheWasWritten(scope: scope, waiting: 0.3)
        XCTAssertFalse(written)
    }

    @MainActor
    func testReconcilingWithoutAVoteStoreDoesNothing() {
        let bills = (1...10).map { bill($0) }
        let scope = "bills-store-vote-write-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(bills: bills, cacheScope: scope, service: FakeBillsService(), preferencesService: FakePreferencesService())

        let writes = billsWrites(of: store) { store.reconcileVotesFromCache() }

        XCTAssertEqual(writes, 0)
    }

    /// The write count does not grow with the number of bills, which is what made the old loop quadratic.
    @MainActor
    func testReconcileWritesDoNotGrowWithTheBillCount() {
        for count in [50, 400, 1_500] {
            let bills = (1...count).map { bill($0) }
            let (store, _, _) = makeStore(bills: bills, votes: [count: .nay, 1: .yea])

            let writes = billsWrites(of: store) { store.reconcileVotesFromCache() }

            XCTAssertEqual(writes, 1, "\(count) bills")
            XCTAssertEqual(store.bills.filter(\.userVoted).count, 2, "\(count) bills")
        }
    }

    // MARK: - vote(billID:)

    @MainActor
    func testVotingWritesTheBillOnce() async throws {
        let bills = (1...300).map { bill($0) }
        let (store, _, scope) = makeStore(bills: bills)

        var task: Task<Bool, Never>?
        let writes = billsWrites(of: store) {
            task = store.vote(billID: bills[41].id, vote: .yea, watch: true)
        }

        XCTAssertEqual(writes, 1)
        let stored = await task?.value
        XCTAssertEqual(stored, true)
        let voted = try XCTUnwrap(store.bill(for: bills[41].id))
        XCTAssertTrue(voted.userVoted)
        XCTAssertTrue(voted.userWatched)
        XCTAssertEqual(voted.userVote, .yea)
        XCTAssertEqual(voted.userYeaCount, 1)
        XCTAssertEqual(voted.userNayCount, 0)
        XCTAssertNotNil(voted.lastVotedAt)
        XCTAssertEqual(store.bills.filter(\.userVoted).count, 1, "no other bill changed")
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testChangingAVoteWritesTheBillOnceAndMovesTheCount() async throws {
        let bills = (1...100).map { bill($0) }
        let (store, _, scope) = makeStore(bills: bills)
        _ = await store.vote(billID: bills[9].id, vote: .yea, watch: nil)?.value
        await settleBillsCache(scope: scope)

        var task: Task<Bool, Never>?
        let writes = billsWrites(of: store) {
            task = store.vote(billID: bills[9].id, vote: .nay, watch: nil)
        }
        _ = await task?.value

        XCTAssertEqual(writes, 1)
        let changed = try XCTUnwrap(store.bill(for: bills[9].id))
        XCTAssertEqual(changed.userVote, .nay)
        XCTAssertEqual(changed.userYeaCount, 0, "the earlier Yea is taken back")
        XCTAssertEqual(changed.userNayCount, 1)
        XCTAssertFalse(changed.userWatched, "a nil watch leaves the watch as it was")
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testAnAbstainClearsTheVoteInOneWrite() async throws {
        let bills = (1...100).map { bill($0) }
        let (store, _, scope) = makeStore(bills: bills)
        _ = await store.vote(billID: bills[2].id, vote: .yea, watch: nil)?.value
        await settleBillsCache(scope: scope)

        var task: Task<Bool, Never>?
        let writes = billsWrites(of: store) {
            task = store.vote(billID: bills[2].id, vote: .abstain, watch: nil)
        }
        _ = await task?.value

        XCTAssertEqual(writes, 1)
        let abstained = try XCTUnwrap(store.bill(for: bills[2].id))
        XCTAssertFalse(abstained.userVoted, "an abstain is not a counted vote")
        XCTAssertNil(abstained.userVote)
        XCTAssertNil(abstained.lastVotedAt)
        XCTAssertEqual(abstained.userYeaCount, 0)
        await settleBillsCache(scope: scope)
    }
}
