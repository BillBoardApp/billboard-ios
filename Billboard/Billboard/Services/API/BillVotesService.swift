import Foundation

/// REST API wrapper for user bill voting feedback.
///
/// Endpoints:
/// - Single fetch:  `GET  /feedback?billId=BILL-123`
/// - Batch fetch:   `POST /feedback-batch { "billIds": [...] }`
/// - Set vote:      `POST /feedback { "billId": "BILL-123", "feedback": "Yea" }`
///
/// Legacy paths (`/fetchFeedback`, `/setFeedback`) are tried as 404 fallbacks.
///
/// `POST /feedback` is the one App Attest protected request (spec C3 3.4, 3.10): it is sent through
/// `AppAttestManager.current.performProtected`, which adds `X-Billboard-App-Attest` (an assertion over the
/// exact body bytes, or a marker) and never holds the vote back for long. The legacy `/setFeedback`
/// fallback is sent without it.
enum BillVotesService {
    enum Paths {
        static let fetchFeedback = "fetchFeedback"
        static let setFeedback = "setFeedback"
        static let feedback = "feedback"
        static let feedbackBatch = "feedback-batch"
    }

    struct RemoteVote: Equatable {
        let vote: VoteType
        let votedAt: Date
    }

    enum RemoteVoteState: Equatable {
        case voted(RemoteVote)
        case notVoted
    }

