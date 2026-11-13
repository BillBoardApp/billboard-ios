import Foundation

/// REST API wrapper for the signed-in user's civic endpoints.
///
/// Endpoints:
/// - Civic score:    `GET /civic-score`
/// - Civic profile:  `GET /civic-profile`
enum CivicService {
    static func fetchCivicScore() async throws -> CivicScore {
        #if DEBUG
        print(">>> [CivicScoreService] GET civic-score")
        #endif

        let score = try await APIClient.current.response(
            CivicScore.self,
            .get,
            "civic-score",
            label: "CivicScoreService civic-score",
            decoder: .usingDefaultKeys()
        )

        #if DEBUG
        print(">>> [CivicScoreService] success -> civicScore=\(score.civicScore) totalVotes=\(score.totalVotes) streak=\(score.currentStreak)")
        #endif

        return score
    }

    static func fetchCivicProfile() async throws -> CivicProfileResponse {
        #if DEBUG
        print(">>> [CivicProfileService] GET civic-profile")
        #endif

        let profile = try await APIClient.current.response(
            CivicProfileResponse.self,
            .get,
            "civic-profile",
            label: "CivicProfileService civic-profile",
            decoder: .usingDefaultKeys()
        )

        #if DEBUG
        print(">>> [CivicProfileService] success -> votesUsed=\(profile.votesUsed) isReady=\(profile.isReady)")
        #endif

        return profile
    }
}
