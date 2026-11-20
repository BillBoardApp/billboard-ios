import SwiftUI
import XCTest
@testable import Billboard

/// Watch, Follow and the bill types change at once and then save. When the save fails the store puts the old value
/// back, and the control that started it shows and says so (UX-48): VoiceOver had already said the change worked. The
/// failure no longer goes to `UserStore.errorMessage`, which no screen showed and Updates read as "the profile didn't
/// load".
@MainActor
final class PreferenceSaveFailureTests: XCTestCase {
    private static let guid = "BILLS-119hr901"
    private static let memberID = "K000384"
    private static let offline = URLError(.notConnectedToInternet)

    /// The pages' own requests (the vote, the member) fail as offline.
    private static func offlineClient() -> APIClient {
        APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
    }

    func testTheWordsOfEachFailure() {
        XCTAssertEqual(BillWatchCopy.saveFailedText(isWatching: false), "Couldn't stop watching this bill.")
        XCTAssertEqual(BillWatchCopy.saveFailedText(isWatching: true), "Couldn't watch this bill.")
        XCTAssertEqual(CongressFollowToolbarButton.saveFailedText(isFollowing: true), "Couldn't follow this member.")
        XCTAssertEqual(CongressFollowToolbarButton.saveFailedText(isFollowing: false), "Couldn't unfollow this member.")
        XCTAssertEqual(CongressFollowedMembersSection.unfollowFailedText(memberName: "Tim Kaine"), "Couldn't unfollow Tim Kaine.")
        XCTAssertEqual(AppSettingsCopy.billTypeSaveFailedText(.jointResolutions, isOn: false), "Couldn't turn off joint resolutions.")
        XCTAssertEqual(AppSettingsCopy.billTypeSaveFailedText(.bills, isOn: true), "Couldn't turn on bills.")
    }

    // MARK: - The store reports to the caller, not the shared message

    func testAFailedFollowIsPutBackAndLeavesTheSharedMessageAlone() async {
        let preferences = FakePreferencesService()
        let user = await signedInUser(preferences)
        preferences.putError = Self.offline

        let saved = await user.toggleMemberSubscription(manifestId: Self.memberID).value

        XCTAssertFalse(saved)
        XCTAssertEqual(preferences.putCalls.count, 1, "the follow was sent")
        XCTAssertEqual(user.profile.subscribedMemberIDs, [], "and put back")
        XCTAssertNil(user.errorMessage, "Updates reads the shared message as a profile that didn't load")
    }

    func testAFailedUnfollowIsPutBackAndLeavesTheSharedMessageAlone() async {
        let preferences = FakePreferencesService()
        preferences.preferences = PreferencesMutations.congressMemberItems(values: [Self.memberID])
        let user = await signedInUser(preferences)
        let followed = [UUID.deterministic(from: Self.memberID)]
        XCTAssertEqual(user.profile.subscribedMemberIDs, followed, "precondition: the member is followed")
        preferences.deleteError = Self.offline

        let saved = await user.toggleMemberSubscription(manifestId: Self.memberID).value

        XCTAssertFalse(saved)
        XCTAssertEqual(user.profile.subscribedMemberIDs, followed, "followed again")
        XCTAssertNil(user.errorMessage)
    }

    func testAFailedBillTypesSaveIsPutBackAndLeavesTheSharedMessageAlone() async {
        let preferences = FakePreferencesService()
        let user = await signedInUser(preferences)
        preferences.putError = Self.offline

        let saved = await user.updateSelectedBillContentTypes([.bills, .otherResolutions]).value

        XCTAssertFalse(saved)
        XCTAssertEqual(user.profile.effectiveSelectedBillContentTypes, Set(BillContentTypePreference.allCases), "every type is on again")
        XCTAssertNil(user.errorMessage)
    }

    func testSavesThatWorkSaySo() async {
        let preferences = FakePreferencesService()
        let user = await signedInUser(preferences)

        let followed = await user.toggleMemberSubscription(manifestId: Self.memberID).value
        let types = await user.updateSelectedBillContentTypes([.bills]).value

        XCTAssertTrue(followed)
        XCTAssertTrue(types)
        XCTAssertEqual(user.profile.subscribedMemberIDs, [UUID.deterministic(from: Self.memberID)])
        XCTAssertEqual(user.profile.effectiveSelectedBillContentTypes, [.bills])
    }

    // MARK: - The bill page

    // The page tests are not async: a hosted page needs the main run loop, which an async test holds.

