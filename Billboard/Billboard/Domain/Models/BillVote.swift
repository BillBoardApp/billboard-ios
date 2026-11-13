import Foundation

/// The user's vote choice for a bill.
///
/// NOTE: This is intentionally separate from `UserVote` in `Bill.swift`.
/// `UserVote` is currently used inside the bills payload; `VoteType` is the
/// canonical type used by the feedback/voting API.
nonisolated enum VoteType: String, Codable, CaseIterable, Hashable, Sendable {
    case yea
    case nay
    case abstain

    /// Server contract for SetFeedback: "Yea" | "Nay" | "Abstain"
    nonisolated var feedbackValue: String {
        switch self {
        case .yea: return "Yea"
        case .nay: return "Nay"
        case .abstain: return "Abstain"
        }
    }

    /// Backwards-compatible alias for older code paths.
    nonisolated var apiValue: String { feedbackValue }

    nonisolated init?(apiValue: String) {
        switch apiValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yea", "yes":
            self = .yea
        case "nay", "no":
            self = .nay
        case "abstain", "abstention":
            self = .abstain
        default:
            return nil
        }
    }

    /// `abstain` is treated as a non-vote for user vote counts and civic score.
    nonisolated var countsAsVote: Bool {
        switch self {
        case .yea, .nay:
            return true
        case .abstain:
            return false
        }
    }
}

/// Optional user-selected context for why they chose a vote.
/// These keys are sent to the backend as stable identifiers.
nonisolated enum VoteReason: String, Codable, CaseIterable, Hashable, Sendable {
    case moralsValues = "morals_values"
    case constitutionalRights = "constitutional_rights"
    case economicImpact = "economic_impact"
    case taxesSpending = "taxes_spending"
    case publicSafety = "public_safety"
    case healthcare = "healthcare"
    case education = "education"
    case environment = "environment"
    case nationalSecurity = "national_security"
    case privacyLiberty = "privacy_liberty"
    case localCommunity = "local_community"
    case trustSponsor = "trust_sponsor"
    case evidenceData = "evidence_data"
    case needMoreInfo = "need_more_info"

    static let maxSelections = 3

    nonisolated var title: String {
        switch self {
        case .moralsValues: return "Morals / Values"
        case .constitutionalRights: return "Constitutional Rights"
        case .economicImpact: return "Economic Impact / Jobs"
        case .taxesSpending: return "Taxes / Spending"
        case .publicSafety: return "Public Safety"
        case .healthcare: return "Healthcare"
        case .education: return "Education"
        case .environment: return "Environment / Climate"
        case .nationalSecurity: return "National Security"
        case .privacyLiberty: return "Privacy / Civil Liberties"
        case .localCommunity: return "Impact on My Community"
        case .trustSponsor: return "Trust of Sponsor/Party"
        case .evidenceData: return "Evidence / Data"
        case .needMoreInfo: return "Need More Information"
        }
    }

    /// The reasons a Yea or Nay can give: every reason but Need More Information, which contradicts a Yea or
    /// Nay (feature review N13). The identifiers sent to the server are unchanged; 1.0 and 1.1 still offer it.
    nonisolated static let yeaNayReasons: [VoteReason] = allCases.filter { $0 != .needMoreInfo }

    /// The reasons an Abstain can give: Need More Information only. The server stores reasons with any vote
    /// (setFeedback), and counts only a Yea's or a Nay's in Why people voted, so an Abstain's is shown to no one.
    nonisolated static let abstainReasons: [VoteReason] = [.needMoreInfo]

    /// The reasons offered after `voteType`, in their base order (`VoteReasonOrder` shuffles them per person).
    nonisolated static func offered(for voteType: VoteType) -> [VoteReason] {
        voteType.countsAsVote ? yeaNayReasons : abstainReasons
    }
}

extension UserVote {
    /// The bills payload's vote for a feedback API vote.
    init(_ voteType: VoteType) {
        switch voteType {
        case .yea: self = .yea
        case .nay: self = .nay
        case .abstain: self = .abstain
        }
    }

    /// The feedback API's vote for this one.
    var voteType: VoteType {
        switch self {
        case .yea: return .yea
        case .nay: return .nay
        case .abstain: return .abstain
        }
    }
}

extension VoteState {
    /// The vote as a choice the vote bar and badges show (Abstain included), or nil when not voted
    /// or not known.
    nonisolated var choice: VoteChoice? {
        guard case .voted(let voteType) = self else { return nil }
        return VoteChoice(voteType)
    }
}

/// A cached "voted" record.
nonisolated struct BillVote: Codable, Hashable, Sendable {
    let vote: VoteType
    let votedAt: Date
    let cachedAt: Date
}

/// UI state for a bill's vote.
///
/// - `unknown`: We haven't fetched yet, or cache expired.
/// - `notVoted`: We fetched and the user has no vote recorded.
/// - `voted`: We fetched and the user has a vote recorded.
nonisolated enum VoteState: Equatable, Sendable {
    case voted(VoteType)
    case notVoted
    case unknown

    /// True only for vote states that should count toward user vote metrics.
    nonisolated var countsAsVote: Bool {
        guard case .voted(let voteType) = self else { return false }
        return voteType.countsAsVote
    }
}
