import XCTest
@testable import Billboard

final class BillModelTests: XCTestCase {

    // MARK: - BillStatus

    func testBillStatusRawValues() {
        XCTAssertEqual(BillStatus.new.rawValue, "New")
        XCTAssertEqual(BillStatus.updated.rawValue, "Updated")
        XCTAssertEqual(BillStatus.finalized.rawValue, "Finalized")
    }

    func testBillStatusDecodable() throws {
        let json = "\"New\""
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(BillStatus.self, from: data)
        XCTAssertEqual(decoded, .new)
    }

    // MARK: - UserVote

    func testUserVoteRawValues() {
        XCTAssertEqual(UserVote.yea.rawValue, "Yea")
        XCTAssertEqual(UserVote.nay.rawValue, "Nay")
        XCTAssertEqual(UserVote.abstain.rawValue, "Abstain")
    }

    func testUserVoteCountsAsVote() {
        XCTAssertTrue(UserVote.yea.countsAsVote)
        XCTAssertTrue(UserVote.nay.countsAsVote)
        XCTAssertFalse(UserVote.abstain.countsAsVote)
    }

    // MARK: - Bill identity

    func testBillIdentityById() {
        let bill1 = makeBill(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Bill A")
        let bill2 = makeBill(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Bill B")
        XCTAssertEqual(bill1.id, bill2.id, "Bills with the same UUID should be considered the same entity")
    }

    // MARK: - Default aggregates

    func testDefaultAggregatesAreZero() {
        let bill = makeBill()
        XCTAssertEqual(bill.userYeaCount, 0)
        XCTAssertEqual(bill.userNayCount, 0)
        XCTAssertNil(bill.congressHouseYeaCount)
        XCTAssertNil(bill.congressHouseNayCount)
        XCTAssertNil(bill.congressSenateYeaCount)
        XCTAssertNil(bill.congressSenateNayCount)
    }

    @MainActor
    func testBillsManifestItemDecodesUpdatedAt() throws {
        let json = """
        {
          "guid": "BILLS-119hr1234ih",
          "billType": "hr",
          "congress": "119",
          "billNumber": "1234",
          "updatedAt": "2026-03-06T19:59:00.000Z",
          "title": "Clean Energy Access Act",
          "subCategories": ["Energy"],
          "lifeAreas": ["Environment"],
          "sponsors": ["Jane Doe"],
          "cosponsors": [],
          "billStatus": "Updated"
        }
        """

        let decoder = JSONDecoder()
        let item = try decoder.decode(BillsManifestItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.updatedAt, "2026-03-06T19:59:00.000Z")
        XCTAssertEqual(item.billStatus, "Updated")
    }

    @MainActor
    func testPreferredBillStatusDoesNotDowngradeUpdatedToNew() {
        XCTAssertEqual(
            BillsStore.preferredBillStatus(incoming: .new, existing: .updated),
            .updated
        )
    }

    @MainActor
    func testPreferredBillStatusAllowsUpgradeFromNewToUpdated() {
        XCTAssertEqual(
            BillsStore.preferredBillStatus(incoming: .updated, existing: .new),
            .updated
        )
    }

    @MainActor
    func testMergedBillPreservesQueueEligibilityWhenHydratingDetail() {
        let billID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let existing = Bill(
            id: billID,
            title: "Energy Independence Act",
            category: "Energy",
            subCategory: "Climate",
            summary: "",
            soWhat: "",
            storedAt: "2026-04-08T10:00:00.000Z",
            link: nil,
            actions: [],
            committees: [],
            lifeAreas: ["Environment"],
            billStatus: .updated,
            guid: "BILLS-119hr123ih",
            congress: "119",
            billType: "hr",
            billID: "123",
            sponsorMemberID: nil,
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            isPriority: true,
            priorityRank: 2,
            priorityReason: "Trending",
            priorityExpiresAt: "2026-04-10T10:00:00.000Z",
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil,
            officialVotes: nil,
            isProcessedDetailHydrated: false
        )

        let hydrated = Bill(
            id: billID,
            title: "Energy Independence Act",
            category: "Other",
            subCategory: nil,
            summary: "Detailed summary",
            soWhat: "Why it matters",
            storedAt: "2026-04-01T10:00:00.000Z",
            link: "https://example.com/bill",
            actions: [],
            committees: [],
            lifeAreas: [],
            billStatus: .new,
            guid: "BILLS-119hr123ih",
            congress: "119",
            billType: "hr",
            billID: "123",
            sponsorMemberID: nil,
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            isPriority: false,
            priorityRank: nil,
            priorityReason: nil,
            priorityExpiresAt: nil,
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil,
            officialVotes: nil,
            isProcessedDetailHydrated: true
        )

        let merged = BillsStore.mergedBillPreservingExistingContext(incoming: hydrated, existing: existing)

        XCTAssertEqual(merged.storedAt, existing.storedAt)
        XCTAssertEqual(merged.category, existing.category)
        XCTAssertEqual(merged.subCategory, existing.subCategory)
        // The processed bill's life areas replace the cached ones, even none (UX-29, project decision
        // 2026-10-28; this test used to pin the union, which kept "Environment").
        XCTAssertEqual(merged.lifeAreas, [])
        XCTAssertEqual(merged.billStatus, .updated)
        XCTAssertEqual(merged.summary, hydrated.summary)
        XCTAssertEqual(merged.link, hydrated.link)
        XCTAssertTrue(merged.isPriority)
        XCTAssertEqual(merged.priorityRank, existing.priorityRank)
        XCTAssertEqual(merged.isProcessedDetailHydrated, true)
    }

    @MainActor
    func testMergedBillPrefersNewerManifestMetadataWhileKeepingHydratedDetail() {
        let billID = UUID(uuidString: "00000000-0000-0000-0000-000000000124")!
        let hydrated = Bill(
            id: billID,
            title: "Water Infrastructure Act",
            category: "Energy",
            subCategory: "Water",
            summary: "Hydrated summary",
            soWhat: "Hydrated so what",
            storedAt: "2026-04-07T10:00:00.000Z",
            link: "https://example.com/water",
            actions: [],
            committees: [],
            lifeAreas: ["Infrastructure"],
            billStatus: .new,
            guid: "BILLS-119s124is",
            congress: "119",
            billType: "s",
            billID: "124",
            sponsorMemberID: nil,
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            isPriority: false,
            priorityRank: nil,
            priorityReason: nil,
            priorityExpiresAt: nil,
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil,
            officialVotes: nil,
            isProcessedDetailHydrated: true
        )

        let manifest = Bill(
            id: billID,
            title: "Water Infrastructure Act",
            category: "Infrastructure",
            subCategory: "Water",
            summary: "",
            soWhat: "",
            storedAt: "2026-04-09T09:00:00.000Z",
            link: nil,
            actions: [],
            committees: [],
            lifeAreas: ["Infrastructure", "Environment"],
            billStatus: .updated,
            guid: "BILLS-119s124is",
            congress: "119",
            billType: "s",
            billID: "124",
            sponsorMemberID: nil,
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            isPriority: true,
            priorityRank: 1,
            priorityReason: "High signal",
            priorityExpiresAt: "2026-04-12T09:00:00.000Z",
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil,
            officialVotes: nil,
            isProcessedDetailHydrated: false
        )

        let merged = BillsStore.mergedBillPreservingExistingContext(incoming: manifest, existing: hydrated, source: .manifestRow)

        XCTAssertEqual(merged.storedAt, manifest.storedAt)
        XCTAssertEqual(merged.billStatus, .updated)
        XCTAssertEqual(merged.summary, hydrated.summary)
        XCTAssertEqual(merged.soWhat, hydrated.soWhat)
        XCTAssertEqual(merged.link, hydrated.link)
        XCTAssertTrue(merged.isPriority)
        XCTAssertEqual(merged.priorityRank, manifest.priorityRank)
        XCTAssertEqual(merged.lifeAreas, ["Environment", "Infrastructure"], "the manifest row's (UX-29)")
        // The manifest row is newer than the hydrated details, so they are fetched again on next open
        // (REL-31); until then the hydrated detail above stays.
        XCTAssertEqual(merged.isProcessedDetailHydrated, false)
    }

    // MARK: - Official votes and stale details (REL-31)

    private func chamberVote(_ yea: Int, _ nay: Int) -> Bill.OfficialChamberVote {
        Bill.OfficialChamberVote(
            yea: yea,
            nay: nay,
            present: 0,
            notVoting: 0,
            totalCounted: yea + nay,
            actionCode: nil,
            actionDate: nil,
            resultText: nil,
            memberDataAvailable: false,
            members: []
        )
    }

    private func officialVotes(house: Bill.OfficialChamberVote?, senate: Bill.OfficialChamberVote?) -> Bill.OfficialVotesBreakdown {
        Bill.OfficialVotesBreakdown(house: house, senate: senate, lastSyncedAt: nil, source: nil, completeness: nil)
    }

    private func repairBill(
        storedAt: String,
        officialVotes: Bill.OfficialVotesBreakdown?,
        link: String? = nil,
        isProcessedDetailHydrated: Bool?
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: "BILLS-119hr5334"),
            title: "Repaired bill",
            category: "Other",
            soWhat: "",
            storedAt: storedAt,
            link: link,
            billStatus: .passed,
            guid: "BILLS-119hr5334",
            userVoted: false,
            officialVotes: officialVotes,
            isProcessedDetailHydrated: isProcessedDetailHydrated
        )
    }

