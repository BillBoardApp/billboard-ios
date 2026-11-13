import Foundation
import Combine
import SwiftUI

/// What one vote write ended with (`BillVoteStore.submitVote`).
nonisolated enum VoteWriteResult: Equatable, Sendable {
    /// The server stored the vote.
    case stored
    /// The vote was not confirmed and stays as sent: the outcome is unknown (offline, a timeout, a server
    /// error without a code), the write was cancelled, or the server refused it while a newer vote on the
    /// bill was waiting (that vote's result decides).
    case notSaved
    /// The server refused the vote and the bill's vote went back to `restored`: its row from before the
    /// votes the server has not confirmed (`.voted(.abstain)` for an Abstain row, `.unknown` when the
    /// vote is not known and will be checked again). Every place that shows the vote rolls back (APPF-27).
    case rolledBack(restored: VoteState)
}

/// SwiftUI-friendly repository for user bill votes.
///
/// Intent-driven screens call `fetchVotes(for:)` or `fetchVoteIfNeeded(for:)`.
/// This store:
/// - renders immediately using cache (or `.unknown`)
/// - fetches in the background (no blocking initial render)
/// - updates UI reactively via `@Published` state
@MainActor
final class BillVoteStore: ObservableObject {
    @Published private(set) var statesByBillId: [String: VoteState] = [:]

    /// User-facing error message for the most recent failed operation.
    /// Views can bind to this with `BBErrorBanner(message: $voteStore.lastError)`.
    @Published var lastError: String?

    private let cache: BillVoteCache
    private let service: any BillVotesServicing

    /// The bills whose Abstain row the cache dropped at this launch (`BillVoteCache.droppedAbstainIds`),
    /// until `recheckEarlierAbstains()` has taken them.
    private var earlierAbstainIds: [String]

    /// Latest server write per bill. Each new write waits for the previous one so a
    /// reasons update can never land before (and be overwritten by) the vote it belongs to.
    private var writeChains: [String: (token: UUID, task: Task<VoteWriteResult, Never>)] = [:]

    /// A bill with a vote write the server has not confirmed: the vote row as it was before the first
    /// such write (`baseline`, what a refused vote rolls back to, with its `votedAt` when it is a vote)
    /// and the latest vote's token.
    private struct UnconfirmedVote {
        var baseline: VoteState
        var baselineVotedAt: Date?
        var latest: UUID
    }

    /// Per bill with a vote write the server has not confirmed. A refusal rolls back only when no newer
    /// vote is waiting behind it (spec D 2.8.4, APPF-27).
    private var unconfirmedVotes: [String: UnconfirmedVote] = [:]

    /// The latest vote written per bill (its `submitVote` token): the vote a reasons update belongs to.
    private var latestVotes: [String: UUID] = [:]

    /// The votes the server refused (`submitVote` tokens whose failure rolls back), per bill. A reasons update
    /// that belongs to one is dropped, because it would send the refused vote again (APPF-27). Once the bill's
    /// queued writes have all run, only the latest vote's refusal is kept: later updates belong to that vote.
    private var refusedVotes: [String: Set<UUID>] = [:]

    /// Weak references for post-vote refresh.
    private weak var civicScoreStore: CivicScoreStore?
    private weak var civicProfileStore: CivicProfileStore?

    func connect(civicScoreStore: CivicScoreStore, civicProfileStore: CivicProfileStore) {
        self.civicScoreStore = civicScoreStore
        self.civicProfileStore = civicProfileStore
    }

    init(
        scope: String? = nil,
        cache: BillVoteCache? = nil,
        service: any BillVotesServicing = BillVotesService.Live()
    ) {
        let cache = cache ?? BillVoteCache(scope: scope)
        self.cache = cache
        self.service = service
        self.earlierAbstainIds = cache.droppedAbstainIds
        // Seed published state from persisted cache snapshot.
        self.statesByBillId = Self.normalizeStates(self.cache.snapshotStates())
    }

    /// Cheap, non-blocking lookup used by views.
    /// IMPORTANT: This method is read-only and does NOT mutate @Published state
    /// to avoid triggering SwiftUI re-render loops.
    func vote(for billId: String) -> VoteState {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .unknown }

