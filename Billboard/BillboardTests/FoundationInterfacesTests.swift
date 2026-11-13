import Foundation
import SwiftUI
import XCTest
@testable import Billboard

/// The interfaces wave 0 fixes for the other R2 packages (spec D 4.1): `VoteChoice`, feature flags,
/// notification names, the new tutorial anchors, the website URL key and the address-cap fields of
/// `DistrictVerificationStatus`.
@MainActor
final class FoundationInterfacesTests: XCTestCase {
    // MARK: - VoteChoice

    func testVoteChoiceWordsSymbolsAndLabels() {
        XCTAssertEqual(VoteChoice.allCases, [.yea, .nay, .abstain], "left to right on the vote bar")
        XCTAssertEqual(VoteChoice.allCases.map(\.title), ["Yea", "Nay", "Abstain"])
        XCTAssertEqual(VoteChoice.allCases.map(\.symbolName), ["checkmark", "xmark", "minus"])
        XCTAssertEqual(VoteChoice.allCases.map(\.accessibilityLabel), ["Vote Yea", "Vote Nay", "Abstain"])
        XCTAssertEqual(VoteChoice.allCases.map(\.confirmationMessage), ["You voted Yea", "You voted Nay", "You abstained"])
    }

    func testVoteChoiceRoundTripsWithVoteType() {
        for voteType in VoteType.allCases {
            XCTAssertEqual(VoteChoice(voteType).voteType, voteType)
        }
        for choice in VoteChoice.allCases {
            XCTAssertEqual(VoteChoice(choice.voteType), choice)
        }
    }

    func testVoteChoiceColoursAreTheVoteTokens() {
        XCTAssertEqual(VoteChoice.yea.paletteToken, BillboardPalette.voteYea)
        XCTAssertEqual(VoteChoice.nay.paletteToken, BillboardPalette.voteNay)
        XCTAssertEqual(VoteChoice.abstain.paletteToken, BillboardPalette.voteAbstain)
        XCTAssertTrue(VoteChoice.yea.uiColor === BillboardUIColors.voteYea)
        XCTAssertTrue(VoteChoice.nay.uiColor === BillboardUIColors.voteNay)
        XCTAssertTrue(VoteChoice.abstain.uiColor === BillboardUIColors.voteAbstain)
    }

    /// The press responses in Civic Record's motion budget (spec 5.2): capsules scale to 0.98, rows,
    /// links and tabs dim to 0.6. Neither style plays a haptic.
    func testPressStylesFollowTheMotionBudget() {
        XCTAssertEqual(CapsulePress.pressedScale, 0.98)
        XCTAssertEqual(RowButtonStyle.pressedOpacity, 0.6)
        XCTAssertFalse(RowButtonStyle().textOnly, "the Button Shapes outline is for text-only controls")
        XCTAssertEqual(ButtonShapeOutline.horizontalOutset * 2, 10, "10 pt wider than the label")
        XCTAssertEqual(ButtonShapeOutline.verticalOutset * 2, 6, "6 pt taller than the label")
    }

    /// A pressed capsule scales to 0.98. Reduce Motion takes the scale away (spec 5.2) and the capsule
    /// fades to 0.6 instead, so a press still shows; nothing changes while it is not pressed.
    func testACapsulePressStillShowsWithReduceMotion() {
        XCTAssertEqual(CapsulePress.scale(isPressed: true, reduceMotion: false), 0.98)
        XCTAssertEqual(CapsulePress.opacity(isPressed: true, reduceMotion: false), 1)
        XCTAssertEqual(CapsulePress.scale(isPressed: true, reduceMotion: true), 1, "no scale with Reduce Motion")
        XCTAssertEqual(CapsulePress.opacity(isPressed: true, reduceMotion: true), 0.6, "a fade instead")
        for reduceMotion in [false, true] {
            XCTAssertEqual(CapsulePress.scale(isPressed: false, reduceMotion: reduceMotion), 1)
            XCTAssertEqual(CapsulePress.opacity(isPressed: false, reduceMotion: reduceMotion), 1)
        }
    }

