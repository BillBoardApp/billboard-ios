import XCTest
@testable import Billboard

/// `BillsService.decodeProcessedBill(from:)` reads `GET /processed-bill` through the generated
/// `UserAPIContractsV1.ProcessedBill` (CON-03), its only decode path. Since CON-11 the contract accepts
/// the live Congress.gov committee shapes the app's old tolerant fallback existed for; a payload the
/// contract still rejects is logged and surfaces as `APIServiceError.invalidPayload("processed-bill")`.
final class ProcessedBillDecodingTests: XCTestCase {
    /// billboard-backend/contracts/fixtures/entities/processed-bill.v1.valid.json, trimmed.
    private static let contractFixture = #"""
    {
      "schemaVersion": 1,
      "kind": "processed",
      "storedAt": "2026-03-06T20:00:00.000Z",
      "identifier": {"congress": "119", "billType": "hr", "billNumber": "1234"},
      "guid": "BILLS-119hr1234ih",
      "title": "Clean Energy Access Act",
      "officialTitle": "To expand access to clean energy programs, and for other purposes.",
      "link": "https://www.congress.gov/bill/119th-congress/house-bill/1234",
      "soWhat": "Creates grant funding for state-level clean energy grid upgrades.",
      "summary": "A bill to establish clean energy grid grants.",
      "billBreakdown": {
        "who": "State energy offices and eligible utilities",
        "what": "Provides competitive clean energy grid grants",
        "how": "Authorizes federal appropriations and application scoring",
        "when": "Funding begins in fiscal year 2027",
        "where": "All U.S. states and territories",
        "why": "Improve grid resiliency and lower emissions"
      },
      "internalSchema": 2,
      "subCategories": ["Energy", "Climate Change"],
      "lifeAreas": ["Utility Bills", "Home Energy"],
      "sponsors": ["D000001"],
      "cosponsors": ["S000001", "L000001"],
      "isPriority": true,
      "priorityRank": 1,
      "priorityReason": "National outlets are covering the bill.",
      "priorityExpiresAt": "2026-03-07T08:00:00.000Z",
      "actions": [
        {
          "actionCode": "8000",
          "actionDate": "2026-02-27",
          "text": "On passage Passed by the Yeas and Nays: 231 - 196, 2 Present (Roll no. 58).",
          "type": "Floor",
          "sourceSystem": {"code": 2, "name": "House floor actions"}
        },
        {"actionDate": "2026-02-10", "text": "Introduced in House", "type": "IntroReferral"}
      ],
      "committees": [
        {
          "name": "Energy and Commerce Committee",
          "chamber": "House",
          "systemCode": "hsif00",
          "type": "Standing",
          "activities": [{"name": "Referred to", "date": "2026-02-10T15:03:15Z"}]
        }
      ],
      "billStatus": "Updated",
      "civicProfile": {"individualVsCommunity": 0.55, "localVsFederal": -0.25},
      "officialVotes": {
        "house": {
          "yea": 231, "nay": 196, "present": 2, "notVoting": 6, "totalCounted": 429,
          "actionCode": "pass", "actionDate": "2026-02-27", "resultText": "Passed",
          "memberDataAvailable": true,
          "members": [
            {"bioguideId": "D000001", "displayName": "Doe, Jane", "party": "D", "state": "CA", "district": "12", "votePosition": "Yea"}
          ]
        },
        "lastSyncedAt": "2026-03-06T19:55:00.000Z",
        "source": "congress_api",
        "completeness": "partial"
      }
    }
    """#

    private func fixtureObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.contractFixture.utf8)) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Committee shapes of live bills of the 119th Congress that the contract rejected before CON-11:
    /// a committee activity with no `date` (H.R. 3838, H.R. 4275) and a committee with only
    /// subcommittee activities, so no `activities` of its own (H.R. 4275's subcommittee, H.R. 471).
    /// Copied from the stored processed bills without the Congress.gov fields the `Bill` does not
    /// carry from the contract (`systemCode`, `type`, `url`).
    private struct LiveCommitteeShape {
        let guid: String
        let billNumber: String
        let committees: [[String: Any]]
        /// The `Bill` the removed tolerant fallback built from `payload(for:)`, encoded with sorted keys.
        /// Recorded from the fallback before it was deleted, when both paths still produced it byte for byte.
        let fallbackBill: String
    }

    private static let liveCommitteeShapes: [LiveCommitteeShape] = [
        LiveCommitteeShape(guid: "BILLS-119hr3838", billNumber: "3838", committees: [
            ["name": "Agriculture Committee", "chamber": "House", "activities": [["name": "Bills of Interest - Exchange of Letters"]]],
            ["name": "Armed Services Committee", "chamber": "House", "activities": [
                ["name": "Reported By", "date": "2025-08-19T14:01:38Z"],
                ["name": "Markup By", "date": "2025-07-15T13:04:42Z"],
                ["name": "Referred To", "date": "2025-06-09T16:00:15Z"]
            ]]
        ], fallbackBill: #"{"actions":[{"actionCode":"8000","actionDate":"2026-02-27","text":"Passed House","type":"Floor"},{"actionDate":"2026-02-10","text":"Introduced in House","type":"IntroReferral"}],"billBreakdown":{"how":"Authorizes federal appropriations and application scoring","what":"Provides competitive clean energy grid grants","when":"Funding begins in fiscal year 2027","where":"All U.S. states and territories","who":"State energy offices and eligible utilities","why":"Improve grid resiliency and lower emissions"},"billStatus":"Updated","category":"Environmental and Energy Policy","committees":[{"activities":[{"name":"Bills of Interest - Exchange of Letters"}],"chamber":"House","name":"Agriculture Committee"},{"activities":[{"date":"2025-08-19T14:01:38Z","name":"Reported By"},{"date":"2025-07-15T13:04:42Z","name":"Markup By"},{"date":"2025-06-09T16:00:15Z","name":"Referred To"}],"chamber":"House","name":"Armed Services Committee"}],"congressHouseNayCount":196,"congressHouseYeaCount":231,"id":"42494C4C-532D-3131-3968-723338333800","isPriority":true,"isProcessedDetailHydrated":true,"lifeAreas":["Utility Bills","Home Energy"],"link":"https:\/\/www.congress.gov\/bill\/119th-congress\/house-bill\/1234","officialTitle":"To expand access to clean energy programs, and for other purposes.","officialVotes":{"completeness":"partial","house":{"actionCode":"pass","actionDate":"2026-02-27","memberDataAvailable":true,"members":[{"bioguideId":"D000001","displayName":"Doe, Jane","district":"12","party":"D","state":"CA","votePosition":"Yea"}],"nay":196,"notVoting":6,"present":2,"resultText":"Passed","totalCounted":429,"yea":231},"lastSyncedAt":"2026-03-06T19:55:00.000Z","source":"congress_api"},"passedHouse":false,"passedSenate":false,"priorityExpiresAt":"2026-03-07T08:00:00.000Z","priorityRank":1,"priorityReason":"National outlets are covering the bill.","relatedMemberIDs":["44303030-3030-3100-0000-000000000000","4C303030-3030-3100-0000-000000000000","53303030-3030-3100-0000-000000000000"],"soWhat":"Creates grant funding for state-level clean energy grid upgrades.","sponsorMemberID":"44303030-3030-3100-0000-000000000000","storedAt":"2026-03-06T20:00:00.000Z","subCategory":"Energy","summary":"A bill to establish clean energy grid grants.","title":"Clean Energy Access Act","userNayCount":0,"userVoted":false,"userWatched":false,"userYeaCount":0}"#),
        LiveCommitteeShape(guid: "BILLS-119hr4275", billNumber: "4275", committees: [
            ["name": "Armed Services Committee", "chamber": "House", "activities": [["name": "Bills of Interest - Exchange of Letters"]]],
            ["name": "Homeland Security Committee", "chamber": "House", "activities": [["name": "Bills of Interest - Exchange of Letters"]]],
            ["name": "Transportation and Infrastructure Committee", "chamber": "House",
             "activities": [["name": "Reported By", "date": "2025-07-22T14:07:53Z"], ["name": "Referred To", "date": "2025-07-02T13:02:25Z"]],
             "subcommittees": [["name": "Coast Guard and Maritime Transportation Subcommittee", "activities": [["name": "Referred to", "date": "2025-07-03T13:48:00Z"]]]]]
        ], fallbackBill: #"{"actions":[{"actionCode":"8000","actionDate":"2026-02-27","text":"Passed House","type":"Floor"},{"actionDate":"2026-02-10","text":"Introduced in House","type":"IntroReferral"}],"billBreakdown":{"how":"Authorizes federal appropriations and application scoring","what":"Provides competitive clean energy grid grants","when":"Funding begins in fiscal year 2027","where":"All U.S. states and territories","who":"State energy offices and eligible utilities","why":"Improve grid resiliency and lower emissions"},"billStatus":"Updated","category":"Environmental and Energy Policy","committees":[{"activities":[{"name":"Bills of Interest - Exchange of Letters"}],"chamber":"House","name":"Armed Services Committee"},{"activities":[{"name":"Bills of Interest - Exchange of Letters"}],"chamber":"House","name":"Homeland Security Committee"},{"activities":[{"date":"2025-07-22T14:07:53Z","name":"Reported By"},{"date":"2025-07-02T13:02:25Z","name":"Referred To"}],"chamber":"House","name":"Transportation and Infrastructure Committee"}],"congressHouseNayCount":196,"congressHouseYeaCount":231,"id":"42494C4C-532D-3131-3968-723432373500","isPriority":true,"isProcessedDetailHydrated":true,"lifeAreas":["Utility Bills","Home Energy"],"link":"https:\/\/www.congress.gov\/bill\/119th-congress\/house-bill\/1234","officialTitle":"To expand access to clean energy programs, and for other purposes.","officialVotes":{"completeness":"partial","house":{"actionCode":"pass","actionDate":"2026-02-27","memberDataAvailable":true,"members":[{"bioguideId":"D000001","displayName":"Doe, Jane","district":"12","party":"D","state":"CA","votePosition":"Yea"}],"nay":196,"notVoting":6,"present":2,"resultText":"Passed","totalCounted":429,"yea":231},"lastSyncedAt":"2026-03-06T19:55:00.000Z","source":"congress_api"},"passedHouse":false,"passedSenate":false,"priorityExpiresAt":"2026-03-07T08:00:00.000Z","priorityRank":1,"priorityReason":"National outlets are covering the bill.","relatedMemberIDs":["44303030-3030-3100-0000-000000000000","4C303030-3030-3100-0000-000000000000","53303030-3030-3100-0000-000000000000"],"soWhat":"Creates grant funding for state-level clean energy grid upgrades.","sponsorMemberID":"44303030-3030-3100-0000-000000000000","storedAt":"2026-03-06T20:00:00.000Z","subCategory":"Energy","summary":"A bill to establish clean energy grid grants.","title":"Clean Energy Access Act","userNayCount":0,"userVoted":false,"userWatched":false,"userYeaCount":0}"#),
        LiveCommitteeShape(guid: "BILLS-119hr471", billNumber: "471", committees: [
            ["name": "Agriculture, Nutrition, and Forestry Committee", "chamber": "Senate",
             "subcommittees": [["name": "Conservation, Forestry, Natural Resources, and Biotechnology Subcommittee", "activities": [["name": "Hearings By (subcommittee)", "date": "2025-03-06T16:00:00Z"]]]]],
            ["name": "Agriculture Committee", "chamber": "House", "activities": [["name": "Referred To", "date": "2025-01-16T14:02:40Z"]]]
        ], fallbackBill: #"{"actions":[{"actionCode":"8000","actionDate":"2026-02-27","text":"Passed House","type":"Floor"},{"actionDate":"2026-02-10","text":"Introduced in House","type":"IntroReferral"}],"billBreakdown":{"how":"Authorizes federal appropriations and application scoring","what":"Provides competitive clean energy grid grants","when":"Funding begins in fiscal year 2027","where":"All U.S. states and territories","who":"State energy offices and eligible utilities","why":"Improve grid resiliency and lower emissions"},"billStatus":"Updated","category":"Environmental and Energy Policy","committees":[{"chamber":"Senate","name":"Agriculture, Nutrition, and Forestry Committee"},{"activities":[{"date":"2025-01-16T14:02:40Z","name":"Referred To"}],"chamber":"House","name":"Agriculture Committee"}],"congressHouseNayCount":196,"congressHouseYeaCount":231,"id":"42494C4C-532D-3131-3968-723437310000","isPriority":true,"isProcessedDetailHydrated":true,"lifeAreas":["Utility Bills","Home Energy"],"link":"https:\/\/www.congress.gov\/bill\/119th-congress\/house-bill\/1234","officialTitle":"To expand access to clean energy programs, and for other purposes.","officialVotes":{"completeness":"partial","house":{"actionCode":"pass","actionDate":"2026-02-27","memberDataAvailable":true,"members":[{"bioguideId":"D000001","displayName":"Doe, Jane","district":"12","party":"D","state":"CA","votePosition":"Yea"}],"nay":196,"notVoting":6,"present":2,"resultText":"Passed","totalCounted":429,"yea":231},"lastSyncedAt":"2026-03-06T19:55:00.000Z","source":"congress_api"},"passedHouse":false,"passedSenate":false,"priorityExpiresAt":"2026-03-07T08:00:00.000Z","priorityRank":1,"priorityReason":"National outlets are covering the bill.","relatedMemberIDs":["44303030-3030-3100-0000-000000000000","4C303030-3030-3100-0000-000000000000","53303030-3030-3100-0000-000000000000"],"soWhat":"Creates grant funding for state-level clean energy grid upgrades.","sponsorMemberID":"44303030-3030-3100-0000-000000000000","storedAt":"2026-03-06T20:00:00.000Z","subCategory":"Energy","summary":"A bill to establish clean energy grid grants.","title":"Clean Energy Access Act","userNayCount":0,"userVoted":false,"userWatched":false,"userYeaCount":0}"#)
    ]

    /// The contract fixture as the live bill: its guid, identifier and committees, and actions without
    /// the Congress.gov fields the `Bill` does not carry from the contract (`sourceSystem`).
    private func payload(for shape: LiveCommitteeShape) throws -> [String: Any] {
        var object = try fixtureObject()
        object["guid"] = shape.guid
        object["identifier"] = ["congress": "119", "billType": "hr", "billNumber": shape.billNumber]
        object["actions"] = [
            ["actionCode": "8000", "actionDate": "2026-02-27", "text": "Passed House", "type": "Floor"],
            ["actionDate": "2026-02-10", "text": "Introduced in House", "type": "IntroReferral"]
        ]
        object["committees"] = shape.committees
        return object
    }

    /// APPF-23: `GET /processed-bill` adds `companionGroup` to a grouped bill. The contract decodes it,
    /// the app maps it, and the bill itself is unchanged by it.
    @MainActor
    func testCompanionGroupDecodesAndLeavesTheBillUnchanged() throws {
        var object = try fixtureObject()
        object["companionGroup"] = [
            "primaryGuid": "BILLS-119hr1234",
            "memberGuids": ["BILLS-119hr1234", "BILLS-119s570"],
            "relationship": "identical"
        ]

        let dto = try JSONDecoder.convertingFromSnakeCase(dates: .iso8601)
            .decode(UserAPIContractsV1.ProcessedBill.self, from: try data(object))
        let group = try XCTUnwrap(dto.companionGroup.flatMap(BillCompanionGroup.init(dto:)))
        XCTAssertEqual(group.primaryGuid, "BILLS-119hr1234")
        XCTAssertEqual(group.memberGuids, ["BILLS-119hr1234", "BILLS-119s570"])
        XCTAssertTrue(group.isIdentical)

        let withGroup = try BillsService.decodeProcessedBill(from: try data(object))
        let without = try BillsService.decodeProcessedBill(from: Data(Self.contractFixture.utf8))
        XCTAssertEqual(try encoded(withGroup), try encoded(without))
    }

    @MainActor
    private func encoded(_ bill: Bill) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(bill), as: UTF8.self)
    }

    @MainActor
    private func contractDecodes(_ data: Data) -> Bool {
        (try? JSONDecoder.convertingFromSnakeCase().decode(UserAPIContractsV1.ProcessedBill.self, from: data)) != nil
    }

    @MainActor
    func testContractPayloadMapsIntoBill() throws {
        let payload = Data(Self.contractFixture.utf8)
        XCTAssertTrue(contractDecodes(payload))

        let bill = try BillsService.decodeProcessedBill(from: payload)

        XCTAssertEqual(bill.id, UUID.deterministic(from: "BILLS-119hr1234ih"))
        XCTAssertEqual(bill.title, "Clean Energy Access Act")
        XCTAssertEqual(bill.officialTitle, "To expand access to clean energy programs, and for other purposes.")
        XCTAssertEqual(bill.category, SubscriptionsConfig.categoryEnvironmentalAndEnergyPolicy)
        XCTAssertEqual(bill.subCategory, "Energy")
        XCTAssertEqual(bill.summary, "A bill to establish clean energy grid grants.")
        XCTAssertEqual(bill.soWhat, "Creates grant funding for state-level clean energy grid upgrades.")
        XCTAssertEqual(bill.billBreakdown?.`where`, "All U.S. states and territories")
        XCTAssertEqual(bill.storedAt, "2026-03-06T20:00:00.000Z")
        XCTAssertEqual(bill.link, "https://www.congress.gov/bill/119th-congress/house-bill/1234")
        XCTAssertEqual(bill.lifeAreas, ["Utility Bills", "Home Energy"])
        XCTAssertEqual(bill.billStatus, .updated)
        XCTAssertEqual(bill.sponsorMemberID, UUID.deterministic(from: "D000001"))
        XCTAssertEqual(bill.relatedMemberIDs?.count, 3)
        XCTAssertTrue(bill.isPriority)
        XCTAssertEqual(bill.priorityRank, 1)
        XCTAssertEqual(bill.priorityExpiresAt, "2026-03-07T08:00:00.000Z")
        XCTAssertEqual(bill.isProcessedDetailHydrated, true)

        XCTAssertEqual(bill.actions.map(\.type), ["Floor", "IntroReferral"])
        XCTAssertEqual(bill.actions.first?.actionCode, "8000")
        // The contract lists only the action fields the app reads, so this came from the contract path.
        XCTAssertNil(bill.actions.first?.sourceSystem)
        XCTAssertEqual(bill.committees.first?.name, "Energy and Commerce Committee")
        XCTAssertEqual(bill.committees.first?.chamber, "House")
        XCTAssertEqual(bill.committees.first?.activities?.first?.date, "2026-02-10T15:03:15Z")

        XCTAssertEqual(bill.officialVotes?.house?.yea, 231)
        XCTAssertEqual(bill.officialVotes?.house?.members.first?.votePosition, "Yea")
        XCTAssertEqual(bill.officialVotes?.completeness, "partial")
        XCTAssertEqual(bill.congressHouseYeaCount, 231)
        XCTAssertNil(bill.officialVotes?.senate)
    }

    /// The live committee shapes (H.R. 3838, H.R. 471, H.R. 4275) are contract-valid since CON-11.
    @MainActor
    func testLiveCommitteeShapesDecodeThroughTheContract() throws {
        var object = try fixtureObject()
        object["committees"] = [
            [
                "name": "Agriculture Committee",
                "chamber": "House",
                "activities": [["name": "Bills of Interest - Exchange of Letters"]]
            ],
            [
                "name": "Agriculture, Nutrition, and Forestry Committee",
                "chamber": "Senate",
                "subcommittees": [["name": "Conservation Subcommittee", "activities": [["name": "Hearings By (subcommittee)", "date": "2025-03-06T16:00:00Z"]]]]
            ]
        ]
        let payload = try data(object)
        XCTAssertTrue(contractDecodes(payload))

        let bill = try BillsService.decodeProcessedBill(from: payload)

        XCTAssertEqual(bill.title, "Clean Energy Access Act")
        XCTAssertEqual(bill.officialTitle, "To expand access to clean energy programs, and for other purposes.")
        XCTAssertEqual(bill.committees.count, 2)
        XCTAssertEqual(bill.committees[0].activities?.first?.name, "Bills of Interest - Exchange of Letters")
        XCTAssertNil(bill.committees[0].activities?.first?.date)
        XCTAssertNil(bill.committees[1].activities)
        XCTAssertEqual(bill.actions.count, 2)
        // The contract lists only the action fields the app reads.
        XCTAssertNil(bill.actions.first?.sourceSystem)
        XCTAssertEqual(bill.officialVotes?.house?.yea, 231)
        XCTAssertEqual(bill.isProcessedDetailHydrated, true)
    }

    /// The three live shapes decode through the contract to the same `Bill`, byte for byte once
    /// encoded, as the removed tolerant fallback built from them.
    @MainActor
    func testLiveCommitteeShapesMapToTheBillTheFallbackProduced() throws {
        for shape in Self.liveCommitteeShapes {
            let payload = try data(payload(for: shape))
            XCTAssertTrue(contractDecodes(payload), shape.guid)

            let bill = try BillsService.decodeProcessedBill(from: payload)

            XCTAssertEqual(try encoded(bill), shape.fallbackBill, shape.guid)
        }
    }

    /// Every activity date is kept, and a committee with only subcommittee activity has no activities.
    @MainActor
    func testLiveCommitteeShapesKeepEachCommitteesActivities() throws {
        let bills = try Self.liveCommitteeShapes.map { try BillsService.decodeProcessedBill(from: data(payload(for: $0))) }

        XCTAssertEqual(bills[0].committees.map { $0.activities?.map(\.date) }, [[nil], ["2025-08-19T14:01:38Z", "2025-07-15T13:04:42Z", "2025-06-09T16:00:15Z"]])
        XCTAssertEqual(bills[1].committees.map { $0.activities?.count }, [1, 1, 2])
        XCTAssertEqual(bills[1].committees.map { $0.activities?.first?.name }, ["Bills of Interest - Exchange of Letters", "Bills of Interest - Exchange of Letters", "Reported By"])
        XCTAssertEqual(bills[2].committees.map(\.name), ["Agriculture, Nutrition, and Forestry Committee", "Agriculture Committee"])
        XCTAssertNil(bills[2].committees[0].activities)
        XCTAssertEqual(bills[2].committees[1].activities?.map(\.date), ["2025-01-16T14:02:40Z"])
        XCTAssertEqual(bills[2].committees[1].activities?.map(\.name), ["Referred To"])
    }

    /// There is no tolerant fallback any more: a payload outside the contract is rejected with the
    /// error the fallback path threw when both decodes failed.
    @MainActor
    func testPayloadOutsideTheContractIsRejected() throws {
        var missingRequiredField = try fixtureObject()
        missingRequiredField.removeValue(forKey: "kind")

        for payload in [Data(#"{"billStatus": "Failed"}"#.utf8), try data(missingRequiredField)] {
            XCTAssertFalse(contractDecodes(payload))
            XCTAssertThrowsError(try BillsService.decodeProcessedBill(from: payload)) { error in
                XCTAssertEqual(error as? APIServiceError, .invalidPayload("processed-bill"))
            }
        }
    }

    @MainActor
    func testNonObjectPayloadIsRejected() {
        XCTAssertThrowsError(try BillsService.decodeProcessedBill(from: Data("[]".utf8))) { error in
            XCTAssertEqual(error as? APIServiceError, .invalidPayload("processed-bill"))
        }
    }

    // MARK: - Actions without text, breakdowns without why (live shapes)

    /// Shapes a validation of every stored processed bill found, which the contract now accepts: an
    /// action without `text` (an Intro-S IntroReferral action, as stored), a breakdown without `why`
    /// (older summaries) and with an extra key, and a cosponsor listed twice.
    @MainActor
    func testLiveShapesWithoutActionTextOrBreakdownWhyDecode() throws {
        var object = try fixtureObject()
        object["actions"] = [
            ["actionCode": "Intro-S", "actionDate": "2025-12-04", "sourceSystem": ["code": 0, "name": "Senate"], "type": "IntroReferral"],
            ["actionDate": "2025-12-04", "text": "Read twice and referred to the Committee on Finance.", "type": "IntroReferral"]
        ]
        object["billBreakdown"] = [
            "who": "Taxpayers", "what": "Changes a credit", "how": "Amends the tax code", "when": "Tax year 2027",
            "where": "Nationwide", "lifeAreas": ["Taxes"]
        ]
        object["cosponsors"] = ["S000001", "L000001", "S000001"]
        let payload = try data(object)
        XCTAssertTrue(contractDecodes(payload))

        let bill = try BillsService.decodeProcessedBill(from: payload, guid: "BILLS-119hr1234ih")

        XCTAssertEqual(bill.actions.count, 2)
        XCTAssertNil(bill.actions[0].text)
        XCTAssertEqual(bill.actions[0].actionCode, "Intro-S")
        XCTAssertEqual(bill.actions[0].type, "IntroReferral")
        let breakdown = try XCTUnwrap(bill.billBreakdown)
        XCTAssertNil(breakdown.why)
        XCTAssertEqual(breakdown.who, "Taxpayers")
        XCTAssertTrue(breakdown.hasContent)
        XCTAssertEqual(bill.relatedMemberIDs?.count, 3, "the sponsor and two distinct cosponsors")

        // The bill detail shows no Why row and no entry for the action without text.
        let rows = BillDisplayFormatting.breakdownRows(breakdown)
        XCTAssertEqual(rows.map(\.label), ["Who", "What", "How", "When", "Where"])
        XCTAssertFalse(rows.contains { $0.text.isEmpty || $0.text.contains("nil") })
        XCTAssertEqual(BillDisplayFormatting.timelineActions(bill.actions).map(\.text), ["Read twice and referred to the Committee on Finance."])
    }

    @MainActor
    func testBreakdownRowsLeaveOutMissingAndBlankFields() {
        let breakdown = BillBreakdown(who: " Farmers ", what: "", how: nil, when: "  ", where: "Rural areas", why: nil)

        let rows = BillDisplayFormatting.breakdownRows(breakdown)

        XCTAssertEqual(rows.map(\.label), ["Who", "Where"])
        XCTAssertEqual(rows.map(\.text), ["Farmers", "Rural areas"])
    }

    @MainActor
    func testTimelineActionsAreOldestFirstWithoutRepeats() {
        func action(_ date: String, _ text: String?, code: String? = nil, type: String = "IntroReferral") -> Bill.BillAction {
            Bill.BillAction(actionCode: code, actionDate: date, text: text, type: type, sourceSystem: nil, committees: nil)
        }
        let actions = [
            action("2026-02-27", "Passed House", type: "Floor"),
            // Left out: an action with text shares its date.
            action("2026-02-10", nil, code: "Intro-S"),
            action("2026-02-10", "Introduced in House"),
            action("2026-02-10", "Introduced in House"),
            // Listed by its type: no action with text shares its date.
            action("2026-02-11", "   "),
            // Left out: no text, and a type without a label.
            action("2026-02-12", nil, type: "NotAType")
        ]

        let timeline = BillDisplayFormatting.timelineActions(actions)

        XCTAssertEqual(timeline.compactMap(BillDisplayFormatting.timelineText(for:)), ["Introduced in House", "Introduced and referred", "Passed House"])
        XCTAssertEqual(timeline.map(BillDisplayFormatting.timelineTypeLabel(for:)), ["Introduced and referred", nil, "Floor action"], "a type shown as the line is not repeated under it")
    }

    @MainActor
    func testTimelineShowsABillsOnlyActionWithoutText() {
        let intro = Bill.BillAction(actionCode: "Intro-S", actionDate: "2025-12-04", text: nil, type: "IntroReferral", sourceSystem: nil, committees: nil)

        let timeline = BillDisplayFormatting.timelineActions([intro, intro])

        XCTAssertEqual(timeline, [intro])
        XCTAssertEqual(BillDisplayFormatting.timelineText(for: intro), "Introduced and referred")
    }

    @MainActor
    func testDecodeLogLabelNamesTheBill() {
        XCTAssertEqual(BillsService.processedBillLogLabel(guid: " BILLS-119hr1234ih "), "BillsService processed-bill guid=BILLS-119hr1234ih")
        XCTAssertEqual(BillsService.processedBillLogLabel(guid: nil), "BillsService processed-bill")
        XCTAssertEqual(BillsService.processedBillLogLabel(guid: " "), "BillsService processed-bill")
    }

    // MARK: - Official title (LLM-05)

    func testOfficialTitleForDisplay() {
        let headline = "Farm aid and food program changes"
        XCTAssertEqual(
            BillDisplayFormatting.officialTitle("  To provide for reconciliation pursuant to title II of H. Con. Res. 14. ", headline: headline),
            "To provide for reconciliation pursuant to title II of H. Con. Res. 14."
        )
        XCTAssertNil(BillDisplayFormatting.officialTitle(nil, headline: headline))
        XCTAssertNil(BillDisplayFormatting.officialTitle("   ", headline: headline))
        XCTAssertNil(BillDisplayFormatting.officialTitle("farm aid and food program changes", headline: headline))
    }

    @MainActor
    func testHydrationMergeKeepsTheOfficialTitle() {
        let hydrated = Bill(
            title: "Clean Energy Access Act",
            officialTitle: "To expand access to clean energy programs.",
            category: "Energy",
            soWhat: "",
            billStatus: .updated,
            userVoted: false,
            isProcessedDetailHydrated: true
        )
        let manifestOnly = Bill(id: hydrated.id, title: "Clean Energy Access Act", category: "Energy", soWhat: "", billStatus: .updated, userVoted: false)

        let merged = BillsStore.mergedBillPreservingExistingContext(incoming: manifestOnly, existing: hydrated)
        XCTAssertEqual(merged.officialTitle, "To expand access to clean energy programs.")
        XCTAssertEqual(merged.displayOfficialTitle, "To expand access to clean energy programs.")

        let reversed = BillsStore.mergedBillPreservingExistingContext(incoming: hydrated, existing: manifestOnly)
        XCTAssertEqual(reversed.officialTitle, "To expand access to clean energy programs.")
    }
}
