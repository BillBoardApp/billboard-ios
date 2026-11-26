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

    /// A record that doesn't say how long the member has served leaves it unknown, and the page shows no Service
    /// section (UX-39c), rather than "Terms served 0 · Service start <this year>". One that does keeps its figures.
    @MainActor
    func testServiceHistoryIsNeverGuessed() throws {
        let manifest = try manifestItem(#"{"bioguideId": "K000384", "name": "Tim Kaine", "chamber": "Senate"}"#)
        for payload in [
            #"{"bioguideId": "K000384", "name": "Tim Kaine", "chamber": "Senate"}"#,
            #"{"bioguideId": "K000384", "name": "Tim Kaine", "chamber": "Senate", "termsServed": 0, "terms": []}"#
        ] {
            let member = try CongressService.decodeProcessedCongressMember(from: Data(payload.utf8)).toCongressMember(fallback: manifest)
            XCTAssertNil(member.termsServed, payload)
            XCTAssertNil(member.serviceStartYear, payload)
            XCTAssertEqual(CongressMemberPageContent(member: member, civicProfileMode: .unavailable).serviceRows, [], payload)
        }

        let served = Data(#"""
        {"bioguideId": "K000384", "name": "Tim Kaine", "chamber": "Senate",
         "terms": [{"chamber": "Senate", "startYear": 2013, "endYear": 2019, "stateCode": "VA"},
                   {"chamber": "Senate", "startYear": 2019, "stateCode": "VA"}]}
        """#.utf8)
        let house = try CongressService.decodeProcessedCongressMember(from: served).toCongressMember(fallback: manifest)
        XCTAssertEqual(house.termsServed, 2)
        XCTAssertEqual(house.serviceStartYear, 2013)
        XCTAssertEqual(
            CongressMemberPageContent(member: house, civicProfileMode: .unavailable).serviceRows.map(\.label),
            ["Terms served", "Service start", "Years in office"]
        )
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

/// REL-46 A6: the member page's tracked counts name the Congress that the server's `currentCongressCounts` covers
/// (the newest Congress the member has counts in, else the 119th), never one computed from the date. Without the
/// field, the 119th Congress counts keep their 119th labels, and a member new in the 120th Congress, who sends no
/// 119th counts, still has counts.
final class CongressMemberCongressCountsTests: XCTestCase {
    /// contracts/fixtures/entities/processed-congress-member.v1.valid.json in billboard-backend (main 9973fd2).
    private static let processedFixture = #"""
    {
      "bioguideId": "D000001",
      "name": "Jane Doe",
      "firstName": "Jane",
      "lastName": "Doe",
      "directOrderName": "Jane Doe",
      "chamber": "House of Representatives",
      "state": "CA",
      "district": "12",
      "party": "Democratic",
      "partyAbbreviation": "D",
      "partyName": "Democratic",
      "depictionImageUrl": "https://example.com/members/D000001.jpg",
      "sponsoredLegislationCount": 12,
      "cosponsoredLegislationCount": 84,
      "currentCongressBillsSupportedCount": 9,
      "trackedSponsoredCount": 2,
      "trackedSupportedCount": 9,
      "currentCongressCounts": { "congress": 119, "sponsored": 2, "supported": 9 },
      "termCount": 3,
      "congress": 119,
      "memberType": "Representative",
      "startYear": 2021,
      "stateCode": "CA",
      "stateName": "California",
      "updateDate": "2026-03-05T12:00:00.000Z",
      "terms": [
        {
          "chamber": "House of Representatives",
          "memberType": "Representative",
          "congress": 119,
          "district": 12,
          "startYear": 2025,
          "endYear": 2027,
          "stateCode": "CA",
          "stateName": "California"
        }
      ]
    }
    """#

    /// contracts/fixtures/entities/congress-member-manifest.v1.valid.json in billboard-backend (main 9973fd2).
    private static let manifestFixture = #"""
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
    """#

    /// The processed-member fixture with `removing` left out and `setting` put in.
    private func processedPayload(removing: [String] = [], setting: [String: Any] = [:]) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.processedFixture.utf8)) as? [String: Any])
        for key in removing { object.removeValue(forKey: key) }
        object.merge(setting) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @MainActor
    private func manifestItem(_ json: String) throws -> CongressMemberManifestItem {
        try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data(json.utf8))
    }

    private static let plainManifest = #"{"bioguideId": "D000001", "name": "Jane Doe"}"#

    /// The page's member for `payload`, with `manifest` as the members list's row.
    @MainActor
    private func pageMember(_ payload: Data, manifest: String = plainManifest) throws -> CongressMember {
        let fallback = try manifestItem(manifest)
        return try CongressService.decodeProcessedCongressMember(from: payload).toCongressMember(fallback: fallback)
    }

    @MainActor
    private func rows(_ member: CongressMember) -> [String] {
        member.trackedActivityRows.map { "\($0.label)=\($0.value)" }
    }

    /// The contract fixture: a member whose newest counts are the 119th Congress's.
    @MainActor
    func testTheContractFixtureCarriesTheCongressItsCountsCover() throws {
        let processed = try CongressService.decodeProcessedCongressMember(from: Data(Self.processedFixture.utf8))
        XCTAssertEqual(processed.terms?.count, 1, "the contract shape, which keeps the terms")
        XCTAssertEqual(processed.currentCongressCounts, TrackedCongressCounts(congress: 119, sponsored: 2, supported: 9))

        let member = try pageMember(Data(Self.processedFixture.utf8))
        XCTAssertEqual(member.trackedCongress, 119)
        XCTAssertEqual(rows(member), ["Sponsored in 119th Congress=2", "Supported in 119th Congress=9"])
    }

    /// Present with the 120th Congress: the page shows those counts, labelled 120th, and not the 119th fields.
    @MainActor
    func testCountsOfThe120thAreLabelledWithThe120th() throws {
        let payload = try processedPayload(setting: ["currentCongressCounts": ["congress": 120, "sponsored": 1, "supported": 4]])
        let processed = try CongressService.decodeProcessedCongressMember(from: payload)
        XCTAssertEqual(processed.terms?.count, 1, "the contract shape")
        XCTAssertEqual(processed.currentCongressCounts, TrackedCongressCounts(congress: 120, sponsored: 1, supported: 4))

        let member = try pageMember(payload)
        XCTAssertEqual(member.trackedCongress, 120)
        XCTAssertEqual(rows(member), ["Sponsored in 120th Congress=1", "Supported in 120th Congress=4"])
        XCTAssertEqual(
            CongressMemberPageContent.trackedCaption(congress: member.trackedCongress),
            "Counts only 120th Congress bills in Billboard."
        )
    }

    /// Absent (services before REL-46): the 119th Congress counts, labelled 119th.
    @MainActor
    func testWithoutTheFieldThe119thCountsKeepTheir119thLabels() throws {
        let payload = try processedPayload(removing: ["currentCongressCounts"])
        let processed = try CongressService.decodeProcessedCongressMember(from: payload)
        XCTAssertEqual(processed.terms?.count, 1, "the contract shape")
        XCTAssertNil(processed.currentCongressCounts)

        let member = try pageMember(payload)
        XCTAssertEqual(member.trackedCongress, 119)
        XCTAssertEqual(rows(member), ["Sponsored in 119th Congress=2", "Supported in 119th Congress=9"])
    }

    /// A member new in the 120th Congress sends no 119th counts. The payload still has counts, so the manifest's
    /// are not used, and the page shows the 120th's, zeros included.
    @MainActor
    func testAMemberNewInThe120thKeepsTheirCounts() throws {
        let payload = try processedPayload(
            removing: ["trackedSponsoredCount", "trackedSupportedCount", "currentCongressBillsSupportedCount"],
            setting: ["currentCongressCounts": ["congress": 120, "sponsored": 0, "supported": 3]]
        )
        let manifest = #"{"bioguideId": "D000001", "name": "Jane Doe", "trackedSponsoredCount": 5, "trackedSupportedCount": 6}"#

        let processed = try CongressService.decodeProcessedCongressMember(from: payload)
        XCTAssertEqual(processed.terms?.count, 1, "the contract shape")
        XCTAssertNil(processed.trackedSponsoredCount)
        XCTAssertNil(processed.trackedSupportedCount)

        let member = try pageMember(payload, manifest: manifest)
        XCTAssertNil(member.trackedSponsoredCount, "not the manifest's 119th counts")
        XCTAssertNil(member.trackedSupportedCount)
        XCTAssertEqual(rows(member), ["Sponsored in 120th Congress=0", "Supported in 120th Congress=3"])
    }

    /// A payload with no counts at all (its member stats read failed) takes the manifest's, 120th ones included.
    @MainActor
    func testTheManifestsCountsFillAPayloadWithoutAny() throws {
        let payload = try processedPayload(
            removing: ["trackedSponsoredCount", "trackedSupportedCount", "currentCongressBillsSupportedCount", "currentCongressCounts"]
        )
        let manifest = #"""
        {"bioguideId": "D000001", "name": "Jane Doe", "trackedSponsoredCount": 2, "trackedSupportedCount": 7,
         "currentCongressCounts": {"congress": 120, "sponsored": 1, "supported": 4}}
        """#

        let member = try pageMember(payload, manifest: manifest)
        XCTAssertEqual(rows(member), ["Sponsored in 120th Congress=1", "Supported in 120th Congress=4"])
    }

    /// No counts anywhere: no rows, so the page has no Tracked by Billboard section (REL-46 D8).
    @MainActor
    func testAMemberWithNoCountsHasNoTrackedRows() throws {
        let payload = try processedPayload(
            removing: ["trackedSponsoredCount", "trackedSupportedCount", "currentCongressBillsSupportedCount", "currentCongressCounts"]
        )

        let member = try pageMember(payload)
        XCTAssertNil(member.currentCongressCounts)
        XCTAssertEqual(rows(member), [])
    }

    /// The flexible decoder (a payload the contract shape does not read) carries the field too.
    @MainActor
    func testTheFlexibleDecoderReadsTheCounts() throws {
        // No `name`, so the contract shape fails.
        let payload = Data(#"{"id": "N000001", "currentCongressCounts": {"congress": 120, "sponsored": 1, "supported": 2}}"#.utf8)
        let processed = try CongressService.decodeProcessedCongressMember(from: payload)
        XCTAssertEqual(processed.bioguideId, "N000001")
        XCTAssertNil(processed.trackedSponsoredCount)
        XCTAssertEqual(processed.currentCongressCounts, TrackedCongressCounts(congress: 120, sponsored: 1, supported: 2))

        let member = try pageMember(payload, manifest: #"{"bioguideId": "N000001", "name": "N"}"#)
        XCTAssertEqual(rows(member), ["Sponsored in 120th Congress=1", "Supported in 120th Congress=2"])

        // A malformed value is left out rather than failing the member.
        let malformed = Data(#"{"id": "N000001", "trackedSponsoredCount": 3, "currentCongressCounts": {"congress": "120th"}}"#.utf8)
        let lenient = try CongressService.decodeProcessedCongressMember(from: malformed)
        XCTAssertNil(lenient.currentCongressCounts)
        XCTAssertEqual(lenient.trackedSponsoredCount, 3)
    }

    /// The members manifest carries the field from the contract, and its disk cache keeps it.
    @MainActor
    func testTheManifestMapsAndCachesTheCounts() throws {
        let manifest = try JSONDecoder.convertingFromSnakeCase().decode(
            UserAPIContractsV1.CongressMembersManifest.self,
            from: Data(Self.manifestFixture.utf8)
        )
        let items = manifest.members.map(CongressMemberManifestItem.init(dto:))
        XCTAssertEqual(items.map(\.currentCongressCounts), [TrackedCongressCounts(congress: 120, sponsored: 1, supported: 4), nil])
        XCTAssertEqual(items.map(\.trackedSponsoredCount), [2, nil])

        let cached = try JSONDecoder.convertingFromSnakeCase().decode([CongressMemberManifestItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(cached, items)
    }
}
