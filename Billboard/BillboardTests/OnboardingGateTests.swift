import Amplify
import XCTest
@testable import Billboard

/// What a signed-in launch shows before the tabs (spec D 2.5.1-2.5.3): "Where do you vote?" only
/// while the profile has no state or district (topics no longer count), the age gate only for an
/// account with no answer on the server and none stored on the device, and the loading screen while a
/// stored sign-up answer is resent. No network: `GET /me` and the preferences come from fakes.
@MainActor
final class OnboardingGateTests: XCTestCase {
    // MARK: - needsLocationSetup

    func testLocationSetupTruthTable() {
        let cases: [(state: String, district: String, topics: [String], lifeAreas: [String], members: [UUID], expected: Bool)] = [
            ("", "", [], [], [], true),
            ("VA", "", [], [], [], true),
            ("", "11", [], [], [], true),
            ("  ", "11", ["Healthcare"], [], [], true),
            ("VA", "  ", [], ["Taxes"], [], true),
            ("VA", "11", [], [], [], false),
            ("VA", "11", ["Healthcare"], [], [], false),
            ("VA", "11", [], ["Taxes"], [], false),
            ("AK", "At-Large", [], [], [UUID()], false),
            ("", "", ["Healthcare"], ["Taxes"], [UUID()], true)
        ]
        for testCase in cases {
            let profile = UserProfile.placeholder().updating(
                id: "user",
                state: testCase.state,
                district: testCase.district,
                subscribedSubCategories: testCase.topics,
                subscribedLifeAreas: testCase.lifeAreas,
                subscribedMemberIDs: testCase.members
            )
            XCTAssertEqual(OnboardingGate.needsLocationSetup(profile), testCase.expected, "\(testCase)")
        }
    }

    // MARK: - SignedInGate

    private func gate(
        refreshed: Bool = true,
        requiresAdult: Bool = false,
        stored: Bool = false,
        retry: SignedInGate.AdultAnswerRetryState = .notStarted,
        underage: Bool = false,
        setup: Bool = false,
        completing: Bool = false,
        noLocation: Bool = false
    ) -> SignedInGate.Screen {
        SignedInGate(
            hasRefreshedOnce: refreshed,
            requiresAdultAnswer: requiresAdult,
            hasStoredAdultAnswer: stored,
            adultAnswerRetry: retry,
            isUnderageBlocked: underage,
            shouldShowLocationSetup: setup,
            isCompletingLocationSetup: completing,
            lacksLocation: noLocation
        ).screen
    }

    func testLoadingUntilTheFirstRefreshFinishes() {
        XCTAssertEqual(gate(refreshed: false), .loading)
        XCTAssertEqual(gate(refreshed: false, requiresAdult: true, underage: true, setup: true), .loading)
        XCTAssertEqual(gate(), .tabs)
    }

    func testAgeGateOnlyWithoutAStoredAnswer() {
        XCTAssertEqual(gate(requiresAdult: true, stored: false), .ageGate, "an account from before R2, or another device")
        XCTAssertEqual(gate(requiresAdult: true, stored: false, retry: .finished), .ageGate)
        XCTAssertEqual(gate(requiresAdult: true, stored: false, setup: true), .ageGate, "the age comes before the location")
    }

    func testStoredAnswerShowsLoadingWhileItIsResentAndNeverTheGate() {
        XCTAssertEqual(gate(requiresAdult: true, stored: true, retry: .notStarted), .loading)
        XCTAssertEqual(gate(requiresAdult: true, stored: true, retry: .running), .loading)
        // Every attempt failed: no second question; the account carries on without writes and the
        // next launch tries again.
        XCTAssertEqual(gate(requiresAdult: true, stored: true, retry: .finished), .tabs)
        XCTAssertEqual(gate(requiresAdult: true, stored: true, retry: .finished, setup: true), .locationSetup)
    }

    /// A new account whose stored sign-up answer could not be resent: writes look disallowed, so
    /// `shouldShowOnboarding` is false, but the server accepts this account's writes. It still gets
    /// "Where do you vote?" (and the tour after it) instead of tabs with no district.
    func testAFailedResendStillGetsWhereDoYouVote() {
        XCTAssertEqual(gate(requiresAdult: true, stored: true, retry: .finished, noLocation: true), .locationSetup)
        XCTAssertEqual(gate(requiresAdult: true, stored: true, retry: .running, noLocation: true), .loading, "still waits for the resend")
        XCTAssertEqual(gate(requiresAdult: true, stored: false, noLocation: true), .ageGate, "no stored answer: the age comes first")
        XCTAssertEqual(gate(requiresAdult: true, stored: true, retry: .finished, underage: true, noLocation: true), .ineligible)
        XCTAssertEqual(gate(noLocation: true), .tabs, "an answered account follows shouldShowOnboarding")
    }

    func testAnAccountWithNoServerAnswerAndNoLocationLacksALocation() async {
        let (store, _) = await makeStore(
            attributes: [],
            preferences: [],
            me: #"{"adultStatus":"unknown","deletionStatus":"not_requested","canWrite":false}"#
        )
        XCTAssertTrue(store.requiresAdultAttestation)
        XCTAssertFalse(store.canPerformUserWrites)
        XCTAssertFalse(store.shouldShowOnboarding, "precondition: the write check hides the setup")
        XCTAssertTrue(store.lacksLocationAfterRefresh)

        let (located, _) = await makeStore(
            attributes: [AuthUserAttribute(.custom("state"), value: "VA"), AuthUserAttribute(.custom("district"), value: "11")],
            preferences: [],
            me: #"{"adultStatus":"unknown","deletionStatus":"not_requested","canWrite":false}"#
        )
        XCTAssertFalse(located.lacksLocationAfterRefresh)
    }

