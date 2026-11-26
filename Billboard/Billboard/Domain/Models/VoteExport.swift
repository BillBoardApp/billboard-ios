import Foundation

// Download my votes (UX-40 L7): the caller's own votes from `GET /account-data/votes`, and the two files the app
// writes from one response, a CSV for people and a JSON document for tools (project decisions D32 to D34,
// 2026-11-23; the Congress column, a project decision of 2026-11-26). The generated Swift contract has no type for
// this route, so the wire types are written here by hand from user-api.v1.json (VoteExport, ExportedVote).

// MARK: - Wire types

/// One page of `GET /account-data/votes`. `nextToken` is there while more rows follow (a page can hold no votes and
/// still carry one); it goes back as the next page's `cursor` exactly as given.
nonisolated struct VoteExportPage: Decodable, Equatable, Sendable {
    let votes: [ExportedVote]
    let nextToken: String?
}

/// One of the caller's votes as the server stores it (contract ExportedVote). `billId`, `vote`, `reasons` and
/// `verified` are always there and never null; the other eight are null where nothing is known.
nonisolated struct ExportedVote: Codable, Equatable, Sendable {
    /// The bill's guid as the vote is stored: a plain guid (`BILLS-119hr1285`), or for an old row a legacy
    /// text-version guid (`BILLS-119hr1181rh`).
    let billId: String
    /// The bill's manifest title; nil when the bill has no manifest row.
    let title: String?
    /// From the bill id ("119"); nil when the id is not a bill guid.
    let congress: String?
    /// From the bill id, lower case ("hr"); nil when the id is not a bill guid.
    let billType: String?
    /// From the bill id ("1285"); nil when the id is not a bill guid.
    let billNumber: String?
    /// Yea, Nay or Abstain on the wire.
    let vote: VoteType
    /// The reason keys picked with the vote, sorted; empty when none.
    let reasons: [String]
    /// When the vote was first cast (ISO 8601); nil when unknown.
    let firstVotedAt: String?
    /// When the vote was last changed (ISO 8601); nil for a vote stored before votes were timed.
    let votedAt: String?
    /// The state stored with the vote; nil when none.
    let state: String?
    /// The district stored with the vote; nil when none.
    let district: String?
    /// Whether the vote was stored as a verified voter's.
    let verified: Bool

    init(
        billId: String,
        title: String?,
        congress: String?,
        billType: String?,
        billNumber: String?,
        vote: VoteType,
        reasons: [String],
        firstVotedAt: String?,
        votedAt: String?,
        state: String?,
        district: String?,
        verified: Bool
    ) {
        self.billId = billId
        self.title = title
        self.congress = congress
        self.billType = billType
        self.billNumber = billNumber
        self.vote = vote
        self.reasons = reasons
        self.firstVotedAt = firstVotedAt
        self.votedAt = votedAt
        self.state = state
        self.district = district
        self.verified = verified
    }

    private enum CodingKeys: String, CodingKey {
        case billId, title, congress, billType, billNumber, vote, reasons, firstVotedAt, votedAt, state, district, verified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billId = try container.decode(String.self, forKey: .billId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        congress = try container.decodeIfPresent(String.self, forKey: .congress)
        billType = try container.decodeIfPresent(String.self, forKey: .billType)
        billNumber = try container.decodeIfPresent(String.self, forKey: .billNumber)
        let rawVote = try container.decode(String.self, forKey: .vote)
        guard let vote = Self.voteType(wire: rawVote) else {
            // The value is the user's vote: it stays out of the error, which is logged.
            throw DecodingError.dataCorruptedError(forKey: .vote, in: container, debugDescription: "not Yea, Nay or Abstain")
        }
        self.vote = vote
        reasons = try container.decode([String].self, forKey: .reasons)
        firstVotedAt = try container.decodeIfPresent(String.self, forKey: .firstVotedAt)
        votedAt = try container.decodeIfPresent(String.self, forKey: .votedAt)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        district = try container.decodeIfPresent(String.self, forKey: .district)
        verified = try container.decode(Bool.self, forKey: .verified)
    }

    /// The server's fields, nulls written out, the vote as on the wire ("Yea").
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(billId, forKey: .billId)
        try container.encode(title, forKey: .title)
        try container.encode(congress, forKey: .congress)
        try container.encode(billType, forKey: .billType)
        try container.encode(billNumber, forKey: .billNumber)
        try container.encode(vote.feedbackValue, forKey: .vote)
        try container.encode(reasons, forKey: .reasons)
        try container.encode(firstVotedAt, forKey: .firstVotedAt)
        try container.encode(votedAt, forKey: .votedAt)
        try container.encode(state, forKey: .state)
        try container.encode(district, forKey: .district)
        try container.encode(verified, forKey: .verified)
    }

    /// The contract's enum, exactly: "Yea", "Nay" or "Abstain".
    private static func voteType(wire: String) -> VoteType? {
        VoteType.allCases.first { $0.feedbackValue == wire }
    }
}

