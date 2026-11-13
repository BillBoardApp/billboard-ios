import Amplify
import SwiftUI
import XCTest
@testable import Billboard

/// The topic picker (spec D 2.5.6, 2.5.7): after the first vote it is seeded from the voted bill
/// (its topic and life areas selected, its topic group open), from Profile it shows what the profile
/// follows; names are always current (LLM-10), so a save never sends a legacy name. The Profile save
/// (`UserStore.updateFollowedTopics`) is checked against a recording preferences fake.
@MainActor
final class TopicPickerModelTests: XCTestCase {
    private let civilRights = SubscriptionsConfig.subCivilRightsAndLiberties
    private let heritage = SubscriptionsConfig.subHeritageAndIdentity

    // MARK: - The first-vote prompt's Save (spec 3.16)

    /// Save is disabled until something is chosen (a topic, a life area, or a new party), and while it is it
    /// says what is missing on a caption line under it, read as its hint, as every other disabled primary
    /// does. A seed bill without a known topic leaves nothing chosen.
    func testTheFirstVoteSaveSaysWhatIsMissingWhileDisabled() throws {
        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let host = AccessibilityTreeText.Host(
            NavigationStack { TopicPickerView(context: .firstVote(seedBill: nil)) {} }.environmentObject(store),
            size: CGSize(width: 402, height: 874)
        )
        defer { host.close() }
        host.run(0.5)
        XCTAssertEqual(TopicPickerView.firstVoteSaveHint, "Choose a topic or life area to continue.")
        XCTAssertEqual(host.traits(of: "Save")?.contains(.notEnabled), true, host.text())
        XCTAssertEqual(host.hint(of: "Save"), TopicPickerView.firstVoteSaveHint)
        XCTAssertTrue(host.text().contains(TopicPickerView.firstVoteSaveHint), "the caption line: \(host.text())")

        let lifeArea = try XCTUnwrap(TopicPickerModel.lifeAreas.first)
        XCTAssertTrue(host.activate(lifeArea, settle: 0.4), host.text())
        XCTAssertEqual(host.traits(of: "Save")?.contains(.notEnabled), false, "a life area is chosen")
        XCTAssertNil(host.hint(of: "Save"))
        XCTAssertFalse(host.text().contains(TopicPickerView.firstVoteSaveHint), host.text())
    }

    // MARK: - Group chevron (spec 3.18, 5.2)

    /// The chevron turns 180° over 0.2 s as a group opens; with Reduce Motion nothing turns: the group opens at
    /// once and the symbol is `chevron.up` while it is open.
    func testGroupChevronTurnsOnlyWithoutReduceMotion() {
        XCTAssertEqual(TopicGroupChevron.symbolName(isExpanded: false, reduceMotion: false), "chevron.down")
        XCTAssertEqual(TopicGroupChevron.symbolName(isExpanded: true, reduceMotion: false), "chevron.down")
        XCTAssertEqual(TopicGroupChevron.rotation(isExpanded: false, reduceMotion: false).degrees, 0)
        XCTAssertEqual(TopicGroupChevron.rotation(isExpanded: true, reduceMotion: false).degrees, 180)
        XCTAssertEqual(TopicGroupChevron.animation(reduceMotion: false), .easeInOut(duration: 0.2))

        XCTAssertEqual(TopicGroupChevron.symbolName(isExpanded: false, reduceMotion: true), "chevron.down")
        XCTAssertEqual(TopicGroupChevron.symbolName(isExpanded: true, reduceMotion: true), "chevron.up")
        for isExpanded in [false, true] {
            XCTAssertEqual(TopicGroupChevron.rotation(isExpanded: isExpanded, reduceMotion: true).degrees, 0, "no rotation")
        }
        XCTAssertNil(TopicGroupChevron.animation(reduceMotion: true), "opens at once")
    }

    // MARK: - Groups

    func testGroupsAreTheSevenTopicGroupsInOrderWithCurrentNamesOnly() {
        XCTAssertEqual(TopicPickerModel.groups.map(\.name), SubscriptionsConfig.allCategories)
        XCTAssertEqual(TopicPickerModel.groups.count, 7)
        let topics = TopicPickerModel.groups.flatMap(\.topics)
        XCTAssertEqual(topics, SubscriptionsConfig.allCategories.flatMap { SubscriptionsConfig.subcategoryGroups[$0] ?? [] })
        XCTAssertEqual(Set(topics), Set(SubscriptionsConfig.allSubcategories))
        XCTAssertEqual(topics.count, 31)
        XCTAssertFalse(topics.contains(SubscriptionsConfig.legacyTopicSocialJustice))
        XCTAssertFalse(topics.contains(SubscriptionsConfig.legacyTopicIdentityPolitics))
        XCTAssertEqual(TopicPickerModel.lifeAreas, SubscriptionsConfig.allLifeAreas)
    }

