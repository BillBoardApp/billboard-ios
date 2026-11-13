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
