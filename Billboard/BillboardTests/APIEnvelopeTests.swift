import XCTest
@testable import Billboard

/// `APIEnvelope` unwraps a Lambda proxy envelope (`{"body": ...}`) exactly once. Every
/// API response passes through it before decoding (`APIClient.payload`).
final class APIEnvelopeTests: XCTestCase {
    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testUnwrapsStringBody() {
        let wrapped = json(#"{"statusCode":200,"headers":{},"body":"{\"civicScore\":12}"}"#)
        XCTAssertEqual(APIEnvelope.unwrap(wrapped), json(#"{"civicScore":12}"#))
    }

    func testUnwrapsObjectBody() throws {
        let wrapped = json(#"{"body":{"verified":true,"status":"verified"}}"#)
        let inner = try jsonObject(APIEnvelope.unwrap(wrapped))
        XCTAssertEqual(inner, ["verified": true, "status": "verified"] as NSDictionary)
    }

    func testUnwrapsArrayBody() throws {
        let wrapped = json(#"{"body":[{"billId":"A"}]}"#)
        let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: APIEnvelope.unwrap(wrapped)) as? [[String: String]])
        XCTAssertEqual(inner, [["billId": "A"]])
    }

    func testLeavesPayloadsWithoutAnEnvelopeUnchanged() {
        let cases = [
            #"{"billId":"BILLS-119hr1ih","feedback":"Yea"}"#,
            #"{"kind":"body"}"#,            // "body" as a value, not a key
            #"{"body":42}"#,                // not JSON text or a JSON container
            #"{"body":null}"#,
            #"{"body":""}"#,                // empty body string
            #"["body"]"#,                   // top level is not an object
            #"not json "body""#,
            "",
            "   "
        ]
        for raw in cases {
            XCTAssertEqual(APIEnvelope.unwrap(json(raw)), json(raw), raw)
            XCTAssertNil(APIEnvelope.payload(in: json(raw)), raw)
        }
    }

    func testAllowsWhitespaceBeforeTheEnvelope() {
        let wrapped = json("\n  " + #"{"body":"[]"}"#)
        XCTAssertEqual(APIEnvelope.unwrap(wrapped), json("[]"))
    }

    func testUnwrapsOnlyOnce() {
        let doublyWrapped = json(#"{"body":"{\"body\":\"{}\"}"}"#)
        XCTAssertEqual(APIEnvelope.unwrap(doublyWrapped), json(#"{"body":"{}"}"#))
    }

    // MARK: - Through the services

    @MainActor
    func testClientDecodesAnEnvelopedResponse() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"body":"{\"votesUsed\":3,\"totalVotesWithProfile\":5,\"isReady\":false}"}"#)]

        let profile = try await APIClient.$current.withValue(transport.client) {
            try await CivicService.fetchCivicProfile()
        }

        XCTAssertEqual(profile.votesUsed, 3)
        XCTAssertFalse(profile.isReady)
    }

    @MainActor
    func testClientRethrowsTheDecodingErrorForAnUnreadablePayload() async {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"body":"{\"unexpected\":true}"}"#)]

        do {
            _ = try await APIClient.$current.withValue(transport.client) {
                try await CivicService.fetchCivicScore()
            }
            XCTFail("Expected a decoding error")
        } catch {
            XCTAssertTrue(error is DecodingError, "got \(error)")
        }
    }

    /// Before the shared decode path, the vote decoders tried the raw payload first. Their
    /// all-optional DTO matched `{"body": ...}` itself, so an enveloped vote read as "not
    /// voted". The envelope is now unwrapped before any shape is tried.
    @MainActor
    func testEnvelopedVoteIsReadAsTheVote() async throws {
        let transport = RecordingTransport()
        transport.responses = [
            json(#"{"body":"{\"billId\":\"BILLS-119hr1ih\",\"feedback\":\"Yea\",\"votedAt\":\"2026-09-20T12:00:00Z\"}"}"#)
        ]

        let state = try await APIClient.$current.withValue(transport.client) {
            try await BillVotesService.fetchFeedback(billId: "BILLS-119hr1ih")
        }

        let votedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z"))
        XCTAssertEqual(state, .voted(.init(vote: .yea, votedAt: votedAt)))
    }

    @MainActor
    func testBatchVoteDecoderReadsWrapperShapes() throws {
        let payload = json(#"{"items":[{"bill_id":"A","feedback":"nay","voted_at":"2026-09-20T12:00:00Z"},{"billId":"C","feedback":"Yea"}],"not_voted_bill_ids":["B"]}"#)

        let states = try BillVotesService.decodeBatchVoteStates(from: payload, requestedBillIds: ["A", "B", "C", "D"])

        let votedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z"))
        XCTAssertEqual(states["A"], .voted(.init(vote: .nay, votedAt: votedAt)))
        XCTAssertEqual(states["B"], .notVoted)
        XCTAssertEqual(states["C"], .notVoted, "a vote without a timestamp is not trusted")
        XCTAssertEqual(states["D"], .notVoted)
    }

    @MainActor
    func testVoteDecoderRejectsNonObjectPayloads() {
        XCTAssertThrowsError(try BillVotesService.decodeVoteState(from: json("[1,2]"))) { error in
            XCTAssertEqual(error as? APIServiceError, .invalidPayload("feedback"))
        }
        XCTAssertEqual(try BillVotesService.decodeVoteState(from: Data()), .notVoted)
    }
}
