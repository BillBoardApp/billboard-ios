import XCTest
@testable import Billboard

/// LLM-10 (decision 1B): "Social Justice" became "Civil Rights and Liberties" and "Identity Politics" became
/// "Heritage and Identity". The backend accepts and may still return the old names, so the app reads both and
/// keeps only the new ones in memory: processed bills, the manifest, the disk caches, pushes and stored
/// follows are canonicalized on the way in, and the topic picker offers (so writes send) only current names
/// (spec D 2.6).
@MainActor
final class LabelAliasTests: XCTestCase {
    private let socialJustice = "Social Justice"
    private let identityPolitics = "Identity Politics"
    private let civilRights = "Civil Rights and Liberties"
    private let heritage = "Heritage and Identity"

    // MARK: - Alias table

    func testAliasTableMirrorsThePlatformAliases() {
        // billboard-backend services/src/models/categories.ts LEGACY_SUB_CATEGORY_ALIASES.
        XCTAssertEqual(SubscriptionsConfig.legacyTopicAliases, [
            "Social Justice": "Civil Rights and Liberties",
            "Identity Politics": "Heritage and Identity"
        ])
        XCTAssertEqual(SubscriptionsConfig.subCivilRightsAndLiberties, civilRights)
        XCTAssertEqual(SubscriptionsConfig.subHeritageAndIdentity, heritage)
        XCTAssertEqual(SubscriptionsConfig.legacyTopicSocialJustice, socialJustice)
        XCTAssertEqual(SubscriptionsConfig.legacyTopicIdentityPolitics, identityPolitics)
    }

    func testEveryAliasTargetIsACurrentTopicAndNoLegacyNameIsCurrent() {
        let current = Set(SubscriptionsConfig.allSubcategories)
        for (legacy, target) in SubscriptionsConfig.legacyTopicAliases {
            XCTAssertTrue(current.contains(target), target)
            XCTAssertFalse(current.contains(legacy), legacy)
            XCTAssertFalse(SubscriptionsConfig.isLegacyTopic(target), target)
        }
    }

    func testRenamedTopicsKeepTheirTopicGroup() {
        XCTAssertEqual(parentGroup(of: civilRights), SubscriptionsConfig.categorySocialPolicy)
        XCTAssertEqual(parentGroup(of: heritage), SubscriptionsConfig.categoryCulturalAndEthicalIssues)
        XCTAssertEqual(
            SubscriptionsConfig.subcategoriesSocial.firstIndex(of: civilRights),
            3,
            "the new name takes the old name's place in its group"
        )
        XCTAssertEqual(SubscriptionsConfig.subcategoriesCultural.firstIndex(of: heritage), 1)
    }

    // MARK: - Taxonomy

    func testTopicGroupsMirrorThePlatformTaxonomy() {
        // billboard-backend services/src/models/categories.ts BILL_CATEGORY_DEFINITIONS.
        let platform: [(group: String, topics: [String])] = [
            ("Economic Policy", ["Fiscal Policy", "Monetary Policy", "Labor and Employment", "Trade and Globalization", "Social Welfare"]),
            ("Social Policy", ["Healthcare", "Education", "Housing", "Civil Rights and Liberties", "Family and Gender Policy"]),
            ("Environmental and Energy Policy", ["Climate Change", "Energy", "Conservation and Natural Resources", "Pollution Control"]),
            ("Foreign Policy and Defense", ["Diplomacy", "Military and Defense", "Trade and Sanctions", "Immigration and Border Control", "Humanitarian Intervention"]),
            ("Governance and Institutional Policy", ["Constitutional and Legal Issues", "Elections and Voting", "Transparency and Accountability", "Local vs. Federal Power"]),
            ("Science, Technology, and Infrastructure", ["Technology Regulation", "Transportation", "Research and Innovation", "Telecommunications"]),
            ("Cultural and Ethical Issues", ["Religion and State", "Heritage and Identity", "Freedom of Speech and Press", "Ethics in Policy"])
        ]

        XCTAssertEqual(Set(SubscriptionsConfig.subcategoryGroups.keys), Set(platform.map { $0.group }))
        for (group, topics) in platform {
            XCTAssertEqual(SubscriptionsConfig.subcategoryGroups[group], topics, group)
        }
        XCTAssertEqual(SubscriptionsConfig.allSubcategories, platform.flatMap { $0.topics })
        XCTAssertEqual(SubscriptionsConfig.allSubcategories.count, 31)
    }

    func testPickerListsOfferNoLegacyName() {
        let offered = SubscriptionsConfig.allSubcategories + SubscriptionsConfig.subcategoryGroups.values.flatMap { $0 }
        XCTAssertFalse(offered.contains(where: SubscriptionsConfig.isLegacyTopic))
        XCTAssertFalse(offered.contains(socialJustice))
        XCTAssertFalse(offered.contains(identityPolitics))
    }

