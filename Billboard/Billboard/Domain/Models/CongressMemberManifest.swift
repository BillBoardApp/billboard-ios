import Foundation

struct CongressMemberManifestItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let chamber: String?
    let state: String?
    let district: String?
    let party: String?
    let depictionImageUrl: URL?
    let currentCongressBillsSupportedCount: Int?
    /// BillBoard's tracked 119th Congress counts; absent from services before APPF-03 and when the
    /// member stats could not be read.
    let trackedSponsoredCount: Int?
    let trackedSupportedCount: Int?

    enum CodingKeys: String, CodingKey {
        case bioguideId
        case name
        case chamber
        case state
        case district
        case party
        case depictionImageUrl
        case currentCongressBillsSupportedCount
        case trackedSponsoredCount
        case trackedSupportedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .bioguideId)
        name = try container.decode(String.self, forKey: .name)
        chamber = try container.decodeIfPresent(String.self, forKey: .chamber)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        party = try container.decodeIfPresent(String.self, forKey: .party)

        // `district` in the manifest may be a string ("1", "At-Large") or a number (1).
        // Decode flexibly: try String, then Int, then Double, falling back to nil.
        if let d = try? container.decodeIfPresent(String.self, forKey: .district) {
            district = d
        } else if let di = try? container.decodeIfPresent(Int.self, forKey: .district) {
            district = String(di)
        } else if let dd = try? container.decodeIfPresent(Double.self, forKey: .district) {
            // handle numeric districts that may come as doubles
            district = String(Int(dd))
        } else {
            district = nil
        }

        if let urlString = try? container.decodeIfPresent(String.self, forKey: .depictionImageUrl) {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            depictionImageUrl = trimmed.isEmpty ? nil : URL(string: trimmed)
        } else {
            depictionImageUrl = nil
        }
        currentCongressBillsSupportedCount = try container.decodeIfPresent(Int.self, forKey: .currentCongressBillsSupportedCount)
        trackedSponsoredCount = try container.decodeIfPresent(Int.self, forKey: .trackedSponsoredCount)
        trackedSupportedCount = try container.decodeIfPresent(Int.self, forKey: .trackedSupportedCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .bioguideId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(chamber, forKey: .chamber)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(district, forKey: .district)
        try container.encodeIfPresent(party, forKey: .party)
        try container.encodeIfPresent(depictionImageUrl?.absoluteString, forKey: .depictionImageUrl)
        try container.encodeIfPresent(currentCongressBillsSupportedCount, forKey: .currentCongressBillsSupportedCount)
        try container.encodeIfPresent(trackedSponsoredCount, forKey: .trackedSponsoredCount)
        try container.encodeIfPresent(trackedSupportedCount, forKey: .trackedSupportedCount)
    }

    var chamberLabel: String? {
        chamberDisplayName
    }

    var chamberDisplayName: String? {
        guard let normalized = chamberNormalized else { return normalizedOrNil(chamber) }
        switch normalized {
        case "House":
            return "House of Representatives"
        default:
            return normalized
        }
    }

    var chamberNormalized: String? {
        guard let value = normalizedOrNil(chamber) else { return nil }
        let lower = value.lowercased()

        // Map common variants to canonical chamber names used by the UI.
        if lower.contains("house") || lower.contains("representative") {
            return "House"
        }

        if lower.contains("senate") {
            return "Senate"
        }

        // Fallback: capitalize the value for display/grouping.
        return value.capitalized
    }

    /// "VA-11" for House members, the state code for senators.
    var regionLabel: String? {
        if let label = CongressMember.districtLabel(state: state, district: district) { return label }
        if let state = normalizedOrNil(state) { return state }
        return nil
    }

    private func normalizedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension CongressMemberManifestItem {
    /// Roster order: last name, then first name (see `CongressMemberNameSortKey`).
    static func rosterSorted(_ items: [CongressMemberManifestItem]) -> [CongressMemberManifestItem] {
        items
            .map { (item: $0, key: CongressMemberNameSortKey(name: $0.name)) }
            .sorted { $0.key < $1.key }
            .map(\.item)
    }

    init(dto: UserAPIContractsV1.CongressMemberManifestItem) {
        self.id = dto.bioguideId
        self.name = dto.name
        self.chamber = dto.chamber
        self.state = dto.state
        self.district = dto.district
        self.party = dto.party
        if let raw = dto.depictionImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            self.depictionImageUrl = URL(string: raw)
        } else {
            self.depictionImageUrl = nil
        }
        self.currentCongressBillsSupportedCount = dto.currentCongressBillsSupportedCount
        self.trackedSponsoredCount = dto.trackedSponsoredCount
        self.trackedSupportedCount = dto.trackedSupportedCount
    }
}
