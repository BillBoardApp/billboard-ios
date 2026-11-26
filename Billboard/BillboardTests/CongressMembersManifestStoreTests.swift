import XCTest
@testable import Billboard

/// `CongressMembersManifestStore` against a fake congress service: cache use, roster
/// order and the load error.
final class CongressMembersManifestStoreTests: XCTestCase {
    @MainActor
    private func members(_ names: [(id: String, name: String)]) throws -> [CongressMemberManifestItem] {
        let json = names.map { #"{"bioguideId":"\#($0.id)","name":"\#($0.name)"}"# }.joined(separator: ",")
        return try JSONDecoder().decode([CongressMemberManifestItem].self, from: Data("[\(json)]".utf8))
    }

    @MainActor
    func testLoadFetchesAndSortsByLastName() async throws {
        let service = FakeCongressService()
        service.manifestResult = .success(try members([
            ("S000148", "Charles E. Schumer"),
            ("A000370", "Alma S. Adams"),
            ("P000197", "Nancy Pelosi")
        ]))
        let store = CongressMembersManifestStore(service: service)

        await store.load()

        XCTAssertEqual(service.manifestRequestCount, 1)
        XCTAssertEqual(store.items.map(\.id), ["A000370", "P000197", "S000148"])
        XCTAssertTrue(store.hasLoadedOnce)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testFreshCacheIsShownWithoutARequest() async throws {
        let service = FakeCongressService()
        service.cachedManifest = try members([("P000197", "Nancy Pelosi")])
        service.cacheIsFresh = true

        let store = CongressMembersManifestStore(service: service)
        XCTAssertEqual(store.items.map(\.id), ["P000197"])
        XCTAssertTrue(store.hasLoadedOnce)

        await store.load()

        XCTAssertEqual(service.manifestRequestCount, 0)
    }

    @MainActor
    func testStaleCacheIsShownThenRefreshed() async throws {
        let service = FakeCongressService()
        service.cachedManifest = try members([("P000197", "Nancy Pelosi")])
        service.manifestResult = .success(try members([("P000197", "Nancy Pelosi"), ("A000370", "Alma S. Adams")]))

        let store = CongressMembersManifestStore(service: service)
        XCTAssertEqual(store.items.map(\.id), ["P000197"])
        XCTAssertFalse(store.hasLoadedOnce)

        await store.load()

        XCTAssertEqual(service.manifestRequestCount, 1)
        XCTAssertEqual(store.items.map(\.id), ["A000370", "P000197"])
    }

    @MainActor
    func testFailedLoadKeepsCachedMembersAndReportsIt() async throws {
        let service = FakeCongressService()
        service.cachedManifest = try members([("P000197", "Nancy Pelosi")])
        service.manifestResult = .failure(FakeServiceError())
        let store = CongressMembersManifestStore(service: service)

        await store.load(forceRefresh: true)

        XCTAssertEqual(store.errorMessage, "Could not load members right now.")
        XCTAssertEqual(store.items.map(\.id), ["P000197"])
        XCTAssertTrue(store.hasLoadedOnce)
    }
}

/// The members manifest's disk cache keeps each member's per-Congress counts (REL-46 A6), so the members list and a
/// basic profile name the Congress they cover after a relaunch, and a cache an earlier build wrote, without them,
/// still loads with its 119th Congress counts. The manifest cache is not scoped, so each test starts without one and
/// puts back the one that was there.
final class CongressMembersManifestCacheCountsTests: XCTestCase {
    // Mirror CongressService's private cache keys.
    private static let dataKey = "CongressService.congressMembersManifest.data"
    private static let timestampKey = "CongressService.congressMembersManifest.timestamp"

    /// contracts/fixtures/entities/congress-member-manifest.v1.valid.json in billboard-backend (main 9973fd2).
    private static let manifestFixture = Data(#"""
    {
      "generatedAt": "2026-03-06T20:00:00.000Z",
      "count": 2,
      "members": [
        {
          "bioguideId": "D000001",
          "name": "Jane Doe",
          "chamber": "House of Representatives",
          "state": "CA",
          "party": "D",
          "district": "12",
          "depictionImageUrl": "https://example.com/members/D000001.jpg",
          "updatedAt": "2026-03-05T12:00:00.000Z",
          "currentCongressBillsSupportedCount": 7,
          "trackedSponsoredCount": 2,
          "trackedSupportedCount": 7,
          "currentCongressCounts": { "congress": 120, "sponsored": 1, "supported": 4 }
        },
        {
          "bioguideId": "S000001",
          "name": "John Smith",
          "chamber": "Senate",
          "state": "NY",
          "party": "R",
          "district": null,
          "depictionImageUrl": null,
          "updatedAt": "2026-03-04T09:30:00.000Z",
          "currentCongressBillsSupportedCount": 3
        }
      ]
    }
    """#.utf8)

    override func setUp() {
        super.setUp()
        let previousData = DiskJSONCache.data(forKey: Self.dataKey)
        let previousTimestamp = UserDefaults.standard.object(forKey: Self.timestampKey)
        addTeardownBlock {
            if let previousData {
                DiskJSONCache.store(previousData, forKey: Self.dataKey)
            } else {
                DiskJSONCache.removeData(forKey: Self.dataKey)
            }
            if let previousTimestamp {
                UserDefaults.standard.set(previousTimestamp, forKey: Self.timestampKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.timestampKey)
            }
            CongressService.invalidateMemberIndex()
        }
        DiskJSONCache.removeData(forKey: Self.dataKey)
        CongressService.invalidateMemberIndex()
    }

    /// Fetched, cached, then read back by the store as a relaunch does: the counts keep their Congress.
    @MainActor
    func testTheCacheKeepsTheCongressOfEachMembersCounts() async throws {
        let transport = RecordingTransport()
        transport.responses = [Self.manifestFixture]
        let fetched = try await APIClient.$current.withValue(transport.client) {
            try await CongressService.getCongressMembersManifest()
        }
        XCTAssertEqual(fetched.map(\.currentCongressCounts), [TrackedCongressCounts(congress: 120, sponsored: 1, supported: 4), nil])

        XCTAssertEqual(CongressService.cachedCongressMembersManifest(), fetched)
        let store = CongressMembersManifestStore(service: CongressService.Live())
        XCTAssertEqual(store.items.map(\.id), ["D000001", "S000001"])
        XCTAssertEqual(store.items.map(\.currentCongressCounts), [TrackedCongressCounts(congress: 120, sponsored: 1, supported: 4), nil])
        XCTAssertEqual(store.items.map(\.trackedSponsoredCount), [2, nil])
    }

    /// A cache written before 1.3 has no currentCongressCounts: it still loads, with its 119th Congress counts.
    @MainActor
    func testACacheWrittenBeforeTheCountsStillLoads() throws {
        // As CongressMemberManifestItem.encode(to:) wrote it before 1.3.
        let earlier = #"""
        [{"bioguideId":"D000001","name":"Jane Doe","chamber":"House of Representatives","state":"CA","district":"12","party":"D",\#
        "depictionImageUrl":"https:\/\/example.com\/members\/D000001.jpg","currentCongressBillsSupportedCount":7,\#
        "trackedSponsoredCount":2,"trackedSupportedCount":7}]
        """#
        XCTAssertTrue(DiskJSONCache.store(Data(earlier.utf8), forKey: Self.dataKey))

        let store = CongressMembersManifestStore(service: CongressService.Live())
        XCTAssertEqual(store.items.map(\.id), ["D000001"])
        let item = try XCTUnwrap(store.items.first)
        XCTAssertNil(item.currentCongressCounts)
        XCTAssertEqual(item.trackedSponsoredCount, 2)
        XCTAssertEqual(item.trackedSupportedCount, 7)
    }
}
