import SwiftUI
import XCTest
@testable import Billboard

/// REL-46 (PR 7): the one-time "Your district may have changed" push carries `domain: "district_check"` and no bills
/// (backend services/scripts/sendDistrictNotice.ts, `noticeApnsPayload`). A tap waits in `PendingPushDeepLink` like
/// any other until navigation is allowed, then opens the Profile tab at its root with Profile's own Where you vote
/// editor, so the Where you vote line shows what it saved. While the app is open it shows by the master switch only
/// (D13).
@MainActor
final class DistrictCheckPushTests: XCTestCase {
    /// The payload the backend sends.
    private static let userInfo: [AnyHashable: Any] = [
        "aps": [
            "alert": [
                "title": "Your district may have changed",
                "body": "The new Congress began Jan 3, with new House maps in some states. Open Profile and check where you vote."
            ],
            "sound": "default",
            "thread-id": "district"
        ],
        "domain": "district_check"
    ]

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "DistrictCheckPushTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    func testTheDomainParses() {
        let payload = PushNotificationPayload(userInfo: Self.userInfo)
        XCTAssertEqual(payload.domain, .districtCheck)
        XCTAssertTrue(payload.isDistrictCheck)
        XCTAssertEqual(PushNotificationPayload(userInfo: ["domain": " District-Check "]).domain, .districtCheck)
        XCTAssertFalse(payload.isWeeklyDigestRelevant)
        XCTAssertFalse(payload.isBillsManifestRelevant)
        XCTAssertFalse(payload.isBillAlertRelevant)
        XCTAssertEqual(payload.allBillIds, [])
        XCTAssertFalse(PushNotificationPayload(userInfo: ["domain": "bill"]).isDistrictCheck)
    }

    func testThePendingLinkRoundTrips() throws {
        let defaults = try isolatedDefaults()
        PendingPushDeepLink.save(.districtCheck, defaults: defaults)
        XCTAssertEqual(PendingPushDeepLink.consume(defaults: defaults), .districtCheck)
        XCTAssertNil(PendingPushDeepLink.consume(defaults: defaults), "consumed once")
        XCTAssertEqual(PendingPushDeepLink.Kind.districtCheck.sanitized(), .districtCheck)
    }

    /// A tap saves the district check as the pending link and says so; a push that arrives unopened saves nothing.
    /// Either way it has no bills, so the bill handling never runs.
    func testATapSavesTheDistrictCheckAsThePendingLink() throws {
        let payload = PushNotificationPayload(userInfo: Self.userInfo)
        let defaults = try isolatedDefaults()
        let center = NotificationCenter()
        let saved = expectation(forNotification: .billboardDidSavePendingPushDeepLink, object: nil, notificationCenter: center)
        saved.assertForOverFulfill = true

        XCTAssertTrue(PushNotificationsAppDelegate.handlePushWithoutBills(
            payload, wasUserInteraction: true, defaults: defaults, notificationCenter: center
        ))
        wait(for: [saved], timeout: 1)
        XCTAssertEqual(PendingPushDeepLink.consume(defaults: defaults), .districtCheck)

        XCTAssertTrue(PushNotificationsAppDelegate.handlePushWithoutBills(
            payload, wasUserInteraction: false, defaults: defaults, notificationCenter: center
        ))
        XCTAssertNil(PendingPushDeepLink.consume(defaults: defaults), "not tapped")

        let billPush = PushNotificationPayload(userInfo: ["domain": "bill", "billId": "BILLS-119hr12", "notificationType": "new"])
        XCTAssertFalse(PushNotificationsAppDelegate.handlePushWithoutBills(
            billPush, wasUserInteraction: true, defaults: defaults, notificationCenter: center
        ), "a bill push goes on to its bills")
        XCTAssertNil(PendingPushDeepLink.consume(defaults: defaults))
    }

    /// Once navigation is allowed, the pending district check lands on Profile at its root and asks for Profile's
    /// own Where you vote editor, not the tab bar's: Profile's editor puts the verification it saved on the Where
    /// you vote line, which the tab bar's copy never told Profile about.
    func testThePendingDistrictCheckOpensProfilesOwnWhereYouVote() throws {
        let defaults = try isolatedDefaults()
        PendingPushDeepLink.save(.districtCheck, defaults: defaults)
        let pending = try XCTUnwrap(PendingPushDeepLink.consume(defaults: defaults))
        let appState = AppState()
        appState.selectedTab = TabsBar.Tab.home.rawValue
        var profilePath = NavigationPath()
        profilePath.append("a pushed screen")
        let tabBarEditor = expectation(forNotification: .billboardRequestLocationEditor, object: nil)
        tabBarEditor.isInverted = true

        XCTAssertTrue(PushDeepLinkRouter.openPendingWithoutBills(pending, appState: appState, profilePath: &profilePath))

        wait(for: [tabBarEditor], timeout: 0.2)
        XCTAssertEqual(appState.selectedTab, TabsBar.Tab.profile.rawValue)
        XCTAssertTrue(profilePath.isEmpty, "Profile at its root")
        XCTAssertEqual(appState.pendingProfileSheet, .whereYouVote)
        XCTAssertEqual(ProfileView.Sheet(.whereYouVote), .location, "Profile's own location editor")

        // A bill push is not one of these: it opens its bill.
        XCTAssertFalse(PushDeepLinkRouter.openPendingWithoutBills(
            .digest(billIds: ["BILLS-119hr12"], notificationType: "new"), appState: appState, profilePath: &profilePath
        ))
    }

    /// Profile opens the pending sheet once, and not while a tab bar sheet is up (a second sheet cannot show over it):
    /// it waits for that one to close.
    func testProfileOpensThePendingSheetOnceNoTabBarSheetIsUp() {
        let appState = AppState()
        XCTAssertNil(appState.takePendingProfileSheet(), "nothing asked for")
        appState.pendingProfileSheet = .whereYouVote
        appState.isTabsSheetUp = true
        XCTAssertNil(appState.takePendingProfileSheet(), "the tab bar's sheet is up")
        XCTAssertEqual(appState.pendingProfileSheet, .whereYouVote, "still waiting")
        appState.isTabsSheetUp = false
        XCTAssertEqual(appState.takePendingProfileSheet(), .whereYouVote)
        XCTAssertNil(appState.pendingProfileSheet)
        XCTAssertNil(appState.takePendingProfileSheet(), "once")
    }

    /// While the app is open it shows unless notifications are off: it has no setting of its own.
    func testForegroundPresentationFollowsTheMasterSwitchOnly() throws {
        let payload = PushNotificationPayload(userInfo: Self.userInfo)
        let defaults = try isolatedDefaults()
        XCTAssertTrue(PushPresentationSettings.allowsForegroundPresentation(of: payload, defaults: defaults))

        var settings = DeviceNotificationSettings.allEnabled
        settings.notifyNew = false
        settings.notifyUpdated = false
        settings.notifyAlert = false
        settings.notifyPassed = false
        settings.notifyFailed = false
        PushPresentationSettings.save(settings, defaults: defaults)
        XCTAssertTrue(PushPresentationSettings.allowsForegroundPresentation(of: payload, defaults: defaults), "every type off")
        // Not a bill push, so a bill type's switch never hides it, even if the push names a type.
        var typed = Self.userInfo
        typed["notificationType"] = "new"
        XCTAssertTrue(
            PushPresentationSettings.allowsForegroundPresentation(of: PushNotificationPayload(userInfo: typed), defaults: defaults),
            "New bills off"
        )

        settings.notificationsEnabled = false
        PushPresentationSettings.save(settings, defaults: defaults)
        XCTAssertFalse(PushPresentationSettings.allowsForegroundPresentation(of: payload, defaults: defaults))

        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        PushPresentationSettings.clear(defaults: defaults)
        XCTAssertFalse(PushPresentationSettings.allowsForegroundPresentation(of: payload, defaults: defaults), "the master switch")
    }
}