    // MARK: - First vote

    func testFirstVoteSeedsTheBillsTopicLifeAreasAndOpensItsGroup() {
        let model = TopicPickerModel.firstVote(seedBill: bill(
            category: SubscriptionsConfig.categorySocialPolicy,
            subCategory: SubscriptionsConfig.subHousing,
            lifeAreas: [SubscriptionsConfig.lifeTaxes, "utility bills", "Not A Life Area"]
        ))
        XCTAssertEqual(model.selectedTopics, [SubscriptionsConfig.subHousing])
        XCTAssertEqual(model.selectedLifeAreas, [SubscriptionsConfig.lifeTaxes, SubscriptionsConfig.lifeUtilityBills], "listed life areas only, matched ignoring case")
        XCTAssertEqual(model.expandedGroups, [SubscriptionsConfig.categorySocialPolicy], "the other groups start closed")
        XCTAssertTrue(model.hasSelection)
        XCTAssertFalse(model.hasChanges, "seeding is not a change")
    }

    func testFirstVoteSeedWithALegacyTopicUsesTheNewName() {
        let model = TopicPickerModel.firstVote(seedBill: bill(
            category: SubscriptionsConfig.categoryCulturalAndEthicalIssues,
            subCategory: " identity politics "
        ))
        XCTAssertEqual(model.selectedTopics, [heritage])
        XCTAssertEqual(model.expandedGroups, [SubscriptionsConfig.categoryCulturalAndEthicalIssues])
        XCTAssertEqual(model.topicsToSave, [heritage])
    }

    func testFirstVoteWithoutAKnownTopicOpensTheBillsGroupOrNothing() {
        let groupOnly = TopicPickerModel.firstVote(seedBill: bill(category: SubscriptionsConfig.categoryEconomicPolicy, subCategory: "Something New"))
        XCTAssertTrue(groupOnly.selectedTopics.isEmpty)
        XCTAssertEqual(groupOnly.expandedGroups, [SubscriptionsConfig.categoryEconomicPolicy])

        let none = TopicPickerModel.firstVote(seedBill: nil)
        XCTAssertTrue(none.selectedTopics.isEmpty)
        XCTAssertTrue(none.selectedLifeAreas.isEmpty)
        XCTAssertTrue(none.expandedGroups.isEmpty)
        XCTAssertFalse(none.hasSelection)
    }

    // MARK: - Profile

    func testProfileSeedsWhatItFollowsWithCurrentNamesAndOpensThoseGroups() {
        let profile = UserProfile.placeholder().updating(
            id: "user",
            subscribedSubCategories: [SubscriptionsConfig.legacyTopicSocialJustice, SubscriptionsConfig.subEnergy],
            subscribedLifeAreas: [SubscriptionsConfig.lifeHomeEnergy]
        )
        let model = TopicPickerModel.profile(profile)
        XCTAssertEqual(model.selectedTopics, [civilRights, SubscriptionsConfig.subEnergy])
        XCTAssertEqual(model.selectedLifeAreas, [SubscriptionsConfig.lifeHomeEnergy])
        XCTAssertEqual(model.expandedGroups, [SubscriptionsConfig.categorySocialPolicy, SubscriptionsConfig.categoryEnvironmentalAndEnergyPolicy])
        XCTAssertFalse(model.hasChanges)
    }

    func testTogglingAndSaveLists() {
        var model = TopicPickerModel.profile(UserProfile.placeholder().updating(
            id: "user",
            subscribedSubCategories: [SubscriptionsConfig.subEnergy, "An Old Unlisted Topic"]
        ))

        model.toggle(topic: SubscriptionsConfig.legacyTopicSocialJustice)
        XCTAssertTrue(model.isSelected(topic: civilRights), "a legacy name toggles its new name")
        model.toggle(topic: SubscriptionsConfig.subFiscalPolicy)
        model.toggle(topic: SubscriptionsConfig.subEnergy)
        model.toggle(lifeArea: SubscriptionsConfig.lifeTaxes)
        XCTAssertTrue(model.hasChanges)

        XCTAssertEqual(
            model.topicsToSave,
            [SubscriptionsConfig.subFiscalPolicy, civilRights, "An Old Unlisted Topic"],
            "picker order, then a followed value the picker does not list (kept, so it is not deleted)"
        )
        XCTAssertEqual(model.lifeAreasToSave, [SubscriptionsConfig.lifeTaxes])
        for name in SubscriptionsConfig.legacyTopicAliases.keys {
            XCTAssertFalse(model.topicsToSave.contains(name), name)
        }

        let socialPolicy = TopicPickerModel.groups.first { $0.name == SubscriptionsConfig.categorySocialPolicy }!
        XCTAssertEqual(model.selectedCount(in: socialPolicy), 1)
        model.toggleExpansion(of: socialPolicy)
        model.toggleExpansion(of: socialPolicy)
        XCTAssertEqual(model.isExpanded(socialPolicy), false, "closed, open, closed")

        model.toggle(topic: civilRights)
        model.toggle(topic: SubscriptionsConfig.subFiscalPolicy)
        model.toggle(topic: SubscriptionsConfig.subEnergy)
        model.toggle(lifeArea: SubscriptionsConfig.lifeTaxes)
        XCTAssertFalse(model.hasChanges, "back where it started")
    }