    static func setFeedback(billId: String, feedback: VoteType, reasons: [String] = []) async throws {
        let cleanReasons = Array(
            Set(
                reasons
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        #if DEBUG
        print(">>> [BillVotesService] setFeedback -> billId=\(billId) feedback=\(feedback.feedbackValue) reasons=\(cleanReasons.count)")
        #endif
        let payload = SetFeedbackRequest(
            billId: billId,
            feedback: feedback.feedbackValue,
            reasons: cleanReasons.isEmpty ? nil : cleanReasons
        )
        let body = try jsonBody(payload)
        let client = APIClient.current
        do {
            #if DEBUG
            print(">>> [BillVotesService] POST \(Paths.feedback) (set)")
            #endif
            // CDK defines POST /feedback for set. The assertion covers exactly `body`, which `send` sends.
            let label = "BillVotesService \(Paths.feedback)"
            try await AppAttestManager.current.performProtected(
                method: APIRequest.Method.post.rawValue,
                path: Paths.feedback,
                body: body
            ) { headers in
                try await client.payload(.post, Paths.feedback, body: body, label: label, headers: headers)
            }
        } catch {
            // Fallback to legacy /setFeedback if present.
            // Some environments expose these as separate resources.
            if let status = APIErrorDebug.httpStatusCode(from: error), status == 404 {
                #if DEBUG
                print(">>> [BillVotesService] POST \(Paths.feedback) -> 404, retrying POST \(Paths.setFeedback)")
                #endif
                try await client.payload(.post, Paths.setFeedback, body: body, label: "BillVotesService \(Paths.setFeedback)")
                return
            }
            #if DEBUG
            print(">>> [BillVotesService] setFeedback FAILED:\n\(APIErrorDebug.debugString(for: error))")
            #endif
            throw error
        }

        #if DEBUG
        print(">>> [BillVotesService] setFeedback -> success")
        #endif
    }

    static func fetchFeedback(billId: String) async throws -> RemoteVoteState {
        #if DEBUG
        print(">>> [BillVotesService] fetchFeedback(single) -> billId=\(billId)")
        #endif
        let payload = FetchFeedbackRequest(billId: billId)
        let body = try jsonBody(payload)
        do {
            #if DEBUG
            print(">>> [BillVotesService] GET \(Paths.feedback) (fetch single)")
            #endif
            // CDK defines GET /feedback for fetch. Pass billId via query string.
            let data = try await APIClient.current.payload(
                .get,
                Paths.feedback,
                query: ["billId": billId],
                label: "BillVotesService \(Paths.feedback)"
            )
            return try decodeVoteState(from: data)
        } catch {
            // Fallback to legacy /fetchFeedback if present.
            // (Some earlier deployments used POST /fetchFeedback { billId }).
            if let status = APIErrorDebug.httpStatusCode(from: error), status == 404 {
                #if DEBUG
                print(">>> [BillVotesService] GET \(Paths.feedback) -> 404, retrying POST \(Paths.fetchFeedback)")
                #endif
                let data = try await APIClient.current.payload(.post, Paths.fetchFeedback, body: body, label: "BillVotesService \(Paths.fetchFeedback)")
                return try decodeVoteState(from: data)
            }
            #if DEBUG
            print(">>> [BillVotesService] fetchFeedback(single) FAILED:\n\(APIErrorDebug.debugString(for: error))")
            #endif
            throw error
        }
    }

    /// Batch fetch vote states using `POST /feedback-batch`.
    /// Falls back to individual fan-out if the batch endpoint is not yet deployed (404).
    static func fetchFeedback(billIds: [String]) async throws -> [String: RemoteVoteState] {
        let cleaned = Array(Set(billIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !cleaned.isEmpty else { return [:] }

        #if DEBUG
        print(">>> [BillVotesService] fetchFeedback(batch) -> billIds=\(cleaned.count)")
        #endif

        let payload = FetchFeedbackBatchRequest(billIds: cleaned)
        let body = try jsonBody(payload)

        do {
            let data = try await APIClient.current.payload(
                .post,
                Paths.feedbackBatch,
                body: body,
                label: "BillVotesService \(Paths.feedbackBatch)"
            )
            let result = try decodeBatchVoteStates(from: data, requestedBillIds: cleaned)
            #if DEBUG
            print(">>> [BillVotesService] fetchFeedback(batch) -> resolved \(result.count)/\(cleaned.count)")
            #endif
            return result
        } catch {
            // If the batch endpoint doesn't exist yet (404), fall back to individual fan-out.
            if let status = APIErrorDebug.httpStatusCode(from: error), status == 404 {
                #if DEBUG
                print(">>> [BillVotesService] POST \(Paths.feedbackBatch) -> 404, falling back to fan-out")
                #endif
                return try await fetchFeedbackFanOut(billIds: cleaned)
            }
            #if DEBUG
            print(">>> [BillVotesService] fetchFeedback(batch) FAILED:\n\(APIErrorDebug.debugString(for: error))")
            #endif
            throw error
        }
    }

    /// Fan-out fallback: individual `GET /feedback?billId=` calls capped at 10 concurrent.
    private static func fetchFeedbackFanOut(billIds: [String]) async throws -> [String: RemoteVoteState] {
        let maxConcurrent = 10
        var result: [String: RemoteVoteState] = [:]

        var index = 0
        while index < billIds.count {
            let slice = Array(billIds[index..<min(index + maxConcurrent, billIds.count)])
            index += maxConcurrent

            let batch: [(String, RemoteVoteState)] = await withTaskGroup(
                of: (String, RemoteVoteState)?.self,
                returning: [(String, RemoteVoteState)].self
            ) { group in
                for billId in slice {
                    group.addTask {
                        do {
                            let state = try await fetchFeedback(billId: billId)
                            return (billId, state)
                        } catch {
                            #if DEBUG
                            print(">>> [BillVotesService] fetchFeedbackFanOut single failed billId=\(billId): \(error.localizedDescription)")
                            #endif
                            return nil
                        }
                    }
                }

                var collected: [(String, RemoteVoteState)] = []
                for await item in group {
                    if let item { collected.append(item) }
                }
                return collected
            }

            for (billId, state) in batch {
                result[billId] = state
            }
        }

        #if DEBUG
        print(">>> [BillVotesService] fetchFeedbackFanOut -> resolved \(result.count)/\(billIds.count)")
        #endif

        return result
    }

    // MARK: - Payloads

    private struct SetFeedbackRequest: Encodable {
        let billId: String
        let feedback: String
        let reasons: [String]?
    }

    private struct FetchFeedbackRequest: Encodable {
        let billId: String
    }

    private struct FetchFeedbackBatchRequest: Encodable {
        let billIds: [String]
    }

    // MARK: - Decoding (resilient to wrapper shapes)

    private struct VoteDTO: Decodable {
        let billId: String?
        let feedback: String?
        let votedAt: String?
        let votedAtDate: Date?
        let updatedAt: String?
        let updatedAtDate: Date?

        enum CodingKeys: String, CodingKey {
            case billId
            case feedback
            case votedAt
            case voted_at
            case updatedAt
            case updated_at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            billId = try? container.decodeIfPresent(String.self, forKey: .billId)
            feedback = try? container.decodeIfPresent(String.self, forKey: .feedback)

            // votedAt can be string or Date depending on server
            votedAt = (try? container.decodeIfPresent(String.self, forKey: .votedAt))
                ?? (try? container.decodeIfPresent(String.self, forKey: .voted_at))

            votedAtDate = (try? container.decodeIfPresent(Date.self, forKey: .votedAt))
                ?? (try? container.decodeIfPresent(Date.self, forKey: .voted_at))

            updatedAt = (try? container.decodeIfPresent(String.self, forKey: .updatedAt))
                ?? (try? container.decodeIfPresent(String.self, forKey: .updated_at))

            updatedAtDate = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt))
                ?? (try? container.decodeIfPresent(Date.self, forKey: .updated_at))
        }

        func parsedVotedAt() -> Date? {
            if let votedAtDate { return votedAtDate }
            if let updatedAtDate { return updatedAtDate }
            return FlexibleISO8601.parse(votedAt) ?? FlexibleISO8601.parse(updatedAt)
        }
    }

    private struct SingleVoteWrapperDTO: Decodable {
        let vote: VoteDTO?
        let item: VoteDTO?
        let feedback: VoteDTO?
        let hasVote: Bool?
        let exists: Bool?
    }

    private struct BatchWrapperArrayDTO: Decodable {
        let votes: [VoteDTO]?
        let items: [VoteDTO]?
        let feedback: [VoteDTO]?
        let notVotedBillIds: [String]?
        let not_voted_bill_ids: [String]?
    }

    /// The vote state in a single-vote payload: an empty body, a vote object, or a
    /// `{vote|item|feedback, hasVote, exists}` wrapper.
    static func decodeVoteState(from data: Data) throws -> RemoteVoteState {
        if data.isEmpty {
            return .notVoted
        }

        let decoder = JSONDecoder.convertingFromSnakeCase(dates: .iso8601)

        // 1) Direct DTO
        if let dto = try? decoder.decode(VoteDTO.self, from: data) {
            if let raw = dto.feedback, let vote = VoteType(apiValue: raw), let votedAt = dto.parsedVotedAt() {
                return .voted(RemoteVote(vote: vote, votedAt: votedAt))
            }
            // Some backends return an object with billId but no vote when not voted.
            return .notVoted
        }

        // 2) Common wrapper
        if let wrapped = try? decoder.decode(SingleVoteWrapperDTO.self, from: data) {
            if wrapped.hasVote == false || wrapped.exists == false {
                return .notVoted
            }

            let dto = wrapped.vote ?? wrapped.item ?? wrapped.feedback
            if let dto {
                if let raw = dto.feedback, let vote = VoteType(apiValue: raw), let votedAt = dto.parsedVotedAt() {
                    return .voted(RemoteVote(vote: vote, votedAt: votedAt))
                }
                return .notVoted
            }
        }

        // No known shape matched: log why the primary shape failed to decode.
        _ = try? APIDecoding.decode(VoteDTO.self, from: data, decoder: decoder, label: "BillVotesService feedback")
        throw APIServiceError.invalidPayload(Paths.feedback)
    }

    /// Vote states for `requestedBillIds` from a batch payload: a vote array or a
    /// `{votes|items|feedback, notVotedBillIds}` wrapper. Ids the payload does not
    /// mention come back `.notVoted`.
    static func decodeBatchVoteStates(from data: Data, requestedBillIds: [String]) throws -> [String: RemoteVoteState] {
        if data.isEmpty {
            return Dictionary(uniqueKeysWithValues: requestedBillIds.map { ($0, .notVoted) })
        }

        let decoder = JSONDecoder.convertingFromSnakeCase(dates: .iso8601)

        // 1) Raw array
        if let arr = try? decoder.decode([VoteDTO].self, from: data) {
            return mapBatch(arr, requestedBillIds: requestedBillIds, explicitNotVoted: [])
        }

        // 2) Wrapper
        if let wrapped = try? decoder.decode(BatchWrapperArrayDTO.self, from: data) {
            let arr = wrapped.votes ?? wrapped.items ?? wrapped.feedback ?? []
            let notVoted = wrapped.notVotedBillIds ?? wrapped.not_voted_bill_ids ?? []
            return mapBatch(arr, requestedBillIds: requestedBillIds, explicitNotVoted: notVoted)
        }

        // No known shape matched: log why the primary shape failed to decode.
        _ = try? APIDecoding.decode([VoteDTO].self, from: data, decoder: decoder, label: "BillVotesService feedback-batch")
        throw APIServiceError.invalidPayload(Paths.feedbackBatch)
    }

    private static func mapBatch(_ arr: [VoteDTO], requestedBillIds: [String], explicitNotVoted: [String]) -> [String: RemoteVoteState] {
        var result: [String: RemoteVoteState] = Dictionary(uniqueKeysWithValues: requestedBillIds.map { ($0, .notVoted) })

        for billId in explicitNotVoted {
            result[billId] = .notVoted
        }

        for dto in arr {
            guard let billId = (dto.billId?.trimmingCharacters(in: .whitespacesAndNewlines)), !billId.isEmpty else {
                continue
            }
            guard let voteStr = dto.feedback, let vote = VoteType(apiValue: voteStr) else {
                continue
            }
            guard let votedAt = dto.parsedVotedAt() else {
                // If server omits votedAt, treat as notVoted rather than manufacturing timestamps.
                result[billId] = .notVoted
                continue
            }
            result[billId] = .voted(RemoteVote(vote: vote, votedAt: votedAt))
        }

        return result
    }

    // MARK: - Request bodies

    private static func jsonBody<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        // Feedback API contract expects camelCase keys (e.g., `billId`, `billIds`).
        // Other APIs in this app use snake_case, but this one should not.
        encoder.keyEncodingStrategy = .useDefaultKeys
        return try encoder.encode(value)
    }
}

/// REST API wrapper for bill-level community rollups.
///
/// Endpoint:
/// - Fetch stats: `GET /bill-stats?billId=BILLS-...[&scope=companions]`
enum BillStatsService {
    private static let path = "bill-stats"

