import SwiftUI

/// App settings copy and choices (spec D 2.5.7). Pure, for tests.
enum AppSettingsCopy {
    static let appearanceFooter = "System matches your iPhone's light or dark setting."
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
}

/// App settings (spec D 2.5.7; Civic Record spec 4.69): Appearance, Bill types, how far back the Bills tab
/// goes, and the tour, as a settings list on paper (spec 3.25). Switches in `controlOn`; "Replay the tour" is
/// an ink text row. Notifications moved to Profile.
struct AppSettingsView: View {
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(ProductTutorialStorage.replayRequestedKey) private var replayTutorialRequested = false
    @AppStorage(BillboardDisplayStorage.historyWindowDaysKey) private var billboardHistoryWindowDays = BillboardHistoryWindow.default.rawValue
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system

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
                userStore.updateSelectedBillContentTypes(
                    Array(updated).sorted { $0.sortOrder < $1.sortOrder }
                )
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
            } header: {
                RecordListHeader("Appearance")
            } footer: {
                RecordListFooter(AppSettingsCopy.appearanceFooter)
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
                RecordListFooter(AppSettingsCopy.billTypesFooter)
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
        .navigationTitle("App settings")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("settings.app.screen")
    }
}
