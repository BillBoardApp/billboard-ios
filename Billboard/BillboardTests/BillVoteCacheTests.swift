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
}
