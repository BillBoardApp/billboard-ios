import Foundation

// The API services the stores use, as protocols. Each store takes the ones it needs
// in its initializer, defaulting to the live service (`<Service>.Live()`, which
// forwards to the static API), so tests can pass fakes and never touch the network.

// MARK: - Bills

protocol BillsServicing: Sendable {
    func getBillsManifest(updatedAfter: Date?) async throws -> [BillsManifestItem]
    func getProcessedBill(guid: String, congress: String?, billType: String?, billID: String?) async throws -> Bill

    /// Cache reads are nonisolated: the store reads the manifest cache off the main actor.
    nonisolated func cachedBillsManifest() -> [BillsManifestItem]?
    nonisolated func cachedBillsManifestIsFresh(maxAge: TimeInterval) -> Bool
    nonisolated func cachedBillsManifestIsFull() -> Bool
    nonisolated func cachedBillsManifestIsFull(maxAge: TimeInterval) -> Bool
    /// The companion groups (APPF-23) of the latest manifest response that listed them; nil when none
    /// has. `getBillsManifest` keeps them current. Default: nil.
    nonisolated func cachedCompanionGroups() -> [BillCompanionGroup]?
}

extension BillsServicing {
    nonisolated func cachedCompanionGroups() -> [BillCompanionGroup]? { nil }
}

extension BillsService {
    struct Live: BillsServicing {
        nonisolated init() {}

        func getBillsManifest(updatedAfter: Date?) async throws -> [BillsManifestItem] {
            try await BillsService.getBillsManifest(updatedAfter: updatedAfter)
        }

        func getProcessedBill(guid: String, congress: String?, billType: String?, billID: String?) async throws -> Bill {
            try await BillsService.getProcessedBill(guid: guid, congress: congress, billType: billType, billID: billID)
        }

        nonisolated func cachedBillsManifest() -> [BillsManifestItem]? {
            BillsService.cachedBillsManifest()
        }

        nonisolated func cachedBillsManifestIsFresh(maxAge: TimeInterval) -> Bool {
            BillsService.cachedBillsManifestIsFresh(maxAge: maxAge)
        }

        nonisolated func cachedBillsManifestIsFull() -> Bool {
            BillsService.cachedBillsManifestIsFull()
        }

        nonisolated func cachedBillsManifestIsFull(maxAge: TimeInterval) -> Bool {
            BillsService.cachedBillsManifestIsFull(maxAge: maxAge)
        }

        nonisolated func cachedCompanionGroups() -> [BillCompanionGroup]? {
            BillsService.cachedCompanionGroups()
        }
    }
}

// MARK: - Votes

protocol BillVotesServicing: Sendable {
    func fetchFeedback(billIds: [String]) async throws -> [String: BillVotesService.RemoteVoteState]
    func fetchFeedback(billId: String) async throws -> BillVotesService.RemoteVoteState
    func setFeedback(billId: String, feedback: VoteType, reasons: [String]) async throws
}

extension BillVotesService {
    struct Live: BillVotesServicing {
        nonisolated init() {}

        func fetchFeedback(billIds: [String]) async throws -> [String: RemoteVoteState] {
            try await BillVotesService.fetchFeedback(billIds: billIds)
        }

        func fetchFeedback(billId: String) async throws -> RemoteVoteState {
            try await BillVotesService.fetchFeedback(billId: billId)
        }

        func setFeedback(billId: String, feedback: VoteType, reasons: [String]) async throws {
            try await BillVotesService.setFeedback(billId: billId, feedback: feedback, reasons: reasons)
        }
    }
}

// MARK: - Congress

protocol CongressServicing: Sendable {
    func getCongressMembersManifest() async throws -> [CongressMemberManifestItem]
    func cachedCongressMembersManifest() -> [CongressMemberManifestItem]?
    func cachedCongressMembersManifest(maxAge: TimeInterval) -> [CongressMemberManifestItem]?
}

extension CongressService {
    struct Live: CongressServicing {
        nonisolated init() {}

        func getCongressMembersManifest() async throws -> [CongressMemberManifestItem] {
            try await CongressService.getCongressMembersManifest()
        }

        func cachedCongressMembersManifest() -> [CongressMemberManifestItem]? {
            CongressService.cachedCongressMembersManifest()
        }

        func cachedCongressMembersManifest(maxAge: TimeInterval) -> [CongressMemberManifestItem]? {
            CongressService.cachedCongressMembersManifest(maxAge: maxAge)
        }
    }
}

// MARK: - Preferences

protocol PreferencesServicing: Sendable {
    func getPreferences() async throws -> [PreferencesItem]
    func putPreferences(_ items: [PreferencesItem]) async throws
    func deletePreferences(_ items: [PreferencesItem]) async throws
}

extension PreferencesService {
    struct Live: PreferencesServicing {
        nonisolated init() {}

        func getPreferences() async throws -> [PreferencesItem] {
            try await PreferencesService.getPreferences()
        }

        func putPreferences(_ items: [PreferencesItem]) async throws {
            try await PreferencesService.putPreferences(items)
        }

        func deletePreferences(_ items: [PreferencesItem]) async throws {
            try await PreferencesService.deletePreferences(items)
        }
    }
}

// MARK: - Civic score and profile

protocol CivicServicing: Sendable {
    func fetchCivicScore() async throws -> CivicScore
    func fetchCivicProfile() async throws -> CivicProfileResponse
}

extension CivicService {
    struct Live: CivicServicing {
        nonisolated init() {}

        func fetchCivicScore() async throws -> CivicScore {
            try await CivicService.fetchCivicScore()
        }

        func fetchCivicProfile() async throws -> CivicProfileResponse {
            try await CivicService.fetchCivicProfile()
        }
    }
}

// MARK: - Weekly digest

protocol WeeklyDigestServicing: Sendable {
    func fetchLatest() async throws -> WeeklyDigest?
}

extension WeeklyDigestService {
    struct Live: WeeklyDigestServicing {
        nonisolated init() {}

        func fetchLatest() async throws -> WeeklyDigest? {
            try await WeeklyDigestService.fetchLatest()
        }
    }
}
