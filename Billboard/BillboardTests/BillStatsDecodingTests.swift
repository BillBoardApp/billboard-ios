import XCTest
@testable import Billboard

/// `GET /bill-stats` decoding for R2 (spec D 2.2, 3.1): the `comparison` block, bodies without it,
/// and a future server that drops the `weighted*` fields.
@MainActor
final class BillStatsDecodingTests: XCTestCase {
    /// `billboard-backend/contracts/fixtures/openapi/BillStats.valid.json` (the contract's example payload),
    /// verbatim.
    static let contractExample = #"""
        {
          "billId": "BILLS-119hr1285ih",
          "generatedAt": "2026-10-08T12:00:00.000Z",
          "totals": {
            "votes": 12,
            "yea": 7,
            "nay": 3,
            "abstain": 2,
            "decisionVotes": 10,
            "yeaPct": 70,
            "weightedVotes": 12,
            "weightedYea": 7,
            "weightedNay": 3,
            "weightedAbstain": 2,
            "weightedDecisionVotes": 10,
            "weightedYeaPct": 70
          },
          "segments": {
            "verified": {
              "votes": 6,
              "yea": 4,
              "nay": 1,
              "abstain": 1,
              "decisionVotes": 5,
              "yeaPct": 80,
              "weightedVotes": 6,
              "weightedYea": 4,
              "weightedNay": 1,
              "weightedAbstain": 1,
              "weightedDecisionVotes": 5,
              "weightedYeaPct": 80
            },
            "selfAttested": {
              "votes": 6,
              "yea": 3,
              "nay": 2,
              "abstain": 1,
              "decisionVotes": 5,
              "yeaPct": 60,
              "weightedVotes": 6,
              "weightedYea": 3,
              "weightedNay": 2,
              "weightedAbstain": 1,
              "weightedDecisionVotes": 5,
              "weightedYeaPct": 60
            }
          },
          "comparison": {
            "allUsers": { "votes": 12, "yea": 7, "nay": 3, "abstain": 2, "decisionVotes": 10, "yeaPct": 70 },
            "verified": { "votes": 6, "yea": 4, "nay": 1, "abstain": 1, "decisionVotes": 5, "yeaPct": 80 },
            "verifiedWithheld": false,
            "minDecisionVotes": 5
          },
          "rollups": {
            "byState": {
              "CA": {
                "state": "CA",
                "totals": {
                  "votes": 6,
                  "yea": 4,
                  "nay": 1,
                  "abstain": 1,
                  "decisionVotes": 5,
                  "yeaPct": 80,
                  "weightedVotes": 6,
                  "weightedYea": 4,
                  "weightedNay": 1,
                  "weightedAbstain": 1,
                  "weightedDecisionVotes": 5,
                  "weightedYeaPct": 80
                },
                "segments": {
                  "verified": {
                    "votes": 6,
                    "yea": 4,
                    "nay": 1,
                    "abstain": 1,
                    "decisionVotes": 5,
                    "yeaPct": 80,
                    "weightedVotes": 6,
                    "weightedYea": 4,
                    "weightedNay": 1,
                    "weightedAbstain": 1,
                    "weightedDecisionVotes": 5,
                    "weightedYeaPct": 80
                  },
                  "selfAttested": {
                    "votes": 0,
                    "yea": 0,
                    "nay": 0,
                    "abstain": 0,
                    "decisionVotes": 0,
                    "yeaPct": null,
                    "weightedVotes": 0,
                    "weightedYea": 0,
                    "weightedNay": 0,
                    "weightedAbstain": 0,
                    "weightedDecisionVotes": 0,
                    "weightedYeaPct": null
                  }
                }
              }
            },
            "byDistrict": {
              "CA-12": {
                "state": "CA",
                "district": "CA-12",
                "totals": {
                  "votes": 6,
                  "yea": 4,
                  "nay": 1,
                  "abstain": 1,
                  "decisionVotes": 5,
                  "yeaPct": 80,
                  "weightedVotes": 6,
                  "weightedYea": 4,
                  "weightedNay": 1,
                  "weightedAbstain": 1,
                  "weightedDecisionVotes": 5,
                  "weightedYeaPct": 80
                },
                "segments": {
                  "verified": {
                    "votes": 6,
                    "yea": 4,
                    "nay": 1,
                    "abstain": 1,
                    "decisionVotes": 5,
                    "yeaPct": 80,
                    "weightedVotes": 6,
                    "weightedYea": 4,
                    "weightedNay": 1,
                    "weightedAbstain": 1,
                    "weightedDecisionVotes": 5,
                    "weightedYeaPct": 80
                  },
                  "selfAttested": {
                    "votes": 0,
                    "yea": 0,
                    "nay": 0,
                    "abstain": 0,
                    "decisionVotes": 0,
                    "yeaPct": null,
                    "weightedVotes": 0,
                    "weightedYea": 0,
                    "weightedNay": 0,
                    "weightedAbstain": 0,
                    "weightedDecisionVotes": 0,
                    "weightedYeaPct": null
                  }
                }
              }
            }
          },
          "reasonBreakdown": {
            "minCount": 3,
            "yea": { "voteCount": 7, "reasons": [{ "reasonKey": "economic_impact", "count": 3, "pct": 42.8571 }] },
            "nay": { "voteCount": 3, "reasons": [] }
          }
        }
        """#

    private func decode(_ json: String) throws -> BillStatsService.BillStats {
        try JSONDecoder.convertingFromSnakeCase().decode(BillStatsService.BillStats.self, from: Data(json.utf8))
    }

    func testDecodesTheContractExampleWithItsComparison() throws {
        let stats = try decode(Self.contractExample)

        let comparison = try XCTUnwrap(stats.comparison)
        XCTAssertEqual(comparison.allUsers, BillStatsService.VoteSplit(votes: 12, yea: 7, nay: 3, abstain: 2, decisionVotes: 10, yeaPct: 70))
        XCTAssertEqual(comparison.verified, BillStatsService.VoteSplit(votes: 6, yea: 4, nay: 1, abstain: 1, decisionVotes: 5, yeaPct: 80))
        XCTAssertFalse(comparison.verifiedWithheld)
        XCTAssertEqual(comparison.minDecisionVotes, 5)
        XCTAssertEqual(stats.resolvedComparison, comparison)

        XCTAssertEqual(stats.totals.yeaPct, 70)
        XCTAssertEqual(stats.totals.weightedYeaPct, 70, "weighted fields still decode while servers send them")
        XCTAssertEqual(stats.rollups.byState["CA"]?.totals.decisionVotes, 5)
        XCTAssertEqual(stats.rollups.byDistrict["CA-12"]?.district, "CA-12")
        XCTAssertEqual(stats.reasonBreakdown?.minCount, 3)

        let rows = VoteResultsFormatting.nationalRows(stats.resolvedComparison)
        XCTAssertEqual(rows.map(\.value.text), ["70% Yea · 30% Nay · 10 votes", "80% Yea · 20% Nay · 5 votes"])
    }

    func testABodyWithoutComparisonFallsBackToTotalsAndSegments() throws {
        let body = try XCTUnwrap(Self.removingComparison(from: Self.contractExample))
        let stats = try decode(body)

        XCTAssertNil(stats.comparison)
        let comparison = stats.resolvedComparison
        XCTAssertEqual(comparison.allUsers, BillStatsService.VoteSplit(stats.totals))
        XCTAssertEqual(comparison.verified, BillStatsService.VoteSplit(stats.segments.verified))
        XCTAssertFalse(comparison.verifiedWithheld, "5 verified Yea or Nay votes meet the floor")
        XCTAssertEqual(comparison.minDecisionVotes, BillStatsService.Comparison.defaultMinDecisionVotes)
    }

    func testABodyWithoutAnyWeightedFieldDecodes() throws {
        let weighted = try NSRegularExpression(pattern: #",\s*"weighted[A-Za-z]+":\s*[-0-9.a-z]+"#)
        let body = weighted.stringByReplacingMatches(
            in: Self.contractExample,
            range: NSRange(Self.contractExample.startIndex..., in: Self.contractExample),
            withTemplate: ""
        )
        XCTAssertFalse(body.contains("weighted"), "precondition: every weighted field removed")

        let stats = try decode(body)
        XCTAssertNil(stats.totals.weightedYeaPct)
        XCTAssertNil(stats.totals.weightedVotes)
        XCTAssertNil(stats.segments.verified.weightedDecisionVotes)
        XCTAssertNil(stats.rollups.byState["CA"]?.totals.weightedYea)
        XCTAssertEqual(stats.totals.yeaPct, 70)
        XCTAssertEqual(stats.rollups.byState["CA"]?.totals.yeaPct, 80)
        XCTAssertNotNil(stats.comparison)
    }

    func testAWithheldComparisonHasNoVerifiedSplit() throws {
        let body = Self.contractExample.replacingOccurrences(
            of: #""verified": { "votes": 6, "yea": 4, "nay": 1, "abstain": 1, "decisionVotes": 5, "yeaPct": 80 },"#,
            with: ""
        ).replacingOccurrences(of: #""verifiedWithheld": false"#, with: #""verifiedWithheld": true"#)
        XCTAssertTrue(body.contains(#""verifiedWithheld": true"#), "precondition")

        let comparison = try XCTUnwrap(decode(body).comparison)
        XCTAssertTrue(comparison.verifiedWithheld)
        XCTAssertNil(comparison.verified)
        XCTAssertEqual(VoteResultsFormatting.nationalRows(comparison)[1].value, .fewerThanFloor(5))
    }

    func testAComparisonWithoutAVerifiedSplitIsWithheldWhateverTheFlagSays() throws {
        let body = Self.contractExample.replacingOccurrences(
            of: #""verified": { "votes": 6, "yea": 4, "nay": 1, "abstain": 1, "decisionVotes": 5, "yeaPct": 80 },"#,
            with: ""
        )
        let comparison = try XCTUnwrap(decode(body).comparison)
        XCTAssertTrue(comparison.verifiedWithheld)
    }

    func testAMalformedComparisonFallsBackInsteadOfFailingTheResponse() throws {
        let body = Self.contractExample.replacingOccurrences(of: #""allUsers":"#, with: #""everyone":"#)
        let stats = try decode(body)
        XCTAssertNil(stats.comparison)
        XCTAssertEqual(stats.resolvedComparison.allUsers, BillStatsService.VoteSplit(stats.totals))
    }

    func testAFloorBelowOneIsRaisedToOne() throws {
        let body = Self.contractExample.replacingOccurrences(of: #""minDecisionVotes": 5"#, with: #""minDecisionVotes": 0"#)
        XCTAssertEqual(try decode(body).comparison?.minDecisionVotes, 1)
    }

    /// The service decodes through the API client the same way (snake-case decoder).
    func testFetchBillStatsDecodesTheComparison() async throws {
        let transport = RecordingTransport()
        transport.responses = [Data(Self.contractExample.utf8)]
        let stats = try await APIClient.$current.withValue(transport.client) {
            try await BillStatsService.fetchBillStats(billId: "BILLS-119hr1285ih")
        }
        XCTAssertEqual(stats.comparison?.allUsers.decisionVotes, 10)
        XCTAssertEqual(stats.comparison?.verified?.yeaPct, 80)
    }

    /// The contract example without its `comparison` block.
    static func removingComparison(from json: String) -> String? {
        guard let start = json.range(of: #"  "comparison": {"#),
              let end = json.range(of: #""minDecisionVotes": 5\n  },\n"#, options: .regularExpression, range: start.upperBound..<json.endIndex)
        else { return nil }
        return json.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
    }
}
