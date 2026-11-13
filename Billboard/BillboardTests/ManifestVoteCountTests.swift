import XCTest
@testable import Billboard

/// INT-11: the Bills list never ranks by other users' votes, and the app stops reading the manifest's
/// `voteCount`. Order is an active priority ("In the news") first, then its rank, then the newest, then
/// title and guid. A manifest, a manifest cache file or a bills cache file that still carries counts
/// (an old server, a snapshot published before the change, a cache written by 1.1) decodes as before;
/// the count is ignored and the next write drops it.
final class ManifestVoteCountTests: XCTestCase {
    private static func iso(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    /// Counts that, if they still counted, would put the oldest bills first.
    private static let updated = (old: iso(daysAgo: 3), middle: iso(daysAgo: 2), new: iso(daysAgo: 1))

    private static var manifestJSON: String {
        func item(_ guid: String, title: String, updatedAt: String, votes: Int, priorityRank: Int? = nil) -> String {
            let priority = priorityRank.map { #""isPriority":true,"priorityRank":\#($0),"# } ?? ""
            return #"{"guid":"\#(guid)","congress":"119","billType":"hr","billID":"\#(guid.dropFirst(11))","#
                + #""updatedAt":"\#(updatedAt)","subCategories":["Energy"],"lifeAreas":[],"sponsors":[],"cosponsors":[],"#
                + #""voteCount":\#(votes),"# + priority + #""title":"\#(title)","billStatus":"New"}"#
        }
        let items = [
            item("BILLS-119hr1", title: "Oldest, most voted", updatedAt: updated.old, votes: 900),
            item("BILLS-119hr2", title: "Newest, no votes", updatedAt: updated.new, votes: 0),
            item("BILLS-119hr3", title: "Bravo", updatedAt: updated.middle, votes: 40),
            item("BILLS-119hr4", title: "Alpha", updatedAt: updated.middle, votes: 2),
            item("BILLS-119hr5", title: "In the news, rank 2", updatedAt: updated.old, votes: 0, priorityRank: 2),
            item("BILLS-119hr6", title: "In the news, rank 1", updatedAt: updated.old, votes: 0, priorityRank: 1),
            item("BILLS-119hr7", title: "Alpha", updatedAt: updated.middle, votes: 300)
        ]
        return #"{"generatedAt":"\#(updated.new)","count":\#(items.count),"bills":[\#(items.joined(separator: ","))]}"#
    }

    private static func decodedItems() throws -> [BillsManifestItem] {
        try JSONDecoder().decode(BillsManifest.self, from: Data(manifestJSON.utf8)).bills
    }

    /// Priority by rank, then newest, then title, then guid: never the count.
    private static let expectedOrder = [
        "BILLS-119hr6", "BILLS-119hr5",                   // in the news, by rank
        "BILLS-119hr2",                                   // the newest
        "BILLS-119hr4", "BILLS-119hr7", "BILLS-119hr3",   // a day older: Alpha (hr4, hr7 by guid), Bravo
        "BILLS-119hr1"                                    // the oldest, though most voted
    ]

    // MARK: - Decoding

    func testAManifestWithVoteCountsDecodesAndNothingKeepsTheCount() throws {
        let items = try Self.decodedItems()
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.first?.title, "Oldest, most voted")

        let encoded = try JSONEncoder().encode(items)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("voteCount"), "the cache never writes a count")

        let bills = items.map(BillsStore.placeholderBill(from:))
        let encodedBills = try JSONEncoder().encode(bills)
        XCTAssertFalse(String(decoding: encodedBills, as: UTF8.self).contains("voteCount"), "a bill carries no count")
    }

