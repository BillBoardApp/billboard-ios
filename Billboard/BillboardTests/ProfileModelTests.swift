import UserNotifications
import XCTest
@testable import Billboard

/// The editable Profile tab and App settings (spec D 2.5.7): what each section shows for a profile,
/// a verification status and an iOS permission state, all as pure rules. (About you is gone: UX-36.)
@MainActor
final class ProfileModelTests: XCTestCase {
    // MARK: - Fixtures

    private func profile(
        id: String = "user-1",
        state: String = "VA",
        district: String = "11",
        topics: [String] = [],
        lifeAreas: [String] = [],
        members: [UUID] = []
    ) -> UserProfile {
        UserProfile.placeholder().updating(
            id: id,
            email: "voter@example.com",
            state: state,
            district: district,
            subscribedSubCategories: topics,
            subscribedLifeAreas: lifeAreas,
            subscribedMemberIDs: members
        )
    }

    private func status(
        verified: Bool,
        status: String? = nil,
        method: String? = nil,
        limitReason: String? = nil
    ) -> DistrictVerificationStatus {
        DistrictVerificationStatus(
            verified: verified,
            status: status,
            method: method,
            verifiedAt: nil,
            resolved: nil,
            signals: nil,
            repsSignalEligible: nil,
            nextStep: nil,
            limitReason: limitReason
        )
    }

