import Amplify
import XCTest
@testable import Billboard

/// APPF-26: a deep link, push or share link to a bill outside the loaded history window (neither voted
/// on nor watched) opens the bill: the detail screen fetches it from `GET /processed-bill` with a
/// loading state, and shows "Bill not found" only when the API answers 404. Companion groups still open
/// on the primary when it is loaded, and manifest loads treat the fetched bill as before.
final class LinkedBillTests: XCTestCase {
    /// A bill from an earlier Congress: never in the history window of these stores.
    private static let oldGuid = "BILLS-117hr42"

    @MainActor
    private func makeStore(
        _ service: FakeBillsService,
        bills: [Bill]? = nil,
        groups: [BillCompanionGroup] = []
    ) async -> (store: BillsStore, scope: String) {
        let scope = "linked-bill-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        service.cachedGroups = groups
        service.cachedManifest = []
        let store = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        await store.restoreCachedStateIfNeeded()
        return (store, scope)
    }

    @MainActor
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "LinkedBillTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// A processed bill as `BillsService.getProcessedBill` returns it.
    private func processedBill(_ guid: String, storedAt: String = "2022-03-01T00:00:00.000Z") -> Bill {
        let locator = BillsService.deriveLocator(from: guid)
        return Bill(
            id: UUID.deterministic(from: guid),
            title: "An older bill",
            category: "Other",
            soWhat: "Why it matters",
            storedAt: storedAt,
            link: "https://www.congress.gov/bill/117th-congress/house-bill/42",
            billStatus: .passed,
            guid: guid,
            congress: locator?.congress,
            billType: locator?.billType,
            billID: locator?.billID,
            userVoted: false,
            isProcessedDetailHydrated: true
        )
    }

