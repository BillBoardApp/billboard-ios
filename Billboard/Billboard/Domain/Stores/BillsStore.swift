import Combine
import Foundation

/// Bills for the signed-in user: the bills manifest, the bills built from it, and the user's
/// votes and watches on them.
///
/// The store is split by concern across files:
/// - `BillsStore.swift`: state, loading, and scheduling the `activeManifestBills` recalculation.
/// - `BillsStore+Manifest.swift`: manifest normalization, deduplication and placeholder bills.
/// - `BillsStore+ActiveManifest.swift`: resolving the history window into `activeManifestBills`.
/// - `BillsStore+Hydration.swift`: processed-bill hydration and merging bills with local state.
/// - `BillsStore+Cache.swift`: the per-user disk cache, and preparing it for the restore.
/// - `BillsStore+Voting.swift`: votes, watches and revotes.
///
/// Extensions in other files cannot see `private` members, so the members they share are
/// internal. Only the store and its extensions write its state.
@MainActor
final class BillsStore: ObservableObject {
    /// Written by the extensions too, so the setter is not `private`.
    @Published var bills: [Bill] {
        didSet {
            billsRevision &+= 1
            refreshBillLookups()
            requestActiveManifestBillsRecalculation()
        }
    }
    @Published private(set) var manifestItems: [BillsManifestItem] {
        didSet {
            manifestRevision &+= 1
            if let preparedEntries = preparedManifestEntriesOverride {
                manifestEntries = preparedEntries
                preparedManifestEntriesOverride = nil
            } else {
                refreshManifestEntries()
            }
            requestActiveManifestBillsRecalculation()
        }
    }
    @Published private(set) var activeManifestBills: [Bill]
    /// The companion groups (APPF-23) of the manifest: identical House and Senate bills shown as one.
    /// Empty when the server lists none (or predates them), which gives today's one card per bill.
    @Published private(set) var companionGroupIndex: CompanionGroupIndex = .empty {
        didSet {
            guard companionGroupIndex != oldValue else { return }
            companionMemberBillsCache = nil
            requestActiveManifestBillsRecalculation()
        }
    }
    /// The loaded bills of each group member (`loadedBills(ofMember:)`), for one `billsRevision`.
    private var companionMemberBillsCache: (revision: Int, byMember: [String: [Bill]])?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasLoadedOnce: Bool = false
    @Published private(set) var hasFullManifestCoverage: Bool
    /// User-facing error for the most recent failed operation.
    /// Views can bind with `BBErrorBanner(message: $billsStore.errorMessage)`.
    @Published var errorMessage: String?
    /// `errorMessage` after a failed `load()`.
    static let loadFailedBanner = "Could not load bills right now. Pull to refresh and try again."
    /// Set when the most recent `load()` failed; cleared when a load starts or succeeds.
    /// Screens use it to show a load-failure state instead of an empty one.
    @Published private(set) var loadErrorMessage: String?

    /// Bill IDs that should be treated as requiring a revote (e.g., due to a meaningful update push).
    var requiresRevoteIDs: Set<UUID> = []

    /// The latest vote recorded per guid whose write has not ended (APPF-27): only its result may roll
    /// the bill's vote back, so an earlier vote's refusal never undoes a newer vote.
    var latestVoteWrites: [String: UUID] = [:]

    /// Optional reference to the vote store so `vote()` can be the single entry point
    /// for recording votes, keeping both stores in sync automatically.
    private(set) weak var voteStore: BillVoteStore?

    /// Optional reference to the user store for syncing watch state to backend.
    private(set) weak var userStore: UserStore?

    /// Connect to a BillVoteStore so votes are automatically synced.
    /// Call this once after both stores are created (e.g., in TabsBar).
    func connect(voteStore: BillVoteStore) {
        self.voteStore = voteStore
    }

    /// Connect to UserStore so watch state syncs to backend preferences.
    func connect(userStore: UserStore) {
        self.userStore = userStore
    }

    enum LoadMode {
        /// Load only the bills manifest and create placeholder bills (fast, title-only use cases).
        /// Bill details are hydrated on demand via `ensureHydrated(billID:)`.
        case manifestOnly
    }