    private func member(_ id: String, _ name: String, chamber: String, state: String, district: Int? = nil, party: String) throws -> CongressMemberManifestItem {
        var fields = [
            #""bioguideId":"\#(id)""#,
            #""name":"\#(name)""#,
            #""chamber":"\#(chamber)""#,
            #""state":"\#(state)""#,
            #""party":"\#(party)""#
        ]
        if let district { fields.append(#""district":\#(district)"#) }
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    // MARK: - Where you vote

    func testWhereYouVoteLines() {
        let verified = WhereYouVoteSummary.make(state: "VA", district: "11", status: status(verified: true, status: "verified", method: "address_geocode"), isLoading: false)
        XCTAssertEqual(verified.line, "VA-11 · Verified")
        XCTAssertTrue(verified.isVerified)
        XCTAssertNil(verified.note)

        let chosen = WhereYouVoteSummary.make(state: "VA", district: "11", status: status(verified: false, status: "self_attested", method: "manual_state_district"), isLoading: false)
        XCTAssertEqual(chosen.line, "VA-11 · Not verified (district chosen by you)")
        XCTAssertEqual(chosen.verification, .chosenByYou)

        // R1 servers sent only the status for a picked district.
        let chosenByStatusOnly = WhereYouVoteSummary.make(state: "VA", district: "11", status: status(verified: false, status: "self_attested"), isLoading: false)
        XCTAssertEqual(chosenByStatusOnly.verification, .chosenByYou)

        let notVerified = WhereYouVoteSummary.make(state: "VA", district: "2", status: status(verified: false), isLoading: false)
        XCTAssertEqual(notVerified.line, "VA-2 · Not verified")

        let atLarge = WhereYouVoteSummary.make(state: "WY", district: "At-Large", status: status(verified: true), isLoading: false)
        XCTAssertEqual(atLarge.line, "WY at-large · Verified")
    }

    func testAddressCapShowsNotVerifiedWithTheSetupNote() {
        for capped in [
            status(verified: false, method: DistrictVerificationStatus.methodAddressCapped),
            status(verified: false, method: "address_geocode", limitReason: "address_limit")
        ] {
            let summary = WhereYouVoteSummary.make(state: "VA", district: "11", status: capped, isLoading: false)
            XCTAssertEqual(summary.verification, .addressCapped)
            XCTAssertEqual(summary.line, "VA-11 · Not verified")
            XCTAssertEqual(summary.note, LocationEditorView.addressCappedMessage)
            XCTAssertEqual(summary.note, "This address already has the most verified accounts allowed. Your district is saved, but your votes count as not verified.")
        }
    }

    func testWhereYouVoteWhileLoadingAndWhenTheStatusIsUnavailable() {
        let checking = WhereYouVoteSummary.make(state: "Virginia", district: "11", status: nil, isLoading: true)
        XCTAssertEqual(checking.line, "VA-11 · Checking…")

        let unavailable = WhereYouVoteSummary.make(state: "VA", district: "11", status: nil, isLoading: false)
        XCTAssertEqual(unavailable.line, "VA-11")
        XCTAssertNil(unavailable.note)
    }

    func testWhereYouVoteWithoutALocationAsksForAnAddress() {
        let summary = WhereYouVoteSummary.make(state: "", district: "", status: status(verified: false), isLoading: false)
        XCTAssertNil(summary.locationLabel)
        XCTAssertEqual(summary.line, WhereYouVoteSummary.missingLocationText)

        let stateOnly = WhereYouVoteSummary.make(state: "VA", district: "", status: nil, isLoading: false)
        XCTAssertEqual(stateOnly.line, "VA")
    }

    // MARK: - Topics you follow

    func testTopicsUseCurrentNamesAndAreDeduplicated() {
        let summary = FollowedTopicsSummary(profile: profile(
            topics: ["Social Justice", "Civil Rights and Liberties", "Healthcare", "Identity Politics"],
            lifeAreas: ["Housing", " Housing "]
        ))

        XCTAssertEqual(summary.topics, ["Civil Rights and Liberties", "Healthcare", "Heritage and Identity"])
        XCTAssertEqual(summary.lifeAreas, ["Housing"])
        XCTAssertFalse(summary.allChips.contains { $0.title == "Social Justice" || $0.title == "Identity Politics" })
        XCTAssertEqual(summary.countText, "3 topics and 1 life area")
    }

    func testNoTopicsShowsTheEmptyLine() {
        let summary = FollowedTopicsSummary(profile: profile())
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(FollowedTopicsSummary.emptyText, "You don't follow any topics yet.")
    }

    func testLifeAreasOnlyCountAsFollowing() {
        let summary = FollowedTopicsSummary(topics: [], lifeAreas: ["Housing", "Jobs"])
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(summary.countText, "2 life areas")
        XCTAssertEqual(summary.allChips.map(\.kind), [.lifeArea, .lifeArea])
    }

    func testManyTopicsAreCappedWithACount() {
        let topics = (1...15).map { "Topic \($0)" }
        let summary = FollowedTopicsSummary(topics: topics, lifeAreas: ["Housing"])
        XCTAssertEqual(summary.visibleChips.count, FollowedTopicsSummary.chipLimit)
        XCTAssertEqual(summary.hiddenCount, 16 - FollowedTopicsSummary.chipLimit)
        XCTAssertEqual(summary.visibleChips.first?.kind, .topic)
    }

    // MARK: - Members you follow

    func testMembersCountAndFirstThreeInRosterOrder() throws {
        let manifest = [
            try member("W000805", "Mark R. Warner", chamber: "Senate", state: "VA", party: "D"),
            try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D"),
            try member("W000804", "Robert J. Wittman", chamber: "House of Representatives", state: "VA", district: 1, party: "R"),
            try member("S000033", "Bernard Sanders", chamber: "Senate", state: "VT", party: "I"),
            try member("X000001", "Not Followed", chamber: "Senate", state: "VT", party: "R")
        ]
        let followed = ["W000805", "K000384", "W000804", "S000033"].map { UUID.deterministic(from: $0) }

        let summary = FollowedMembersSummary.make(subscribedIDs: followed, manifest: manifest)

        XCTAssertEqual(summary.count, 4)
        XCTAssertEqual(summary.countText, "You follow 4 members.")
        XCTAssertEqual(summary.preview.map(\.id), ["K000384", "S000033", "W000805"])
        XCTAssertEqual(summary.remainingCount, 1)
        XCTAssertEqual(summary.preview.map(\.name), ["Tim Kaine", "Bernard Sanders", "Mark R. Warner"])
    }

    func testMembersBeforeTheManifestLoadsStillCount() {
        let summary = FollowedMembersSummary.make(subscribedIDs: [UUID.deterministic(from: "K000384")], manifest: [])
        XCTAssertEqual(summary.countText, "You follow 1 member.")
        XCTAssertTrue(summary.preview.isEmpty)
    }

    func testNoMembers() {
        let summary = FollowedMembersSummary.make(subscribedIDs: [], manifest: [])
        XCTAssertEqual(summary.countText, "You don't follow any members yet.")
        XCTAssertEqual(summary.remainingCount, 0)
    }

    // MARK: - Notifications

    func testNotificationTypesUseTheGlossaryNamesInOrder() {
        XCTAssertEqual(NotificationKind.allCases.map(\.title), [
            "New bills", "Updated bills", "Actions in Congress", "Passed bills", "Failed bills"
        ])
    }

    func testEachTypeReadsItsOwnSwitch() {
        var settings = DeviceNotificationSettings.allEnabled
        settings.notifyNew = false
        settings.notifyAlert = false
        settings.notifyFailed = false

        XCTAssertFalse(NotificationKind.newBills.isOn(in: settings))
        XCTAssertTrue(NotificationKind.updatedBills.isOn(in: settings))
        XCTAssertFalse(NotificationKind.actionsInCongress.isOn(in: settings))
        XCTAssertTrue(NotificationKind.passedBills.isOn(in: settings))
        XCTAssertFalse(NotificationKind.failedBills.isOn(in: settings))
    }

    func testPermissionStatesGateTheSwitches() {
        let allowed = NotificationsSectionModel(permission: .authorized, settings: .allEnabled)
        XCTAssertTrue(allowed.isMasterOn)
        XCTAssertFalse(allowed.isMasterDisabled)
        XCTAssertFalse(allowed.areKindTogglesDisabled)
        XCTAssertEqual(allowed.permissionText, "Allowed")
        XCTAssertNil(allowed.permissionHint)

        let denied = NotificationsSectionModel(permission: .denied, settings: .allEnabled)
        XCTAssertFalse(denied.isMasterOn, "shows the effective state while iOS blocks delivery")
        XCTAssertTrue(denied.isMasterDisabled)
        XCTAssertTrue(denied.areKindTogglesDisabled)
        XCTAssertEqual(denied.permissionText, "Off")
        XCTAssertEqual(denied.permissionHint, NotificationsSectionModel.deniedHint)

        let notAsked = NotificationsSectionModel(permission: .notDetermined, settings: .allEnabled)
        XCTAssertFalse(notAsked.isMasterOn)
        XCTAssertTrue(notAsked.areKindTogglesDisabled)
        XCTAssertEqual(notAsked.permissionText, "Not asked yet")
        XCTAssertEqual(notAsked.permissionHint, NotificationsSectionModel.notAskedHint)

        let checking = NotificationsSectionModel(permission: nil, settings: .allEnabled)
        XCTAssertEqual(checking.permissionText, "Checking…")
        XCTAssertNil(checking.permissionHint, "the not-asked hint does not flash before the first read")
        XCTAssertTrue(checking.isMasterOn)

        XCTAssertEqual(NotificationsSectionModel(permission: .provisional, settings: .allEnabled).permissionText, "Allowed quietly")
    }

    func testMasterOffDisablesTypesButKeepsTheirValues() {
        var settings = DeviceNotificationSettings.allEnabled
        settings.notificationsEnabled = false
        let model = NotificationsSectionModel(permission: .authorized, settings: settings)

        XCTAssertFalse(model.isMasterOn)
        XCTAssertFalse(model.isMasterDisabled)
        XCTAssertTrue(model.areKindTogglesDisabled)
        XCTAssertTrue(NotificationKind.newBills.isOn(in: model.settings))

        let saving = NotificationsSectionModel(permission: .authorized, settings: .allEnabled, isBusy: true)
        XCTAssertTrue(saving.isMasterDisabled)
        XCTAssertTrue(saving.areKindTogglesDisabled)
    }

    func testWeeklyBriefCopy() {
        XCTAssertEqual(NotificationsSectionModel.weeklyBriefTitle, "Weekly Brief in Updates")
        XCTAssertEqual(
            NotificationsSectionModel.weeklyBriefFootnote,
            "A short summary each week of what happened to the bills and members you follow."
        )
    }

    func testNotificationSettingsErrorsArePlainCopy() {
        for message in [NotificationSettingsStore.loadFailedMessage, NotificationSettingsStore.saveFailedMessage] {
            XCTAssertTrue(message.hasPrefix("Couldn't"), message)
            XCTAssertFalse(message.contains("Could not"), message)
        }
    }

    // MARK: - App settings

    func testAppSettingsCopy() {
        XCTAssertEqual(AppSettingsCopy.billTypesFooter, "Choose which kinds of bills appear on the Bills tab and in notifications. Keep at least one.")
        XCTAssertEqual(AppSettingsCopy.historyPickerTitle, "Show bills from the last")
        XCTAssertEqual(AppSettingsCopy.replayTitle, "Replay the tour")
        XCTAssertEqual(AppSettingsCopy.replaySubtitle, "A 3-step tour of voting in Billboard.")
        XCTAssertEqual(AppSettingsCopy.historyOptionTitle(.oneWeek), "1 week (Recommended)")
        XCTAssertEqual(AppSettingsCopy.historyOptionTitle(.threeWeeks), "3 weeks")
        XCTAssertEqual(AppSettingsCopy.billTypeTitle(.jointResolutions), "Joint resolutions")
        XCTAssertEqual(AppSettingsCopy.billTypeTitle(.bills), "Bills")
    }

    func testHistoryOptionsKeepAnOlderStoredValue() {
        XCTAssertEqual(AppSettingsCopy.historyOptions(selectedDays: 14), BillboardHistoryWindow.allCases)
        XCTAssertEqual(AppSettingsCopy.historyOptions(selectedDays: 0), BillboardHistoryWindow.allCases, "0 means the default")
        XCTAssertEqual(
            AppSettingsCopy.historyOptions(selectedDays: 10).map(\.rawValue),
            [7, 10, 14, 21, 28]
        )
    }

    func testTheLastBillTypeCannotBeTurnedOff() {
        XCTAssertFalse(AppSettingsCopy.canTurnOff(.bills, enabled: [.bills]))
        XCTAssertTrue(AppSettingsCopy.canTurnOff(.bills, enabled: [.bills, .jointResolutions]))
        XCTAssertTrue(AppSettingsCopy.canTurnOff(.otherResolutions, enabled: [.bills]))
    }

    func testAppearanceChoicesStoreUnderTheSharedKey() {
        XCTAssertEqual(AppearancePreference.storageKey, "BillBoard.appearance.v1")
        XCTAssertEqual(AppearancePreference.allCases.map(\.title), ["System", "Light", "Dark"])
    }

    // MARK: - Delete account

    func testDeleteNeedsTheConfirmationWord() {
        XCTAssertTrue(DeleteAccountCopy.isConfirmed("DELETE"))
        XCTAssertTrue(DeleteAccountCopy.isConfirmed(" delete "))
        XCTAssertFalse(DeleteAccountCopy.isConfirmed("DELET"))
        XCTAssertFalse(DeleteAccountCopy.isConfirmed(""))
        XCTAssertEqual(DeleteAccountCopy.warning, "Deleting your account removes your Billboard data. This can't be undone.")
        XCTAssertEqual(DeleteAccountCopy.buttonTitle, "Delete account and data")
        // One name for the screen, the Settings row and the button (spec 4.6's inline titles).
        XCTAssertEqual(DeleteAccountCopy.screenTitle, "Delete account and data")
    }

    // MARK: - Voting streak

    func testStreakSummaryForVoiceOver() {
        let days = [VoteDay(date: "2026-10-06", count: 0), VoteDay(date: "2026-10-07", count: 2), VoteDay(date: "2026-10-08", count: 1)]
        XCTAssertEqual(VotingStreakView.activeDayCount(days), 2)
        XCTAssertEqual(VotingStreakView.accessibilitySummary(days), "Voted on 2 of the last 3 days")
    }

    // MARK: - Copy rules

    func testProfileCopyAvoidsRetiredTerms() {
        let copy: [String] = [
            WhereYouVoteSummary.missingLocationText,
            FollowedTopicsSummary.emptyText,
            FollowedMembersSummary.emptyText,
            NotificationsSectionModel.deniedHint,
            NotificationsSectionModel.notAskedHint,
            NotificationsSectionModel.weeklyBriefFootnote,
            AppSettingsCopy.appearanceFooter,
            AppSettingsCopy.billTypesFooter,
            AppSettingsCopy.historyFooter(.twoWeeks),
            DeleteAccountCopy.warning
        ] + NotificationKind.allCases.map(\.title)

        let retired = ["Subscri", "Sub-categor", "Home", "Alert", "Digest", "Self-attested", "constituent", "history window"]
        for text in copy {
            XCTAssertFalse(text.contains("BillBoard"), "\"\(text)\" spells the app BillBoard")
            for term in retired {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(term), "\"\(text)\" contains \(term)")
            }
        }
    }
}
