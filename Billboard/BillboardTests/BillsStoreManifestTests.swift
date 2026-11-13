import XCTest
@testable import Billboard

/// `BillsStore.deduplicateManifest` merges the manifest items of one bill (legacy guids with a
/// GovInfo text-version suffix) and never merges distinct bills: bills of different types share
/// numbers (926 numbers did in the live manifest, hiding 2,910 bills), and generated titles repeat.
final class BillsStoreManifestTests: XCTestCase {
    private func item(
        _ guid: String,
        congress: String? = "119",
        type: String?,
        number: String?,
        title: String = "A bill",
        sponsors: [String] = [],
        subCategories: [String] = [],
        updatedAt: String = "2026-09-20T11:00:00.000Z"
    ) -> BillsManifestItem {
        BillsManifestItem(
            guid: guid,
            congress: congress,
            billType: type,
            billID: number,
            updatedAt: updatedAt,
            subCategories: subCategories,
            lifeAreas: [],
            sponsors: sponsors,
            cosponsors: [],
            title: title
        )
    }

    func testBillsOfDifferentTypesWithTheSameNumberAreNotMerged() {
        let items = [
            item("BILLS-119hr4500ih", type: "hr", number: "4500"),
            item("BILLS-119s4500is", type: "s", number: "4500"),
            item("BILLS-119hres4500ih", type: "house-resolution", number: "4500"),
            item("BILLS-119sjres4500is", type: "senate-joint-resolution", number: "4500")
        ]

        let deduplicated = BillsStore.deduplicateManifest(items)

        XCTAssertEqual(Set(deduplicated.map(\.guid)), Set(items.map(\.guid)))
    }

    func testSuffixedAndUnsuffixedGuidsOfOneBillMergeKeepingTheUnsuffixedGuid() throws {
        // The suffixed item comes first and uses the Congress.gov slug, as live legacy items do.
        let items = [
            item("BILLS-119hr6512ih", type: "house-bill", number: "6512", sponsors: ["B000002"], updatedAt: "2026-09-21T00:00:00.000Z"),
            item("BILLS-119hr6512", type: "hr", number: "6512", title: "Current title", sponsors: ["A000001"]),
            item("BILLS-119s77is", type: "senate-bill", number: "77"),
            item("BILLS-119s77", type: "s", number: "077"),
            item("BILLS-119s77rs", type: "S", number: "77")
        ]

        let deduplicated = BillsStore.deduplicateManifest(items)

        XCTAssertEqual(deduplicated.map(\.guid), ["BILLS-119hr6512", "BILLS-119s77"])
        let hr6512 = try XCTUnwrap(deduplicated.first)
        XCTAssertEqual(hr6512.title, "Current title")
        XCTAssertEqual(hr6512.sponsors, ["A000001", "B000002"], "the text-version duplicate's sponsors are kept")
        XCTAssertEqual(hr6512.updatedAt, "2026-09-21T00:00:00.000Z", "the newest update wins")
    }

    func testIdenticalTitlesDoNotMergeDistinctBills() {
        let items = [
            item("BILLS-119hr10", type: "hr", number: "10", title: "Protecting Veterans Act"),
            item("BILLS-119s10", type: "s", number: "10", title: "Protecting Veterans Act"),
            item("BILLS-119hr11", type: "hr", number: "11", title: "  protecting veterans act "),
            item("BILLS-119hres12", type: nil, number: nil, title: "Protecting Veterans Act")
        ]

        let deduplicated = BillsStore.deduplicateManifest(items)

        XCTAssertEqual(deduplicated.count, 4)
        XCTAssertEqual(Set(deduplicated.map(\.guid)), Set(items.map(\.guid)))
    }

    func testItemsInDifferentCongressesAreNotMerged() {
        let items = [
            item("BILLS-118hr1", congress: "118", type: "hr", number: "1"),
            item("BILLS-119hr1", congress: "119", type: "hr", number: "1")
        ]

        XCTAssertEqual(BillsStore.deduplicateManifest(items).count, 2)
    }

