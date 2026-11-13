import XCTest
@testable import Billboard

@MainActor
final class VoterMapJoinTests: XCTestCase {
    func testCanonicalDistrictRegionIDWithFullCode() {
        XCTAssertEqual(
            VoterMapStyling.canonicalDistrictRegionID(stateCode: "CA", rawDistrict: "CA-12"),
            "CA-12"
        )
    }

    func testCanonicalDistrictRegionIDWithNumericOnly() {
        XCTAssertEqual(
            VoterMapStyling.canonicalDistrictRegionID(stateCode: "CA", rawDistrict: "12"),
            "CA-12"
        )
    }

    func testCanonicalDistrictRegionIDWithCompactStatePrefix() {
        XCTAssertEqual(
            VoterMapStyling.canonicalDistrictRegionID(stateCode: "CA", rawDistrict: "CA12"),
            "CA-12"
        )
    }

    func testCanonicalDistrictRegionIDWithAtLargeTokens() {
        XCTAssertEqual(
            VoterMapStyling.canonicalDistrictRegionID(stateCode: "AK", rawDistrict: "AL"),
            "AK-AL"
        )
        XCTAssertEqual(
            VoterMapStyling.canonicalDistrictRegionID(stateCode: "AK", rawDistrict: "00"),
            "AK-AL"
        )
        XCTAssertEqual(
            VoterMapStyling.canonicalDistrictRegionID(stateCode: "AK", rawDistrict: "At-Large"),
            "AK-AL"
        )
    }

    func testCanonicalDistrictRegionIDRejectsInvalidInput() {
        XCTAssertNil(VoterMapStyling.canonicalDistrictRegionID(stateCode: "C", rawDistrict: "12"))
        XCTAssertNil(VoterMapStyling.canonicalDistrictRegionID(stateCode: "CA", rawDistrict: ""))
        XCTAssertNil(VoterMapStyling.canonicalDistrictRegionID(stateCode: "CA", rawDistrict: "unknown"))
    }

    // MARK: - Region names in the selection card (spec D 2.2)

    func testSelectionNamesAStateInFullAndADistrictByItsNumber() {
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "CA", label: "CA"), "California")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "CA-12", label: "CA-12"), "CA-12")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "CA-02", label: "CA-02"), "CA-2")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "AK-AL", label: "AK-AL"), "AK at-large")
    }

    func testARollupJoinsItsCanonicalRegionAndKeepsItsCounts() throws {
        let data = Data(#"{"votes":11,"yea":5,"nay":4,"abstain":2,"decisionVotes":9,"yeaPct":55.6}"#.utf8)
        let totals = try JSONDecoder.convertingFromSnakeCase().decode(BillStatsService.VoteTotals.self, from: data)
        let id = try XCTUnwrap(VoterMapStyling.canonicalDistrictRegionID(stateCode: "VA", rawDistrict: "11"))
        let stat = VoterMapRegionStat(id: id, label: id, totals: totals)
        XCTAssertEqual(stat.id, "VA-11")
        XCTAssertEqual(stat.abstainVotes, 2)
        XCTAssertEqual(
            VoteResultsFormatting.mapSelectionText(
                name: VoteResultsFormatting.regionDisplayName(id: stat.id, label: stat.label),
                yeaPct: stat.yeaPct,
                yea: stat.yea,
                nay: stat.nay,
                decisionVotes: stat.decisionVotes,
                floor: 5
            ),
            "VA-11 · 56% Yea · 44% Nay · 9 verified votes"
        )
    }
}