        // First check published state (avoids cache lookup if already known).
        if let known = statesByBillId[cleaned] {
            return Self.normalizeState(known)
        }

        // Fall back to cache but do NOT update @Published here - that would
        // cause infinite re-render loops when called from SwiftUI computed properties.
        return Self.normalizeState(cache.getState(for: cleaned))
    }

    /// Batch fetch vote states for a set of billIds.
    ///
    /// - Uses cache immediately; only fetches missing/expired.
    /// - Single network call (no N+1) assuming backend supports batch endpoint.
    /// - `revalidateNotVoted` (bill detail, INT-11) also fetches a bill cached as not voted, so a vote
    ///   made on another device, or before a reinstall, unlocks Results on open. A cached vote row,
    ///   Abstain included, is not fetched again.
    /// - Returns the error message (also set as `lastError`) when the read failed, else nil: nothing to
    ///   read, read, or cancelled.
    @discardableResult
    func fetchVotes(for billIds: [String], revalidateNotVoted: Bool = false) async -> String? {
        let cleaned = Array(Set(billIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !cleaned.isEmpty else { return nil }

        #if DEBUG
        print(">>> [BillVoteStore] fetchVotes requested count=\(cleaned.count)")
        #endif

        // 1) Populate from cache and determine what we still need.
        var missing: [String] = []
        missing.reserveCapacity(cleaned.count)

        for id in cleaned {
            let cached = cache.getState(for: id)
            statesByBillId[id] = Self.normalizeState(cached)
            if Self.needsFetch(cached, revalidateNotVoted: revalidateNotVoted), unconfirmedVotes[id] == nil {
                missing.append(id)
            }
        }

        guard !missing.isEmpty else { return nil }

        #if DEBUG
        print(">>> [BillVoteStore] fetchVotes missing/expired count=\(missing.count)")
        #endif

        // 2) Fetch missing in a single request.
        do {
            let writes = voteWriteTokens(missing)
            let remote = try await service.fetchFeedback(billIds: missing)
            applyRemote(remote, to: missing, unlessWrittenSince: writes)
            return nil
        } catch {
            if APIErrorResponse.isCancellation(error) { return nil }
            lastError = Self.loadVotesFailedMessage
            #if DEBUG
            print(">>> [BillVoteStore] fetchVotes failed: \(APIErrorDebug.debugString(for: error))")
            #endif
            return Self.loadVotesFailedMessage
        }
    }

    /// Clear cached vote state for a bill so it resurfaces as unvoted.
    /// Used when a push notification arrives indicating the bill has changed.
    func clearVote(for billId: String) {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        cache.remove(billId: cleaned)
        statesByBillId.removeValue(forKey: cleaned)
        // The server cleared the vote: a refused vote still in flight rolls back to "unknown", not to it.
        if let pending = unconfirmedVotes[cleaned] {
            unconfirmedVotes[cleaned] = UnconfirmedVote(baseline: .unknown, baselineVotedAt: nil, latest: pending.latest)
        }
    }

    /// Detail-screen helper: fetch a single bill only if missing/expired, or also when cached as not
    /// voted with `revalidateNotVoted` (`fetchVotes(for:revalidateNotVoted:)`).
    @discardableResult
    func fetchVoteIfNeeded(for billId: String, reportError: Bool = true, revalidateNotVoted: Bool = false) async -> String? {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let cached = cache.getState(for: cleaned)
        statesByBillId[cleaned] = Self.normalizeState(cached)
        guard Self.needsFetch(cached, revalidateNotVoted: revalidateNotVoted), unconfirmedVotes[cleaned] == nil else { return nil }

        #if DEBUG
        print(">>> [BillVoteStore] fetchVoteIfNeeded -> fetching billId=\(cleaned)")
        #endif

        do {
            let writes = voteWriteTokens([cleaned])
            let remote = try await service.fetchFeedback(billId: cleaned)
            applyRemote([cleaned: remote], to: [cleaned], unlessWrittenSince: writes)
            return nil
        } catch {
            if APIErrorResponse.isCancellation(error) { return nil }
            let message = Self.checkVoteFailedMessage
            if reportError {
                lastError = message
            }
            #if DEBUG
            print(">>> [BillVoteStore] fetchVoteIfNeeded failed: \(APIErrorDebug.debugString(for: error))")
            #endif
            return message
        }
    }

    /// Reads the server's rows for `billIds` again, whatever the cache holds: bill detail calls it when
    /// the server answered `RESULTS_LOCKED` (INT-11), so the screen follows the rows the server holds. A
    /// bill with a vote write still being sent (`unconfirmedVotes`), or written while this read was out,
    /// is left as it is, so an optimistic vote is never overwritten. Failures stay quiet.
    func refreshVotes(for billIds: [String]) async {
        let ids = Array(Set(billIds.compactMap { BillsStore.trimmedOrNil($0) }))
            .filter { unconfirmedVotes[$0] == nil }
            .sorted()
        guard !ids.isEmpty else { return }
        do {
            let writes = voteWriteTokens(ids)
            let remote = try await service.fetchFeedback(billIds: ids)
            applyRemote(remote, to: ids, unlessWrittenSince: writes)
        } catch {
            #if DEBUG
            if !APIErrorResponse.isCancellation(error) {
                print(">>> [BillVoteStore] refreshVotes failed: \(APIErrorDebug.debugString(for: error))")
            }
            #endif
        }
    }

    /// INT-11, once on the first launch of 1.2: reads the server's rows for the Abstains the cache dropped
    /// (`BillVoteCache.droppedAbstainIds`), in one request. 1.1 stored every Updates Dismiss as an Abstain,
    /// and the server leaves those out of what 1.2 reads, so a dismissal stays not voted with Results locked
    /// while the user's own Abstain comes back. The cache already holds no row for these bills, so a read that
    /// fails (or leaves a bill out) is quiet and loses nothing: the bill is read when it is opened.
    func recheckEarlierAbstains() async {
        let ids = earlierAbstainIds
        earlierAbstainIds = []
        guard !ids.isEmpty else { return }
        await refreshVotes(for: ids)
    }

    /// A cached state that `fetchVotes` and `fetchVoteIfNeeded` read from the server: unknown, or not voted
    /// when revalidating. `cached` is the raw cache state, in which an Abstain row is `.voted(.abstain)`.
    private static func needsFetch(_ cached: VoteState, revalidateNotVoted: Bool) -> Bool {
        switch cached {
        case .unknown: return true
        case .notVoted: return revalidateNotVoted
        case .voted: return false
        }
    }

    /// The latest vote written per bill (`latestVotes`), taken before a read so a write made while the
    /// read was out is not overwritten by its older answer.
    private func voteWriteTokens(_ ids: [String]) -> [String: UUID] {
        ids.reduce(into: [:]) { tokens, id in tokens[id] = latestVotes[id] }
    }

    /// Stores the server's rows for `ids`. An id the server left out stays as it is (never assumed not
    /// voted), and so does one with a vote write still unconfirmed or made since `writes` was taken.
    private func applyRemote(_ remote: [String: BillVotesService.RemoteVoteState], to ids: [String], unlessWrittenSince writes: [String: UUID]) {
        let now = Date()
        for id in ids {
            guard let state = remote[id],
                  unconfirmedVotes[id] == nil,
                  latestVotes[id] == writes[id] else { continue }
            switch state {
            case .voted(let rv):
                cache.setVoted(billId: id, vote: rv.vote, votedAt: rv.votedAt, now: now)
                statesByBillId[id] = rv.vote.countsAsVote ? .voted(rv.vote) : .notVoted
            case .notVoted:
                cache.setNotVoted(billId: id, now: now)
                statesByBillId[id] = .notVoted
            }
        }
    }

    /// Optimistic voting write flow.
    ///
    /// - Updates UI immediately.
    /// - Updates cache immediately.
    /// - Calls server idempotently (overwrite existing vote).
    ///
    /// A failed write keeps the optimistic vote and reports it (nothing retries it), except a vote the
    /// server refused (`voteFailure(for:)`: `VOTE_DAILY_LIMIT` and the other coded refusals, sent before the
    /// server stores anything), which rolls the bill back to its vote before this one (spec D 2.8.4,
    /// APPF-27). Server codes get their own copy.
    ///
    /// Returns true once the server has stored the vote.
    @discardableResult
    func setVote(billId: String, vote: VoteType, reasons: [VoteReason] = []) async -> Bool {
        await submitVote(billId: billId, vote: vote, reasons: reasons) == .stored
    }

    /// `setVote(billId:vote:reasons:)` with the write's full result, so the bills store and bill detail
    /// can roll back a refused vote too (APPF-27).
    func submitVote(billId: String, vote: VoteType, reasons: [VoteReason] = []) async -> VoteWriteResult {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .notSaved }

        #if DEBUG
        print(">>> [BillVoteStore] setVote -> billId=\(cleaned) vote=\(vote.feedbackValue) reasons=\(reasons.count)")
        #endif

        // Remember the row this vote replaces, in case the server refuses it.
        let voteToken = UUID()
        latestVotes[cleaned] = voteToken
        if var pending = unconfirmedVotes[cleaned] {
            pending.latest = voteToken
            unconfirmedVotes[cleaned] = pending
        } else {
            unconfirmedVotes[cleaned] = UnconfirmedVote(
                baseline: cache.getState(for: cleaned),
                baselineVotedAt: cache.votedRow(for: cleaned)?.votedAt,
                latest: voteToken
            )
        }

        // Optimistic update. We don't know `votedAt` from server yet; use `now`.
        let now = Date()
        cache.setVoted(billId: cleaned, vote: vote, votedAt: now, now: now)
        statesByBillId[cleaned] = vote.countsAsVote ? .voted(vote) : .notVoted

        let reasonKeys = reasons.map(\.rawValue)
        let service = service
        return await enqueueWrite(billId: cleaned) { [weak self] in
            do {
                try await service.setFeedback(
                    billId: cleaned,
                    feedback: vote,
                    reasons: reasonKeys
                )
                self?.voteWriteFinished(billId: cleaned, token: voteToken, storedVote: vote, votedAt: now)
                // Refresh profile-derived metrics in the background after a successful vote; a read
                // already running is followed by one more, so this vote counts (UX-39 N11).
                Task { await self?.civicScoreStore?.refresh(afterSavedVote: true) }
                Task { await self?.civicProfileStore?.refresh(afterSavedVote: true) }
                return .stored
            } catch {
                guard let self else { return .notSaved }
                if APIErrorResponse.isCancellation(error) {
                    self.voteWriteFinished(billId: cleaned, token: voteToken, storedVote: nil, votedAt: nil)
                    return .notSaved
                }
                let failure = Self.voteFailure(for: error)
                var result = VoteWriteResult.notSaved
                if failure.rollsBack {
                    // Also when a newer vote decides: reasons queued for this one must not send it again.
                    self.refusedVotes[cleaned, default: []].insert(voteToken)
                    if let restored = self.rollBackRefusedVote(billId: cleaned, token: voteToken) {
                        result = .rolledBack(restored: restored)
                    }
                } else {
                    // Keep the optimistic state so the UI feels instant, but tell the user.
                    self.voteWriteFinished(billId: cleaned, token: voteToken, storedVote: nil, votedAt: nil)
                }
                self.lastError = failure.message
                #if DEBUG
                print(">>> [BillVoteStore] setVote failed: \(APIErrorDebug.debugString(for: error))")
                #endif
                return result
            }
        }
    }

    /// A vote write ended without a rollback. `storedVote` is the vote the server now holds (cast at
    /// `votedAt`), or nil when it is unknown (a failure that keeps the optimistic state). The bill's rollback
    /// record ends with its latest vote; while a newer vote waits, a stored vote becomes the row a refusal
    /// of that newer vote restores.
    private func voteWriteFinished(billId: String, token: UUID, storedVote: VoteType?, votedAt: Date?) {
        guard let pending = unconfirmedVotes[billId] else { return }
        if pending.latest == token {
            unconfirmedVotes[billId] = nil
        } else if let storedVote {
            unconfirmedVotes[billId] = UnconfirmedVote(baseline: .voted(storedVote), baselineVotedAt: votedAt, latest: pending.latest)
        }
    }

    /// The server refused the vote: put back the vote row from before it (with its own `votedAt`) and return
    /// it, unless a newer vote on the bill is still waiting, whose own result then decides (nil).
    private func rollBackRefusedVote(billId: String, token: UUID) -> VoteState? {
        guard let pending = unconfirmedVotes[billId], pending.latest == token else { return nil }
        unconfirmedVotes[billId] = nil
        switch pending.baseline {
        case .unknown:
            cache.remove(billId: billId)
            statesByBillId.removeValue(forKey: billId)
        case .notVoted:
            cache.setNotVoted(billId: billId)
            statesByBillId[billId] = .notVoted
        case .voted(let previous):
            let now = Date()
            cache.setVoted(billId: billId, vote: previous, votedAt: pending.baselineVotedAt ?? now, now: now)
            statesByBillId[billId] = Self.normalizeState(.voted(previous))
        }
        return pending.baseline
    }

    // MARK: - Failure copy (spec D 2.8.4)

    static let loadVotesFailedMessage = "Couldn't check your votes. Pull down to try again."
    static let checkVoteFailedMessage = "Couldn't check your vote on this bill."
    static let reasonsNotSavedMessage = "Your reasons could not be saved. Try again in a moment."

    /// What a failed vote write shows, and whether the vote is rolled back (APPF-27). `POST /feedback`
    /// answers every coded refusal before it stores the row (account eligibility, then App Attest, then the
    /// daily limit), so a vote refused with a code the app knows was not stored and rolls back:
    /// `VOTE_DAILY_LIMIT`, the App Attest codes (`APP_ATTEST_UNAVAILABLE` included: 503, fail closed),
    /// `APP_UPDATE_REQUIRED`, `DEVICE_ACCOUNT_LIMIT` and the account codes. A failure without a code
    /// (offline, a timeout, a status without a body) or with a code the app does not know may have been
    /// stored, so it keeps the optimistic vote. Known codes get their copy
    /// (`AuthErrorMessages.message(forBackendCode:)`); `APP_ATTEST_UNAVAILABLE` and every other failure get
    /// `voteNotSaved`.
    static func voteFailure(for error: Error) -> (message: String, rollsBack: Bool) {
        guard let code = APIErrorResponse.errorCode(from: error) else {
            return (AuthErrorMessages.voteNotSaved, false)
        }
        switch code {
        case AuthErrorMessages.BackendCode.voteDailyLimit:
            return (AuthErrorMessages.voteDailyLimit, true)
        case AppAttestServerCode.unavailable.rawValue:
            return (AuthErrorMessages.voteNotSaved, true)
        default:
            guard let copy = AuthErrorMessages.message(forBackendCode: code) else {
                return (AuthErrorMessages.voteNotSaved, false)
            }
            return (copy, true)
        }
    }

    /// What a failed reasons update shows. The vote itself was stored earlier and stays.
    static func reasonsFailureMessage(for error: Error) -> String {
        guard let code = APIErrorResponse.errorCode(from: error) else { return reasonsNotSavedMessage }
        switch code {
        case AuthErrorMessages.BackendCode.voteDailyLimit:
            return AuthErrorMessages.reasonsDailyLimit
        case AppAttestServerCode.unavailable.rawValue:
            return reasonsNotSavedMessage
        default:
            return AuthErrorMessages.message(forBackendCode: code) ?? reasonsNotSavedMessage
        }
    }

    /// Re-sends an already recorded vote with a new set of reasons (reasons picked or
    /// changed after the vote was tapped). The server stores the full row on every write,
    /// so the vote is sent again alongside the reasons.
    ///
    /// The update belongs to the bill's latest vote (`submitVote`) and waits for its write. When the server
    /// refuses that vote, the update is dropped without being sent (false, and `lastError` keeps the vote's
    /// text): it would send the vote the app rolled back, which the server could then store (APPF-27).
    ///
    /// Returns true once the server has stored the update.
    @discardableResult
    func updateReasons(billId: String, vote: VoteType, reasons: [VoteReason]) async -> Bool {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        #if DEBUG
        print(">>> [BillVoteStore] updateReasons -> billId=\(cleaned) vote=\(vote.feedbackValue) reasons=\(reasons.count)")
        #endif

        let reasonKeys = reasons.map(\.rawValue)
        let service = service
        let voteToken = latestVotes[cleaned]
        let result = await enqueueWrite(billId: cleaned) { [weak self] () -> VoteWriteResult in
            if let voteToken, self?.refusedVotes[cleaned]?.contains(voteToken) == true {
                #if DEBUG
                print(">>> [BillVoteStore] updateReasons dropped: the server refused the vote billId=\(cleaned)")
                #endif
                return .notSaved
            }
            do {
                try await service.setFeedback(
                    billId: cleaned,
                    feedback: vote,
                    reasons: reasonKeys
                )
                return .stored
            } catch {
                if APIErrorResponse.isCancellation(error) { return .notSaved }
                self?.lastError = Self.reasonsFailureMessage(for: error)
                #if DEBUG
                print(">>> [BillVoteStore] updateReasons failed: \(APIErrorDebug.debugString(for: error))")
                #endif
                return .notSaved
            }
        }
        return result == .stored
    }

    /// Runs `operation` after any earlier write for the same bill has finished.
    /// The write runs in its own task so leaving a screen does not cancel it.
    private func enqueueWrite(
        billId: String,
        _ operation: @escaping @MainActor () async -> VoteWriteResult
    ) async -> VoteWriteResult {
        let previous = writeChains[billId]?.task
        let token = UUID()
        let task = Task { @MainActor in
            _ = await previous?.value
            return await operation()
        }
        writeChains[billId] = (token, task)

        let result = await task.value
        if writeChains[billId]?.token == token {
            writeChains[billId] = nil
            // Every write queued so far has run; an update queued from now on belongs to the latest vote.
            if let latest = latestVotes[billId], refusedVotes[billId]?.contains(latest) == true {
                refusedVotes[billId] = [latest]
            } else {
                refusedVotes[billId] = nil
            }
        }
        return result
    }

    // MARK: - Companion groups (APPF-23)

    /// The vote row the user holds on `billId`, Abstain included, or nil when none is known.
    /// `vote(for:)` reports an Abstain as `.notVoted`; the vote matrix needs to know the row exists,
    /// because a new vote on a group goes to the member that already holds one.
    func heldVote(for billId: String) -> VoteType? {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if case .voted(let vote)? = statesByBillId[cleaned] { return vote }
        // The published state reports an Abstain as not voted; the cache keeps the row itself.
        if case .voted(let vote) = cache.getState(for: cleaned) { return vote }
        return nil
    }

    /// When the row `heldVote(for:)` finds was cast: the server's `votedAt`, or the time of a vote
    /// made on this device. Nil when no row is cached. Bill detail uses it to tell an Abstain made
    /// after a bill's update from one made before it.
    func heldVoteDate(for billId: String) -> Date? {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cache.votedRow(for: cleaned)?.votedAt
    }

    /// The group's vote under the vote matrix, from this store's rows on the member guids.
    /// `BillsStore.companionVote(forBillID:)` also reads the cached bills and legacy text-version guids;
    /// screens use that one.
    func companionVote(for group: BillCompanionGroup) -> CompanionVoteResolution {
        CompanionGroupIndex.voteResolution(for: group) { member in
            heldVote(for: member).map { CompanionVoteRow(memberGuid: member, guid: member, vote: $0) }
        }
    }

    /// True when any member of `group` has a counted (Yea or Nay) vote in this store.
    func isAnyMemberVoted(_ group: BillCompanionGroup) -> Bool {
        group.memberGuids.contains { vote(for: $0).countsAsVote }
    }

    /// Fetches the vote state of every member of `group` (the detail screen), in one request.
    func fetchVotes(for group: BillCompanionGroup) async {
        await fetchVotes(for: group.memberGuids)
    }

    private static func normalizeStates(_ states: [String: VoteState]) -> [String: VoteState] {
        states.mapValues { normalizeState($0) }
    }

    private static func normalizeState(_ state: VoteState) -> VoteState {
        guard case .voted(let voteType) = state else { return state }
        return voteType.countsAsVote ? state : .notVoted
    }
}