    // MARK: - canonicalTopic

    func testLegacyNamesMapToTheirNewNames() {
        XCTAssertEqual(SubscriptionsConfig.canonicalTopic(socialJustice), civilRights)
        XCTAssertEqual(SubscriptionsConfig.canonicalTopic(identityPolitics), heritage)
        XCTAssertTrue(SubscriptionsConfig.isLegacyTopic(socialJustice))
        XCTAssertTrue(SubscriptionsConfig.isLegacyTopic(identityPolitics))
    }

    func testLegacyNamesMatchTrimmedAndIgnoringCase() {
        XCTAssertEqual(SubscriptionsConfig.canonicalTopic("  Social Justice \n"), civilRights)
        XCTAssertEqual(SubscriptionsConfig.canonicalTopic("social justice"), civilRights)
        XCTAssertEqual(SubscriptionsConfig.canonicalTopic("IDENTITY POLITICS"), heritage)
        XCTAssertTrue(SubscriptionsConfig.isLegacyTopic(" identity politics"))
    }

    func testEveryOtherValueIsReturnedUnchanged() {
        let values = SubscriptionsConfig.allSubcategories
            + SubscriptionsConfig.allCategories
            + SubscriptionsConfig.allLifeAreas
            + ["", "   ", "Other", "Priority Bill", "Bill Alert", "Social", "Justice", "Social Justice Reform", " Energy "]
        for value in values {
            XCTAssertEqual(SubscriptionsConfig.canonicalTopic(value), value, value)
            XCTAssertFalse(SubscriptionsConfig.isLegacyTopic(value), value)
        }
    }

    func testCanonicalTopicsMapsInOrderAndDropsTheDuplicatesItCreates() {
        XCTAssertEqual(
            SubscriptionsConfig.canonicalTopics([socialJustice, "Housing", civilRights, identityPolitics, heritage, "Housing"]),
            [civilRights, "Housing", heritage]
        )
        XCTAssertEqual(SubscriptionsConfig.canonicalTopics(["Energy", "Climate Change"]), ["Energy", "Climate Change"])
        XCTAssertEqual(SubscriptionsConfig.canonicalTopics([]), [])
    }

    // MARK: - Processed bills (GET /processed-bill)

    func testProcessedBillWithALegacyLabelIsReadUnderTheNewName() throws {
        let bill = try BillsService.decodeProcessedBill(from: processedBillPayload(subCategories: [socialJustice, "Housing"]))

        XCTAssertEqual(bill.subCategory, civilRights)
        XCTAssertEqual(bill.category, SubscriptionsConfig.categorySocialPolicy)
    }

    func testProcessedBillWithTheOtherLegacyLabelKeepsItsGroup() throws {
        let bill = try BillsService.decodeProcessedBill(from: processedBillPayload(subCategories: [identityPolitics]))

        XCTAssertEqual(bill.subCategory, heritage)
        XCTAssertEqual(bill.category, SubscriptionsConfig.categoryCulturalAndEthicalIssues)
    }

    func testProcessedBillWithTheNewLabelIsUnchanged() throws {
        let bill = try BillsService.decodeProcessedBill(from: processedBillPayload(subCategories: [heritage, "Ethics in Policy"]))

        XCTAssertEqual(bill.subCategory, heritage)
        XCTAssertEqual(bill.category, SubscriptionsConfig.categoryCulturalAndEthicalIssues)
    }

    func testProcessedBillWithBothNamesHasOneTopic() throws {
        let bill = try BillsService.decodeProcessedBill(from: processedBillPayload(subCategories: [socialJustice, civilRights]))

        XCTAssertEqual(bill.subCategory, civilRights)
        XCTAssertEqual(bill.category, SubscriptionsConfig.categorySocialPolicy)
    }

    // MARK: - Manifest

    func testManifestItemsAndPlaceholdersCarryTheNewNames() throws {
        let items = [
            manifestItem("BILLS-119hr10", subCategories: [identityPolitics]),
            manifestItem("BILLS-119hr11", subCategories: ["Housing", socialJustice, civilRights])
        ]

        let deduplicated = BillsStore.deduplicateManifest(items)

        XCTAssertEqual(deduplicated.map(\.subCategories), [[heritage], [civilRights, "Housing"]])
        let placeholders = BillsStore.preparedManifestEntries(from: deduplicated).map(\.placeholderBill)
        XCTAssertEqual(placeholders.map(\.subCategory), [heritage, civilRights])
        XCTAssertEqual(placeholders.map(\.category), [
            SubscriptionsConfig.categoryCulturalAndEthicalIssues,
            SubscriptionsConfig.categorySocialPolicy
        ])
    }

    // MARK: - Disk caches

