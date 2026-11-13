import Foundation

/// Axes for the civic profile radar chart.
/// Each axis is a spectrum between two ideological positions.
enum CivicProfileAxis: String, CaseIterable, Codable, Hashable {
    case individualVsCommunity
    case localVsFederal
    case freeMarketVsRegulated
    case traditionalVsProgressive
    case interventionistVsRestrained
    case privacyVsSecurity

    /// Short label for the "low" end of this axis (value closer to 0).
    var lowLabel: String {
        switch self {
        case .individualVsCommunity: return "Individual"
        case .localVsFederal: return "Local"
        case .freeMarketVsRegulated: return "Free Market"
        case .traditionalVsProgressive: return "Traditional"
        case .interventionistVsRestrained: return "Restrained"
        case .privacyVsSecurity: return "Privacy"
        }
    }

    /// Short label for the "high" end of this axis (value closer to 1).
    var highLabel: String {
        switch self {
        case .individualVsCommunity: return "Community"
        case .localVsFederal: return "Federal"
        case .freeMarketVsRegulated: return "Regulated"
        case .traditionalVsProgressive: return "Progressive"
        case .interventionistVsRestrained: return "Intervene"
        case .privacyVsSecurity: return "Security"
        }
    }

    /// Clarifies what a higher score on this axis represents.
    var explanation: String {
        "\(lowLabel) (1) to \(highLabel) (10)"
    }
}

struct CivicProfileAxisCoverage: Codable, Equatable {
    let evidenceCount: Int
    let weightedEvidence: Double
    let isReady: Bool
}

struct CivicProfileEvidenceWeights: Codable, Equatable {
    let voteYea: Double
    let voteNay: Double
    let sponsor: Double
    let cosponsor: Double
}

struct CivicProfileDiagnostics: Codable, Equatable {
    let rollingWindow: Int
    let evidenceWeights: CivicProfileEvidenceWeights
    let weightedEvidenceUsed: Double
    let totalWeightedEvidenceWithProfile: Double
    let minWeightedEvidenceRequired: Double
    let minAxisWeightedEvidenceRequired: Double
    let minAxesRequired: Int
    let axesWithSufficientSignal: Int
    let axisCoverage: [String: CivicProfileAxisCoverage]
    let readinessReasons: [String]
    let latestEvidenceAt: String?
}

struct CivicProfileEvidenceItem: Codable, Equatable, Identifiable {
    var id: String { "\(billGuid)-\(evidenceType)-\(occurredAt)" }

    let billGuid: String
    let title: String?
    let evidenceType: String
    let votePosition: String?
    let occurredAt: String
    let weight: Double
    let axes: [String]
    let civicProfile: [String: Double]
}

/// Response from `GET /civic-profile`.
struct CivicProfileResponse: Codable, Equatable {
    /// Axis values normalized to 0..1. An axis without enough evidence is absent (the server
    /// omits axes below its per-axis evidence floor); treat a missing axis as "not enough data".
    let axes: [String: Double]
    /// Number of non-abstain votes used for computation.
    let votesUsed: Int
    /// Total votes that have civic profile data attached.
    let totalVotesWithProfile: Int
    /// Member-only: sponsored bills used for congress member civic profiles.
    let sponsoredBillsUsed: Int?
    /// Member-only: cosponsored bills used for congress member civic profiles.
    let cosponsoredBillsUsed: Int?
    /// Member-only: total evidence items used for congress member civic profiles.
    let totalEvidenceUsed: Int?
    /// Member-only: total evidence items available for congress member civic profiles.
    let totalEvidenceWithProfile: Int?
    /// Member-only: minimum evidence items required before the chart is shown.
    let minEvidenceRequired: Int?
    /// Minimum votes required before the chart is shown.
    let minVotesRequired: Int
    /// Whether the user has enough votes to display the chart.
    let isReady: Bool
    /// Member-only: scoring diagnostics and readiness thresholds.
    let diagnostics: CivicProfileDiagnostics?
    /// Member-only: most recent evidence items used by the chart.
    let evidence: [CivicProfileEvidenceItem]
    /// UX-32, additive (GET /civic-profile only; nil from a server before UX-32, for a member, and in `.empty`):
    /// what holds a locked profile, "votes" or "themes"; null when ready. Kept as sent: the contract asks clients
    /// to read any value other than "themes" as the vote lock (`isLockedByThemes`).
    let lockedBy: String?
    /// UX-32: themes with `minThemeVotes` of the user's votes, the themes in `axes`.
    let themesReady: Int?
    /// UX-32: themes at `minThemeVotes` the profile needs to unlock (3).
    let minThemesRequired: Int?
    /// UX-32: votes on bills scored on a theme before the theme gets a score (8).
    let minThemeVotes: Int?

