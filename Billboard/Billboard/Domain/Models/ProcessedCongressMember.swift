import Foundation

struct ProcessedCongressMember: Decodable {
    let bioguideId: String
    let name: String
    let chamber: String?
    let state: String?
    let district: String?
    let party: String?
    let biography: String?
    let termsServed: Int?
    let serviceStartYear: Int?

    // Subset of Congress.gov enriched fields (see the Congress.gov member API)
    let imageUrl: URL?
    let sponsoredLegislationCount: Int?
    let cosponsoredLegislationCount: Int?
    let currentCongressBillsSupportedCount: Int?
    /// BillBoard's tracked 119th Congress counts; absent from services before APPF-03 and when the
    /// member stats could not be read.
    let trackedSponsoredCount: Int?
    let trackedSupportedCount: Int?
    let terms: [Term]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let bioguide = try container.decodeIfPresent(String.self, forKey: .bioguideId)
            ?? container.decodeIfPresent(String.self, forKey: .id)

        guard let resolvedBioguide = bioguide?.trimmingCharacters(in: .whitespacesAndNewlines), !resolvedBioguide.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.bioguideId, .init(codingPath: decoder.codingPath, debugDescription: "Missing bioguideId"))
        }
        bioguideId = resolvedBioguide

        let first = try? container.decodeIfPresent(String.self, forKey: .firstName)
        let last = try? container.decodeIfPresent(String.self, forKey: .lastName)
        let joined = [first, last]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let primaryName = container.decodeFirstString(for: [.name, .fullName, .displayName])
            ?? (joined.isEmpty ? nil : joined)

        let directOrderName = container.decodeFirstString(for: [.directOrderName])

        name = (primaryName ?? directOrderName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? resolvedBioguide

        let rawChamber = container.decodeFirstString(for: [.chamber, .memberType, .role, .title, .branch])
        chamber = ProcessedCongressMember.normalizeChamber(rawChamber)

        state = container.decodeFirstString(for: [.state, .stateName, .stateCode, .stateAbbrev])

        if let districtString = container.decodeFirstString(for: [.district, .districtCode]) {
            district = districtString
        } else if let districtInt = container.decodeIntStringIfPresent(forKey: .district) {
            district = "\(districtInt)"
        } else if let districtNumber = container.decodeIntStringIfPresent(forKey: .districtNumber) {
            district = "\(districtNumber)"
        } else {
            district = nil
        }

        party = container.decodeFirstString(for: [.party, .partyName, .partyCode, .partyAbbreviation])

        biography = container.decodeFirstString(for: [.biography, .bio, .summary, .description])

        termsServed = try? container.decodeIfPresent(Int.self, forKey: .termsServed)
            ?? container.decodeIntStringIfPresent(forKey: .terms)
            ?? container.decodeIntStringIfPresent(forKey: .yearsInOffice)
            ?? container.decodeIntStringIfPresent(forKey: .termCount)

        serviceStartYear = try? container.decodeIfPresent(Int.self, forKey: .serviceStartYear)
            ?? container.decodeIntStringIfPresent(forKey: .startYear)
            ?? container.decodeYearFromDateString(forKey: .startDate)

        // Congress.gov-derived extras
        // Accept either nested Congress.gov depiction object ({ depiction: { imageUrl } }) or a flattened `depictionImageUrl` string.
        if let depiction = try? container.decodeIfPresent(Depiction.self, forKey: .depiction),
           let urlString = depiction.imageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlString.isEmpty {
            imageUrl = URL(string: urlString)
        } else if let urlString = (try? container.decodeIfPresent(String.self, forKey: .depictionImageUrl)) ?? nil {
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            imageUrl = trimmed.isEmpty ? nil : URL(string: trimmed)
        } else {
            imageUrl = nil
        }

        // Accept either nested wrappers ({ sponsoredLegislation: { count } }) or flattened `...Count` fields.
        sponsoredLegislationCount = (try? container.decodeIfPresent(CountWrapper.self, forKey: .sponsoredLegislation))?.count
            ?? (try? container.decodeIfPresent(Int.self, forKey: .sponsoredLegislationCount))
        cosponsoredLegislationCount = (try? container.decodeIfPresent(CountWrapper.self, forKey: .cosponsoredLegislation))?.count
            ?? (try? container.decodeIfPresent(Int.self, forKey: .cosponsoredLegislationCount))
        currentCongressBillsSupportedCount = try? container.decodeIfPresent(Int.self, forKey: .currentCongressBillsSupportedCount)
        trackedSponsoredCount = try? container.decodeIfPresent(Int.self, forKey: .trackedSponsoredCount)
        trackedSupportedCount = try? container.decodeIfPresent(Int.self, forKey: .trackedSupportedCount)

        terms = try? container.decodeIfPresent([Term].self, forKey: .terms)
    }

    enum CodingKeys: String, CodingKey {
        case bioguideId
        case id
        case name
        case fullName
        case displayName
        case firstName
        case lastName
        case chamber
        case branch
        case role
        case title
        case party
        case partyName
        case partyCode
        case partyAbbreviation
        case state
        case stateCode
        case stateAbbrev
        case stateName
        case district
        case districtCode
        case districtNumber
        case biography
        case bio
        case summary
        case description
        case termsServed
        case terms
        case yearsInOffice
        case serviceStartYear
        case startYear
        case startDate

        // Congress.gov-derived extras
        case depiction
        case sponsoredLegislation
        case cosponsoredLegislation
        case sponsoredLegislationCount
        case cosponsoredLegislationCount
        case currentCongressBillsSupportedCount
        case trackedSponsoredCount
        case trackedSupportedCount
        case directOrderName

        // Flattened payload support
        case depictionImageUrl
        case termCount
        case memberType
    }

    struct Depiction: Decodable {
        let imageUrl: String?
    }

    struct CountWrapper: Decodable {
        let count: Int?
    }

    struct Term: Decodable {
        let chamber: String?
        let memberType: String?
        let stateName: String?
        let stateCode: String?
        let startYear: Int?
        let endYear: Int?
        let district: String?

        private enum CodingKeys: String, CodingKey {
            case chamber
            case memberType
            case stateName
            case stateCode
            case startYear
            case endYear
            case district
        }

        init(
            chamber: String?,
            memberType: String?,
            stateName: String?,
            stateCode: String?,
            startYear: Int?,
            endYear: Int?,
            district: String?
        ) {
            self.chamber = chamber
            self.memberType = memberType
            self.stateName = stateName
            self.stateCode = stateCode
            self.startYear = startYear
            self.endYear = endYear
            self.district = district
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chamber = try container.decodeIfPresent(String.self, forKey: .chamber)
            memberType = try container.decodeIfPresent(String.self, forKey: .memberType)
            stateName = try container.decodeIfPresent(String.self, forKey: .stateName)
            stateCode = try container.decodeIfPresent(String.self, forKey: .stateCode)
            startYear = try container.decodeIfPresent(Int.self, forKey: .startYear)
            endYear = try container.decodeIfPresent(Int.self, forKey: .endYear)

            if let districtString = try container.decodeIfPresent(String.self, forKey: .district) {
                district = districtString
            } else if let districtInt = try container.decodeIfPresent(Int.self, forKey: .district) {
                district = String(districtInt)
            } else {
                district = nil
            }
        }
    }

    func toCongressMember(fallback manifest: CongressMemberManifestItem) -> CongressMember {
        let currentTerm = terms?.max(by: { (lhs, rhs) in
            let lhsStart = lhs.startYear ?? 0
            let rhsStart = rhs.startYear ?? 0
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return (lhs.endYear ?? 0) < (rhs.endYear ?? 0)
        })

        let derivedStartYear = terms?
            .compactMap { $0.startYear }
            .min()
        let derivedTermsServed = terms?.count

        let derivedChamber = ProcessedCongressMember.normalizeChamber(currentTerm?.chamber ?? currentTerm?.memberType)
            ?? terms?
                .compactMap { $0.chamber ?? $0.memberType }
                .compactMap { ProcessedCongressMember.normalizeChamber($0) }
                .last

        let normalizedChamber = derivedChamber
            ?? ProcessedCongressMember.normalizeChamber(chamber)
            ?? manifest.chamberNormalized
            ?? "Member"

        let resolvedParty = PoliticalParty.from(raw: party)
            ?? PoliticalParty.from(raw: manifest.party)
            ?? .independent

        let resolvedState = state
            ?? currentTerm?.stateCode
            ?? currentTerm?.stateName
            ?? terms?.compactMap { $0.stateCode ?? $0.stateName }.first
            ?? manifest.state
            ?? ""

        // Prefer a postal code so districts read "VA-11"; the display state may be a full name.
        let resolvedStateCode = [currentTerm?.stateCode, state, manifest.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .first { $0.count == 2 && $0.allSatisfy(\.isLetter) }

        let resolvedDistrict = currentTerm?.district
            ?? district
            ?? manifest.district
        let resolvedStartYear = derivedStartYear
            ?? serviceStartYear
            ?? Calendar.current.component(.year, from: Date())
        let resolvedTerms = derivedTermsServed
            ?? termsServed
            ?? 0
        let resolvedBiography = (biography ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty ? manifest.name : name
        // The tracked counts come as a pair. Use the manifest's when this payload has neither
        // (its member stats read failed), rather than showing no tracked counts.
        let hasTrackedCounts = trackedSponsoredCount != nil || trackedSupportedCount != nil

        return CongressMember(
            id: UUID.deterministic(from: bioguideId),
            name: resolvedName,
            state: resolvedState,
            stateCode: resolvedStateCode,
            chamber: normalizedChamber,
            imageUrl: imageUrl,
            sponsoredLegislationCount: sponsoredLegislationCount,
            cosponsoredLegislationCount: cosponsoredLegislationCount,
            currentCongressBillsSupportedCount: currentCongressBillsSupportedCount,
            trackedSponsoredCount: hasTrackedCounts ? trackedSponsoredCount : manifest.trackedSponsoredCount,
            trackedSupportedCount: hasTrackedCounts ? trackedSupportedCount : manifest.trackedSupportedCount,
            biography: resolvedBiography,
            party: resolvedParty,
            district: resolvedDistrict,
            termsServed: resolvedTerms,
            serviceStartYear: resolvedStartYear
        )
    }

    private static func normalizeChamber(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.contains("house") || lower.contains("representative") {
            return "House"
        }
        if lower.contains("senate") || lower.contains("senator") {
            return "Senate"
        }
        return value.capitalized
    }
}

private extension KeyedDecodingContainer where Key == ProcessedCongressMember.CodingKeys {
    func decodeFirstString(for keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    func decodeIntStringIfPresent(forKey key: Key) -> Int? {
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
            return intValue
        }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeYearFromDateString(forKey key: Key) -> Int? {
        guard let stringValue = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 4, let year = Int(trimmed.prefix(4)) {
            return year
        }
        return nil
    }
}

extension ProcessedCongressMember {
    init(dto: UserAPIContractsV1.ProcessedCongressMember) {
        let mappedTerms = dto.terms?.map { term in
            Term(
                chamber: term.chamber,
                memberType: term.memberType,
                stateName: term.stateName,
                stateCode: term.stateCode,
                startYear: term.startYear,
                endYear: term.endYear,
                district: term.district
            )
        }
        let mappedTermCount = mappedTerms?.count ?? dto.termCount
        let mappedServiceStartYear = mappedTerms?
            .compactMap(\.startYear)
            .min()
            ?? ProcessedCongressMember.deriveServiceStartYear(
                currentTermStartYear: dto.startYear,
                termCount: mappedTermCount
            )

        bioguideId = dto.bioguideId
        name = dto.name
        chamber = dto.chamber ?? dto.memberType
        state = dto.state ?? dto.stateCode ?? dto.stateName
        district = dto.district
        party = dto.party ?? dto.partyAbbreviation ?? dto.partyName
        biography = nil
        termsServed = mappedTermCount
        serviceStartYear = mappedServiceStartYear ?? dto.startYear
        if let raw = dto.depictionImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            imageUrl = URL(string: raw)
        } else {
            imageUrl = nil
        }
        sponsoredLegislationCount = dto.sponsoredLegislationCount
        cosponsoredLegislationCount = dto.cosponsoredLegislationCount
        currentCongressBillsSupportedCount = dto.currentCongressBillsSupportedCount
        trackedSponsoredCount = dto.trackedSponsoredCount
        trackedSupportedCount = dto.trackedSupportedCount
        terms = mappedTerms
    }

    private static func deriveServiceStartYear(currentTermStartYear: Int?, termCount: Int?) -> Int? {
        guard let currentTermStartYear, let termCount, termCount > 1 else {
            return currentTermStartYear
        }

        // Congress.gov processed summaries count congressional service periods.
        // Each Congress spans two years, so this recovers the first listed period
        // when the API does not include the full terms array.
        return currentTermStartYear - ((termCount - 1) * 2)
    }
}