    @MainActor
    func testProcessedResponseReplacesTheCachedOfficialVotes() {
        // Cached before the repair: a Congressional Record page range read as a House tally.
        let cached = repairBill(
            storedAt: "2026-09-01T10:00:00.000Z",
            officialVotes: officialVotes(house: chamberVote(3111, 3112), senate: chamberVote(60, 40)),
            link: "https://example.test/bill",
            isProcessedDetailHydrated: true
        )
        XCTAssertEqual(cached.congressHouseYeaCount, 3111)

        let senateOnly = repairBill(
            storedAt: "2026-09-24T10:00:00.000Z",
            officialVotes: officialVotes(house: nil, senate: chamberVote(60, 40)),
            isProcessedDetailHydrated: true
        )
        let merged = BillsStore.mergedBillPreservingExistingContext(incoming: senateOnly, existing: cached)
        XCTAssertNil(merged.officialVotes?.house)
        XCTAssertNil(merged.congressHouseYeaCount, "no fallback to the cached House count")
        XCTAssertNil(merged.congressHouseNayCount)
        XCTAssertEqual(merged.congressSenateYeaCount, 60)
        XCTAssertEqual(merged.link, cached.link)

        let noVotes = repairBill(storedAt: "2026-09-24T10:00:00.000Z", officialVotes: nil, isProcessedDetailHydrated: true)
        let cleared = BillsStore.mergedBillPreservingExistingContext(incoming: noVotes, existing: cached)
        XCTAssertNil(cleared.officialVotes)
        XCTAssertNil(cleared.congressHouseYeaCount)
        XCTAssertNil(cleared.congressSenateNayCount)

        // A manifest placeholder carries no official votes: the cached ones stay.
        let placeholder = repairBill(storedAt: "2026-09-01T10:00:00.000Z", officialVotes: nil, isProcessedDetailHydrated: false)
        let kept = BillsStore.mergedBillPreservingExistingContext(incoming: placeholder, existing: cached)
        XCTAssertEqual(kept.officialVotes, cached.officialVotes)
        XCTAssertEqual(kept.congressHouseYeaCount, 3111)
    }