    nonisolated struct ManifestEntry: Sendable {
        let item: BillsManifestItem
        let updatedAtDate: Date?
        let placeholderBill: Bill
    }

    let cacheScope: String?
    let service: any BillsServicing
    let preferencesService: any PreferencesServicing
    private static let activeManifestRecalculationDebounceNanoseconds: UInt64 = 100_000_000
    /// The one restore of the cached manifest and bills. Every load awaits it, so a restore that
    /// finishes after a load cannot replace the load's newer manifest and bills with the cache.
    private var cacheRestoreTask: Task<Void, Never>?
    private var manifestEntries: [ManifestEntry] = []
    private var preparedManifestEntriesOverride: [ManifestEntry]?
    private var billsByGuid: [String: Bill]
    private var billsByID: [UUID: Bill]
    /// Bumped on every change to `bills`, so work done off the main actor can tell whether the bills
    /// it started from are still current.
    private var billsRevision = 0
    /// Bumped on every change to `manifestItems` (Search's index follows it, UX-39).
    private var manifestRevision = 0
    private let activeManifestBillsRecalculator = DebouncedRecalculator(
        debounceNanoseconds: BillsStore.activeManifestRecalculationDebounceNanoseconds,
        priority: .userInitiated
    )
    private var activeManifestBillsRecalculationSuppressionCount: Int = 0
    private var needsDeferredActiveManifestBillsRecalculation = false
    private var activeManifestHistoryWindow: BillboardHistoryWindow = .current {
        didSet {
            scheduleActiveManifestBillsRecalculation()
        }
    }

    init(
        bills: [Bill]? = nil,
        cacheScope: String? = nil,
        service: any BillsServicing = BillsService.Live(),
        preferencesService: any PreferencesServicing = PreferencesService.Live()
    ) {
        let normalizedScope = Self.normalizedScope(cacheScope)
        let initialBills: [Bill]
        if let bills {
            initialBills = Self.normalizeAbstainVotes(in: Self.deduplicate(bills))
        } else {
            initialBills = []
        }

        self.cacheScope = normalizedScope
        self.service = service
        self.preferencesService = preferencesService
        self.hasFullManifestCoverage = service.cachedBillsManifestIsFull()
        self.manifestItems = []
        self.bills = initialBills
        self.activeManifestBills = []
        self.billsByGuid = Self.makeBillLookupByGuid(from: initialBills)
        self.billsByID = Self.makeBillLookupByID(from: initialBills)
    }

    private func refreshManifestEntries() {
        manifestEntries = Self.preparedManifestEntries(from: manifestItems)
    }

    private func refreshBillLookups() {
        billsByGuid = Self.makeBillLookupByGuid(from: bills)
        billsByID = Self.makeBillLookupByID(from: bills)
    }

    private func replaceManifestItemsIfNeeded(
        _ manifest: [BillsManifestItem],
        preparedEntries: [ManifestEntry]? = nil
    ) -> Bool {
        guard !Self.manifestsAreEquivalent(manifest, manifestItems) else { return false }
        preparedManifestEntriesOverride = preparedEntries
        manifestItems = manifest
        return true
    }

    private func requestActiveManifestBillsRecalculation() {
        if activeManifestBillsRecalculationSuppressionCount > 0 {
            needsDeferredActiveManifestBillsRecalculation = true
            return
        }
        scheduleActiveManifestBillsRecalculation()
    }

    func performActiveManifestBillsBatchUpdate(_ updates: () -> Void) {
        activeManifestBillsRecalculationSuppressionCount += 1
        updates()
        activeManifestBillsRecalculationSuppressionCount -= 1

        guard activeManifestBillsRecalculationSuppressionCount == 0 else { return }
        guard needsDeferredActiveManifestBillsRecalculation else { return }

        needsDeferredActiveManifestBillsRecalculation = false
        scheduleActiveManifestBillsRecalculation()
    }