    func testGroupOfTopicAcceptsLegacyNames() {
        XCTAssertEqual(TopicPickerModel.group(ofTopic: SubscriptionsConfig.legacyTopicSocialJustice), SubscriptionsConfig.categorySocialPolicy)
        XCTAssertEqual(TopicPickerModel.group(ofTopic: heritage), SubscriptionsConfig.categoryCulturalAndEthicalIssues)
        XCTAssertNil(TopicPickerModel.group(ofTopic: "Nope"))
    }

    // MARK: - Saving (UserStore)

    func testProfileSaveAddsThenDeletesTheDifferenceWithCurrentNames() async throws {
        let preferences = StaticPreferencesService(items:
            PreferencesMutations.categoryItems(for: [civilRights, SubscriptionsConfig.subEnergy])
            + PreferencesMutations.lifeAreaItems(for: [SubscriptionsConfig.lifeTaxes])
        )
        let store = await makeStore(preferences: preferences)
        XCTAssertEqual(Set(store.profile.subscribedSubCategories), [civilRights, SubscriptionsConfig.subEnergy], "precondition")

        try await store.updateFollowedTopics(
            topics: [SubscriptionsConfig.legacyTopicSocialJustice, SubscriptionsConfig.subHousing],
            lifeAreas: [SubscriptionsConfig.lifeTaxes, SubscriptionsConfig.lifeMedicalCosts]
        )

        XCTAssertEqual(preferences.putCalls.count, 1)
        XCTAssertEqual(
            Set(preferences.putCalls[0].map(\.value)),
            [SubscriptionsConfig.subHousing, SubscriptionsConfig.lifeMedicalCosts],
            "the legacy name is the topic already followed, so it is not added again"
        )
        XCTAssertEqual(preferences.deleteCalls.count, 1)
        XCTAssertEqual(preferences.deleteCalls[0].map(\.value), [SubscriptionsConfig.subEnergy])
        let written = (preferences.putCalls + preferences.deleteCalls).flatMap { $0 }.map(\.value)
        for legacy in SubscriptionsConfig.legacyTopicAliases.keys {
            XCTAssertFalse(written.contains(legacy), "never sent: a DELETE with an old name removes the new row too")
        }
        XCTAssertEqual(store.profile.subscribedSubCategories, [civilRights, SubscriptionsConfig.subHousing])
        XCTAssertEqual(store.profile.subscribedLifeAreas, [SubscriptionsConfig.lifeMedicalCosts, SubscriptionsConfig.lifeTaxes])
    }

    func testProfileSaveWithNoChangeWritesNothing() async throws {
        let preferences = StaticPreferencesService(items: PreferencesMutations.categoryItems(for: [heritage]))
        let store = await makeStore(preferences: preferences)
        try await store.updateFollowedTopics(topics: [SubscriptionsConfig.legacyTopicIdentityPolitics], lifeAreas: [])
        XCTAssertTrue(preferences.putCalls.isEmpty)
        XCTAssertTrue(preferences.deleteCalls.isEmpty)
    }

    func testFailedSaveRestoresTheProfileAndThrows() async {
        let preferences = StaticPreferencesService(items: PreferencesMutations.categoryItems(for: [heritage]))
        preferences.putError = URLError(.notConnectedToInternet)
        let store = await makeStore(preferences: preferences)

        do {
            try await store.updateFollowedTopics(topics: [heritage, SubscriptionsConfig.subHousing], lifeAreas: [SubscriptionsConfig.lifeTaxes])
            XCTFail("expected the save to throw")
        } catch {
            XCTAssertEqual(store.profile.subscribedSubCategories, [heritage])
            XCTAssertEqual(store.profile.subscribedLifeAreas, [])
            XCTAssertEqual(store.errorMessage, "Couldn't update the topics you follow.")
        }
    }