    @MainActor
    func testOnlyANewerManifestRowMarksHydratedDetailsStale() {
        let hydrated = repairBill(
            storedAt: "2026-09-01T10:00:00.000Z",
            officialVotes: nil,
            link: "https://example.test/bill",
            isProcessedDetailHydrated: true
        )
        func merged(placeholderStoredAt: String) -> Bill {
            BillsStore.mergedBillPreservingExistingContext(
                incoming: repairBill(storedAt: placeholderStoredAt, officialVotes: nil, isProcessedDetailHydrated: false),
                existing: hydrated
            )
        }

        XCTAssertEqual(merged(placeholderStoredAt: "2026-09-01T10:00:00.000Z").isProcessedDetailHydrated, true, "the same row")
        XCTAssertEqual(merged(placeholderStoredAt: "2026-08-01T10:00:00.000Z").isProcessedDetailHydrated, true, "an older row")
        let stale = merged(placeholderStoredAt: "2026-09-24T10:00:00.000Z")
        XCTAssertEqual(stale.isProcessedDetailHydrated, false)
        XCTAssertEqual(stale.link, hydrated.link, "the details stay until they are fetched again")

        // A bill cached before the flag existed counts as hydrated by its details.
        let legacy = repairBill(storedAt: "2026-09-01T10:00:00.000Z", officialVotes: nil, link: "https://example.test/bill", isProcessedDetailHydrated: nil)
        let legacyMerged = BillsStore.mergedBillPreservingExistingContext(
            incoming: repairBill(storedAt: "2026-09-01T10:00:00.000Z", officialVotes: nil, isProcessedDetailHydrated: false),
            existing: legacy
        )
        XCTAssertEqual(legacyMerged.isProcessedDetailHydrated, true)
    }