    private func scheduleActiveManifestBillsRecalculation() {
        activeManifestBillsRecalculator.schedule(
            snapshot: {
                (
                    manifestEntries: self.manifestEntries,
                    billsByGuid: self.billsByGuid,
                    billsByID: self.billsByID,
                    historyWindow: self.activeManifestHistoryWindow,
                    companions: self.companionGroupIndex
                )
            },
            compute: { snapshot -> [Bill] in
                #if DEBUG
                let startedAt = CFAbsoluteTimeGetCurrent()
                #endif

                let visibleManifestEntries = Self.visibleManifestEntries(
                    from: snapshot.manifestEntries,
                    historyWindow: snapshot.historyWindow,
                    companions: snapshot.companions
                )

                let resolvedBills = Self.resolveManifestBills(
                    manifestEntries: visibleManifestEntries,
                    billsByGuid: snapshot.billsByGuid,
                    billsByID: snapshot.billsByID
                )

                #if DEBUG
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
                if elapsedMs >= 40 {
                    HomePerfTimeline.mark(
                        "active_manifest_bills_recalculated",
                        detail: "visible=\(resolvedBills.count) manifest=\(snapshot.manifestEntries.count) bills=\(snapshot.billsByID.count) elapsedMs=\(elapsedMs)"
                    )
                }
                #endif

                return resolvedBills
            },
            apply: { resolvedBills in
                self.activeManifestBills = resolvedBills
            }
        )
    }

    /// Default time window for fetching updated bills. Controlled by the user's Home history setting.
    private static func updatedAfterInterval(for historyWindow: BillboardHistoryWindow?) -> TimeInterval {
        (historyWindow ?? BillboardHistoryWindow.current).timeInterval
    }

    /// Tracks the oldest date we've fetched bills from. Used for "load more" functionality.
    @Published private(set) var oldestFetchedDate: Date?

    /// Whether more older bills can potentially be loaded.
    @Published private(set) var canLoadMore: Bool = true

    /// - Parameter historyWindow: the Bills tab's window to keep (Search passes the session's); nil uses the
    ///   saved setting, as topic pages do.
    func ensureFullManifestLoaded(mode: LoadMode = .manifestOnly, historyWindow: BillboardHistoryWindow? = nil) async {
        // The restore checks the cached copy itself, so a full copy that is gone or unreadable does not
        // count as coverage.
        await restoreCachedStateIfNeeded()
        guard !hasFullManifestCoverage else { return }
        await load(mode: mode, loadFullManifest: true, historyWindow: historyWindow)
    }

    /// Which `searchableBills()` the store holds: it changes with every change to `bills` or the manifest, so
    /// Search can keep its index until then.
    struct SearchVersion: Equatable {
        let bills: Int
        let manifest: Int
    }

    var searchVersion: SearchVersion { SearchVersion(bills: billsRevision, manifest: manifestRevision) }

    /// Every bill Search can find (UX-39): each manifest row, which is every bill once the full manifest is
    /// loaded, as the loaded bill when the store holds it (with the user's state) and else as the row's
    /// placeholder, in manifest order; then the loaded bills the manifest lacks. `bills` alone holds only the
    /// Bills tab's window, so a bill that didn't change lately was never found.
    func searchableBills() -> [Bill] {
        let fromManifest = Self.resolveManifestBills(
            manifestEntries: manifestEntries,
            billsByGuid: billsByGuid,
            billsByID: billsByID
        )
        var seen = Set(fromManifest.map(\.id))
        var all = fromManifest
        for bill in bills where seen.insert(bill.id).inserted {
            all.append(bill)
        }
        return all
    }

    func load(
        forceRefresh: Bool = false,
        mode: LoadMode = .manifestOnly,
        loadFullManifest: Bool = false,
        historyWindow: BillboardHistoryWindow? = nil
    ) async {
        activeManifestHistoryWindow = historyWindow ?? .current
        let historyWindow = activeManifestHistoryWindow
        HomePerfTimeline.mark(
            "bills_load_requested",
            detail: "forceRefresh=\(forceRefresh) mode=\(mode) fullManifest=\(loadFullManifest) historyWindow=\(historyWindow.rawValue)"
        )
        await restoreCachedStateIfNeeded()
        if isLoading {
            HomePerfTimeline.mark("bills_load_skipped_already_loading")
            return
        }

        isLoading = true
        errorMessage = nil
        loadErrorMessage = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
            HomePerfTimeline.mark(
                "bills_load_completed",
                detail: "manifestItems=\(manifestItems.count) bills=\(bills.count) activeManifestBills=\(activeManifestBills.count)"
            )
        }