    private func manifestItem(guid: String, updatedDaysAgo: Double) -> BillsManifestItem {
        BillsManifestItem(
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: String(guid.filter(\.isNumber).dropFirst(3)),
            updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-updatedDaysAgo * 24 * 60 * 60)),
            subCategories: [],
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            title: "Recent bill",
            billStatus: "new"
        )
    }

    private func httpError(_ status: Int) throws -> APIError {
        let url = try XCTUnwrap(URL(string: "https://api.example.test/processed-bill"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return APIError.httpStatusError(status, response)
    }

    /// Routes `guid` with `route` on a store that holds only an in-window bill, then checks that the
    /// screen shows loading instead of "Bill not found" and the bill loads from the processed-bill API.
    @MainActor
    private func assertOpensOnDemand(
        guid: String,
        route: (BillsStore) -> BillLinkTarget?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let service = FakeBillsService()
        service.processedBillResult = .success(processedBill(guid))
        let (store, scope) = await makeStore(service, bills: [companionTestBill("BILLS-119hr1")])

        let target = try XCTUnwrap(route(store), file: file, line: line)
        XCTAssertEqual(target, BillLinkTarget(billID: UUID.deterministic(from: guid), guid: guid), file: file, line: line)
        XCTAssertNil(store.bill(for: target.billID), "the bill is not loaded", file: file, line: line)
        XCTAssertEqual(
            BillDetail.missingBillContent(linkGUID: target.guid, phase: .idle),
            .loading,
            "the screen shows loading, not \"Bill not found\"",
            file: file,
            line: line
        )

        let result = await store.loadLinkedBill(target)

        XCTAssertEqual(result, .loaded(billID: target.billID), file: file, line: line)
        XCTAssertEqual(BillDetail.linkedBillPhase(after: result), .idle, file: file, line: line)
        XCTAssertEqual(service.processedBillRequests.map { $0.guid }, [guid], "one processed-bill request", file: file, line: line)
        let opened = try XCTUnwrap(store.bill(for: target.billID), file: file, line: line)
        XCTAssertEqual(opened.title, "An older bill", file: file, line: line)
        XCTAssertTrue(BillDetail.isDetailReady(opened, in: store), "the screen shows the fetched bill", file: file, line: line)
        await settleBillsCache(scope: scope)
    }

    // MARK: - Entry points

    @MainActor
    func testDeepLinkToABillOutsideTheWindowFetchesIt() async throws {
        let guid = Self.oldGuid
        let url = try XCTUnwrap(URL(string: "billboard://bill?guid=\(guid)"))
        XCTAssertEqual(AppDeepLink(url: url, allowedWebHosts: []), .bill(guid: guid))
        // A link that arrives before navigation is allowed waits in PendingAppDeepLink.
        let defaults = try isolatedDefaults()
        PendingAppDeepLink.saveBillGuid(guid, defaults: defaults)
        let pending = try XCTUnwrap(PendingAppDeepLink.consumeBillGuid(defaults: defaults))

        try await assertOpensOnDemand(guid: pending) { $0.deepLinkTarget(forGUID: pending) }
    }

    @MainActor
    func testShareLinkToABillOutsideTheWindowFetchesIt() async throws {
        let guid = Self.oldGuid
        // The link the app's share sheet sends, on the configured share host.
        let url = try XCTUnwrap(BillShareURLBuilder.shareURL(forBillGuid: guid), "SHARE_SITE_BASE_URL is not configured")
        XCTAssertEqual(AppDeepLink(url: url), .bill(guid: guid))
        let pathLink = try XCTUnwrap(URL(string: "https://share.example.test/b/\(guid)"))
        XCTAssertEqual(AppDeepLink(url: pathLink, allowedWebHosts: ["share.example.test"]), .bill(guid: guid))

        try await assertOpensOnDemand(guid: guid) { $0.deepLinkTarget(forGUID: guid) }
    }

    @MainActor
    func testBillPushToABillOutsideTheWindowFetchesIt() async throws {
        let guid = Self.oldGuid
        let payload = PushNotificationPayload(userInfo: ["domain": "bill", "billIds": [guid], "notificationType": "passed"])
        // A tapped push waits in PendingPushDeepLink until navigation is allowed.
        let defaults = try isolatedDefaults()
        PendingPushDeepLink.save(.digest(billIds: payload.allBillIds, notificationType: payload.notificationType.rawValue), defaults: defaults)
        guard case .digest(let billIds, _)? = PendingPushDeepLink.consume(defaults: defaults) else {
            return XCTFail("expected a bill push")
        }

        try await assertOpensOnDemand(guid: guid) { $0.pushDeepLinkTarget(forGUIDs: billIds) }
    }

    @MainActor
    func testAlertPushToABillOutsideTheWindowFetchesIt() async throws {
        let guid = Self.oldGuid
        let payload = PushNotificationPayload(userInfo: [
            "domain": "bill",
            "billIds": [guid],
            "notificationType": "alert",
            "alertId": "alert-1"
        ])
        XCTAssertTrue(payload.isBillAlertRelevant)
        let defaults = try isolatedDefaults()
        PendingPushDeepLink.save(.alert(.init(alertId: payload.normalizedAlertId, billId: payload.normalizedBillGuid)), defaults: defaults)
        guard case .alert(let alert)? = PendingPushDeepLink.consume(defaults: defaults) else {
            return XCTFail("expected an alert push")
        }
        let billId = try XCTUnwrap(alert.billId)

        try await assertOpensOnDemand(guid: guid) { $0.deepLinkTarget(forGUID: billId) }
    }

    // MARK: - Not found and failures

    @MainActor
    func testOnlyA404IsBillNotFound() async throws {
        let guid = Self.oldGuid
        let notFound = try httpError(404)
        let serverError = try httpError(500)
        let offline = URLError(.notConnectedToInternet)
        let badPayload = APIServiceError.invalidPayload("processed-bill")
        let failures: [(error: Error, expected: LinkedBillLoad)] = [
            (notFound, .notFound),
            (serverError, .failed(message: UserFacingLoadError.message(for: serverError, loading: "this bill"))),
            (offline, .failed(message: UserFacingLoadError.message(for: offline, loading: "this bill"))),
            (badPayload, .failed(message: UserFacingLoadError.message(for: badPayload, loading: "this bill"))),
            (CancellationError(), .cancelled),
            (APIError.networkError("cancelled", nil, URLError(.cancelled)), .cancelled)
        ]
        XCTAssertNotEqual(
            UserFacingLoadError.message(for: offline, loading: "this bill"),
            UserFacingLoadError.message(for: serverError, loading: "this bill"),
            "offline gets the connectivity copy"
        )

        for (error, expected) in failures {
            let service = FakeBillsService()
            service.processedBillResult = .failure(error)
            let (store, _) = await makeStore(service)
            let target = store.deepLinkTarget(forGUID: guid)

            let result = await store.loadLinkedBill(target)

            XCTAssertEqual(result, expected, "\(error)")
            XCTAssertNil(store.bill(for: target.billID), "\(error)")
            switch expected {
            case .notFound:
                XCTAssertEqual(BillDetail.linkedBillPhase(after: result), .notFound)
                XCTAssertEqual(BillDetail.missingBillContent(linkGUID: guid, phase: .notFound), .notFound)
            case .failed(let message):
                XCTAssertEqual(BillDetail.linkedBillPhase(after: result), .failed(message))
                XCTAssertEqual(
                    BillDetail.missingBillContent(linkGUID: guid, phase: .failed(message)),
                    .failed(message),
                    "a failure offers Retry instead of \"Bill not found\""
                )
            case .cancelled:
                XCTAssertNil(BillDetail.linkedBillPhase(after: result), "a cancelled load leaves the screen as it is")
            case .loaded:
                XCTFail("unexpected")
            }
        }
    }

    /// `getProcessedBill` reports 404 only after every locator it tries answered 404, and stops at a
    /// cancelled request.
    @MainActor
    func testProcessedBillReports404OnlyAfterEveryLocatorAndStopsWhenCancelled() async throws {
        let notFound = RecordingTransport()
        let notFoundError = try httpError(404)
        notFound.failure = { _ in notFoundError }
        do {
            _ = try await APIClient.$current.withValue(notFound.client) {
                try await BillsService.getProcessedBill(guid: Self.oldGuid)
            }
            XCTFail("Expected a 404")
        } catch {
            XCTAssertEqual(APIErrorDebug.httpStatusCode(from: error), 404)
        }
        XCTAssertEqual(notFound.requests.map(\.queryParameters), [
            ["guid": Self.oldGuid, "congress": "117", "type": "hr"],
            ["guid": Self.oldGuid],
            ["congress": "117", "type": "hr", "bill_id": "42"]
        ])

        let cancelled = RecordingTransport()
        cancelled.failure = { _ in APIError.networkError("cancelled", nil, URLError(.cancelled)) }
        do {
            _ = try await APIClient.$current.withValue(cancelled.client) {
                try await BillsService.getProcessedBill(guid: Self.oldGuid)
            }
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(cancelled.requests.count, 1)
    }

    @MainActor
    func testAScreenWithoutALinkGuidStillShowsBillNotFound() {
        XCTAssertEqual(BillDetail.missingBillContent(linkGUID: nil, phase: .idle), .notFound, "in-app screens are unchanged")
        XCTAssertEqual(BillDetail.missingBillContent(linkGUID: "  ", phase: .loading), .notFound)
        XCTAssertEqual(BillDetail.missingBillContent(linkGUID: Self.oldGuid, phase: .loading), .loading)
    }

    // MARK: - Loaded bills, companion groups and manifest loads

    @MainActor
    func testALoadedBillOpensWithoutARequest() async {
        let service = FakeBillsService()
        let loaded = companionTestBill("BILLS-119hr5")
        let (store, _) = await makeStore(service, bills: [loaded])

        let result = await store.loadLinkedBill(store.deepLinkTarget(forGUID: "BILLS-119hr5"))

        XCTAssertEqual(result, .loaded(billID: loaded.id))
        XCTAssertTrue(service.processedBillRequests.isEmpty)
    }

    @MainActor
    func testACompanionLinkStillOpensTheLoadedPrimaryAndFetchesOnlyAMissingBill() async {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")

        // The primary is loaded: a link or push to the other member opens it; nothing is fetched.
        let service = FakeBillsService()
        let (withPrimary, _) = await makeStore(service, bills: [companionTestBill(house)], groups: [group])
        let target = withPrimary.deepLinkTarget(forGUID: senate)
        XCTAssertEqual(target, BillLinkTarget(billID: UUID.deterministic(from: house), guid: house))
        XCTAssertEqual(withPrimary.pushDeepLinkTarget(forGUIDs: [house, senate]), target)
        XCTAssertEqual(withPrimary.deepLinkBillID(forGUID: senate), target.billID, "the existing routing is unchanged")
        let opened = await withPrimary.loadLinkedBill(target)
        XCTAssertEqual(opened, .loaded(billID: UUID.deterministic(from: house)))
        XCTAssertTrue(service.processedBillRequests.isEmpty)

        // Neither member is loaded: the linked member is fetched and the screen shows its group.
        let fetching = FakeBillsService()
        fetching.processedBillResult = .success(processedBill(senate))
        let (empty, scope) = await makeStore(fetching, groups: [group])
        let senateTarget = empty.deepLinkTarget(forGUID: senate)
        XCTAssertEqual(senateTarget, BillLinkTarget(billID: UUID.deterministic(from: senate), guid: senate))
        let fetched = await empty.loadLinkedBill(senateTarget)
        XCTAssertEqual(fetched, .loaded(billID: senateTarget.billID))
        XCTAssertEqual(fetching.processedBillRequests.map { $0.guid }, [senate])
        XCTAssertEqual(empty.companionGroup(forBillID: senateTarget.billID), group)
        await settleBillsCache(scope: scope)
    }

    /// A manifest load treats a fetched linked bill like any other bill outside the window that is
    /// neither voted nor watched (unchanged): it leaves the store and is never a Home card. The screen
    /// keeps the fetched copy, and voting re-adds it (`billIDForVoting`), so the vote is kept.
    @MainActor
    func testAManifestLoadTreatsALinkedBillAsBeforeAndTheScreensCopyStillVotes() async throws {
        let service = FakeBillsService()
        service.processedBillResult = .success(processedBill(Self.oldGuid))
        service.manifestResults = [.success([manifestItem(guid: "BILLS-119hr101", updatedDaysAgo: 1)])]
        let (store, scope) = await makeStore(service)
        let target = store.deepLinkTarget(forGUID: Self.oldGuid)
        let result = await store.loadLinkedBill(target)
        XCTAssertEqual(result, .loaded(billID: target.billID))
        let screenCopy = try XCTUnwrap(store.bill(for: target.billID), "the screen keeps this copy")

        await store.load(forceRefresh: true, historyWindow: .oneWeek)

        XCTAssertNil(store.bill(for: target.billID), "unchanged: the load keeps bills in the window, voted or watched")
        XCTAssertEqual(store.activeManifestBills.map(\.guid), ["BILLS-119hr101"], "the linked bill is not a Home card")

        // What `BillDetailContent.billIDForVoting` does before a vote on a copy the store does not hold.
        store.upsertProcessedBill(screenCopy)
        let vote = store.vote(billID: screenCopy.id, vote: .yea, watch: false)
        XCTAssertNotNil(vote, "the vote is recorded")
        _ = await vote?.value
        XCTAssertEqual(store.bill(for: target.billID)?.userVote, .yea)
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testALinkAnsweredForAnotherGuidOpensTheBillItLoaded() async {
        // A legacy text-version guid that the API answers with the plain bill (the locator fallback):
        // `BillsService` keeps the requested guid on the bill, whose id comes from the answered guid.
        let requested = "BILLS-117hr42ih"
        var answered = processedBill(Self.oldGuid)
        answered.guid = requested
        let service = FakeBillsService()
        service.processedBillResult = .success(answered)
        let (store, scope) = await makeStore(service)
        let target = store.deepLinkTarget(forGUID: requested)

        let result = await store.loadLinkedBill(target)

        XCTAssertEqual(result, .loaded(billID: UUID.deterministic(from: Self.oldGuid)))
        XCTAssertNotNil(store.bill(for: UUID.deterministic(from: Self.oldGuid)))
        XCTAssertEqual(
            store.bill(for: UUID.deterministic(from: Self.oldGuid))?.guid,
            Self.oldGuid,
            "the bill keeps the guid the API answered with (its vote identity), not the link's legacy guid"
        )
        await settleBillsCache(scope: scope)
    }

    /// A link with a legacy text-version guid to a bill the store holds under its plain guid (manifest
    /// loads keep the plain one) opens that bill without a request, and its guid, the vote identity,
    /// stays the plain one.
    @MainActor
    func testALegacyGuidLinkOpensTheLoadedBillAndKeepsItsGuid() async throws {
        let plain = "BILLS-119hr6512"
        let legacy = "BILLS-119hr6512ih"
        var answered = processedBill(plain)
        answered.guid = legacy
        let service = FakeBillsService()
        service.processedBillResult = .success(answered)
        let (store, scope) = await makeStore(service, bills: [companionTestBill(plain, userVote: .yea)])
        let target = store.deepLinkTarget(forGUID: legacy)
        XCTAssertEqual(target, BillLinkTarget(billID: UUID.deterministic(from: legacy), guid: legacy))
        XCTAssertNil(store.bill(for: target.billID), "precondition: the link's own id is not loaded")

        let result = await store.loadLinkedBill(target)

        XCTAssertEqual(result, .loaded(billID: UUID.deterministic(from: plain)), "the screen opens the loaded bill")
        XCTAssertTrue(service.processedBillRequests.isEmpty, "a loaded bill opens without a request")
        let opened = try XCTUnwrap(store.bill(for: UUID.deterministic(from: plain)))
        XCTAssertEqual(opened.guid, plain, "votes, watch and preferences still go to the plain guid")
        XCTAssertEqual(opened.userVote, .yea)
        await settleBillsCache(scope: scope)
    }

    /// A link to a bill the store holds only as a legacy text-version bill (voted on a suffixed guid
    /// in an earlier version, kept because it is voted) fetches the plain bill and opens it, as before
    /// `loadedBill(sameBillAs:)`: the legacy bill's guid is its vote identity, so opening it would send
    /// the screen's vote, watch and preferences to the suffixed guid. Also for a link with another
    /// legacy guid of the bill.
    @MainActor
    func testALinkDoesNotOpenALoadedLegacyBillUnderAnotherGuid() async throws {
        let plain = "BILLS-119hr6512"
        let legacy = "BILLS-119hr6512ih"
        for linkGuid in [plain, "BILLS-119hr6512eh"] {
            let service = FakeBillsService()
            service.processedBillResult = .success(processedBill(plain))
            let legacyBill = companionTestBill(legacy, userVote: .yea)
            let (store, scope) = await makeStore(service, bills: [legacyBill])
            let target = store.deepLinkTarget(forGUID: linkGuid)
            XCTAssertEqual(target, BillLinkTarget(billID: UUID.deterministic(from: linkGuid), guid: linkGuid))

            let result = await store.loadLinkedBill(target)

            XCTAssertEqual(result, .loaded(billID: UUID.deterministic(from: plain)), "the screen opens the plain bill (\(linkGuid))")
            XCTAssertEqual(service.processedBillRequests.map(\.guid), [linkGuid], "the linked bill is fetched, as before (\(linkGuid))")
            XCTAssertEqual(store.bill(for: UUID.deterministic(from: plain))?.guid, plain, "its vote identity is the plain guid (\(linkGuid))")
            XCTAssertEqual(store.bill(for: legacyBill.id)?.userVote, .yea, "the legacy bill and its vote stay (\(linkGuid))")
            await settleBillsCache(scope: scope)
        }
    }

    /// A store at `maxBillsInMemory` keeps a fetched linked bill that ranks last (an old bill, not
    /// voted on or watched) and drops the lowest-ranked other bill instead, so `.loaded` means the
    /// screen finds the bill. Voted bills are kept, and the cap holds.
    @MainActor
    func testALinkedBillLoadedIntoAFullStoreStaysInTheStore() async throws {
        let service = FakeBillsService()
        service.processedBillResult = .success(processedBill(Self.oldGuid))
        let voted = companionTestBill("BILLS-119hr1", userVote: .yea)
        let window = (2...BillsStore.maxBillsInMemory).map { companionTestBill("BILLS-119hr\($0)") }
        let (store, scope) = await makeStore(service, bills: [voted] + window)
        XCTAssertEqual(store.bills.count, BillsStore.maxBillsInMemory, "precondition: the store is full")
        let target = store.deepLinkTarget(forGUID: Self.oldGuid)

        let result = await store.loadLinkedBill(target)

        XCTAssertEqual(result, .loaded(billID: target.billID))
        let opened = try XCTUnwrap(store.bill(for: target.billID), "`.loaded`, so the screen finds the bill")
        XCTAssertTrue(BillDetail.isDetailReady(opened, in: store))
        XCTAssertEqual(store.bills.count, BillsStore.maxBillsInMemory, "the cap holds")
        XCTAssertNotNil(store.bill(for: voted.id), "voted bills are kept")
        let lowestRanked = try XCTUnwrap(rankBillsForBoard(window).last)
        XCTAssertNil(store.bill(for: lowestRanked.id), "the lowest-ranked other bill went instead")
        await settleBillsCache(scope: scope)
    }

    /// `capBills(keeping:)` changes the result only when the feed order would drop the kept bill.
    @MainActor
    func testCappingKeepsTheKeptBillAndIsOtherwiseUnchanged() {
        let voted = companionTestBill("BILLS-119hr1", userVote: .yea)
        let recent = (2...6).map { companionTestBill("BILLS-119hr\($0)") }
        let old = companionTestBill(Self.oldGuid, storedAt: "2022-03-01T00:00:00.000Z")
        let bills = [old, voted] + recent
        let capped = BillsStore.capBills(bills, limit: 4)
        XCTAssertFalse(capped.contains { $0.id == old.id }, "precondition: the feed order drops the old bill")

        for keptID in [voted.id] + capped.map(\.id) {
            XCTAssertEqual(BillsStore.capBills(bills, limit: 4, keeping: [keptID]).map(\.id), capped.map(\.id), "a bill kept anyway")
        }
        let keepingOld = BillsStore.capBills(bills, limit: 4, keeping: [old.id])
        XCTAssertEqual(keepingOld.map(\.id), [voted.id, old.id] + capped.dropFirst().dropLast().map(\.id))
        // Voted bills fill the limit: the kept bill is the one bill over it.
        XCTAssertEqual(BillsStore.capBills([old, voted], limit: 1, keeping: [old.id]).map(\.id), [voted.id, old.id])
        XCTAssertEqual(BillsStore.capBills([old, voted], limit: 1).map(\.id), [voted.id])
    }

    /// Several kept bills (a companion group's members): each stays, as many of the lowest-ranked other
    /// bills go, and a kept bill the feed order keeps anyway is not the one dropped for another.
    @MainActor
    func testCappingKeepsEveryKeptBill() {
        let voted = companionTestBill("BILLS-119hr1", userVote: .yea)
        let newer = companionTestBill("BILLS-119hr2", storedAt: "2026-09-21T11:00:00.000Z")
        let recent = companionTestBill("BILLS-119hr3", storedAt: "2026-09-20T11:00:00.000Z")
        let old = companionTestBill("BILLS-119hr4", storedAt: "2025-02-01T00:00:00.000Z")
        let older = companionTestBill("BILLS-119s5", storedAt: "2025-01-01T00:00:00.000Z")
        let bills = [older, old, voted, recent, newer]
        XCTAssertEqual(BillsStore.capBills(bills, limit: 4).map(\.id), [voted.id, newer.id, recent.id, old.id], "precondition")

        // One kept bill (round 1): `old`, kept by the feed order, is the one dropped for `older`.
        XCTAssertEqual(BillsStore.capBills(bills, limit: 4, keeping: [older.id]).map(\.id), [voted.id, older.id, newer.id, recent.id])
        // Both kept: the lowest-ranked other bill goes instead.
        XCTAssertEqual(
            BillsStore.capBills(bills, limit: 4, keeping: [older.id, old.id]).map(\.id),
            [voted.id, older.id, newer.id, old.id]
        )
        // Two kept bills the feed order drops: two other bills go.
        XCTAssertEqual(
            BillsStore.capBills(bills, limit: 3, keeping: [older.id, old.id]).map(\.id),
            [voted.id, older.id, old.id]
        )
        // Kept bills the feed order keeps, or that are not there: unchanged.
        XCTAssertEqual(
            BillsStore.capBills(bills, limit: 4, keeping: [newer.id, old.id, voted.id, UUID()]).map(\.id),
            BillsStore.capBills(bills, limit: 4).map(\.id)
        )
        // Voted bills fill the limit: the kept bills are the ones over it.
        XCTAssertEqual(BillsStore.capBills(bills, limit: 1, keeping: [older.id, old.id]).map(\.id), [voted.id, older.id, old.id])
    }

    /// A link to a companion member (S) whose primary (P) is not loaded, into a full store: the detail
    /// screen's In Congress section fetches P (`BillCompanionMembersSection.loadMember`). Storing P
    /// keeps S, so the section's `loadTaskKey` settles after one fetch with both members current.
    /// Before, the members, both ranked last, dropped each other on every fetch and the section
    /// fetched them again without end.
    @MainActor
    func testTheMembersOfALinkedCompanionGroupSettleInAFullStore() async throws {
        let house = "BILLS-119hr500"
        let senate = "BILLS-119s250"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let storedAt = [house: "2025-01-01T00:00:00.000Z", senate: "2025-02-01T00:00:00.000Z"]
        func processed(_ guid: String) -> Bill { processedBill(guid, storedAt: storedAt[guid]!) }
        let service = FakeBillsService()
        service.processedBillResult = .success(processed(senate))
        let voted = companionTestBill("BILLS-119hr1", userVote: .yea)
        let window = (2...BillsStore.maxBillsInMemory).map { companionTestBill("BILLS-119hr\($0 + 1_000)") }
        let (store, scope) = await makeStore(service, bills: [voted] + window, groups: [group])
        XCTAssertEqual(store.bills.count, BillsStore.maxBillsInMemory, "precondition: the store is full")

        let linked = await store.loadLinkedBill(store.deepLinkTarget(forGUID: senate))
        XCTAssertEqual(linked, .loaded(billID: UUID.deterministic(from: senate)))

        // Each run of the section's `.task(id: loadTaskKey)` fetches the members that are not current
        // (none is loaded here) and stores them as `loadMember` does; a changed key runs it again.
        var key = BillCompanionMembersSection.loadTaskKey(for: group, in: store)
        XCTAssertEqual(key.isCurrent, [false, true], "precondition: the primary is fetched")
        var fetches = 0
        var settled = false
        for _ in 0..<10 {
            for (index, member) in group.memberGuids.enumerated() where !key.isCurrent[index] {
                XCTAssertTrue(store.loadedBills(ofMember: member).isEmpty, "a missing member is fetched, not hydrated")
                fetches += 1
                store.upsertCompanionMemberBill(processed(member), of: group)
            }
            let next = BillCompanionMembersSection.loadTaskKey(for: group, in: store)
            if next == key { settled = true; break }
            key = next
        }

        XCTAssertTrue(settled, "the members' load settles instead of fetching while the screen is open")
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(key.isCurrent, [true, true], "both members' details are shown")
        XCTAssertEqual(store.bills.count, BillsStore.maxBillsInMemory, "the cap holds")
        XCTAssertNotNil(store.bill(for: voted.id), "voted bills are kept")
        await settleBillsCache(scope: scope)
    }

    /// A Board bill (S) that ranks last in a full store, in a group whose other member (P) is outside
    /// the window: storing the fetched P keeps S (and P), and another bill goes. Before, S went, so the
    /// section fetched S, which dropped P, without end. Storing members fetched one after the other
    /// keeps both too.
    @MainActor
    func testStoringAFetchedCompanionMemberKeepsTheOtherMembersInAFullStore() async throws {
        let house = "BILLS-119hr500"
        let senate = "BILLS-119s250"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let voted = companionTestBill("BILLS-119hr1", userVote: .yea)
        let window = (3...BillsStore.maxBillsInMemory).map { companionTestBill("BILLS-119hr\($0 + 1_000)") }
        let boardBill = companionTestBill(senate, storedAt: "2026-09-01T00:00:00.000Z")
        let (store, scope) = await makeStore(FakeBillsService(), bills: [voted] + window + [boardBill], groups: [group])
        XCTAssertEqual(store.bills.count, BillsStore.maxBillsInMemory, "precondition: the store is full")
        XCTAssertEqual(rankBillsForBoard(window + [boardBill]).last?.id, boardBill.id, "precondition: S ranks last")
        let lowestOther = try XCTUnwrap(rankBillsForBoard(window).last)

        store.upsertCompanionMemberBill(processedBill(house), of: group)

        XCTAssertNotNil(store.bill(for: UUID.deterministic(from: house)), "the fetched member is stored")
        XCTAssertNotNil(store.bill(for: boardBill.id), "the other member stays")
        XCTAssertNil(store.bill(for: lowestOther.id), "the lowest-ranked other bill went instead")
        XCTAssertEqual(store.bills.count, BillsStore.maxBillsInMemory, "the cap holds")
        XCTAssertNotNil(store.bill(for: voted.id), "voted bills are kept")

        // Neither member loaded: P, then S.
        let (empty, emptyScope) = await makeStore(FakeBillsService(), bills: [voted] + window + [companionTestBill("BILLS-119hr2")], groups: [group])
        XCTAssertEqual(empty.bills.count, BillsStore.maxBillsInMemory, "precondition: the store is full")
        empty.upsertCompanionMemberBill(processedBill(house), of: group)
        empty.upsertCompanionMemberBill(processedBill(senate), of: group)
        XCTAssertNotNil(empty.bill(for: UUID.deterministic(from: house)), "both members stay")
        XCTAssertNotNil(empty.bill(for: UUID.deterministic(from: senate)), "both members stay")
        XCTAssertEqual(empty.bills.count, BillsStore.maxBillsInMemory, "the cap holds")
        await settleBillsCache(scope: scope)
        await settleBillsCache(scope: emptyScope)
    }
}
