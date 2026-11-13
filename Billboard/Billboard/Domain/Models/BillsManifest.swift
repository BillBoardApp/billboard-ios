import Foundation

// Nonisolated so the manifest can be decoded, merged and cached off the main actor.
nonisolated struct BillsManifest: Codable, Sendable {
    let generatedAt: String?
    let count: Int?
    let bills: [BillsManifestItem]
}

nonisolated struct BillsManifestItem: Codable, Hashable, Sendable {
    let guid: String
    let congress: String?
    let billType: String?
    let billID: String?
    let updatedAt: String?
    let subCategories: [String]
    let lifeAreas: [String]
    let sponsors: [String]
    let cosponsors: [String]
    let isPriority: Bool?
    let priorityRank: Int?
    let priorityReason: String?
    let priorityExpiresAt: String?
    let title: String
    let billStatus: String?
    let civicProfile: [String: Double]?

    nonisolated init(
        guid: String,
        congress: String?,
        billType: String?,
        billID: String?,
        updatedAt: String? = nil,
        subCategories: [String],
        lifeAreas: [String],
        sponsors: [String],
        cosponsors: [String],
        isPriority: Bool? = nil,
        priorityRank: Int? = nil,
        priorityReason: String? = nil,
        priorityExpiresAt: String? = nil,
        title: String,
        billStatus: String? = nil,
        civicProfile: [String: Double]? = nil
    ) {
        self.guid = guid
        self.congress = congress
        self.billType = billType
        self.billID = billID
        self.updatedAt = updatedAt
        self.subCategories = subCategories
        self.lifeAreas = lifeAreas
        self.sponsors = sponsors
        self.cosponsors = cosponsors
        self.isPriority = isPriority
        self.priorityRank = priorityRank
        self.priorityReason = priorityReason
        self.priorityExpiresAt = priorityExpiresAt
        self.title = title
        self.billStatus = billStatus
        self.civicProfile = civicProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)

        guid = try container.decode(String.self, forKey: .guid)
        congress = try container.decodeIfPresent(String.self, forKey: .congress)

        // Server-side uses query key `type`, but manifest may emit `billType` or `bill_type`.
        let billTypeCamel = try container.decodeIfPresent(String.self, forKey: .billType)
        let billTypeType = try container.decodeIfPresent(String.self, forKey: .type)
        let billTypeSnake = try container.decodeIfPresent(String.self, forKey: .billTypeSnake)
        billType = billTypeCamel ?? billTypeType ?? billTypeSnake

        // Server-side uses query key `bill_id`, but manifest may emit `billID` or `billId`.
        let billIdUpper = try container.decodeIfPresent(String.self, forKey: .billID)
        let billIdLower = try container.decodeIfPresent(String.self, forKey: .billId)
        let billIdSnake = try container.decodeIfPresent(String.self, forKey: .billIdSnake)
        billID = billIdUpper ?? billIdLower ?? billIdSnake
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)

        subCategories = (try container.decodeIfPresent([String].self, forKey: .subCategories)) ?? []
        lifeAreas = (try container.decodeIfPresent([String].self, forKey: .lifeAreas)) ?? []
        sponsors = (try container.decodeIfPresent([String].self, forKey: .sponsors)) ?? []
        cosponsors = (try container.decodeIfPresent([String].self, forKey: .cosponsors)) ?? []
        // `voteCount` (other users' votes) is not read: no longer sent (INT-11), and ignored when an old
        // server or cache file still has it.
        isPriority = try container.decodeIfPresent(Bool.self, forKey: .isPriority)
        priorityRank = try container.decodeIfPresent(Int.self, forKey: .priorityRank)
        priorityReason = try container.decodeIfPresent(String.self, forKey: .priorityReason)
        priorityExpiresAt = try container.decodeIfPresent(String.self, forKey: .priorityExpiresAt)
        title = (try container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        billStatus = try container.decodeIfPresent(String.self, forKey: .billStatus)
        civicProfile = try container.decodeIfPresent([String: Double].self, forKey: .civicProfile)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(guid, forKey: .guid)
        try container.encodeIfPresent(congress, forKey: .congress)
        try container.encodeIfPresent(billType, forKey: .billType)
        try container.encodeIfPresent(billID, forKey: .billID)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(subCategories, forKey: .subCategories)
        try container.encode(lifeAreas, forKey: .lifeAreas)
        try container.encode(sponsors, forKey: .sponsors)
        try container.encode(cosponsors, forKey: .cosponsors)
        try container.encodeIfPresent(isPriority, forKey: .isPriority)
        try container.encodeIfPresent(priorityRank, forKey: .priorityRank)
        try container.encodeIfPresent(priorityReason, forKey: .priorityReason)
        try container.encodeIfPresent(priorityExpiresAt, forKey: .priorityExpiresAt)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(billStatus, forKey: .billStatus)
        try container.encodeIfPresent(civicProfile, forKey: .civicProfile)
    }

    private enum CodingKeys: String, CodingKey {
        case guid
        case congress
        case billType
        case billID
        case updatedAt
        case subCategories
        case lifeAreas
        case sponsors
        case cosponsors
        case isPriority
        case priorityRank
        case priorityReason
        case priorityExpiresAt
        case title
        case billStatus
        case civicProfile
    }

    private enum DecodingKeys: String, CodingKey {
        case guid
        case congress
        case billType
        case billTypeSnake = "bill_type"
        case type
        case billID
        case billId
        case billIdSnake = "bill_id"
        case updatedAt
        case subCategories
        case lifeAreas
        case sponsors
        case cosponsors
        case isPriority
        case priorityRank
        case priorityReason
        case priorityExpiresAt
        case title
        case billStatus
        case civicProfile
    }
}

nonisolated extension BillsManifestItem {
    init(dto: UserAPIContractsV1.BillsManifestItem) {
        self.init(
            guid: dto.guid,
            congress: dto.congress,
            billType: dto.billType,
            billID: dto.billNumber,
            updatedAt: dto.updatedAt,
            subCategories: dto.subCategories ?? [],
            lifeAreas: dto.lifeAreas ?? [],
            sponsors: dto.sponsors ?? [],
            cosponsors: dto.cosponsors ?? [],
            isPriority: dto.isPriority,
            priorityRank: dto.priorityRank,
            priorityReason: dto.priorityReason,
            priorityExpiresAt: dto.priorityExpiresAt,
            title: dto.title ?? "",
            billStatus: dto.billStatus,
            civicProfile: dto.civicProfile
        )
    }
}
