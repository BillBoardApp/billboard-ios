import Foundation

enum PreferencesMutations {
    static func diffStrings(previous: [String], updated: [String]) -> (toAdd: [String], toRemove: [String]) {
        let previousSet = Set(previous)
        let updatedSet = Set(updated)

        let toAdd = Array(updatedSet.subtracting(previousSet))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let toRemove = Array(previousSet.subtracting(updatedSet))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return (toAdd, toRemove)
    }

    static func categoryItems(for topics: [String]) -> [PreferencesItem] {
        topics
            .map { topic in
                let category = SubscriptionsConfig.subcategoryGroups.first(where: { $0.value.contains(topic) })?.key
                return PreferencesItem(subCategory: nil, preference: topic, category: category, type: "Category")
            }
    }

    static func lifeAreaItems(for lifeAreas: [String]) -> [PreferencesItem] {
        lifeAreas.map { life in
            PreferencesItem(subCategory: nil, preference: life, category: nil, type: "Life Area")
        }
    }

    static func congressMemberItemValue(manifestId: String?, uuid: UUID) -> String {
        let cleaned = (manifestId?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        return cleaned ?? uuid.uuidString
    }

    static func congressMemberItems(values: [String]) -> [PreferencesItem] {
        values.map { value in
            PreferencesItem(subCategory: nil, preference: value, category: "Congress", type: "Congress Member")
        }
    }

    static func watchItems(for guids: [String]) -> [PreferencesItem] {
        guids.map { guid in
            PreferencesItem(subCategory: nil, preference: guid, category: "", type: "Watch")
        }
    }

    static func contentTypeItems(for contentTypes: [BillContentTypePreference]) -> [PreferencesItem] {
        contentTypes.map { contentType in
            PreferencesItem(subCategory: nil, preference: contentType.rawValue, category: "", type: "Content Type")
        }
    }
}