    /// Why the stats were not served (INT-11).
    enum FetchError: Error, Equatable {
        /// `RESULTS_LOCKED` (403): the server holds no Yea, Nay or Abstain from this user on the bill or
        /// its companion group yet, such as a vote that was not saved.
        case resultsLocked
    }

    /// The server's code for `FetchError.resultsLocked`.
    static let resultsLockedCode = "RESULTS_LOCKED"

    /// Whose votes the stats count (APPF-23).
    enum Scope: String, Sendable {
        /// This bill's votes only (the API's default; the query leaves `scope` out).
        case bill
        /// For a bill in a companion group, every member's votes, one per person (the primary's wins),
        /// with `companionBillIds` set. For any other bill, the same as `.bill`.
        case companions
    }

    /// Vote counts for one scope. Every vote counts once (INT-08); R2 reads only the
    /// plain fields. The `weighted*` fields are optional so a server that drops them still decodes;
    /// nothing in the app reads them any more (servers keep them for R1 and older builds).
    struct VoteTotals: Decodable, Equatable {
        let votes: Int
        let yea: Int
        let nay: Int
        let abstain: Int
        let decisionVotes: Int
        let yeaPct: Double?
        let weightedVotes: Double?
        let weightedYea: Double?
        let weightedNay: Double?
        let weightedAbstain: Double?
        let weightedDecisionVotes: Double?
        let weightedYeaPct: Double?
    }