    func testBillsRestoredFromTheDiskCacheCarryTheNewNames() throws {
        let scope = "label-alias-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let legacy = bill(guid: "BILLS-119hr20", category: SubscriptionsConfig.categorySocialPolicy, subCategory: socialJustice)
        let current = bill(guid: "BILLS-119hr21", category: SubscriptionsConfig.categoryEconomicPolicy, subCategory: "Fiscal Policy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertTrue(DiskJSONCache.store(
            try encoder.encode([legacy, current]),
            forKey: ScopedStorageKey.make(base: "BillsStore.bills.data", scope: scope)
        ))

        let restored = try XCTUnwrap(BillsStore.cachedBills(scope: scope))

        XCTAssertEqual(restored.map(\.subCategory), [civilRights, "Fiscal Policy"])
        XCTAssertEqual(restored.map(\.category), [SubscriptionsConfig.categorySocialPolicy, SubscriptionsConfig.categoryEconomicPolicy])
        XCTAssertEqual(restored.map(\.id), [legacy.id, current.id])
    }

    func testCacheRestoreSnapshotCanonicalizesCachedManifestAndBills() {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60))
        let cachedBill = bill(guid: "BILLS-119hr30", category: SubscriptionsConfig.categoryCulturalAndEthicalIssues, subCategory: identityPolitics)

        let snapshot = BillsStore.cacheRestoreSnapshot(
            cachedManifest: [manifestItem("BILLS-119hr31", subCategories: [socialJustice], updatedAt: recent)],
            cachedBills: [cachedBill],
            historyWindow: .oneWeek
        )

        XCTAssertEqual(snapshot.deduplicatedManifest.map(\.subCategories), [[civilRights]])
        XCTAssertEqual(snapshot.normalizedCachedBills.map(\.subCategory), [heritage])
        let restored = snapshot.restoredBills ?? []
        XCTAssertFalse(restored.isEmpty)
        XCTAssertFalse(restored.contains { bill in
            [bill.subCategory, bill.category].compactMap { $0 }.contains(where: SubscriptionsConfig.isLegacyTopic)
        })
    }

    func testAlertsLoadedFromTheCacheCarryTheNewNames() throws {
        let scope = "label-alias-tests-\(UUID().uuidString)"
        addTeardownBlock { BillAlertsStore.clearCache(scope: scope) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(
            try encoder.encode([alert(subCategory: socialJustice, category: SubscriptionsConfig.categorySocialPolicy)]),
            forKey: ScopedStorageKey.make(base: "BillAlertsStore.alerts.data", scope: scope)
        )

        let store = BillAlertsStore(scope: scope)

        XCTAssertEqual(store.alerts.map(\.subCategory), [civilRights])
        XCTAssertEqual(store.alerts.map(\.category), [SubscriptionsConfig.categorySocialPolicy])
    }

    func testIngestedAndInjectedAlertsCarryTheNewNames() {
        let scope = "label-alias-tests-\(UUID().uuidString)"
        addTeardownBlock { BillAlertsStore.clearCache(scope: scope) }
        let store = BillAlertsStore(scope: scope, alerts: [alert(subCategory: identityPolitics)])

        store.ingest(alert(subCategory: socialJustice, category: socialJustice))

        XCTAssertEqual(Set(store.alerts.compactMap(\.subCategory)), [heritage, civilRights])
        XCTAssertFalse(store.alerts.contains { SubscriptionsConfig.isLegacyTopic($0.category) })
    }

    func testBillAlertWithoutALegacyNameIsReturnedAsIs() {
        let current = alert(subCategory: "Energy", category: "Bill Alert")
        XCTAssertEqual(current.canonicalizingTopics(), current)

        let noTopic = alert(subCategory: nil)
        XCTAssertEqual(noTopic.canonicalizingTopics(), noTopic)
    }

    // MARK: - Follows

    func testStoredFollowsUnderEitherNameBecomeOneNewName() {
        let summary = PreferencesInterpreter.summarize([
            PreferencesItem(subCategory: nil, preference: socialJustice, category: SubscriptionsConfig.categorySocialPolicy, type: "Category"),
            PreferencesItem(subCategory: nil, preference: civilRights, category: SubscriptionsConfig.categorySocialPolicy, type: "Category"),
            PreferencesItem(subCategory: identityPolitics, preference: nil, category: nil, type: nil),
            PreferencesItem(subCategory: nil, preference: "Energy", category: nil, type: "Category")
        ])

        XCTAssertEqual(summary.subscribedSubCategories, [civilRights, "Energy", heritage])
    }

    func testCachedProfileFollowsAreCanonicalized() {
        let cached = profile(topics: ["Energy", socialJustice, civilRights, identityPolitics])

        let canonical = cached.canonicalizingTopics()

        XCTAssertEqual(canonical.subscribedSubCategories, [civilRights, "Energy", heritage])
        XCTAssertEqual(canonical.id, cached.id)
        XCTAssertEqual(canonical.subscribedLifeAreas, cached.subscribedLifeAreas)

        let current = profile(topics: ["Energy", heritage])
        XCTAssertEqual(current.canonicalizingTopics(), current, "a profile without legacy names is unchanged")
    }

    func testABillCachedUnderTheOldNameMatchesAFollowOfTheNewName() {
        let follower = profile(topics: [civilRights])
        let cached = bill(guid: "BILLS-119hr40", category: SubscriptionsConfig.categorySocialPolicy, subCategory: socialJustice)

        XCTAssertFalse(cached.matchesSubscribedInterests(follower), "without canonicalization the old label misses")
        XCTAssertTrue(cached.canonicalizingTopics().matchesSubscribedInterests(follower))

        let legacyFollower = profile(topics: [identityPolitics]).canonicalizingTopics()
        let current = bill(guid: "BILLS-119hr41", category: SubscriptionsConfig.categoryCulturalAndEthicalIssues, subCategory: heritage)
        XCTAssertTrue(current.matchesSubscribedInterests(legacyFollower))
    }

    // MARK: - Writes

    func testPickerWritesNeverContainALegacyName() {
        let items = PreferencesMutations.categoryItems(for: SubscriptionsConfig.allSubcategories)

        XCTAssertEqual(items.count, SubscriptionsConfig.allSubcategories.count)
        XCTAssertFalse(items.contains { SubscriptionsConfig.isLegacyTopic($0.value) })
        XCTAssertFalse(items.contains { $0.category == nil }, "every offered topic has its group")
    }

    func testALegacySelectionIsWrittenUnderItsNewNameAndGroup() {
        let items = PreferencesMutations.categoryItems(for: SubscriptionsConfig.canonicalTopics([socialJustice, identityPolitics]))

        XCTAssertEqual(items, [
            PreferencesItem(subCategory: nil, preference: civilRights, category: SubscriptionsConfig.categorySocialPolicy, type: "Category"),
            PreferencesItem(subCategory: nil, preference: heritage, category: SubscriptionsConfig.categoryCulturalAndEthicalIssues, type: "Category")
        ])
    }

    // MARK: - Helpers

    private func parentGroup(of topic: String) -> String? {
        SubscriptionsConfig.subcategoryGroups.first { $0.value.contains(topic) }?.key
    }

    /// A minimal `GET /processed-bill` body the contract accepts.
    private func processedBillPayload(subCategories: [String]) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "kind": "processed",
            "storedAt": "2026-10-01T12:00:00.000Z",
            "identifier": ["congress": "119", "billType": "hr", "billNumber": "77"],
            "guid": "BILLS-119hr77ih",
            "title": "A bill",
            "link": "https://www.congress.gov/bill/119th-congress/house-bill/77",
            "soWhat": "So what.",
            "billBreakdown": ["who": "Who", "what": "What", "how": "How", "when": "When", "where": "Where"],
            "subCategories": subCategories,
            "lifeAreas": [String](),
            "sponsors": ["A000001"],
            "cosponsors": [String]()
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func manifestItem(
        _ guid: String,
        subCategories: [String],
        updatedAt: String = "2026-09-20T11:00:00.000Z"
    ) -> BillsManifestItem {
        let locator = BillsService.deriveLocator(from: guid)
        return BillsManifestItem(
            guid: guid,
            congress: locator?.congress,
            billType: locator?.billType,
            billID: locator?.billID,
            updatedAt: updatedAt,
            subCategories: subCategories,
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            title: "A bill"
        )
    }

    private func bill(guid: String, category: String, subCategory: String?) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: "A bill",
            category: category,
            subCategory: subCategory,
            soWhat: "",
            storedAt: "2026-09-20T11:00:00.000Z",
            billStatus: .new,
            guid: guid,
            userVoted: false
        )
    }

    private func alert(subCategory: String?, category: String = "Bill Alert") -> BillAlert {
        BillAlert(
            id: UUID(),
            sponsorMemberID: nil,
            billID: UUID.deterministic(from: "BILLS-119hr50"),
            title: "Action in Congress",
            category: category,
            summary: "",
            soWhat: "",
            lifeAreas: ["Taxes"],
            subCategory: subCategory,
            alertText: "Passed House",
            actionDate: "2026-10-01",
            actionCode: "8000",
            actionType: "Floor",
            date: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private func profile(topics: [String]) -> UserProfile {
        UserProfile(
            id: "user-1",
            email: "hello@example.com",
            district: "11",
            state: "VA",
            avatarName: nil,
            subscribedSubCategories: topics,
            subscribedLifeAreas: ["Taxes"],
            subscribedMemberIDs: [],
            watchedBillGUIDs: [],
            selectedBillContentTypes: []
        )
    }
}
