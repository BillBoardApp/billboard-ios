import Amplify
import Foundation
import XCTest
@testable import Billboard

// Fakes for the service protocols the stores take (`APIServiceProtocols.swift`), a
// recording transport for `APIClient`, a fake App Attest manager and a URLProtocol stub for
// dedicated URLSessions. None of them touch the network or Amplify.

struct FakeServiceError: Error, Equatable {}

// MARK: - Server errors

/// A failed request whose body is `{"error": "<code>"}`, as `APIErrorResponse.errorCode(from:)` reads it.
/// It has no HTTP status (Amplify's `AWSHTTPURLResponse`, which carries both, cannot be built in tests);
/// code-based mapping does not need one.
func backendError(_ code: String) -> Error {
    NSError(
        domain: "BillboardTests.backend",
        code: 0,
        userInfo: ["body": Data(#"{"error":"\#(code)","message":"Server text that is never shown."}"#.utf8)]
    )
}

/// Amplify's error for an HTTP status with no readable body.
func httpStatusError(_ status: Int, path: String = "feedback") -> APIError {
    let url = URL(string: "https://api.example.test/\(path)")!
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    return APIError.httpStatusError(status, response)
}

// MARK: - Bills

@MainActor
final class FakeBillsService: BillsServicing {
    /// Results for successive `getBillsManifest` calls; the last one repeats.
    var manifestResults: [Result<[BillsManifestItem], Error>] = [.success([])]
    private(set) var manifestRequests: [Date?] = []

    var processedBillResult: Result<Bill, Error> = .failure(FakeServiceError())
    private(set) var processedBillRequests: [(guid: String, congress: String?, billType: String?, billID: String?)] = []

    // Cache reads are nonisolated in the protocol; tests set these before use.
    nonisolated(unsafe) var cachedManifest: [BillsManifestItem]?
    nonisolated(unsafe) var cacheIsFresh = false
    nonisolated(unsafe) var cacheIsFull = false
    /// Called at the start of each `cachedBillsManifest()` read, off the main actor when the store
    /// reads its cache; a test can block in it to hold a read.
    nonisolated(unsafe) var onCachedManifestRead: (@Sendable () -> Void)?
    /// The companion groups `cachedCompanionGroups()` returns (APPF-23).
    nonisolated(unsafe) var cachedGroups: [BillCompanionGroup]?

    func getBillsManifest(updatedAfter: Date?) async throws -> [BillsManifestItem] {
        manifestRequests.append(updatedAfter)
        let index = min(manifestRequests.count - 1, manifestResults.count - 1)
        return try manifestResults[index].get()
    }

    func getProcessedBill(guid: String, congress: String?, billType: String?, billID: String?) async throws -> Bill {
        processedBillRequests.append((guid, congress, billType, billID))
        return try processedBillResult.get()
    }

    nonisolated func cachedBillsManifest() -> [BillsManifestItem]? {
        onCachedManifestRead?()
        return cachedManifest
    }
    nonisolated func cachedBillsManifestIsFresh(maxAge: TimeInterval) -> Bool { cacheIsFresh }
    nonisolated func cachedBillsManifestIsFull() -> Bool { cacheIsFull }
    nonisolated func cachedBillsManifestIsFull(maxAge: TimeInterval) -> Bool { cacheIsFresh && cacheIsFull }
    nonisolated func cachedCompanionGroups() -> [BillCompanionGroup]? { cachedGroups }
}

// MARK: - Votes

@MainActor
final class FakeBillVotesService: BillVotesServicing {
    struct SetFeedbackCall: Equatable {
        let billId: String
        let feedback: VoteType
        let reasons: [String]
    }

    private(set) var setFeedbackCalls: [SetFeedbackCall] = []
    /// Thrown by every `setFeedback` call when set (after `setFeedbackOutcomes` runs out).
    var setFeedbackError: Error?
    /// Outcomes for successive `setFeedback` calls, taken first: nil succeeds, an error is thrown.
    var setFeedbackOutcomes: [Error?] = []
    /// Called when a `setFeedback` call starts, before it is released by `holdSetFeedback`.
    var onSetFeedback: ((SetFeedbackCall) -> Void)?
    /// When set, `setFeedback` suspends until the gate opens.
    var holdSetFeedback: Gate?

    var batchResult: Result<[String: BillVotesService.RemoteVoteState], Error> = .success([:])
    private(set) var batchRequests: [[String]] = []
    var singleResult: Result<BillVotesService.RemoteVoteState, Error> = .success(.notVoted)
    private(set) var singleRequests: [String] = []

    func fetchFeedback(billIds: [String]) async throws -> [String: BillVotesService.RemoteVoteState] {
        batchRequests.append(billIds)
        return try batchResult.get()
    }

    func fetchFeedback(billId: String) async throws -> BillVotesService.RemoteVoteState {
        singleRequests.append(billId)
        return try singleResult.get()
    }

    func setFeedback(billId: String, feedback: VoteType, reasons: [String]) async throws {
        let call = SetFeedbackCall(billId: billId, feedback: feedback, reasons: reasons)
        setFeedbackCalls.append(call)
        onSetFeedback?(call)
        let outcome: Error?? = setFeedbackOutcomes.isEmpty ? nil : .some(setFeedbackOutcomes.removeFirst())
        if let gate = holdSetFeedback {
            await gate.wait()
        }
        if let outcome {
            if let error = outcome { throw error }
            return
        }
        if let setFeedbackError {
            throw setFeedbackError
        }
    }
}

// MARK: - App Attest

/// Stands in for `AppAttestManager` (swap it in with `AppAttestManager.$current.withValue(fake) { ... }`).
/// Records every protected request, preparation and sign-up, and hands `send` a fixed header.
final class FakeAppAttestManager: AppAttestManaging, @unchecked Sendable {
    struct ProtectedCall: Equatable {
        let method: String
        let path: String
        let body: Data?
    }

    private let lock = NSLock()
    private var recordedCalls: [ProtectedCall] = []
    private var recordedSignUpEmails: [String] = []
    private var preparations = 0
    private var header: [String: String]
    private var metadata: [String: String]

    init(
        headers: [String: String] = [AppAttestWire.attestHeader: "v1.b"],
        signUpMetadata: [String: String] = [AppAttestWire.MetadataKey.appVersion: "1.2"]
    ) {
        header = headers
        metadata = signUpMetadata
    }

    var protectedCalls: [ProtectedCall] { lock.withLock { recordedCalls } }
    var signUpEmails: [String] { lock.withLock { recordedSignUpEmails } }
    var prepareCount: Int { lock.withLock { preparations } }

    func prepareIfNeeded() async {
        lock.withLock { preparations += 1 }
    }

    func performProtected<T: Sendable>(
        method: String,
        path: String,
        body: Data?,
        send: @Sendable (_ headers: [String: String]) async throws -> T
    ) async throws -> T {
        let headers = lock.withLock {
            recordedCalls.append(ProtectedCall(method: method, path: path, body: body))
            return header
        }
        return try await send(headers)
    }

    func signUpMetadata(email: String) async -> [String: String] {
        lock.withLock {
            recordedSignUpEmails.append(email)
            return metadata
        }
    }
}

// MARK: - Congress

@MainActor
final class FakeCongressService: CongressServicing {
    var manifestResult: Result<[CongressMemberManifestItem], Error> = .success([])
    private(set) var manifestRequestCount = 0
    /// Any cached manifest, and the cached manifest while it is still fresh.
    var cachedManifest: [CongressMemberManifestItem]?
    var cacheIsFresh = false

    func getCongressMembersManifest() async throws -> [CongressMemberManifestItem] {
        manifestRequestCount += 1
        return try manifestResult.get()
    }

    func cachedCongressMembersManifest() -> [CongressMemberManifestItem]? { cachedManifest }

    func cachedCongressMembersManifest(maxAge: TimeInterval) -> [CongressMemberManifestItem]? {
        cacheIsFresh ? cachedManifest : nil
    }
}

// MARK: - Civic

@MainActor
final class FakeCivicService: CivicServicing {
    var scoreResult: Result<CivicScore, Error> = .success(.empty)
    var profileResult: Result<CivicProfileResponse, Error> = .success(.empty)

    func fetchCivicScore() async throws -> CivicScore { try scoreResult.get() }
    func fetchCivicProfile() async throws -> CivicProfileResponse { try profileResult.get() }
}

// MARK: - Preferences

@MainActor
final class FakePreferencesService: PreferencesServicing {
    var preferences: [PreferencesItem] = []
    /// Thrown by `getPreferences` when set.
    var getPreferencesError: Error?
    private(set) var putCalls: [[PreferencesItem]] = []
    private(set) var deleteCalls: [[PreferencesItem]] = []

    func getPreferences() async throws -> [PreferencesItem] {
        if let getPreferencesError { throw getPreferencesError }
        return preferences
    }
    func putPreferences(_ items: [PreferencesItem]) async throws { putCalls.append(items) }
    func deletePreferences(_ items: [PreferencesItem]) async throws { deleteCalls.append(items) }
}

// MARK: - Companion groups (APPF-23)

extension XCTestCase {
    /// A bills store holding `bills`, connected to a vote store on `votes`, whose service reports
    /// `groups` as the cached companion groups; the cache restore has run, so the store has built its
    /// group index. The bills store writes preferences to `preferences`. The scope's bills cache is
    /// removed in teardown.
    @MainActor
    func makeCompanionStore(
        bills: [Bill],
        groups: [BillCompanionGroup],
        votes: FakeBillVotesService? = nil,
        preferences: FakePreferencesService? = nil
    ) async -> (store: BillsStore, voteStore: BillVoteStore, scope: String) {
        let votes = votes ?? FakeBillVotesService()
        let scope = "companion-store-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedGroups = groups
        service.cachedManifest = []
        let store = BillsStore(
            bills: bills,
            cacheScope: scope,
            service: service,
            preferencesService: preferences ?? FakePreferencesService()
        )
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        store.connect(voteStore: voteStore)
        // The bills store holds the vote store weakly; keep it for the whole test.
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        await store.restoreCachedStateIfNeeded()
        return (store, voteStore, scope)
    }

    /// Waits briefly for the store's detached bills-cache write (if any) and removes its timestamp, so
    /// no write lands after the teardown clears the scope.
    @MainActor
    func settleBillsCache(scope: String) async {
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        let timestampKey = ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope)
        for _ in 0..<100 where UserDefaults.standard.object(forKey: timestampKey) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }
}

/// A bill for companion-group tests: id from the guid, one hour old unless `storedAt` is given.
func companionTestBill(
    _ guid: String,
    status: BillStatus = .new,
    storedAt: String? = "2026-09-20T11:00:00.000Z",
    userVote: UserVote? = nil
) -> Bill {
    Bill(
        id: UUID.deterministic(from: guid),
        title: "A bill",
        category: "Other",
        soWhat: "",
        storedAt: storedAt,
        billStatus: status,
        guid: guid,
        userVoted: userVote?.countsAsVote == true,
        userVote: userVote
    )
}

/// A read state that is never persisted.
@MainActor
final class InMemoryReadStateStore: ReadStateStore {
    private var snapshots: [ReadStateScope: ReadStateSnapshot] = [:]

    func load(scope: ReadStateScope) -> ReadStateSnapshot { snapshots[scope] ?? .empty }
    func save(_ snapshot: ReadStateSnapshot, scope: ReadStateScope) { snapshots[scope] = snapshot }
}

// MARK: - Async helpers

/// Suspends callers of `wait()` until `open()`.
@MainActor
final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

// MARK: - APIClient transport

/// Records every request an `APIClient` sends and answers with canned payloads.
@MainActor
final class RecordingTransport {
    private(set) var requests: [APIClient.Request] = []
    /// Response bodies for successive requests; an empty body once they run out.
    var responses: [Data] = []
    /// The error a request fails with instead of taking the next response, if any.
    var failure: ((APIClient.Request) -> Error?)?

    var client: APIClient {
        APIClient(transport: { [self] request in
            try await self.respond(to: request)
        })
    }

    private func respond(to request: APIClient.Request) throws -> Data {
        requests.append(request)
        if let error = failure?(request) { throw error }
        return responses.isEmpty ? Data() : responses.removeFirst()
    }
}

// MARK: - URLSession stub

/// Answers the requests of a URLSession whose configuration lists it in `protocolClasses`, and
/// records each request as the session sent it. URLSession creates the protocol instances, so the
/// stubs and the record are static; `reset` them in each test.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = Data()
        /// When set, the request fails with this error instead.
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pendingStubs: [Stub] = []
    nonisolated(unsafe) private static var recordedRequests: [URLRequest] = []

    /// Stubs for successive requests; a request after they run out fails with `.resourceUnavailable`.
    static func reset(_ stubs: [Stub] = []) {
        lock.withLock {
            pendingStubs = stubs
            recordedRequests = []
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    /// A session with `configuration` (default: the manifest snapshot client's) answered by this stub.
    static func session(
        configuration: URLSessionConfiguration = BillsManifestSnapshotClient.makeSessionConfiguration()
    ) -> URLSession {
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub? = Self.lock.withLock {
            Self.recordedRequests.append(request)
            return Self.pendingStubs.isEmpty ? nil : Self.pendingStubs.removeFirst()
        }
        guard let stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Parses a JSON request or response body for order-independent comparison.
func jsonObject(_ data: Data?, file: StaticString = #filePath, line: UInt = #line) throws -> NSDictionary {
    let data = try XCTUnwrap(data, "missing JSON body", file: file, line: line)
    return try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? NSDictionary,
        "body is not a JSON object",
        file: file,
        line: line
    )
}