    @MainActor
    func testMergedBillPreservesRelatedMemberIDsAcrossHydration() {
        let sponsorID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let cosponsorID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let hydratedOnlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!

        let existing = Bill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
            title: "Grid Modernization Act",
            category: "Infrastructure",
            subCategory: "Energy",
            summary: "",
            soWhat: "",
            storedAt: "2026-04-18T08:00:00.000Z",
            link: nil,
            actions: [],
            committees: [],
            lifeAreas: [],
            billStatus: .new,
            guid: "BILLS-119hr8248",
            congress: "119",
            billType: "hr",
            billID: "8248",
            sponsorMemberID: sponsorID,
            relatedMemberIDs: [sponsorID, cosponsorID],
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            isPriority: false,
            priorityRank: nil,
            priorityReason: nil,
            priorityExpiresAt: nil,
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil,
            officialVotes: nil,
            isProcessedDetailHydrated: false
        )

        let hydrated = Bill(
            id: existing.id,
            title: existing.title,
            category: existing.category,
            subCategory: existing.subCategory,
            summary: "Detailed summary",
            soWhat: "Why it matters",
            storedAt: "2026-04-18T08:05:00.000Z",
            link: "https://example.com/grid",
            actions: [],
            committees: [],
            lifeAreas: [],
            billStatus: .new,
            guid: existing.guid,
            congress: existing.congress,
            billType: existing.billType,
            billID: existing.billID,
            sponsorMemberID: sponsorID,
            relatedMemberIDs: [sponsorID, hydratedOnlyID],
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            isPriority: false,
            priorityRank: nil,
            priorityReason: nil,
            priorityExpiresAt: nil,
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil,
            officialVotes: nil,
            isProcessedDetailHydrated: true
        )

        let merged = BillsStore.mergedBillPreservingExistingContext(incoming: hydrated, existing: existing)

