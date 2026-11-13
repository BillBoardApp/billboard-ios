import Foundation

struct BillAlert: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let sponsorMemberID: UUID?
    let billID: UUID?
    let title: String
    let category: String
    let summary: String
    let soWhat: String
    let lifeAreas: [String]
    let subCategory: String?

    // Alert-specific fields (optional; present for push-generated alerts)
    let alertText: String?
    let actionDate: String?
    let actionCode: String?
    let actionType: String?

    let date: Date
}

// MARK: - Renamed topics (LLM-10)

extension BillAlert {
    /// This alert with a legacy topic name in `subCategory` or `category` replaced by its current name
    /// (`SubscriptionsConfig.canonicalTopic`); returns `self` when neither carries one. `BillAlertsStore`
    /// applies it to cached and incoming alerts, which an older build or push may have written.
    func canonicalizingTopics() -> BillAlert {
        let canonicalSubCategory = subCategory.map(SubscriptionsConfig.canonicalTopic)
        let canonicalCategory = SubscriptionsConfig.canonicalTopic(category)
        guard canonicalSubCategory != subCategory || canonicalCategory != category else { return self }

        return BillAlert(
            id: id,
            sponsorMemberID: sponsorMemberID,
            billID: billID,
            title: title,
            category: canonicalCategory,
            summary: summary,
            soWhat: soWhat,
            lifeAreas: lifeAreas,
            subCategory: canonicalSubCategory,
            alertText: alertText,
            actionDate: actionDate,
            actionCode: actionCode,
            actionType: actionType,
            date: date
        )
    }
}
