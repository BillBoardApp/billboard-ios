import XCTest
@testable import Billboard

/// UX-51 (project decision 2026-11-19): a vetoed bill says VETOED wherever an outcome is labelled. The server keeps
/// `billStatus` (Passed, or Failed once an override fails) and adds `vetoed: true` beside it on the processed bill,
/// the manifest row and the Weekly Brief item. The app stamps VETOED in the Failed colour, single-ruled, unless the
/// bill became law; lists still follow the status. A vetoed member leads its companion group over a Passed one.
/// Bills held from 1.2 take the flag from the manifest rows by guid, in the window or not.
@MainActor
final class VetoedStatusTests: XCTestCase {
    /// H.R. 131 and S. 296: the vetoed bill is the primary of its group, and its partner is New.
    private static let house = "BILLS-119hr131"
    private static let senate = "BILLS-119s296"
    private static let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
    private let companions = CompanionGroupIndex(groups: [VetoedStatusTests.group])
    private let noVotes: (String) -> VoteState = { _ in .unknown }

    /// A recent bill with an active priority, so it matches the placeholder profile without topics.
    private func bill(
        _ guid: String,
        _ status: BillStatus,
        vetoed: Bool? = nil,
        hoursAgo: Double = 1,
        hydrated: Bool? = nil,
        userVote: UserVote? = nil
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: "Bill \(guid)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 60 * 60)),
            billStatus: status,
            vetoed: vetoed,
            guid: guid,
            userVoted: userVote?.countsAsVote == true,
            userVote: userVote,
            isPriority: true,
            isProcessedDetailHydrated: hydrated
        )
    }

    private func row(
        _ guid: String,
        status: String? = "Failed",
        vetoed: Bool? = nil,
        updatedAt: String = "2026-01-08T18:00:00.000Z",
        title: String = "A bill"
    ) -> BillsManifestItem {
        let locator = BillsService.deriveLocator(from: guid)
        return BillsManifestItem(
            guid: guid,
            congress: locator?.congress,
            billType: locator?.billType,
            billID: locator?.billID,
            updatedAt: updatedAt,
            subCategories: ["Energy"],
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            title: title,
            billStatus: status,
            vetoed: vetoed
        )
    }

    private func iso(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    // MARK: - The flag

    func testAVetoedBillKeepsItsStatusAndAFinalizedBillIsNeverVetoed() {
        XCTAssertTrue(bill(Self.house, .failed, vetoed: true).isVetoed)
        XCTAssertTrue(bill(Self.house, .passed, vetoed: true).isVetoed)
        XCTAssertEqual(bill(Self.house, .failed, vetoed: true).billStatus, .failed)
        XCTAssertFalse(bill(Self.house, .finalized, vetoed: true).isVetoed, "Finalized always wins")
        XCTAssertFalse(bill(Self.house, .failed).isVetoed)
        XCTAssertFalse(bill(Self.house, .failed, vetoed: false).isVetoed)
    }

    // MARK: - Decoding

    private static let processedBillJSON = #"""
    {
      "schemaVersion": 1, "kind": "processed", "storedAt": "2026-11-13T20:00:00.000Z",
      "identifier": {"congress": "119", "billType": "hr", "billNumber": "131"},
      "guid": "BILLS-119hr131", "title": "Finish the Arkansas Valley Conduit Act",
      "link": "https://www.congress.gov/bill/119th-congress/house-bill/131", "soWhat": "A water pipeline.",
      "billBreakdown": {"who": "Rural towns", "what": "Changes the repayment terms", "how": "Amends a 1962 law",
                        "when": "On enactment", "where": "Colorado"},
      "subCategories": ["Conservation and Natural Resources"], "lifeAreas": [], "sponsors": ["D000001"], "cosponsors": [],
      "actions": [
        {"actionCode": "33000", "actionDate": "2026-01-08", "text": "Failed of passage in House over veto by the Yeas and Nays: 248 - 177.", "type": "Veto"},
        {"actionCode": "31000", "actionDate": "2025-12-29", "text": "Vetoed by President.", "type": "President"}
      ],
      "billStatus": "Failed"
    }
    """#

    private func processedBillData(vetoed: Any?) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.processedBillJSON.utf8)) as? [String: Any])
        object["vetoed"] = vetoed
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func manifestData(_ items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["generatedAt": "2026-11-19T12:00:00.000Z", "count": items.count, "bills": items])
    }

    private func manifestRow(_ guid: String, vetoed: Any? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "guid": guid, "billType": "hr", "congress": "119", "billNumber": String(guid.dropFirst(11)),
            "updatedAt": "2026-01-08T18:00:00.000Z", "title": "A bill", "billStatus": "Failed"
        ]
        object["vetoed"] = vetoed
        return object
    }

    func testTheContractsDecodeWithAndWithoutTheFlag() throws {
        let decoder = JSONDecoder.convertingFromSnakeCase()

        let processed = try decoder.decode(UserAPIContractsV1.ProcessedBill.self, from: try processedBillData(vetoed: true))
        XCTAssertEqual(processed.vetoed, true)
        XCTAssertNil(try decoder.decode(UserAPIContractsV1.ProcessedBill.self, from: try processedBillData(vetoed: nil)).vetoed)

        let manifest = try decoder.decode(
            UserAPIContractsV1.BillsManifest.self,
            from: try manifestData([manifestRow(Self.house, vetoed: true), manifestRow("BILLS-119hr504")])
        )
        XCTAssertEqual(manifest.bills.map(\.vetoed), [true, nil])
        XCTAssertEqual(manifest.bills.map(BillsManifestItem.init(dto:)).map(\.vetoed), [true, nil])

        func digestItem(_ vetoed: Bool?) throws -> UserAPIContractsV1.WeeklyDigestItem {
            var object: [String: Any] = [
                "id": "bill|\(Self.house)", "kind": "bill", "title": "A bill", "summary": "Jan 8: Failed of passage.",
                "accent": "attention", "billState": "failed", "billGuid": Self.house
            ]
            object["vetoed"] = vetoed
            return try decoder.decode(UserAPIContractsV1.WeeklyDigestItem.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let vetoedItem = try WeeklyDigestItem(dto: try digestItem(true))
        XCTAssertEqual(vetoedItem.vetoed, true)
        XCTAssertEqual(vetoedItem.billState, .failed, "billState keeps the status's value")
        XCTAssertNil(try WeeklyDigestItem(dto: try digestItem(nil)).vetoed)
    }

    func testTheAppsManifestItemDecodesWithAndWithoutTheFlagAndRoundTrips() throws {
        let decoder = JSONDecoder.convertingFromSnakeCase()
        let items = try decoder.decode(
            [BillsManifestItem].self,
            from: JSONSerialization.data(withJSONObject: [manifestRow(Self.house, vetoed: true), manifestRow("BILLS-119hr504")])
        )
        XCTAssertEqual(items.map(\.vetoed), [true, nil])

        let encoded = try JSONEncoder().encode(items)
        XCTAssertEqual(try decoder.decode([BillsManifestItem].self, from: encoded), items)
        let written = String(decoding: encoded, as: UTF8.self)
        XCTAssertEqual(written.components(separatedBy: "\"vetoed\"").count - 1, 1, "absent is not written: \(written)")
    }

    func testAFlagThatIsNotABooleanNeverFailsTheManifest() throws {
        let decoder = JSONDecoder.convertingFromSnakeCase()
        let items = try decoder.decode(
            [BillsManifestItem].self,
            from: JSONSerialization.data(withJSONObject: [
                manifestRow(Self.house, vetoed: "yes"), manifestRow("BILLS-119hr504", vetoed: false)
            ])
        )
        XCTAssertEqual(items.map(\.guid), [Self.house, "BILLS-119hr504"], "every row decodes")
        XCTAssertEqual(items.map(\.vetoed), [nil, nil], "the server sends only true")
    }

    func testABillCachedWithoutTheKeyDecodesAndACachedFlagIsKept() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 1.2 wrote no key.
        let plain = try encoder.encode([bill(Self.house, .failed)])
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("vetoed"))
        XCTAssertNil(try decoder.decode([Bill].self, from: plain).first?.vetoed)

        // 1.3 keeps the flag through the cache and the topic renaming of cached bills (LLM-10).
        let flagged = Bill(
            id: UUID.deterministic(from: Self.house), title: "A bill", category: "Social Justice", subCategory: "Social Justice",
            soWhat: "", billStatus: .failed, vetoed: true, guid: Self.house, userVoted: false
        )
        let restored = try XCTUnwrap(try decoder.decode([Bill].self, from: encoder.encode([flagged])).first)
        XCTAssertEqual(restored.vetoed, true)
        let renamed = restored.canonicalizingTopics()
        XCTAssertNotEqual(renamed.subCategory, "Social Justice", "precondition: the topic was renamed")
        XCTAssertEqual(renamed.vetoed, true)
    }

    // MARK: - Mapping

    func testThePlaceholderAndTheProcessedBillCarryTheFlag() throws {
        XCTAssertEqual(BillsStore.placeholderBill(from: row(Self.house, vetoed: true)).vetoed, true)
        XCTAssertNil(BillsStore.placeholderBill(from: row(Self.house)).vetoed)
        XCTAssertNil(BillsStore.placeholderBill(from: row(Self.house, vetoed: false)).vetoed)

        let vetoed = try BillsService.decodeProcessedBill(from: try processedBillData(vetoed: true))
        XCTAssertEqual(vetoed.vetoed, true)
        XCTAssertEqual(vetoed.billStatus, .failed)
        XCTAssertTrue(vetoed.isVetoed)
        XCTAssertNil(try BillsService.decodeProcessedBill(from: try processedBillData(vetoed: nil)).vetoed)
    }

    // MARK: - Stamps and VoiceOver

    func testTheStampIsVetoedInTheFailedColourSingleRuled() {
        let kind = StatusStamp.Kind(status: .failed, vetoed: true)
        XCTAssertEqual(kind, .vetoed)
        XCTAssertEqual(kind.word, "Vetoed")
        XCTAssertEqual(kind.spokenWord, "Vetoed")
        XCTAssertEqual(kind.paletteToken, BillboardPalette.statusFailed)
        XCTAssertFalse(kind.isDoubleRuled)
        XCTAssertEqual(StatusStamp.Kind(status: .passed, vetoed: true), .vetoed)
        XCTAssertEqual(StatusStamp.Kind(status: .finalized, vetoed: true), .becameLaw)
        XCTAssertEqual(StatusStamp.Kind(status: .failed, vetoed: false), .failed)
    }

    func testASlipReadsVetoed() {
        let profile = UserProfile.placeholder()
        let single = BillSlipContent(bill: bill(Self.house, .failed, vetoed: true), profile: profile)
        XCTAssertEqual(single.stamp, .vetoed)
        XCTAssertTrue(single.accessibilityLabel().contains("House bill 131. Vetoed."), single.accessibilityLabel())

        let law = BillSlipContent(bill: bill(Self.house, .finalized, vetoed: true), profile: profile)
        XCTAssertEqual(law.stamp, .becameLaw)
    }

    /// H.R. 131 is the primary of its group and leads it: a plain VETOED stamp, no number.
    func testTheGroupLedByItsVetoedPrimaryReadsVetoed() {
        let members = [bill(Self.house, .failed, vetoed: true, hoursAgo: 24), bill(Self.senate, .new)]
        let lead = companions.statusLead(for: Self.group, memberBills: members)
        XCTAssertEqual(lead.guid, Self.house)
        XCTAssertTrue(lead.isPrimary)
        XCTAssertTrue(lead.vetoed)
        XCTAssertEqual(lead.label, "Vetoed")

        let slip = BillSlipContent(bill: members[0], profile: .placeholder(), companion: BillCompanionDisplay(group: Self.group, statusLead: lead))
        XCTAssertEqual(slip.stamp, .vetoed)
        XCTAssertTrue(slip.accessibilityLabel().contains("House bill 131 and Senate bill 296. Vetoed."), slip.accessibilityLabel())

        // S. 296's own page shows the group too, led by H.R. 131.
        let page = BillFrontMatter.Content(bill: members[1], companion: BillCompanionDisplay(group: Self.group, statusLead: lead))
        XCTAssertEqual(page.status, .failed)
        XCTAssertTrue(page.vetoed)
        XCTAssertNil(page.companionLead)
    }

    /// Primary S. 10 and vetoed H.R. 10: the stamp names the vetoed member.
    func testAVetoedMemberThatIsNotThePrimaryIsNamed() {
        let group = BillCompanionGroup(primaryGuid: "BILLS-119s10", memberGuids: ["BILLS-119s10", "BILLS-119hr10"], relationship: "identical")
        let index = CompanionGroupIndex(groups: [group])
        let members = [bill("BILLS-119s10", .passed), bill("BILLS-119hr10", .failed, vetoed: true, hoursAgo: 48)]
        let lead = index.statusLead(for: group, memberBills: members)
        XCTAssertEqual(lead.guid, "BILLS-119hr10")
        XCTAssertEqual(lead.label, "Vetoed · H.R. 10")

        let slip = BillSlipContent(bill: members[0], profile: .placeholder(), companion: BillCompanionDisplay(group: group, statusLead: lead))
        XCTAssertEqual(slip.stamp, .companionLead(number: "H.R. 10", status: .failed, vetoed: true))
        XCTAssertEqual(slip.stamp.word, "H.R. 10 Vetoed")
        XCTAssertTrue(slip.accessibilityLabel().contains("House bill 10 vetoed"), slip.accessibilityLabel())
    }

    func testTheCompanionMemberRowAndTheUpdatesRowStampVetoed() {
        let vetoed = bill(Self.house, .failed, vetoed: true)
        XCTAssertTrue(UpdatesOutcomeRow(bill: vetoed).accessibilityText.contains("House bill 131. Vetoed."))
        XCTAssertTrue(UpdatesOutcomeRow(bill: bill(Self.house, .failed)).accessibilityText.contains("House bill 131. Failed."))
        let item = WeeklyDigestItem(
            id: "bill|\(Self.house)", kind: .bill, title: "A bill", eyebrow: "Failed Jan 8", summary: "Jan 8: Failed of passage.",
            detail: nil, reason: nil, accent: .attention, billState: .failed, vetoed: true, billGuid: Self.house,
            primaryMemberBioguideID: nil
        )
        XCTAssertTrue(WeeklyBriefItemView(item: item).accessibilityText.contains("House bill 131. Vetoed."))
    }

    // MARK: - Status lead

    func testTheStatusLeadRanksAVetoedMemberAbovePassedAndBelowALaw() {
        // A vetoed Failed member beats a Passed partner, whichever moved later.
        let failedVeto = companions.statusLead(for: Self.group, memberBills: [
            bill(Self.house, .failed, vetoed: true, hoursAgo: 48), bill(Self.senate, .passed, hoursAgo: 1)
        ])
        XCTAssertEqual(failedVeto.guid, Self.house)
        XCTAssertEqual(failedVeto.label, "Vetoed")

        // A vetoed Passed member beats a Passed partner stored later.
        let passedVeto = companions.statusLead(for: Self.group, memberBills: [
            bill(Self.house, .passed, vetoed: true, hoursAgo: 48), bill(Self.senate, .passed, hoursAgo: 1)
        ])
        XCTAssertEqual(passedVeto.guid, Self.house)
        XCTAssertTrue(passedVeto.vetoed)

        // Finalized beats vetoed.
        let law = companions.statusLead(for: Self.group, memberBills: [
            bill(Self.house, .failed, vetoed: true, hoursAgo: 1), bill(Self.senate, .finalized, hoursAgo: 48)
        ])
        XCTAssertEqual(law.guid, Self.senate)
        XCTAssertFalse(law.vetoed)
        XCTAssertEqual(law.label, "Became law · S. 296")
    }

    // MARK: - Lists follow the status

    private func feed(_ bills: [Bill]) -> UpdatesFeedSnapshot {
        UpdatesDerivation.feedSnapshot(
            bills: bills,
            alerts: [],
            dismissedBillIDs: [],
            readBillAlertIDs: [],
            userProfile: .placeholder(),
            voteLookup: noVotes,
            billLookup: { _ in nil },
            companions: .empty
        )
    }

    func testAVetoedBillIsListedByItsStatus() {
        let passedVeto = bill("BILLS-119hr1", .passed, vetoed: true)
        let failedVeto = bill("BILLS-119hr2", .failed, vetoed: true)
        let open = bill("BILLS-119hr3", .new)
        let bills = [passedVeto, failedVeto, open]

        let snapshot = feed(bills)
        XCTAssertEqual(snapshot.passedBills.map(\.guid), ["BILLS-119hr1"], "Updates' Passed bills, stamped VETOED")
        XCTAssertEqual(snapshot.failedBills.map(\.guid), ["BILLS-119hr2"])

        let passedTile = BillBoardDerivedCollections.passedSubscribed(bills: bills, profile: .placeholder(), companions: .empty)
        XCTAssertEqual(passedTile.map(\.guid), ["BILLS-119hr1"], "Search's Passed tile")

        let queue = BillboardQueueDerivation.snapshot(
            bills: bills,
            dismissedBillIDs: [],
            userProfile: .placeholder(),
            historyWindow: .oneWeek,
            voteIndex: UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: noVotes, companions: .empty),
            voteLookup: noVotes,
            starterFeedEnabled: false
        )
        XCTAssertEqual(queue.pendingBills.map(\.guid), ["BILLS-119hr3"], "the Bills queue leaves both out")
    }

    // MARK: - Merging

    func testTheManifestRowIsTheAuthority() {
        let held = bill(Self.house, .failed, hydrated: true)
        let flaggedRow = BillsStore.placeholderBill(from: row(Self.house, vetoed: true))
        XCTAssertEqual(BillsStore.mergedBillPreservingExistingContext(incoming: flaggedRow, existing: held, source: .manifestRow).vetoed, true)

        let flagged = bill(Self.house, .failed, vetoed: true, hydrated: true)
        let plainRow = BillsStore.placeholderBill(from: row(Self.house))
        XCTAssertNil(BillsStore.mergedBillPreservingExistingContext(incoming: plainRow, existing: flagged, source: .manifestRow).vetoed)
    }

    func testAProcessedBillWinsAndAPartialOrCachedCopyKeepsTheHeldFlag() {
        let flagged = bill(Self.house, .failed, vetoed: true, hydrated: true)
        let processedWithout = bill(Self.house, .failed, hydrated: true)
        XCTAssertNil(BillsStore.mergedBillPreservingExistingContext(incoming: processedWithout, existing: flagged, source: .loadedBill).vetoed)
        let processedWith = bill(Self.house, .failed, vetoed: true, hydrated: true)
        XCTAssertEqual(
            BillsStore.mergedBillPreservingExistingContext(incoming: processedWith, existing: bill(Self.house, .failed), source: .loadedBill).vetoed,
            true
        )

        let screenCopy = bill(Self.house, .failed, hydrated: false)
        XCTAssertEqual(BillsStore.mergedBillPreservingExistingContext(incoming: screenCopy, existing: flagged, source: .loadedBill).vetoed, true)
        XCTAssertEqual(BillsStore.mergedBillPreservingExistingContext(incoming: processedWithout, existing: flagged, source: .cachedBill).vetoed, true)
    }

    func testFinalizedClearsTheVeto() {
        let flagged = bill(Self.house, .failed, vetoed: true, hydrated: true)
        let lawRow = BillsStore.placeholderBill(from: row(Self.house, status: "Finalized", updatedAt: iso(daysAgo: 0)))
        let merged = BillsStore.mergedBillPreservingExistingContext(incoming: lawRow, existing: flagged, source: .manifestRow)
        XCTAssertEqual(merged.billStatus, .finalized)
        XCTAssertNil(merged.vetoed)
        XCTAssertFalse(merged.isVetoed)
        XCTAssertEqual(StatusStamp.Kind(status: merged.billStatus, vetoed: merged.isVetoed), .becameLaw)
    }

    /// The full manifest's row for a voted bill outside the window is not merged into it (only the window's rows
    /// are); the copy by guid sets the flag anyway.
    func testAFullManifestSetsTheFlagOnAVotedBillOutsideTheWindow() {
        let voted = bill(Self.house, .failed, hoursAgo: 24 * 300, hydrated: true, userVote: .yea)
        let manifest = [row(Self.house, vetoed: true, updatedAt: iso(daysAgo: 300)), row("BILLS-119hr9", status: "New", updatedAt: iso(daysAgo: 1))]

        let update = BillsStore.manifestUpdate(for: manifest, replacing: [], existingBills: [voted], historyWindow: .oneWeek)

        let changes = update.changes
        XCTAssertEqual(changes?.visibleEntries.map(\.item.guid), ["BILLS-119hr9"], "precondition: the voted bill's row is outside the window")
        let merged = changes?.mergedBills.first { $0.guid == Self.house }
        XCTAssertEqual(merged?.vetoed, true)
        XCTAssertEqual(merged?.isProcessedDetailHydrated, true, "its details are kept, so ensureHydrated will not fetch them again")
        XCTAssertEqual(merged?.userVote, .yea)

        // A row without the flag clears it; a bill the manifest does not list keeps its own.
        let flaggedVoted = bill(Self.house, .failed, vetoed: true, hoursAgo: 24 * 300, hydrated: true, userVote: .yea)
        let other = bill("BILLS-119hr504", .failed, vetoed: true, hoursAgo: 24 * 300, hydrated: true, userVote: .nay)
        let cleared = BillsStore.manifestUpdate(
            for: [row(Self.house, updatedAt: iso(daysAgo: 300)), row("BILLS-119hr9", status: "New", updatedAt: iso(daysAgo: 1))],
            replacing: [],
            existingBills: [flaggedVoted, other],
            historyWindow: .oneWeek
        ).changes?.mergedBills
        XCTAssertNil(cleared?.first { $0.guid == Self.house }?.vetoed)
        XCTAssertEqual(cleared?.first { $0.guid == "BILLS-119hr504" }?.vetoed, true)
    }

    /// 1.2 held H.R. 131 as hydrated and FAILED; opening it does not fetch it again. The one-time full load after
    /// the update gives it the flag from its row, so its card and page say VETOED.
    func testAHydratedBillHeldFrom12GetsTheFlagFromTheFullManifest() async {
        let scope = "vetoed-status-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let held = bill(Self.house, .failed, hoursAgo: 24 * 300, hydrated: true, userVote: .yea)
        let service = FakeBillsService()
        service.cachedManifest = []
        service.manifestResults = [.success([
            row(Self.house, vetoed: true, updatedAt: iso(daysAgo: 300)),
            row("BILLS-119hr9", status: "New", updatedAt: iso(daysAgo: 1))
        ])]
        let store = BillsStore(bills: [held], cacheScope: scope, service: service, preferencesService: FakePreferencesService())

        await store.load(loadFullManifest: true, historyWindow: .oneWeek)

        let loaded = store.bill(forGUID: Self.house)
        XCTAssertEqual(loaded?.vetoed, true)
        XCTAssertEqual(loaded?.billStatus, .failed)
        XCTAssertEqual(loaded?.userVote, .yea)
        await store.ensureHydrated(billID: held.id)
        XCTAssertTrue(service.processedBillRequests.isEmpty, "precondition: a bill held as hydrated is not fetched again")
        XCTAssertEqual(store.bill(forGUID: Self.house)?.isVetoed, true)
        await settleBillsCache(scope: scope)
    }

    func testTheRestoreTakesTheCachedRowsFlags() {
        let voted = bill(Self.house, .failed, hoursAgo: 24 * 300, hydrated: true, userVote: .yea)
        let snapshot = BillsStore.cacheRestoreSnapshot(
            cachedManifest: [row(Self.house, vetoed: true, updatedAt: iso(daysAgo: 300))],
            cachedBills: [voted],
            historyWindow: .oneWeek
        )
        XCTAssertEqual(snapshot.restoredBills?.first { $0.guid == Self.house }?.vetoed, true)
    }

    // MARK: - Manifest normalization and cache

    func testAChangeToTheFlagAloneIsAChange() {
        XCTAssertFalse(BillsStore.manifestsAreEquivalent([row(Self.house, vetoed: true)], [row(Self.house)]))
        XCTAssertTrue(BillsStore.manifestsAreEquivalent([row(Self.house, vetoed: true)], [row(Self.house, vetoed: true)]))
    }

    func testDeduplicationKeepsTheFlagOfTheRowWhoseStatusIsKept() {
        // The unsuffixed guid is kept; its status and flag go with it.
        let merged = BillsStore.deduplicateManifest([row("BILLS-119hr131ih", status: "Passed"), row(Self.house, vetoed: true)])
        XCTAssertEqual(merged.map(\.guid), [Self.house])
        XCTAssertEqual(merged.first?.vetoed, true)

        // A kept row without a status takes the duplicate's status and flag.
        let fromDuplicate = BillsStore.deduplicateManifest([row(Self.house, status: nil), row("BILLS-119hr131ih", vetoed: true)])
        XCTAssertEqual(fromDuplicate.first?.billStatus, "Failed")
        XCTAssertEqual(fromDuplicate.first?.vetoed, true)
    }

    func testTheCacheMergeTakesTheFlagWithTheStatusAndCountsIt() {
        // Same date: the more complete item, which the flag makes this one.
        let sameDate = BillsManifestCache.deduplicatedItems([row(Self.house), row(Self.house, vetoed: true)])
        XCTAssertEqual(sameDate.map(\.vetoed), [true])

        // The newer item wins, with its own (absent) flag: an override cleared it.
        let newer = BillsManifestCache.deduplicatedItems([
            row(Self.house, vetoed: true, updatedAt: "2026-01-08T18:00:00.000Z"),
            row(Self.house, status: "Passed", updatedAt: "2026-02-01T18:00:00.000Z")
        ])
        XCTAssertEqual(newer.first?.billStatus, "Passed")
        XCTAssertNil(newer.first?.vetoed)

        // The newer item has no status: the status and the flag come from the other one.
        let statusFromFallback = BillsManifestCache.deduplicatedItems([
            row(Self.house, vetoed: true, updatedAt: "2026-01-08T18:00:00.000Z"),
            row(Self.house, status: nil, updatedAt: "2026-02-01T18:00:00.000Z")
        ])
        XCTAssertEqual(statusFromFallback.first?.billStatus, "Failed")
        XCTAssertEqual(statusFromFallback.first?.vetoed, true)
    }
}
