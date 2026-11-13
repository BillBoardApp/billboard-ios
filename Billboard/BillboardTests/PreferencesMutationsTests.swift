import XCTest
@testable import Billboard

/// `PreferencesMutations` computes which preference rows to add or delete and builds the
/// `PreferencesItem` payloads `UserStore` sends to the preferences API.
final class PreferencesMutationsTests: XCTestCase {
    // MARK: - diffStrings

    @MainActor
    func testDiffReportsAddedAndRemovedValuesSortedCaseInsensitively() {
        let diff = PreferencesMutations.diffStrings(
            previous: ["Housing", "Energy", "Taxes"],
            updated: ["Taxes", "Diplomacy", "banking", "Energy"]
        )

        XCTAssertEqual(diff.toAdd, ["banking", "Diplomacy"])
        XCTAssertEqual(diff.toRemove, ["Housing"])
    }

    @MainActor
    func testDiffIgnoresOrderAndDuplicates() {
        let diff = PreferencesMutations.diffStrings(previous: ["b", "a", "b"], updated: ["a", "b"])

        XCTAssertEqual(diff.toAdd, [])
        XCTAssertEqual(diff.toRemove, [])
    }

    @MainActor
    func testDiffFromEmptyAddsEverything() {
        let diff = PreferencesMutations.diffStrings(previous: [], updated: ["Zeta", "alpha", "Beta"])

        XCTAssertEqual(diff.toAdd, ["alpha", "Beta", "Zeta"])
        XCTAssertEqual(diff.toRemove, [])
    }

    @MainActor
    func testDiffToEmptyRemovesEverything() {
        let diff = PreferencesMutations.diffStrings(previous: ["Zeta", "alpha"], updated: [])

        XCTAssertEqual(diff.toAdd, [])
        XCTAssertEqual(diff.toRemove, ["alpha", "Zeta"])
    }

    @MainActor
    func testDiffTreatsCaseVariantsAsDifferentValues() {
        let diff = PreferencesMutations.diffStrings(previous: ["Taxes"], updated: ["taxes"])

        XCTAssertEqual(diff.toAdd, ["taxes"])
        XCTAssertEqual(diff.toRemove, ["Taxes"])
    }

    // MARK: - Item builders

    @MainActor
    func testCategoryItemsCarryTheParentCategory() {
        let items = PreferencesMutations.categoryItems(for: [SubscriptionsConfig.subFiscalPolicy])

        XCTAssertEqual(items, [
            PreferencesItem(
                subCategory: nil,
                preference: SubscriptionsConfig.subFiscalPolicy,
                category: SubscriptionsConfig.categoryEconomicPolicy,
                type: "Category"
            )
        ])
        XCTAssertEqual(items.first?.kind, .topic)
    }

    @MainActor
    func testCategoryItemsForUnknownTopicHaveNoCategory() {
        let items = PreferencesMutations.categoryItems(for: ["Not A Real Topic"])

        XCTAssertEqual(items, [
            PreferencesItem(subCategory: nil, preference: "Not A Real Topic", category: nil, type: "Category")
        ])
    }

    @MainActor
    func testCategoryItemsForTheRenamedTopicsCarryTheirGroups() {
        let items = PreferencesMutations.categoryItems(for: [
            SubscriptionsConfig.subCivilRightsAndLiberties,
            SubscriptionsConfig.subHeritageAndIdentity
        ])

        XCTAssertEqual(items, [
            PreferencesItem(
                subCategory: nil,
                preference: "Civil Rights and Liberties",
                category: SubscriptionsConfig.categorySocialPolicy,
                type: "Category"
            ),
            PreferencesItem(
                subCategory: nil,
                preference: "Heritage and Identity",
                category: SubscriptionsConfig.categoryCulturalAndEthicalIssues,
                type: "Category"
            )
        ])
    }

