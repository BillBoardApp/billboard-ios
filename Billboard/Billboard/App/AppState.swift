import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var pendingHomeScrollTarget: String?
    @Published var pendingTutorialAnchor: TutorialAnchor?
    @Published var sessionBillboardHistoryWindow: BillboardHistoryWindow?
    @Published var isReconcilingHomeQueue: Bool = false
    @Published var hasCompletedHomeQueueReconciliation: Bool = false
}

extension AppState {
    enum TabIndex: Int {
        case home = 0
        case updates = 1
        case congress = 2
        case profile = 3
    }
}

enum ProductTutorialStorage {
    /// Set by "Where do you vote?" for a new account; the tour starts once the tabs are usable.
    static let pendingAutoShowKey = "BillBoard.tutorial.pendingAutoShow.v1"
    /// Set by App Settings' "Replay the tour".
    static let replayRequestedKey = "BillBoard.tutorial.replayRequested.v1"
    static let completedVersionKey = "BillBoard.tutorial.completedVersion"
    /// 2 is the R2 three-step tour (spec D 2.5.5). Accounts that finished version 1 are not shown it
    /// automatically: only setup's `pendingAutoShowKey` starts the tour.
    static let currentVersion = 2
    static let coordinateSpaceName = "productTutorialSpace"
#if DEBUG
    static let debugStartStepKey = "BillBoard.tutorial.debugStartStep"
#endif
}

enum AppNotificationStorage {
    static let notificationsEnabledKey = "BillBoard.notifications.enabled.local.v1"
}

enum AccountComplianceStorage {
    /// R1's "show the age gate after sign-up" flag. R2 never sets it (a failed sign-up answer is retried
    /// instead, spec D 2.5.2); `RootView` removes a value an R1 build left.
    static let pendingSignupAgeGateKey = "BillBoard.accountCompliance.pendingSignupAgeGate.v1"
    static let cachedAdultStatusKeyPrefix = "BillBoard.accountCompliance.cachedAdultStatus.v1."
}

enum BillboardDisplayStorage {
    static let historyWindowDaysKey = "BillBoard.display.historyWindowDays.v2"
}

struct BillboardHistoryWindow: RawRepresentable, Hashable, CaseIterable, Identifiable, Sendable {
    let rawValue: Int

    nonisolated init(rawValue: Int) {
        self.rawValue = max(7, rawValue)
    }

    static let oneWeek = BillboardHistoryWindow(rawValue: 7)
    static let twoWeeks = BillboardHistoryWindow(rawValue: 14)
    static let threeWeeks = BillboardHistoryWindow(rawValue: 21)
    static let fourWeeks = BillboardHistoryWindow(rawValue: 28)
    static let maxExpanded = BillboardHistoryWindow(rawValue: 364)

    static let allCases: [BillboardHistoryWindow] = [.oneWeek, .twoWeeks, .threeWeeks, .fourWeeks]

    var id: Int { rawValue }

    private var wholeWeeks: Int? {
        rawValue.isMultiple(of: 7) ? (rawValue / 7) : nil
    }

    /// "1 week", "2 weeks", "10 days".
    var title: String {
        if let wholeWeeks {
            return "\(wholeWeeks) week\(wholeWeeks == 1 ? "" : "s")"
        }
        return "\(rawValue) days"
    }

    /// "Recommended" for the default window; nil for the others.
    var subtitle: String? {
        rawValue == Self.default.rawValue ? "Recommended" : nil
    }

    nonisolated var timeInterval: TimeInterval {
        TimeInterval(rawValue * 24 * 60 * 60)
    }

    static let `default`: BillboardHistoryWindow = .oneWeek

    static var current: BillboardHistoryWindow {
        from(rawValue: UserDefaults.standard.integer(forKey: BillboardDisplayStorage.historyWindowDaysKey))
    }

    static func from(rawValue: Int) -> BillboardHistoryWindow {
        rawValue > 0 ? BillboardHistoryWindow(rawValue: rawValue) : .default
    }

    var canExpandFurther: Bool {
        rawValue < Self.maxExpanded.rawValue
    }

    var nextExpanded: BillboardHistoryWindow {
        BillboardHistoryWindow(rawValue: min(rawValue + 7, Self.maxExpanded.rawValue))
    }
}
