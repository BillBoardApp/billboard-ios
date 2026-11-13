import Foundation
import os

enum CongressService {
    private enum CacheKeys {
        static let manifestData = "CongressService.congressMembersManifest.data"
        static let manifestTimestamp = "CongressService.congressMembersManifest.timestamp"
    }

    /// The cached manifest's members by their stored UUID (`UUID.deterministic(from: id)`), for
    /// `congressMember(for:)`: every bill card looks up its sponsor, and without the index each lookup
    /// would read and decode the whole file. Built from the file on the first lookup and dropped when
    /// the manifest is written. `generation` counts the drops, so a build that began before one does
    /// not store its out-of-date result.
    private nonisolated struct MemberIndex {
        var generation = 0
        var membersByID: [UUID: CongressMemberManifestItem]?
    }

    private nonisolated static let memberIndex = OSAllocatedUnfairLock(initialState: MemberIndex())

    private struct ProcessedCongressMemberEnvelope: Decodable {
        let member: UserAPIContractsV1.ProcessedCongressMember
    }

    private struct FlexibleProcessedCongressMemberEnvelope: Decodable {
        let member: ProcessedCongressMember
    }

    private enum Paths {
        static let manifest = "congress-members-manifest"
        static let processedMember = "processed-congress-members"
        static let civicProfile = "congress-member-civic-profile"
    }

    /// Fetches the manifest of Congress members (IDs and basic display fields).
    /// This endpoint is expected to be exposed at `GET /congress-members-manifest` on the `myapi` REST API.
    static func getCongressMembersManifest() async throws -> [CongressMemberManifestItem] {
        let data = try await APIClient.current.payload(
            .get,
            Paths.manifest,
            label: "CongressService congress-members-manifest",
            authMode: .autoFetch
        )
        guard !data.isEmpty else { return [] }

        let items: [CongressMemberManifestItem]
        do {
            let manifest = try APIDecoding.decode(
                UserAPIContractsV1.CongressMembersManifest.self,
                from: data,
                decoder: .convertingFromSnakeCase(),
                label: "CongressService congress-members-manifest"
            )
            items = manifest.members.map(CongressMemberManifestItem.init(dto:))
        } catch {
            throw APIServiceError.invalidPayload(Paths.manifest)
        }

        cacheCongressMembersManifest(items)
        return items
    }

    /// Returns the last cached manifest if available.
    static func cachedCongressMembersManifest() -> [CongressMemberManifestItem]? {
        guard let data = DiskJSONCache.data(forKey: CacheKeys.manifestData) else { return nil }
        return try? JSONDecoder.convertingFromSnakeCase().decode([CongressMemberManifestItem].self, from: data)
    }

    /// Returns the cached manifest only if it is within `maxAge` seconds.
    /// Use this to avoid network refreshes when the cache is still fresh.
    static func cachedCongressMembersManifest(maxAge: TimeInterval) -> [CongressMemberManifestItem]? {
        let defaults = UserDefaults.standard
        let ts = defaults.double(forKey: CacheKeys.manifestTimestamp)
        guard ts > 0 else { return nil }
        let age = Date().timeIntervalSince1970 - ts
        guard age >= 0, age <= maxAge else { return nil }
        return cachedCongressMembersManifest()
    }

    static func cacheCongressMembersManifest(_ items: [CongressMemberManifestItem]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        if let data = try? encoder.encode(items) {
            let defaults = UserDefaults.standard
            DiskJSONCache.store(data, forKey: CacheKeys.manifestData)
            defaults.set(Date().timeIntervalSince1970, forKey: CacheKeys.manifestTimestamp)
            invalidateMemberIndex()
        }
    }

    /// Drops the member index, so the next `congressMember(for:)` builds it from the cache file again.
    /// Every write of the manifest does this.
    nonisolated static func invalidateMemberIndex() {
        memberIndex.withLock { state in
            state.generation += 1
            state.membersByID = nil
        }
    }

    /// Fetches full member details for a specific bioguide ID using the processed endpoint.
    static func getProcessedCongressMember(bioguideId: String) async throws -> ProcessedCongressMember {
        let normalizedId = bioguideId.uppercased()
        let queryParameters = ["bioguideId": normalizedId]
        let data = try await APIClient.current.payload(
            .get,
            Paths.processedMember,
            query: queryParameters,
            label: "CongressService processed-congress-members",
            authMode: .autoFetch
        )
        if data.isEmpty {
#if DEBUG
            print("[CongressService] processed-congress-members EMPTY body for bioguideId=\(normalizedId)")
#endif
            throw APIServiceError.invalidPayload(Paths.processedMember)
        }

#if DEBUG
        if let bodyPreview = String(data: data, encoding: .utf8) {
            let prefix = bodyPreview.prefix(500)
            print("[CongressService] processed-congress-members response prefix: \(prefix)")
        }
#endif

        return try decodeProcessedCongressMember(from: data)
    }

    /// The member in a `GET /processed-congress-members` payload: the contract shape
    /// (bare or under `member`) first, then the flexible legacy decoder.
    static func decodeProcessedCongressMember(from data: Data) throws -> ProcessedCongressMember {
        let decoder = JSONDecoder.convertingFromSnakeCase()

        if let item = try? decoder.decode(UserAPIContractsV1.ProcessedCongressMember.self, from: data) {
            return ProcessedCongressMember(dto: item)
        }
        if let wrapped = try? decoder.decode(ProcessedCongressMemberEnvelope.self, from: data) {
            return ProcessedCongressMember(dto: wrapped.member)
        }
        if let flexible = try? decoder.decode(ProcessedCongressMember.self, from: data) {
            return flexible
        }
        if let flexibleWrapped = try? decoder.decode(FlexibleProcessedCongressMemberEnvelope.self, from: data) {
            return flexibleWrapped.member
        }
        // No known shape matched: log why the contract shape failed to decode.
        _ = try? APIDecoding.decode(
            UserAPIContractsV1.ProcessedCongressMember.self,
            from: data,
            decoder: decoder,
            label: "CongressService processed-congress-members"
        )
        throw APIServiceError.invalidPayload(Paths.processedMember)
    }