        do {
            var manifest: [BillsManifestItem]
            // Published only once the manifest is applied (below): until then Search reads the old one, and
            // "every bill" would let it say a bill doesn't exist while the full list is still being processed.
            let fullManifestCoverage: Bool
            if !forceRefresh,
               service.cachedBillsManifestIsFresh(maxAge: ManifestCachePolicy.ttl),
               !manifestItems.isEmpty {
                let cachedManifestIsFull = service.cachedBillsManifestIsFull(maxAge: ManifestCachePolicy.ttl)
                if loadFullManifest && !cachedManifestIsFull {
                    HomePerfTimeline.mark("manifest_request_started", detail: "source=full_refresh")
                    manifest = try await service.getBillsManifest(updatedAfter: nil)
                    HomePerfTimeline.mark("manifest_response_received", detail: "source=full_refresh count=\(manifest.count)")
                    oldestFetchedDate = nil
                    canLoadMore = false
                    fullManifestCoverage = true
                } else {
                    manifest = manifestItems
                    HomePerfTimeline.mark(
                        "manifest_reused_in_memory",
                        detail: "count=\(manifest.count) isFull=\(cachedManifestIsFull)"
                    )
                    if loadFullManifest || cachedManifestIsFull {
                        oldestFetchedDate = nil
                        canLoadMore = false
                        fullManifestCoverage = cachedManifestIsFull
                    } else {
                        oldestFetchedDate = oldestFetchedDate ?? Date(timeIntervalSinceNow: -Self.updatedAfterInterval(for: historyWindow))
                        canLoadMore = true
                        fullManifestCoverage = false
                    }
                }
            } else if loadFullManifest {
                // Load full manifest without date filter (for pull-to-refresh or explicit "load all").
                HomePerfTimeline.mark("manifest_request_started", detail: "source=full_refresh")
                manifest = try await service.getBillsManifest(updatedAfter: nil)
                HomePerfTimeline.mark("manifest_response_received", detail: "source=full_refresh count=\(manifest.count)")
                oldestFetchedDate = nil
                canLoadMore = false
                fullManifestCoverage = true
            } else {
                // Use updatedAfter to fetch only bills updated within the selected Home history window.
                // This reduces payload size since the API now returns DDB table items directly.
                let updatedAfter = Date(timeIntervalSinceNow: -Self.updatedAfterInterval(for: historyWindow))
                HomePerfTimeline.mark(
                    "manifest_request_started",
                    detail: "source=windowed historyWindow=\(historyWindow.rawValue)"
                )
                manifest = try await service.getBillsManifest(updatedAfter: updatedAfter)
                HomePerfTimeline.mark("manifest_response_received", detail: "source=windowed count=\(manifest.count)")
                if service.cachedBillsManifestIsFull(),
                   let cachedFullManifest = await Self.readCachedManifest(from: service) {
                    // When a full manifest cache already exists, incremental refreshes merge into it (one
                    // that leaves a gap replaces it instead, so it is no longer full: `BillsManifestCache`).
                    // Use that same cache as the live source of truth so a stale cold start and the
                    // next immediate cold start produce the same Home count.
                    manifest = cachedFullManifest
                    HomePerfTimeline.mark(
                        "manifest_upgraded_to_cached_full",
                        detail: "count=\(manifest.count)"
                    )
                    oldestFetchedDate = nil
                    canLoadMore = false
                    fullManifestCoverage = true
                } else {
                    oldestFetchedDate = updatedAfter
                    canLoadMore = true
                    fullManifestCoverage = false
                }
            }

            applyManifestUpdate(await manifestUpdate(for: manifest))
            hasFullManifestCoverage = fullManifestCoverage
            #if DEBUG
            reportDuplicateBillIDs()
            #endif

            cacheBills(bills)
        } catch {
            // Amplify reports a cancelled request as an `APIError` wrapping `URLError.cancelled`.
            if APIErrorResponse.isCancellation(error) { return }
            errorMessage = Self.loadFailedBanner
            loadErrorMessage = UserFacingLoadError.message(for: error, loading: "your bills")
            #if DEBUG
            print("[BillsStore] load() failed: \(APIErrorDebug.debugString(for: error))")
            #endif
        }
    }

    /// `manifest` normalized against the current manifest and bills, off the main actor like the cache
    /// restore: deduplicating it, building its placeholder bills and merging them with the bills covers
    /// every manifest item (tens of thousands for a full manifest).
    private func manifestUpdate(for manifest: [BillsManifestItem]) async -> (update: ManifestUpdate, billsRevision: Int) {
        let currentManifest = manifestItems
        let currentCompanionIndex = companionGroupIndex
        let existingBills = bills
        let existingBillsRevision = billsRevision
        let historyWindow = activeManifestHistoryWindow
        let service = service
        let update = await Task.detached(priority: .userInitiated) {
            // The fetch kept the cached groups current: a response's list replaced them, and one without
            // the field left them (`BillsService.getBillsManifest`).
            Self.manifestUpdate(
                for: manifest,
                companionGroups: service.cachedCompanionGroups() ?? [],
                replacing: currentManifest,
                currentCompanionIndex: currentCompanionIndex,
                existingBills: existingBills,
                historyWindow: historyWindow
            )
        }.value
        HomePerfTimeline.mark("manifest_deduplicated", detail: "count=\(update.manifest.count)")
        return (update, existingBillsRevision)
    }

    /// Publishes a manifest update. When `bills` changed while it was computed (a vote, a hydration),
    /// the placeholders are merged into the current bills instead, so that change is kept.
    private func applyManifestUpdate(_ computed: (update: ManifestUpdate, billsRevision: Int)) {
        let update = computed.update
        guard let changes = update.changes else {
            HomePerfTimeline.mark("manifest_apply_skipped_no_change", detail: "count=\(update.manifest.count)")
            return
        }

        var mergedBills = changes.mergedBills
        var resolvedActiveManifestBills = changes.resolvedActiveManifestBills
        if billsRevision != computed.billsRevision {
            mergedBills = Self.mergeIncomingBillsPreservingProtected(
                changes.visibleEntries.map(\.placeholderBill),
                existing: bills,
                source: .manifestRow
            )
            resolvedActiveManifestBills = Self.resolveManifestBills(
                manifestEntries: changes.visibleEntries,
                billsByGuid: Self.makeBillLookupByGuid(from: mergedBills),
                billsByID: Self.makeBillLookupByID(from: mergedBills)
            )
        }
        HomePerfTimeline.mark(
            "manifest_apply_started",
            detail: "visibleEntries=\(changes.visibleEntries.count) mergedBills=\(mergedBills.count)"
        )
        // Watched and voted bills outside the new manifest window stay (mergeIncomingBillsPreservingProtected).
        performActiveManifestBillsBatchUpdate {
            _ = replaceManifestItemsIfNeeded(update.manifest, preparedEntries: changes.preparedEntries)
            companionGroupIndex = update.companionIndex
            bills = mergedBills
            activeManifestBills = resolvedActiveManifestBills
        }
        HomePerfTimeline.mark(
            "manifest_apply_completed",
            detail: "manifestItems=\(manifestItems.count) bills=\(bills.count)"
        )
        applyRevoteFlagsIfNeeded()
        reconcileVotesFromCache()
        HomePerfTimeline.mark("manifest_post_apply_reconciliation_completed")
    }

    #if DEBUG
    private func reportDuplicateBillIDs() {
        let uniqueIds = Set(bills.map { $0.id })
        guard uniqueIds.count != bills.count else { return }
        print("[BillsStore] WARNING: bills array contains duplicates! Total: \(bills.count), Unique: \(uniqueIds.count)")
        var idCounts: [UUID: Int] = [:]
        for bill in bills {
            idCounts[bill.id, default: 0] += 1
        }
        for (id, count) in idCounts.filter({ $0.value > 1 }) {
            if let bill = bills.first(where: { $0.id == id }) {
                print("[BillsStore] Duplicate bill: \(bill.title) (guid: \(bill.guid ?? "nil"), id: \(id), count: \(count))")
            }
        }
    }
    #endif

    /// The cached manifest, read and decoded off the main actor (it holds the full manifest).
    private static func readCachedManifest(from service: any BillsServicing) async -> [BillsManifestItem]? {
        await Task.detached(priority: .userInitiated) {
            service.cachedBillsManifest()
        }.value
    }

    /// Restores the cached manifest and bills once; later calls wait for that restore to finish.
    /// `load`, `loadMore` and `ensureFullManifestLoaded` call it first, so the restore never applies
    /// the cache over a newer manifest.
    func restoreCachedStateIfNeeded() async {
        if let cacheRestoreTask {
            await cacheRestoreTask.value
            return
        }
        let task = Task { await self.restoreCachedState() }
        cacheRestoreTask = task
        await task.value
    }

    private func restoreCachedState() async {
        HomePerfTimeline.mark("cache_restore_started")
        let startBillsRevision = billsRevision

        #if DEBUG
        let startedAt = CFAbsoluteTimeGetCurrent()
        #endif

        let scope = cacheScope
        let service = service
        let manifestTask = Task.detached(priority: .userInitiated) {
            service.cachedBillsManifest() ?? []
        }
        let billsTask = Task.detached(priority: .userInitiated) {
            Self.cachedBills(scope: scope) ?? []
        }

        let cachedManifest = await manifestTask.value
        let cachedBills = await billsTask.value
        HomePerfTimeline.mark(
            "cache_reads_completed",
            detail: "manifest=\(cachedManifest.count) bills=\(cachedBills.count)"
        )

        let historyWindow = activeManifestHistoryWindow
        let restoreSnapshot = await Task.detached(priority: .userInitiated) {
            // The companion groups (APPF-23) are a small file of their own, read with the snapshot.
            let groups = service.cachedCompanionGroups() ?? []
            return Self.cacheRestoreSnapshot(cachedManifest: cachedManifest, cachedBills: cachedBills, cachedCompanionGroups: groups, historyWindow: historyWindow)
        }.value

        // A full copy counts only when it was read: the file can be gone (Caches purged) or unreadable
        // while its coverage is still recorded.
        hasFullManifestCoverage = !cachedManifest.isEmpty && service.cachedBillsManifestIsFull()

        if var restoredBills = restoreSnapshot.restoredBills {
            var resolvedActiveManifestBills = restoreSnapshot.resolvedActiveManifestBills
            if billsRevision != startBillsRevision {
                // `bills` changed while the cache was read (a vote, a hydrated bill): merge the restored
                // bills into them so that change is kept, with the life areas loaded since (UX-29).
                restoredBills = Self.mergeIncomingBillsPreservingProtected(restoredBills, existing: bills, source: .cachedBill)
                resolvedActiveManifestBills = Self.resolveManifestBills(
                    manifestEntries: restoreSnapshot.visibleManifestEntries,
                    billsByGuid: Self.makeBillLookupByGuid(from: restoredBills),
                    billsByID: Self.makeBillLookupByID(from: restoredBills)
                )
            }
            performActiveManifestBillsBatchUpdate {
                _ = replaceManifestItemsIfNeeded(
                    restoreSnapshot.deduplicatedManifest,
                    preparedEntries: restoreSnapshot.preparedManifestEntries
                )
                companionGroupIndex = restoreSnapshot.companionIndex
                bills = restoredBills
                activeManifestBills = resolvedActiveManifestBills
            }
        } else {
            performActiveManifestBillsBatchUpdate {
                _ = replaceManifestItemsIfNeeded(
                    restoreSnapshot.deduplicatedManifest,
                    preparedEntries: restoreSnapshot.preparedManifestEntries
                )
                companionGroupIndex = restoreSnapshot.companionIndex
                activeManifestBills = restoreSnapshot.resolvedActiveManifestBills
            }
        }

        reconcileVotesFromCache()
        HomePerfTimeline.mark(
            "cache_restore_completed",
            detail: "manifest=\(restoreSnapshot.deduplicatedManifest.count) bills=\(bills.count) visible=\(restoreSnapshot.visibleManifestEntries.count)"
        )

        #if DEBUG
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
        HomePerfTimeline.mark(
            "bills_cache_restored",
            detail: "manifest=\(restoreSnapshot.deduplicatedManifest.count) cachedBills=\(restoreSnapshot.normalizedCachedBills.count) visibleManifest=\(restoreSnapshot.visibleManifestEntries.count) elapsedMs=\(elapsedMs)"
        )
        #endif
    }

    /// Load older bills by extending the date range further back.
    /// Each call extends by another selected Home history window.
    @Published private(set) var isLoadingMore: Bool = false

    func loadMore() async {
        await restoreCachedStateIfNeeded()
        guard canLoadMore, !isLoadingMore, !isLoading else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            // Extend the window by another selected Home history window from the oldest date we've fetched.
            let baseDate = oldestFetchedDate ?? Date()
            let newOldestDate = baseDate.addingTimeInterval(-Self.updatedAfterInterval(for: nil))

            // Run through the same dedup pipeline used by initial loads before comparing.
            let olderManifest = Self.deduplicateManifest(try await service.getBillsManifest(updatedAfter: newOldestDate))
            // The response's companion groups replaced the cached list (APPF-23).
            if let groups = service.cachedCompanionGroups() {
                companionGroupIndex = CompanionGroupIndex(groups: groups)
            }

            // If we got no new logical items, we've reached the end.
            let existingGuids = Set(
                bills.compactMap {
                    $0.guid?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            )
            let existingBillKeys = Set(
                bills.compactMap { bill in
                    Self.billIdentityKey(congress: bill.congress, billType: bill.billType, billID: bill.billID, guid: bill.guid)
                }
            )

            // An item is new unless the store has its guid or another guid of the same bill. Titles
            // are not compared: distinct bills can share a generated title.
            let newItems = olderManifest.filter { item in
                if existingGuids.contains(item.guid) { return false }
                if let key = Self.billIdentityKey(congress: item.congress, billType: item.billType, billID: item.billID, guid: item.guid),
                   existingBillKeys.contains(key) {
                    return false
                }
                return true
            }

            if newItems.isEmpty {
                canLoadMore = false
                return
            }

            // Create placeholders for new items and merge.
            let newPlaceholders = newItems.map { Self.placeholderBill(from: $0) }

            // Merge with existing bills.
            var allBills = bills + newPlaceholders

            // Deduplicate before capping to ensure no duplicates slip through
            allBills = Self.deduplicate(allBills)

            // Cap total bills. Always keep voted/watched bills.
            if allBills.count > Self.maxBillsInMemory {
                allBills = Self.capBills(allBills, limit: Self.maxBillsInMemory)
                canLoadMore = false  // Hit the cap, stop loading more.
            }

            bills = allBills
            oldestFetchedDate = newOldestDate
            cacheBills(bills)
        } catch {
            if APIErrorResponse.isCancellation(error) { return }
            errorMessage = "Could not load more bills. Try again later."
            #if DEBUG
            print("[BillsStore] loadMore failed: \(APIErrorDebug.debugString(for: error))")
            #endif
        }
    }

    func bill(for billID: UUID) -> Bill? {
        bills.first { $0.id == billID }
    }

    func bill(forGUID guid: String) -> Bill? {
        let normalized = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return bills.first {
            $0.guid?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }
    }
}

