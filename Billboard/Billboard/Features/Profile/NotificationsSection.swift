import SwiftUI
import UIKit
import UserNotifications

/// The push types a user can turn on or off, in the order Profile lists them (spec D 2.5.7). The
/// names follow the glossary: "Actions in Congress" is the `alert` type.
enum NotificationKind: String, CaseIterable, Identifiable {
    case newBills
    case updatedBills
    case actionsInCongress
    case passedBills
    case failedBills

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newBills: return "New bills"
        case .updatedBills: return "Updated bills"
        case .actionsInCongress: return "Actions in Congress"
        case .passedBills: return "Passed bills"
        case .failedBills: return "Failed bills"
        }
    }

    var accessibilityIdentifier: String {
        "profile.notifications.\(rawValue)"
    }

    /// The stored switch for this type.
    func isOn(in settings: DeviceNotificationSettings) -> Bool {
        switch self {
        case .newBills: return settings.notifyNew
        case .updatedBills: return settings.notifyUpdated
        case .actionsInCongress: return settings.notifyAlert
        case .passedBills: return settings.notifyPassed
        case .failedBills: return settings.notifyFailed
        }
    }
}

/// What the Notifications section shows for an iOS permission state and the device's settings
/// (R1's App Settings rules, APPF-04, moved to Profile). Pure, for tests.
struct NotificationsSectionModel: Equatable {
    /// iOS permission; nil until the first read, so "Not asked yet" does not flash for users who
    /// allowed notifications.
    var permission: UNAuthorizationStatus?
    var settings: DeviceNotificationSettings
    /// Loading or saving the device settings.
    var isBusy = false

    static let deniedHint = "Notifications are off in iOS Settings. Turn them on there to use these options."
    static let notAskedHint = "Billboard needs your permission before it can send notifications. Turn them on to use these options."
    static let weeklyBriefTitle = "Weekly Brief in Updates"
    static let weeklyBriefFootnote = "A short summary each week of what happened to the bills and members you follow."

    /// iOS blocks delivery when permission is denied, whatever the in-app switches say.
    var isPermissionDenied: Bool { permission == .denied }

    /// iOS has not asked yet (for example "Not now" on the Updates card), so nothing can arrive.
    var isPermissionNotAsked: Bool { permission == .notDetermined }

    var isDeliveryBlockedBySystem: Bool { isPermissionDenied || isPermissionNotAsked }

    /// The master switch shows the effective state: off until iOS permission is granted.
    var isMasterOn: Bool { settings.notificationsEnabled && !isDeliveryBlockedBySystem }

    var isMasterDisabled: Bool { isBusy || isDeliveryBlockedBySystem }

    /// The per-type switches keep their stored values but cannot change while nothing can arrive.
    var areKindTogglesDisabled: Bool {
        isBusy || isDeliveryBlockedBySystem || !settings.notificationsEnabled
    }

    /// The value next to "iOS permission".
    var permissionText: String {
        guard let permission else { return "Checking…" }
        switch permission {
        case .authorized:
            return "Allowed"
        case .provisional:
            // Delivered quietly to Notification Center without sounds or banners.
            return "Allowed quietly"
        case .ephemeral:
            return "Allowed for now"
        case .denied:
            return "Off"
        case .notDetermined:
            return "Not asked yet"
        @unknown default:
            return "Not known"
        }
    }

    /// The hint under the permission line, when one applies.
    var permissionHint: String? {
        if isPermissionDenied { return Self.deniedHint }
        if isPermissionNotAsked { return Self.notAskedHint }
        return nil
    }
}

/// Profile's Notifications section, drawn from plain values (`NotificationsSection` supplies them),
/// so render tests can draw every permission state.
///
/// Civic Record spec 4.62: one slip of rows with hairlines between them. "iOS permission" with its value
/// (`ink2`, or Off in `danger`) and, when iOS blocks delivery, the hint and a secondary capsule ("Open iOS
/// Settings" or "Turn on notifications"); the master switch; the five kinds indented 16 pt; then "Weekly
/// Brief in Updates" with its footnote. Switches in `controlOn`. An error under the slip in `danger` with
/// `exclamationmark.circle`.
struct NotificationsSectionContent: View {
    let model: NotificationsSectionModel
    let isWeeklyBriefOn: Bool
    let errorMessage: String?
    let onSetMaster: (Bool) -> Void
    let onSetKind: (NotificationKind, Bool) -> Void
    let onSetWeeklyBrief: (Bool) -> Void
    let onRequestPermission: () -> Void
    let onOpenSettings: () -> Void

