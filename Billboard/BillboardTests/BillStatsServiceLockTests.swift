import XCTest
@testable import Billboard

/// INT-11: `GET /bill-stats` answers `RESULTS_LOCKED` (403) until the server holds the caller's Yea, Nay
/// or Abstain on the bill or its companion group. `BillStatsService.fetchBillStats` turns that code into
/// `FetchError.resultsLocked`, also when a proxy envelope wraps the body, and passes every other failure
/// through unchanged. The 200 body decodes as before.
@MainActor
final class BillStatsServiceLockTests: XCTestCase {
    private static let guid = "BILLS-119hr4300"

    /// Amplify keeps the body of an HTTP error; the tests' stand-in carries it in `userInfo` (an
    /// `AWSHTTPURLResponse` with a status cannot be built in tests).
    private func errorWithBody(_ body: String) -> Error {
        NSError(domain: "BillboardTests.backend", code: 403, userInfo: ["body": Data(body.utf8)])
    }

    private func fetch(failingWith error: Error?, response: Data = Data()) async -> Result<BillStatsService.BillStats, Error> {
        let transport = RecordingTransport()
        transport.responses = [response]
        if let error {
            transport.failure = { _ in error }
        }
        do {
            let stats = try await APIClient.$current.withValue(transport.client) {
                try await BillStatsService.fetchBillStats(billId: Self.guid, scope: .companions)
            }
            XCTAssertEqual(transport.requests.map(\.path), ["bill-stats"])
            return .success(stats)
        } catch {
            return .failure(error)
        }
    }

    private func isResultsLocked(_ result: Result<BillStatsService.BillStats, Error>) -> Bool {
        if case .failure(let error) = result, let fetchError = error as? BillStatsService.FetchError {
            return fetchError == .resultsLocked
        }
        return false
    }

    func testResultsLockedMapsToItsOwnError() async {
        let plain = await fetch(failingWith: backendError("RESULTS_LOCKED"))
        XCTAssertTrue(isResultsLocked(plain), "\(plain)")

        let withMessage = await fetch(failingWith: errorWithBody(
            #"{"error":"RESULTS_LOCKED","message":"Vote or abstain on this bill to see its results."}"#
        ))
        XCTAssertTrue(isResultsLocked(withMessage))

        // A Lambda proxy envelope around the body.
        let enveloped = await fetch(failingWith: errorWithBody(
            #"{"statusCode":403,"body":"{\"error\":\"RESULTS_LOCKED\",\"message\":\"Vote or abstain on this bill to see its results.\"}"}"#
        ))
        XCTAssertTrue(isResultsLocked(enveloped))
    }

    func testOtherFailuresPassThroughUnchanged() async {
        let otherCode = await fetch(failingWith: backendError("ADULT_STATUS_LOCKED"))
        XCTAssertFalse(isResultsLocked(otherCode))
        if case .failure(let error) = otherCode {
            XCTAssertEqual(APIErrorResponse.errorCode(from: error), "ADULT_STATUS_LOCKED", "the original error")
        }

        let forbidden = await fetch(failingWith: httpStatusError(403, path: "bill-stats"))
        XCTAssertFalse(isResultsLocked(forbidden), "a 403 without the code")

        let serverError = await fetch(failingWith: httpStatusError(503, path: "bill-stats"))
        XCTAssertFalse(isResultsLocked(serverError))
        if case .failure(let error) = serverError {
            XCTAssertEqual(APIErrorDebug.httpStatusCode(from: error), 503)
        }

        let offline = await fetch(failingWith: URLError(.notConnectedToInternet))
        XCTAssertFalse(isResultsLocked(offline))
        if case .failure(let error) = offline {
            XCTAssertTrue(APIErrorResponse.isNetworkFailure(error))
        }

        let lowercase = await fetch(failingWith: errorWithBody(#"{"error":"results_locked"}"#))
        XCTAssertFalse(isResultsLocked(lowercase), "only the exact code")
    }

    func testTheUnlockedBodyDecodesAsBefore() async throws {
        let body = #"""
        {"billId":"BILLS-119hr4300","totals":{"votes":46,"yea":25,"nay":15,"abstain":6,"decisionVotes":40,"yeaPct":62.5},
         "segments":{"verified":{"votes":12,"yea":7,"nay":5,"abstain":0,"decisionVotes":12,"yeaPct":58.3},
                     "selfAttested":{"votes":34,"yea":18,"nay":10,"abstain":6,"decisionVotes":28,"yeaPct":64.3}},
         "rollups":{"byState":{},"byDistrict":{}},"companionBillIds":["BILLS-119hr4300","BILLS-119s2100"]}
        """#
        let result = await fetch(failingWith: nil, response: Data(body.utf8))
        let stats = try result.get()
        XCTAssertEqual(stats.billId, Self.guid)
        XCTAssertEqual(stats.totals.yea, 25)
        XCTAssertEqual(stats.companionBillIds, ["BILLS-119hr4300", "BILLS-119s2100"])
    }
}
