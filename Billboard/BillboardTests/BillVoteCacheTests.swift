import XCTest
@testable import Billboard

final class BillVoteCacheTests: XCTestCase {
    private var cache: BillVoteCache!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var persistenceKey: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Persist into a throwaway suite so tests never touch the host app's UserDefaults.standard.
        suiteName = "BillVoteCacheTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        persistenceKey = "test_vote_cache_\(UUID().uuidString)"
        let config = BillVoteCache.Config(persistenceKey: persistenceKey)
        cache = BillVoteCache(config: config, defaults: defaults)
    }

    override func tearDown() {
        cache = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        persistenceKey = nil
        super.tearDown()
    }

    // MARK: - Basic read/write

    func testGetStateReturnsUnknownForMissingBill() {
        let state = cache.getState(for: "BILL-999")
        XCTAssertEqual(state, .unknown)
    }

    func testSetVotedAndRetrieve() {
        let now = Date()
        cache.setVoted(billId: "BILL-1", vote: .yea, votedAt: now, now: now)

        let state = cache.getState(for: "BILL-1")
        XCTAssertEqual(state, .voted(.yea))
    }

    func testSetNotVotedAndRetrieve() {
        let now = Date()
        cache.setNotVoted(billId: "BILL-2", now: now)

        let state = cache.getState(for: "BILL-2")
        XCTAssertEqual(state, .notVoted)
    }

    func testOverwriteVote() {
        let now = Date()
        cache.setVoted(billId: "BILL-3", vote: .yea, votedAt: now, now: now)
        cache.setVoted(billId: "BILL-3", vote: .nay, votedAt: now, now: now)

        let state = cache.getState(for: "BILL-3")
        XCTAssertEqual(state, .voted(.nay))
    }

    // MARK: - Snapshot

    func testSnapshotStatesReturnsAllCachedEntries() {
        let now = Date()
        cache.setVoted(billId: "A", vote: .yea, votedAt: now, now: now)
        cache.setNotVoted(billId: "B", now: now)

        let snapshot = cache.snapshotStates()
        XCTAssertEqual(snapshot["A"], .voted(.yea))
        XCTAssertEqual(snapshot["B"], .notVoted)
    }

    // MARK: - Persistence isolation

    func testWritesGoToInjectedDefaultsOnly() {
        let now = Date()
        cache.setVoted(billId: "BILL-4", vote: .yea, votedAt: now, now: now)

        XCTAssertNotNil(defaults.data(forKey: persistenceKey))
        XCTAssertNil(UserDefaults.standard.data(forKey: persistenceKey))
    }

    // MARK: - Empty billId

    func testEmptyBillIdReturnsUnknown() {
        let state = cache.getState(for: "")
        XCTAssertEqual(state, .unknown)
    }

    // MARK: - Votes not saved yet (APPF-30 step 2)

    private func unsaved(_ vote: VoteType, sentAt: Date = Date(), reasons: [String] = [], autoResent: Bool = false) -> BillVoteCache.UnsavedVote {
        BillVoteCache.UnsavedVote(vote: vote, sentAt: sentAt, reasons: reasons, autoResent: autoResent)
    }

    /// The marks are saved beside the rows, under `<persistenceKey>.unconfirmed`, and a new cache on the same defaults
    /// (the next launch) finds them, with their vote, send time, reasons and whether the automatic resend was used.
    @MainActor
    func testVotesNotSavedYetSurviveANewCacheOnTheSameDefaults() {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        cache.setVoted(billId: "BILL-1", vote: .yea, votedAt: sentAt, now: Date())
        cache.setUnsavedVote(unsaved(.yea, sentAt: sentAt, reasons: ["education"]), for: "BILL-1")
        cache.setVoted(billId: "BILL-2", vote: .nay, votedAt: sentAt, now: Date())
        cache.setUnsavedVote(unsaved(.nay, sentAt: sentAt, autoResent: true), for: "BILL-2")
        XCTAssertNotNil(defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: persistenceKey)))

        let next = BillVoteCache(config: BillVoteCache.Config(persistenceKey: persistenceKey), defaults: defaults)

        XCTAssertEqual(next.unsavedVotes, [
            "BILL-1": unsaved(.yea, sentAt: sentAt, reasons: ["education"]),
            "BILL-2": unsaved(.nay, sentAt: sentAt, autoResent: true)
        ])
        XCTAssertEqual(next.getState(for: "BILL-1"), .voted(.yea), "the row itself is an ordinary vote row")

        next.setUnsavedVote(nil, for: "BILL-1")
        next.setUnsavedVote(nil, for: "BILL-2")
        XCTAssertNil(defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: persistenceKey)), "no map left once empty")
        XCTAssertEqual(BillVoteCache(config: BillVoteCache.Config(persistenceKey: persistenceKey), defaults: defaults).unsavedVotes, [:])
    }

    /// A 1.2 cache has rows and no map: it loads as it is, with no vote marked.
    @MainActor
    func testACacheWithoutTheMapLoadsAsItIs() {
        let now = Date()
        cache.setVoted(billId: "BILL-1", vote: .yea, votedAt: now, now: now)
        cache.setNotVoted(billId: "BILL-2", now: now)
        XCTAssertNil(defaults.data(forKey: BillVoteCache.unsavedVotesKey(for: persistenceKey)), "precondition: no map")

        let next = BillVoteCache(config: BillVoteCache.Config(persistenceKey: persistenceKey), defaults: defaults)

        XCTAssertEqual(next.getState(for: "BILL-1"), .voted(.yea))
        XCTAssertEqual(next.getState(for: "BILL-2"), .notVoted)
        XCTAssertEqual(next.unsavedVotes, [:])
    }

    /// Sign-out and account deletion clear the marks with the rows (`clearPersistence`, from `UserLocalDataPurge`), so
    /// a vote not saved yet never reaches the next account; another account's marks stay. A sign-out that does not know
    /// the account clears every account's marks.
    @MainActor
    func testSignOutClearsTheVotesNotSavedYet() {
        let mine = BillVoteCache(scope: "account-a", defaults: defaults)
        mine.setVoted(billId: "BILL-1", vote: .yea, votedAt: Date())
        mine.setUnsavedVote(unsaved(.yea), for: "BILL-1")
        let theirs = BillVoteCache(scope: "account-b", defaults: defaults)
        theirs.setVoted(billId: "BILL-1", vote: .nay, votedAt: Date())
        theirs.setUnsavedVote(unsaved(.nay), for: "BILL-1")

        UserLocalDataPurge.purge(userId: "account-a", defaults: defaults)

        XCTAssertEqual(BillVoteCache(scope: "account-a", defaults: defaults).unsavedVotes, [:])
        XCTAssertEqual(BillVoteCache(scope: "account-a", defaults: defaults).getState(for: "BILL-1"), .unknown)
        XCTAssertEqual(BillVoteCache(scope: "account-b", defaults: defaults).unsavedVotes.keys.sorted(), ["BILL-1"])

        UserLocalDataPurge.purge(userId: nil, defaults: defaults)

        XCTAssertEqual(BillVoteCache(scope: "account-b", defaults: defaults).unsavedVotes, [:])
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.hasSuffix(".unconfirmed") })
    }

    /// A mark goes when its row is pruned (the TTL, or the size cap), and a mark sent longer ago than the TTL goes too
    /// (its row went with a push and was never read again). Removing the row alone (a push) keeps the mark.
    @MainActor
    func testAMarkGoesWithItsPrunedRow() {
        let key = "test_vote_cache_prune_\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let small = BillVoteCache(config: BillVoteCache.Config(ttl: 100, maxEntries: 2, persistenceKey: key), defaults: defaults)
        small.setVoted(billId: "OLD", vote: .yea, votedAt: start, now: start)
        small.setUnsavedVote(unsaved(.yea, sentAt: start), for: "OLD")
        small.setVoted(billId: "PUSHED", vote: .nay, votedAt: start, now: start)
        small.setUnsavedVote(unsaved(.nay, sentAt: start.addingTimeInterval(50)), for: "PUSHED")
        small.remove(billId: "PUSHED")
        XCTAssertEqual(small.unsavedVotes.keys.sorted(), ["OLD", "PUSHED"], "a push removes the row, not the mark")

        // Two newer rows: the size cap evicts the oldest.
        small.setVoted(billId: "A", vote: .yea, votedAt: start, now: start.addingTimeInterval(10))
        small.setVoted(billId: "B", vote: .yea, votedAt: start, now: start.addingTimeInterval(20))
        XCTAssertEqual(small.getState(for: "OLD", now: start.addingTimeInterval(20)), .unknown, "precondition: evicted")
        XCTAssertEqual(small.unsavedVotes.keys.sorted(), ["PUSHED"])

        small.prune(now: start.addingTimeInterval(151))
        XCTAssertEqual(small.unsavedVotes, [:], "sent longer ago than the TTL")
        XCTAssertEqual(BillVoteCache(config: BillVoteCache.Config(ttl: 100, persistenceKey: key), defaults: defaults).unsavedVotes, [:])
    }
}
