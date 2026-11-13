import XCTest
@testable import Billboard

/// `CongressService.congressMember(for:)` resolves a bill card's sponsor from the cached members
/// manifest. Every card makes the call, and each used to read and decode the whole members file, which
/// made search results and bill lists slow; the service now keeps an in-memory index of the manifest.
/// The tests write the live manifest cache and put back what was there.
@MainActor
final class CongressServiceMemberLookupTests: XCTestCase {
    // Mirror CongressService's private cache keys.
    private static let manifestDataKey = "CongressService.congressMembersManifest.data"
    private static let manifestTimestampKey = "CongressService.congressMembersManifest.timestamp"

    private var savedCache = false

    private func member(
        _ id: String,
        _ name: String,
        chamber: String,
        state: String,
        district: String? = nil,
        party: String
    ) throws -> CongressMemberManifestItem {
        var fields = [
            #""bioguideId":"\#(id)""#,
            #""name":"\#(name)""#,
            #""chamber":"\#(chamber)""#,
            #""state":"\#(state)""#,
            #""party":"\#(party)""#,
            #""currentCongressBillsSupportedCount":12"#
        ]
        if let district {
            fields.append(#""district":"\#(district)""#)
        }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data(json.utf8))
    }

    private func sponsorID(_ id: String) -> UUID {
        UUID.deterministic(from: id)
    }

    /// Caches `items` as the members manifest (which drops the index), and puts back what was cached
    /// before the test when it ends.
    private func cacheManifest(_ items: [CongressMemberManifestItem]) {
        if !savedCache {
            savedCache = true
            let previousItems = CongressService.cachedCongressMembersManifest()
            let previousTimestamp = UserDefaults.standard.object(forKey: Self.manifestTimestampKey)
            addTeardownBlock {
                if let previousItems {
                    CongressService.cacheCongressMembersManifest(previousItems)
                } else {
                    // Caching drops the index; then the file goes, so nothing is left to find.
                    CongressService.cacheCongressMembersManifest([])
                    DiskJSONCache.removeData(forKey: Self.manifestDataKey)
                }
                if let previousTimestamp {
                    UserDefaults.standard.set(previousTimestamp, forKey: Self.manifestTimestampKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.manifestTimestampKey)
                }
            }
        }
        CongressService.cacheCongressMembersManifest(items)
    }

    private func roster() throws -> [CongressMemberManifestItem] {
        [
            try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D"),
            try member("W000805", "Mark R. Warner", chamber: "Senate", state: "VA", party: "Democratic"),
            try member("B001292", "Donald S. Beyer, Jr.", chamber: "House of Representatives", state: "VA", district: "8", party: "D"),
            try member("W000804", "Robert J. Wittman", chamber: "House of Representatives", state: "VA", district: "1", party: "R")
        ]
    }

    func testLookupBuildsTheMemberFromItsManifestItem() throws {
        cacheManifest(try roster())

        let beyer = try XCTUnwrap(CongressService.congressMember(for: sponsorID("B001292")))
        XCTAssertEqual(beyer.id, sponsorID("B001292"))
        XCTAssertEqual(beyer.name, "Donald S. Beyer, Jr.")
        XCTAssertEqual(beyer.state, "VA")
        XCTAssertEqual(beyer.chamber, "House")
        XCTAssertEqual(beyer.party, .democratic)
        XCTAssertEqual(beyer.district, "8")
        XCTAssertEqual(beyer.currentCongressBillsSupportedCount, 12)
        XCTAssertEqual(beyer.biography, "")
        XCTAssertEqual(beyer.termsServed, 0)
        XCTAssertEqual(beyer.serviceStartYear, Calendar.current.component(.year, from: Date()))

        let kaine = try XCTUnwrap(CongressService.congressMember(for: sponsorID("K000384")))
        XCTAssertEqual(kaine.chamber, "Senate")
        XCTAssertNil(kaine.district)
        XCTAssertEqual(try XCTUnwrap(CongressService.congressMember(for: sponsorID("W000804"))).party, .republican)
    }

