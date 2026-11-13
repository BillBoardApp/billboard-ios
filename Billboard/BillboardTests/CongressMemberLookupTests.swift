import XCTest
@testable import Billboard

/// `CongressService.congressMember(for:)`, which every bill card calls for its sponsor: it reads an
/// in-memory index of the cached members manifest, built from the cache file on first use and dropped when
/// the manifest is written, instead of decoding the file for each card. The manifest cache is not scoped,
/// so each test starts without one and puts back the one that was there.
final class CongressMemberLookupTests: XCTestCase {
    // Mirror CongressService's private cache keys.
    private static let dataKey = "CongressService.congressMembersManifest.data"
    private static let timestampKey = "CongressService.congressMembersManifest.timestamp"

    private static let pelosi = "P000197"
    private static let schumer = "S000148"
    private static let adams = "A000370"

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

    private func memberJSON(id: String, name: String) -> String {
        #"{"bioguideId":"\#(id)","name":"\#(name)","chamber":"House of Representatives","state":"CA","party":"Democratic","district":"11","depictionImageUrl":"https://example.test/\#(id).jpg","currentCongressBillsSupportedCount":12}"#
    }

    /// Fetches the manifest `members` through the service, which caches it.
    @MainActor
    private func fetchAndCache(_ members: [(id: String, name: String)]) async throws {
        let members = members.map { memberJSON(id: $0.id, name: $0.name) }.joined(separator: ",")
        let transport = RecordingTransport()
        transport.responses = [Data(#"{"generatedAt":"2026-10-14T00:00:00Z","count":0,"members":[\#(members)]}"#.utf8)]
        _ = try await APIClient.$current.withValue(transport.client) {
            try await CongressService.getCongressMembersManifest()
        }
    }

    /// Writes the cache file with one member, without going through the service, so the index is not told.
    @MainActor
    private func writeCacheFile(id: String, name: String) throws {
        let items = try JSONDecoder().decode([CongressMemberManifestItem].self, from: Data("[\(memberJSON(id: id, name: name))]".utf8))
        DiskJSONCache.store(try JSONEncoder().encode(items), forKey: Self.dataKey)
    }

    private func storedID(_ bioguideID: String) -> UUID {
        UUID.deterministic(from: bioguideID)
    }

    // MARK: - Lookups

    @MainActor
    func testLookupResolvesTheMemberFromTheCachedManifest() async throws {
        try await fetchAndCache([(Self.pelosi, "Nancy Pelosi"), (Self.schumer, "Charles E. Schumer")])

        let member = try XCTUnwrap(CongressService.congressMember(for: storedID(Self.pelosi)))

        XCTAssertEqual(member.id, storedID(Self.pelosi))
        XCTAssertEqual(member.name, "Nancy Pelosi")
        XCTAssertEqual(member.state, "CA")
        XCTAssertEqual(member.chamber, "House")
        XCTAssertEqual(member.party, .democratic)
        XCTAssertEqual(member.district, "11")
        XCTAssertEqual(member.imageUrl, URL(string: "https://example.test/\(Self.pelosi).jpg"))
        XCTAssertEqual(member.currentCongressBillsSupportedCount, 12)
        XCTAssertNil(CongressService.congressMember(for: storedID(Self.adams)))
        XCTAssertNil(CongressService.congressMember(for: UUID()))
    }

    @MainActor
    func testLookupsAfterTheFirstDoNotReadTheCacheFile() async throws {
        try await fetchAndCache([(Self.pelosi, "Nancy Pelosi"), (Self.schumer, "Charles E. Schumer")])
        XCTAssertNotNil(CongressService.congressMember(for: storedID(Self.pelosi)))

        // With the file gone, only a lookup that still reads it comes back empty.
        DiskJSONCache.removeData(forKey: Self.dataKey)

        XCTAssertEqual(CongressService.congressMember(for: storedID(Self.pelosi))?.name, "Nancy Pelosi")
        XCTAssertEqual(CongressService.congressMember(for: storedID(Self.schumer))?.name, "Charles E. Schumer")
        XCTAssertNil(CongressService.congressMember(for: storedID(Self.adams)))
    }

    @MainActor
    func testManifestItemLookupReadsTheIndexToo() async throws {
        try await fetchAndCache([(Self.pelosi, "Nancy Pelosi"), (Self.schumer, "Charles E. Schumer")])
        XCTAssertEqual(CongressService.cachedMemberManifestItem(for: storedID(Self.schumer))?.id, Self.schumer)

        // With the file gone, only a lookup that still reads it comes back empty.
        DiskJSONCache.removeData(forKey: Self.dataKey)

        XCTAssertEqual(CongressService.cachedMemberManifestItem(for: storedID(Self.pelosi))?.name, "Nancy Pelosi")
        XCTAssertNil(CongressService.cachedMemberManifestItem(for: storedID(Self.adams)))
    }

    @MainActor
    func testTheIndexIsBuiltFromTheCacheFileOnFirstUse() throws {
        try writeCacheFile(id: Self.adams, name: "Alma S. Adams")

        XCTAssertEqual(CongressService.congressMember(for: storedID(Self.adams))?.name, "Alma S. Adams")
    }

    @MainActor
    func testNoCachedManifestIsNotRemembered() throws {
        XCTAssertNil(CongressService.congressMember(for: storedID(Self.adams)))

        try writeCacheFile(id: Self.adams, name: "Alma S. Adams")

        XCTAssertEqual(CongressService.congressMember(for: storedID(Self.adams))?.name, "Alma S. Adams")
    }

    @MainActor
    func testCachingANewManifestReplacesTheIndex() async throws {
        try await fetchAndCache([(Self.pelosi, "Nancy Pelosi")])
        XCTAssertNotNil(CongressService.congressMember(for: storedID(Self.pelosi)))

        try await fetchAndCache([(Self.adams, "Alma S. Adams")])

        XCTAssertNil(CongressService.congressMember(for: storedID(Self.pelosi)), "no longer in the manifest")
        XCTAssertEqual(CongressService.congressMember(for: storedID(Self.adams))?.name, "Alma S. Adams")
    }

    @MainActor
    func testTheFirstOfTwoMembersWithTheSameStoredIDIsFound() async throws {
        // The stored ID sums the bytes of the ID by position modulo 16, so IDs longer than 16 characters
        // can collide: "A" + "D" and "B" + "C" at positions 0 and 16 both add up to 133.
        let first = "AXXXXXXXXXXXXXXXD"
        let second = "BXXXXXXXXXXXXXXXC"
        XCTAssertEqual(storedID(first), storedID(second))
        try await fetchAndCache([(first, "First Member"), (second, "Second Member")])

        XCTAssertEqual(CongressService.congressMember(for: storedID(second))?.name, "First Member")
        XCTAssertEqual(CongressService.cachedMemberManifestItem(for: storedID(second))?.id, first)
    }
}