    func testUnderageAndLocationSetup() {
        XCTAssertEqual(gate(underage: true), .ineligible)
        XCTAssertEqual(gate(underage: true, setup: true), .ineligible)
        XCTAssertEqual(gate(setup: true), .locationSetup)
        XCTAssertEqual(gate(completing: true), .locationSetup, "setup holds itself through its success panel")
        XCTAssertEqual(gate(setup: false, completing: false), .tabs)
    }

    // MARK: - UserStore

    func testAProfileWithALocationButNoTopicsGoesStraightToTheTabs() async {
        let (store, _) = await makeStore(
            attributes: [
                AuthUserAttribute(.custom("state"), value: "VA"),
                AuthUserAttribute(.custom("district"), value: "11")
            ],
            preferences: []
        )
        XCTAssertTrue(store.profile.subscribedSubCategories.isEmpty, "precondition: no topics")
        XCTAssertFalse(store.needsOnboarding)
        XCTAssertFalse(store.shouldShowOnboarding, "topics are asked after the first vote, not at setup")
    }

    func testAProfileWithTopicsButNoLocationGetsTheSetup() async {
        let (store, _) = await makeStore(
            attributes: [AuthUserAttribute(.custom("state"), value: "VA")],
            preferences: PreferencesMutations.categoryItems(for: [SubscriptionsConfig.subHealthcare])
        )
        XCTAssertEqual(store.profile.subscribedSubCategories, [SubscriptionsConfig.subHealthcare])
        XCTAssertTrue(store.needsOnboarding)
        XCTAssertTrue(store.shouldShowOnboarding)
    }

    func testAgeQuestionNeedsTheServersAnswerNotAFailedLookup() async {
        // `GET /me` fails (offline): nothing is known, so no age gate.
        let (offline, _) = await makeStore(attributes: [], preferences: [], me: nil)
        XCTAssertTrue(offline.hasRefreshedOnce)
        XCTAssertFalse(offline.hasLoadedCompliance)
        XCTAssertEqual(offline.compliance.adultStatus, .unknown)
        XCTAssertFalse(offline.requiresAdultAttestation)

        // The server answers with no age answer: the gate (or a resend) is needed.
        let (unknown, _) = await makeStore(attributes: [], preferences: [], me: #"{"adultStatus":"unknown","deletionStatus":"not_requested","canWrite":false}"#)
        XCTAssertTrue(unknown.hasLoadedCompliance)
        XCTAssertTrue(unknown.requiresAdultAttestation)

        // Answered.
        let (adult, _) = await makeStore(attributes: [], preferences: [])
        XCTAssertFalse(adult.requiresAdultAttestation)
        XCTAssertTrue(adult.canPerformUserWrites)

        // Sign-out forgets that the server answered.
        adult.clearForSignOut()
        XCTAssertFalse(adult.hasLoadedCompliance)
        XCTAssertFalse(adult.requiresAdultAttestation)
    }

    func testCachedProfileWithALegacyTopicNameIsReadWithTheNewName() throws {
        let userId = "onboarding-gate-tests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in UserStore.clearCachedProfile(userId: userId) }

        let cached = UserProfile.placeholder().updating(
            id: userId,
            state: "VA",
            district: "11",
            subscribedSubCategories: [SubscriptionsConfig.legacyTopicSocialJustice, SubscriptionsConfig.subHousing]
        )
        UserProfileDiskCache.store(try JSONEncoder().encode(cached), userId: userId)

        let store = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        store.hydrateCachedProfileIfAvailable(userId: userId)

        XCTAssertEqual(store.profile.id, userId)
        XCTAssertEqual(
            Set(store.profile.subscribedSubCategories),
            [SubscriptionsConfig.subCivilRightsAndLiberties, SubscriptionsConfig.subHousing]
        )
        XCTAssertFalse(store.profile.subscribedSubCategories.contains(SubscriptionsConfig.legacyTopicSocialJustice))
    }

    // MARK: - Helpers

    /// A store refreshed through the bootstrap's fast path with `attributes`, `preferences` and a
    /// `GET /me` body (nil: the request fails). Caches it writes are removed in teardown.
    private func makeStore(
        attributes: [AuthUserAttribute],
        preferences: [PreferencesItem],
        me: String? = #"{"adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#
    ) async -> (UserStore, String) {
        let userId = "onboarding-gate-tests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            UserStore.clearCachedProfile(userId: userId)
            UserDefaults.standard.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        }
        let store = UserStore(preferencesService: StaticPreferencesService(items: preferences), congressService: FakeCongressService())
        let body = me.map { Data($0.utf8) }
        let client = APIClient(transport: { _ in
            guard let body else { throw URLError(.notConnectedToInternet) }
            return body
        })
        await APIClient.$current.withValue(client) {
            await store.refresh(userId: userId, attributes: attributes)
        }
        return (store, userId)
    }
}

/// Answers `GET /preferences` with fixed items and records writes.
@MainActor
final class StaticPreferencesService: PreferencesServicing {
    let items: [PreferencesItem]
    private(set) var putCalls: [[PreferencesItem]] = []
    private(set) var deleteCalls: [[PreferencesItem]] = []
    /// Thrown by `putPreferences` when set.
    var putError: Error?

    init(items: [PreferencesItem]) {
        self.items = items
    }

    func getPreferences() async throws -> [PreferencesItem] { items }

    func putPreferences(_ items: [PreferencesItem]) async throws {
        putCalls.append(items)
        if let putError { throw putError }
    }

    func deletePreferences(_ items: [PreferencesItem]) async throws {
        deleteCalls.append(items)
    }
}