    func testItemMissingItsCongressOrNumberMergesWithItsTwinThroughTheGuid() throws {
        let items = [
            item("BILLS-119hr6512ih", congress: nil, type: "hr", number: " ", sponsors: ["B000002"]),
            item("BILLS-119hr6512", type: "house-bill", number: "6512", sponsors: ["A000001"]),
            item("BILLS-119s77", congress: "", type: nil, number: nil),
            item("BILLS-119s77is", type: "s", number: "77"),
            // Not a GovInfo bill guid: nothing to derive, so it passes through.
            item("custom-guid", congress: nil, type: nil, number: nil)
        ]

        let deduplicated = BillsStore.deduplicateManifest(items)

        XCTAssertEqual(deduplicated.map(\.guid), ["custom-guid", "BILLS-119hr6512", "BILLS-119s77"])
        XCTAssertEqual(deduplicated[1].sponsors, ["A000001", "B000002"])
        let s77 = deduplicated[2]
        XCTAssertEqual([s77.congress, s77.billType, s77.billID], ["119", "s", "77"], "the kept guid takes the fields it lacked from its twin")
        XCTAssertEqual(
            BillsStore.billIdentityKey(congress: nil, billType: nil, billID: nil, guid: "BILLS-119hjres131eh"),
            BillsStore.billIdentityKey(congress: "119", billType: "house-joint-resolution", billID: "131")
        )
        XCTAssertNil(BillsStore.billIdentityKey(congress: nil, billType: "hr", billID: "1", guid: "custom-guid"))
    }

    func testNormalizedBillType() {
        XCTAssertEqual(BillsStore.normalizedBillType("house-bill"), "hr")
        XCTAssertEqual(BillsStore.normalizedBillType(" HR "), "hr")
        XCTAssertEqual(BillsStore.normalizedBillType("H.R."), "hr")
        XCTAssertEqual(BillsStore.normalizedBillType("S.J.Res."), "sjres")
        XCTAssertEqual(BillsStore.normalizedBillType("senate-concurrent-resolution"), "sconres")
        XCTAssertEqual(BillsStore.normalizedBillType("house-joint-resolution"), "hjres")
        XCTAssertNil(BillsStore.normalizedBillType("  "))
        XCTAssertNil(BillsStore.normalizedBillType(nil))
        XCTAssertNotEqual(
            BillsStore.billIdentityKey(congress: "119", billType: "hr", billID: "4500"),
            BillsStore.billIdentityKey(congress: "119", billType: "s", billID: "4500")
        )
        XCTAssertEqual(
            BillsStore.billIdentityKey(congress: "119", billType: "house-bill", billID: "04500"),
            BillsStore.billIdentityKey(congress: "119", billType: "hr", billID: "4500")
        )
    }

