import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// The Home Screen icons: White (the primary icon) and Navy (the alternate), the names iOS knows them by, and the
/// App icon row in App settings. The test host is the app, so its Info.plist and `UIApplication` are the real ones.
@MainActor
final class AppIconTests: XCTestCase {
    func testAppIconChoices() {
        XCTAssertEqual(AppSettingsCopy.appIconTitle, "App icon")
        XCTAssertEqual(AppSettingsCopy.appIconFailedText, "Couldn't change the app icon.")
        XCTAssertEqual(AppIconChoice.allCases.map(\.title), ["White", "Navy"])
        XCTAssertEqual(AppIconChoice.allCases.map(\.alternateIconName), [nil, "AppIcon-Navy"])
        for choice in AppIconChoice.allCases {
            XCTAssertEqual(AppIconChoice.from(alternateIconName: choice.alternateIconName), choice)
        }
        XCTAssertEqual(AppIconChoice.from(alternateIconName: "AppIcon-Retired"), .white, "an unknown icon reads as the primary one")
    }

    /// Every alternate icon is in the app's Info.plist (from ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES), so
    /// setAlternateIconName(_:) finds it.
    func testTheAppListsEveryAlternateIcon() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        XCTAssertEqual(Set(alternates.keys), Set(AppIconChoice.allCases.compactMap(\.alternateIconName)))
    }

    /// App settings offers the app icon under Appearance (the app can change its icon on the simulator).
    func testAppSettingsOffersTheAppIcon() throws {
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let host = AccessibilityTreeText.Host(
            NavigationStack { AppSettingsView() }.environmentObject(userStore),
            size: CGSize(width: 390, height: 844),
            settle: 0.3
        )
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(AppSettingsCopy.appIconTitle), text)
        XCTAssertTrue(text.contains(AppSettingsCopy.appearanceAndIconFooter), text)
        let label = host.label(ofIdentifier: "settings.appIcon")
        XCTAssertTrue(label?.contains(AppSettingsCopy.appIconTitle) == true, "settings.appIcon is labelled \(label ?? "nil")")
    }
}