        XCTAssertEqual(
            Set(merged.subscriptionMemberIDs),
            Set([sponsorID, cosponsorID, hydratedOnlyID])
        )
    }

    // MARK: - Renamed topics (LLM-10)

    /// A bill with every field set to a value other than its default.
    @MainActor
    private func fullyPopulatedBill(category: String, subCategory: String?) -> Bill {
        var bill = Bill(
            id: UUID.deterministic(from: "BILLS-119hr4242"),
            title: "Heritage Month Act",
            officialTitle: "To designate a heritage month, and for other purposes.",
            category: category,
            subCategory: subCategory,
            summary: "Summary.",
            soWhat: "So what.",
            billBreakdown: BillBreakdown(who: "Who", what: "What", how: "How", when: "When", where: "Where", why: "Why"),
            storedAt: "2026-09-30T12:00:00.000Z",
            link: "https://www.congress.gov/bill/119th-congress/house-bill/4242",
            actions: [
                Bill.BillAction(
                    actionCode: "8000",
                    actionDate: "2026-09-29",
                    text: "Passed House",
                    type: "Floor",
                    sourceSystem: Bill.BillAction.SourceSystem(code: 2, name: "House floor actions"),
                    committees: [Bill.BillAction.CommitteeRef(name: "Oversight", systemCode: "hsgo00", url: "https://example.com/c")]
                )
            ],
            committees: [
                Bill.BillCommittee(
                    chamber: "House",
                    name: "Oversight",
                    systemCode: "hsgo00",
                    type: "Standing",
                    url: "https://example.com/c",
                    activities: [Bill.BillCommittee.Activity(date: "2026-09-01", name: "Referred to")]
                )
            ],
            lifeAreas: ["Taxes"],
            billStatus: .passed,
            guid: "BILLS-119hr4242",
            congress: "119",
            billType: "hr",
            billID: "4242",
            sponsorMemberID: UUID.deterministic(from: "A000001"),
            relatedMemberIDs: [UUID.deterministic(from: "A000001"), UUID.deterministic(from: "B000002")],
            passedHouse: true,
            passedSenate: true,
            userVoted: true,
            userWatched: true,
            userVote: .nay,
            lastVotedAt: Date(timeIntervalSince1970: 1_790_000_123.5),
            userYeaCount: 3,
            userNayCount: 4,
            isPriority: true,
            priorityRank: 2,
            priorityReason: "In the news.",
            priorityExpiresAt: "2026-10-09T00:00:00.000Z",
            congressSenateNayCount: 41,
            officialVotes: officialVotes(house: chamberVote(231, 196), senate: chamberVote(60, 40)),
            isProcessedDetailHydrated: true
        )
        // Counts that differ from `officialVotes` (and one missing), as a cached bill can hold.
        bill.congressHouseYeaCount = nil
        bill.congressHouseNayCount = 190
        bill.congressSenateYeaCount = 59
        return bill
    }

    @MainActor
    private func jsonObject(_ bill: Bill) throws -> NSDictionary {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bill)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @MainActor
    func testCanonicalizingTopicsRenamesTheTopicAndKeepsEveryOtherField() throws {
        let legacy = fullyPopulatedBill(category: SubscriptionsConfig.categoryCulturalAndEthicalIssues, subCategory: "Identity Politics")

        let canonical = legacy.canonicalizingTopics()

        XCTAssertEqual(canonical.subCategory, "Heritage and Identity")
        XCTAssertEqual(canonical.category, SubscriptionsConfig.categoryCulturalAndEthicalIssues)
        XCTAssertNil(canonical.congressHouseYeaCount, "a missing count is not filled from officialVotes")
        XCTAssertEqual(canonical.congressHouseNayCount, 190)
        XCTAssertEqual(canonical.congressSenateYeaCount, 59)
        XCTAssertEqual(canonical.congressSenateNayCount, 41)

        let expected = try jsonObject(fullyPopulatedBill(
            category: SubscriptionsConfig.categoryCulturalAndEthicalIssues,
            subCategory: "Heritage and Identity"
        ))
        XCTAssertEqual(try jsonObject(canonical), expected, "only the topic changes")
    }

    @MainActor
    func testCanonicalizingTopicsMapsALegacyNameUsedAsTheCategory() {
        let bill = fullyPopulatedBill(category: "Social Justice", subCategory: nil)

        let canonical = bill.canonicalizingTopics()

        XCTAssertEqual(canonical.category, "Civil Rights and Liberties")
        XCTAssertNil(canonical.subCategory)
    }

    @MainActor
    func testCanonicalizingTopicsLeavesCurrentNamesAlone() throws {
        let current = fullyPopulatedBill(category: SubscriptionsConfig.categorySocialPolicy, subCategory: "Civil Rights and Liberties")

        XCTAssertEqual(try jsonObject(current.canonicalizingTopics()), try jsonObject(current))
        XCTAssertEqual(makeBill(category: "Other").canonicalizingTopics().category, "Other")
    }

    @MainActor
    func testPreferencesInterpreterReadsLegacyTopicFollowsUnderTheNewNames() {
        let summary = PreferencesInterpreter.summarize([
            PreferencesItem(subCategory: nil, preference: "Identity Politics", category: "Cultural and Ethical Issues", type: "Category"),
            PreferencesItem(subCategory: nil, preference: "Heritage and Identity", category: "Cultural and Ethical Issues", type: "Category"),
            PreferencesItem(subCategory: nil, preference: "Social Justice", category: "Social Policy", type: "Category"),
            PreferencesItem(subCategory: nil, preference: "Social Justice", category: nil, type: "Life Area")
        ])

        XCTAssertEqual(summary.subscribedSubCategories, ["Civil Rights and Liberties", "Heritage and Identity"])
        XCTAssertEqual(summary.subscribedLifeAreas, ["Social Justice"], "only topics are renamed")
    }

    func testPreferencesInterpreterParsesContentTypePreferences() {
        let preferences = [
            PreferencesItem(subCategory: nil, preference: BillContentTypePreference.bills.rawValue, category: "", type: "Content Type"),
            PreferencesItem(subCategory: nil, preference: BillContentTypePreference.otherResolutions.rawValue, category: "", type: "Content Type"),
        ]

        let summary = PreferencesInterpreter.summarize(preferences)

        XCTAssertEqual(summary.selectedBillContentTypes, [.bills, .otherResolutions])
    }

    func testUserProfileDefaultsContentTypesToAllEnabledWhenUnset() {
        let profile = UserProfile.placeholder()

        XCTAssertEqual(profile.selectedBillContentTypes, [])
        XCTAssertEqual(profile.effectiveSelectedBillContentTypes, Set(BillContentTypePreference.allCases))
    }

    func testFollowedMemberMakesBillEligibleForHomeQueue() {
        let followedMemberID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let profile = UserProfile(
            id: "user-1",
            email: "hello@example.com",
            district: "12",
            state: "NY",
            avatarName: nil,
            subscribedSubCategories: [],
            subscribedLifeAreas: [],
            subscribedMemberIDs: [followedMemberID],
            watchedBillGUIDs: [],
            selectedBillContentTypes: [.otherResolutions]
        )

        let bill = Bill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            title: "Recognize Black Maternal Health Week",
            category: "Other",
            subCategory: nil,
            summary: "",
            soWhat: "",
            storedAt: "2026-04-18T02:53:41.505Z",
            link: nil,
            actions: [],
            committees: [],
            lifeAreas: [],
            billStatus: .new,
            guid: "BILLS-119sres675",
            congress: "119",
            billType: "sres",
            billID: "675",
            sponsorMemberID: nil,
            relatedMemberIDs: [followedMemberID],
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            isPriority: false,
            priorityRank: nil,
            priorityReason: nil,
            priorityExpiresAt: nil,
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil,
            officialVotes: nil,
            isProcessedDetailHydrated: false
        )

        XCTAssertTrue(bill.matchesSubscribedMembers(profile))
        XCTAssertTrue(bill.matchesPriorityAwareFeedEligibility(profile))
        XCTAssertTrue(bill.matchesPriorityAwareSubscription(profile))
    }

    func testUserProfileUpdatingOnlyChangesRequestedFields() {
        let original = UserProfile(
            id: "user-1",
            email: "hello@example.com",
            district: "12",
            state: "NY",
            avatarName: "star",
            subscribedSubCategories: ["Education"],
            subscribedLifeAreas: ["Health"],
            subscribedMemberIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!],
            watchedBillGUIDs: ["BILLS-119hr1ih"],
            selectedBillContentTypes: [.bills]
        )

        let updated = original.updating(
            district: "13",
            watchedBillGUIDs: ["BILLS-119hr2ih"],
            selectedBillContentTypes: [.otherResolutions]
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.email, original.email)
        XCTAssertEqual(updated.district, "13")
        XCTAssertEqual(updated.state, original.state)
        XCTAssertEqual(updated.avatarName, original.avatarName)
        XCTAssertEqual(updated.subscribedSubCategories, original.subscribedSubCategories)
        XCTAssertEqual(updated.subscribedLifeAreas, original.subscribedLifeAreas)
        XCTAssertEqual(updated.subscribedMemberIDs, original.subscribedMemberIDs)
        XCTAssertEqual(updated.watchedBillGUIDs, ["BILLS-119hr2ih"])
        XCTAssertEqual(updated.selectedBillContentTypes, [.otherResolutions])
    }

    func testScopedStorageKeyUsesTrimmedScope() {
        XCTAssertEqual(ScopedStorageKey.make(base: "cache.key", scope: "  member-123  "), "cache.key.member-123")
        XCTAssertEqual(ScopedStorageKey.make(base: "cache.key", scope: "   "), "cache.key")
    }

    func testBillContentTypePreferenceMapsKnownBillTypes() {
        XCTAssertEqual(BillContentTypePreference.from(rawBillType: "house-bill"), .bills)
        XCTAssertEqual(BillContentTypePreference.from(rawBillType: "sjres"), .jointResolutions)
        XCTAssertEqual(BillContentTypePreference.from(rawBillType: "senate-resolution"), .otherResolutions)
    }

    func testBillContentTypePreferenceAllowsUnknownBillTypes() {
        let allowed = Set([BillContentTypePreference.bills])

        XCTAssertTrue(BillContentTypePreference.allows(rawBillType: nil, allowed: allowed))
        XCTAssertTrue(BillContentTypePreference.allows(rawBillType: "unknown-type", allowed: allowed))
    }

    func testWeeklyDigestTitleUsesEasternDateRange() {
        let title = WeeklyDigestDateFormatter.title(
            weekStart: easternDate(year: 2026, month: 3, day: 15),
            weekEnd: easternDate(year: 2026, month: 3, day: 21)
        )

        XCTAssertEqual(title, "Your Week in Congress | Mar 15\u{2013}21, 2026")
    }

    func testWeeklyDigestPublishedLabelIncludesEasternReleaseTime() {
        let publishedLabel = WeeklyDigestDateFormatter.publishedDate(
            easternDate(year: 2026, month: 3, day: 22, hour: 10)
        )

        XCTAssertEqual(publishedLabel, "Published Sunday, March 22 at 10:00 AM ET")
    }

    @MainActor
    func testWeeklyDigestContractMappingDefaultsSourceAndReadState() throws {
        let json = """
        {
          "id": "2026-03-22T10:00:00-04:00",
          "title": "Your Week in Congress | Mar 15-21, 2026",
          "summary": "One bill needs your attention, two representatives took action, and one more bill is worth a look.",
          "weekStart": "2026-03-15T00:00:00-04:00",
          "weekEnd": "2026-03-21T00:00:00-04:00",
          "publishedAt": "2026-03-22T10:00:00-04:00",
          "isRead": false,
          "stats": [
            {
              "id": "attention",
              "label": "Need attention",
              "value": "1",
              "accent": "attention"
            }
          ],
          "sections": [
            {
              "kind": "needs_attention",
              "title": "Needs Your Attention",
              "subtitle": "The highest-signal changes from the week.",
              "items": [
                {
                  "id": "bill|BILLS-119hr1ih",
                  "kind": "bill",
                  "title": "A Bill",
                  "eyebrow": "Updated Mar 20",
                  "summary": "A short summary.",
                  "detail": "A short detail.",
                  "reason": "You voted on this before",
                  "accent": "attention",
                  "billState": "updated",
                  "billGuid": "BILLS-119hr1ih",
                  "primaryMemberBioguideId": "a000360"
                }
              ]
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let dto = try decoder.decode(UserAPIContractsV1.WeeklyDigest.self, from: Data(json.utf8))
        let digest = try WeeklyDigest(dto: dto)

        XCTAssertEqual(digest.source, .remote)
        XCTAssertFalse(digest.isRead)
        XCTAssertEqual(digest.sections.first?.kind, .needsAttention)
        XCTAssertEqual(digest.sections.first?.items.first?.billState, .updated)
        XCTAssertEqual(digest.sections.first?.items.first?.primaryMemberBioguideID, "A000360")
    }

    @MainActor
    func testWeeklyDigestWindowBeforeSundayReleaseUsesPreviousDigest() {
        let window = WeeklyDigestStore.latestPublishedWindow(
            relativeTo: easternDate(year: 2026, month: 3, day: 22, hour: 9, minute: 59)
        )

        XCTAssertEqual(window.start, easternDate(year: 2026, month: 3, day: 8))
        XCTAssertEqual(window.end, easternDate(year: 2026, month: 3, day: 14))
        XCTAssertEqual(window.releaseAt, easternDate(year: 2026, month: 3, day: 15, hour: 10))
    }

    @MainActor
    func testWeeklyDigestWindowAtSundayReleaseUsesCurrentDigest() {
        let window = WeeklyDigestStore.latestPublishedWindow(
            relativeTo: easternDate(year: 2026, month: 3, day: 22, hour: 10)
        )

        XCTAssertEqual(window.start, easternDate(year: 2026, month: 3, day: 15))
        XCTAssertEqual(window.end, easternDate(year: 2026, month: 3, day: 21))
        XCTAssertEqual(window.releaseAt, easternDate(year: 2026, month: 3, day: 22, hour: 10))
    }

    func testWeeklyDigestNotificationSchedulingRequiresUnreadEnabledAndNewDigest() {
        let digest = makeDigest()

        XCTAssertTrue(
            WeeklyDigestStore.shouldScheduleNotification(
                for: digest,
                digestNotificationsEnabled: true,
                appNotificationsEnabled: true,
                lastNotifiedDigestID: nil
            )
        )

        XCTAssertFalse(
            WeeklyDigestStore.shouldScheduleNotification(
                for: digest,
                digestNotificationsEnabled: false,
                appNotificationsEnabled: true,
                lastNotifiedDigestID: nil
            )
        )

        XCTAssertFalse(
            WeeklyDigestStore.shouldScheduleNotification(
                for: digest,
                digestNotificationsEnabled: true,
                appNotificationsEnabled: false,
                lastNotifiedDigestID: nil
            )
        )

        XCTAssertFalse(
            WeeklyDigestStore.shouldScheduleNotification(
                for: digest,
                digestNotificationsEnabled: true,
                appNotificationsEnabled: true,
                lastNotifiedDigestID: digest.id
            )
        )

        XCTAssertFalse(
            WeeklyDigestStore.shouldScheduleNotification(
                for: makeDigest(isRead: true),
                digestNotificationsEnabled: true,
                appNotificationsEnabled: true,
                lastNotifiedDigestID: nil
            )
        )
    }

    func testPushNotificationPayloadRecognizesWeeklyDigestNotification() {
        let payload = PushNotificationPayload(
            userInfo: [
                "domain": "weekly_digest",
                "notificationType": "digest",
                "digestId": "2026-03-22T10:00:00-04:00"
            ]
        )

        XCTAssertTrue(payload.isWeeklyDigestRelevant)
        XCTAssertEqual(payload.normalizedDigestID, "2026-03-22T10:00:00-04:00")
        XCTAssertTrue(payload.allBillIds.isEmpty)
    }

    // MARK: - Helpers

    private func makeBill(
        id: UUID = UUID(),
        title: String = "Test Bill",
        category: String = "Test",
        summary: String = "",
        soWhat: String = "",
        billStatus: BillStatus = .new
    ) -> Bill {
        Bill(
            id: id,
            title: title,
            category: category,
            subCategory: nil,
            summary: summary,
            soWhat: soWhat,
            storedAt: nil,
            link: nil,
            actions: [],
            committees: [],
            lifeAreas: [],
            billStatus: billStatus,
            guid: nil,
            congress: nil,
            billType: nil,
            billID: nil,
            sponsorMemberID: nil,
            passedHouse: false,
            passedSenate: false,
            userVoted: false,
            userWatched: false,
            userVote: nil,
            lastVotedAt: nil,
            userYeaCount: 0,
            userNayCount: 0,
            congressHouseYeaCount: nil,
            congressHouseNayCount: nil,
            congressSenateYeaCount: nil,
            congressSenateNayCount: nil
        )
    }

    private func easternDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WeeklyDigestSchedule.timeZone

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.timeZone = WeeklyDigestSchedule.timeZone

        return try! XCTUnwrap(calendar.date(from: components))
    }

    private func makeDigest(
        id: String = "2026-03-22T10:00:00-04:00",
        isRead: Bool = false
    ) -> WeeklyDigest {
        WeeklyDigest(
            id: id,
            title: "Your Week in Congress | Mar 15-21, 2026",
            summary: "One bill needs your attention this week.",
            weekStart: easternDate(year: 2026, month: 3, day: 15),
            weekEnd: easternDate(year: 2026, month: 3, day: 21),
            publishedAt: easternDate(year: 2026, month: 3, day: 22, hour: 10),
            source: .remote,
            isRead: isRead,
            stats: [],
            sections: []
        )
    }
}