    func testFirstVoteSaveSendsCurrentNamesOnly() async throws {
        let preferences = StaticPreferencesService(items: [])
        let store = await makeStore(preferences: preferences)
        try await store.setInitialPreferences(
            subCategories: [SubscriptionsConfig.legacyTopicSocialJustice, civilRights],
            lifeAreas: [SubscriptionsConfig.lifeTaxes]
        )
        XCTAssertEqual(preferences.putCalls.count, 1)
        XCTAssertEqual(preferences.putCalls[0].filter { $0.kind == .topic }.map(\.value), [civilRights])
        XCTAssertEqual(store.profile.subscribedSubCategories, [civilRights])
    }

    /// Spec D 2.5.2: an account whose sign-up age answer could not be resent yet (server status
    /// unknown, answer stored on this device) is never asked its age again and goes through setup,
    /// the tour and the first-vote topic prompt. The server accepts its writes, so Save works.
    func testTopicsSaveWhileTheSignUpAgeAnswerWaitsToBeResent() async throws {
        let email = "pending-\(UUID().uuidString)@example.com"
        let answers = makeAdultAnswerStore()
        answers.saveAdultAnswer(email: email)
        let preferences = StaticPreferencesService(items: [])
        let store = await makeStore(preferences: preferences, adultStatus: "unknown", email: email, adultAnswers: answers)
        XCTAssertFalse(store.canPerformUserWrites, "precondition: the age answer has not reached the server")
        XCTAssertTrue(store.canSaveFollowedTopics)

        try await store.setInitialPreferences(subCategories: [civilRights], lifeAreas: [])
        try await store.updateFollowedTopics(topics: [civilRights, SubscriptionsConfig.subHousing], lifeAreas: [])
        XCTAssertEqual(preferences.putCalls.count, 2)
        XCTAssertEqual(store.profile.subscribedSubCategories, [civilRights, SubscriptionsConfig.subHousing])
    }

    func testTopicsAreNotSavedWithoutAnAgeAnswer() async {
        let email = "none-\(UUID().uuidString)@example.com"
        let answers = makeAdultAnswerStore()
        let preferences = StaticPreferencesService(items: [])
        let store = await makeStore(preferences: preferences, adultStatus: "unknown", email: email, adultAnswers: answers)
        XCTAssertFalse(store.canSaveFollowedTopics)

        let unknown = Data(#"{"adultStatus":"unknown","deletionStatus":"not_requested","canWrite":false}"#.utf8)
        let client = APIClient(transport: { _ in unknown })
        do {
            try await APIClient.$current.withValue(client) {
                try await store.updateFollowedTopics(topics: [civilRights], lifeAreas: [])
            }
            XCTFail("expected the save to be refused")
        } catch {
            XCTAssertTrue(preferences.putCalls.isEmpty)
        }

        let underage = await makeStore(preferences: preferences, adultStatus: "self_reported_under18", email: email, adultAnswers: answers)
        answers.saveAdultAnswer(email: email)
        XCTAssertFalse(underage.canSaveFollowedTopics, "the server refuses an under-18 account")
    }

    // MARK: - Helpers

    private func makeAdultAnswerStore() -> AdultAnswerStore {
        let suiteName = "topic-picker-tests-answers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AdultAnswerStore(defaults: defaults)
    }

    private func bill(category: String, subCategory: String?, lifeAreas: [String] = []) -> Bill {
        Bill(
            title: "A bill",
            category: category,
            subCategory: subCategory,
            soWhat: "",
            lifeAreas: lifeAreas,
            billStatus: .new,
            guid: "BILLS-119hr1ih",
            userVoted: false
        )
    }

    /// An account with the location set (adult unless `adultStatus` says otherwise), refreshed with
    /// `preferences`.
    private func makeStore(
        preferences: StaticPreferencesService,
        adultStatus: String = "attested_adult",
        email: String? = nil,
        adultAnswers: AdultAnswerStore? = nil
    ) async -> UserStore {
        let userId = "topic-picker-tests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            UserStore.clearCachedProfile(userId: userId)
            UserDefaults.standard.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        }
        let store = UserStore(
            preferencesService: preferences,
            congressService: FakeCongressService(),
            adultAnswerStore: adultAnswers ?? makeAdultAnswerStore()
        )
        let canWrite = adultStatus == "attested_adult"
        let me = Data(#"{"adultStatus":"\#(adultStatus)","deletionStatus":"not_requested","canWrite":\#(canWrite)}"#.utf8)
        let client = APIClient(transport: { _ in me })
        var attributes = [
            AuthUserAttribute(.custom("state"), value: "VA"),
            AuthUserAttribute(.custom("district"), value: "11")
        ]
        if let email {
            attributes.append(AuthUserAttribute(.email, value: email))
        }
        await APIClient.$current.withValue(client) {
            await store.refresh(userId: userId, attributes: attributes)
        }
        return store
    }
}
