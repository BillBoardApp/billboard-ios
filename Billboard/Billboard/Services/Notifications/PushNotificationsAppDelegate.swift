import Foundation
import os
import UIKit
import UserNotifications

final class PushNotificationsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = AppLog.push
    private var hasRequestedRemoteNotificationsThisLaunch = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        logger.info("Push delegate initialized")
        return true
    }

    // MARK: - Registration

    func requestAuthorizationAndRegisterIfPossible() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    self.requestRemoteNotificationsIfNeeded(reason: "registering")
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    self.logger.info("Push permission prompt result: granted=\(granted)")
                    guard granted else { return }
                    DispatchQueue.main.async {
                        self.requestRemoteNotificationsIfNeeded(reason: "registering")
                    }
                }
            case .denied:
                self.logger.warning("Push permission denied")
                break
            @unknown default:
                self.logger.warning("Push permission unknown authorizationStatus")
                break
            }
        }
    }

    func syncRemoteNotificationRegistrationIfAuthorized() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    self.requestRemoteNotificationsIfNeeded(reason: "syncing")
                }
            case .notDetermined, .denied:
                break
            @unknown default:
                self.logger.warning("Push permission unknown during registration sync")
            }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        let suffix = String(token.suffix(8))
        logger.info("Registered for remote notifications (token suffix=\(suffix, privacy: .public))")

        // Persist immediately to avoid missing observers during app launch transitions.
        PushTokenStore.save(token)
        NotificationCenter.default.post(name: .billboardDidRegisterPushToken, object: nil, userInfo: ["token": token])
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        hasRequestedRemoteNotificationsThisLaunch = false
        logger.error("Failed to register for remote notifications: \(String(describing: error), privacy: .public)")
    }

    // MARK: - Receiving

    /// Silent/background pushes (content-available) come through here.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        handlePush(userInfo: userInfo)
        completionHandler(.newData)
    }

    /// Foreground presentation. The push is always processed; the banner and
    /// sound are shown only if the user's in-app settings allow its type.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        handlePush(userInfo: userInfo)

        let payload = PushNotificationPayload(userInfo: userInfo)
        if PushPresentationSettings.allowsForegroundPresentation(of: payload) {
            completionHandler([.banner, .sound, .badge])
        } else {
            logger.info("Foreground push not presented: type disabled in notification settings")
            completionHandler([])
        }
    }

    /// User taps the notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handlePush(userInfo: response.notification.request.content.userInfo, wasUserInteraction: true)
        completionHandler()
    }

    private func handlePush(userInfo: [AnyHashable: Any], wasUserInteraction: Bool = false) {
        let payload = PushNotificationPayload(userInfo: userInfo)

        // Bill alerts are delivered with bill identifiers, but are handled via the alert pathway
        // (we ingest the alert and may deep-link to bill detail on user tap).
        let isBillAlert = payload.isBillAlertRelevant

        let domainText = String(describing: payload.domain)
        let notifText = String(describing: payload.notificationType)
        let guidText = payload.normalizedBillGuid ?? "(nil)"
        let updatedAtText = payload.updatedAt ?? "(nil)"
        let legacyEventText = payload.legacyEvent.isEmpty ? "(none)" : payload.legacyEvent
        logger.info("Received push domain=\(domainText, privacy: .public) type=\(notifText, privacy: .public) billId=\(guidText, privacy: .public) updatedAt=\(updatedAtText, privacy: .public) legacyEvent=\(legacyEventText, privacy: .public) userTap=\(wasUserInteraction, privacy: .public)")

        if payload.isWeeklyDigestRelevant {
            if wasUserInteraction {
                PendingPushDeepLink.save(.weeklyDigest(digestId: payload.normalizedDigestID))
                NotificationCenter.default.post(name: .billboardDidSavePendingPushDeepLink, object: nil)
            }
            return
        }

        // Bills
        if !isBillAlert, payload.isBillsManifestRelevant {
            NotificationCenter.default.post(name: .billboardBillsManifestDidChange, object: nil)
        }

        // Handle all bill notifications (single or multiple)
        if !isBillAlert {
            let billIds = payload.allBillIds
            guard !billIds.isEmpty else { return }

            if wasUserInteraction {
                PendingPushDeepLink.save(.digest(billIds: billIds, notificationType: payload.notificationType != .unknown ? payload.notificationType.rawValue : nil))
            }

            // Post individual notifications for each bill
            for guid in billIds {
                var info: [AnyHashable: Any] = [
                    "guid": guid,
                    "user_interaction": false  // Don't deep link individual bills; deep link is handled via PendingPushDeepLink
                ]
                if payload.notificationType != .unknown {
                    info["notificationType"] = payload.notificationType.rawValue
                }
                NotificationCenter.default.post(name: .billboardBillDidChange, object: nil, userInfo: info)
            }

            if wasUserInteraction {
                NotificationCenter.default.post(name: .billboardDidSavePendingPushDeepLink, object: nil)
            }
        }

        // Bill alerts
        if isBillAlert {
            if wasUserInteraction {
                PendingPushDeepLink.save(
                    .alert(
                        .init(
                            alertId: payload.normalizedAlertId,
                            billId: payload.normalizedBillGuid,
                            category: payload.category,
                            subCategory: payload.subCategory,
                            updatedAt: payload.updatedAt,
                            title: payload.apsTitle,
                            subtitle: payload.apsSubtitle,
                            body: payload.apsBody,
                            alertText: payload.alertText,
                            actionDate: payload.alertActionDate,
                            actionCode: payload.alertActionCode,
                            actionType: payload.alertActionType
                        )
                    )
                )
            }
            var info: [AnyHashable: Any] = [:]

            info["user_interaction"] = wasUserInteraction

            if let alertId = payload.normalizedAlertId { info["alertId"] = alertId }
            if let billId = payload.normalizedBillGuid { info["billId"] = billId }
            if let category = payload.category { info["category"] = category }
            if let subCategory = payload.subCategory { info["subCategory"] = subCategory }
            if let updatedAt = payload.updatedAt { info["updatedAt"] = updatedAt }
            if let title = payload.apsTitle { info["title"] = title }
            if let subtitle = payload.apsSubtitle { info["subtitle"] = subtitle }
            if let body = payload.apsBody { info["body"] = body }

            if let alertText = payload.alertText { info["alertText"] = alertText }
            if let actionDate = payload.alertActionDate { info["actionDate"] = actionDate }
            if let actionCode = payload.alertActionCode { info["actionCode"] = actionCode }
            if let actionType = payload.alertActionType { info["actionType"] = actionType }

            NotificationCenter.default.post(name: .billboardBillAlertDidChange, object: nil, userInfo: info)
        }
    }

    private func requestRemoteNotificationsIfNeeded(reason: String) {
        guard !hasRequestedRemoteNotificationsThisLaunch else {
            logger.debug("Remote notifications registration already requested this launch; skipping duplicate \(reason, privacy: .public) request")
            return
        }

        hasRequestedRemoteNotificationsThisLaunch = true
        logger.info("Push permission already granted; \(reason, privacy: .public) remote notifications registration")
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// The in-app notification preferences last saved on this device, used to decide
/// whether a push that arrives while the app is in the foreground is shown.
///
/// The master switch is `AppNotificationStorage.notificationsEnabledKey`, which
/// `NotificationSettingsStore` already persists. Per-type toggles come from a
/// snapshot of `DeviceNotificationSettings` that the settings store saves with
/// `save(_:)`; until one exists, every type is allowed (the server already
/// filters by type before sending).
///
/// Only the toggles are stored. The device id stays in the Keychain (see
/// `DeviceIdStore`) so it is not copied into backups through UserDefaults.
enum PushPresentationSettings {
    static let snapshotKey = "BillBoard.notifications.settingsSnapshot.v1"

    /// The stored subset of `DeviceNotificationSettings`: everything except the device id.
    struct Snapshot: Codable, Equatable {
        var notificationsEnabled: Bool
        var notifyNew: Bool
        var notifyUpdated: Bool
        var notifyAlert: Bool
        var notifyPassed: Bool
        var notifyFailed: Bool

        init(_ settings: DeviceNotificationSettings) {
            notificationsEnabled = settings.notificationsEnabled
            notifyNew = settings.notifyNew
            notifyUpdated = settings.notifyUpdated
            notifyAlert = settings.notifyAlert
            notifyPassed = settings.notifyPassed
            notifyFailed = settings.notifyFailed
        }

        enum CodingKeys: String, CodingKey {
            case notificationsEnabled = "notifications_enabled"
            case notifyNew = "notify_new"
            case notifyUpdated = "notify_updated"
            case notifyAlert = "notify_alert"
            case notifyPassed = "notify_passed"
            case notifyFailed = "notify_failed"
        }
    }

    static func save(_ settings: DeviceNotificationSettings, defaults: UserDefaults = .standard) {
        store(Snapshot(settings), defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: snapshotKey)
    }

    /// The saved toggles, or nil when none are saved. Snapshots written by earlier builds
    /// also held the device id; those are rewritten without it.
    static func load(defaults: UserDefaults = .standard) -> Snapshot? {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder.usingDefaultKeys().decode(Snapshot.self, from: data) else {
            return nil
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["device_id"] != nil {
            store(snapshot, defaults: defaults)
        }
        return snapshot
    }

    private static func store(_ snapshot: Snapshot, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func allowsForegroundPresentation(
        of payload: PushNotificationPayload,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let masterEnabled = defaults.object(forKey: AppNotificationStorage.notificationsEnabledKey) as? Bool ?? true
        guard masterEnabled else { return false }

        guard let settings = load(defaults: defaults) else {
            return true
        }
        guard settings.notificationsEnabled else { return false }

        // The weekly brief has its own setting, applied when it is scheduled.
        if payload.isWeeklyDigestRelevant { return true }
        if payload.isBillAlertRelevant { return settings.notifyAlert }

        switch payload.notificationType {
        case .new:
            return settings.notifyNew
        case .updated:
            return settings.notifyUpdated
        case .passed:
            return settings.notifyPassed
        case .failed:
            return settings.notifyFailed
        case .alert:
            return settings.notifyAlert
        case .digest, .unknown:
            // Multi-bill digests mix types; the server already applied the toggles.
            return true
        }
    }
}