    @MainActor
    func testLoadShowsBillsThatShareANumberAcrossTypes() async {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let service = FakeBillsService()
        service.manifestResults = [.success([
            item("BILLS-119hr4500", type: "hr", number: "4500", title: "House bill", updatedAt: recent),
            item("BILLS-119s4500", type: "s", number: "4500", title: "Senate bill", updatedAt: recent),
            item("BILLS-119s4500is", type: "senate-bill", number: "4500", title: "Senate bill (legacy)", updatedAt: recent)
        ])]
        let scope = "bills-store-manifest-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())

        await store.load(historyWindow: .oneWeek)

        XCTAssertEqual(Set(store.manifestItems.map(\.guid)), ["BILLS-119hr4500", "BILLS-119s4500"])
        XCTAssertEqual(Set(store.activeManifestBills.map(\.title)), ["House bill", "Senate bill"])
        // Let the store's detached bills-cache write finish before the teardown clears the scope.
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        let timestampKey = ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope)
        for _ in 0..<500 where UserDefaults.standard.object(forKey: timestampKey) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }

    // MARK: - Renamed topics (LLM-10)

    func testTextVersionDuplicatesUnderTheOldAndNewLabelMergeIntoOneTopic() throws {
        let items = [
            item("BILLS-119hr6512ih", type: "house-bill", number: "6512", subCategories: ["Social Justice", "Housing"]),
            item("BILLS-119hr6512", type: "hr", number: "6512", subCategories: ["Civil Rights and Liberties"])
        ]

        let merged = try XCTUnwrap(BillsStore.deduplicateManifest(items).first)

        XCTAssertEqual(merged.guid, "BILLS-119hr6512")
        XCTAssertEqual(merged.subCategories, ["Civil Rights and Liberties", "Housing"])
    }

    func testAManifestWithLegacyLabelsEqualsItsRelabelledCopy() {
        // What the relabel script (C2 3.8.3) does to the stored bills: the manifest that follows must not
        // read as a change.
        let legacy = [
            item("BILLS-119hr1", type: "hr", number: "1", subCategories: ["Identity Politics", "Ethics in Policy"]),
            item("BILLS-119hr2", type: "hr", number: "2", subCategories: ["Housing", "Social Justice"])
        ]
        let relabelled = [
            item("BILLS-119hr1", type: "hr", number: "1", subCategories: ["Heritage and Identity", "Ethics in Policy"]),
            item("BILLS-119hr2", type: "hr", number: "2", subCategories: ["Housing", "Civil Rights and Liberties"])
        ]

        XCTAssertTrue(BillsStore.manifestsAreEquivalent(
            BillsStore.deduplicateManifest(legacy),
            BillsStore.deduplicateManifest(relabelled)
        ))
    }

    func testPlaceholderTopicGroupAgreesWithTheTopicGroupsForEveryNameOldAndNew() {
        let names = SubscriptionsConfig.allSubcategories + Array(SubscriptionsConfig.legacyTopicAliases.keys)
        for name in names {
            let canonical = SubscriptionsConfig.canonicalTopic(name)
            let expectedGroup = SubscriptionsConfig.subcategoryGroups.first { $0.value.contains(canonical) }?.key

            let placeholder = BillsStore.placeholderBill(from: item("BILLS-119hr5", type: "hr", number: "5", subCategories: [name]))

            XCTAssertEqual(placeholder.subCategory, canonical, name)
            XCTAssertEqual(placeholder.category, expectedGroup, name)
        }
    }

    func testPlaceholderOfAnUnknownLabelKeepsItAsItsGroup() {
        let placeholder = BillsStore.placeholderBill(from: item("BILLS-119hr6", type: "hr", number: "6", subCategories: ["Crime"]))

        XCTAssertEqual(placeholder.subCategory, "Crime")
        XCTAssertEqual(placeholder.category, "Crime")
    }

    @MainActor
    func testLoadKeepsOnlyTheNewTopicNames() async {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let service = FakeBillsService()
        service.manifestResults = [.success([
            item("BILLS-119hr700", type: "hr", number: "700", subCategories: ["Social Justice"], updatedAt: recent),
            item("BILLS-119s701", type: "s", number: "701", subCategories: ["Identity Politics", "Heritage and Identity"], updatedAt: recent)
        ])]
        let scope = "bills-store-manifest-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())

        await store.load(historyWindow: .oneWeek)

        XCTAssertEqual(Set(store.manifestItems.flatMap(\.subCategories)), ["Civil Rights and Liberties", "Heritage and Identity"])
        XCTAssertEqual(Set(store.activeManifestBills.compactMap(\.subCategory)), ["Civil Rights and Liberties", "Heritage and Identity"])
        XCTAssertEqual(
            Set(store.activeManifestBills.map(\.category)),
            [SubscriptionsConfig.categorySocialPolicy, SubscriptionsConfig.categoryCulturalAndEthicalIssues]
        )
        // Let the store's detached bills-cache write finish before the teardown clears the scope.
        await BillsStore.latestBillsCacheWrite(scope: scope)?.value
        let timestampKey = ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope)
        for _ in 0..<500 where UserDefaults.standard.object(forKey: timestampKey) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }

    // MARK: - Companion groups (APPF-23)

    private let group = BillCompanionGroup(
        primaryGuid: "BILLS-119hr900",
        memberGuids: ["BILLS-119hr900", "BILLS-119s456"],
        relationship: "identical"
    )

    func testCompanionBillsAreNotMergedByDeduplication() {
        let items = [
            item("BILLS-119hr900", type: "hr", number: "900", title: "Same title"),
            item("BILLS-119s456", type: "s", number: "456", title: "Same title")
        ]

        XCTAssertEqual(BillsStore.deduplicateManifest(items).map(\.guid), ["BILLS-119hr900", "BILLS-119s456"])
    }

    func testManifestsWithDifferentGroupsAreNotEquivalent() {
        let items = [item("BILLS-119hr900", type: "hr", number: "900")]
        let grouped = CompanionGroupIndex(groups: [group])

        XCTAssertTrue(BillsStore.manifestsAreEquivalent(items, items))
        XCTAssertTrue(BillsStore.manifestsAreEquivalent(items, items, lhsGroups: grouped, rhsGroups: grouped))
        XCTAssertFalse(BillsStore.manifestsAreEquivalent(items, items, lhsGroups: grouped, rhsGroups: .empty))
    }

    func testVisibleEntriesAddThePartnersOfVisibleGroupedBills() {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let entries = BillsStore.preparedManifestEntries(from: [
            item("BILLS-119s456", type: "s", number: "456", updatedAt: recent),
            item("BILLS-119hr900", type: "hr", number: "900", updatedAt: "2025-01-01T00:00:00.000Z"),
            item("BILLS-119hr1", type: "hr", number: "1", updatedAt: "2025-01-01T00:00:00.000Z")
        ])

        let grouped = BillsStore.visibleManifestEntries(from: entries, historyWindow: .oneWeek, companions: CompanionGroupIndex(groups: [group]))
        let plain = BillsStore.visibleManifestEntries(from: entries, historyWindow: .oneWeek)

        XCTAssertEqual(grouped.map(\.item.guid), ["BILLS-119s456", "BILLS-119hr900"])
        XCTAssertEqual(plain.map(\.item.guid), ["BILLS-119s456"])
    }

    @MainActor
    func testLoadBuildsTheIndexAndThePrimarysPlaceholderWhenOnlyThePartnerMoved() async {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let service = FakeBillsService()
        service.manifestResults = [.success([
            item("BILLS-119s456", type: "s", number: "456", title: "Senate bill", updatedAt: recent),
            item("BILLS-119hr900", type: "hr", number: "900", title: "House bill", updatedAt: "2025-01-01T00:00:00.000Z")
        ])]
        service.cachedGroups = [group]
        let scope = "bills-store-manifest-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())

        let timestampKey = ScopedStorageKey.make(base: "BillsStore.bills.timestamp", scope: scope)
        func waitForBillsCacheWrite() async {
            await BillsStore.latestBillsCacheWrite(scope: scope)?.value
            for _ in 0..<500 where UserDefaults.standard.object(forKey: timestampKey) == nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            UserDefaults.standard.removeObject(forKey: timestampKey)
        }

        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite()

        XCTAssertEqual(store.companionGroupIndex.groups, [group])
        XCTAssertEqual(Set(store.activeManifestBills.compactMap(\.guid)), ["BILLS-119s456", "BILLS-119hr900"])
        XCTAssertEqual(store.bill(forGUID: "BILLS-119hr900")?.title, "House bill")
        XCTAssertEqual(store.deepLinkBillID(forGUID: "BILLS-119s456"), UUID.deterministic(from: "BILLS-119hr900"))

        // The same items with the groups gone: the change is applied, and the store falls back to one
        // bill per card (the out-of-window House bill leaves the active bills).
        service.cachedGroups = []
        await store.load(forceRefresh: true, historyWindow: .oneWeek)

        XCTAssertTrue(store.companionGroupIndex.isEmpty)
        XCTAssertEqual(store.activeManifestBills.compactMap(\.guid), ["BILLS-119s456"])
        await waitForBillsCacheWrite()
    }
}