    func testTheContractItemStillDecodesACountAndTheAppDropsIt() throws {
        // The generated contract keeps the optional field (deprecated); the app's own model has none.
        let json = #"{"guid":"BILLS-119hr9","billType":"hr","title":"A bill","voteCount":12,"updatedAt":"2026-10-01T00:00:00.000Z"}"#
        let dto = try JSONDecoder().decode(UserAPIContractsV1.BillsManifestItem.self, from: Data(json.utf8))
        XCTAssertEqual(dto.voteCount, 12)
        let item = BillsManifestItem(dto: dto)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("voteCount"))
    }

    // MARK: - Order

    func testRankBillsForBoardOrdersByPriorityThenNewestThenTitleAndGuid() throws {
        let bills = try Self.decodedItems().map(BillsStore.placeholderBill(from:))
        XCTAssertEqual(rankBillsForBoard(bills).map(\.guid), Self.expectedOrder)
        XCTAssertEqual(rankBillsForBoard(bills.reversed()).map(\.guid), Self.expectedOrder, "independent of input order")
    }

    func testTheCapKeepsTheNewestBillsNotTheMostVoted() throws {
        let bills = try Self.decodedItems().map(BillsStore.placeholderBill(from:))
        let kept = BillsStore.capBills(bills, limit: 3)
        XCTAssertEqual(Set(kept.compactMap(\.guid)), ["BILLS-119hr6", "BILLS-119hr5", "BILLS-119hr2"])
    }

    func testCompanionRankValuesOrderByPriorityThenNewestThenTitle() throws {
        let bills = try Self.decodedItems().map(BillsStore.placeholderBill(from:))
        let ranked = bills
            .map { (values: CompanionRankValues(bills: [$0]), bill: $0) }
            .sorted(by: CompanionRankValues.ranksBefore)
            .map(\.bill.guid)
        XCTAssertEqual(ranked, Self.expectedOrder, "matches rankBillsForBoard for single bills")
    }

    func testTheManifestCacheOrdersByPriorityThenNewestThenGuid() throws {
        let sorted = try Self.decodedItems()
            .map { (key: BillsManifestCache.SortKey(item: $0), guid: $0.guid) }
            .sorted { $0.key < $1.key }
            .map(\.guid)
        // The cache has no titles in its key: equal dates fall back to the guid.
        XCTAssertEqual(sorted, [
            "BILLS-119hr6", "BILLS-119hr5", "BILLS-119hr2", "BILLS-119hr3", "BILLS-119hr4", "BILLS-119hr7", "BILLS-119hr1"
        ])
    }

    // MARK: - Old cache files

    func testAnOldManifestCacheFileWithCountsReadsAndTheNextWriteDropsThem() throws {
        let cache = BillsManifestCache(namespace: "manifest-vote-count-tests-\(UUID().uuidString)")
        addTeardownBlock { cache.clear() }
        // The items array as 1.1 wrote it, counts included.
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.manifestJSON.utf8)) as? [String: Any])
        let oldFile = try JSONSerialization.data(withJSONObject: try XCTUnwrap(manifest["bills"]))
        XCTAssertTrue(String(decoding: oldFile, as: UTF8.self).contains("\"voteCount\":900"), "precondition")
        XCTAssertTrue(DiskJSONCache.store(oldFile, forKey: cache.dataKey))

        let read = try XCTUnwrap(cache.items(), "an old file still decodes")
        XCTAssertEqual(read.count, 7)

        XCTAssertEqual(cache.store(read, fetched: .full), .full)
        let written = try XCTUnwrap(DiskJSONCache.data(forKey: cache.dataKey))
        XCTAssertFalse(String(decoding: written, as: UTF8.self).contains("voteCount"))
        XCTAssertEqual(try XCTUnwrap(cache.items()).map(\.guid), [
            "BILLS-119hr6", "BILLS-119hr5", "BILLS-119hr2", "BILLS-119hr3", "BILLS-119hr4", "BILLS-119hr7", "BILLS-119hr1"
        ])
    }

    func testAnOldBillsCacheFileWithCountsStillRestores() throws {
        let scope = "manifest-vote-count-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let bills = try Self.decodedItems().map(BillsStore.placeholderBill(from:))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Each bill as 1.1 cached it, with its manifest count.
        var objects = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(bills)) as? [[String: Any]])
        for index in objects.indices {
            objects[index]["voteCount"] = 1_000 - index
        }
        XCTAssertTrue(DiskJSONCache.store(
            try JSONSerialization.data(withJSONObject: objects),
            forKey: ScopedStorageKey.make(base: "BillsStore.bills.data", scope: scope)
        ))

        let restored = try XCTUnwrap(BillsStore.cachedBills(scope: scope), "an old file still decodes")

        XCTAssertEqual(restored.map(\.guid), bills.map(\.guid))
        XCTAssertEqual(rankBillsForBoard(restored).map(\.guid), Self.expectedOrder)
        XCTAssertFalse(String(decoding: try encoder.encode(restored), as: UTF8.self).contains("voteCount"), "the next write drops it")
    }
}
