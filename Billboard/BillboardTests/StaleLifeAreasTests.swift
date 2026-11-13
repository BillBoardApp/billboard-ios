import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// UX-29 (project decision 2026-10-28): a bill's life areas follow the server. A bills-manifest row and a
/// /processed-bill response hold the bill's current life areas, so theirs replace the ones the device
/// holds, even none: since 2026-10-29 the server gives ceremonial resolutions none (H.Res. 1187,
/// Community Health Workers Week, was tagged "Medical Costs" on devices that held the old row), and a reprocess can change
/// a bill's. A copy that may not carry them (a screen's copy of a stored bill, a stub, the device's own
/// bills cache read back at launch) keeps the ones the device holds, so it never strips a tag. Until this
/// change every merge took the union, so a life area the server removed never left a device that held it.
@MainActor
final class StaleLifeAreasTests: XCTestCase {
    private static let guid = "BILLS-119hres1187"
    private static let title = "Recognize Community Health Workers Week"
    private static let medicalCosts = SubscriptionsConfig.lifeMedicalCosts
    /// The row's date, which relabelling it does not move (the server keeps a ceremonial row's date).
    private static let storedAt = iso(daysAgo: 2)

    private static func iso(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    /// The bill as a device holds it: tagged Medical Costs, and hydrated unless `hydrated` says otherwise.
    private static func heldBill(
        lifeAreas: [String]? = nil,
        hydrated: Bool? = true,
        userVoted: Bool = false
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: SubscriptionsConfig.categorySocialPolicy,
            subCategory: "Healthcare",
            summary: hydrated == true ? "Supports the designation of Community Health Workers Week." : "",
            soWhat: hydrated == true ? "It changes no law." : "",
            storedAt: storedAt,
            link: hydrated == true ? "https://www.congress.gov/bill/119th-congress/house-resolution/1187" : nil,
            lifeAreas: lifeAreas ?? [medicalCosts],
            billStatus: .new,
            guid: guid,
            congress: "119",
            billType: "hres",
            billID: "1187",
            userVoted: userVoted,
            isProcessedDetailHydrated: hydrated
        )
    }