    @MainActor
    func testEveryPickerTopicIsWrittenUnderACurrentNameWithItsGroup() {
        for (group, topics) in SubscriptionsConfig.subcategoryGroups {
            let items = PreferencesMutations.categoryItems(for: topics)

            XCTAssertEqual(items.compactMap(\.preference), topics, group)
            XCTAssertEqual(Set(items.compactMap(\.category)), [group], group)
            XCTAssertFalse(items.contains { SubscriptionsConfig.isLegacyTopic($0.value) }, group)
        }
    }

    @MainActor
    func testDiffOfACanonicalizedProfileDoesNotRewriteARenamedFollow() {
        // A follow stored under the old name reads as the new name (PreferencesInterpreter), so keeping it
        // in the picker is not a change, and removing it deletes it by its new name (the server deletes
        // both rows, C2 3.8.2).
        let stored = PreferencesInterpreter.summarize([
            PreferencesItem(subCategory: nil, preference: "Social Justice", category: "Social Policy", type: "Category"),
            PreferencesItem(subCategory: nil, preference: "Housing", category: "Social Policy", type: "Category")
        ]).subscribedSubCategories

        let kept = PreferencesMutations.diffStrings(previous: stored, updated: ["Civil Rights and Liberties", "Housing"])
        XCTAssertEqual(kept.toAdd, [])
        XCTAssertEqual(kept.toRemove, [])

        let removed = PreferencesMutations.diffStrings(previous: stored, updated: ["Housing"])
        XCTAssertEqual(PreferencesMutations.categoryItems(for: removed.toRemove).map(\.preference), ["Civil Rights and Liberties"])
    }

    @MainActor
    func testLifeAreaItems() {
        let items = PreferencesMutations.lifeAreaItems(for: [SubscriptionsConfig.lifeTaxes])

        XCTAssertEqual(items, [
            PreferencesItem(subCategory: nil, preference: SubscriptionsConfig.lifeTaxes, category: nil, type: "Life Area")
        ])
        XCTAssertEqual(items.first?.kind, .lifeArea)
    }

    @MainActor
    func testCongressMemberItemValuePrefersTrimmedManifestId() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "8D3D6F85-0E3A-4B3C-9A5F-5B1B1E7E2C4A"))

        XCTAssertEqual(PreferencesMutations.congressMemberItemValue(manifestId: " A000360 ", uuid: uuid), "A000360")
        XCTAssertEqual(PreferencesMutations.congressMemberItemValue(manifestId: nil, uuid: uuid), uuid.uuidString)
        XCTAssertEqual(PreferencesMutations.congressMemberItemValue(manifestId: "   ", uuid: uuid), uuid.uuidString)
    }

    @MainActor
    func testCongressMemberItems() {
        let items = PreferencesMutations.congressMemberItems(values: ["A000360"])

        XCTAssertEqual(items, [
            PreferencesItem(subCategory: nil, preference: "A000360", category: "Congress", type: "Congress Member")
        ])
        XCTAssertEqual(items.first?.kind, .congressMember)
    }

    @MainActor
    func testWatchItems() {
        let items = PreferencesMutations.watchItems(for: ["BILLS-119hr1ih"])

        XCTAssertEqual(items, [
            PreferencesItem(subCategory: nil, preference: "BILLS-119hr1ih", category: "", type: "Watch")
        ])
        XCTAssertEqual(items.first?.kind, .watch)
    }

    @MainActor
    func testContentTypeItemsUseRawValues() {
        let items = PreferencesMutations.contentTypeItems(for: [.bills, .jointResolutions])

        XCTAssertEqual(items.map(\.preference), ["bills", "joint_resolutions"])
        XCTAssertEqual(items.map(\.type), ["Content Type", "Content Type"])
        XCTAssertEqual(items.map(\.kind), [.contentType, .contentType])
    }

    @MainActor
    func testBuildersPreserveInputOrderAndReturnEmptyForEmptyInput() {
        XCTAssertEqual(
            PreferencesMutations.lifeAreaItems(for: ["b", "a"]).map(\.preference),
            ["b", "a"]
        )
        XCTAssertTrue(PreferencesMutations.categoryItems(for: []).isEmpty)
        XCTAssertTrue(PreferencesMutations.watchItems(for: []).isEmpty)
    }
}
