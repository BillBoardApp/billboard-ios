import Foundation
import os

/// Persists a pending push-tap deep link across app launch.
///
/// Why: if the app is launched from a notification tap (cold start), the UNUserNotificationCenter delegate
/// can fire before SwiftUI views have attached their NotificationCenter subscribers.
/// Storing the deep link lets the UI consume it once ready.
///
/// Values come from a push payload, so they are validated and capped (see
/// `PushPayloadLimits`) both before they are written and when they are read back.
enum PendingPushDeepLink {
    enum Kind: Codable, Equatable {
        case digest(billIds: [String], notificationType: String?)
        case weeklyDigest(digestId: String?)
        case alert(Alert)

        struct Alert: Codable, Equatable {
            var alertId: String?
            var billId: String?
            var category: String?
            var subCategory: String?
            var updatedAt: String?

            var title: String?
            var subtitle: String?
            var body: String?

            var alertText: String?
            var actionDate: String?
            var actionCode: String?
            var actionType: String?
        }

        /// The same link with malformed ids dropped and free text capped, or nil
        /// when nothing routable is left.
        func sanitized() -> Kind? {
            switch self {
            case .digest(let billIds, let notificationType):
                let validIds = PushPayloadLimits.billGuids(billIds)
                guard !validIds.isEmpty else { return nil }
                let type = PushPayloadLimits.identifier(notificationType)
                return .digest(billIds: validIds, notificationType: type)

            case .weeklyDigest(let digestId):
                return .weeklyDigest(digestId: PushPayloadLimits.identifier(digestId))

            case .alert(let alert):
                let fieldLimit = PushPayloadLimits.maxFieldLength
                return .alert(
                    Alert(
                        alertId: PushPayloadLimits.identifier(alert.alertId),
                        billId: BillGuid.validated(alert.billId),
                        category: PushPayloadLimits.text(alert.category, limit: fieldLimit),
                        subCategory: PushPayloadLimits.text(alert.subCategory, limit: fieldLimit),
                        updatedAt: PushPayloadLimits.text(alert.updatedAt, limit: fieldLimit),
                        title: PushPayloadLimits.text(alert.title),
                        subtitle: PushPayloadLimits.text(alert.subtitle),
                        body: PushPayloadLimits.text(alert.body),
                        alertText: PushPayloadLimits.text(alert.alertText),
                        actionDate: PushPayloadLimits.text(alert.actionDate, limit: fieldLimit),
                        actionCode: PushPayloadLimits.text(alert.actionCode, limit: fieldLimit),
                        actionType: PushPayloadLimits.text(alert.actionType, limit: fieldLimit)
                    )
                )
            }
        }
    }

    private static let key = "BillBoard.pendingPushDeepLink.v1"

    static func save(_ kind: Kind, defaults: UserDefaults = .standard) {
        guard let sanitized = kind.sanitized() else {
            AppLog.push.info("Pending push deep link dropped: no valid target")
            return
        }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        defaults.set(data, forKey: key)
    }

    /// Loads and clears the pending deep link.
    static func consume(defaults: UserDefaults = .standard) -> Kind? {
        guard let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return (try? JSONDecoder.usingDefaultKeys().decode(Kind.self, from: data))?.sanitized()
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
