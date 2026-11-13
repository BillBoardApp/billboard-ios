import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// What Search finds (UX-39, feature review N9): every bill of the full manifest, by its number in the usual
/// spellings (and its companion's), or by every word of the search in its headline, official title, the topic
/// the app shows, its topic group or life areas. The no-results notice says what was searched and in which
/// bills. Nothing here reads or orders by anyone's votes (INT-11).
@MainActor
final class BillsSearchMatchingTests: XCTestCase {
    private func bill(
        _ guid: String,
        title: String,
        officialTitle: String? = nil,
        category: String = "Other",
        topic: String? = nil,
        lifeAreas: [String] = [],
        type: String? = nil,
        number: String? = nil
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            officialTitle: officialTitle,
            category: category,
            subCategory: topic,
            soWhat: "",
            lifeAreas: lifeAreas,
            billStatus: .new,
            guid: guid,
            congress: "119",
            billType: type,
            billID: number,
            userVoted: false
        )
    }

    private lazy var bills: [Bill] = [
        bill("BILLS-119hr1", title: "One Big Beautiful Bill", type: "hr", number: "1"),
        bill("BILLS-119hr10", title: "Bill ten", type: "hr", number: "10"),
        bill("BILLS-119hres1", title: "House rules", type: "hres", number: "1"),
        bill("BILLS-119s5", title: "Detain immigrants charged with theft", officialTitle: "Laken Riley Act", category: "Social Policy", topic: "Immigration and Border Control", type: "s", number: "5"),
        bill("BILLS-119hr2", title: "Medicare dental coverage", category: "Social Policy", topic: "Healthcare", lifeAreas: ["Health Care Costs"], type: "hr", number: "2"),
        bill("BILLS-119hr3", title: "Puente para la Peña", category: "Economic Policy", topic: "Housing", lifeAreas: ["Housing and Rent"], type: "hr", number: "3")
    ]

    private func search(_ text: String, in bills: [Bill]? = nil, companions: CompanionGroupIndex = .empty) -> [String] {
        guard let query = BillsSearch.Query(text) else { return [] }
        return BillsSearch.results(in: bills ?? self.bills, query: query, companions: companions).compactMap(\.guid)
    }

    // MARK: - The query

    func testABlankSearchIsNoSearch() {
        XCTAssertNil(BillsSearch.Query(""))
        XCTAssertNil(BillsSearch.Query("   \n"))
        let query = BillsSearch.Query("  Medicare  Dental ")
        XCTAssertEqual(query?.text, "Medicare  Dental")
        XCTAssertEqual(query?.words, ["medicare", "dental"])
        XCTAssertNil(query?.numberKey)
    }

    func testANumberSearchSaysTheNumberAsCongressWritesIt() {
        XCTAssertEqual(BillsSearch.Query("hr1")?.officialNumber, "H.R. 1")
        XCTAssertEqual(BillsSearch.Query("s j res 21")?.officialNumber, "S.J.Res. 21")
        XCTAssertNil(BillsSearch.Query("medicare")?.officialNumber)
    }

    // MARK: - Numbers

    /// "H.R. 1" in each of the ways people write it finds H.R. 1 only: not H.R. 10 and not H.Res. 1.
    func testEveryCommonSpellingOfANumberFindsThatBillOnly() {
        for spelling in ["H.R. 1", "HR 1", "hr1", "H.R.1", "HR-1", "H.R. #1", "h. r. 1", "House bill 1", "house bill 001"] {
            XCTAssertEqual(search(spelling), ["BILLS-119hr1"], spelling)
        }
        XCTAssertEqual(search("H.Res. 1"), ["BILLS-119hres1"])
        XCTAssertEqual(search("House resolution 1"), ["BILLS-119hres1"])
        XCTAssertEqual(search("S. 5"), ["BILLS-119s5"])
        XCTAssertEqual(search("Senate bill 5"), ["BILLS-119s5"])
        XCTAssertEqual(search("H.R. 99999"), [])
    }

    func testTheNumberSpellingsReadAsBillNumbers() {
        XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey("HR-900"), "hr900")
        XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey("H.R. #900"), "hr900")
        XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey("House bill 900"), "hr900")
        XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey("Senate joint resolution 21"), "sjres21")
        XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey("house concurrent resolution 3"), "hconres3")
        for query in ["housing", "house", "senate bill", "house bill nine"] {
            XCTAssertNil(BillDisplayFormatting.billNumberQueryKey(query), query)
        }
        // What VoiceOver says reads back as the same number.
        XCTAssertEqual(SpokenForm.billNumber("House bill 900"), "House bill 900")
    }

    /// Over every bill, a number search lists the bill with that number first, then bills whose text names it as a
    /// whole number. Text that only holds the typed characters ("states 180" for "S 1", "H.R. 1234" for "H.R. 1")
    /// is no match.
    func testANumberSearchListsTheBillFirstAndSkipsNearMisses() {
        let near = [
            bill("BILLS-119hr7", title: "Gives states 180 days to report", type: "hr", number: "7"),
            bill("BILLS-119hr8", title: "Amends H.R. 1234 on rural roads", type: "hr", number: "8"),
            bill("BILLS-119hr9", title: "Repeals part of H.R. 1, the budget law", type: "hr", number: "9"),
            bill("BILLS-119s1", title: "Senate bill one", type: "s", number: "1"),
            bill("BILLS-119hr1", title: "One Big Beautiful Bill", type: "hr", number: "1")
        ]
        XCTAssertEqual(search("H.R. 1", in: near), ["BILLS-119hr1", "BILLS-119hr9"], "the bill, then a bill that names it")
        XCTAssertEqual(search("S 1", in: near), ["BILLS-119s1"])
        XCTAssertEqual(search("s. 1", in: near), ["BILLS-119s1"])
        XCTAssertEqual(search("H.R. 12", in: near), [], "not the start of a longer number")
    }

    /// A companion group (APPF-23) is found by either member's number and shows once, on the primary's bill.
    func testACompanionIsFoundByEitherNumber() {
        let house = bill("BILLS-119hr900", title: "Clean Water Act", type: "hr", number: "900")
        let senate = bill("BILLS-119s456", title: "Clean Water Act", type: "s", number: "456")
        let companions = CompanionGroupIndex(groups: [
            BillCompanionGroup(primaryGuid: "BILLS-119hr900", memberGuids: ["BILLS-119hr900", "BILLS-119s456"], relationship: "identical")
        ])
        XCTAssertEqual(search("S. 456", in: [house, senate], companions: companions), ["BILLS-119hr900"])
        XCTAssertEqual(search("hr 900", in: [house, senate], companions: companions), ["BILLS-119hr900"])
        XCTAssertEqual(search("clean water", in: [house, senate], companions: companions), ["BILLS-119hr900"])
    }

    // MARK: - Words

    func testTheTopicPeopleSeeAndFollowFindsTheBill() {
        XCTAssertEqual(search("healthcare"), ["BILLS-119hr2"], "the topic on the bill, not only its group")
        XCTAssertEqual(search("Immigration"), ["BILLS-119s5"])
        XCTAssertEqual(search("social policy"), ["BILLS-119s5", "BILLS-119hr2"], "the topic group still matches")
    }

    func testLifeAreasFindTheBill() {
        XCTAssertEqual(search("health care costs"), ["BILLS-119hr2"])
        XCTAssertEqual(search("rent"), ["BILLS-119hr3"])
    }

    func testTheOfficialTitleFindsAnOpenedBill() {
        XCTAssertEqual(search("Laken Riley"), ["BILLS-119s5"])
    }

    func testEveryWordMustMatchInAnyOrderCaseOrAccent() {
        XCTAssertEqual(search("dental medicare"), ["BILLS-119hr2"])
        XCTAssertEqual(search("MEDICARE"), ["BILLS-119hr2"])
        XCTAssertEqual(search("pena"), ["BILLS-119hr3"], "accents don't matter")
        XCTAssertEqual(search("medicare housing"), [], "every word, not any word")
    }

    /// Matches keep the manifest's order (newest first as the store keeps it), never anyone's votes (INT-11).
    func testMatchesKeepTheGivenOrder() {
        XCTAssertEqual(search("bill"), ["BILLS-119hr1", "BILLS-119hr10"])
        XCTAssertEqual(search("bill", in: bills.reversed()), ["BILLS-119hr10", "BILLS-119hr1"])
    }

    /// The index asks for the bills and folds them once per version of the store's bills and manifest, and
    /// gives the same matches.
    func testTheIndexGivesTheSameMatchesAndFollowsNewBills() throws {
        let index = BillsSearchIndex()
        let query = try XCTUnwrap(BillsSearch.Query("dental"))
        let first = BillsStore.SearchVersion(bills: 1, manifest: 1)
        var asked = 0
        let all = bills
        let provide: () -> [Bill] = { asked += 1; return all }
        XCTAssertEqual(index.results(for: query, version: first, companions: .empty, bills: provide).map(\.guid), ["BILLS-119hr2"])
        XCTAssertEqual(index.results(for: query, version: first, companions: .empty, bills: provide).map(\.guid), ["BILLS-119hr2"])
        let other = try XCTUnwrap(BillsSearch.Query("medicare"))
        XCTAssertEqual(index.results(for: other, version: first, companions: .empty, bills: provide).map(\.guid), ["BILLS-119hr2"])
        XCTAssertEqual(asked, 1, "one index per version")

        let more = all + [bill("BILLS-119hr4", title: "Dental care for veterans", type: "hr", number: "4")]
        let second = BillsStore.SearchVersion(bills: 1, manifest: 2)
        XCTAssertEqual(index.results(for: query, version: second, companions: .empty) { more }.map(\.guid), ["BILLS-119hr2", "BILLS-119hr4"])
    }

    // MARK: - No results

    func testNoResultsSaysWhatWasSearchedAndWhere() throws {
        let words = try XCTUnwrap(BillsSearch.Query("medicare dental"))
        XCTAssertEqual(BillsSearch.noResultsTitle(for: words), "No results for \"medicare dental\"")
        XCTAssertEqual(
            BillsSearch.noResultsMessage(for: words, coverage: .everyBill),
            "We looked in the number, title, topic and life areas of every bill."
        )
        XCTAssertEqual(
            BillsSearch.noResultsMessage(for: words, coverage: .failed(message: "Offline")),
            "We looked in the number, title, topic and life areas of the bills loaded so far."
        )

        let number = try XCTUnwrap(BillsSearch.Query("hr 99999"))
        XCTAssertEqual(
            BillsSearch.noResultsMessage(for: number, coverage: .everyBill),
            "We looked for H.R. 99999 in every bill. A bill shows up here once its text is published."
        )
    }

    // MARK: - Loading every bill

    private func manifestItem(_ guid: String, type: String, number: String, title: String, updatedAt: String) -> BillsManifestItem {
        BillsManifestItem(
            guid: guid,
            congress: "119",
            billType: type,
            billID: number,
            updatedAt: updatedAt,
            subCategories: [],
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            title: title
        )
    }

    /// Opening Search loads the full manifest with the existing request (no `updatedAfter`), so a bill that
    /// didn't change this week is searchable, though the Bills tab's window leaves it out of `bills`.
    func testSearchLoadsEveryBillWithTheFullManifestRequest() async throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let service = FakeBillsService()
        service.manifestResults = [.success([
            manifestItem("BILLS-119hr5", type: "hr", number: "5", title: "Recent bill", updatedAt: recent),
            manifestItem("BILLS-119hr1", type: "hr", number: "1", title: "One Big Beautiful Bill", updatedAt: "2025-07-04T12:00:00.000Z")
        ])]
        let scope = "bills-search-every-bill-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())

        let coverage = await store.loadEveryBillForSearch(historyWindow: .twoWeeks)

        XCTAssertEqual(coverage, .everyBill)
        XCTAssertEqual(service.manifestRequests, [nil], "the full manifest, as topic pages load it")
        XCTAssertTrue(store.hasFullManifestCoverage)
        XCTAssertFalse(store.bills.contains { $0.guid == "BILLS-119hr1" }, "outside the Bills tab's window")
        let query = try XCTUnwrap(BillsSearch.Query("H.R. 1"))
        let found = BillsSearch.results(in: store.searchableBills(), query: query, companions: store.companionGroupIndex)
        XCTAssertEqual(found.map(\.guid), ["BILLS-119hr1"])
        XCTAssertEqual(found.first?.title, "One Big Beautiful Bill", "the manifest's copy, which the bill page starts from")
        XCTAssertEqual(store.searchableBills().compactMap(\.guid), ["BILLS-119hr5", "BILLS-119hr1"], "manifest order")

        // Once every bill is in, Search asks for nothing more.
        _ = await store.loadEveryBillForSearch(historyWindow: nil)
        XCTAssertEqual(service.manifestRequests.count, 1)
        await waitForCacheWrite(scope: scope)
    }

    func testAFailedLoadGivesItsMessage() async {
        let service = FakeBillsService()
        service.manifestResults = [.failure(FakeServiceError())]
        let scope = "bills-search-every-bill-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())

        let coverage = await store.loadEveryBillForSearch(historyWindow: nil)

        XCTAssertEqual(coverage, .failed(message: "We couldn't load your bills right now. Try again in a moment."))
        XCTAssertFalse(store.hasFullManifestCoverage)
        // Search shows its own COULDN'T LOAD notice: the store's "Pull to refresh" banner would otherwise show on
        // the next bill page opened, which has no pull to refresh.
        XCTAssertNil(store.errorMessage)
    }

    /// The store says it has every bill only once the full manifest is applied: while the download is still being
    /// processed, Search keeps its loading line instead of a NOT FOUND that claims every bill was searched.
    func testEveryBillCountsOnlyOnceTheFullManifestIsApplied() async {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let service = FakeBillsService()
        service.manifestResults = [.success([
            manifestItem("BILLS-119hr5", type: "hr", number: "5", title: "Recent bill", updatedAt: recent),
            manifestItem("BILLS-119hr1", type: "hr", number: "1", title: "One Big Beautiful Bill", updatedAt: "2025-07-04T12:00:00.000Z")
        ])]
        let scope = "bills-search-every-bill-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())

        var searchableWhenCovered: [[String]] = []
        let watch = store.$hasFullManifestCoverage.dropFirst().sink { covered in
            // `@Published` sends before the value changes; everything the load applied first is already in.
            if covered { searchableWhenCovered.append(store.searchableBills().compactMap(\.guid)) }
        }
        defer { watch.cancel() }

        let coverage = await store.loadEveryBillForSearch(historyWindow: .twoWeeks)

        XCTAssertEqual(coverage, .everyBill)
        XCTAssertEqual(searchableWhenCovered, [["BILLS-119hr5", "BILLS-119hr1"]])
        await waitForCacheWrite(scope: scope)
    }

    // MARK: - A full copy left longer than the Bills window

    /// A manifest response with these rows inline.
    private func manifestPayload(_ rows: [(number: String, title: String, daysAgo: Double)]) -> Data {
        let formatter = ISO8601DateFormatter()
        let bills = rows.map { row in
            let updatedAt = formatter.string(from: Date().addingTimeInterval(-row.daysAgo * 86_400))
            return #"{"guid":"BILLS-119hr\#(row.number)","billType":"hr","congress":"119","billNumber":"\#(row.number)","title":"\#(row.title)","updatedAt":"\#(updatedAt)"}"#
        }
        return Data(#"{"generatedAt":"\#(formatter.string(from: Date()))","count":\#(rows.count),"bills":[\#(bills.joined(separator: ","))]}"#.utf8)
    }

    /// Someone opened Search once (a full copy), then didn't open the app for 30 days. At the next launch the Bills
    /// tab's 7-day fetch doesn't reach back to the copy, so the store no longer has every bill, and Search loads the
    /// full manifest instead of saying that H.R. 2, published 20 days ago, is in none of them. The live service and
    /// cache run under the store here, so the cache's own rule decides.
    func testAFullCopyLeftLongerThanTheBillsWindowIsNotEveryBill() async throws {
        let cache = BillsManifestCache(namespace: "bills-search-gap-\(UUID().uuidString)")
        addTeardownBlock { cache.clear() }
        let transport = RecordingTransport()
        let service = CacheBackedBillsService(cache: cache, transport: transport)
        // What Search loaded 30 days ago.
        transport.responses = [manifestPayload([("1", "One Big Beautiful Bill", 60)])]
        _ = try await service.getBillsManifest(updatedAfter: nil)
        UserDefaults.standard.set(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970, forKey: cache.timestampKey)

        let scope = "bills-search-gap-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        XCTAssertTrue(store.hasFullManifestCoverage, "the old copy, until the launch's fetch")

        // The launch: the Bills tab's 7-day fetch.
        transport.responses = [manifestPayload([("3", "Recent bill", 1)])]
        await store.load(historyWindow: .oneWeek)
        XCTAssertFalse(store.hasFullManifestCoverage, "a 23-day gap: not every bill")
        XCTAssertEqual(cache.coverage(), .windowed)

        // Search.
        transport.responses = [manifestPayload([("1", "One Big Beautiful Bill", 60), ("2", "Medicare dental coverage", 20), ("3", "Recent bill", 1)])]
        let coverage = await store.loadEveryBillForSearch(historyWindow: .oneWeek)

        XCTAssertEqual(coverage, .everyBill)
        XCTAssertEqual(transport.requests.map { $0.queryParameters?["updatedAfter"] == nil }, [true, false, true], "full, the launch's window, full")
        let query = try XCTUnwrap(BillsSearch.Query("H.R. 2"))
        let found = BillsSearch.results(in: store.searchableBills(), query: query, companions: store.companionGroupIndex)
        XCTAssertEqual(found.compactMap(\.guid), ["BILLS-119hr2"])
        await waitForCacheWrite(scope: scope)
    }

    /// Search open while the store stops having every bill (the Bills tab's fetch after such a gap) loads every
    /// bill again. Search used to settle "every bill" once per visit, so it went on saying it had looked in every
    /// bill when the store held only the Bills tab's window.
    func testOpenSearchLoadsEveryBillAgainWhenTheStoreLosesThem() throws {
        let service = FakeBillsService()
        service.cachedManifest = [manifestItem("BILLS-119hr1", type: "hr", number: "1", title: "One Big Beautiful Bill", updatedAt: "2025-07-04T12:00:00.000Z")]
        service.cacheIsFull = true
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        service.manifestResults = [
            .success([manifestItem("BILLS-119hr3", type: "hr", number: "3", title: "Recent bill", updatedAt: recent)]),
            .success([
                manifestItem("BILLS-119hr1", type: "hr", number: "1", title: "One Big Beautiful Bill", updatedAt: "2025-07-04T12:00:00.000Z"),
                manifestItem("BILLS-119hr3", type: "hr", number: "3", title: "Recent bill", updatedAt: recent)
            ])
        ]
        let scope = "bills-search-reload-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        store.connect(voteStore: voteStore)
        // The launch restores the cached copy first.
        Task { await store.restoreCachedStateIfNeeded() }
        for _ in 0..<100 where store.searchableBills().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(store.searchableBills().compactMap(\.guid), ["BILLS-119hr1"])
        XCTAssertTrue(store.hasFullManifestCoverage)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = AccessibilityTreeText.Host(
            NavigationStack { BillsSearchView() }
                .environmentObject(store)
                .environmentObject(voteStore)
                .environmentObject(UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService()))
                .environmentObject(AppReadState(scope: .user(scope), store: InMemoryReadStateStore()))
                .environmentObject(AppState()),
            size: CGSize(width: 390, height: 844),
            settle: 0.5,
            scene: scene
        )
        defer { host.close() }
        XCTAssertEqual(service.manifestRequests.count, 0, "every bill is in: Search asks for nothing")

        // The Bills tab's fetch replaces the full copy.
        service.cacheIsFull = false
        Task { await store.load(historyWindow: .oneWeek) }
        for _ in 0..<100 where service.manifestRequests.count < 2 || !store.hasFullManifestCoverage {
            host.run(0.05)
        }

        XCTAssertEqual(service.manifestRequests.count, 2)
        XCTAssertNotNil(service.manifestRequests.first ?? nil, "the Bills tab's window")
        XCTAssertNil(service.manifestRequests.last ?? Date(), "then the full manifest, for Search")
        XCTAssertTrue(store.hasFullManifestCoverage)
    }

    /// Lets the store's detached bills-cache write finish before the teardown clears the scope.
    private func waitForCacheWrite(scope: String) async {
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        let timestampKey = ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope)
        for _ in 0..<500 where UserDefaults.standard.object(forKey: timestampKey) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }
}