    func testAMemberNotInTheManifestIsNotFound() throws {
        cacheManifest(try roster())

        XCTAssertNil(CongressService.congressMember(for: sponsorID("Z000000")))
        XCTAssertNil(CongressService.congressMember(for: UUID()))
    }

    /// The first lookup builds the index; the ones after it must not read the file, which the old code
    /// did for each call. The file is replaced behind the service's back to show that none does.
    func testLookupsAfterTheFirstDoNotReadTheFileAgain() throws {
        cacheManifest(try roster())
        XCTAssertEqual(CongressService.congressMember(for: sponsorID("K000384"))?.name, "Tim Kaine")

        XCTAssertTrue(DiskJSONCache.store(Data("[]".utf8), forKey: Self.manifestDataKey))

        XCTAssertEqual(CongressService.congressMember(for: sponsorID("K000384"))?.name, "Tim Kaine")
        XCTAssertEqual(CongressService.congressMember(for: sponsorID("W000805"))?.name, "Mark R. Warner")
        XCTAssertEqual(CongressService.congressMember(for: sponsorID("B001292"))?.name, "Donald S. Beyer, Jr.")
        for _ in 0..<500 {
            XCTAssertNotNil(CongressService.congressMember(for: sponsorID("W000804")))
        }
    }

    func testCachingANewManifestReplacesTheIndexedMembers() throws {
        cacheManifest(try roster())
        XCTAssertNotNil(CongressService.congressMember(for: sponsorID("K000384")))

        cacheManifest([
            try member("W000805", "Mark R. Warner", chamber: "Senate", state: "VA", party: "D"),
            try member("V000128", "Chris Van Hollen", chamber: "Senate", state: "MD", party: "D")
        ])

        XCTAssertNil(CongressService.congressMember(for: sponsorID("K000384")), "no longer in the manifest")
        XCTAssertEqual(CongressService.congressMember(for: sponsorID("V000128"))?.state, "MD")
        XCTAssertEqual(CongressService.congressMember(for: sponsorID("W000805"))?.name, "Mark R. Warner")
    }

    func testWithoutACachedManifestNothingIsFoundAndTheNextWriteIsPickedUp() throws {
        cacheManifest([])
        DiskJSONCache.removeData(forKey: Self.manifestDataKey)
        XCTAssertNil(CongressService.cachedCongressMembersManifest())

        XCTAssertNil(CongressService.congressMember(for: sponsorID("K000384")))
        XCTAssertNil(CongressService.congressMember(for: sponsorID("K000384")), "still nothing, still no crash")

        cacheManifest(try roster())

        XCTAssertEqual(CongressService.congressMember(for: sponsorID("K000384"))?.name, "Tim Kaine")
    }

    func testAnUnreadableManifestFileFindsNothing() throws {
        cacheManifest(try roster())
        XCTAssertNotNil(CongressService.congressMember(for: sponsorID("K000384")))
        // A write that goes through the service drops the index; an unreadable file then has no members.
        cacheManifest([])
        XCTAssertTrue(DiskJSONCache.store(Data("not json".utf8), forKey: Self.manifestDataKey))

        XCTAssertNil(CongressService.congressMember(for: sponsorID("K000384")))
    }

    /// `first(where:)` returned the first item when two had the same id; the index keeps that item.
    func testWhenTwoItemsShareAnIDTheFirstOneWins() throws {
        cacheManifest([
            try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D"),
            try member("K000384", "Timothy Kaine", chamber: "Senate", state: "VA", party: "D"),
            try member("W000805", "Mark R. Warner", chamber: "Senate", state: "VA", party: "D")
        ])

        XCTAssertEqual(CongressService.congressMember(for: sponsorID("K000384"))?.name, "Tim Kaine")
        XCTAssertEqual(CongressService.congressMember(for: sponsorID("W000805"))?.name, "Mark R. Warner")
    }
}
