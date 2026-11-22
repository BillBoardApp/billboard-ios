import SwiftUI
import UIKit

/// App settings copy and choices (spec D 2.5.7). Pure, for tests.
enum AppSettingsCopy {
    static let appearanceFooter = "System matches your iPhone's light or dark setting."
    /// Under Appearance when the app can change its icon: with dark icons, iOS shows the navy look whichever is picked.
    static let appearanceAndIconFooter = "System matches your iPhone's light or dark setting. When your iPhone shows dark icons, both app icons are navy."
    static let appIconTitle = "App icon"
    /// Under Appearance, and said to VoiceOver, when iOS refused the change and the picker was put back.
    static let appIconFailedText = "Couldn't change the app icon."
    static let appIconErrorIdentifier = "settings.appIcon.error"
    static let billTypesFooter = "Choose which kinds of bills appear on the Bills tab and in notifications. Keep at least one."
    static let historyPickerTitle = "Show bills from the last"
    static let replayTitle = "Replay the tour"
    static let replaySubtitle = "A 3-step tour of voting in Billboard."

    /// "1 week (Recommended)", "2 weeks".
    static func historyOptionTitle(_ window: BillboardHistoryWindow) -> String {
        guard let subtitle = window.subtitle else { return window.title }
        return "\(window.title) (\(subtitle))"
    }

    /// The picker's choices: the standard windows, plus the stored one when an older build saved a
    /// value that is not among them (so the picker never shows an empty selection).
    static func historyOptions(selectedDays: Int) -> [BillboardHistoryWindow] {
        let standard = BillboardHistoryWindow.allCases
        let selected = BillboardHistoryWindow.from(rawValue: selectedDays)
        guard !standard.contains(selected) else { return standard }
        return (standard + [selected]).sorted { $0.rawValue < $1.rawValue }
    }

    /// The caption under the picker: "Bills from the last 1 week. You can add one more week at a
    /// time from the Bills tab."
    static func historyFooter(_ window: BillboardHistoryWindow) -> String {
        "Bills from the last \(window.title). You can add one more week at a time from the Bills tab."
    }

    /// Sentence case for the bill-type names the model spells in title case ("Joint resolutions").
    static func billTypeTitle(_ contentType: BillContentTypePreference) -> String {
        let title = contentType.title
        guard let first = title.first else { return title }
        return String(first) + title.dropFirst().lowercased()
    }

    /// A bill type can be turned off only while another one stays on.
    static func canTurnOff(_ contentType: BillContentTypePreference, enabled: Set<BillContentTypePreference>) -> Bool {
        !(enabled.count == 1 && enabled.contains(contentType))
    }

    /// "Couldn't turn off joint resolutions.": under the Bill types switches, and said to VoiceOver, when a switch's
    /// save failed and the switch was put back (UX-48). `isOn` is the value the switch asked for.
    static func billTypeSaveFailedText(_ contentType: BillContentTypePreference, isOn: Bool) -> String {
        "Couldn't turn \(isOn ? "on" : "off") \(billTypeTitle(contentType).lowercased())."
    }

    static let billTypesErrorIdentifier = "settings.billTypes.error"
}

/// App settings (spec D 2.5.7; Civic Record spec 4.69): Appearance and the app icon, Bill types, how far back the
/// Bills tab goes, and the tour, as a settings list on paper (spec 3.25). Switches in `controlOn`; "Replay the tour"
/// is an ink text row. Notifications moved to Profile.
struct AppSettingsView: View {
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(ProductTutorialStorage.replayRequestedKey) private var replayTutorialRequested = false
    @AppStorage(BillboardDisplayStorage.historyWindowDaysKey) private var billboardHistoryWindowDays = BillboardHistoryWindow.default.rawValue
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    /// A switch's failed save (UX-48), until the next switch is flipped.
    @State private var billTypesError: String?
    /// The Home Screen icon, as iOS reports it when the screen opens.
    @State private var appIcon = AppIconChoice.from(alternateIconName: UIApplication.shared.alternateIconName)
    /// A refused icon change, until the next change.
    @State private var appIconError: String?
    private let canChangeAppIcon = UIApplication.shared.supportsAlternateIcons

    private var selectedBillboardHistoryWindow: BillboardHistoryWindow {
        BillboardHistoryWindow.from(rawValue: billboardHistoryWindowDays)
    }

    private var effectiveBillContentTypes: Set<BillContentTypePreference> {
        userStore.profile.effectiveSelectedBillContentTypes
    }

