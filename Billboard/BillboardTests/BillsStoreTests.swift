import Combine
import XCTest
@testable import Billboard

/// `BillsStore` loading and hydration against a fake bills service. Each test uses its
/// own cache scope; tests that make the store write its bills cache wait for the write
/// and then remove it.
final class BillsStoreTests: XCTestCase {
    private static let connectivityCopy = "Can't reach Billboard right now. Check your connection and try again."

    @MainActor
    private func makeStore(
        _ service: FakeBillsService,
        bills: [Bill]? = nil,
        preferences: FakePreferencesService? = nil
    ) -> (store: BillsStore, scope: String) {
        let scope = "bills-store-tests-\(UUID().uuidString)"
        addTeardownBlock {
            BillsStore.clearCachedBills(scope: scope)
        }
        let store = BillsStore(
            bills: bills,
            cacheScope: scope,
            service: service,
            preferencesService: preferences ?? FakePreferencesService()
        )
        return (store, scope)
    }

    /// The store writes its bills cache from a detached task (data first, then a
    /// timestamp). Waits for the timestamp and removes it, so each call waits for the
    /// next write and none lands after the teardown clears the scope.
    @MainActor
    private func waitForBillsCacheWrite(scope: String, file: StaticString = #filePath, line: UInt = #line) async {
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        // Mirrors BillsStore's private timestamp key.
        let timestampKey = ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope)
        for _ in 0..<500 {
            if UserDefaults.standard.object(forKey: timestampKey) != nil {
                UserDefaults.standard.removeObject(forKey: timestampKey)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The bills cache was not written", file: file, line: line)
    }

    private func manifestItem(
        guid: String,
        title: String,
        updatedDaysAgo: Double,
        billStatus: String? = "new",
        isPriority: Bool? = nil
    ) -> BillsManifestItem {
        let updatedAt = Date().addingTimeInterval(-updatedDaysAgo * 24 * 60 * 60)
        return BillsManifestItem(
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: String(guid.filter(\.isNumber).dropFirst(3)),
            updatedAt: ISO8601DateFormatter().string(from: updatedAt),
            subCategories: [],
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            isPriority: isPriority,
            title: title,
            billStatus: billStatus
        )
    }

    // MARK: - load()

    @MainActor
    func testWindowedLoadAppliesTheManifest() async throws {
        let service = FakeBillsService()
        service.manifestResults = [.success([
            manifestItem(guid: "BILLS-119hr101ih", title: "Recent bill", updatedDaysAgo: 1),
            manifestItem(guid: "BILLS-119hr202ih", title: "Older bill", updatedDaysAgo: 30)
        ])]
        let (store, scope) = makeStore(service)

        await store.load(historyWindow: .oneWeek)

        XCTAssertEqual(service.manifestRequests.count, 1)
        let updatedAfter = try XCTUnwrap(service.manifestRequests.first ?? nil)
        XCTAssertEqual(updatedAfter.timeIntervalSinceNow, -7 * 24 * 60 * 60, accuracy: 60)

        XCTAssertEqual(Set(store.manifestItems.map(\.guid)), ["BILLS-119hr101ih", "BILLS-119hr202ih"])
        XCTAssertEqual(store.activeManifestBills.map(\.title), ["Recent bill"], "only bills inside the history window are shown")
        XCTAssertTrue(store.hasLoadedOnce)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.canLoadMore)
        XCTAssertFalse(store.hasFullManifestCoverage)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.loadErrorMessage)
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testFullManifestLoadRequestsEverything() async throws {
        let service = FakeBillsService()
        service.manifestResults = [.success([manifestItem(guid: "BILLS-119hr101ih", title: "Recent bill", updatedDaysAgo: 2)])]
        let (store, scope) = makeStore(service)

        await store.load(loadFullManifest: true, historyWindow: .oneWeek)

        XCTAssertEqual(service.manifestRequests.count, 1)
        XCTAssertNil(service.manifestRequests[0], "a full load sends no updatedAfter")
        XCTAssertTrue(store.hasFullManifestCoverage)
        XCTAssertFalse(store.canLoadMore)
        XCTAssertNil(store.oldestFetchedDate)
        XCTAssertEqual(store.activeManifestBills.map(\.title), ["Recent bill"])
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testFreshManifestInMemoryIsNotRefetched() async {
        let service = FakeBillsService()
        service.manifestResults = [.success([manifestItem(guid: "BILLS-119hr101ih", title: "Recent bill", updatedDaysAgo: 1)])]
        let (store, scope) = makeStore(service)
        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)

        service.cacheIsFresh = true
        await store.load(historyWindow: .oneWeek)

        XCTAssertEqual(service.manifestRequests.count, 1)
        XCTAssertEqual(store.activeManifestBills.map(\.title), ["Recent bill"])
        XCTAssertNil(store.loadErrorMessage)
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testOfflineLoadFailureShowsConnectivityCopy() async {
        let service = FakeBillsService()
        service.manifestResults = [.failure(URLError(.notConnectedToInternet))]
        let (store, _) = makeStore(service)

        await store.load(historyWindow: .oneWeek)

        XCTAssertEqual(store.errorMessage, "Could not load bills right now. Pull to refresh and try again.")
        XCTAssertEqual(store.loadErrorMessage, Self.connectivityCopy)
        XCTAssertTrue(store.hasLoadedOnce)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.bills.isEmpty)
        XCTAssertTrue(store.activeManifestBills.isEmpty)
    }

