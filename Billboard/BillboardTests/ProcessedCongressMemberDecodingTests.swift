import XCTest
@testable import Billboard

/// `CongressService.decodeProcessedCongressMember(from:)` reads `GET /processed-congress-members`.
/// The synced contract decodes a district sent as a number, so House members now take the
/// contract path (like senators) instead of falling through to the flexible decoder,
/// which drops their terms.
final class ProcessedCongressMemberDecodingTests: XCTestCase {
    private let houseMember = Data(#"""
    {
      "bioguideId": "P000197",
      "name": "Nancy Pelosi",
      "chamber": "House of Representatives",
      "state": "California",
      "stateCode": "CA",
      "district": 11,
      "party": "Democratic",
      "terms": [
        {"chamber": "House of Representatives", "congress": 118, "district": 11, "startYear": 2023, "endYear": 2025, "stateCode": "CA"},
        {"chamber": "House of Representatives", "congress": 119, "district": 11, "startYear": 2025, "stateCode": "CA"}
      ]
    }
    """#.utf8)

    @MainActor
    func testHouseMemberWithNumericDistrictKeepsTerms() throws {
        let member = try CongressService.decodeProcessedCongressMember(from: houseMember)

        XCTAssertEqual(member.bioguideId, "P000197")
        XCTAssertEqual(member.district, "11")
        XCTAssertEqual(member.terms?.count, 2)
        XCTAssertEqual(member.terms?.map(\.district), ["11", "11"])
        XCTAssertEqual(member.termsServed, 2)
        XCTAssertEqual(member.serviceStartYear, 2023)
    }

    @MainActor
    func testFlexibleDecoderDropsTermsWithNumericDistricts() throws {
        // The fallback the House path used before the contract sync.
        let flexible = try JSONDecoder.convertingFromSnakeCase().decode(ProcessedCongressMember.self, from: houseMember)

        XCTAssertEqual(flexible.district, "11")
        XCTAssertNil(flexible.terms)
    }

    @MainActor
    func testSenatorWithNullDistrictDecodes() throws {
        let senator = Data(#"""
        {"bioguideId": "S000148", "name": "Charles E. Schumer", "chamber": "Senate", "state": "New York", "district": null,
         "terms": [{"chamber": "Senate", "startYear": 1999, "stateCode": "NY", "district": null}]}
        """#.utf8)

        let member = try CongressService.decodeProcessedCongressMember(from: senator)

        XCTAssertNil(member.district)
        XCTAssertEqual(member.chamber, "Senate")
        XCTAssertEqual(member.terms?.count, 1)
        XCTAssertEqual(member.serviceStartYear, 1999)
    }

    @MainActor
    func testMemberUnderAWrapperKeyDecodes() throws {
        let wrapped = Data(#"{"member": {"bioguideId": "A000370", "name": "Alma Adams", "district": "12"}}"#.utf8)

        let member = try CongressService.decodeProcessedCongressMember(from: wrapped)

        XCTAssertEqual(member.bioguideId, "A000370")
        XCTAssertEqual(member.district, "12")
    }

    @MainActor
    func testUnknownShapeIsRejected() {
        XCTAssertThrowsError(try CongressService.decodeProcessedCongressMember(from: Data(#"{"members": []}"#.utf8))) { error in
            XCTAssertEqual(error as? APIServiceError, .invalidPayload("processed-congress-members"))
        }
    }

    @MainActor
    func testRequestUsesTheUppercasedBioguideId() async throws {
        let transport = RecordingTransport()
        transport.responses = [houseMember]

        let member = try await APIClient.$current.withValue(transport.client) {
            try await CongressService.getProcessedCongressMember(bioguideId: "p000197")
        }

        XCTAssertEqual(member.terms?.count, 2)
        XCTAssertEqual(
            transport.requests,
            [
                APIClient.Request(
                    method: .get,
                    path: "processed-congress-members",
                    queryParameters: ["bioguideId": "P000197"],
                    body: nil,
                    label: "CongressService processed-congress-members",
                    authMode: .autoFetch,
                    traceTimeline: false
                )
            ]
        )
    }
}

/// APPF-03: BillBoard's tracked 119th Congress counts (`trackedSponsoredCount` /
/// `trackedSupportedCount`) reach the member profile as their own rows, apart from the
/// Congress.gov career totals.
final class CongressMemberTrackedCountsTests: XCTestCase {
    @MainActor
    private func manifestItem(_ json: String) throws -> CongressMemberManifestItem {
        try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data(json.utf8))
    }

    private func rows(_ rows: [(label: String, value: String)]) -> [String] {
        rows.map { "\($0.label)=\($0.value)" }
    }

    @MainActor
    func testTrackedCountsAreShownApartFromCareerTotals() throws {
        let payload = Data(#"""
        {"bioguideId": "K000384", "name": "Tim Kaine", "chamber": "Senate", "state": "VA", "district": null,
         "sponsoredLegislationCount": 654, "cosponsoredLegislationCount": 2956,
         "currentCongressBillsSupportedCount": 186, "trackedSponsoredCount": 36, "trackedSupportedCount": 186}
        """#.utf8)
        let manifest = try manifestItem(#"{"bioguideId": "K000384", "name": "Tim Kaine", "chamber": "Senate"}"#)

        let processed = try CongressService.decodeProcessedCongressMember(from: payload)
        XCTAssertEqual(processed.trackedSponsoredCount, 36)
        XCTAssertEqual(processed.trackedSupportedCount, 186)

        let member = processed.toCongressMember(fallback: manifest)
        XCTAssertEqual(rows(member.careerActivityRows), ["Proposed Legislation=654", "Supported Legislation=2956"])
        XCTAssertEqual(rows(member.trackedActivityRows), ["Sponsored in 119th Congress=36", "Supported in 119th Congress=186"])
    }

    @MainActor
    func testPayloadWithoutTrackedCountsKeepsTheSupportedRow() throws {
        // Services before APPF-03 send only currentCongressBillsSupportedCount.
        let payload = Data(#"{"bioguideId": "K000384", "name": "Tim Kaine", "currentCongressBillsSupportedCount": 5}"#.utf8)
        let manifest = try manifestItem(#"{"bioguideId": "K000384", "name": "Tim Kaine"}"#)

        let member = try CongressService.decodeProcessedCongressMember(from: payload).toCongressMember(fallback: manifest)

        XCTAssertEqual(rows(member.trackedActivityRows), ["Supported in 119th Congress=5"])
        XCTAssertTrue(member.careerActivityRows.isEmpty)
    }

    @MainActor
    func testManifestTrackedCountsFillAPayloadWithoutThem() throws {
        let payload = Data(#"{"bioguideId": "K000384", "name": "Tim Kaine", "currentCongressBillsSupportedCount": 0}"#.utf8)
        let manifest = try manifestItem(#"{"bioguideId": "K000384", "name": "Tim Kaine", "trackedSponsoredCount": 2, "trackedSupportedCount": 4}"#)

        let member = try CongressService.decodeProcessedCongressMember(from: payload).toCongressMember(fallback: manifest)

        XCTAssertEqual(rows(member.trackedActivityRows), ["Sponsored in 119th Congress=2", "Supported in 119th Congress=4"])
    }

    @MainActor
    func testFlexibleDecoderReadsTrackedCounts() throws {
        // No `name`, so the contract shape fails and the flexible decoder reads it.
        let payload = Data(#"{"id": "K000384", "trackedSponsoredCount": 3, "trackedSupportedCount": 0}"#.utf8)

        let processed = try CongressService.decodeProcessedCongressMember(from: payload)

        XCTAssertEqual(processed.bioguideId, "K000384")
        XCTAssertEqual(processed.trackedSponsoredCount, 3)
        XCTAssertEqual(processed.trackedSupportedCount, 0)
    }

    @MainActor
    func testManifestItemMapsAndCachesTrackedCounts() throws {
        let dto = try JSONDecoder().decode(
            UserAPIContractsV1.CongressMemberManifestItem.self,
            from: Data(#"{"bioguideId": "A1", "name": "A", "chamber": "House", "state": "VA", "party": "D", "district": "11", "trackedSponsoredCount": 1, "trackedSupportedCount": 3}"#.utf8)
        )
        let item = CongressMemberManifestItem(dto: dto)
        XCTAssertEqual(item.district, "11")
        XCTAssertEqual(item.trackedSponsoredCount, 1)
        XCTAssertEqual(item.trackedSupportedCount, 3)

        let cached = try JSONDecoder().decode(CongressMemberManifestItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(cached, item)
    }
}