    /// Plain counts for one group of voters (`VoteSplitV1`): every vote counted once. `yeaPct` is
    /// 0 to 100 over Yea + Nay, nil when there are none.
    struct VoteSplit: Decodable, Equatable {
        let votes: Int
        let yea: Int
        let nay: Int
        let abstain: Int
        let decisionVotes: Int
        let yeaPct: Double?

        init(votes: Int, yea: Int, nay: Int, abstain: Int, decisionVotes: Int, yeaPct: Double?) {
            self.votes = votes
            self.yea = yea
            self.nay = nay
            self.abstain = abstain
            self.decisionVotes = decisionVotes
            self.yeaPct = yeaPct
        }

        /// The plain split of a scope's totals (the fallback for a body without `comparison`).
        init(_ totals: VoteTotals) {
            self.init(
                votes: totals.votes,
                yea: totals.yea,
                nay: totals.nay,
                abstain: totals.abstain,
                decisionVotes: totals.decisionVotes,
                yeaPct: totals.yeaPct
            )
        }
    }

    /// All users beside verified voters, national only (`BillStatsComparisonV1`, INT-08).
    /// `verified` is absent when `verifiedWithheld` (fewer than `minDecisionVotes` verified Yea + Nay).
    struct Comparison: Decodable, Equatable {
        /// The floor a body without `comparison` implies (`STATS_MIN_DECISION_VOTES`).
        static let defaultMinDecisionVotes = 5