    @MainActor
    func testUnreadableManifestShowsGenericCopy() async {
        let service = FakeBillsService()
        service.manifestResults = [.failure(APIServiceError.invalidPayload("bills-manifest"))]
        let (store, _) = makeStore(service)

        await store.load(historyWindow: .oneWeek)

        XCTAssertEqual(store.loadErrorMessage, "We couldn't load your bills right now. Try again in a moment.")
    }

    @MainActor
    func testSuccessfulReloadClearsTheLoadError() async {
        let service = FakeBillsService()
        service.manifestResults = [
            .failure(URLError(.timedOut)),
            .success([manifestItem(guid: "BILLS-119hr101ih", title: "Recent bill", updatedDaysAgo: 1)])
        ]
        let (store, scope) = makeStore(service)

        await store.load(historyWindow: .oneWeek)
        XCTAssertEqual(store.loadErrorMessage, Self.connectivityCopy)

        await store.load(forceRefresh: true, historyWindow: .oneWeek)

        XCTAssertEqual(service.manifestRequests.count, 2)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.loadErrorMessage)
        XCTAssertEqual(store.activeManifestBills.map(\.title), ["Recent bill"])
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testCancelledLoadReportsNothing() async {
        let service = FakeBillsService()
        service.manifestResults = [.failure(CancellationError())]
        let (store, _) = makeStore(service)

        await store.load(historyWindow: .oneWeek)

        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.loadErrorMessage)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testCancelledRequestsReportNothing() async {
        // Amplify reports a cancelled request as an error wrapping `URLError.cancelled`.
        let cancellations: [Error] = [
            URLError(.cancelled),
            NSError(domain: "Amplify.APIError", code: 0, userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)])
        ]
        for cancellation in cancellations {
            let service = FakeBillsService()
            service.manifestResults = [.failure(cancellation)]
            let (store, _) = makeStore(service)

            await store.load(historyWindow: .oneWeek)
            XCTAssertNil(store.errorMessage, "\(cancellation)")
            XCTAssertNil(store.loadErrorMessage, "\(cancellation)")

            await store.loadMore()
            XCTAssertEqual(service.manifestRequests.count, 2, "Load More asked for older bills")
            XCTAssertNil(store.errorMessage, "\(cancellation)")
        }
    }

    // MARK: - Cache restore

    @MainActor
    func testLoadWaitsForTheCacheRestoreSoTheCacheDoesNotReplaceNewerBills() async {
        let service = FakeBillsService()
        service.cachedManifest = [manifestItem(guid: "BILLS-119hr1", title: "Cached bill", updatedDaysAgo: 1)]
        service.manifestResults = [.success([manifestItem(guid: "BILLS-119hr2", title: "Fetched bill", updatedDaysAgo: 1)])]
        // Hold the restore in its cache read until the load has had time to fetch and apply.
        let releaseRead = DispatchSemaphore(value: 0)
        service.onCachedManifestRead = { releaseRead.wait() }
        let (store, scope) = makeStore(service)

        let restore = Task { await store.restoreCachedStateIfNeeded() }
        let load = Task { await store.load(forceRefresh: true, historyWindow: .oneWeek) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(service.manifestRequests.isEmpty, "the load waits for the restore")
        releaseRead.signal()
        await restore.value
        await load.value

        XCTAssertEqual(store.manifestItems.map(\.guid), ["BILLS-119hr2"])
        XCTAssertEqual(store.bills.map(\.title), ["Fetched bill"])
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testRecordedFullCoverageWithoutACachedManifestIsNotFull() async {
        let service = FakeBillsService()
        // Coverage says full, but there is no copy to read (Caches purged, or the file does not decode).
        service.cacheIsFull = true
        service.cachedManifest = nil
        service.manifestResults = [.success([manifestItem(guid: "BILLS-119hr1", title: "Fetched bill", updatedDaysAgo: 1)])]
        let (store, scope) = makeStore(service)

        await store.ensureFullManifestLoaded()

        XCTAssertEqual(service.manifestRequests, [nil], "the full manifest is fetched")
        XCTAssertTrue(store.hasFullManifestCoverage)
        XCTAssertEqual(store.manifestItems.map(\.guid), ["BILLS-119hr1"])
        await waitForBillsCacheWrite(scope: scope)
    }

    // MARK: - ensureHydrated(billID:)

    @MainActor
    private func placeholderBill(guid: String) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: "Placeholder",
            category: "Other",
            soWhat: "",
            billStatus: .new,
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: "101",
            userVoted: false,
            userWatched: true
        )
    }

    @MainActor
    func testEnsureHydratedReplacesThePlaceholderAndKeepsUserState() async throws {
        let guid = "BILLS-119hr101ih"
        let placeholder = placeholderBill(guid: guid)
        let service = FakeBillsService()
        service.processedBillResult = .success(Bill(
            id: placeholder.id,
            title: "Processed title",
            category: "Economy",
            soWhat: "Why it matters",
            link: "https://example.test/bill",
            billStatus: .passed,
            guid: guid,
            userVoted: false,
            isProcessedDetailHydrated: true
        ))
        let (store, scope) = makeStore(service, bills: [placeholder])

        let message = await store.ensureHydrated(billID: placeholder.id)

        XCTAssertNil(message)
        let request = try XCTUnwrap(service.processedBillRequests.first)
        XCTAssertEqual(request.guid, guid)
        XCTAssertEqual(request.congress, "119")
        XCTAssertEqual(request.billType, "hr")
        XCTAssertEqual(request.billID, "101")
        let hydrated = try XCTUnwrap(store.bill(for: placeholder.id))
        XCTAssertEqual(hydrated.title, "Processed title")
        XCTAssertTrue(store.isBillDetailHydrated(hydrated))
        XCTAssertTrue(hydrated.userWatched, "local watch state survives hydration")
        XCTAssertNil(store.errorMessage)
        await waitForBillsCacheWrite(scope: scope)

        // Already hydrated: no second request.
        _ = await store.ensureHydrated(billID: placeholder.id)
        XCTAssertEqual(service.processedBillRequests.count, 1)
    }

    @MainActor
    func testEnsureHydratedFailureReturnsCopyAndReportsOnlyWhenAsked() async {
        let guid = "BILLS-119hr101ih"
        let placeholder = placeholderBill(guid: guid)
        let service = FakeBillsService()
        service.processedBillResult = .failure(APIServiceError.invalidPayload("processed-bill"))
        let (store, _) = makeStore(service, bills: [placeholder])

        let quietMessage = await store.ensureHydrated(billID: placeholder.id, reportsError: false)
        XCTAssertEqual(quietMessage, "We couldn't load this bill right now. Try again in a moment.")
        XCTAssertNil(store.errorMessage)

        let reportedMessage = await store.ensureHydrated(billID: placeholder.id)
        XCTAssertEqual(reportedMessage, "We couldn't load this bill right now. Try again in a moment.")
        XCTAssertEqual(store.errorMessage, "Couldn't load this bill.")
        XCTAssertEqual(store.bill(for: placeholder.id)?.title, "Placeholder")
    }

    @MainActor
    func testANewerManifestRowRefetchesHydratedDetailsAndDropsARemovedTally() async throws {
        // REL-31: the device hydrated this bill before the repair, with a Congressional Record page
        // range read as a House tally; the repair rewrote the processed bill without it.
        let guid = "BILLS-119hr5334"
        let chamber = { (yea: Int, nay: Int) in
            Bill.OfficialChamberVote(
                yea: yea, nay: nay, present: 0, notVoting: 0, totalCounted: yea + nay,
                actionCode: nil, actionDate: nil, resultText: nil, memberDataAvailable: false, members: []
            )
        }
        let hydrated = Bill(
            id: UUID.deterministic(from: guid),
            title: "Repaired bill",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60)),
            link: "https://example.test/bill",
            billStatus: .passed,
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: "5334",
            userVoted: false,
            userWatched: true,
            officialVotes: Bill.OfficialVotesBreakdown(
                house: chamber(3111, 3112), senate: chamber(60, 40), lastSyncedAt: nil, source: nil, completeness: nil
            ),
            isProcessedDetailHydrated: true
        )
        let repairedRow = manifestItem(guid: guid, title: "Repaired bill", updatedDaysAgo: 1, billStatus: "Passed")
        let service = FakeBillsService()
        service.manifestResults = [.success([repairedRow])]
        let (store, scope) = makeStore(service, bills: [hydrated])
        XCTAssertTrue(store.isBillDetailHydrated(hydrated))

        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)

        let stale = try XCTUnwrap(store.bill(forGUID: guid))
        XCTAssertFalse(store.isBillDetailHydrated(stale), "the processed bill changed after it was hydrated")

        service.processedBillResult = .success(Bill(
            id: hydrated.id,
            title: "Repaired bill",
            category: "Other",
            soWhat: "",
            storedAt: repairedRow.updatedAt,
            link: "https://example.test/bill",
            billStatus: .passed,
            guid: guid,
            userVoted: false,
            officialVotes: Bill.OfficialVotesBreakdown(house: nil, senate: chamber(60, 40), lastSyncedAt: nil, source: nil, completeness: nil),
            isProcessedDetailHydrated: true
        ))
        let message = await store.ensureHydrated(billID: hydrated.id)
        await waitForBillsCacheWrite(scope: scope)

        XCTAssertNil(message)
        XCTAssertEqual(service.processedBillRequests.map(\.guid), [guid])
        let repaired = try XCTUnwrap(store.bill(forGUID: guid))
        XCTAssertNil(repaired.officialVotes?.house)
        XCTAssertNil(repaired.congressHouseYeaCount)
        XCTAssertNil(repaired.congressHouseNayCount)
        XCTAssertEqual(repaired.congressSenateYeaCount, 60)
        XCTAssertTrue(repaired.userWatched)
        XCTAssertTrue(store.isBillDetailHydrated(repaired))

        _ = await store.ensureHydrated(billID: hydrated.id)
        XCTAssertEqual(service.processedBillRequests.count, 1, "fresh again: no second request")
    }

    @MainActor
    func testDetailsMarkedStaleStayOnScreenAndRestartTheDetailFetch() async throws {
        // The user opened H.R. 900 days ago; a newer processed bill (a new text version, a patch or the
        // REL-31 repair) moved the manifest row on. BillDetail keeps the cached details on screen while
        // it fetches them again, and still shows them when that fetch fails (offline).
        let guid = "BILLS-119hr900"
        let hydrated = Bill(
            id: UUID.deterministic(from: guid),
            title: "Cached bill",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 24 * 60 * 60)),
            link: "https://example.test/bill",
            billStatus: .updated,
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: "900",
            userVoted: false,
            isProcessedDetailHydrated: true
        )
        let newerRow = manifestItem(guid: guid, title: "Cached bill", updatedDaysAgo: 1, billStatus: "Updated")
        let service = FakeBillsService()
        service.manifestResults = [.success([newerRow])]
        service.processedBillResult = .failure(APIServiceError.invalidPayload("processed-bill"))
        let (store, scope) = makeStore(service, bills: [hydrated])
        let openedKey = BillDetail.hydrationTaskKey(billID: hydrated.id, bill: hydrated, in: store)
        XCTAssertTrue(BillDetail.isDetailReady(hydrated, in: store))

        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)

        let stale = try XCTUnwrap(store.bill(forGUID: guid))
        XCTAssertFalse(store.isBillDetailHydrated(stale), "the processed bill changed after it was hydrated")
        XCTAssertTrue(BillDetail.isDetailReady(stale, in: store), "the cached details stay on screen")
        XCTAssertNotEqual(
            BillDetail.hydrationTaskKey(billID: hydrated.id, bill: stale, in: store),
            openedKey,
            "the open screen fetches the details again"
        )

        let message = await store.ensureHydrated(billID: hydrated.id, reportsError: false)
        XCTAssertNotNil(message)
        let afterFailure = try XCTUnwrap(store.bill(forGUID: guid))
        XCTAssertEqual(afterFailure.link, "https://example.test/bill")
        XCTAssertTrue(BillDetail.isDetailReady(afterFailure, in: store), "offline, the cached details still open")

        // A manifest placeholder that was never hydrated has nothing to show yet.
        XCTAssertFalse(BillDetail.isDetailReady(BillsStore.placeholderBill(from: newerRow), in: store))
        XCTAssertFalse(BillDetail.isDetailReady(placeholderBill(guid: "BILLS-119hr101ih"), in: store))
    }

    // MARK: - vote(billID:)

    @MainActor
    func testVoteSyncsThroughTheVoteStoreAndSavesTheBillPreference() async throws {
        let guid = "BILLS-119hr101ih"
        let placeholder = placeholderBill(guid: guid)
        let votes = FakeBillVotesService()
        let preferences = FakePreferencesService()
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        let (store, scope) = makeStore(FakeBillsService(), bills: [placeholder], preferences: preferences)
        store.connect(voteStore: voteStore)

        let stored = await store.vote(billID: placeholder.id, vote: .yea, watch: true, reasons: [.healthcare])?.value

        XCTAssertEqual(stored, true)
        XCTAssertEqual(votes.setFeedbackCalls, [.init(billId: guid, feedback: .yea, reasons: ["healthcare"])])
        XCTAssertEqual(voteStore.vote(for: guid), .voted(.yea))
        let bill = try XCTUnwrap(store.bill(for: placeholder.id))
        XCTAssertTrue(bill.userVoted)
        XCTAssertEqual(bill.userVote, .yea)
        XCTAssertEqual(bill.userYeaCount, 1)

        // The bill preference is saved best-effort from its own task.
        for _ in 0..<500 where preferences.putCalls.isEmpty {
            await Task.yield()
        }
        let saved = try XCTUnwrap(preferences.putCalls.first)
        XCTAssertEqual(saved.map(\.preference), [guid])
        XCTAssertEqual(saved.map(\.type), ["bill"])
        XCTAssertEqual(saved.map(\.category), [""])
        await waitForBillsCacheWrite(scope: scope)
    }

    // MARK: - Writes to bills

    private func billsCacheTimestamp(scope: String) -> Any? {
        UserDefaults.standard.object(forKey: ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope))
    }

    /// A store holding `billCount` bills (`BILLS-119hr1ih`, `BILLS-119hr2ih`, ...) and connected to a vote
    /// store that holds `votes`, by guid. Bills the store holds are not marked voted until it reconciles.
    @MainActor
    private func makeStoreWithVotes(
        billCount: Int,
        votes: [String: VoteType] = [:]
    ) -> (store: BillsStore, scope: String) {
        let voteCache = BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil))
        for (guid, vote) in votes {
            voteCache.setVoted(billId: guid, vote: vote, votedAt: Date())
        }
        let voteStore = BillVoteStore(cache: voteCache, service: FakeBillVotesService())
        let (store, scope) = makeStore(
            FakeBillsService(),
            bills: (1...billCount).map { companionTestBill("BILLS-119hr\($0)ih") }
        )
        store.connect(voteStore: voteStore)
        // The bills store holds the vote store weakly; keep it for the whole test.
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        return (store, scope)
    }

    // MARK: - reconcileVotesFromCache()

    @MainActor
    func testReconcileThatChangesNothingDoesNotWriteBillsOrTheCache() async {
        let (store, scope) = makeStoreWithVotes(billCount: 300)
        let writes = BillsWriteCounter(store)

        store.reconcileVotesFromCache()

        XCTAssertEqual(writes.count, 0)
        // The cache is written from a detached task: wait for any write before checking there was none.
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        XCTAssertNil(billsCacheTimestamp(scope: scope))
    }

    @MainActor
    func testReconcileMarksTheBillsTheVoteStoreHoldsWithOneWriteAndSavesThem() async throws {
        let (store, scope) = makeStoreWithVotes(
            billCount: 300,
            votes: ["BILLS-119hr3ih": .yea, "BILLS-119hr7ih": .nay, "BILLS-119hr9ih": .abstain]
        )
        let writes = BillsWriteCounter(store)

        store.reconcileVotesFromCache()

        XCTAssertEqual(writes.count, 1)
        // An abstain is not a vote. The other 297 bills are as they were.
        XCTAssertEqual(store.bills.filter(\.userVoted).compactMap(\.guid).sorted(), ["BILLS-119hr3ih", "BILLS-119hr7ih"])
        XCTAssertEqual(store.bill(forGUID: "BILLS-119hr3ih")?.userVoted, true, "the lookups follow the write")
        XCTAssertEqual(store.bill(for: UUID.deterministic(from: "BILLS-119hr7ih"))?.userVoted, true)
        XCTAssertEqual(store.bill(forGUID: "BILLS-119hr9ih")?.userVoted, false)
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testReconcileClearsLegacyAbstainStateWithOneWriteAndSavesIt() async throws {
        let (store, scope) = makeStoreWithVotes(billCount: 300)
        var legacy = companionTestBill("BILLS-119hr5ih")
        legacy.userVoted = true
        legacy.userVote = .abstain
        legacy.lastVotedAt = Date()
        // Assigned after the init, which already normalizes the bills it is given.
        store.bills[4] = legacy
        let writes = BillsWriteCounter(store)

        store.reconcileVotesFromCache()

        XCTAssertEqual(writes.count, 1)
        let bill = try XCTUnwrap(store.bill(forGUID: "BILLS-119hr5ih"))
        XCTAssertFalse(bill.userVoted)
        XCTAssertNil(bill.userVote)
        XCTAssertNil(bill.lastVotedAt)
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testReconcileLeavesBillsThatAreAlreadyVotedAlone() async {
        let guid = "BILLS-119hr2ih"
        let (store, scope) = makeStoreWithVotes(billCount: 300, votes: [guid: .yea])
        store.bills[1] = companionTestBill(guid, userVote: .yea)
        let writes = BillsWriteCounter(store)

        store.reconcileVotesFromCache()

        XCTAssertEqual(writes.count, 0, "the vote store agrees with the bill, so there is nothing to write")
        XCTAssertEqual(store.bill(forGUID: guid)?.userVote, .yea)
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        XCTAssertNil(billsCacheTimestamp(scope: scope))
    }

    // MARK: - vote(billID:) writes

    @MainActor
    func testVoteWritesTheBillOnce() async throws {
        let (store, scope) = makeStoreWithVotes(billCount: 300)
        let guid = "BILLS-119hr10ih"
        var voted = companionTestBill(guid, userVote: .yea)
        voted.userYeaCount = 4
        store.bills[9] = voted
        let writes = BillsWriteCounter(store)

        // A changed vote runs the whole per-bill update: the vote, the watch, both counts and the time.
        _ = await store.vote(billID: voted.id, vote: .nay, watch: true)?.value

        XCTAssertEqual(writes.count, 1)
        let bill = try XCTUnwrap(store.bill(forGUID: guid))
        XCTAssertTrue(bill.userVoted)
        XCTAssertTrue(bill.userWatched)
        XCTAssertEqual(bill.userVote, .nay)
        XCTAssertEqual(bill.userYeaCount, 3)
        XCTAssertEqual(bill.userNayCount, 1)
        XCTAssertNotNil(bill.lastVotedAt)
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testGroupVoteOnAPrimaryThatIsNotLoadedAddsItsBillWithOneWrite() async throws {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let (store, _, scope) = await makeCompanionStore(bills: [companionTestBill(senate)], groups: [group])
        let writes = BillsWriteCounter(store)

        _ = await store.vote(billID: UUID.deterministic(from: senate), vote: .yea, watch: false)?.value

        XCTAssertEqual(writes.count, 1, "the placeholder is added with the vote on it")
        let added = try XCTUnwrap(store.bill(forGUID: house))
        XCTAssertEqual(added.userVote, .yea)
        XCTAssertEqual(added.userYeaCount, 1)
        XCTAssertTrue(added.userVoted)
        await settleBillsCache(scope: scope)
    }

    // MARK: - Updates feed

    @MainActor
    func testUpdatesFeedListsABillThatPassedInARefreshThatChangesNoVotes() async throws {
        let service = FakeBillsService()
        let steady = manifestItem(guid: "BILLS-119hr101ih", title: "Steady bill", updatedDaysAgo: 1, isPriority: true)
        let passed = manifestItem(guid: "BILLS-119hr202ih", title: "Passed bill", updatedDaysAgo: 1, billStatus: "Passed", isPriority: true)
        service.manifestResults = [.success([steady]), .success([steady, passed])]
        let (store, scope) = makeStore(service)
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        store.connect(voteStore: voteStore)
        // The bills store holds the vote store weakly; keep it for the whole test.
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)
        let refreshes = UpdatesFeedRefreshes(store, voteStore: voteStore)

        // The refresh brings the bill, and nothing in it is a vote to reconcile: the merge is the last
        // write to `bills`, so the one publish after it is the only one the Updates screen hears.
        await store.load(forceRefresh: true, historyWindow: .oneWeek)
        await refreshes.settle()

        XCTAssertEqual(refreshes.afterWrite.last?.passedBills.map(\.guid), ["BILLS-119hr202ih"])
        XCTAssertEqual(refreshes.inPublisher.last?.passedBills.map(\.guid), [], "the publisher fires before the write")
        await waitForBillsCacheWrite(scope: scope)
    }

    @MainActor
    func testUpdatesFeedDropsABillOnceVotedFromTheBillsAfterTheVoteWrite() async throws {
        var passed = companionTestBill("BILLS-119hr7ih", status: .passed)
        passed.isPriority = true
        let (store, voteStore, scope) = await makeCompanionStore(bills: [passed], groups: [])
        let refreshes = UpdatesFeedRefreshes(store, voteStore: voteStore)

        // The vote writes the bill once, so that one publish is the only one the Updates screen hears
        // from `bills`.
        _ = await store.vote(billID: passed.id, vote: .yea, watch: false)?.value
        await refreshes.settle()

        XCTAssertEqual(refreshes.afterWrite.last?.passedBills.map(\.guid), [])
        XCTAssertEqual(refreshes.inPublisher.last?.passedBills.map(\.guid), ["BILLS-119hr7ih"], "the publisher fires before the write")
        await settleBillsCache(scope: scope)
    }

    // MARK: - Companion groups (APPF-23)

    @MainActor
    func testGroupVoteWithThePrimaryNotLoadedWritesThePrimaryAndAddsItsBill() async throws {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let votes = FakeBillVotesService()
        let (store, voteStore, scope) = await makeCompanionStore(bills: [companionTestBill(senate)], groups: [group], votes: votes)

        let stored = await store.vote(billID: UUID.deterministic(from: senate), vote: .nay, watch: false)?.value

        XCTAssertEqual(stored, true)
        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), [house], "no vote yet: the primary is the target")
        XCTAssertEqual(voteStore.vote(for: house), .voted(.nay))
        let added = try XCTUnwrap(store.bill(forGUID: house))
        XCTAssertEqual(added.id, UUID.deterministic(from: house))
        XCTAssertEqual(added.userVote, .nay)
        XCTAssertEqual([added.congress, added.billType, added.billID], ["119", "hr", "900"])
        XCTAssertNil(store.bill(forGUID: senate)?.userVote)
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testWithoutGroupsVotingIsPerBill() async {
        let votes = FakeBillVotesService()
        let (store, _, scope) = await makeCompanionStore(
            bills: [companionTestBill("BILLS-119hr900"), companionTestBill("BILLS-119s456")],
            groups: [],
            votes: votes
        )

        _ = await store.vote(billID: UUID.deterministic(from: "BILLS-119s456"), vote: .yea, watch: false)?.value

        XCTAssertEqual(votes.setFeedbackCalls.map(\.billId), ["BILLS-119s456"])
        XCTAssertNil(store.companionVote(forBillID: UUID.deterministic(from: "BILLS-119s456")))
        XCTAssertEqual(store.companionMemberBillIDs(forBillID: UUID.deterministic(from: "BILLS-119s456")), [UUID.deterministic(from: "BILLS-119s456")])
        await settleBillsCache(scope: scope)
    }
}

