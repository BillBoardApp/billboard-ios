import SwiftUI
import XCTest
@testable import Billboard

/// REL-46 (PR 7): the one-time "Your district may have changed" push carries `domain: "district_check"` and no bills
/// (backend services/scripts/sendDistrictNotice.ts, `noticeApnsPayload`). A tap waits in `PendingPushDeepLink` like
/// any other until navigation is allowed, then opens the Profile tab at its root with the Where you vote editor.
/// While the app is open it shows by the master switch only (D13).
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

    /// The tap lands on Profile at its root and asks for the Where you vote editor, once.
    func testATapOpensProfileWithWhereYouVote() {
        let appState = AppState()
        appState.selectedTab = TabsBar.Tab.home.rawValue
        var profilePath = NavigationPath()
        profilePath.append("a pushed screen")
        let center = NotificationCenter()
        let request = expectation(forNotification: .billboardRequestLocationEditor, object: nil, notificationCenter: center)
        request.assertForOverFulfill = true

        PushDeepLinkRouter.openWhereYouVote(appState: appState, profilePath: &profilePath, notificationCenter: center)

        wait(for: [request], timeout: 1)
        XCTAssertEqual(appState.selectedTab, TabsBar.Tab.profile.rawValue)
        XCTAssertTrue(profilePath.isEmpty, "Profile at its root")
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

        settings.notificationsEnabled = false
        PushPresentationSettings.save(settings, defaults: defaults)
        XCTAssertFalse(PushPresentationSettings.allowsForegroundPresentation(of: payload, defaults: defaults))

        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        PushPresentationSettings.clear(defaults: defaults)
        XCTAssertFalse(PushPresentationSettings.allowsForegroundPresentation(of: payload, defaults: defaults), "the master switch")
    }
}
