import XCTest
@testable import Billboard

/// `BillsService.getBillsManifest(updatedAfter:)` caches what it fetched in `BillsManifestCache`: a
/// full fetch replaces the copy and marks it full, a windowed fetch merges into a full copy when its
/// window reaches back to the copy's last write and otherwise replaces the copy as windowed. The copy
/// is not capped (it used to keep 2,000 items and still be marked full). Each test uses its own cache
/// keys.
final class BillsManifestCacheTests: XCTestCase {
    private var cache = BillsManifestCache(namespace: "bills-manifest-cache-tests")

    override func setUp() {
        super.setUp()
        cache = BillsManifestCache(namespace: "bills-manifest-cache-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        cache.clear()
        super.tearDown()
    }

    private func manifest(_ bills: [(guid: String, title: String)]) -> Data {
        let items = bills.map { #"{"guid":"\#($0.guid)","billType":"hr","title":"\#($0.title)","updatedAt":"2026-09-20T11:00:00.000Z"}"# }
        return Data(#"{"generatedAt":"2026-09-20T12:00:00.000Z","count":\#(bills.count),"bills":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    private func bills(_ count: Int) -> [(guid: String, title: String)] {
        (1...count).map { ("BILLS-119hr\($0)", "Bill \($0)") }
    }

    /// One `getBillsManifest` call answered with `payload` (inline, so no snapshot is involved).
    @MainActor
    private func getManifest(_ payload: Data, updatedAfter: Date? = nil) async throws -> [BillsManifestItem] {
        let transport = RecordingTransport()
        transport.responses = [payload]
        return try await APIClient.$current.withValue(transport.client) {
            try await BillsManifestCache.$current.withValue(cache) {
                try await BillsService.getBillsManifest(updatedAfter: updatedAfter)
            }
        }
    }

    private func cached<T>(_ read: () -> T) -> T {
        BillsManifestCache.$current.withValue(cache) { read() }
    }

    @MainActor
    func testFullFetchCachesEveryItemAndIsFull() async throws {
        let fetched = try await getManifest(manifest(bills(2_500)))

        XCTAssertEqual(fetched.count, 2_500)
        XCTAssertEqual(cached { BillsService.cachedBillsManifest()?.count }, 2_500, "no 2,000-item cap")
        XCTAssertTrue(cached { BillsService.cachedBillsManifestIsFull() })
        XCTAssertTrue(cached { BillsService.cachedBillsManifestIsFull(maxAge: 60) })
        XCTAssertTrue(cached { BillsService.cachedBillsManifestIsFresh(maxAge: 60) })
        XCTAssertEqual(cache.coverage(), .full)
    }

    @MainActor
    func testWindowedFetchMergesIntoAFullCopy() async throws {
        _ = try await getManifest(manifest(bills(2_100)))

        let since = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await getManifest(manifest([("BILLS-119hr7", "Bill 7 updated"), ("BILLS-119hr9999", "New bill")]), updatedAfter: since)

        let items = try XCTUnwrap(cache.items())
        XCTAssertEqual(items.count, 2_101)
        XCTAssertEqual(items.first { $0.guid == "BILLS-119hr7" }?.title, "Bill 7 updated")
        XCTAssertTrue(items.contains { $0.guid == "BILLS-119hr9999" })
        XCTAssertEqual(cache.coverage(), .full, "a full copy kept current by a windowed fetch is still full")
    }

    @MainActor
    func testWindowedFetchWithoutAFullCopyIsWindowedAndReplacesIt() async throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await getManifest(manifest([("BILLS-119hr1", "One"), ("BILLS-119hr2", "Two")]), updatedAfter: since)

        XCTAssertEqual(cache.coverage(), .windowed)
        XCTAssertFalse(cached { BillsService.cachedBillsManifestIsFull() })

        _ = try await getManifest(manifest([("BILLS-119hr3", "Three")]), updatedAfter: since)

        XCTAssertEqual(cache.items()?.map(\.guid), ["BILLS-119hr3"], "windowed copies are not merged across fetches")
        XCTAssertEqual(cache.coverage(), .windowed)
    }

    // MARK: - A gap longer than the window

    /// The copy's last write, as if it was `daysAgo` days ago.
    private func setLastWrite(daysAgo: Double) {
        UserDefaults.standard.set(Date().addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970, forKey: cache.timestampKey)
    }

    /// Someone opened Search once (a full copy), then didn't open the app for 30 days. The Bills tab's 7-day
    /// fetch at the next launch does not reach back to the copy, so merging it would leave out every bill
    /// published or changed in between while the copy still claimed to hold every bill (and Search said a bill
    /// it lacked was in none). The copy is replaced as windowed instead, so the next Search fetches every bill.
    @MainActor
    func testAWindowedFetchThatLeavesAGapReplacesTheFullCopy() async throws {
        _ = try await getManifest(manifest(bills(3)))
        setLastWrite(daysAgo: 30)

        _ = try await getManifest(manifest([("BILLS-119hr9", "New this week")]), updatedAfter: Date().addingTimeInterval(-7 * 86_400))

        XCTAssertEqual(cache.items()?.map(\.guid), ["BILLS-119hr9"])
        XCTAssertEqual(cache.coverage(), .windowed)
        XCTAssertFalse(cached { BillsService.cachedBillsManifestIsFull() })
    }

    /// A launch within the window (here 3 days after the last write, with a 7-day fetch) keeps the copy full.
    @MainActor
    func testAWindowedFetchThatReachesBackToTheLastWriteKeepsTheCopyFull() async throws {
        _ = try await getManifest(manifest(bills(3)))
        setLastWrite(daysAgo: 3)

        _ = try await getManifest(manifest([("BILLS-119hr9", "New this week")]), updatedAfter: Date().addingTimeInterval(-7 * 86_400))

        XCTAssertEqual(Set(try XCTUnwrap(cache.items()).map(\.guid)), ["BILLS-119hr1", "BILLS-119hr2", "BILLS-119hr3", "BILLS-119hr9"])
        XCTAssertEqual(cache.coverage(), .full)
    }

    /// The window must start an hour before the last write: a row written while that fetch ran can be dated a
    /// little before it.
    func testTheWindowMustStartAnHourBeforeTheLastWrite() throws {
        let lastWrite = Date().addingTimeInterval(-2 * 86_400)

        cache.store(items(["BILLS-119hr1"]), fetched: .full)
        UserDefaults.standard.set(lastWrite.timeIntervalSince1970, forKey: cache.timestampKey)
        XCTAssertEqual(cache.store(items(["BILLS-119hr2"]), fetched: .windowed(updatedAfter: lastWrite.addingTimeInterval(-30 * 60))), .windowed)

        cache.store(items(["BILLS-119hr1"]), fetched: .full)
        UserDefaults.standard.set(lastWrite.timeIntervalSince1970, forKey: cache.timestampKey)
        XCTAssertEqual(cache.store(items(["BILLS-119hr2"]), fetched: .windowed(updatedAfter: lastWrite.addingTimeInterval(-BillsManifestCache.gapAllowance - 1))), .full)
        XCTAssertEqual(Set(try XCTUnwrap(cache.items()).map(\.guid)), ["BILLS-119hr1", "BILLS-119hr2"])
    }

    /// A full copy whose write time is unknown is not merged into: a windowed fetch replaces it.
    func testAFullCopyWithoutAWriteTimeIsReplacedByAWindowedFetch() {
        cache.store(items(["BILLS-119hr1"]), fetched: .full)
        UserDefaults.standard.removeObject(forKey: cache.timestampKey)

        XCTAssertEqual(cache.store(items(["BILLS-119hr2"]), fetched: .windowed(updatedAfter: Date().addingTimeInterval(-7 * 86_400))), .windowed)
        XCTAssertEqual(cache.items()?.map(\.guid), ["BILLS-119hr2"])
    }

    @MainActor
    func testEmptyPayloadLeavesTheCacheAlone() async throws {
        _ = try await getManifest(manifest(bills(3)))

        let fetched = try await getManifest(Data())

        XCTAssertEqual(fetched, [])
        XCTAssertEqual(cache.items()?.count, 3)
        XCTAssertEqual(cache.coverage(), .full)
    }

    func testStoreDeduplicatesByGuidAndKeepsTheNewerItem() throws {
        func item(_ title: String, updatedAt: String) -> BillsManifestItem {
            BillsManifestItem(guid: "BILLS-119hr1", congress: "119", billType: "hr", billID: "1", updatedAt: updatedAt, subCategories: [], lifeAreas: [], sponsors: ["A000001"], cosponsors: [], title: title)
        }

        let coverage = cache.store([item("Old", updatedAt: "2026-09-01T00:00:00Z"), item("New", updatedAt: "2026-09-02T00:00:00Z")], fetched: .full)

        XCTAssertEqual(coverage, .full)
        XCTAssertEqual(cache.items()?.map(\.title), ["New"])
    }

    // MARK: - Concurrent writes

    private func items(_ guids: [String], updatedAt: String = "2026-09-20T11:00:00.000Z") -> [BillsManifestItem] {
        guids.map {
            BillsManifestItem(guid: $0, congress: "119", billType: "hr", billID: nil, updatedAt: updatedAt, subCategories: [], lifeAreas: [], sponsors: [], cosponsors: [], title: $0)
        }
    }

    func testConcurrentWindowedWritesIntoAFullCopyLoseNothing() async throws {
        let cache = cache
        let full = items((1...2_000).map { "BILLS-119hr\($0)" })
        XCTAssertEqual(cache.store(full, fetched: .full), .full)

        let added = (1...8).map { "BILLS-119s\($0)" }
        let windowed = added.map { items([$0]) }
        await withTaskGroup(of: Void.self) { group in
            for batch in windowed {
                group.addTask { cache.store(batch, fetched: .windowed(updatedAfter: Date(timeIntervalSinceNow: -7 * 86_400))) }
            }
        }

        let guids = Set(try XCTUnwrap(cache.items()).map(\.guid))
        XCTAssertEqual(guids.count, 2_008, "each windowed write merged into the copy the previous one left")
        XCTAssertTrue(guids.isSuperset(of: added))
        XCTAssertEqual(cache.coverage(), .full)
    }

    func testConcurrentFullAndWindowedWritesLeaveAFullCopy() async throws {
        let cache = cache
        let full = items((1...1_500).map { "BILLS-119hr\($0)" })
        let windowed = (1...8).map { items(["BILLS-119s\($0)"]) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { cache.store(full, fetched: .full) }
            for batch in windowed {
                group.addTask { cache.store(batch, fetched: .windowed(updatedAfter: Date(timeIntervalSinceNow: -7 * 86_400))) }
            }
        }

        // A windowed write before the full one is replaced by it; one after it is merged into it.
        // Either way the last copy holds the full fetch and is recorded as full.
        XCTAssertEqual(cache.coverage(), .full)
        let guids = Set(try XCTUnwrap(cache.items()).map(\.guid))
        XCTAssertTrue(guids.isSuperset(of: full.map(\.guid)))
    }

    func testWindowedItemOlderThanTheCachedOneDoesNotReplaceIt() {
        cache.store(items(["BILLS-119hr1"], updatedAt: "2026-09-21T00:00:00Z"), fetched: .full)

        cache.store(items(["BILLS-119hr1", "BILLS-119hr2"], updatedAt: "2026-09-20T00:00:00Z"), fetched: .windowed(updatedAfter: Date(timeIntervalSinceNow: -7 * 86_400)))

        let cached = cache.items() ?? []
        XCTAssertEqual(cached.map(\.guid).sorted(), ["BILLS-119hr1", "BILLS-119hr2"])
        XCTAssertEqual(cached.first { $0.guid == "BILLS-119hr1" }?.updatedAt, "2026-09-21T00:00:00Z")
    }

    // MARK: - Coverage and the file

    func testCoverageNeedsTheFileItWasRecordedFor() throws {
        cache.store(items(["BILLS-119hr1", "BILLS-119hr2"]), fetched: .full)
        XCTAssertEqual(cache.coverage(), .full)

        // Purged with the rest of Caches.
        DiskJSONCache.removeData(forKey: cache.dataKey)
        XCTAssertNil(cache.coverage())
        XCTAssertFalse(BillsManifestCache.$current.withValue(cache) { BillsService.cachedBillsManifestIsFull() })

        // Replaced by a file of another size.
        cache.store(items(["BILLS-119hr1", "BILLS-119hr2"]), fetched: .full)
        DiskJSONCache.store(Data("[]".utf8), forKey: cache.dataKey)
        XCTAssertNil(cache.coverage())
    }

    func testCopyThatDoesNotDecodeLosesItsCoverage() throws {
        cache.store(items(["BILLS-119hr1"]), fetched: .full)
        let size = try XCTUnwrap(DiskJSONCache.byteCount(forKey: cache.dataKey))
        DiskJSONCache.store(Data(repeating: UInt8(ascii: "x"), count: size), forKey: cache.dataKey)
        XCTAssertEqual(cache.coverage(), .full, "same size: only decoding tells")

        XCTAssertNil(cache.items())

        XCTAssertNil(cache.coverage())
    }

    func testFailedWriteKeepsThePreviousCopyAndItsCoverage() throws {
        cache.store(items(["BILLS-119hr1"]), fetched: .full)
        let cachesDirectory = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        // Mirrors DiskJSONCache's path for a key made of file-name-safe characters.
        let path = cachesDirectory.appendingPathComponent("BillboardJSONCache/\(cache.dataKey).json").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // An immutable file cannot be replaced, so the next write fails.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }

        XCTAssertNil(cache.store(items(["BILLS-119hr2"]), fetched: .windowed(updatedAfter: Date(timeIntervalSinceNow: -7 * 86_400))))

        XCTAssertEqual(cache.items()?.map(\.guid), ["BILLS-119hr1"])
        XCTAssertEqual(cache.coverage(), .full)
    }

    func testWriteRemovesTheLegacyCaches() {
        let defaults = UserDefaults.standard
        defaults.set(Data("[]".utf8), forKey: "\(cache.namespace).data")
        DiskJSONCache.store(Data("[]".utf8), forKey: "\(cache.namespace).data.v3")
        DiskJSONCache.store(Data("[]".utf8), forKey: "\(cache.namespace).data.v4")
        let legacyDefaultsNames = ["timestamp", "timestamp.v3", "coverage.v1", "timestamp.v4", "coverage.v2", "bytes.v1"]
        for key in legacyDefaultsNames {
            defaults.set("legacy", forKey: "\(cache.namespace).\(key)")
        }

        cache.store(items(["BILLS-119hr1"]), fetched: .full)

        XCTAssertNil(defaults.object(forKey: "\(cache.namespace).data"))
        XCTAssertNil(DiskJSONCache.byteCount(forKey: "\(cache.namespace).data.v3"))
        XCTAssertNil(DiskJSONCache.byteCount(forKey: "\(cache.namespace).data.v4"))
        for key in legacyDefaultsNames {
            XCTAssertNil(defaults.object(forKey: "\(cache.namespace).\(key)"), key)
        }
        XCTAssertEqual(
            BillsManifestCache().legacyDefaultsKeys,
            legacyDefaultsNames.map { "BillsService.billsManifest.\($0)" }
        )
        XCTAssertEqual(
            BillsManifestCache().legacyDataKeys,
            ["BillsService.billsManifest.data", "BillsService.billsManifest.data.v3", "BillsService.billsManifest.data.v4"]
        )
    }

    func testCopyWithoutCoverageIsNotFull() {
        cache.store([], fetched: .full)
        UserDefaults.standard.removeObject(forKey: cache.coverageKey)

        XCTAssertNil(cache.coverage())
        XCTAssertFalse(BillsManifestCache.$current.withValue(cache) { BillsService.cachedBillsManifestIsFull() })
    }

    // MARK: - Companion groups (APPF-23)

    /// A manifest with `companionGroups` as House/Senate pairs; nil leaves the field out.
    private func manifest(_ bills: [(guid: String, title: String)], groups: [(String, String)]?) -> Data {
        let items = bills.map { #"{"guid":"\#($0.guid)","billType":"hr","title":"\#($0.title)","updatedAt":"2026-09-20T11:00:00.000Z"}"# }
        let groupsField = groups.map { pairs in
            let list = pairs.map { #"{"primaryGuid":"\#($0.0)","memberGuids":["\#($0.0)","\#($0.1)"],"relationship":"identical"}"# }
            return #","companionGroups":[\#(list.joined(separator: ","))]"#
        } ?? ""
        return Data(#"{"generatedAt":"2026-09-20T12:00:00.000Z","count":\#(bills.count),"bills":[\#(items.joined(separator: ","))]\#(groupsField)}"#.utf8)
    }

    private func cachedMemberLists() -> [[String]]? {
        cached { BillsService.cachedCompanionGroups() }?.map(\.memberGuids)
    }

    @MainActor
    func testCompanionGroupsAreCachedUnderTheirOwnKey() async throws {
        _ = try await getManifest(manifest(bills(2), groups: [("BILLS-119hr1", "BILLS-119s1")]))

        XCTAssertEqual(cachedMemberLists(), [["BILLS-119hr1", "BILLS-119s1"]])
        // The groups carry no vote data, so INT-11's key bump (ManifestCacheUpgradeTests) leaves their file.
        XCTAssertEqual(cache.companionGroupsKey, "\(cache.namespace).companionGroups.v1")
        XCTAssertEqual(cache.dataKey, "\(cache.namespace).data.v5")
        XCTAssertEqual(cache.coverageKey, "\(cache.namespace).coverage.v3")
        XCTAssertEqual(cache.coverage(), .full)
    }

    @MainActor
    func testAResponseWithoutTheFieldKeepsTheCachedGroupsAndAnEmptyListClearsThem() async throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await getManifest(manifest(bills(2), groups: [("BILLS-119hr1", "BILLS-119s1")]))

        _ = try await getManifest(manifest([("BILLS-119hr3", "Three")], groups: nil), updatedAfter: since)
        XCTAssertEqual(cachedMemberLists(), [["BILLS-119hr1", "BILLS-119s1"]], "a missing field keeps the cached list")

        _ = try await getManifest(manifest([("BILLS-119hr3", "Three")], groups: [("BILLS-119hr2", "BILLS-119s2")]), updatedAfter: since)
        XCTAssertEqual(cachedMemberLists(), [["BILLS-119hr2", "BILLS-119s2"]], "a windowed response's list replaces it")

        _ = try await getManifest(manifest([("BILLS-119hr3", "Three")], groups: []), updatedAfter: since)
        XCTAssertEqual(cachedMemberLists(), [], "an empty list clears it")
    }

    func testNoGroupsCachedIsNilAndClearRemovesThem() {
        XCTAssertNil(cache.companionGroups())
        cache.storeCompanionGroups([BillCompanionGroup(primaryGuid: "BILLS-119hr1", memberGuids: ["BILLS-119s1"], relationship: "identical")])
        XCTAssertEqual(cache.companionGroups()?.count, 1)

        cache.clear()

        XCTAssertNil(cache.companionGroups())
    }
}
