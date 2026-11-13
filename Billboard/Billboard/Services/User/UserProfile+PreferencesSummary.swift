import Foundation

extension UserProfile {
    func applying(_ summary: PreferencesSummary) -> UserProfile {
        updating(
            subscribedSubCategories: summary.subscribedSubCategories,
            subscribedLifeAreas: summary.subscribedLifeAreas,
            subscribedMemberIDs: summary.subscribedMemberIDs,
            watchedBillGUIDs: summary.watchedBillGUIDs,
            selectedBillContentTypes: summary.selectedBillContentTypes
        )
    }

    /// This profile with legacy topic names (LLM-10) replaced by their current names, de-duplicated and
    /// sorted as `PreferencesInterpreter.summarize` sorts them; returns `self` when it follows none. For a
    /// profile restored from the disk cache, which an older build may have written with old names, so the
    /// topic picker and the Bills matching see current names before the preferences refresh lands.
    func canonicalizingTopics() -> UserProfile {
        guard subscribedSubCategories.contains(where: SubscriptionsConfig.isLegacyTopic) else { return self }
        let topics = SubscriptionsConfig.canonicalTopics(subscribedSubCategories)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return updating(subscribedSubCategories: topics)
    }
}