    /// Fetches a Congress member civic profile computed from official votes.
    /// Endpoint: `GET /congress-member-civic-profile?bioguideId=...`
    static func getCongressMemberCivicProfile(bioguideId: String) async throws -> CivicProfileResponse {
        let normalizedId = bioguideId.uppercased()
        let queryParameters = ["bioguideId": normalizedId]
        let data = try await APIClient.current.payload(
            .get,
            Paths.civicProfile,
            query: queryParameters,
            label: "CongressService congress-member-civic-profile",
            authMode: .autoFetch
        )

        guard !data.isEmpty else {
            throw APIServiceError.invalidPayload(Paths.civicProfile)
        }

        let decoder = JSONDecoder.usingDefaultKeys()
        if let profile = try? APIDecoding.decode(
            UserAPIContractsV1.CongressMemberCivicProfile.self,
            from: data,
            decoder: decoder,
            label: "CongressService congress-member-civic-profile"
        ) {
            return CivicProfileResponse(
                axes: profile.axes,
                votesUsed: profile.votesUsed,
                totalVotesWithProfile: profile.totalVotesWithProfile,
                sponsoredBillsUsed: profile.sponsoredBillsUsed,
                cosponsoredBillsUsed: profile.cosponsoredBillsUsed,
                totalEvidenceUsed: profile.totalEvidenceUsed,
                totalEvidenceWithProfile: profile.totalEvidenceWithProfile,
                minEvidenceRequired: profile.minEvidenceRequired,
                minVotesRequired: profile.minEvidenceRequired,
                isReady: profile.isReady,
                diagnostics: CivicProfileDiagnostics(
                    rollingWindow: profile.diagnostics.rollingWindow,
                    evidenceWeights: CivicProfileEvidenceWeights(
                        voteYea: profile.diagnostics.evidenceWeights.voteYea,
                        voteNay: profile.diagnostics.evidenceWeights.voteNay,
                        sponsor: profile.diagnostics.evidenceWeights.sponsor,
                        cosponsor: profile.diagnostics.evidenceWeights.cosponsor
                    ),
                    weightedEvidenceUsed: profile.diagnostics.weightedEvidenceUsed,
                    totalWeightedEvidenceWithProfile: profile.diagnostics.totalWeightedEvidenceWithProfile,
                    minWeightedEvidenceRequired: profile.diagnostics.minWeightedEvidenceRequired,
                    minAxisWeightedEvidenceRequired: profile.diagnostics.minAxisWeightedEvidenceRequired,
                    minAxesRequired: profile.diagnostics.minAxesRequired,
                    axesWithSufficientSignal: profile.diagnostics.axesWithSufficientSignal,
                    axisCoverage: profile.diagnostics.axisCoverage.mapValues {
                        CivicProfileAxisCoverage(
                            evidenceCount: $0.evidenceCount,
                            weightedEvidence: $0.weightedEvidence,
                            isReady: $0.isReady
                        )
                    },
                    readinessReasons: profile.diagnostics.readinessReasons,
                    latestEvidenceAt: profile.diagnostics.latestEvidenceAt
                ),
                evidence: profile.evidence.map {
                    CivicProfileEvidenceItem(
                        billGuid: $0.billGuid,
                        title: $0.title,
                        evidenceType: $0.evidenceType,
                        votePosition: $0.votePosition,
                        occurredAt: $0.occurredAt,
                        weight: $0.weight,
                        axes: $0.axes,
                        civicProfile: $0.civicProfile
                    )
                }
            )
        }

        throw APIServiceError.invalidPayload(Paths.civicProfile)
    }

    // MARK: - Helpers

    static func debugString(for error: Error) -> String {
        APIErrorDebug.debugString(for: error)
    }

    /// Resolve a `CongressMember` for a stored UUID by consulting the cached manifest.
    /// Returns `nil` if no cached manifest or no matching member is found.
    static func congressMember(for id: UUID) -> CongressMember? {
        if let item = cachedMemberManifestItem(for: id) {
            let party = PoliticalParty.from(raw: item.party) ?? .independent
            return CongressMember(
                id: UUID.deterministic(from: item.id),
                name: item.name,
                state: item.state ?? "",
                chamber: item.chamberNormalized ?? "",
                imageUrl: item.depictionImageUrl,
                currentCongressBillsSupportedCount: item.currentCongressBillsSupportedCount,
                biography: "",
                party: party,
                district: item.district,
                termsServed: 0,
                serviceStartYear: Calendar.current.component(.year, from: Date())
            )
        }
        return nil
    }

    /// The cached manifest item whose stored UUID is `id` (the first, when several share it), from the
    /// member index. A missing or unreadable cache builds no index, so a manifest cached later is found.
    /// For callers that need the item itself rather than the `CongressMember` built from it.
    static func cachedMemberManifestItem(for id: UUID) -> CongressMemberManifestItem? {
        let current = memberIndex.withLock { (generation: $0.generation, membersByID: $0.membersByID) }
        if let membersByID = current.membersByID { return membersByID[id] }

        // The file is read outside the lock.
        guard let manifest = cachedCongressMembersManifest() else { return nil }
        let membersByID = Dictionary(
            manifest.map { (UUID.deterministic(from: $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        memberIndex.withLock { state in
            // Unless the manifest was written while the file was read.
            if state.generation == current.generation { state.membersByID = membersByID }
        }
        return membersByID[id]
    }
}