    /// Civic Record spec 3.10: the ballot buttons are 50 pt at the default size (never under 44), with a
    /// 1.5 pt ring (2 pt with Increase Contrast, 2.5 pt for the current vote while changing), 20 pt corners
    /// and the vote colour at 7% over the sheet (6% in dark mode); pressed, 0.965. The stamp's rule and the
    /// refusal strip's `danger` rule widen with Increase Contrast too (spec 2.9, 7.6).
    func testBallotButtonStyleMetrics() {
        XCTAssertEqual(BallotStamp.ruleWidth, 1.5)
        XCTAssertEqual(BallotStamp.ruleWidthHighContrast, 2)
        XCTAssertEqual(VoteStrip.refusalRuleWidth, 1.5)
        XCTAssertEqual(VoteStrip.refusalRuleWidthHighContrast, 2)
        XCTAssertEqual(BillVoteBarModel.minimumControlHeight, 50)
        XCTAssertGreaterThanOrEqual(BillVoteBarModel.controlHeight(lineHeight: 0), 44, "the floor")
        XCTAssertEqual(BallotButtonStyle.ringWidth, 1.5)
        XCTAssertEqual(BallotButtonStyle.ringWidthHighContrast, 2)
        XCTAssertEqual(BallotButtonStyle.currentRingWidth, 2.5)
        XCTAssertEqual(BallotButtonStyle.cornerRadius, BillboardStyle.Radius.panel - BillVoteBar.panelPadding)
        XCTAssertEqual(BallotButtonStyle.tintOpacity(dark: false), 0.07, "spec: 7% over the sheet")
        XCTAssertEqual(BallotButtonStyle.tintOpacity(dark: true), 0.06)
        XCTAssertEqual(BallotButtonStyle.pressedScale, 0.965)
        XCTAssertEqual(BallotButtonStyle.disabledOpacity, 0.45)
        XCTAssertEqual(BallotBox.side, 16)
        XCTAssertEqual(BallotBox.symbolRatio * BallotBox.side, 10, "the symbol at 10 pt in the 16 pt box")
    }

    // MARK: - Flags, keys and names

    func testFeatureFlagsShipOn() {
        XCTAssertTrue(FeatureFlags.appAttestClient)
        XCTAssertTrue(FeatureFlags.starterFeed)
        XCTAssertTrue(FeatureFlags.voteBarCoachMark)
        XCTAssertTrue(FeatureFlags.glassChrome)
    }