// MARK: - Companion groups (APPF-23)

extension BillsStore {
    /// The companion group of the bill with this id (a member's bill, a legacy text-version bill of a
    /// member, or a group card's id before the primary's bill is loaded); nil when it is in none.
    func companionGroup(forBillID billID: UUID) -> BillCompanionGroup? {
        guard !companionGroupIndex.isEmpty else { return nil }
        if let bill = billsByID[billID], let group = companionGroupIndex.group(for: bill) { return group }
        return companionGroupIndex.groups.first { $0.memberBillIDs.contains(billID) }
    }

    /// The companion group of `guid` (a member's plain guid or a text-version guid of one).
    func companionGroup(forGUID guid: String) -> BillCompanionGroup? {
        companionGroupIndex.group(forGUID: guid)
    }

    /// The loaded bills of `group`, one per member, primary first. A member whose bill is not loaded
    /// is missing (the detail screen fetches it with `getProcessedBill`).
    func companionMemberBills(of group: BillCompanionGroup) -> [Bill] {
        companionGroupIndex.memberBills(of: group, in: bills)
    }

    /// The loaded bills of one group member (its plain guid): the bill with that guid first, then
    /// legacy text-version bills of it. Built once per change to `bills` or the groups, since screens
    /// ask for every card.
    func loadedBills(ofMember member: String) -> [Bill] {
        if let cache = companionMemberBillsCache, cache.revision == billsRevision {
            return cache.byMember[member] ?? []
        }
        var byMember: [String: [Bill]] = [:]
        for bill in bills {
            guard let memberGuid = companionGroupIndex.memberGuid(for: bill) else { continue }
            if bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines) == memberGuid {
                byMember[memberGuid, default: []].insert(bill, at: 0)
            } else {
                byMember[memberGuid, default: []].append(bill)
            }
        }
        companionMemberBillsCache = (billsRevision, byMember)
        return byMember[member] ?? []
    }

    /// Every bill id a card stands for: `billID`, each member's id and the ids of the members' loaded
    /// legacy text-version bills. `[billID]` for a bill in no group. Dismissals use it, so a dismissed
    /// group stays hidden whichever member's id is checked.
    func companionMemberBillIDs(forBillID billID: UUID) -> [UUID] {
        guard let group = companionGroup(forBillID: billID) else { return [billID] }
        return Self.uniqueIDs([billID] + memberBillIDs(of: group))
    }

    /// `companionMemberBillIDs(forBillID:)` for a guid: every member's bill id for a grouped guid,
    /// else the guid's own bill id.
    func companionMemberBillIDs(forGUID guid: String) -> [UUID] {
        let cleaned = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownID = UUID.deterministic(from: cleaned)
        guard let group = companionGroupIndex.group(forGUID: cleaned) else { return [ownID] }
        return Self.uniqueIDs([ownID] + memberBillIDs(of: group))
    }

    private func memberBillIDs(of group: BillCompanionGroup) -> [UUID] {
        group.memberBillIDs + group.memberGuids.flatMap { loadedBills(ofMember: $0).map(\.id) }
    }

    /// Stores the processed bill of a member of `group` that the detail screen fetched
    /// (`BillCompanionMembersSection`). A full store drops another bill to make room, never one of the
    /// group's members: a dropped member would be fetched again, and storing it would drop this one,
    /// without end.
    func upsertCompanionMemberBill(_ processed: Bill, of group: BillCompanionGroup) {
        upsertProcessedBill(processed, alsoKeeping: Set(memberBillIDs(of: group)))
    }

    private static func uniqueIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// The bill to open for a deep link or push to `guid`: the group's primary when its bill is
    /// loaded, else the guid's own bill (the detail screen shows the group for either member).
    /// `deepLinkTarget(forGUID:)` adds the guid to fetch when that bill is not loaded (APPF-26).
    func deepLinkBillID(forGUID guid: String) -> UUID {
        deepLinkTarget(forGUID: guid).billID
    }

    /// The bill a tapped push for `guids` opens: `deepLinkBillID(forGUID:)` of the first guid when the
    /// push names one bill, or only members of one companion group (a push describing one bill also
    /// carries its folded partner's id); nil when it names several bills (the Board tab opens).
    func pushDeepLinkBillID(forGUIDs guids: [String]) -> UUID? {
        pushDeepLinkTarget(forGUIDs: guids)?.billID
    }

    /// The group's status lead (the member furthest along) from the loaded member bills.
    func companionStatusLead(for group: BillCompanionGroup) -> CompanionStatusLead {
        companionGroupIndex.statusLead(for: group, memberBills: group.memberGuids.flatMap(loadedBills(ofMember:)))
    }
}
