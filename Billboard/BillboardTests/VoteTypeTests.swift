import XCTest
@testable import Billboard

final class VoteTypeTests: XCTestCase {

    // MARK: - feedbackValue

    func testFeedbackValueYea() {
        XCTAssertEqual(VoteType.yea.feedbackValue, "Yea")
    }

    func testFeedbackValueNay() {
        XCTAssertEqual(VoteType.nay.feedbackValue, "Nay")
    }

    func testFeedbackValueAbstain() {
        XCTAssertEqual(VoteType.abstain.feedbackValue, "Abstain")
    }

    func testVoteTypeCountsAsVote() {
        XCTAssertTrue(VoteType.yea.countsAsVote)
        XCTAssertTrue(VoteType.nay.countsAsVote)
        XCTAssertFalse(VoteType.abstain.countsAsVote)
    }

    // MARK: - apiValue alias

    func testApiValueMatchesFeedbackValue() {
        for vote in VoteType.allCases {
            XCTAssertEqual(vote.apiValue, vote.feedbackValue)
        }
    }

    // MARK: - init(apiValue:)

    func testInitFromApiValueYea() {
        XCTAssertEqual(VoteType(apiValue: "Yea"), .yea)
        XCTAssertEqual(VoteType(apiValue: "yea"), .yea)
        XCTAssertEqual(VoteType(apiValue: "YES"), .yea)
        XCTAssertEqual(VoteType(apiValue: "yes"), .yea)
    }

    func testInitFromApiValueNay() {
        XCTAssertEqual(VoteType(apiValue: "Nay"), .nay)
        XCTAssertEqual(VoteType(apiValue: "nay"), .nay)
        XCTAssertEqual(VoteType(apiValue: "NO"), .nay)
        XCTAssertEqual(VoteType(apiValue: "no"), .nay)
    }

    func testInitFromApiValueAbstain() {
        XCTAssertEqual(VoteType(apiValue: "Abstain"), .abstain)
        XCTAssertEqual(VoteType(apiValue: "abstain"), .abstain)
        XCTAssertEqual(VoteType(apiValue: "Abstention"), .abstain)
        XCTAssertEqual(VoteType(apiValue: "abstention"), .abstain)
    }

    func testInitFromApiValueTrimsWhitespace() {
        XCTAssertEqual(VoteType(apiValue: "  Yea  "), .yea)
        XCTAssertEqual(VoteType(apiValue: "\nNay\n"), .nay)
    }

    func testInitFromApiValueReturnsNilForUnknown() {
        XCTAssertNil(VoteType(apiValue: ""))
        XCTAssertNil(VoteType(apiValue: "Maybe"))
        XCTAssertNil(VoteType(apiValue: "present"))
    }

    // MARK: - VoteState equatable

    func testVoteStateEquatable() {
        XCTAssertEqual(VoteState.voted(.yea), VoteState.voted(.yea))
        XCTAssertNotEqual(VoteState.voted(.yea), VoteState.voted(.nay))
        XCTAssertEqual(VoteState.notVoted, VoteState.notVoted)
        XCTAssertEqual(VoteState.unknown, VoteState.unknown)
        XCTAssertNotEqual(VoteState.voted(.yea), VoteState.notVoted)
    }

    func testVoteStateCountsAsVote() {
        XCTAssertTrue(VoteState.voted(.yea).countsAsVote)
        XCTAssertTrue(VoteState.voted(.nay).countsAsVote)
        XCTAssertFalse(VoteState.voted(.abstain).countsAsVote)
        XCTAssertFalse(VoteState.notVoted.countsAsVote)
        XCTAssertFalse(VoteState.unknown.countsAsVote)
    }

    // MARK: - Codable round-trip

    func testVoteTypeCodableRoundTrip() throws {
        for vote in VoteType.allCases {
            let data = try JSONEncoder().encode(vote)
            let decoded = try JSONDecoder().decode(VoteType.self, from: data)
            XCTAssertEqual(decoded, vote)
        }
    }

    func testBillVoteCodableRoundTrip() throws {
        let now = Date()
        let bv = BillVote(vote: .yea, votedAt: now, cachedAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bv)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BillVote.self, from: data)

        XCTAssertEqual(decoded.vote, bv.vote)
        // Dates lose sub-second precision in ISO-8601, so compare within 1 second.
        XCTAssertEqual(decoded.votedAt.timeIntervalSince1970, bv.votedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - Conversions used by the vote bar (spec D 2.1.4)

    @MainActor
    func testUserVoteRoundTripsThroughVoteType() {
        for vote in VoteType.allCases {
            XCTAssertEqual(UserVote(vote).voteType, vote)
        }
        XCTAssertEqual(UserVote(.yea), .yea)
        XCTAssertEqual(UserVote(.nay), .nay)
        XCTAssertEqual(UserVote(.abstain), .abstain)
        XCTAssertFalse(UserVote(.abstain).countsAsVote)
    }

    func testVoteStateChoiceIncludesAbstain() {
        XCTAssertEqual(VoteState.voted(.yea).choice, .yea)
        XCTAssertEqual(VoteState.voted(.nay).choice, .nay)
        XCTAssertEqual(VoteState.voted(.abstain).choice, .abstain, "an abstention made on the screen is shown")
        XCTAssertNil(VoteState.notVoted.choice)
        XCTAssertNil(VoteState.unknown.choice)
    }

    func testVoteChoiceMatchesTheVoteTypeForEveryCase() {
        for vote in VoteType.allCases {
            XCTAssertEqual(VoteChoice(vote).voteType, vote)
            XCTAssertEqual(VoteChoice(vote).title, vote.feedbackValue)
        }
    }
}
