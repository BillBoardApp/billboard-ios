import SwiftUI
import UserNotifications

// MARK: - Watch and notifications (UX-47)

/// Why watching a bill can't notify the person on this device (UX-47). The Watch row says so in place of its
/// promise, "Get notified when Congress acts on it.", and the watch is kept either way.
enum BillWatchNotificationBlock: Equatable {
    /// iOS permission is off.
    case permissionOff
    /// iOS hasn't asked, and turning Watch on won't ask now: the bill is watched already, or the app has asked
    /// before.
    case permissionNotAsked
    /// Profile's Notifications switch is off.
    case notificationsOff
    /// Profile's Actions in Congress switch is off: Congress acting on a watched bill comes as that type.
    case actionsInCongressOff

    /// - Parameters:
    ///   - permission: iOS permission; nil until it is read, which blocks nothing, so no warning flashes.
    ///   - settings: The switches this device last saved (`NotificationSettingsStore.savedSettings`).
    ///   - isWatching: The bill (or a member of its companion group) is watched.
    ///   - hasAskedPermission: The app has shown iOS's prompt (`AppNotificationStorage.pushPermissionPromptedKey`).
    static func make(
        permission: UNAuthorizationStatus?,
        settings: DeviceNotificationSettings,
        isWatching: Bool,
        hasAskedPermission: Bool
    ) -> BillWatchNotificationBlock? {
        // Profile's rules for what iOS allows.
        let notifications = NotificationsSectionModel(permission: permission, settings: settings)
        if notifications.isPermissionDenied { return .permissionOff }
        // Not asked yet, with Watch off: turning it on asks (`asksPermission`), so the promise stands until then.
        if notifications.isPermissionNotAsked, isWatching || hasAskedPermission { return .permissionNotAsked }
        if !settings.notificationsEnabled { return .notificationsOff }
        if !NotificationKind.actionsInCongress.isOn(in: settings) { return .actionsInCongressOff }
        return nil
    }

    /// Whether turning Watch on shows iOS's notification prompt: only when the app has never asked (UX-47). It is
    /// the prompt Profile's Notifications switch and the Updates card show, with the same once-only flag.
    static func asksPermission(permission: UNAuthorizationStatus?, hasAskedPermission: Bool) -> Bool {
        permission == .notDetermined && !hasAskedPermission
    }
}

extension BillWatchCopy {
    /// The Watch row's caption: its promise, or why the watch can't notify on this device (UX-47). The permission
    /// lines start with Profile's words (`NotificationsSectionModel`).
    static func rowSubtitle(blockedBy block: BillWatchNotificationBlock?) -> String {
        switch block {
        case nil:
            return rowSubtitle
        case .permissionOff:
            return "Notifications are off in iOS Settings. Turn them on there to get notified when Congress acts on it."
        case .permissionNotAsked:
            return "Billboard needs your permission before it can send notifications. Turn them on in Profile."
        case .notificationsOff:
            return "Notifications are off in Profile. Turn them on there to get notified when Congress acts on it."
        case .actionsInCongressOff:
            return "\(NotificationKind.actionsInCongress.title) notifications are off in Profile. Turn them on there to get notified when Congress acts on it."
        }
    }

    /// Said to VoiceOver when the Watch row is turned off.
    static let stoppedWatchingAnnouncement = "Stopped watching this bill"

    /// What VoiceOver hears after the Watch row is toggled (UX-47): "Stopped watching this bill" when it is turned
    /// off; when it is turned on and the watch can't notify on this device, "Watching this bill. " and the row's
    /// caption, so the person hears why (a project decision of 2026-11-23, D8 (b)). Nil when it is turned on and
    /// nothing blocks it: the switch says its own new value. The page also says nothing while iOS's prompt is about to
    /// show (`asksPermission`), and reads `blockedBy` only after it has read iOS's permission.
    static func announcement(isWatching: Bool, blockedBy block: BillWatchNotificationBlock?) -> String? {
        guard isWatching else { return stoppedWatchingAnnouncement }
        guard let block else { return nil }
        return "Watching this bill. \(rowSubtitle(blockedBy: block))"
    }
}

/// What the bill page reads and does about notifications for its Watch row (UX-47): iOS's permission, the
/// switches this device last saved, whether the app has shown iOS's prompt, and the prompt itself. Tests put fakes
/// here.
nonisolated struct WatchNotificationAccess {
    /// Reads iOS's notification permission.
    var permission: @MainActor () async -> UNAuthorizationStatus
    /// Holds the saved switches (`NotificationSettingsStore.savedSettings`) and
    /// `AppNotificationStorage.pushPermissionPromptedKey`.
    var defaults: UserDefaults
    /// Shows iOS's prompt: the app delegate asks and registers for pushes.
    var showPrompt: @MainActor () -> Void

    static var live: WatchNotificationAccess {
        WatchNotificationAccess(
            permission: {
                await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
                    UNUserNotificationCenter.current().getNotificationSettings { settings in
                        continuation.resume(returning: settings.authorizationStatus)
                    }
                }
            },
            defaults: .standard,
            showPrompt: {
                NotificationCenter.default.post(name: .billboardShouldPromptPushPermission, object: nil)
            }
        )
    }
}

private nonisolated struct WatchNotificationAccessKey: EnvironmentKey {
    static var defaultValue: WatchNotificationAccess { .live }
}

extension EnvironmentValues {
    /// The bill page's notification reads and iOS's prompt, for its Watch row (UX-47). Tests put fakes here.
    var watchNotificationAccess: WatchNotificationAccess {
        get { self[WatchNotificationAccessKey.self] }
        set { self[WatchNotificationAccessKey.self] = newValue }
    }
}