    private enum CodingKeys: String, CodingKey {
        case axes
        case votesUsed
        case totalVotesWithProfile
        case sponsoredBillsUsed
        case cosponsoredBillsUsed
        case totalEvidenceUsed
        case totalEvidenceWithProfile
        case minEvidenceRequired
        case minVotesRequired
        case isReady
        case diagnostics
        case evidence
        case lockedBy
        case themesReady
        case minThemesRequired
        case minThemeVotes
    }

    init(
        axes: [String: Double],
        votesUsed: Int,
        totalVotesWithProfile: Int,
        sponsoredBillsUsed: Int? = nil,
        cosponsoredBillsUsed: Int? = nil,
        totalEvidenceUsed: Int? = nil,
        totalEvidenceWithProfile: Int? = nil,
        minEvidenceRequired: Int? = nil,
        minVotesRequired: Int,
        isReady: Bool,
        diagnostics: CivicProfileDiagnostics? = nil,
        evidence: [CivicProfileEvidenceItem] = [],
        lockedBy: String? = nil,
        themesReady: Int? = nil,
        minThemesRequired: Int? = nil,
        minThemeVotes: Int? = nil
    ) {
        self.axes = axes
        self.votesUsed = votesUsed
        self.totalVotesWithProfile = totalVotesWithProfile
        self.sponsoredBillsUsed = sponsoredBillsUsed
        self.cosponsoredBillsUsed = cosponsoredBillsUsed
        self.totalEvidenceUsed = totalEvidenceUsed
        self.totalEvidenceWithProfile = totalEvidenceWithProfile
        self.minEvidenceRequired = minEvidenceRequired
        self.minVotesRequired = minVotesRequired
        self.isReady = isReady
        self.diagnostics = diagnostics
        self.evidence = evidence
        self.lockedBy = lockedBy
        self.themesReady = themesReady
        self.minThemesRequired = minThemesRequired
        self.minThemeVotes = minThemeVotes
    }

