import os
import XCTest
@testable import Billboard

/// How `BillsService.fetchBillsManifest(updatedAfter:)` gets the manifest (CAP-01). A full fetch asks
/// for `delivery=snapshot`; a pointer answer is downloaded from S3 without auth, then the bills updated
/// since shortly before the snapshot are merged over it. An inline answer is used as it is. When S3
/// rejects the presigned URL (403 or 400) the pointer is requested once more; any other snapshot
/// failure, or a second rejection, fails the fetch (there is no plain full request any more).
/// Windowed fetches are unchanged. The API client runs on a `RecordingTransport` and the snapshot
/// session on `StubURLProtocol`; `fetchBillsManifest` leaves the manifest cache alone.
///
/// `StubURLProtocol` hands URLSession the body as it is, so these tests cannot exercise URLSession's
/// real gzip decoding (`Content-Encoding: gzip`); they cover the check for a body left encoded.
final class BillsManifestDeliveryTests: XCTestCase {
    private static let snapshotURL = "https://billboard-bills-manifest-example.s3.us-east-1.amazonaws.com/snapshots/bills-manifest.v1.json.gz?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260920T120000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&X-Amz-Signature=0123456789abcdef"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func pointer(
        generatedAt: String = "2026-09-20T12:00:00.000Z",
        expiresAt: String = "2999-01-01T00:00:00.000Z"
    ) -> Data {
        Data(#"{"snapshotUrl":"\#(Self.snapshotURL)","generatedAt":"\#(generatedAt)","count":3,"expiresAt":"\#(expiresAt)"}"#.utf8)
    }

    /// A contract `BillsManifest` of bills keyed by guid, each titled `title`. `groups` adds
    /// `companionGroups` (APPF-23) as House/Senate pairs; nil leaves the field out.
    private func manifest(
        generatedAt: String = "2026-09-20T12:00:00.000Z",
        _ bills: [(guid: String, title: String)],
        groups: [(String, String)]? = nil
    ) -> Data {
        let items = bills.map { #"{"guid":"\#($0.guid)","billType":"hr","title":"\#($0.title)","updatedAt":"2026-09-20T11:00:00.000Z"}"# }
        let groupsField = groups.map { pairs in
            let list = pairs.map { #"{"primaryGuid":"\#($0.0)","memberGuids":["\#($0.0)","\#($0.1)"],"relationship":"identical"}"# }
            return #","companionGroups":[\#(list.joined(separator: ","))]"#
        } ?? ""
        return Data(#"{"generatedAt":"\#(generatedAt)","count":\#(bills.count),"bills":[\#(items.joined(separator: ","))]\#(groupsField)}"#.utf8)
    }

    private func stub(_ body: Data) -> StubURLProtocol.Stub {
        StubURLProtocol.Stub(body: body)
    }

    @MainActor
    private func fetch(
        _ transport: RecordingTransport,
        updatedAfter: Date? = nil
    ) async throws -> BillsService.FetchedManifest? {
        let snapshotClient = BillsManifestSnapshotClient(session: StubURLProtocol.session())
        return try await APIClient.$current.withValue(transport.client) {
            try await BillsManifestSnapshotClient.$current.withValue(snapshotClient) {
                try await BillsService.fetchBillsManifest(updatedAfter: updatedAfter)
            }
        }
    }

    // MARK: - Pointer

    @MainActor
    func testPointerDownloadsTheSnapshotWithoutAuthAndMergesTheDelta() async throws {
        let transport = RecordingTransport()
        transport.responses = [
            pointer(generatedAt: "2026-09-20T12:00:00.000Z"),
            manifest([("B", "B updated"), ("D", "D new")])
        ]
        // A publish landed after the pointer was issued: the object is newer than the pointer says.
        StubURLProtocol.reset([stub(manifest(generatedAt: "2026-09-20T12:05:00.000Z", [("A", "A"), ("B", "B"), ("C", "C")]))])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(fetched.source, "snapshot")
        XCTAssertEqual(fetched.items.map(\.guid), ["A", "B", "C", "D"])
        XCTAssertEqual(fetched.items.map(\.title), ["A", "B updated", "C", "D new"])

        // The pointer request, then the delta from the downloaded manifest's generatedAt minus 15 minutes.
        XCTAssertEqual(transport.requests.map(\.path), ["bills-manifest", "bills-manifest"])
        XCTAssertEqual(transport.requests.map(\.queryParameters), [["delivery": "snapshot"], ["updatedAfter": "2026-09-20T11:50:00.000Z"]])
        XCTAssertEqual(transport.requests.map(\.label), ["BillsService bills-manifest", "BillsService bills-manifest delta"])
        XCTAssertEqual(transport.requests.map(\.authMode), [.autoFetch, .autoFetch])

        // The snapshot went straight to the presigned URL, with no auth of any kind.
        let snapshotRequest = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(snapshotRequest.url?.absoluteString, Self.snapshotURL)
        XCTAssertEqual(snapshotRequest.httpMethod, "GET")
        XCTAssertNil(snapshotRequest.value(forHTTPHeaderField: "Authorization"))
        let headerNames = Set((snapshotRequest.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertTrue(headerNames.isDisjoint(with: ["authorization", "cookie", "x-amz-security-token", "x-api-key"]), "\(headerNames)")
    }

    @MainActor
    func testSnapshotSessionCarriesNoCredentialsCookiesOrCache() throws {
        let configuration = BillsManifestSnapshotClient.liveSession.configuration

        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpAdditionalHeaders?["Authorization"])
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 90)

        let request = BillsManifestSnapshotClient.request(for: try XCTUnwrap(URL(string: Self.snapshotURL)))
        XCTAssertEqual(request.allHTTPHeaderFields, ["Accept": "application/json"])
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    @MainActor
    func testDeltaFailureKeepsTheSnapshot() async throws {
        let transport = RecordingTransport()
        transport.responses = [pointer()]
        transport.failure = { request in
            request.label == "BillsService bills-manifest delta" ? FakeServiceError() as Error : nil
        }
        StubURLProtocol.reset([stub(manifest([("A", "A"), ("B", "B")]))])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(fetched.source, "snapshot")
        XCTAssertEqual(fetched.items.map(\.guid), ["A", "B"])
        // Pointer and delta only: a failed delta does not fall back to the plain request.
        XCTAssertEqual(transport.requests.map(\.queryParameters), [["delivery": "snapshot"], ["updatedAfter": "2026-09-20T11:45:00.000Z"]])
    }

    // MARK: - Expiry, rejection and failure

    private let snapshotQuery = ["delivery": "snapshot"]
    private let deltaQuery = ["updatedAfter": "2026-09-20T11:45:00.000Z"]

    @MainActor
    func testPointerPastItsExpiryOnTheDeviceClockIsStillDownloaded() async throws {
        // S3 enforces expiresAt; a device clock running fast must not reject a pointer by itself.
        let transport = RecordingTransport()
        transport.responses = [pointer(expiresAt: "2026-01-01T00:00:00.000Z"), Data()]
        StubURLProtocol.reset([stub(manifest([("A", "A"), ("B", "B")]))])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(fetched.source, "snapshot")
        XCTAssertEqual(fetched.items.map(\.guid), ["A", "B"])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(transport.requests.map(\.queryParameters), [snapshotQuery, deltaQuery])
    }

    @MainActor
    func testRejectedSnapshotURLRequestsANewPointerOnce() async throws {
        let rejections: [(name: String, stub: StubURLProtocol.Stub)] = [
            ("presigned URL expired", StubURLProtocol.Stub(status: 403, headers: ["Content-Type": "application/xml"], body: Data("<Error/>".utf8))),
            ("malformed presigned URL", StubURLProtocol.Stub(status: 400, body: Data()))
        ]

        for rejection in rejections {
            let transport = RecordingTransport()
            transport.responses = [pointer(), pointer(), manifest([("C", "C new")])]
            StubURLProtocol.reset([rejection.stub, stub(manifest([("A", "A"), ("B", "B")]))])

            let result = try await fetch(transport)
            let fetched = try XCTUnwrap(result, rejection.name)

            XCTAssertEqual(fetched.source, "snapshot_retry", rejection.name)
            XCTAssertEqual(fetched.items.map(\.guid), ["A", "B", "C"], rejection.name)
            XCTAssertEqual(StubURLProtocol.requests.count, 2, rejection.name)
            // Two pointer requests, then the delta; never the plain full request.
            XCTAssertEqual(transport.requests.map(\.queryParameters), [snapshotQuery, snapshotQuery, deltaQuery], rejection.name)
            XCTAssertEqual(transport.requests.map(\.label), ["BillsService bills-manifest", "BillsService bills-manifest", "BillsService bills-manifest delta"], rejection.name)
        }
    }

    @MainActor
    func testNewPointerRequestAnsweredInlineUsesTheInlineManifest() async throws {
        let transport = RecordingTransport()
        transport.responses = [pointer(), manifest([("A", "A")])]
        StubURLProtocol.reset([StubURLProtocol.Stub(status: 403, body: Data())])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(fetched.source, "full")
        XCTAssertEqual(fetched.items.map(\.guid), ["A"])
        XCTAssertEqual(transport.requests.map(\.queryParameters), [snapshotQuery, snapshotQuery])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    @MainActor
    func testSecondRejectionFailsTheFetch() async {
        let transport = RecordingTransport()
        transport.responses = [pointer(), pointer()]
        StubURLProtocol.reset([StubURLProtocol.Stub(status: 403, body: Data()), StubURLProtocol.Stub(status: 403, body: Data())])

        do {
            _ = try await fetch(transport)
            XCTFail("Expected the rejection to fail the fetch")
        } catch {
            XCTAssertEqual(error as? ManifestSnapshotError, .httpStatus(403))
        }
        XCTAssertEqual(transport.requests.map(\.queryParameters), [snapshotQuery, snapshotQuery])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    @MainActor
    func testOtherSnapshotFailuresFailTheFetchWithoutAnotherRequest() async {
        let gzipMagic = Data([0x1F, 0x8B, 0x08, 0x00])
        let failures: [(name: String, stub: StubURLProtocol.Stub, expected: (Error) -> Bool)] = [
            ("S3 server error", StubURLProtocol.Stub(status: 500, body: Data()), { ($0 as? ManifestSnapshotError) == .httpStatus(500) }),
            ("network timeout", StubURLProtocol.Stub(error: URLError(.timedOut)), { ($0 as? URLError)?.code == .timedOut }),
            ("gzip body without Content-Encoding", stub(gzipMagic), { ($0 as? ManifestSnapshotError) == .gzipBodyNotDecoded }),
            ("body is not a manifest", stub(Data(#"{"bills":"nope"}"#.utf8)), { ($0 as? APIServiceError) == .invalidPayload("bills-manifest") })
        ]

        for failure in failures {
            let transport = RecordingTransport()
            transport.responses = [pointer(), manifest([("A", "A")])]
            StubURLProtocol.reset([failure.stub])

            do {
                _ = try await fetch(transport)
                XCTFail("Expected \(failure.name) to fail the fetch")
            } catch {
                XCTAssertTrue(failure.expected(error), "\(failure.name): \(error)")
            }
            XCTAssertEqual(StubURLProtocol.requests.count, 1, failure.name)
            XCTAssertEqual(transport.requests.map(\.queryParameters), [snapshotQuery], failure.name)
        }
    }

    // MARK: - Cancellation and the presigned URL

    @MainActor
    func testCancelledSnapshotDownloadThrowsCancellationError() async {
        let transport = RecordingTransport()
        transport.responses = [pointer(), pointer()]
        StubURLProtocol.reset([StubURLProtocol.Stub(error: URLError(.cancelled))])

        do {
            _ = try await fetch(transport)
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(transport.requests.map(\.queryParameters), [snapshotQuery], "a cancelled download is not retried")
    }

    @MainActor
    func testCancelledManifestRequestThrowsCancellationError() async {
        // The windowed request, then the pointer request of a full fetch.
        for updatedAfter in [Date(timeIntervalSince1970: 1_790_000_000), nil] as [Date?] {
            let transport = RecordingTransport()
            transport.failure = { _ in URLError(.cancelled) }

            do {
                _ = try await fetch(transport, updatedAfter: updatedAfter)
                XCTFail("Expected CancellationError")
            } catch {
                XCTAssertTrue(error is CancellationError, "updatedAfter=\(String(describing: updatedAfter)): \(error)")
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    @MainActor
    func testCancelledDeltaThrowsCancellationErrorInsteadOfUsingTheSnapshot() async {
        let transport = RecordingTransport()
        transport.responses = [pointer()]
        transport.failure = { request in
            request.label == "BillsService bills-manifest delta" ? URLError(.cancelled) as Error : nil
        }
        StubURLProtocol.reset([stub(manifest([("A", "A")]))])

        do {
            _ = try await fetch(transport)
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    @MainActor
    func testSnapshotNetworkErrorDoesNotCarryThePresignedURL() async throws {
        let url = try XCTUnwrap(URL(string: Self.snapshotURL))
        let withURL = URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let transport = RecordingTransport()
        transport.responses = [pointer()]
        StubURLProtocol.reset([StubURLProtocol.Stub(error: withURL)])

        do {
            _ = try await fetch(transport)
            XCTFail("Expected the network error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
            XCTAssertTrue(UserFacingLoadError.isConnectivityProblem(error), "still reads as a connectivity problem")
            let described = "\(error) \(String(reflecting: error)) \((error as NSError).userInfo)"
            XCTAssertFalse(described.contains("X-Amz-Signature"), described)
            XCTAssertFalse(described.contains("amazonaws.com"), described)
        }

        // The mapping itself, for errors from any source.
        let mapped = BillsService.snapshotFailure(withURL)
        XCTAssertEqual((mapped as? URLError)?.code, .networkConnectionLost)
        XCTAssertTrue((mapped as NSError).userInfo.isEmpty)
        XCTAssertTrue(BillsService.snapshotFailure(URLError(.cancelled)) is CancellationError)
        XCTAssertEqual(BillsService.snapshotFailure(ManifestSnapshotError.httpStatus(403)) as? ManifestSnapshotError, .httpStatus(403))
    }

    // MARK: - Isolation

    @MainActor
    func testSnapshotIsDownloadedAndDecodedOffTheMainThread() async throws {
        let transport = RecordingTransport()
        transport.responses = [pointer(), Data()]
        let body = manifest([("A", "A")])
        let onMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        // The transport runs on the executor of the code that downloads the snapshot.
        let snapshotClient = BillsManifestSnapshotClient(transport: { request in
            onMainThread.withLock { $0 = pthread_main_np() != 0 }
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
                throw URLError(.badURL)
            }
            return (body, response)
        })

        let result = try await APIClient.$current.withValue(transport.client) {
            try await BillsManifestSnapshotClient.$current.withValue(snapshotClient) {
                try await BillsService.fetchBillsManifest(updatedAfter: nil)
            }
        }

        XCTAssertEqual(result?.source, "snapshot")
        XCTAssertEqual(onMainThread.withLock { $0 }, false, "the manifest pipeline runs off the main actor")
    }

    // MARK: - Inline and windowed

    @MainActor
    func testInlineManifestIsUsedDirectly() async throws {
        let transport = RecordingTransport()
        transport.responses = [manifest([("A", "A"), ("B", "B")])]

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(fetched.source, "full")
        XCTAssertEqual(fetched.items.map(\.guid), ["A", "B"])
        XCTAssertEqual(transport.requests.map(\.queryParameters), [["delivery": "snapshot"]])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testWindowedRequestIsUnchanged() async throws {
        let transport = RecordingTransport()
        transport.responses = [manifest([("A", "A")])]
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T08:30:00Z"))

        let result = try await fetch(transport, updatedAfter: since)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(fetched.source, "windowed")
        XCTAssertEqual(fetched.items.map(\.guid), ["A"])
        XCTAssertEqual(
            transport.requests,
            [
                APIClient.Request(
                    method: .get,
                    path: "bills-manifest",
                    queryParameters: ["updatedAfter": "2026-09-17T08:30:00.000Z"],
                    body: nil,
                    label: "BillsService bills-manifest",
                    authMode: .autoFetch,
                    traceTimeline: true
                )
            ]
        )
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - Companion groups (APPF-23)

    private func memberLists(_ fetched: BillsService.FetchedManifest) -> [[String]]? {
        fetched.companionGroups?.map(\.memberGuids)
    }

    @MainActor
    func testTheDeltasCompanionGroupsReplaceTheSnapshots() async throws {
        let transport = RecordingTransport()
        transport.responses = [pointer(), manifest([("B", "B")], groups: [("BILLS-119hr2", "BILLS-119s2")])]
        StubURLProtocol.reset([stub(manifest([("A", "A")], groups: [("BILLS-119hr1", "BILLS-119s1")]))])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(memberLists(fetched), [["BILLS-119hr2", "BILLS-119s2"]])
    }

    @MainActor
    func testADeltaWithoutCompanionGroupsKeepsTheSnapshots() async throws {
        let transport = RecordingTransport()
        transport.responses = [pointer(), manifest([("B", "B")])]
        StubURLProtocol.reset([stub(manifest([("A", "A")], groups: [("BILLS-119hr1", "BILLS-119s1")]))])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(memberLists(fetched), [["BILLS-119hr1", "BILLS-119s1"]])
    }

    @MainActor
    func testADeltaWithAnEmptyListClearsTheGroups() async throws {
        let transport = RecordingTransport()
        transport.responses = [pointer(), manifest([("B", "B")], groups: [])]
        StubURLProtocol.reset([stub(manifest([("A", "A")], groups: [("BILLS-119hr1", "BILLS-119s1")]))])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(memberLists(fetched), [])
    }

    @MainActor
    func testAFailedDeltaKeepsTheSnapshotsGroups() async throws {
        let transport = RecordingTransport()
        transport.responses = [pointer()]
        transport.failure = { request in
            request.label == "BillsService bills-manifest delta" ? FakeServiceError() as Error : nil
        }
        StubURLProtocol.reset([stub(manifest([("A", "A")], groups: [("BILLS-119hr1", "BILLS-119s1")]))])

        let result = try await fetch(transport)
        let fetched = try XCTUnwrap(result)

        XCTAssertEqual(memberLists(fetched), [["BILLS-119hr1", "BILLS-119s1"]])
    }

    @MainActor
    func testInlineAndWindowedManifestsCarryTheirGroupsOrNone() async throws {
        let transport = RecordingTransport()
        transport.responses = [
            manifest([("A", "A")], groups: [("BILLS-119hr1", "BILLS-119s1")]),
            manifest([("A", "A")])
        ]
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T08:30:00Z"))

        let inlineResult = try await fetch(transport)
        let windowedResult = try await fetch(transport, updatedAfter: since)
        let inline = try XCTUnwrap(inlineResult)
        let windowed = try XCTUnwrap(windowedResult)

        XCTAssertEqual(memberLists(inline), [["BILLS-119hr1", "BILLS-119s1"]])
        XCTAssertNil(windowed.companionGroups, "a response without the field reports none, so the cached list stays")
    }

    func testCompanionGroupMergeRule() {
        let group = BillCompanionGroup(primaryGuid: "BILLS-119hr1", memberGuids: ["BILLS-119s1"], relationship: "identical")

        XCTAssertEqual(BillsService.mergingCompanionGroups(delta: [], snapshot: [group]), [])
        XCTAssertEqual(BillsService.mergingCompanionGroups(delta: nil, snapshot: [group]), [group])
        XCTAssertNil(BillsService.mergingCompanionGroups(delta: nil, snapshot: nil))
    }

    // MARK: - Merge

    @MainActor
    func testDeltaReplacesSnapshotItemsByGuidAndAppendsNewOnes() {
        func item(_ guid: String, _ title: String) -> BillsManifestItem {
            BillsManifestItem(guid: guid, congress: "119", billType: "hr", billID: nil, subCategories: [], lifeAreas: [], sponsors: [], cosponsors: [], title: title)
        }
        let snapshot = [item("A", "A1"), item("B", "B1"), item("C", "C1")]
        let delta = [item("E", "E1"), item("C", "C2"), item("A", "A2"), item("E", "E2")]

        let merged = BillsService.mergingManifestDelta(delta, into: snapshot)

        XCTAssertEqual(merged.map(\.guid), ["A", "B", "C", "E"])
        XCTAssertEqual(merged.map(\.title), ["A2", "B1", "C2", "E2"])
        XCTAssertEqual(BillsService.mergingManifestDelta([], into: snapshot).map(\.title), ["A1", "B1", "C1"])
    }
}
