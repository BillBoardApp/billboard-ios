import Foundation

struct CongressMember: Identifiable, Hashable {
    let id: UUID
    let name: String
    let state: String
    /// Two-letter postal code when known (e.g. "VA"); `state` may hold the full name.
    let stateCode: String?
    let chamber: String // e.g. "House", "Senate"

    // Enriched profile (from processed congress member payload)
    let imageUrl: URL?
    let sponsoredLegislationCount: Int?
    let cosponsoredLegislationCount: Int?
    let currentCongressBillsSupportedCount: Int?
    /// BillBoard's own counts of the 119th Congress bills it tracks that this member sponsored or
    /// cosponsored. Nil when the payload does not carry them.
    let trackedSponsoredCount: Int?
    let trackedSupportedCount: Int?

    // Profile
    let biography: String
    let party: PoliticalParty
    let district: String? // House only (e.g. "CA-12")

    // Service
    let termsServed: Int
    let serviceStartYear: Int

    init(
        id: UUID,
        name: String,
        state: String,
        stateCode: String? = nil,
        chamber: String,
        imageUrl: URL? = nil,
        sponsoredLegislationCount: Int? = nil,
        cosponsoredLegislationCount: Int? = nil,
        currentCongressBillsSupportedCount: Int? = nil,
        trackedSponsoredCount: Int? = nil,
        trackedSupportedCount: Int? = nil,
        biography: String = "",
        party: PoliticalParty = .independent,
        district: String? = nil,
        termsServed: Int = 0,
        serviceStartYear: Int = Calendar.current.component(.year, from: Date())
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.stateCode = stateCode
        self.chamber = chamber
        self.imageUrl = imageUrl
        self.sponsoredLegislationCount = sponsoredLegislationCount
        self.cosponsoredLegislationCount = cosponsoredLegislationCount
        self.currentCongressBillsSupportedCount = currentCongressBillsSupportedCount
        self.trackedSponsoredCount = trackedSponsoredCount
        self.trackedSupportedCount = trackedSupportedCount
        self.biography = biography
        self.party = party
        self.district = district
        self.termsServed = termsServed
        self.serviceStartYear = serviceStartYear
    }

    var chamberDisplayName: String {
        CongressMember.displayChamberName(chamber)
    }

    /// Career totals reported by Congress.gov (`sponsoredLegislation.count` / `cosponsoredLegislation.count`).
    var careerActivityRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let sponsoredLegislationCount {
            rows.append((label: "Proposed Legislation", value: "\(sponsoredLegislationCount)"))
        }
        if let cosponsoredLegislationCount {
            rows.append((label: "Supported Legislation", value: "\(cosponsoredLegislationCount)"))
        }
        return rows
    }

    /// BillBoard's own counters: 119th Congress bills it tracks that this member sponsored or
    /// cosponsored. Payloads without the tracked counts (services before APPF-03) still show the
    /// supported count from `currentCongressBillsSupportedCount`.
    var trackedActivityRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let trackedSponsoredCount {
            rows.append((label: "Sponsored in 119th Congress", value: "\(trackedSponsoredCount)"))
        }
        if let supported = trackedSupportedCount ?? currentCongressBillsSupportedCount {
            rows.append((label: "Supported in 119th Congress", value: "\(supported)"))
        }
        return rows
    }

    /// House district for display, e.g. "VA-11" or "AK At-Large". Nil when there is no district.
    var districtLabel: String? {
        CongressMember.districtLabel(state: stateCode ?? state, district: district)
    }

    static func displayChamberName(_ chamber: String) -> String {
        switch chamber {
        case "House":
            return "House of Representatives"
        default:
            return chamber
        }
    }

    /// Formats a House district as the state code plus the number without a leading zero ("VA-11",
    /// "VA-1", as the frames and every affiliation line write it: `CongressMemberLabel.seat`,
    /// `VoteResultsFormatting.districtLabel`), or "AK At-Large" for at-large seats. The state prefix is
    /// only added when `state` is a two-letter code. Returns nil when there is no district.
    static func districtLabel(state: String?, district: String?) -> String? {
        guard let rawDistrict = district?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDistrict.isEmpty else { return nil }

        let upperState = state?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let stateCode = (upperState.count == 2 && upperState.allSatisfy(\.isLetter)) ? upperState : ""

        guard let normalized = DistrictNormalization.normalize(rawDistrict, userState: stateCode) else { return nil }

        if normalized == "AT-LARGE" {
            return stateCode.isEmpty ? "At-Large" : "\(stateCode) At-Large"
        }

        let districtPart = Int(normalized).map(String.init) ?? rawDistrict
        return stateCode.isEmpty ? districtPart : "\(stateCode)-\(districtPart)"
    }
}

/// Orders member names the way rosters do: by last name, then first name.
///
/// Member payloads carry only a display name ("Tim Kaine", occasionally "Kaine, Tim"), so the
/// last name is inferred: generational suffixes ("Jr.", "III") are ignored and surname particles
/// stay with the surname ("Van Hollen", "De La Cruz"). Two-word surnames without a particle
/// ("Wasserman Schultz") sort under their final word.
struct CongressMemberNameSortKey: Comparable {
    let lastName: String
    let givenNames: String
    let fullName: String

    init(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        fullName = trimmed

        var working = trimmed
        // Drop a trailing ", Jr." style suffix before checking for "Last, First" order.
        if let comma = working.lastIndex(of: ","),
           Self.isGenerationalSuffix(String(working[working.index(after: comma)...])) {
            working = String(working[..<comma])
        }

        if let comma = working.firstIndex(of: ",") {
            lastName = working[..<comma].trimmingCharacters(in: .whitespaces)
            givenNames = working[working.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return
        }

        var tokens = working.split(whereSeparator: \.isWhitespace).map(String.init)
        while tokens.count > 1, let last = tokens.last, Self.isGenerationalSuffix(last) {
            tokens.removeLast()
        }

        guard tokens.count > 1 else {
            lastName = working
            givenNames = ""
            return
        }

        var surnameStart = tokens.count - 1
        while surnameStart > 1, Self.surnameParticles.contains(tokens[surnameStart - 1].lowercased()) {
            surnameStart -= 1
        }

        lastName = tokens[surnameStart...].joined(separator: " ")
        givenNames = tokens[..<surnameStart].joined(separator: " ")
    }

    static func < (lhs: CongressMemberNameSortKey, rhs: CongressMemberNameSortKey) -> Bool {
        let pairs = [
            (lhs.lastName, rhs.lastName),
            (lhs.givenNames, rhs.givenNames),
            (lhs.fullName, rhs.fullName)
        ]
        for (left, right) in pairs {
            let result = left.localizedCaseInsensitiveCompare(right)
            if result != .orderedSame { return result == .orderedAscending }
        }
        return false
    }

    private static let generationalSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]
    private static let surnameParticles: Set<String> = ["da", "de", "del", "della", "der", "di", "du", "la", "le", "van", "von"]

    private static func isGenerationalSuffix(_ token: String) -> Bool {
        let cleaned = token
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            .lowercased()
        return generationalSuffixes.contains(cleaned)
    }
}
