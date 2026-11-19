import XCTest
@testable import Billboard

/// UX-51 (project decision 2026-11-19): once after the update to 1.3, the app loads the full manifest, so a voted
/// or watched bill held from 1.2 outside the Bills tab's window takes its row's veto flag
/// (`BillsStore.loadFullManifestOnceForVetoedFlagIfNeeded`).
///
/// It runs only when it can matter (an update, or such a bill held), never on a fresh install; only after Home's
/// startup reconciliation; in the background, so a pull-to-refresh is never skipped for it; and a failure is
/// silent and tried again on a later launch.
final class VetoedFlagFullLoadTests: XCTestCase {
    private var defaults: UserDefaults!
    private var scope = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suite = "vetoed-flag-full-load-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        scope = "vetoed-flag-full-load-tests-\(UUID().uuidString)"
        let scope = scope
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suite)
            BillsStore.clearCachedBills(scope: scope)
        }
    }

    // MARK: - Helpers

    private func iso(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    private func item(_ guid: String, daysAgo: Double, status: String = "New", vetoed: Bool = false) throws -> BillsManifestItem {
        var object: [String: Any] = [
            "guid": guid, "congress": "119", "billType": "hr", "billID": String(guid.dropFirst(11)),
            "updatedAt": iso(daysAgo: daysAgo), "title": "Bill \(guid)", "billStatus": status
        ]
        if vetoed { object["vetoed"] = true }
        return try JSONDecoder().decode(BillsManifestItem.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// A bill as 1.2 held it: Failed, no veto flag, voted Nay.
    @MainActor
    private func votedBillHeldFrom12(_ guid: String, daysAgo: Double) throws -> Bill {
        var bill = BillsStore.placeholderBill(from: try item(guid, daysAgo: daysAgo, status: "Failed"))
        bill.userVoted = true
        bill.userVote = .nay
        XCTAssertNil(bill.vetoed)
        return bill
    }

    /// Writes the scope's bills cache, as the earlier version left it.
    private func writeBillsCache(_ bills: [Bill]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertTrue(DiskJSONCache.store(try encoder.encode(bills), forKey: ScopedStorageKey.make(base: "BillsStore.bills.data", scope: scope)))
    }

    /// A store for this launch: the manifest cache keys moved with the update, so no manifest copy is read.
    @MainActor
    private func makeStore(_ service: FakeBillsService) -> BillsStore {
        service.cachedManifest = []
        return BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())
    }

    /// Home's startup refresh, which the one-time load follows.
    @MainActor
    private func startupRefresh(_ store: BillsStore, historyWindow: BillboardHistoryWindow? = nil) async {
        await store.load(forceRefresh: true, mode: .manifestOnly, historyWindow: historyWindow ?? .oneWeek)
    }

    @MainActor
    private func loadOnce(
        _ store: BillsStore,
        historyWindow: BillboardHistoryWindow? = nil,
        afterUpdate: Bool
    ) async {
        await store.loadFullManifestOnceForVetoedFlagIfNeeded(
            historyWindow: historyWindow ?? .oneWeek,
            earlierManifestCacheFound: afterUpdate,
            defaults: defaults
        )
    }

    @MainActor
    private func isDone(_ store: BillsStore) -> Bool {
        defaults.bool(forKey: store.vetoedFlagFullLoadKey)
    }

    /// Whether the service's latest manifest request was a full fetch (`updatedAfter` nil).
    @MainActor
    private func lastRequestIsFull(_ service: FakeBillsService) -> Bool {
        guard let last = service.manifestRequests.last else { return false }
        return last == nil
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met in \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Only when it can matter

    @MainActor
    func testAFreshInstallIsMarkedDoneWithoutAFullLoad() async throws {
        let service = FakeBillsService()
        service.manifestResults = [.success([try item("BILLS-119hr9", daysAgo: 1)])]
        let store = makeStore(service)
        await startupRefresh(store)
        XCTAssertEqual(service.manifestRequests.count, 1)

        await loadOnce(store, afterUpdate: false)

        XCTAssertFalse(service.manifestRequests.contains(nil), "no full download on first launch")
        XCTAssertEqual(service.manifestRequests.count, 1)
        XCTAssertTrue(isDone(store), "marked done, so no later launch loads it either")
        XCTAssertEqual(store.vetoedFlagFullLoadKey, "BillsStore.vetoedFlagFullLoad.v1.\(scope)", "once per user")
        XCTAssertFalse(store.hasFullManifestCoverage)

        let nextLaunch = makeStore(service)
        await loadOnce(nextLaunch, afterUpdate: false)
        XCTAssertEqual(service.manifestRequests.count, 1)
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testAVotedBillInsideTheWindowTakesItsFlagFromTheWindowedLoadSoNoFullLoad() async throws {
        try writeBillsCache([try votedBillHeldFrom12("BILLS-119hr131", daysAgo: 2)])
        let service = FakeBillsService()
        service.manifestResults = [.success([try item("BILLS-119hr131", daysAgo: 2, status: "Failed", vetoed: true)])]
        let store = makeStore(service)
        await startupRefresh(store)
        XCTAssertEqual(store.bill(forGUID: "BILLS-119hr131")?.vetoed, true)

        await loadOnce(store, afterUpdate: false)

        XCTAssertEqual(service.manifestRequests.count, 1, "no full load")
        XCTAssertTrue(isDone(store))
        await settleBillsCache(scope: scope)
    }

    // MARK: - After an update

    @MainActor
    func testAVotedBillHeldOutsideTheWindowTakesItsFlagFromOneFullLoad() async throws {
        try writeBillsCache([try votedBillHeldFrom12("BILLS-119hr131", daysAgo: 400)])
        let service = FakeBillsService()
        service.manifestResults = [
            .success([try item("BILLS-119hr9", daysAgo: 1)]),
            .success([
                try item("BILLS-119hr9", daysAgo: 1),
                try item("BILLS-119hr12", daysAgo: 10),
                try item("BILLS-119hr131", daysAgo: 400, status: "Failed", vetoed: true)
            ])
        ]
        let store = makeStore(service)
        // The Bills tab shows two weeks this session.
        await startupRefresh(store, historyWindow: .twoWeeks)
        XCTAssertNil(store.bill(forGUID: "BILLS-119hr131")?.vetoed, "a windowed load does not reach it")
        XCTAssertTrue(store.bill(forGUID: "BILLS-119hr131")?.userVoted == true, "held outside the window")

        await loadOnce(store, historyWindow: .twoWeeks, afterUpdate: false)

        XCTAssertEqual(service.manifestRequests.count, 2)
        XCTAssertTrue(lastRequestIsFull(service), "a full fetch")
        let held = try XCTUnwrap(store.bill(forGUID: "BILLS-119hr131"))
        XCTAssertEqual(held.vetoed, true)
        XCTAssertTrue(held.isVetoed)
        XCTAssertTrue(held.userVoted, "the vote is kept")
        XCTAssertTrue(store.hasFullManifestCoverage)
        XCTAssertTrue(isDone(store))
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(
            Set(store.activeManifestBills.compactMap(\.guid)), ["BILLS-119hr9", "BILLS-119hr12"],
            "the Bills tab's window is kept, not reset to the saved one"
        )

        await loadOnce(store, afterUpdate: false)
        let nextLaunch = makeStore(service)
        await loadOnce(nextLaunch, afterUpdate: false)
        XCTAssertEqual(service.manifestRequests.count, 2, "once: never again in this launch or a later one")
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testAnUpdateLoadsItOnceEvenWithNoBillHeldOutsideTheWindow() async throws {
        let service = FakeBillsService()
        service.manifestResults = [
            .success([try item("BILLS-119hr9", daysAgo: 1)]),
            .success([try item("BILLS-119hr9", daysAgo: 1), try item("BILLS-119hr131", daysAgo: 400, status: "Failed", vetoed: true)])
        ]
        let store = makeStore(service)
        await startupRefresh(store)

        await loadOnce(store, afterUpdate: true)

        XCTAssertEqual(service.manifestRequests.count, 2)
        XCTAssertTrue(lastRequestIsFull(service))
        XCTAssertTrue(isDone(store))
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testAFullCopyAlreadyHeldCountsAsDone() async throws {
        let service = FakeBillsService()
        service.cacheIsFull = true
        service.cachedManifest = [try item("BILLS-119hr131", daysAgo: 400, status: "Failed", vetoed: true)]
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        await store.restoreCachedStateIfNeeded()
        XCTAssertTrue(store.hasFullManifestCoverage)

        await loadOnce(store, afterUpdate: true)

        XCTAssertTrue(service.manifestRequests.isEmpty)
        XCTAssertTrue(isDone(store))
    }

    // MARK: - A failure

    @MainActor
    func testAFailureShowsNoBannerAndIsTriedAgainOnALaterLaunch() async throws {
        try writeBillsCache([try votedBillHeldFrom12("BILLS-119hr131", daysAgo: 400)])
        let service = FakeBillsService()
        service.manifestResults = [.success([try item("BILLS-119hr9", daysAgo: 1)]), .failure(FakeServiceError())]
        let store = makeStore(service)
        await startupRefresh(store)

        await loadOnce(store, afterUpdate: true)

        XCTAssertEqual(service.manifestRequests.count, 2)
        XCTAssertTrue(lastRequestIsFull(service), "the full fetch was tried")
        XCTAssertNil(store.errorMessage, "no shared error banner")
        XCTAssertNil(store.loadErrorMessage, "no load-failure state on Home")
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.hasFullManifestCoverage)
        XCTAssertFalse(isDone(store))
        XCTAssertNil(store.bill(forGUID: "BILLS-119hr131")?.vetoed)

        await loadOnce(store, afterUpdate: true)
        XCTAssertEqual(service.manifestRequests.count, 2, "not again in this launch")
        await settleBillsCache(scope: scope)

        // A later launch: 1.2's copy was deleted at the first, but the voted bill is still held outside the window.
        let laterService = FakeBillsService()
        laterService.manifestResults = [
            .success([try item("BILLS-119hr9", daysAgo: 1)]),
            .success([try item("BILLS-119hr9", daysAgo: 1), try item("BILLS-119hr131", daysAgo: 400, status: "Failed", vetoed: true)])
        ]
        let laterLaunch = makeStore(laterService)
        await startupRefresh(laterLaunch)
        await loadOnce(laterLaunch, afterUpdate: false)

        XCTAssertEqual(laterService.manifestRequests.count, 2)
        XCTAssertTrue(lastRequestIsFull(laterService))
        XCTAssertEqual(laterLaunch.bill(forGUID: "BILLS-119hr131")?.vetoed, true)
        XCTAssertTrue(isDone(laterLaunch))
        await settleBillsCache(scope: scope)
    }

    // MARK: - A user's load comes first

    @MainActor
    func testAPullToRefreshDuringTheBackgroundLoadRunsAndIsNotSkipped() async throws {
        try writeBillsCache([try votedBillHeldFrom12("BILLS-119hr131", daysAgo: 400)])
        let service = FakeBillsService()
        let download = CancellableGate()
        service.holdFullManifest = download
        service.manifestResults = [
            .success([try item("BILLS-119hr9", daysAgo: 1)]),
            .success([try item("BILLS-119hr9", daysAgo: 1), try item("BILLS-119hr131", daysAgo: 400, status: "Failed", vetoed: true)]),
            .success([try item("BILLS-119hr9", daysAgo: 1), try item("BILLS-119hr20", daysAgo: 0)])
        ]
        let store = makeStore(service)
        await startupRefresh(store)

        let defaults = defaults!
        let background = Task {
            await store.loadFullManifestOnceForVetoedFlagIfNeeded(historyWindow: .oneWeek, earlierManifestCacheFound: true, defaults: defaults)
        }
        try await waitUntil { service.manifestRequests.count == 2 }
        XCTAssertTrue(lastRequestIsFull(service), "the full download is under way")
        XCTAssertFalse(store.isLoading, "it holds no isLoading, so the Bills tab's pull-to-refresh stays on")

        // The pull-to-refresh, as BillBoardTab starts it.
        await store.load(forceRefresh: true, mode: .manifestOnly, historyWindow: .oneWeek)

        XCTAssertEqual(service.manifestRequests.count, 3, "the refresh fetched")
        XCTAssertFalse(lastRequestIsFull(service), "a windowed fetch")
        XCTAssertNotNil(store.bill(forGUID: "BILLS-119hr20"), "and its manifest was applied")
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)

        // Opened before waiting, so a load that had not been cancelled would finish (and be marked done).
        download.open()
        await background.value
        XCTAssertFalse(isDone(store), "the refresh cancelled it, so a later launch tries again")
        XCTAssertNil(store.errorMessage, "silently")
        XCTAssertFalse(store.hasFullManifestCoverage)
        await settleBillsCache(scope: scope)
    }

    @MainActor
    func testABackgroundLoadWaitsForALoadThatIsRunning() async throws {
        try writeBillsCache([try votedBillHeldFrom12("BILLS-119hr131", daysAgo: 400)])
        let service = FakeBillsService()
        let fullDownload = CancellableGate()
        service.holdFullManifest = fullDownload
        service.manifestResults = [
            .success([try item("BILLS-119hr9", daysAgo: 1)]),
            .success([try item("BILLS-119hr9", daysAgo: 1), try item("BILLS-119hr131", daysAgo: 400, status: "Failed", vetoed: true)]),
            .success([try item("BILLS-119hr9", daysAgo: 1), try item("BILLS-119hr131", daysAgo: 400, status: "Failed", vetoed: true)])
        ]
        let store = makeStore(service)
        await startupRefresh(store)

        // Search's full load is running (its download held), then the one-time load is asked for.
        let search = Task { await store.ensureFullManifestLoaded(historyWindow: .oneWeek) }
        try await waitUntil { service.manifestRequests.count == 2 }
        XCTAssertTrue(store.isLoading)
        let defaults = defaults!
        let background = Task {
            await store.loadFullManifestOnceForVetoedFlagIfNeeded(historyWindow: .oneWeek, earlierManifestCacheFound: true, defaults: defaults)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.manifestRequests.count, 2, "it waits; it does not cancel a running load")

        fullDownload.open()
        await search.value
        await background.value

        XCTAssertTrue(store.hasFullManifestCoverage)
        XCTAssertEqual(service.manifestRequests.count, 2, "Search's full load was enough")
        XCTAssertTrue(isDone(store))
        XCTAssertEqual(store.bill(forGUID: "BILLS-119hr131")?.vetoed, true)
        await settleBillsCache(scope: scope)
    }

    // MARK: - After Home's startup reconciliation (TabsBar)

    /// The state `TabsBar` keeps: its deferred Home refresh, which clears itself when it ends.
    @MainActor
    private final class HomeStartup {
        var deferredRefresh: Task<Void, Never>?
        var reconciliationIsOver = false
    }

    @MainActor
    func testItStartsOnlyOnceHomeStartupReconciliationAndItsDeferredRefreshAreOver() async throws {
        let appState = AppState()
        let startup = HomeStartup()
        let refreshGate = Gate()
        startup.deferredRefresh = Task { @MainActor in
            await refreshGate.wait()
            startup.deferredRefresh = nil
        }

        let waiter = Task { @MainActor in
            await TabsBar.waitForHomeStartupReconciliation(appState: appState) { startup.deferredRefresh }
            startup.reconciliationIsOver = true
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(startup.reconciliationIsOver, "reconciliation has not finished")

        appState.hasCompletedHomeQueueReconciliation = true
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(startup.reconciliationIsOver, "the deferred Home refresh is still running")

        refreshGate.open()
        await waiter.value
        XCTAssertTrue(startup.reconciliationIsOver)
    }

    @MainActor
    func testItStartsAtOnceWhenHomeStartupIsAlreadyOver() async {
        let appState = AppState()
        appState.hasCompletedHomeQueueReconciliation = true
        await TabsBar.waitForHomeStartupReconciliation(appState: appState) { nil }
    }
}
