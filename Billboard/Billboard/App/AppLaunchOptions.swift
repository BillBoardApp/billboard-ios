import Foundation
import UIKit

enum AppLaunchOptions {
    private static let uiTestingFlag = "-bbUITesting"
    private static let resetStateFlag = "-bbResetState"
    private static let disableAnimationsFlag = "-bbDisableAnimations"
    private static let maxHistoryWindowFlag = "-bbUseMaxHistoryWindow"

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(uiTestingFlag)
    }

    static var shouldStreamlineStartupForUITests: Bool {
        isUITesting
    }

    static func prepareAppForLaunch() {
        guard isUITesting else { return }

        if ProcessInfo.processInfo.arguments.contains(resetStateFlag),
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            // State that no longer lives in UserDefaults.
            UserStore.clearAllCachedProfiles()
            PushTokenStore.clear()
        }

        if ProcessInfo.processInfo.arguments.contains(maxHistoryWindowFlag) {
            UserDefaults.standard.set(
                BillboardHistoryWindow.maxExpanded.rawValue,
                forKey: BillboardDisplayStorage.historyWindowDaysKey
            )
        }

        if ProcessInfo.processInfo.arguments.contains(disableAnimationsFlag) {
            UIView.setAnimationsEnabled(false)
        }
    }
}
