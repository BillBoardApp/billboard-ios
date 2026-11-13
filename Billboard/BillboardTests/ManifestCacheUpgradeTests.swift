import os
import XCTest
@testable import Billboard

/// INT-11: an install that updates from 1.1 to 1.2 starts from a fresh manifest fetch. 1.1 kept the
/// full manifest in `data.v4` (coverage `coverage.v2`) ranked by other users' vote count, counts
/// included, and merged every windowed fetch into that order; 1.2 reads other keys (`data.v5`,
/// `coverage.v3`), so that copy is never read and never merged into, and the launch deletes it.
final class ManifestCacheUpgradeTests: XCTestCase {
    private var cache = BillsManifestCache(namespace: "manifest-cache-upgrade-tests")

    override func setUp() {
        super.setUp()
        cache = BillsManifestCache(namespace: "manifest-cache-upgrade-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        cache.clear()
        removeCacheOf11()
        super.tearDown()
    }

    // MARK: - The cache 1.1 left

    private var keysOf11: (data: String, timestamp: String, coverage: String, bytes: String) {
        ("\(cache.namespace).data.v4", "\(cache.namespace).timestamp.v4", "\(cache.namespace).coverage.v2", "\(cache.namespace).bytes.v1")
    }

    private func iso(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    /// 1.1's full copy as it wrote it: the oldest bill, the most voted, first; a count on every item.
    @discardableResult
    private func writeCacheOf11() throws -> Int {
        func item(_ guid: String, daysAgo: Double, votes: Int) -> [String: Any] {
            [
                "guid": guid, "congress": "119", "billType": "hr", "billID": String(guid.dropFirst(11)),
                "updatedAt": iso(daysAgo: daysAgo), "subCategories": ["Energy"], "lifeAreas": [String](),
                "sponsors": [String](), "cosponsors": [String](), "title": "Bill \(guid)", "voteCount": votes
            ]
        }
        let ordered = [
            item("BILLS-119hr1", daysAgo: 30, votes: 900),
            item("BILLS-119hr2", daysAgo: 20, votes: 40),
            item("BILLS-119hr3", daysAgo: 10, votes: 0)
        ]
        let file = try JSONSerialization.data(withJSONObject: ordered)
        let keys = keysOf11
        XCTAssertTrue(DiskJSONCache.store(file, forKey: keys.data))
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: keys.timestamp)
        defaults.set("full", forKey: keys.coverage)
        defaults.set(file.count, forKey: keys.bytes)
        return file.count
    }

    private func cacheOf11Exists() -> Bool {
        let keys = keysOf11
        let defaults = UserDefaults.standard
        return DiskJSONCache.byteCount(forKey: keys.data) != nil
            || [keys.timestamp, keys.coverage, keys.bytes].contains { defaults.object(forKey: $0) != nil }
    }

    private func removeCacheOf11() {
        cache.removeLegacyCache()
    }

    private func item(_ guid: String, daysAgo: Double, votes: Int? = nil, priorityRank: Int? = nil) throws -> BillsManifestItem {
        var object: [String: Any] = [
            "guid": guid, "congress": "119", "billType": "hr", "billID": String(guid.dropFirst(11)),
            "updatedAt": iso(daysAgo: daysAgo), "subCategories": ["Energy"], "title": "Bill \(guid)"
        ]
        if let votes { object["voteCount"] = votes }
        if let priorityRank {
            object["isPriority"] = true
            object["priorityRank"] = priorityRank
        }
        return try JSONDecoder().decode(BillsManifestItem.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - Not read

    func testTheKeysAreNotThoseOf11() {
        XCTAssertEqual(cache.dataKey, "\(cache.namespace).data.v5")
        XCTAssertEqual(cache.coverageKey, "\(cache.namespace).coverage.v3")
        XCTAssertEqual(cache.timestampKey, "\(cache.namespace).timestamp.v5")
        XCTAssertEqual(cache.byteCountKey, "\(cache.namespace).bytes.v2")

        let keys = keysOf11
        XCTAssertEqual(Set([keys.data]).intersection([cache.dataKey, cache.companionGroupsKey]), [])
        XCTAssertEqual(Set([keys.timestamp, keys.coverage, keys.bytes]).intersection([cache.timestampKey, cache.coverageKey, cache.byteCountKey]), [])
        XCTAssertTrue(cache.legacyDataKeys.contains(keys.data), "the launch deletes 1.1's file")
        XCTAssertTrue(Set(cache.legacyDefaultsKeys).isSuperset(of: [keys.timestamp, keys.coverage, keys.bytes]))
    }

    func testAnUpgradedInstallDoesNotReadTheCacheOf11() throws {
        try writeCacheOf11()
        XCTAssertNotNil(DiskJSONCache.data(forKey: keysOf11.data), "precondition: 1.1's copy is there")

        XCTAssertNil(cache.items())
        XCTAssertNil(cache.coverage())
        XCTAssertFalse(cache.isFresh(maxAge: 600), "1.1's timestamp does not make an empty cache fresh")
        BillsManifestCache.$current.withValue(cache) {
            XCTAssertNil(BillsService.cachedBillsManifest())
            XCTAssertNil(BillsService.cachedBillsManifest(maxAge: 600))
            XCTAssertFalse(BillsService.cachedBillsManifestIsFull())
            XCTAssertFalse(BillsService.cachedBillsManifestIsFull(maxAge: 600))
        }
    }

    // MARK: - Deleted at launch

    func testTheLaunchDeletesTheCacheOf11() async throws {
        try writeCacheOf11()
        XCTAssertTrue(cacheOf11Exists(), "precondition")

        await cache.discardEarlierCachesInBackground().value

        XCTAssertFalse(cacheOf11Exists(), "1.1's file and values are gone before the first fetch")
    }

    func testTheLaunchKeepsTheCacheThatIsRead() async throws {
        XCTAssertEqual(cache.store([try item("BILLS-119hr9", daysAgo: 1)], fetched: .full), .full)
        XCTAssertTrue(cache.storeCompanionGroups([]))
        try writeCacheOf11()

        await cache.discardEarlierCachesInBackground().value

        XCTAssertEqual(cache.items()?.map(\.guid), ["BILLS-119hr9"])
        XCTAssertEqual(cache.coverage(), .full)
        XCTAssertEqual(cache.companionGroups()?.count, 0, "the companion groups carry no votes and keep their file")
        XCTAssertFalse(cacheOf11Exists())
    }

    func testTheLaunchIsSafeWhenThereIsNothingToDeleteAndWhenRunTwice() async throws {
        await cache.discardEarlierCachesInBackground().value
        try writeCacheOf11()
        await cache.discardEarlierCachesInBackground().value
        await cache.discardEarlierCachesInBackground().value

        XCTAssertFalse(cacheOf11Exists())
        XCTAssertNil(cache.items())
    }

    // MARK: - Rebuilt without counts

    func testTheFirstFetchAfterTheUpdateWritesAFreshCopyAndDoesNotMergeIntoTheOldOne() throws {
        try writeCacheOf11()
        let newer = try item("BILLS-119hr4", daysAgo: 1, votes: 5)

        // The review's form: 1.1's vote-ordered full copy, then a windowed write of one newer item. On
        // the same keys that item was inserted into the old order and the copy stayed full.
        XCTAssertEqual(cache.store([newer], fetched: .windowed(updatedAfter: Date(timeIntervalSinceNow: -7 * 86_400))), .windowed)

        XCTAssertEqual(cache.items()?.map(\.guid), ["BILLS-119hr4"], "nothing of 1.1's copy is carried over")
        XCTAssertEqual(cache.coverage(), .windowed, "so a full manifest is fetched when a screen needs it")
        let written = try XCTUnwrap(DiskJSONCache.data(forKey: cache.dataKey))
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("voteCount"))
        XCTAssertFalse(cacheOf11Exists(), "the first write removes it too, if the launch has not yet")
    }

    func testTheFullManifestAfterTheUpdateIsOrderedWithoutVotesAndWindowedFetchesMergeInThatOrder() throws {
        try writeCacheOf11()
        // A server that still sends counts, most voted first, the oldest bill leading.
        let fetched = [
            try item("BILLS-119hr1", daysAgo: 30, votes: 900),
            try item("BILLS-119hr3", daysAgo: 10, votes: 40),
            try item("BILLS-119hr2", daysAgo: 20, votes: 2),
            try item("BILLS-119hr5", daysAgo: 25, votes: 0, priorityRank: 1)
        ]
        XCTAssertEqual(cache.store(fetched, fetched: .full), .full)
        XCTAssertEqual(
            cache.items()?.map(\.guid),
            ["BILLS-119hr5", "BILLS-119hr3", "BILLS-119hr2", "BILLS-119hr1"],
            "in the news first, then the newest: no vote-count component"
        )

        let fresh = try item("BILLS-119hr6", daysAgo: 1, votes: 0)
        let reordered = try item("BILLS-119hr1", daysAgo: 0.5, votes: 0)
        XCTAssertEqual(cache.store([fresh, reordered], fetched: .windowed(updatedAfter: Date(timeIntervalSinceNow: -7 * 86_400))), .full)

        XCTAssertEqual(
            cache.items()?.map(\.guid),
            ["BILLS-119hr5", "BILLS-119hr1", "BILLS-119hr6", "BILLS-119hr3", "BILLS-119hr2"]
        )
        let written = try XCTUnwrap(DiskJSONCache.data(forKey: cache.dataKey))
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("voteCount"))
    }

    // MARK: - The bills cache 1.1 left

    /// 1.1 saved the store's bills in the manifest's order, most voted first, each with its manifest
    /// count. With no cached manifest to put them in order again (the case right after the update),
    /// that saved order is what Search and the topic lists show until a fetch lands, or for as long as
    /// the phone is offline.
    @MainActor
    private func storeWithBillsCacheOf11(
        _ bills: [Bill],
        manifest: [BillsManifestItem]? = nil
    ) -> (store: BillsStore, service: FakeBillsService) {
        let scope = "manifest-cache-upgrade-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var objects = (try? JSONSerialization.jsonObject(with: encoder.encode(bills))) as? [[String: Any]] ?? []
        for index in objects.indices { objects[index]["voteCount"] = 1_000 - index }
        let file = (try? JSONSerialization.data(withJSONObject: objects)) ?? Data()
        XCTAssertTrue(DiskJSONCache.store(file, forKey: ScopedStorageKey.make(base: "BillsStore.bills.data", scope: scope)))

        let service = FakeBillsService()
        service.cachedManifest = manifest
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        return (store, service)
    }

    @MainActor
    func testTheBillsCacheOf11RestoresInThePriorityThenNewestOrderWhenThereIsNoCachedManifest() async throws {
        // Saved most voted first: the oldest bill leads, the newest and the one in the news trail.
        let saved = [
            BillsStore.placeholderBill(from: try item("BILLS-119hr1", daysAgo: 30)),
            BillsStore.placeholderBill(from: try item("BILLS-119hr2", daysAgo: 20)),
            BillsStore.placeholderBill(from: try item("BILLS-119hr3", daysAgo: 1)),
            BillsStore.placeholderBill(from: try item("BILLS-119hr4", daysAgo: 25, priorityRank: 1))
        ]
        let (store, _) = storeWithBillsCacheOf11(saved)

        await store.restoreCachedStateIfNeeded()

        XCTAssertEqual(store.bills.compactMap(\.guid), ["BILLS-119hr4", "BILLS-119hr3", "BILLS-119hr2", "BILLS-119hr1"])
        XCTAssertTrue(store.manifestItems.isEmpty, "1.1's manifest copy was not read")
        XCTAssertFalse(store.hasFullManifestCoverage)
    }

    @MainActor
    func testVotedAndWatchedBillsKeptOutsideTheWindowFollowTheProductOrderToo() async throws {
        var oldest = BillsStore.placeholderBill(from: try item("BILLS-119hr1", daysAgo: 400))
        var newer = BillsStore.placeholderBill(from: try item("BILLS-119hr3", daysAgo: 300))
        oldest.userWatched = true
        newer.userWatched = true
        // The manifest has one bill inside the window; the watched ones are outside it.
        let inWindow = try item("BILLS-119hr2", daysAgo: 1)
        let (store, _) = storeWithBillsCacheOf11([oldest, newer], manifest: [inWindow])

        await store.restoreCachedStateIfNeeded()

        XCTAssertEqual(store.bills.compactMap(\.guid), ["BILLS-119hr2", "BILLS-119hr3", "BILLS-119hr1"])
    }

    /// The 2026-10-14 slowness fixes hold on the first launch after the update: the restore reads the
    /// (now empty) manifest cache and ranks the cached bills on a detached task, never on the main thread.
    @MainActor
    func testTheRestoreAfterTheUpdateReadsTheCachesOffTheMainThread() async throws {
        let saved = [
            BillsStore.placeholderBill(from: try item("BILLS-119hr1", daysAgo: 30)),
            BillsStore.placeholderBill(from: try item("BILLS-119hr2", daysAgo: 1))
        ]
        let (store, service) = storeWithBillsCacheOf11(saved)
        let readsOnMain = OSAllocatedUnfairLock(initialState: [Bool]())
        service.onCachedManifestRead = { readsOnMain.withLock { $0.append(Thread.isMainThread) } }

        await store.restoreCachedStateIfNeeded()

        XCTAssertEqual(readsOnMain.withLock { $0 }, [false])
        XCTAssertEqual(store.bills.compactMap(\.guid), ["BILLS-119hr2", "BILLS-119hr1"])
    }

    func testTheRestoreSnapshotRanksTheCachedBills() throws {
        // The ranking is part of the pure snapshot the restore builds on a detached task, not on the main actor.
        let saved = [
            BillsStore.placeholderBill(from: try item("BILLS-119hr1", daysAgo: 30)),
            BillsStore.placeholderBill(from: try item("BILLS-119hr2", daysAgo: 1))
        ]
        let snapshot = BillsStore.cacheRestoreSnapshot(
            cachedManifest: [], cachedBills: saved, historyWindow: .oneWeek
        )
        XCTAssertEqual(snapshot.normalizedCachedBills.compactMap(\.guid), ["BILLS-119hr2", "BILLS-119hr1"])
        XCTAssertEqual(snapshot.restoredBills?.compactMap(\.guid), ["BILLS-119hr2", "BILLS-119hr1"])
    }
}
