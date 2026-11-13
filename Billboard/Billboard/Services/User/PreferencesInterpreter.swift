import Foundation

struct PreferencesSummary: Equatable {
    let subscribedSubCategories: [String]
    let subscribedLifeAreas: [String]
    let subscribedMemberIDs: [UUID]
    let watchedBillGUIDs: [String]
    let selectedBillContentTypes: [BillContentTypePreference]

    static let empty = PreferencesSummary(
        subscribedSubCategories: [],
        subscribedLifeAreas: [],
        subscribedMemberIDs: [],
        watchedBillGUIDs: [],
        selectedBillContentTypes: []
    )
}

enum PreferencesInterpreter {
    /// The profile fields stored as preference rows. Topics are read under their current names and
    /// de-duplicated (LLM-10): during the label switch a user may hold a row under a legacy name, or
    /// under both names.
    static func summarize(_ preferences: [PreferencesItem]) -> PreferencesSummary {
        let subscribedSubCategories = Array(
            Set(
                preferences
                    .filter { $0.kind == .topic }
                    .map { SubscriptionsConfig.canonicalTopic($0.value) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let subscribedLifeAreas = Array(
            Set(
                preferences
                    .filter { $0.kind == .lifeArea }
                    .map { $0.value }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let subscribedMemberIDs: [UUID] = Array(
            Set(
                preferences
                    .filter { $0.kind == .congressMember }
                    .compactMap { item in
                        let raw = item.value
                        guard !raw.isEmpty else { return nil }

                        // Server/client may store either a UUID string or a manifest-style ID
                        // (e.g. "A000382"). Normalize to the internal deterministic UUID.
                        if let uuid = UUID(uuidString: raw) {
                            return uuid
                        }
                        return UUID.deterministic(from: raw)
                    }
            )
        )
        .sorted { $0.uuidString < $1.uuidString }

        let watchedBillGUIDs = Array(
            Set(
                preferences
                    .filter { $0.kind == .watch }
                    .map { $0.value }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()

        let selectedBillContentTypes = Array(
            Set(
                preferences
                    .filter { $0.kind == .contentType }
                    .compactMap { item in
                        let cleaned = item.value
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        return BillContentTypePreference(rawValue: cleaned)
                    }
            )
        )
        .sorted { $0.sortOrder < $1.sortOrder }

        return PreferencesSummary(
            subscribedSubCategories: subscribedSubCategories,
            subscribedLifeAreas: subscribedLifeAreas,
            subscribedMemberIDs: subscribedMemberIDs,
            watchedBillGUIDs: watchedBillGUIDs,
            selectedBillContentTypes: selectedBillContentTypes
        )
    }
}