        let allUsers: VoteSplit
        let verified: VoteSplit?
        let verifiedWithheld: Bool
        let minDecisionVotes: Int

        init(allUsers: VoteSplit, verified: VoteSplit?, verifiedWithheld: Bool, minDecisionVotes: Int) {
            self.allUsers = allUsers
            self.verified = verified
            self.verifiedWithheld = verifiedWithheld
            self.minDecisionVotes = minDecisionVotes
        }

        private enum CodingKeys: String, CodingKey {
            case allUsers
            case verified
            case verifiedWithheld
            case minDecisionVotes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            allUsers = try container.decode(VoteSplit.self, forKey: .allUsers)
            verified = try container.decodeIfPresent(VoteSplit.self, forKey: .verified)
            // A body that names no verified split withholds it, whatever the flag says.
            verifiedWithheld = (try container.decodeIfPresent(Bool.self, forKey: .verifiedWithheld) ?? false) || verified == nil
            let floor = try container.decodeIfPresent(Int.self, forKey: .minDecisionVotes) ?? Self.defaultMinDecisionVotes
            minDecisionVotes = max(1, floor)
        }

        /// The comparison a body without `comparison` implies: everyone from `totals`, verified
        /// voters from `segments.verified`, withheld under the default floor.
        static func fallback(totals: VoteTotals, verified: VoteTotals) -> Comparison {
            let floor = defaultMinDecisionVotes
            let withheld = verified.decisionVotes < floor
            return Comparison(
                allUsers: VoteSplit(totals),
                verified: withheld ? nil : VoteSplit(verified),
                verifiedWithheld: withheld,
                minDecisionVotes: floor
            )
        }
    }

    struct Segments: Decodable, Equatable {
        let verified: VoteTotals
        let selfAttested: VoteTotals
    }

    struct StateRollup: Decodable, Equatable {
        let state: String
        let totals: VoteTotals
        let segments: Segments
    }

    struct DistrictRollup: Decodable, Equatable {
        let state: String
        let district: String
        let totals: VoteTotals
        let segments: Segments
    }

    struct Rollups: Decodable, Equatable {
        let byState: [String: StateRollup]
        let byDistrict: [String: DistrictRollup]

        private enum CodingKeys: String, CodingKey {
            case byState
            case byDistrict
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            byState = try container.decodeIfPresent([String: StateRollup].self, forKey: .byState) ?? [:]
            byDistrict = try container.decodeIfPresent([String: DistrictRollup].self, forKey: .byDistrict) ?? [:]
        }
    }

    struct ReasonBucket: Decodable, Equatable {
        let reasonKey: String
        let count: Int
        let pct: Double
    }