/// The live `BillsService` over a test's own manifest cache and a recording transport, so the store, the service
/// and the cache's coverage rules run as in the app.
@MainActor
private final class CacheBackedBillsService: BillsServicing {
    let cache: BillsManifestCache
    let transport: RecordingTransport

    init(cache: BillsManifestCache, transport: RecordingTransport) {
        self.cache = cache
        self.transport = transport
    }

    func getBillsManifest(updatedAfter: Date?) async throws -> [BillsManifestItem] {
        try await APIClient.$current.withValue(transport.client) {
            try await BillsManifestCache.$current.withValue(cache) {
                try await BillsService.getBillsManifest(updatedAfter: updatedAfter)
            }
        }
    }

    func getProcessedBill(guid: String, congress: String?, billType: String?, billID: String?) async throws -> Bill {
        throw FakeServiceError()
    }

    nonisolated func cachedBillsManifest() -> [BillsManifestItem]? {
        BillsManifestCache.$current.withValue(cache) { BillsService.cachedBillsManifest() }
    }

    nonisolated func cachedBillsManifestIsFresh(maxAge: TimeInterval) -> Bool {
        BillsManifestCache.$current.withValue(cache) { BillsService.cachedBillsManifestIsFresh(maxAge: maxAge) }
    }

    nonisolated func cachedBillsManifestIsFull() -> Bool {
        BillsManifestCache.$current.withValue(cache) { BillsService.cachedBillsManifestIsFull() }
    }

    nonisolated func cachedBillsManifestIsFull(maxAge: TimeInterval) -> Bool {
        BillsManifestCache.$current.withValue(cache) { BillsService.cachedBillsManifestIsFull(maxAge: maxAge) }
    }

    nonisolated func cachedCompanionGroups() -> [BillCompanionGroup]? {
        BillsManifestCache.$current.withValue(cache) { BillsService.cachedCompanionGroups() }
    }
}