// MARK: - What the files say

nonisolated extension ExportedVote {
    /// "H.R. 1285", from the bill type and number or the bill id; the bill id when neither gives one.
    var billLabel: String {
        BillDisplayFormatting.officialBillNumber(billType: billType, billNumber: billNumber, guid: billId) ?? billId
    }

    /// "119th"; empty when the Congress is not known.
    var congressLabel: String {
        guard let raw = congress.trimmedNonEmpty else { return "" }
        guard let number = Int(raw), number > 0 else { return raw }
        return SpokenForm.ordinal(number)
    }

    /// The manifest title, else the bill id.
    var titleLabel: String {
        title.trimmedNonEmpty ?? billId
    }

    /// The app's label for each reason key ("Economic Impact / Jobs"). A key the app does not know is humanized as
    /// Why people voted shows it ("some_new_reason" is "Some New Reason").
    var reasonLabels: [String] {
        reasons.map { key in
            VoteReason(rawValue: key)?.title ?? key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// True when the bill id is a plain guid, or not a bill guid at all; false for a legacy text-version guid.
    var hasPlainBillId: Bool {
        guard let plain = CompanionGroupIndex.plainGuid(billId) else { return true }
        return plain.caseInsensitiveCompare(billId.trimmed) == .orderedSame
    }
}

// MARK: - Files

/// The two formats of Download my votes.
nonisolated enum VoteExportFormat: Sendable {
    case csv
    case json

    var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

/// The JSON document (project decision D33, 2026-11-23): when it was made, then each vote's server fields with its
/// bill number ("bill") and reason labels ("reasonLabels"). Pretty-printed with sorted keys. The app only writes it.
nonisolated struct VoteExportDocument: Encodable, Sendable {
    /// ISO 8601 UTC.
    let exportedAt: String
    let votes: [Vote]

    nonisolated struct Vote: Encodable, Sendable {
        let server: ExportedVote
        /// "H.R. 1285" (`ExportedVote.billLabel`).
        let bill: String
        let reasonLabels: [String]

        init(_ vote: ExportedVote) {
            server = vote
            bill = vote.billLabel
            reasonLabels = vote.reasonLabels
        }

        private enum AddedKeys: String, CodingKey {
            case bill, reasonLabels
        }

        /// One flat object: the server's keys and the two the app adds.
        func encode(to encoder: Encoder) throws {
            try server.encode(to: encoder)
            var container = encoder.container(keyedBy: AddedKeys.self)
            try container.encode(bill, forKey: .bill)
            try container.encode(reasonLabels, forKey: .reasonLabels)
        }
    }
}

/// The CSV and JSON files of Download my votes, written from one response. Pure, for `VoteExportTests`.
nonisolated enum VoteExport {
    /// One CSV column: its header and its cell for a vote.
    struct Column: Sendable {
        let header: String
        let value: @Sendable (ExportedVote) -> String

        init(_ header: String, value: @escaping @Sendable (ExportedVote) -> String) {
            self.header = header
            self.value = value
        }
    }

    /// The CSV's columns, in order, one line each (D34, 2026-11-23; Congress after Bill, 2026-11-26). The header
    /// reads "Bill,Congress,Title,Your vote,Reasons,First voted,Last changed,State,District,Verified".
    static let columns: [Column] = [
        Column("Bill") { $0.billLabel },
        Column("Congress") { $0.congressLabel },
        Column("Title") { $0.titleLabel },
        Column("Your vote") { $0.vote.feedbackValue },
        Column("Reasons") { $0.reasonLabels.joined(separator: "; ") },
        Column("First voted") { utcTime($0.firstVotedAt) },
        Column("Last changed") { utcTime($0.votedAt) },
        Column("State") { $0.state ?? "" },
        Column("District") { $0.district ?? "" },
        Column("Verified") { $0.verified ? "Verified" : "Not verified" }
    ]

    /// A UTF-8 byte order mark, so Excel reads the file as UTF-8.
    static let byteOrderMark = "\u{FEFF}"
    static let lineEnd = "\r\n"

    // MARK: CSV

    /// The CSV (RFC 4180): a byte order mark, the header, then a row per vote, every line ending in CRLF.
    static func csv(_ votes: [ExportedVote]) -> Data {
        var text = byteOrderMark
        text += csvLine(columns.map(\.header))
        for vote in votes {
            text += csvLine(columns.map { $0.value(vote) })
        }
        return Data(text.utf8)
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",") + lineEnd
    }

    /// A field as RFC 4180 writes it: in double quotes, its quotes doubled, when it holds a comma, a quote or a line
    /// break; as is otherwise. Checked by scalar: Swift counts "\r\n" as one character.
    static func csvField(_ value: String) -> String {
        let needsQuotes = value.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// An ISO 8601 time in UTC ("2026-10-02T15:00:00Z"); empty when there is none. A time that does not parse is
    /// kept as the server wrote it.
    static func utcTime(_ raw: String?) -> String {
        guard let raw = raw.trimmedNonEmpty else { return "" }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        guard let date = (try? Date(raw, strategy: withFraction)) ?? (try? Date(raw, strategy: .iso8601)) else {
            return raw
        }
        return date.formatted(.iso8601)
    }

    // MARK: JSON

    static func document(_ votes: [ExportedVote], exportedAt: Date) -> VoteExportDocument {
        VoteExportDocument(exportedAt: exportedAt.formatted(.iso8601), votes: votes.map(VoteExportDocument.Vote.init))
    }

    static func json(_ votes: [ExportedVote], exportedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document(votes, exportedAt: exportedAt))
    }

    // MARK: File names

    /// "Billboard votes 2026-11-22.csv", dated by the device's own calendar day.
    static func fileName(_ format: VoteExportFormat, at date: Date, timeZone: TimeZone = .current) -> String {
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return "Billboard votes \(day).\(format.fileExtension)"
    }

    // MARK: Legacy twins

    /// The votes with one row per bill: where a legacy text-version row (`BILLS-119hr1181rh`) sits beside its plain
    /// row (`BILLS-119hr1181`), only the plain row stays, as `GET /feedback` reads it; where a bill has only
    /// text-version rows, the first one (by bill id, the server's order) stays. Run once over every page: the server
    /// pages by bill id, so a plain row and its twin can sit on different pages (`BILLS-119hr11810` sorts between
    /// them). Order is kept.
    static func removingLegacyTwins(_ votes: [ExportedVote]) -> [ExportedVote] {
        var keeper: [String: Int] = [:]
        for (index, vote) in votes.enumerated() {
            guard let plain = CompanionGroupIndex.plainGuid(vote.billId) else { continue }
            if let current = keeper[plain] {
                if !votes[current].hasPlainBillId && vote.hasPlainBillId { keeper[plain] = index }
            } else {
                keeper[plain] = index
            }
        }
        return votes.enumerated().compactMap { index, vote in
            guard let plain = CompanionGroupIndex.plainGuid(vote.billId) else { return vote }
            return keeper[plain] == index ? vote : nil
        }
    }
}
