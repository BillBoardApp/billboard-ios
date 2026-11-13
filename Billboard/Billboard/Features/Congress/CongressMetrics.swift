import Foundation

enum CongressMetrics {
    static func percentString(_ value: Double) -> String {
        let clamped = max(0, min(100, value))
        return "\(Int(round(clamped)))%"
    }

    static func ratioString(numerator: Int, denominator: Int) -> String {
        guard denominator > 0 else { return "0%" }
        let pct = (Double(numerator) / Double(denominator)) * 100
        return percentString(pct)
    }

    static func billsProposed(bySponsorIDs sponsorIDs: Set<UUID>, in bills: [Bill]) -> [Bill] {
        bills.filter { bill in
            guard let sponsorID = bill.sponsorMemberID else { return false }
            return sponsorIDs.contains(sponsorID)
        }
    }

    /// "Bills by topic group": the share of `bills` in each topic group (`Bill.category`), most
    /// common first (ties by name), at most `top` rows.
    static func categoryRateRows(for bills: [Bill], top: Int = 5) -> [(label: String, value: String)] {
        guard !bills.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for bill in bills {
            guard let group = bill.category.trimmedNonEmpty else { continue }
            counts[group, default: 0] += 1
        }
        return rateRows(counts, total: bills.count, top: top)
    }

    /// "Bills by topic": the share of `bills` with each topic (`Bill.subCategory`, the AI label),
    /// most common first (ties by name), at most `top` rows. Legacy topic names count under their
    /// new name. R1 counted life areas here under the label "Subcategory Proposal Rates".
    static func topicRateRows(for bills: [Bill], top: Int = 5) -> [(label: String, value: String)] {
        guard !bills.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for bill in bills {
            guard let topic = bill.subCategory?.trimmedNonEmpty else { continue }
            counts[SubscriptionsConfig.canonicalTopic(topic), default: 0] += 1
        }
        return rateRows(counts, total: bills.count, top: top)
    }

    private static func rateRows(_ counts: [String: Int], total: Int, top: Int) -> [(label: String, value: String)] {
        counts
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(max(0, top))
            .map { (label: $0.key, value: ratioString(numerator: $0.value, denominator: total)) }
    }
}