    private func contentTypeBinding(_ contentType: BillContentTypePreference) -> Binding<Bool> {
        Binding(
            get: { effectiveBillContentTypes.contains(contentType) },
            set: { newValue in
                var updated = effectiveBillContentTypes
                if newValue {
                    updated.insert(contentType)
                } else {
                    guard AppSettingsCopy.canTurnOff(contentType, enabled: updated) else { return }
                    updated.remove(contentType)
                }
                billTypesError = nil
                let save = userStore.updateSelectedBillContentTypes(
                    Array(updated).sorted { $0.sortOrder < $1.sortOrder }
                )
                Task {
                    guard await !save.value else { return }
                    billTypesError = AppSettingsCopy.billTypeSaveFailedText(contentType, isOn: newValue)
                }
            }
        )
    }

    /// Asks iOS to change the icon (iOS then confirms it in an alert); puts the picker back if iOS refuses.
    private var appIconBinding: Binding<AppIconChoice> {
        Binding(
            get: { appIcon },
            set: { choice in
                guard choice != appIcon else { return }
                let previous = appIcon
                appIcon = choice
                appIconError = nil
                Task {
                    do {
                        try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
                    } catch {
                        appIcon = previous
                        appIconError = AppSettingsCopy.appIconFailedText
                    }
                }
            }
        )
    }

    var body: some View {
        List {
            Section {
                Picker(selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    SettingsRowText("Appearance")
                }
                .accessibilityIdentifier("settings.appearance")

                if canChangeAppIcon {
                    Picker(selection: appIconBinding) {
                        ForEach(AppIconChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    } label: {
                        SettingsRowText(AppSettingsCopy.appIconTitle)
                    }
                    .accessibilityIdentifier("settings.appIcon")
                }
            } header: {
                RecordListHeader("Appearance")
            } footer: {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    if let appIconError {
                        RecordErrorText(appIconError)
                            .accessibilityIdentifier(AppSettingsCopy.appIconErrorIdentifier)
                    }
                    RecordListFooter(canChangeAppIcon ? AppSettingsCopy.appearanceAndIconFooter : AppSettingsCopy.appearanceFooter)
                }
            }
            .recordListRows()

            Section {
                ForEach(BillContentTypePreference.allCases, id: \.rawValue) { contentType in
                    Toggle(isOn: contentTypeBinding(contentType)) {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowText(AppSettingsCopy.billTypeTitle(contentType))
                            Text(contentType.subtitle)
                                .textRole(.caption)
                                .foregroundStyle(BillboardColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .billboardToggle()
                    .disabled(!AppSettingsCopy.canTurnOff(contentType, enabled: effectiveBillContentTypes))
                    .accessibilityIdentifier("settings.billType.\(contentType.rawValue)")
                }
            } header: {
                RecordListHeader("Bill types")
            } footer: {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    if let billTypesError {
                        RecordErrorText(billTypesError)
                            .accessibilityIdentifier(AppSettingsCopy.billTypesErrorIdentifier)
                    }
                    RecordListFooter(AppSettingsCopy.billTypesFooter)
                }
            }
            .recordListRows()

            Section {
                Picker(selection: $billboardHistoryWindowDays) {
                    ForEach(AppSettingsCopy.historyOptions(selectedDays: billboardHistoryWindowDays)) { window in
                        Text(AppSettingsCopy.historyOptionTitle(window)).tag(window.rawValue)
                    }
                } label: {
                    SettingsRowText(AppSettingsCopy.historyPickerTitle)
                }
                .accessibilityIdentifier("settings.historyWindow")
            } header: {
                RecordListHeader("Bills tab")
            } footer: {
                RecordListFooter(AppSettingsCopy.historyFooter(selectedBillboardHistoryWindow))
            }
            .recordListRows()

            Section {
                Button {
                    replayTutorialRequested = true
                } label: {
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                        Text(AppSettingsCopy.replayTitle)
                            .textRole(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(BillboardColors.interactive)
                        Text(AppSettingsCopy.replaySubtitle)
                            .textRole(.caption)
                            .foregroundStyle(BillboardColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("settings.replayTour")
            }
            .recordListRows()
        }
        .recordList()
        // A failed switch is said from the list, not its footer: a list makes its rows only as they scroll into
        // view (UX-48).
        .announcesToVoiceOver(billTypesError)
        .announcesToVoiceOver(appIconError)
        .navigationTitle("App settings")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("settings.app.screen")
    }
}