    static let empty = CivicProfileResponse(
        axes: [:],
        votesUsed: 0,
        totalVotesWithProfile: 0,
        sponsoredBillsUsed: nil,
        cosponsoredBillsUsed: nil,
        totalEvidenceUsed: nil,
        totalEvidenceWithProfile: nil,
        minEvidenceRequired: nil,
        minVotesRequired: 25,
        isReady: false,
        diagnostics: nil,
        evidence: []
    )

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Tolerate omitted axes, a `null` axis value, or no `axes` object at all: each simply
        // means that axis has no score yet, never a decode failure or a zero.
        let rawAxes = try container.decodeIfPresent([String: Double?].self, forKey: .axes) ?? [:]
        axes = rawAxes.compactMapValues { value in
            guard let value, value.isFinite else { return nil }
            return value
        }
        votesUsed = try container.decode(Int.self, forKey: .votesUsed)
        totalVotesWithProfile = try container.decode(Int.self, forKey: .totalVotesWithProfile)
        sponsoredBillsUsed = try container.decodeIfPresent(Int.self, forKey: .sponsoredBillsUsed)
        cosponsoredBillsUsed = try container.decodeIfPresent(Int.self, forKey: .cosponsoredBillsUsed)
        totalEvidenceUsed = try container.decodeIfPresent(Int.self, forKey: .totalEvidenceUsed)
        totalEvidenceWithProfile = try container.decodeIfPresent(Int.self, forKey: .totalEvidenceWithProfile)
        minEvidenceRequired = try container.decodeIfPresent(Int.self, forKey: .minEvidenceRequired)
        minVotesRequired = try container.decodeIfPresent(Int.self, forKey: .minVotesRequired)
            ?? minEvidenceRequired
            ?? Self.empty.minVotesRequired
        isReady = try container.decode(Bool.self, forKey: .isReady)
        diagnostics = try container.decodeIfPresent(CivicProfileDiagnostics.self, forKey: .diagnostics)
        evidence = try container.decodeIfPresent([CivicProfileEvidenceItem].self, forKey: .evidence) ?? []
        // UX-32's fields only explain a locked profile, so one the app cannot read (absent from an older server, or
        // a type it does not expect) is left out rather than failing the whole profile.
        lockedBy = try? container.decodeIfPresent(String.self, forKey: .lockedBy)
        themesReady = try? container.decodeIfPresent(Int.self, forKey: .themesReady)
        minThemesRequired = try? container.decodeIfPresent(Int.self, forKey: .minThemesRequired)
        minThemeVotes = try? container.decodeIfPresent(Int.self, forKey: .minThemeVotes)
    }

    /// UX-32: the server says the profile is held by its themes, not its votes. Any other `lockedBy`, or none, is
    /// the vote lock, as the contract asks.
    var isLockedByThemes: Bool {
        !isReady && lockedBy == "themes"
    }

    /// Typed optional accessor: nil means this axis does not have enough signal.
    func signalValue(for axis: CivicProfileAxis) -> Double? {
        axes[axis.rawValue]
    }

    /// Axes that have no score yet because there is not enough evidence for them.
    var axesWithoutSignal: [CivicProfileAxis] {
        CivicProfileAxis.allCases.filter { signalValue(for: $0) == nil }
    }

    /// Typed accessor: returns the value for a given axis, or 0.5 (center) if missing.
    /// Views should use `signalValue(for:)` so a missing axis is not drawn as a real score.
    func value(for axis: CivicProfileAxis) -> Double {
        signalValue(for: axis) ?? 0.5
    }

    /// Converts a normalized axis value into a user-facing 1...10 scale.
    func displayScore(for axis: CivicProfileAxis) -> Int {
        displayScore(forNormalizedValue: value(for: axis))
    }

    /// Converts a normalized axis value into a user-facing 1...10 scale when signal exists.
    func displayScoreIfAvailable(for axis: CivicProfileAxis) -> Int? {
        guard let signal = signalValue(for: axis) else { return nil }
        return displayScore(forNormalizedValue: signal)
    }

    private func displayScore(forNormalizedValue value: Double) -> Int {
        let normalizedValue = min(max(value, 0), 1)
        if abs(normalizedValue - 0.5) < 0.000_001 {
            return 5
        }
        return min(10, max(1, Int((normalizedValue * 9).rounded()) + 1))
    }

    /// Number of additional votes needed to unlock the chart.
    var votesRemaining: Int {
        max(0, minVotesRequired - votesUsed)
    }

    var evidenceUsed: Int {
        totalEvidenceUsed ?? votesUsed
    }

    var evidenceRequirement: Int {
        minEvidenceRequired ?? minVotesRequired
    }

    var evidenceRemaining: Int {
        max(0, evidenceRequirement - evidenceUsed)
    }

    var weightedEvidenceUsed: Double {
        diagnostics?.weightedEvidenceUsed ?? Double(evidenceUsed)
    }

    var weightedEvidenceRequirement: Double {
        diagnostics?.minWeightedEvidenceRequired ?? Double(evidenceRequirement)
    }

    var weightedEvidenceRemaining: Double {
        max(0, weightedEvidenceRequirement - weightedEvidenceUsed)
    }

    var axesWithSufficientSignal: Int {
        diagnostics?.axesWithSufficientSignal ?? axes.count
    }

    var axesRequirement: Int {
        diagnostics?.minAxesRequired ?? 0
    }

    func coverage(for axis: CivicProfileAxis) -> CivicProfileAxisCoverage? {
        diagnostics?.axisCoverage[axis.rawValue]
    }
}