    /// Watch was on and the stop's save fails: the toggle is on again, and under it the page shows and says "Couldn't
    /// stop watching this bill." once.
    func testTheBillPageSaysAFailedStopUnderTheWatchRow() throws {
        let page = billPage(failing: true)
        let spoken = SpokenLines()
        try APIClient.$current.withValue(Self.offlineClient()) {
            let host = AccessibilityTreeText.Host(page.view.environment(\.announceToVoiceOver, spoken.announce), size: CGSize(width: 390, height: 5000), settle: 0.5)
            defer { host.close() }
            let watching = host.value(ofIdentifier: BillWatchCopy.rowIdentifier)
            let label = try XCTUnwrap(host.label(ofIdentifier: BillWatchCopy.rowIdentifier), host.text())
            XCTAssertNil(host.label(ofIdentifier: BillWatchCopy.errorIdentifier), "no error before the tap")

            XCTAssertTrue(host.activate(label), "the Watch row: \(host.text())")
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillWatchCopy.errorIdentifier) != nil }), host.text())

            XCTAssertEqual(host.label(ofIdentifier: BillWatchCopy.errorIdentifier), "Couldn't stop watching this bill.")
            XCTAssertEqual(spoken.lines, ["Couldn't stop watching this bill."])
            XCTAssertEqual(page.preferences.deleteCalls.count, 1, "the stop was sent")
            XCTAssertEqual(page.user.profile.watchedBillGUIDs, [Self.guid], "the watch is back")
            XCTAssertEqual(host.value(ofIdentifier: BillWatchCopy.rowIdentifier), watching, "the toggle shows it")
            XCTAssertNil(page.user.errorMessage)

            host.run(0.3)
            XCTAssertEqual(spoken.lines, ["Couldn't stop watching this bill."], "said once")
        }
    }

    func testTheBillPageSaysNothingMoreWhenTheStopSaves() throws {
        let page = billPage(failing: false)
        let spoken = SpokenLines()
        try APIClient.$current.withValue(Self.offlineClient()) {
            let host = AccessibilityTreeText.Host(page.view.environment(\.announceToVoiceOver, spoken.announce), size: CGSize(width: 390, height: 5000), settle: 0.5)
            defer { host.close() }
            let label = try XCTUnwrap(host.label(ofIdentifier: BillWatchCopy.rowIdentifier), host.text())

            XCTAssertTrue(host.activate(label), "the Watch row: \(host.text())")
            XCTAssertTrue(host.run(until: { page.preferences.deleteCalls.count == 1 }))
            host.run(0.3)

            XCTAssertNil(host.label(ofIdentifier: BillWatchCopy.errorIdentifier), host.text())
            XCTAssertEqual(spoken.lines, [])
            XCTAssertEqual(page.user.profile.watchedBillGUIDs, [])
        }
    }

    // MARK: - App settings, Congress, the member page

    /// A bill-type switch whose save fails is put back, and the line under the switches says which.
    func testAppSettingsSaysAFailedBillTypeUnderTheSwitches() throws {
        let preferences = FakePreferencesService()
        preferences.putError = Self.offline
        let user = UserStore(preferencesService: preferences, congressService: FakeCongressService())
        let spoken = SpokenLines()
        let host = AccessibilityTreeText.Host(
            NavigationStack { AppSettingsView() }
                .environmentObject(user)
                .environment(\.announceToVoiceOver, spoken.announce),
            size: CGSize(width: 390, height: 1600),
            settle: 0.3
        )
        defer { host.close() }
        let identifier = "settings.billType.\(BillContentTypePreference.jointResolutions.rawValue)"
        let switchLabel = try XCTUnwrap(host.label(ofIdentifier: identifier), host.text())
        let on = host.value(ofIdentifier: identifier)

        XCTAssertTrue(host.activate(switchLabel), host.text())
        XCTAssertTrue(host.run(until: { host.label(ofIdentifier: AppSettingsCopy.billTypesErrorIdentifier) != nil }), host.text())

        XCTAssertEqual(host.label(ofIdentifier: AppSettingsCopy.billTypesErrorIdentifier), "Couldn't turn off joint resolutions.")
        XCTAssertEqual(spoken.lines, ["Couldn't turn off joint resolutions."])
        XCTAssertEqual(host.value(ofIdentifier: identifier), on, "the switch is on again")
        XCTAssertNil(user.errorMessage)
    }

    /// Members you follow shows the failed Unfollow under the list and says it.
    func testMembersYouFollowSaysAFailedUnfollow() throws {
        let spoken = SpokenLines()
        let text = CongressFollowedMembersSection.unfollowFailedText(memberName: "Tim Kaine")
        let members = [try manifestMember()]
        let host = AccessibilityTreeText.Host(
            NavigationStack {
                CongressFollowedMembersSection(members: members, isLoading: false, unfollowError: text, onUnfollow: { _ in })
            }
            .environment(\.announceToVoiceOver, spoken.announce),
            settle: 0.3
        )
        defer { host.close() }
        XCTAssertEqual(host.label(ofIdentifier: CongressFollowedMembersSection.errorIdentifier), text)
        XCTAssertEqual(spoken.lines, [text])
    }

    /// The member page says a failed Follow in every state (here, before the member has loaded); once the page shows,
    /// the line is under the front matter and is not said again.
    func testTheMemberPageSaysAFailedFollow() throws {
        let preferences = FakePreferencesService()
        preferences.putError = Self.offline
        let user = UserStore(preferencesService: preferences, congressService: FakeCongressService())
        let spoken = SpokenLines()
        let manifest = try manifestMember()
        APIClient.$current.withValue(Self.offlineClient()) {
            let host = AccessibilityTreeText.Host(
                NavigationStack { CongressMemberProfileLoaderView(manifest: manifest) }
                    .environmentObject(user)
                    .environment(\.announceToVoiceOver, spoken.announce),
                size: CGSize(width: 390, height: 1600),
                settle: 0.5
            )
            defer { host.close() }
            XCTAssertTrue(host.run(until: { host.strings().contains { $0.contains(CongressMemberLoadErrorView.title) } }), host.text())

            XCTAssertTrue(host.activate(CongressFollowToolbarButton.accessibilityLabel(isFollowing: false)), host.text())
            XCTAssertTrue(host.run(until: { !spoken.lines.isEmpty }), host.text())
            XCTAssertEqual(spoken.lines, ["Couldn't follow this member."])
            XCTAssertEqual(user.profile.subscribedMemberIDs, [], "put back")

            XCTAssertTrue(host.activate(MemberBasicProfileButton.title), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: CongressFollowToolbarButton.errorIdentifier) != nil }), host.text())
            XCTAssertEqual(host.label(ofIdentifier: CongressFollowToolbarButton.errorIdentifier), "Couldn't follow this member.")
            XCTAssertEqual(spoken.lines, ["Couldn't follow this member."], "said once")
        }
    }

    // MARK: - Helpers

    /// A signed-in user store on `preferences` whose account may write (an attested adult), with the profile loaded
    /// from `preferences`. Its cached profile is removed in teardown.
    private func signedInUser(_ preferences: FakePreferencesService) async -> UserStore {
        let (user, userId, client) = signedInUserParts(preferences)
        await APIClient.$current.withValue(client) {
            await user.refresh(userId: userId, attributes: [])
        }
        XCTAssertTrue(user.canPerformUserWrites, "precondition: the user may write")
        return user
    }

    /// `signedInUser(_:)` for a test that is not async: the profile loads on the main run loop.
    private func signedInUserNow(_ preferences: FakePreferencesService) -> UserStore {
        let (user, userId, client) = signedInUserParts(preferences)
        APIClient.$current.withValue(client) {
            Task { await user.refresh(userId: userId, attributes: []) }
        }
        let deadline = Date().addingTimeInterval(5)
        while !user.hasRefreshedOnce, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(user.hasRefreshedOnce, "precondition: the profile loaded")
        XCTAssertTrue(user.canPerformUserWrites, "precondition: the user may write")
        return user
    }

    private func signedInUserParts(_ preferences: FakePreferencesService) -> (UserStore, String, APIClient) {
        let userId = "save-failure-tests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            UserStore.clearCachedProfile(userId: userId)
            UserDefaults.standard.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        }
        let user = UserStore(preferencesService: preferences, congressService: FakeCongressService())
        let me = Data(#"{"userId":"\#(userId)","adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#.utf8)
        let transport = RecordingTransport()
        transport.responses = [me, me]
        return (user, userId, transport.client)
    }

    private struct BillPage {
        let view: AnyView
        let user: UserStore
        let preferences: FakePreferencesService
    }

    /// A bill page for a watched bill, its stores on fakes; the stop's `DELETE /preferences` fails when `failing`.
    private func billPage(failing: Bool) -> BillPage {
        let preferences = FakePreferencesService()
        preferences.preferences = PreferencesMutations.watchItems(for: [Self.guid])
        let user = signedInUserNow(preferences)
        if failing {
            preferences.deleteError = Self.offline
        }
        // A bill the page shows without fetching it (it has its text's link).
        let bill = Bill(
            id: UUID.deterministic(from: Self.guid),
            title: "Bill \(Self.guid)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            link: "https://www.govinfo.gov/app/details/BILLS-119hr901ih",
            billStatus: .new,
            guid: Self.guid,
            userVoted: false,
            userWatched: true
        )
        let scope = "save-failure-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedManifest = []
        let billsStore = BillsStore(bills: [bill], cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        billsStore.connect(userStore: user)
        // The bills store holds both stores weakly; keep them for the whole test.
        addTeardownBlock { withExtendedLifetime((voteStore, user)) {} }
        let view = NavigationStack { BillDetail(billID: bill.id) }
            .environmentObject(billsStore)
            .environmentObject(voteStore)
            .environmentObject(AppReadState(scope: .user("save-failure-tests"), store: InMemoryReadStateStore()))
            .environmentObject(user)
            .environmentObject(CongressMembersManifestStore(service: FakeCongressService()))
        return BillPage(view: AnyView(view), user: user, preferences: preferences)
    }

    private func manifestMember() throws -> CongressMemberManifestItem {
        let json = #"{"bioguideId":"\#(Self.memberID)","name":"Tim Kaine","chamber":"Senate","state":"VA","party":"D"}"#
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data(json.utf8))
    }
}

/// What VoiceOver was told, in order.
@MainActor
private final class SpokenLines {
    private(set) var lines: [String] = []

    var announce: @MainActor @Sendable (String) -> Void {
        { [self] line in lines.append(line) }
    }
}