    /// How far the five kinds sit in from the master switch.
    static let kindIndent: CGFloat = BillboardStyle.Space.l

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileLayout.headToContent) {
            SectionHeader("Notifications")

            RollSheet {
                permissionRow
                    .modifier(NotificationRowInsets())

                HairlineRule()
                ProfileToggleRow(
                    title: "Notifications",
                    isOn: Binding(get: { model.isMasterOn }, set: onSetMaster)
                )
                .disabled(model.isMasterDisabled)
                .accessibilityIdentifier("profile.notifications.master")
                .modifier(NotificationRowInsets())

                ForEach(NotificationKind.allCases) { kind in
                    HairlineRule()
                        .padding(.leading, Self.kindIndent)
                    ProfileToggleRow(
                        title: kind.title,
                        isOn: Binding(
                            get: { kind.isOn(in: model.settings) },
                            set: { onSetKind(kind, $0) }
                        )
                    )
                    .disabled(model.areKindTogglesDisabled)
                    .accessibilityIdentifier(kind.accessibilityIdentifier)
                    .modifier(NotificationRowInsets(extraLeading: Self.kindIndent))
                }

                HairlineRule()
                VStack(alignment: .leading, spacing: 2) {
                    ProfileToggleRow(
                        title: NotificationsSectionModel.weeklyBriefTitle,
                        isOn: Binding(get: { isWeeklyBriefOn }, set: onSetWeeklyBrief)
                    )
                    .accessibilityIdentifier("profile.notifications.weeklyBrief")

                    Text(NotificationsSectionModel.weeklyBriefFootnote)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .modifier(NotificationRowInsets(bottom: BillboardStyle.Space.m))
            }

            if let errorMessage, !errorMessage.isEmpty {
                RecordErrorText(errorMessage)
                    .accessibilityIdentifier("profile.notifications.error")
            }
        }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    permissionTitle
                    Spacer(minLength: 8)
                    permissionValue
                }
                VStack(alignment: .leading, spacing: 2) {
                    permissionTitle
                    permissionValue
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.notifications.permission")

            if let hint = model.permissionHint {
                Text(hint)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Group {
                    if model.isPermissionDenied {
                        Button("Open iOS Settings", action: onOpenSettings)
                            .accessibilityIdentifier("profile.notifications.openSettings")
                    } else {
                        Button("Turn on notifications", action: onRequestPermission)
                            .accessibilityIdentifier("settings.notifications.requestPermission")
                    }
                }
                .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: false))
                .padding(.bottom, BillboardStyle.Space.m)
            }
        }
    }

    private var permissionTitle: some View {
        Text("iOS permission")
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
    }

    private var permissionValue: some View {
        Text(model.permissionText)
            .textRole(.body)
            .foregroundStyle(model.isPermissionDenied ? BillboardColors.danger : BillboardColors.secondaryText)
    }
}

/// The padding of a row in the Notifications slip: the roll sheet's 16 pt leading and 14 pt trailing
/// edges (plus the kinds' indent), and 4 pt above and below a 44 pt switch row.
private struct NotificationRowInsets: ViewModifier {
    var extraLeading: CGFloat = 0
    var bottom: CGFloat = 4

    func body(content: Content) -> some View {
        content
            .padding(.leading, RollRowInsets.leading + extraLeading)
            .padding(.trailing, RollRowInsets.trailing)
            .padding(.top, 4)
            .padding(.bottom, bottom)
    }
}

/// Profile's Notifications section (spec D 2.5.7): the iOS permission line and button, the master
/// switch, one switch per push type, and the in-app Weekly Brief. Moved from App Settings with
/// R1's behaviour (APPF-04): the switches show "off" while iOS blocks delivery.
struct NotificationsSection: View {
    @ObservedObject var store: NotificationSettingsStore

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var weeklyDigestStore: WeeklyDigestStore
    @AppStorage("BillBoard.pushPermission.prompted.v1") private var hasPromptedForPushPermission = false
    @State private var permission: UNAuthorizationStatus?

    private var model: NotificationsSectionModel {
        NotificationsSectionModel(
            permission: permission,
            settings: store.settings,
            isBusy: store.isLoading || store.isSaving
        )
    }

    var body: some View {
        NotificationsSectionContent(
            model: model,
            isWeeklyBriefOn: weeklyDigestStore.settings.isEnabled,
            errorMessage: store.errorMessage,
            onSetMaster: setNotificationsEnabled,
            onSetKind: setKind,
            onSetWeeklyBrief: setWeeklyBrief,
            onRequestPermission: requestSystemPermission,
            onOpenSettings: openSystemSettings
        )
        .task {
            await refreshPermissionStatus()
            await store.load()
            await refreshPermissionStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The user may have changed permission in iOS Settings while the app was in the background.
            guard newPhase == .active else { return }
            Task { await refreshPermissionStatus() }
        }
    }

    private func setNotificationsEnabled(_ enabled: Bool) {
        Task {
            if enabled, permission == .notDetermined, !hasPromptedForPushPermission {
                hasPromptedForPushPermission = true
                NotificationCenter.default.post(name: .billboardShouldPromptPushPermission, object: nil)
            }
            await store.setNotificationsEnabled(enabled)
            await refreshPermissionStatus()
        }
    }

    private func setKind(_ kind: NotificationKind, _ enabled: Bool) {
        Task {
            switch kind {
            case .newBills: await store.setNotifyNew(enabled)
            case .updatedBills: await store.setNotifyUpdated(enabled)
            case .actionsInCongress: await store.setNotifyAlert(enabled)
            case .passedBills: await store.setNotifyPassed(enabled)
            case .failedBills: await store.setNotifyFailed(enabled)
            }
        }
    }

    private func setWeeklyBrief(_ enabled: Bool) {
        weeklyDigestStore.setEnabled(enabled)
        guard enabled else { return }
        Task {
            await weeklyDigestStore.refresh(profile: userStore.profile, forceRefresh: true)
        }
    }

    /// Asks iOS for permission (the app delegate shows the system prompt and registers).
    private func requestSystemPermission() {
        hasPromptedForPushPermission = true
        NotificationCenter.default.post(name: .billboardShouldPromptPushPermission, object: nil)
        Task {
            if !store.settings.notificationsEnabled {
                await store.setNotificationsEnabled(true)
            }
            await refreshPermissionStatus()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshPermissionStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { value in
                continuation.resume(returning: value)
            }
        }
        permission = settings.authorizationStatus
    }
}

/// A switch row (spec 3.17, 4.62): the title in the `body` role, `ink`, the system switch in `controlOn`,
/// at least 44 pt tall.
struct ProfileToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .billboardToggle()
        .frame(minHeight: 44)
    }
}
