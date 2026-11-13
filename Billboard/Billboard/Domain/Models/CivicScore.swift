import Foundation

struct VoteDay: Codable, Equatable {
    let date: String   // "YYYY-MM-DD"
    let count: Int
}

struct CivicRank: Codable, Equatable {
    let id: String
    let title: String
    let minScore: Int
    let approxVotesRequired: Int

    static let empty = CivicRank(
        id: "citizen",
        title: "Citizen",
        minScore: 0,
        approxVotesRequired: 0
    )
}

struct CivicHonor: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let description: String
    let bonusScore: Int
    let category: String
}

struct CivicScore: Codable, Equatable {
    let civicScore: Int
    let totalVotes: Int
    let currentStreak: Int
    let longestStreak: Int
    let lastVotedAt: String?
    let recentVoteDays: [VoteDay]?
    let voteScore: Int
    let streakBonus: Int
    let honorBonus: Int
    let coverageAreaCount: Int
    let rank: CivicRank
    let nextRank: CivicRank?
    let scoreToNextRank: Int
    let honors: [CivicHonor]

    static let empty = CivicScore(
        civicScore: 0,
        totalVotes: 0,
        currentStreak: 0,
        longestStreak: 0,
        lastVotedAt: nil,
        recentVoteDays: nil,
        voteScore: 0,
        streakBonus: 0,
        honorBonus: 0,
        coverageAreaCount: 0,
        rank: .empty,
        nextRank: nil,
        scoreToNextRank: 0,
        honors: []
    )
}