    func testWebsiteBaseURLIsConfiguredForAboutLinks() throws {
        let raw = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "WEBSITE_BASE_URL") as? String)
        XCTAssertEqual(raw, "https://billboard-project.com")
        let base = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(base.scheme, "https")
        XCTAssertEqual(base.appendingPathComponent("roadmap.html").absoluteString, "https://billboard-project.com/roadmap.html")
        XCTAssertEqual(base.appendingPathComponent("privacy.html").absoluteString, "https://billboard-project.com/privacy.html")
    }

    func testWebsiteKeyDoesNotWidenDeepLinkHosts() {
        XCTAssertFalse(AppDeepLink.shareSiteHosts().contains("billboard-project.com"))
    }

    func testNewNotificationNamesAreDistinct() {
        let names: [Notification.Name] = [
            .billboardVoteSaved,
            .billboardRequestTopicPicker,
            .billboardRequestLocationEditor,
            .billboardRequestCongressFollows,
            .billboardBillsManifestDidChange,
            .billboardBillDidChange,
            .billboardBillAlertDidChange,
            .billboardDidRegisterPushToken,
            .billboardDidSavePendingPushDeepLink,
            .billboardDidReceiveBillDeepLink,
            .billboardShouldPromptPushPermission,
            .billboardShouldSyncPushRegistration,
            .billboardAuthSessionInvalidated
        ]
        XCTAssertEqual(Set(names.map(\.rawValue)).count, names.count)
        XCTAssertEqual(Notification.Name.billboardVoteSaved.rawValue, "BillBoard.vote.saved")
    }

    /// Profile's Manage in Congress asks the tab shell for the Congress tab's root (Members you
    /// follow), which pops a Congress screen left open there, instead of only selecting the tab.
    func testManageInCongressAsksForTheCongressRoot() {
        let center = NotificationCenter()
        let requested = expectation(forNotification: .billboardRequestCongressFollows, object: nil, notificationCenter: center)
        FollowedMembersContent.requestManageInCongress(center: center)
        wait(for: [requested], timeout: 1)
    }

    func testNewTutorialAnchorsLiveOnTheBillsTab() {
        XCTAssertEqual(TutorialAnchor.billsFirstCard.scrollID, "tutorial.billsFirstCard")
        XCTAssertEqual(TutorialAnchor.voteBar.scrollID, "tutorial.voteBar")
        XCTAssertEqual(TutorialAnchor.billsFirstCard.ownerTab, .home)
        XCTAssertEqual(TutorialAnchor.voteBar.ownerTab, .home)
        XCTAssertNotEqual(TutorialAnchor.billsFirstCard.scrollID, TutorialAnchor.voteBar.scrollID)
        // Civic Record spec 4.9: the tab capsule, measured for the tour's card, on the Bills root.
        XCTAssertEqual(TutorialAnchor.tabBar.scrollID, "tutorial.tabBar")
        XCTAssertEqual(TutorialAnchor.tabBar.ownerTab, .home)
        XCTAssertEqual(Set([TutorialAnchor.billsFirstCard, .voteBar, .tabBar].map(\.scrollID)).count, 3)
    }

    // MARK: - DistrictVerificationStatus (INT-03)

    /// The contract fixture `contracts/fixtures/openapi/DistrictVerification.valid.json`.
    private static let cappedFixture = """
    {
      "verified": false,
      "status": "self_attested",
      "method": "address_capped",
      "verifiedAt": "2026-10-08T12:00:00.000Z",
      "resolved": { "state": "CA", "districtId": "CA-12" },
      "signals": {
        "addressGeocoded": true,
        "ipStateConsistency": "unknown",
        "ipStateObserved": null,
        "districtClaimMatch": null
      },
      "repsSignalEligible": false,
      "limitReason": "address_limit",
      "nextStep": "This address already has the most verified accounts we allow. Your district is saved; your votes count with all users but not as verified."
    }
    """

    func testDecodesTheAddressCappedContractFixture() throws {
        let status = try JSONDecoder().decode(DistrictVerificationStatus.self, from: Data(Self.cappedFixture.utf8))
        XCTAssertFalse(status.verified)
        XCTAssertEqual(status.method, DistrictVerificationStatus.methodAddressCapped)
        XCTAssertEqual(status.limitReason, DistrictVerificationStatus.limitReasonAddressLimit)
        XCTAssertEqual(status.resolved, DistrictVerificationResolved(state: "CA", districtId: "CA-12"))
        XCTAssertTrue(status.isAddressCapped)
    }

    func testDecodesAResponseWithoutTheLimitFields() throws {
        let json = """
        {"verified": true, "status": "likely_constituent", "method": "address_geocode",
         "resolved": {"state": "VA", "districtId": "VA-11"}, "repsSignalEligible": true}
        """
        let status = try JSONDecoder().decode(DistrictVerificationStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.verified)
        XCTAssertNil(status.limitReason)
        XCTAssertFalse(status.isAddressCapped)
    }

    func testLimitReasonAloneMarksTheAddressCapped() {
        var status = DistrictVerificationStatus.empty
        XCTAssertNil(status.limitReason)
        XCTAssertFalse(status.isAddressCapped)
        status.limitReason = "address_limit"
        XCTAssertTrue(status.isAddressCapped)
    }

    func testLimitReasonRoundTripsThroughEncoding() throws {
        let status = try JSONDecoder().decode(DistrictVerificationStatus.self, from: Data(Self.cappedFixture.utf8))
        let again = try JSONDecoder().decode(DistrictVerificationStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(again, status)
    }
}