/// Counts the writes to a store's `bills`. Every write rebuilds both bill lookups (O(bills)), however small
/// it is, so a reconcile or a vote that wrote per bill, or per field, took time quadratic in the number of
/// bills.
@MainActor
private final class BillsWriteCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init(_ store: BillsStore) {
        subscription = store.$bills.dropFirst().sink { [weak self] _ in self?.count += 1 }
    }
}

/// Rebuilds the Updates feed for each publish of a store's `bills`, the two ways the Updates screen could:
/// from inside the publisher, which fires before `bills` and the lookups built from it change, and in a
/// task started by it, which runs after the write. The screen does the second.
@MainActor
private final class UpdatesFeedRefreshes {
    private(set) var inPublisher: [UpdatesFeedSnapshot] = []
    private(set) var afterWrite: [UpdatesFeedSnapshot] = []
    private var subscription: AnyCancellable?

    init(_ store: BillsStore, voteStore: BillVoteStore) {
        let readState = AppReadState(scope: .user("bills-store-tests"), store: InMemoryReadStateStore())
        func feed() -> UpdatesFeedSnapshot {
            NotificationsView.updatesFeed(
                billsStore: store,
                alerts: [],
                readState: readState,
                userProfile: .placeholder(),
                voteStore: voteStore,
                historyWindow: .oneWeek
            )
        }
        subscription = store.$bills.dropFirst().sink { [weak self] _ in
            self?.inPublisher.append(feed())
            Task { @MainActor in self?.afterWrite.append(feed()) }
        }
    }

    /// Waits for the tasks the publishes started.
    func settle() async {
        for _ in 0..<100 where afterWrite.count < inPublisher.count {
            await Task.yield()
        }
    }
}