    /// GET /processed-bill's answer for the bill: the whole document, hydrated.
    private static func processedBill(lifeAreas: [String]) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: SubscriptionsConfig.categorySocialPolicy,
            subCategory: "Healthcare",
            summary: "Supports the designation of Community Health Workers Week.",
            soWhat: "It changes no law.",
            storedAt: storedAt,
            link: "https://www.congress.gov/bill/119th-congress/house-resolution/1187",
            lifeAreas: lifeAreas,
            billStatus: .new,
            guid: guid,
            userVoted: false,
            isProcessedDetailHydrated: true
        )
    }

    private static func manifestRow(lifeAreas: [String], updatedAt: String? = nil) -> BillsManifestItem {
        BillsManifestItem(
            guid: guid,
            congress: "119",
            billType: "hres",
            billID: "1187",
            updatedAt: updatedAt ?? storedAt,
            subCategories: ["Healthcare"],
            lifeAreas: lifeAreas,
            sponsors: [],
            cosponsors: [],
            title: title,
            billStatus: "New"
        )
    }

    private static func merged(_ incoming: Bill, into existing: Bill, source: BillsStore.IncomingBillSource) -> Bill {
        BillsStore.mergedBillPreservingExistingContext(incoming: incoming, existing: existing, source: source)
    }

    /// A reader who follows the Medical Costs life area and the Healthcare topic.
    private static let reader = UserProfile(
        id: "user-1", email: "reader@example.com", district: "", state: "", avatarName: nil,
        subscribedSubCategories: ["Healthcare"], subscribedLifeAreas: [medicalCosts],
        subscribedMemberIDs: [], watchedBillGUIDs: [], selectedBillContentTypes: []
    )

    // MARK: - The merge

    func testAManifestRowWithNoLifeAreasClearsTheHeldOnes() {
        let row = Self.manifestRow(lifeAreas: [])
        let placeholder = BillsStore.placeholderBill(from: row)

        XCTAssertEqual(Self.merged(placeholder, into: Self.heldBill(), source: .manifestRow).lifeAreas, [])
        XCTAssertEqual(Self.merged(placeholder, into: Self.heldBill(hydrated: false), source: .manifestRow).lifeAreas, [])

        // The manifest paths pass `.manifestRow` themselves.
        let entries = BillsStore.preparedManifestEntries(from: [row])
        let held = [Self.heldBill()]
        let resolved = BillsStore.resolveManifestBills(
            manifestEntries: entries,
            billsByGuid: BillsStore.makeBillLookupByGuid(from: held),
            billsByID: BillsStore.makeBillLookupByID(from: held)
        )
        XCTAssertEqual(resolved.map(\.lifeAreas), [[]])
        let update = BillsStore.manifestUpdate(for: [row], replacing: [], existingBills: held, historyWindow: .oneWeek)
        XCTAssertEqual(update.changes?.mergedBills.map(\.lifeAreas), [[]])
        XCTAssertEqual(update.changes?.resolvedActiveManifestBills.map(\.lifeAreas), [[]])
    }

    func testAProcessedBillWithNoLifeAreasClearsTheHeldOnes() {
        let processed = Self.processedBill(lifeAreas: [])

        XCTAssertEqual(Self.merged(processed, into: Self.heldBill(), source: .loadedBill).lifeAreas, [])
        XCTAssertEqual(Self.merged(processed, into: Self.heldBill(hydrated: false), source: .loadedBill).lifeAreas, [])
        XCTAssertEqual(
            BillsStore.mergedBillPreservingExistingContext(incoming: processed, existing: Self.heldBill()).lifeAreas,
            [],
            "a loaded bill is the default source"
        )
    }

    func testAPartialCopyWithNoLifeAreasKeepsTheHeldOnes() {
        // A copy that is not a processed bill: a screen's copy or a stub (no hydration flag, or false).
        for flag in [nil, false] as [Bool?] {
            var copy = Self.processedBill(lifeAreas: [])
            copy.isProcessedDetailHydrated = flag
            XCTAssertEqual(Self.merged(copy, into: Self.heldBill(), source: .loadedBill).lifeAreas, [Self.medicalCosts], "\(String(describing: flag))")
        }

        // The bills cache read back at launch, merged into a bill loaded since: never replaces, even a
        // cached processed bill.
        XCTAssertEqual(
            Self.merged(Self.heldBill(), into: Self.processedBill(lifeAreas: []), source: .cachedBill).lifeAreas,
            [],
            "the bill loaded since keeps none"
        )
        XCTAssertEqual(
            Self.merged(Self.processedBill(lifeAreas: []), into: Self.heldBill(), source: .cachedBill).lifeAreas,
            [Self.medicalCosts]
        )
    }

    func testARowOrProcessedBillThatDropsOneLifeAreaDropsIt() {
        let held = Self.heldBill(lifeAreas: ["Housing", Self.medicalCosts])
        let row = BillsStore.placeholderBill(from: Self.manifestRow(lifeAreas: ["Housing"]))

        XCTAssertEqual(Self.merged(row, into: held, source: .manifestRow).lifeAreas, ["Housing"])
        XCTAssertEqual(Self.merged(Self.processedBill(lifeAreas: ["Housing"]), into: held, source: .loadedBill).lifeAreas, ["Housing"])
        // A reprocess can also add one, or change them all.
        XCTAssertEqual(
            Self.merged(BillsStore.placeholderBill(from: Self.manifestRow(lifeAreas: [" Taxes ", "Housing", "Taxes"])), into: held, source: .manifestRow).lifeAreas,
            ["Housing", "Taxes"],
            "trimmed, once each, in order"
        )
    }

    // MARK: - The store, without a relaunch

    func testTheNextManifestLoadClearsTheTagEverywhereItIsRead() async throws {
        let service = FakeBillsService()
        service.manifestResults = [.success([Self.manifestRow(lifeAreas: [])])]
        let (store, scope) = makeStore(service, bills: [Self.heldBill()])
        let held = try XCTUnwrap(store.bill(forGUID: Self.guid))
        XCTAssertTrue(held.matchesSubscribedInterests(Self.reader))
        XCTAssertEqual(BillSlipContent.interestTags(for: held, profile: Self.reader), [.topic("Healthcare"), .lifeArea(Self.medicalCosts)])

        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)

        let bill = try XCTUnwrap(store.bill(forGUID: Self.guid))
        XCTAssertEqual(bill.lifeAreas, [])
        XCTAssertEqual(store.activeManifestBills.map(\.lifeAreas), [[]], "the Bills list's card")
        XCTAssertTrue(store.isBillDetailHydrated(bill), "the row kept its date, so the details are not fetched again")
        XCTAssertEqual(BillSlipContent.interestTags(for: bill, profile: Self.reader), [.topic("Healthcare")], "the card's tags")
        XCTAssertTrue(bill.matchesSubscribedInterests(Self.reader), "still listed for the followed topic")
        let lifeAreaOnly = UserProfile(
            id: "user-2", email: "areas@example.com", district: "", state: "", avatarName: nil,
            subscribedSubCategories: [], subscribedLifeAreas: [Self.medicalCosts],
            subscribedMemberIDs: [], watchedBillGUIDs: [], selectedBillContentTypes: []
        )
        XCTAssertFalse(bill.matchesSubscribedInterests(lifeAreaOnly), "no longer 'for you' through Medical Costs")
        XCTAssertTrue(store.bills.filter { $0.lifeAreas.contains(Self.medicalCosts) }.isEmpty, "the Medical Costs life-area list")
    }

    /// Opening the bill clears the tag in what reads the store's bills (the life-area and Search lists,
    /// the "for you" match). The Bills list's cards are built from the manifest rows, so a card follows
    /// its row, not the opened bill: while a row still carries a life area the processed bill dropped,
    /// the card keeps it (and the next manifest change puts it back in the store). The server keeps the
    /// two the same: CreateBillsManifest and GET /processed-bill drop a ceremonial resolution's life
    /// areas alike, and the rows written before 2026-10-29 were rewritten by the backfill replay.
    func testOpeningTheBillClearsTheTagAndTheCardFollowsItsRow() async throws {
        let service = FakeBillsService()
        // The row as written before the server cleared ceremonial rows, then as rewritten.
        service.manifestResults = [
            .success([Self.manifestRow(lifeAreas: [Self.medicalCosts])]),
            .success([Self.manifestRow(lifeAreas: [])])
        ]
        service.processedBillResult = .success(Self.processedBill(lifeAreas: []))
        let (store, scope) = makeStore(service, bills: [Self.heldBill(hydrated: false, userVoted: true)])
        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)
        XCTAssertEqual(store.activeManifestBills.map(\.lifeAreas), [[Self.medicalCosts]])

        // A bill not hydrated yet: opening it fetches the processed bill.
        let message = await store.ensureHydrated(billID: UUID.deterministic(from: Self.guid))
        await waitForBillsCacheWrite(scope: scope)

        XCTAssertNil(message)
        let bill = try XCTUnwrap(store.bill(forGUID: Self.guid))
        XCTAssertEqual(bill.lifeAreas, [], "the life-area and Search lists")
        XCTAssertTrue(bill.userVoted, "the reader's own state stays")
        // The cards are rebuilt (debounced) from the rows and the bills: the card takes the opened bill's
        // details and its row's life areas.
        await waitForActiveManifestBills(of: store) { $0.first?.isProcessedDetailHydrated == true }
        XCTAssertEqual(store.activeManifestBills.map(\.lifeAreas), [[Self.medicalCosts]], "the Bills card follows its row")

        // The rewritten row clears the card at the next manifest load, without fetching the bill again.
        await store.load(forceRefresh: true, historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)
        XCTAssertEqual(store.bill(forGUID: Self.guid)?.lifeAreas, [])
        XCTAssertEqual(store.activeManifestBills.map(\.lifeAreas), [[]], "the Bills card")
        XCTAssertEqual(service.processedBillRequests.count, 1)

        // A processed bill stored another way (a linked bill, a companion member, the detail screen's
        // fallback) replaces them the same way.
        let (other, otherScope) = makeStore(FakeBillsService(), bills: [Self.heldBill()])
        other.upsertProcessedBill(Self.processedBill(lifeAreas: []))
        await waitForBillsCacheWrite(scope: otherScope)
        XCTAssertEqual(other.bill(forGUID: Self.guid)?.lifeAreas, [])
    }

    func testAScreensCopyKeepsTheTags() async throws {
        let (store, scope) = makeStore(FakeBillsService(), bills: [Self.heldBill()])
        var copy = Self.heldBill(lifeAreas: [], hydrated: nil)
        copy.userWatched = true

        store.upsertProcessedBill(copy)
        await waitForBillsCacheWrite(scope: scope)

        XCTAssertEqual(store.bill(forGUID: Self.guid)?.lifeAreas, [Self.medicalCosts])
    }

    func testTheBillsCacheReadWhileABillLoadsDoesNotBringTheTagBack() async throws {
        let service = FakeBillsService()
        let (store, scope) = makeStore(service)
        // The cache holds the bill as processed before 2026-10-29, tagged.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertTrue(DiskJSONCache.store(try encoder.encode([Self.heldBill()]), forKey: Self.billsCacheKey(scope)))
        // Hold the restore in its manifest read while the bill is loaded again (a push opened it).
        let releaseRead = DispatchSemaphore(value: 0)
        service.onCachedManifestRead = { releaseRead.wait() }

        let restore = Task { await store.restoreCachedStateIfNeeded() }
        try await Task.sleep(nanoseconds: 200_000_000)
        store.upsertProcessedBill(Self.processedBill(lifeAreas: []))
        releaseRead.signal()
        await restore.value
        await waitForBillsCacheWrite(scope: scope)

        XCTAssertEqual(store.bill(forGUID: Self.guid)?.lifeAreas, [], "the bill loaded since keeps the server's none")
    }

    func testACacheRestoreAppliesTheCachedManifestRows() {
        let snapshot = BillsStore.cacheRestoreSnapshot(
            cachedManifest: [Self.manifestRow(lifeAreas: [])],
            cachedBills: [Self.heldBill()],
            historyWindow: .oneWeek
        )

        XCTAssertEqual(snapshot.restoredBills?.map(\.lifeAreas), [[]])
        XCTAssertEqual(snapshot.resolvedActiveManifestBills.map(\.lifeAreas), [[]])
    }

    // MARK: - Bills cached before the change

    func testABillsCacheWrittenBeforeTheChangeDecodesAndARowClearsItsTag() throws {
        let scope = "stale-life-areas-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        // One bill as 1.1 wrote it (with the manifest's vote count, before `officialTitle` and the
        // hydration flag) and one as the 1.2 RC wrote it. The bill's fields are unchanged by UX-29.
        let oneOne = #"{"id":"\#(UUID.deterministic(from: Self.guid).uuidString)","title":"\#(Self.title)","#
            + #""category":"Social Policy","subCategory":"Healthcare","summary":"","soWhat":"","#
            + #""storedAt":"\#(Self.storedAt)","actions":[],"committees":[],"lifeAreas":["Medical Costs"],"#
            + #""billStatus":"New","guid":"\#(Self.guid)","congress":"119","billType":"hres","billID":"1187","#
            + #""passedHouse":false,"passedSenate":false,"userVoted":false,"userWatched":true,"#
            + #""userYeaCount":0,"userNayCount":0,"voteCount":42,"isPriority":false}"#
        let rcGuid = "BILLS-119hres826"
        let rc = #"{"id":"\#(UUID.deterministic(from: rcGuid).uuidString)","title":"Designate Careers in Energy Week","#
            + #""officialTitle":"Expressing support for the designation of Careers in Energy Week.","#
            + #""category":"Economic Policy","subCategory":"Labor and Employment","summary":"","soWhat":"It changes no law.","#
            + #""storedAt":"\#(Self.storedAt)","link":"https://www.congress.gov/bill/119th-congress/house-resolution/826","#
            + #""actions":[],"committees":[],"lifeAreas":["Jobs","Medical Costs"],"billStatus":"New","#
            + #""guid":"\#(rcGuid)","congress":"119","billType":"hres","billID":"826","passedHouse":false,"#
            + #""passedSenate":false,"userVoted":true,"userWatched":false,"userVote":"Yea","#
            + #""userYeaCount":1,"userNayCount":0,"isPriority":false,"isProcessedDetailHydrated":true}"#
        XCTAssertTrue(DiskJSONCache.store(Data("[\(oneOne),\(rc)]".utf8), forKey: Self.billsCacheKey(scope)))

        let restored = try XCTUnwrap(BillsStore.cachedBills(scope: scope), "a cache written before UX-29 decodes")
        XCTAssertEqual(restored.map(\.guid), [Self.guid, rcGuid])
        XCTAssertEqual(restored.map(\.lifeAreas), [[Self.medicalCosts], ["Jobs", Self.medicalCosts]])
        XCTAssertEqual(restored.last?.isProcessedDetailHydrated, true)

        let rcRow = BillsManifestItem(
            guid: rcGuid, congress: "119", billType: "hres", billID: "826", updatedAt: Self.storedAt,
            subCategories: ["Labor and Employment"], lifeAreas: [], sponsors: [], cosponsors: [],
            title: "Designate Careers in Energy Week", billStatus: "New"
        )
        let snapshot = BillsStore.cacheRestoreSnapshot(
            cachedManifest: [Self.manifestRow(lifeAreas: []), rcRow],
            cachedBills: restored,
            historyWindow: .oneWeek
        )
        let byGuid = Dictionary(uniqueKeysWithValues: (snapshot.restoredBills ?? []).compactMap { bill in bill.guid.map { ($0, bill) } })
        XCTAssertEqual(byGuid[Self.guid]?.lifeAreas, [])
        XCTAssertEqual(byGuid[rcGuid]?.lifeAreas, [])
        XCTAssertEqual(byGuid[rcGuid]?.userVote, .yea, "the reader's vote stays")
        XCTAssertEqual(byGuid[Self.guid]?.userWatched, true)
    }

    // MARK: - The manifest cache

    func testAWindowedFetchReplacesACachedRowsLifeAreasAtTheSameDate() throws {
        let cache = BillsManifestCache(namespace: "stale-life-areas-tests-\(UUID().uuidString)")
        addTeardownBlock { cache.clear() }
        cache.store([Self.manifestRow(lifeAreas: [Self.medicalCosts])], fetched: .full)

        // The relabelled row keeps its date.
        cache.store([Self.manifestRow(lifeAreas: [])], fetched: .windowed(updatedAfter: Date(timeIntervalSinceNow: -7 * 86_400)))

        XCTAssertEqual(try XCTUnwrap(cache.items()).map(\.lifeAreas), [[]])
        XCTAssertEqual(cache.coverage(), .full)
    }

    func testDuplicateRowsInOneFetchKeepTheNewerRowsLifeAreas() throws {
        let cache = BillsManifestCache(namespace: "stale-life-areas-tests-\(UUID().uuidString)")
        addTeardownBlock { cache.clear() }

        cache.store([
            Self.manifestRow(lifeAreas: [Self.medicalCosts], updatedAt: Self.iso(daysAgo: 3)),
            Self.manifestRow(lifeAreas: [], updatedAt: Self.storedAt)
        ], fetched: .full)

        let items = try XCTUnwrap(cache.items())
        XCTAssertEqual(items.map(\.lifeAreas), [[]], "the older duplicate does not bring Medical Costs back")
        XCTAssertEqual(items.map(\.updatedAt), [Self.storedAt])
    }

    // MARK: - Text-version rows of one bill

    /// The manifest can list a bill under its current guid and an older text-version guid
    /// (`BILLS-119hres1187ih`). `deduplicateManifest` keeps the current row, and its life areas win, an empty list
    /// included (project default of 2026-10-29): until then it took the union, so the older row brought Medical
    /// Costs back, whichever row came first.
    func testTheCurrentRowsLifeAreasWinOverAnOlderTextVersionRow() throws {
        let current = Self.manifestRow(lifeAreas: [])
        let textVersion = Self.textVersionRow(lifeAreas: [Self.medicalCosts])
        for rows in [[current, textVersion], [textVersion, current]] {
            let deduplicated = BillsStore.deduplicateManifest(rows)
            XCTAssertEqual(deduplicated.map(\.guid), [Self.guid], "one bill, under its current guid")
            XCTAssertEqual(deduplicated.map(\.lifeAreas), [[]], "\(rows.map(\.guid))")
        }

        let taxes = SubscriptionsConfig.lifeTaxes
        let narrowed = BillsStore.deduplicateManifest([
            Self.textVersionRow(lifeAreas: [taxes, Self.medicalCosts]),
            Self.manifestRow(lifeAreas: [taxes])
        ])
        XCTAssertEqual(narrowed.map(\.lifeAreas), [[taxes]], "only the current row's")

        // The older row still gives what the current one lacks, as before (here its sponsor).
        let sponsored = BillsStore.deduplicateManifest([
            Self.manifestRow(lifeAreas: []),
            Self.textVersionRow(lifeAreas: [Self.medicalCosts], sponsors: ["S000001"])
        ])
        XCTAssertEqual(sponsored.map(\.sponsors), [["S000001"]])
    }

    /// Through the store: a manifest load that lists both rows clears the tag the device held, in the bill and in
    /// the Bills list's card.
    func testAManifestLoadWithAnOlderTextVersionRowStillClearsTheTag() async throws {
        let service = FakeBillsService()
        service.manifestResults = [.success([Self.textVersionRow(lifeAreas: [Self.medicalCosts]), Self.manifestRow(lifeAreas: [])])]
        let (store, scope) = makeStore(service, bills: [Self.heldBill()])

        await store.load(historyWindow: .oneWeek)
        await waitForBillsCacheWrite(scope: scope)

        XCTAssertEqual(try XCTUnwrap(store.bill(forGUID: Self.guid)).lifeAreas, [])
        XCTAssertEqual(store.activeManifestBills.map(\.lifeAreas), [[]], "the Bills list's card")
        XCTAssertTrue(store.bills.filter { $0.lifeAreas.contains(Self.medicalCosts) }.isEmpty, "the Medical Costs life-area list")
    }

    private static func textVersionRow(lifeAreas: [String], sponsors: [String] = []) -> BillsManifestItem {
        BillsManifestItem(
            guid: "\(guid)ih",
            congress: "119",
            billType: "hres",
            billID: "1187",
            updatedAt: iso(daysAgo: 200),
            subCategories: ["Healthcare"],
            lifeAreas: lifeAreas,
            sponsors: sponsors,
            cosponsors: [],
            title: title,
            billStatus: "New"
        )
    }

    // MARK: - What the reader sees

    /// The slip the Bills list draws for the bill (`BillCard`): the Medical Costs tag goes once the
    /// manifest row clears it, and a partial copy leaves the slip exactly as it was.
    func testTheSlipDropsTheLifeAreaTagTheServerCleared() throws {
        let held = Self.heldBill()
        let cleared = Self.merged(BillsStore.placeholderBill(from: Self.manifestRow(lifeAreas: [])), into: held, source: .manifestRow)
        let kept = Self.merged(Self.heldBill(lifeAreas: [], hydrated: nil), into: held, source: .loadedBill)

        func slip(_ bill: Bill) -> some View {
            BillSlip(content: BillSlipContent(bill: bill, profile: Self.reader))
                .padding(20)
                .background(BillboardColors.background)
        }

        let before = AccessibilityTreeText.text(of: slip(held))
        XCTAssertTrue(before.contains(Self.title), before)
        XCTAssertTrue(before.localizedCaseInsensitiveContains(Self.medicalCosts), before)
        let after = AccessibilityTreeText.text(of: slip(cleared))
        XCTAssertTrue(after.contains(Self.title), after)
        XCTAssertTrue(after.localizedCaseInsensitiveContains("Healthcare"), after)
        XCTAssertFalse(after.localizedCaseInsensitiveContains(Self.medicalCosts), after)

        for scheme in [ColorScheme.light, .dark] {
            let heldImage = try render(slip(held), scheme: scheme)
            let clearedImage = try render(slip(cleared), scheme: scheme)
            let keptImage = try render(slip(kept), scheme: scheme)
            for (name, image) in [("held", heldImage), ("cleared", clearedImage)] {
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "stale-life-area-slip-\(name)-\(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertNotEqual(clearedImage.dataProvider?.data as Data?, heldImage.dataProvider?.data as Data?, "the tag is gone (\(scheme))")
            XCTAssertEqual(keptImage.dataProvider?.data as Data?, heldImage.dataProvider?.data as Data?, "a partial copy changes nothing (\(scheme))")
        }
    }

    // MARK: - Helpers

    private static func billsCacheKey(_ scope: String) -> String {
        // Mirrors BillsStore's private data key.
        ScopedStorageKey.make(base: "BillsStore.bills.data", scope: scope)
    }

    private func makeStore(_ service: FakeBillsService, bills: [Bill]? = nil) -> (store: BillsStore, scope: String) {
        let scope = "stale-life-areas-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let store = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        return (store, scope)
    }

    /// Waits for the store's debounced rebuild of `activeManifestBills` to satisfy `condition`.
    private func waitForActiveManifestBills(
        of store: BillsStore,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: ([Bill]) -> Bool
    ) async {
        for _ in 0..<500 {
            if condition(store.activeManifestBills) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The Bills list's cards were not rebuilt", file: file, line: line)
    }

    /// The store writes its bills cache from a detached task (data, then a timestamp). Waits for the
    /// timestamp and removes it, so no write lands after the teardown clears the scope.
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

    private func render<Content: View>(_ view: Content, scheme: ColorScheme) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: 390).environment(\.colorScheme, scheme))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        return try XCTUnwrap(renderer.cgImage)
    }
}