    struct ReasonSide: Decodable, Equatable {
        let voteCount: Int
        let reasons: [ReasonBucket]
    }

    struct ReasonBreakdown: Decodable, Equatable {
        let minCount: Int
        let yea: ReasonSide
        let nay: ReasonSide
    }

    struct BillStats: Decodable, Equatable {
        let billId: String
        let generatedAt: String?
        let totals: VoteTotals
        let segments: Segments
        let rollups: Rollups
        let reasonBreakdown: ReasonBreakdown?
        /// Set only for `scope=companions` on a grouped bill: the members whose votes were combined,
        /// one vote per person. The detail's "Combined votes on ..." caption shows only when present.
        let companionBillIds: [String]?
        /// Everyone beside verified voters (INT-08); nil in bodies that lack it or
        /// when the block does not decode. Read it through `resolvedComparison`.
        let comparison: Comparison?

        init(
            billId: String,
            generatedAt: String?,
            totals: VoteTotals,
            segments: Segments,
            rollups: Rollups,
            reasonBreakdown: ReasonBreakdown?,
            companionBillIds: [String]?,
            comparison: Comparison? = nil
        ) {
            self.billId = billId
            self.generatedAt = generatedAt
            self.totals = totals
            self.segments = segments
            self.rollups = rollups
            self.reasonBreakdown = reasonBreakdown
            self.companionBillIds = companionBillIds
            self.comparison = comparison
        }

        private enum CodingKeys: String, CodingKey {
            case billId
            case generatedAt
            case totals
            case segments
            case rollups
            case reasonBreakdown
            case companionBillIds
            case comparison
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            billId = try container.decode(String.self, forKey: .billId)
            generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
            totals = try container.decode(VoteTotals.self, forKey: .totals)
            segments = try container.decode(Segments.self, forKey: .segments)
            rollups = try container.decode(Rollups.self, forKey: .rollups)
            reasonBreakdown = try container.decodeIfPresent(ReasonBreakdown.self, forKey: .reasonBreakdown)
            companionBillIds = try container.decodeIfPresent([String].self, forKey: .companionBillIds)
            // Optional and additive: a malformed block falls back to totals and segments rather
            // than failing the whole response.
            comparison = try? container.decodeIfPresent(Comparison.self, forKey: .comparison)
        }

        /// True when the stats combine a companion group's votes (at least two members listed).
        var isCombinedCompanionStats: Bool { (companionBillIds?.count ?? 0) >= 2 }

        /// `comparison`, or, for a body without it, the one its totals imply.
        var resolvedComparison: Comparison {
            comparison ?? .fallback(totals: totals, verified: segments.verified)
        }
    }

    /// The bill's Results. Throws `FetchError.resultsLocked` when the server holds no vote from this user
    /// on the bill (INT-11); every other failure passes through unchanged.
    static func fetchBillStats(billId: String, forceRefresh: Bool = false, scope: Scope = .bill) async throws -> BillStats {
        let cleanedBillId = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedBillId.isEmpty else { throw APIServiceError.invalidPayload(path) }

        var query: [String: String] = ["billId": cleanedBillId]
        if forceRefresh {
            query["forceRefresh"] = "true"
        }
        if scope == .companions {
            query["scope"] = Scope.companions.rawValue
        }

        #if DEBUG
        print(">>> [BillStatsService] GET bill-stats billId=\(cleanedBillId) forceRefresh=\(forceRefresh) scope=\(scope.rawValue)")
        #endif

        let data: Data
        do {
            data = try await APIClient.current.payload(
                .get,
                path,
                query: query,
                label: "BillStatsService bill-stats"
            )
        } catch {
            // Keyed on the code, not the status, so a server that answers 423 instead works too.
            if APIErrorResponse.errorCode(from: error) == resultsLockedCode {
                throw FetchError.resultsLocked
            }
            throw error
        }

        do {
            return try APIDecoding.decode(
                BillStats.self,
                from: data,
                decoder: .convertingFromSnakeCase(),
                label: "BillStatsService bill-stats"
            )
        } catch {
            throw APIServiceError.invalidPayload(path)
        }
    }
}
