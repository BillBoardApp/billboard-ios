import XCTest
@testable import Billboard

/// Pins the request each service sends (method, path, query, body, auth mode, log label, extra
/// headers) by running it against a recording `APIClient` transport, and the headers every API
/// request carries (spec C3 3.8 and 3.10, spec D 2.8.1, integration plan X16). Services with an
/// Amplify session check before the request (preferences, device notification settings) are
/// not covered here.
final class APIRequestShapeTests: XCTestCase {
    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// Runs `operation` on `transport`, with `appAttest` (a fake that hands out `v1.b` by default) as the
    /// App Attest manager.
    @MainActor
    private func run<T>(
        _ transport: RecordingTransport,
        appAttest: any AppAttestManaging = FakeAppAttestManager(),
        _ operation: () async throws -> T
    ) async throws -> T {
        try await AppAttestManager.$current.withValue(appAttest) {
            try await APIClient.$current.withValue(transport.client) {
                try await operation()
            }
        }
    }

    // MARK: - Votes

    @MainActor
    func testSetFeedbackPostsTheVoteWithCleanedReasons() async throws {
        let transport = RecordingTransport()

        try await run(transport) {
            try await BillVotesService.setFeedback(
                billId: "BILLS-119hr1ih",
                feedback: .nay,
                reasons: [" healthcare ", "economic_impact", "healthcare", ""]
            )
        }

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "feedback")
        XCTAssertNil(request.queryParameters)
        XCTAssertEqual(request.label, "BillVotesService feedback")
        XCTAssertEqual(request.authMode, .requireSignedIn)
        XCTAssertEqual(
            try jsonObject(request.body),
            ["billId": "BILLS-119hr1ih", "feedback": "Nay", "reasons": ["economic_impact", "healthcare"]] as NSDictionary
        )
    }

    @MainActor
    func testSetFeedbackOmitsReasonsWhenThereAreNone() async throws {
        let transport = RecordingTransport()

        try await run(transport) {
            try await BillVotesService.setFeedback(billId: "BILLS-119hr1ih", feedback: .yea)
        }

        XCTAssertEqual(
            try jsonObject(transport.requests.first?.body),
            ["billId": "BILLS-119hr1ih", "feedback": "Yea"] as NSDictionary
        )
    }

    @MainActor
    func testFetchSingleVoteUsesAQueryParameter() async throws {
        let transport = RecordingTransport()

        let state = try await run(transport) {
            try await BillVotesService.fetchFeedback(billId: "BILLS-119hr1ih")
        }

        XCTAssertEqual(state, .notVoted)
        XCTAssertEqual(
            transport.requests,
            [
                APIClient.Request(
                    method: .get,
                    path: "feedback",
                    queryParameters: ["billId": "BILLS-119hr1ih"],
                    body: nil,
                    label: "BillVotesService feedback",
                    authMode: .requireSignedIn,
                    traceTimeline: false
                )
            ]
        )
    }

    @MainActor
    func testFetchVoteBatchPostsDeduplicatedIds() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"votes":[{"billId":"A","feedback":"Yea","votedAt":"2026-09-20T12:00:00Z"}]}"#)]

        let states = try await run(transport) {
            try await BillVotesService.fetchFeedback(billIds: [" A ", "B", "A", ""])
        }

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "feedback-batch")
        XCTAssertNil(request.queryParameters)
        XCTAssertEqual(request.label, "BillVotesService feedback-batch")
        let body = try jsonObject(request.body)
        XCTAssertEqual(Set(try XCTUnwrap(body["billIds"] as? [String])), ["A", "B"])
        XCTAssertEqual(body.count, 1)

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states["B"], .notVoted)
        guard case .voted(let vote)? = states["A"] else {
            return XCTFail("Expected a vote for A, got \(String(describing: states["A"]))")
        }
        XCTAssertEqual(vote.vote, .yea)
    }

    @MainActor
    func testBillStatsSendsIdAndForceRefreshAndRejectsAnUnreadablePayload() async throws {
        let transport = RecordingTransport()
        transport.responses = [json("{}")]

        do {
            _ = try await run(transport) {
                try await BillStatsService.fetchBillStats(billId: " BILLS-119hr1ih ", forceRefresh: true)
            }
            XCTFail("Expected invalidPayload")
        } catch {
            XCTAssertEqual(error as? APIServiceError, .invalidPayload("bill-stats"))
        }

        XCTAssertEqual(
            transport.requests,
            [
                APIClient.Request(
                    method: .get,
                    path: "bill-stats",
                    queryParameters: ["billId": "BILLS-119hr1ih", "forceRefresh": "true"],
                    body: nil,
                    label: "BillStatsService bill-stats",
                    authMode: .requireSignedIn,
                    traceTimeline: false
                )
            ]
        )
    }

    // MARK: - Bills and Congress (public routes)

    @MainActor
    func testBillsManifestRequestsArePublicAndTraced() async throws {
        let transport = RecordingTransport()
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T08:30:00Z"))

        // Empty payloads return before the manifest cache is written.
        let full = try await run(transport) { try await BillsService.getBillsManifest(updatedAfter: nil) }
        let windowed = try await run(transport) { try await BillsService.getBillsManifest(updatedAfter: since) }

        XCTAssertEqual(full, [])
        XCTAssertEqual(windowed, [])
        XCTAssertEqual(transport.requests.map(\.path), ["bills-manifest", "bills-manifest"])
        XCTAssertEqual(transport.requests.map(\.method), [.get, .get])
        XCTAssertEqual(transport.requests.map(\.authMode), [.autoFetch, .autoFetch])
        XCTAssertEqual(transport.requests.map(\.traceTimeline), [true, true])
        XCTAssertEqual(transport.requests.map(\.label), ["BillsService bills-manifest", "BillsService bills-manifest"])
        // The full manifest asks for snapshot delivery (CAP-01); a windowed one does not.
        XCTAssertEqual(transport.requests[0].queryParameters, ["delivery": "snapshot"])
        XCTAssertEqual(transport.requests[1].queryParameters, ["updatedAfter": "2026-09-17T08:30:00.000Z"])
    }

    @MainActor
    func testProcessedBillAsksWithTheDerivedLocatorFirst() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"""
        {"schemaVersion":1,"kind":"processed","storedAt":"2026-09-20T12:00:00.000Z",
         "identifier":{"congress":"119","billType":"hr","billNumber":"1"},
         "guid":"BILLS-119hr1ih","title":"Lower Costs Act","link":"https://example.test/bill","soWhat":"Lowers costs.",
         "billBreakdown":{"who":"","what":"","how":"","when":"","where":"","why":""},
         "subCategories":[],"lifeAreas":[],"sponsors":[],"cosponsors":[],"billStatus":"Passed House"}
        """#)]

        let bill = try await run(transport) {
            try await BillsService.getProcessedBill(guid: " BILLS-119hr1ih ")
        }

        XCTAssertEqual(
            transport.requests,
            [
                APIClient.Request(
                    method: .get,
                    path: "processed-bill",
                    queryParameters: ["guid": "BILLS-119hr1ih", "congress": "119", "type": "hr"],
                    body: nil,
                    label: "BillsService processed-bill",
                    authMode: .autoFetch,
                    traceTimeline: false
                )
            ]
        )
        XCTAssertEqual(bill.title, "Lower Costs Act")
        XCTAssertEqual(bill.billStatus, .passed)
        XCTAssertEqual(bill.guid, "BILLS-119hr1ih")
        XCTAssertEqual(bill.congress, "119")
        XCTAssertEqual(bill.billType, "hr")
        XCTAssertEqual(bill.billID, "1")
        XCTAssertEqual(bill.isProcessedDetailHydrated, true)
    }

    @MainActor
    func testCongressManifestRequestIsPublic() async throws {
        let transport = RecordingTransport()

        let members = try await run(transport) { try await CongressService.getCongressMembersManifest() }

        XCTAssertTrue(members.isEmpty)
        XCTAssertEqual(
            transport.requests,
            [
                APIClient.Request(
                    method: .get,
                    path: "congress-members-manifest",
                    queryParameters: nil,
                    body: nil,
                    label: "CongressService congress-members-manifest",
                    authMode: .autoFetch,
                    traceTimeline: false
                )
            ]
        )
    }

    // MARK: - Account and district

    @MainActor
    func testManualDistrictSelectionPostsNormalizedValues() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"body":{"verified":false,"status":"self_reported"}}"#)]

        let status = try await run(transport) {
            try await DistrictVerificationService.submitManualSelection(state: " ca ", district: "CA-07")
        }

        XCTAssertEqual(status.status, "self_reported")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "district-verification")
        XCTAssertNil(request.queryParameters)
        XCTAssertEqual(request.authMode, .requireSignedIn)
        XCTAssertEqual(request.label, "DistrictVerificationService district-verification")
        XCTAssertEqual(try jsonObject(request.body), ["state": "CA", "district": "7"] as NSDictionary)
    }

    @MainActor
    func testAdultAttestationPostsTheAnswer() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"adult_status":"attested_adult","can_write":true}"#)]

        let snapshot = try await run(transport) {
            try await AccountComplianceService.submitAdultAttestation(isAdult: true)
        }

        XCTAssertEqual(snapshot.adultStatus, .attestedAdult)
        XCTAssertTrue(snapshot.canWrite)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "adult-attestation")
        XCTAssertEqual(request.label, "AccountComplianceService adult-attestation")
        XCTAssertEqual(try jsonObject(request.body), ["isAdult": true] as NSDictionary)
    }

    @MainActor
    func testDeleteAccountDataOptsInThroughTheQuery() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"deletionStatus":"completed","deletionCompletedAt":"2026-09-24T10:00:00Z"}"#)]

        let snapshot = try await run(transport) { try await AccountComplianceService.deleteAccountData() }

        XCTAssertEqual(snapshot.deletionStatus, .completed)
        XCTAssertEqual(
            transport.requests,
            [
                APIClient.Request(
                    method: .delete,
                    path: "account-data",
                    queryParameters: ["deleteSignIn": "1"],
                    body: nil,
                    label: "AccountComplianceService account-data delete",
                    authMode: .requireSignedIn,
                    traceTimeline: false
                )
            ]
        )
    }

    @MainActor
    func testAccountComplianceReportsItsOwnErrorForAnUnreadablePayload() async {
        let transport = RecordingTransport()
        transport.responses = [json("[]")]

        do {
            _ = try await run(transport) { try await AccountComplianceService.fetchMe() }
            XCTFail("Expected invalidPayload")
        } catch {
            XCTAssertEqual(error as? AccountComplianceService.ServiceError, .invalidPayload)
        }
        XCTAssertEqual(transport.requests.map(\.path), ["me"])
    }

    // MARK: - Civic and digest

    @MainActor
    func testCivicAndDigestRequestsRequireSignIn() async throws {
        let transport = RecordingTransport()
        transport.responses = [json(#"{"votesUsed":0,"totalVotesWithProfile":0,"isReady":false}"#)]

        _ = try await run(transport) { try await CivicService.fetchCivicProfile() }
        let digest = try await run(transport) { try await WeeklyDigestService.fetchLatest() }

        XCTAssertNil(digest, "an empty payload means no published digest")
        XCTAssertEqual(transport.requests.map(\.path), ["civic-profile", "weekly-digests/latest"])
        XCTAssertEqual(transport.requests.map(\.method), [.get, .get])
        XCTAssertEqual(transport.requests.map(\.authMode), [.requireSignedIn, .requireSignedIn])
        XCTAssertEqual(transport.requests.map(\.label), ["CivicProfileService civic-profile", "WeeklyDigestService latest"])
    }

    // MARK: - App Attest header (spec C3 3.4, 3.10)

    @MainActor
    func testSetFeedbackGoesThroughAppAttestWithTheHeaderOverTheBodyItSends() async throws {
        let transport = RecordingTransport()
        let appAttest = FakeAppAttestManager(headers: [AppAttestWire.attestHeader: "v1.e.timeout"])

        try await run(transport, appAttest: appAttest) {
            try await BillVotesService.setFeedback(billId: "BILLS-119hr1ih", feedback: .yea, reasons: ["healthcare"])
        }

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.path, "feedback")
        XCTAssertEqual(request.headers, ["X-Billboard-App-Attest": "v1.e.timeout"])
        // The assertion is bound to the method, the route and the exact bytes sent.
        XCTAssertEqual(appAttest.protectedCalls, [.init(method: "POST", path: "feedback", body: request.body)])
        XCTAssertEqual(AppAttestWire.normalizedPath(try XCTUnwrap(appAttest.protectedCalls.first).path), "/feedback")
    }

    @MainActor
    func testOnlyTheVotePostCarriesTheAttestationHeader() async throws {
        let transport = RecordingTransport()
        let appAttest = FakeAppAttestManager()

        try await run(transport, appAttest: appAttest) {
            _ = try? await BillVotesService.fetchFeedback(billId: "BILLS-119hr1ih")
            _ = try? await BillVotesService.fetchFeedback(billIds: ["BILLS-119hr1ih", "BILLS-119hr2ih"])
            _ = try? await BillStatsService.fetchBillStats(billId: "BILLS-119hr1ih")
            _ = try? await BillsService.getBillsManifest(updatedAfter: nil)
            _ = try? await CongressService.getCongressMembersManifest()
            _ = try? await DistrictVerificationService.submitManualSelection(state: "CA", district: "7")
            _ = try? await AccountComplianceService.submitAdultAttestation(isAdult: true)
            _ = try? await CivicService.fetchCivicProfile()
            _ = try? await WeeklyDigestService.fetchLatest()
            _ = try? await AppAttestService.issueChallenge(purpose: .assert)
            try await BillVotesService.setFeedback(billId: "BILLS-119hr1ih", feedback: .nay)
        }

        let protected = transport.requests.filter { $0.method == .post && $0.path == "feedback" }
        let others = transport.requests.filter { !($0.method == .post && $0.path == "feedback") }
        XCTAssertEqual(protected.count, 1)
        XCTAssertEqual(protected.first?.headers, ["X-Billboard-App-Attest": "v1.b"])
        XCTAssertGreaterThanOrEqual(others.count, 10)
        for request in others {
            XCTAssertEqual(request.headers, [:], "\(request.method.rawValue) \(request.path)")
        }
        XCTAssertEqual(appAttest.protectedCalls.count, 1)
    }

    @MainActor
    func testTheLegacySetFeedbackFallbackIsSentWithoutTheHeader() async throws {
        let transport = RecordingTransport()
        transport.failure = { request in request.path == "feedback" ? httpStatusError(404) : nil }
        let appAttest = FakeAppAttestManager()

        try await run(transport, appAttest: appAttest) {
            try await BillVotesService.setFeedback(billId: "BILLS-119hr1ih", feedback: .nay)
        }

        XCTAssertEqual(transport.requests.map(\.path), ["feedback", "setFeedback"])
        XCTAssertEqual(transport.requests[0].headers, ["X-Billboard-App-Attest": "v1.b"])
        XCTAssertEqual(transport.requests[1].headers, [:])
        XCTAssertEqual(transport.requests[1].body, transport.requests[0].body)
        XCTAssertEqual(appAttest.protectedCalls.count, 1, "the fallback is not a protected request")
    }

    @MainActor
    func testAFailedVoteRethrowsTheServerError() async throws {
        let transport = RecordingTransport()
        transport.failure = { _ in backendError("VOTE_DAILY_LIMIT") }

        do {
            try await run(transport) {
                try await BillVotesService.setFeedback(billId: "BILLS-119hr1ih", feedback: .yea)
            }
            XCTFail("Expected the server's refusal")
        } catch {
            XCTAssertEqual(APIErrorResponse.errorCode(from: error), "VOTE_DAILY_LIMIT")
        }
        XCTAssertEqual(transport.requests.map(\.path), ["feedback"])
    }

    @MainActor
    func testTheLiveManagerSendsABypassMarkerFromAnUnsupportedDebugDevice() async throws {
        for (isDebugBuild, marker) in [(true, "v1.b"), (false, "v1.u")] {
            var configuration = AppAttestManager.Configuration()
            configuration.isEnabled = true
            configuration.isDebugBuild = isDebugBuild
            var dependencies = AppAttestManager.Dependencies.live
            dependencies.attest = UnsupportedAppAttestDevice()
            let manager = AppAttestManager(configuration: configuration, dependencies: dependencies)
            let transport = RecordingTransport()

            try await run(transport, appAttest: manager) {
                try await BillVotesService.setFeedback(billId: "BILLS-119hr1ih", feedback: .yea)
            }

            XCTAssertEqual(transport.requests.map(\.headers), [["X-Billboard-App-Attest": marker]], "debug \(isDebugBuild)")
        }
    }

    @MainActor
    func testWithAppAttestOffTheVoteCarriesNoHeader() async throws {
        var configuration = AppAttestManager.Configuration()
        configuration.isEnabled = false
        let transport = RecordingTransport()

        try await run(transport, appAttest: AppAttestManager(configuration: configuration)) {
            try await BillVotesService.setFeedback(billId: "BILLS-119hr1ih", feedback: .yea)
        }

        XCTAssertEqual(transport.requests.map(\.headers), [[:]])
    }

    // MARK: - Headers on every request (spec C3 3.8, integration plan X16)

    func testEveryRequestCarriesTheAppVersionAndExtraHeadersNeverReplaceTheFixedOnes() {
        let headers = APIRequestHeaders.make(
            authorization: "Bearer id-token",
            hasBody: true,
            extraHeaders: [
                "X-Billboard-App-Attest": "v1.b",
                "Authorization": "Bearer forged",
                "authorization": "Bearer forged",
                "ACCEPT": "text/html",
                "content-type": "text/plain",
                "x-billboard-app-version": "0.1"
            ],
            appVersion: "1.2"
        )

        XCTAssertEqual(
            headers,
            [
                "Accept": "application/json",
                "Authorization": "Bearer id-token",
                "Content-Type": "application/json",
                "X-Billboard-App-Version": "1.2",
                "X-Billboard-App-Attest": "v1.b"
            ]
        )
    }

    func testASignedOutRequestCannotGainATokenFromExtraHeaders() {
        let headers = APIRequestHeaders.make(
            authorization: nil,
            hasBody: false,
            extraHeaders: ["Authorization": "Bearer forged", "X-Billboard-App-Attest": "v1.u"],
            appVersion: "1.2"
        )

        XCTAssertEqual(
            headers,
            ["Accept": "application/json", "X-Billboard-App-Version": "1.2", "X-Billboard-App-Attest": "v1.u"]
        )
    }

    func testAGetWithoutExtrasCarriesOnlyAcceptTokenAndVersion() {
        XCTAssertEqual(
            APIRequestHeaders.make(authorization: "Bearer id-token", hasBody: false, extraHeaders: [:], appVersion: "1.2"),
            ["Accept": "application/json", "Authorization": "Bearer id-token", "X-Billboard-App-Version": "1.2"]
        )
        XCTAssertEqual(
            APIRequestHeaders.make(authorization: nil, hasBody: false, extraHeaders: [:], appVersion: nil),
            ["Accept": "application/json"],
            "an unreadable version leaves the header out"
        )
    }

    func testTheVersionHeaderCarriesThisBuildsVersion() {
        XCTAssertEqual(APIRequestHeaders.appVersionName, "X-Billboard-App-Version")
        XCTAssertEqual(APIRequestHeaders.appVersion, AppAttestWire.appVersion(from: Bundle.main.infoDictionary))
        XCTAssertNotNil(APIRequestHeaders.appVersion, "MARKETING_VERSION is a valid AppVersion")
    }

    func testTheManifestSnapshotDownloadCarriesNoBillboardHeaders() throws {
        let url = try XCTUnwrap(URL(string: "https://bucket.s3.amazonaws.com/manifest/snapshot.json?X-Amz-Signature=abc"))

        let request = BillsManifestSnapshotClient.request(for: url)

        XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
    }

    func testOnlyA426WithAppUpdateRequiredAsksForAnUpdate() {
        XCTAssertTrue(APIRequest.isAppUpdateRequired(status: 426, code: "APP_UPDATE_REQUIRED"))
        XCTAssertFalse(APIRequest.isAppUpdateRequired(status: 426, code: nil))
        XCTAssertFalse(APIRequest.isAppUpdateRequired(status: 426, code: "APP_ATTEST_REQUIRED"))
        XCTAssertFalse(APIRequest.isAppUpdateRequired(status: 403, code: "APP_UPDATE_REQUIRED"))
        XCTAssertFalse(APIRequest.isAppUpdateRequired(status: nil, code: "APP_UPDATE_REQUIRED"))
    }
}

/// A device without App Attest (the Simulator): the manager never reaches the key, the server or storage.
private final class UnsupportedAppAttestDevice: AppAttestProviding, @unchecked Sendable {
    var isSupported: Bool { false }
    func generateKey() async throws -> String { throw FakeServiceError() }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw FakeServiceError() }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { throw FakeServiceError() }
}
