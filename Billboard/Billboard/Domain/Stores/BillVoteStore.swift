import Foundation
import Combine
import SwiftUI

/// What one vote write ended with (`BillVoteStore.submitVote`).
nonisolated enum VoteWriteResult: Equatable, Sendable {
    /// The server stored the vote.
    case stored
    /// The write failed and its outcome is unknown (offline, a timeout, a server error without a code the app
    /// knows): the vote stays as sent. Bill detail keeps it on screen and says it is not saved yet, with Try
    /// again (UX-49).
    case unconfirmed
    /// The vote was not confirmed and stays as sent, with nothing to say: the write was cancelled, or the
    /// server refused it while a newer vote on the bill was waiting (that vote's result decides).
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

    /// User-facing error message for the most recent failed operation. Every one is about some bills
    /// (`lastErrorBillIds`): bill detail shows it with `lastError(about:)`.
    @Published var lastError: String?

    /// The bills (guids) `lastError` is about, so bill detail shows it only on their page, never on another
    /// bill's, also when it arrives after its page was left (UX-49).
    private var lastErrorBillIds: Set<String> = []

    private let cache: BillVoteCache
    private let service: any BillVotesServicing

    /// The bills whose Abstain row the cache dropped at this launch (`BillVoteCache.droppedAbstainIds`),
    /// until `recheckEarlierAbstains()` has taken them.
    private var earlierAbstainIds: [String]

    /// Latest server write per bill. Each new write waits for the previous one so a
    /// reasons update can never land before (and be overwritten by) the vote it belongs to.
    private var writeChains: [String: (token: UUID, task: Task<VoteWriteResult, Never>)] = [:]

    /// A bill with a vote write the server has not confirmed: the vote row as it was before the first
    /// such write (`baseline`, what a refused vote rolls back to, with its `votedAt` when it is a vote, and
    /// `baselineUnsaved`, its mark, when that row was a vote not saved yet) and the latest vote's token.
    private struct UnconfirmedVote {
        var baseline: VoteState
        var baselineVotedAt: Date?
        var baselineUnsaved: BillVoteCache.UnsavedVote?
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

    /// The votes not saved yet, by the guid each was sent to: the bill's latest vote write ended `.unconfirmed`, so the
    /// server may hold the vote or not, and bill detail shows it with "Not saved yet." and Try again (UX-49), whenever
    /// the page opens (APPF-30 step 2). Cleared by the next vote on the bill (a refusal of that vote rolls back to this
    /// one, which is then still not saved), once the server confirms the vote another way (`onUnsavedVoteConfirmed`),
    /// or when a read finds a later vote from another device (`onUnsavedVoteReplaced`). An "updated" push keeps it: the
    /// app drops its copy of the vote, but the server keeps the row, so the next read of the bill can still confirm it.
    ///
    /// The record is the cache's (`BillVoteCache.UnsavedVote`), kept per account across a relaunch and cleared at
    /// sign-out. It also marks a vote while its write is out, so one the app ended mid-write is not saved yet after a
    /// relaunch; this map leaves those out until the write ends.
    @Published private(set) var unsavedVotes: [String: VoteType] = [:]

    /// Runs once when the server confirms a vote in `unsavedVotes` some other way than its own write: a reasons
    /// update that sends the same vote was stored, or a read of the bill's row returned that vote (UX-49b). The
    /// vote's own write never ended `.stored`, so what follows a stored vote runs now: the bills store writes the
    /// bill's `type=bill` preference row (`BillsStore.connect(voteStore:)`), and this store refreshes the civic
    /// score and profile. It lives here, not on the bill page, because a reasons update sent as the page is left
    /// can end after the page is gone.
    var onUnsavedVoteConfirmed: (@MainActor (_ guid: String, _ vote: VoteType) -> Void)?

    /// Runs when a read of a bill's row finds a vote cast after the vote not saved yet was sent (from another device),
    /// which replaces it here (APPF-30 step 2, project decision 2026-11-23): the bills store's copy of the bill follows
    /// the new row, so the two stores do not split.
    var onUnsavedVoteReplaced: (@MainActor (_ guid: String, _ vote: VoteType) -> Void)?

    /// The read of the votes not saved yet that is running (`startUnsavedVoteRecheck()`), which a second caller joins.
    private var unsavedRecheck: Task<Set<String>?, Never>?

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
        // No write is out yet: every vote the cache marks is not saved yet, also one whose write the app ended.
        self.unsavedVotes = cache.unsavedVotes.mapValues(\.vote)
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

    /// The vote not saved yet on `billId` (`unsavedVotes`): its latest write failed with its outcome unknown, on this
    /// launch or an earlier one, and no write is out for it now. Nil otherwise.
    func unsavedVote(for billId: String) -> VoteType? {
        BillsStore.trimmedOrNil(billId).flatMap { unsavedVotes[$0] }
    }

    /// The vote write out on the first of `billIds` that has one, which ends with its result, or nil when none is out.
    /// Bill detail follows it when this store sends the page's vote not saved yet on its own (APPF-30 step 2), which
    /// hides the vote's mark until the result.
    func voteWriteOut(onAnyOf billIds: [String]) -> Task<VoteWriteResult, Never>? {
        for billId in billIds.compactMap({ BillsStore.trimmedOrNil($0) }) where unconfirmedVotes[billId] != nil {
            if let write = writeChains[billId]?.task { return write }
        }
        return nil
    }

    /// Batch fetch vote states for a set of billIds.
    ///
    /// - Uses cache immediately; only fetches missing/expired, and a vote not saved yet (APPF-30 step 2).
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
            if Self.needsFetch(cached, revalidateNotVoted: revalidateNotVoted) || unsavedVotes[id] != nil, unconfirmedVotes[id] == nil {
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
            report(Self.loadVotesFailedMessage, about: missing)
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
        // Only the app's copy goes: the server keeps the vote row, so a vote not saved yet stays in `unsavedVotes`, and
        // the next read of the bill (its cache is "unknown" now) confirms it when the server holds it (UX-49b).
        // A refused vote still in flight rolls back to "unknown", not to the dropped copy, so a read decides; a vote
        // not saved yet that it replaced comes back with it, still not saved.
        if let pending = unconfirmedVotes[cleaned] {
            unconfirmedVotes[cleaned] = UnconfirmedVote(
                baseline: .unknown,
                baselineVotedAt: nil,
                baselineUnsaved: pending.baselineUnsaved,
                latest: pending.latest
            )
        }
    }

    /// Detail-screen helper: fetch a single bill only if missing/expired, or also when cached as not
    /// voted with `revalidateNotVoted` (`fetchVotes(for:revalidateNotVoted:)`), or holding a vote not saved yet.
    @discardableResult
    func fetchVoteIfNeeded(for billId: String, reportError: Bool = true, revalidateNotVoted: Bool = false) async -> String? {
        let cleaned = billId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let cached = cache.getState(for: cleaned)
        statesByBillId[cleaned] = Self.normalizeState(cached)
        guard Self.needsFetch(cached, revalidateNotVoted: revalidateNotVoted) || unsavedVotes[cleaned] != nil,
              unconfirmedVotes[cleaned] == nil else { return nil }

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
                report(message, about: [cleaned])
            }
            #if DEBUG
            print(">>> [BillVoteStore] fetchVoteIfNeeded failed: \(APIErrorDebug.debugString(for: error))")
            #endif
            return message
        }
    }

    /// Reads the server's rows for `billIds` again, whatever the cache holds: bill detail calls it when
    /// the server answered `RESULTS_LOCKED` (INT-11), so the screen follows the rows the server holds, and when
    /// Results opened for a vote it shows as not saved yet (UX-49). A bill with a vote write still being sent
    /// (`unconfirmedVotes`), or written while this read was out, is left as it is, so an optimistic vote is
    /// never overwritten. Failures stay quiet.
    ///
    /// Returns the rows read and stored, by bill (an Abstain row as `.voted(.abstain)`): empty when the read
    /// failed, and without a bill the server left out or that was left as it is.
    @discardableResult
    func refreshVotes(for billIds: [String]) async -> [String: VoteState] {
        await readRows(billIds) ?? [:]
    }

    /// `refreshVotes(for:)`, which returns nil when the read failed.
    private func readRows(_ billIds: [String]) async -> [String: VoteState]? {
        let ids = Array(Set(billIds.compactMap { BillsStore.trimmedOrNil($0) }))
            .filter { unconfirmedVotes[$0] == nil }
            .sorted()
        guard !ids.isEmpty else { return [:] }
        do {
            let writes = voteWriteTokens(ids)
            let remote = try await service.fetchFeedback(billIds: ids)
            return applyRemote(remote, to: ids, unlessWrittenSince: writes).stored
        } catch {
            #if DEBUG
            if !APIErrorResponse.isCancellation(error) {
                print(">>> [BillVoteStore] refreshVotes failed: \(APIErrorDebug.debugString(for: error))")
            }
            #endif
            return nil
        }
    }

    /// APPF-30 step 2, at launch and when the app comes back: reads the rows of the votes not saved yet
    /// (`unsavedVotes`) again, in one request. A row with the same vote confirms it, a vote cast later on another
    /// device replaces it, and the vote it replaced, or no row, leaves it not saved (`applyRemote`). Failures stay
    /// quiet. A read already running is joined, not repeated. Returns false when the read failed (true with nothing to
    /// read).
    @discardableResult
    func recheckUnsavedVotes() async -> Bool {
        await startUnsavedVoteRecheck().value != nil
    }

    /// The read of `recheckUnsavedVotes()`: started now, or the one already running, which the caller joins. It ends
    /// with the bills whose rows it read and judged (`applyRemote`), or nil when it failed. The bills store sends on
    /// its own only votes in that set: a vote whose write failed after a joined read began was not in that read, and
    /// waits for the next one.
    ///
    /// While the request is out the read holds the service, not this store, so a store that sign-out ended is not
    /// kept alive by it and nothing is written for that account when the answer comes.
    func startUnsavedVoteRecheck() -> Task<Set<String>?, Never> {
        if let running = unsavedRecheck { return running }
        let ids = unsavedVotes.keys.sorted()
        guard !ids.isEmpty else { return Task { Set<String>() } }
        let writes = voteWriteTokens(ids)
        let service = service
        let read = Task { [weak self] () -> Set<String>? in
            var remote: [String: BillVotesService.RemoteVoteState]?
            do {
                remote = try await service.fetchFeedback(billIds: ids)
            } catch {
                #if DEBUG
                if !APIErrorResponse.isCancellation(error) {
                    print(">>> [BillVoteStore] recheckUnsavedVotes failed: \(APIErrorDebug.debugString(for: error))")
                }
                #endif
            }
            guard let self else { return nil }
            self.unsavedRecheck = nil
            guard let remote else { return nil }
            return self.applyRemote(remote, to: ids, unlessWrittenSince: writes).checked
        }
        unsavedRecheck = read
        return read
    }

    /// The votes not saved yet that have not had their one automatic resend (project decision 2026-11-23), with the
    /// reasons they were sent with, by guid.
    func votesAwaitingAutomaticResend() -> [(guid: String, vote: VoteType, reasons: [VoteReason])] {
        unsavedVotes.keys.sorted().compactMap { guid in
            guard let unsaved = cache.unsavedVote(for: guid), !unsaved.autoResent else { return nil }
            return (guid, unsaved.vote, unsaved.reasons.compactMap(VoteReason.init(rawValue:)))
        }
    }

    /// Uses up the one automatic resend of the vote not saved yet on `billId`, before it is sent: it is not sent on
    /// its own again, also after a relaunch, whatever that send ends with. A new vote on the bill gets its own.
    func spendAutomaticResend(for billId: String) {
        guard var unsaved = cache.unsavedVote(for: billId), !unsaved.autoResent else { return }
        unsaved.autoResent = true
        cache.setUnsavedVote(unsaved, for: billId)
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
    /// voted), and so does one with a vote write still unconfirmed or made since `writes` was taken. Returns
    /// the rows it stored (an Abstain row as `.voted(.abstain)`), and the ids whose answer it judged (`checked`): every
    /// id but those left as they are.
    ///
    /// A vote not saved yet (APPF-30 step 2, project decisions D3 and D4): a row with the same vote confirms it
    /// (`confirmUnsavedVote`). A row with the vote it replaced (`UnsavedVote.replacedVotes`), or no vote, leaves the
    /// vote shown and not saved, its row as it is, so the stores never split; unless a push dropped that row, when the
    /// server's row is stored and the mark goes, as the vote did not reach the server. Another vote cast after it was
    /// sent is a later choice (another device) and replaces it (`onUnsavedVoteReplaced`); one cast before it is treated
    /// as the vote replaced.
    @discardableResult
    private func applyRemote(
        _ remote: [String: BillVotesService.RemoteVoteState],
        to ids: [String],
        unlessWrittenSince writes: [String: UUID]
    ) -> (stored: [String: VoteState], checked: Set<String>) {
        let now = Date()
        var stored: [String: VoteState] = [:]
        var checked: Set<String> = []
        var replaced: [(guid: String, vote: VoteType)] = []
        for id in ids {
            guard let state = remote[id],
                  unconfirmedVotes[id] == nil,
                  latestVotes[id] == writes[id] else { continue }
            checked.insert(id)
            if let unsaved = cache.unsavedVote(for: id) {
                switch Self.readOutcome(state, for: unsaved, holdsItsRow: cache.votedRow(for: id)?.vote == unsaved.vote) {
                case .confirms:
                    break
                case .keeps:
                    continue
                case .replaces(let vote):
                    cache.setUnsavedVote(nil, for: id)
                    replaced.append((id, vote))
                case .drops:
                    cache.setUnsavedVote(nil, for: id)
                }
            }
            switch state {
            case .voted(let rv):
                cache.setVoted(billId: id, vote: rv.vote, votedAt: rv.votedAt, now: now)
                statesByBillId[id] = rv.vote.countsAsVote ? .voted(rv.vote) : .notVoted
                stored[id] = .voted(rv.vote)
                confirmUnsavedVote(billId: id, vote: rv.vote)
            case .notVoted:
                cache.setNotVoted(billId: id, now: now)
                statesByBillId[id] = .notVoted
                stored[id] = .notVoted
            }
        }
        publishUnsavedVotes()
        for (guid, vote) in replaced {
            onUnsavedVoteReplaced?(guid, vote)
        }
        return (stored, checked)
    }

    /// What a read of the server's row does to a vote not saved yet (`applyRemote`).
    private enum UnsavedVoteReadOutcome: Equatable {
        /// The server holds the vote: it is saved.
        case confirms
        /// The server holds a vote cast after this one was sent, which replaces it.
        case replaces(VoteType)
        /// The vote stays shown and not saved.
        case keeps
        /// The app's copy of the vote is gone (a push): the server's row is stored and the mark goes.
        case drops
    }

    /// The vote a change replaced is told by its vote (`replacedVotes`), not by the clocks: `row.votedAt` is the server's
    /// time and `sentAt` the phone's, so a phone clock that is behind would make it look later and undo the change. Only
    /// a vote this device did not hold is compared by time. Its limit: with a phone clock off by more than the time
    /// between the two votes, such a vote is taken for an earlier one (clock ahead: kept, so the one automatic resend
    /// can send this vote over it) or for a later one (clock behind: it replaces this one). Both need two devices to
    /// cast different votes on the bill close together. Another device that casts the replaced vote again after this
    /// send is taken for the replaced vote.
    private static func readOutcome(
        _ state: BillVotesService.RemoteVoteState,
        for unsaved: BillVoteCache.UnsavedVote,
        holdsItsRow: Bool
    ) -> UnsavedVoteReadOutcome {
        if case .voted(let row) = state {
            if row.vote == unsaved.vote { return .confirms }
            if !unsaved.replacedVotes.contains(row.vote), row.votedAt > unsaved.sentAt { return .replaces(row.vote) }
        }
        return holdsItsRow ? .keeps : .drops
    }

    /// Publishes the votes the cache marks as not saved yet, but for those with a write out (`unsavedVotes`).
    private func publishUnsavedVotes() {
        let shown = cache.unsavedVotes
            .filter { unconfirmedVotes[$0.key] == nil }
            .mapValues(\.vote)
        if shown != unsavedVotes {
            unsavedVotes = shown
        }
    }

    /// Optimistic voting write flow.
    ///
    /// - Updates UI immediately.
    /// - Updates cache immediately.
    /// - Calls server idempotently (overwrite existing vote).
    ///
    /// A failed write keeps the optimistic vote and ends `.unconfirmed` (bill detail offers Try again, UX-49; the vote
    /// stays in `unsavedVotes` until the server confirms it, UX-49b, and the bills store sends it once more when the
    /// phone is back online, APPF-30 step 2), except a vote the server refused (`voteFailure(for:)`: `VOTE_DAILY_LIMIT`
    /// and the other coded refusals, sent before the server stores anything), which rolls the bill back to its vote
    /// before this one (spec D 2.8.4, APPF-27) and sets `lastError`. Server codes get their own copy.
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

        // Remember the row this vote replaces, in case the server refuses it: a vote not saved yet too, which this
        // write's own result now decides.
        let voteToken = UUID()
        latestVotes[cleaned] = voteToken
        let earlierMark = cache.unsavedVote(for: cleaned)
        if var pending = unconfirmedVotes[cleaned] {
            pending.latest = voteToken
            unconfirmedVotes[cleaned] = pending
        } else {
            unconfirmedVotes[cleaned] = UnconfirmedVote(
                baseline: cache.getState(for: cleaned),
                baselineVotedAt: cache.votedRow(for: cleaned)?.votedAt,
                baselineUnsaved: earlierMark,
                latest: voteToken
            )
        }

        // Optimistic update. We don't know `votedAt` from server yet; use `now`.
        let now = Date()
        let reasonKeys = reasons.map(\.rawValue)
        // Not saved until the server says so (APPF-30 step 2): marked while the write is out too, so a vote whose write
        // the app ended (quit mid-write) is not saved yet at the next launch. The same vote sent again keeps a spent
        // automatic resend spent.
        cache.setUnsavedVote(
            BillVoteCache.UnsavedVote(
                vote: vote,
                sentAt: now,
                reasons: reasonKeys,
                autoResent: earlierMark?.vote == vote && earlierMark?.autoResent == true,
                replacedVotes: Self.votesReplaced(by: vote, row: cache.votedRow(for: cleaned)?.vote, earlierMark: earlierMark)
            ),
            for: cleaned
        )
        cache.setVoted(billId: cleaned, vote: vote, votedAt: now, now: now)
        statesByBillId[cleaned] = vote.countsAsVote ? .voted(vote) : .notVoted
        publishUnsavedVotes()

        let service = service
        return await enqueueWrite(billId: cleaned) { [weak self] in
            do {
                try await service.setFeedback(
                    billId: cleaned,
                    feedback: vote,
                    reasons: reasonKeys
                )
                self?.voteWriteFinished(billId: cleaned, token: voteToken, end: .stored(vote, votedAt: now))
                self?.refreshCivicStatsAfterSavedVote()
                return .stored
            } catch {
                guard let self else { return .notSaved }
                if APIErrorResponse.isCancellation(error) {
                    self.voteWriteFinished(billId: cleaned, token: voteToken, end: .cancelled)
                    return .notSaved
                }
                #if DEBUG
                print(">>> [BillVoteStore] setVote failed: \(APIErrorDebug.debugString(for: error))")
                #endif
                let failure = Self.voteFailure(for: error)
                guard failure.rollsBack else {
                    // Keep the optimistic state: bill detail says the vote is not saved yet, with Try again
                    // (UX-49). No `lastError`: a page that was left says nothing, so it never shows on another bill.
                    // The latest vote stays marked as not saved yet, for the server to confirm another way (UX-49b);
                    // an earlier one's result says nothing, as the newer vote's own result decides.
                    self.voteWriteFinished(billId: cleaned, token: voteToken, end: .unconfirmed)
                    return .unconfirmed
                }
                // Also when a newer vote decides: reasons queued for this one must not send it again.
                self.refusedVotes[cleaned, default: []].insert(voteToken)
                var result = VoteWriteResult.notSaved
                if let restored = self.rollBackRefusedVote(billId: cleaned, token: voteToken) {
                    result = .rolledBack(restored: restored)
                }
                self.report(failure.message, about: [cleaned])
                return result
            }
        }
    }

    /// The votes `vote` replaces on its bill (`UnsavedVote.replacedVotes`): the bill's row (`row`) and, when that row was
    /// itself not saved yet (`earlierMark`), what that vote replaced, back to the last row known as saved. Each once,
    /// without `vote`.
    private static func votesReplaced(by vote: VoteType, row: VoteType?, earlierMark: BillVoteCache.UnsavedVote?) -> [VoteType] {
        let held = (earlierMark?.replacedVotes ?? []) + [earlierMark?.vote, row].compactMap { $0 }
        var seen: Set<VoteType> = [vote]
        return held.filter { seen.insert($0).inserted }
    }

    /// How a vote write ended without a rollback (`voteWriteFinished`).
    private enum WriteEnd {
        /// The server holds the vote, cast at `votedAt`.
        case stored(VoteType, votedAt: Date)
        /// The outcome is unknown, and the optimistic state stays.
        case unconfirmed
        /// The write was cancelled: the vote stays as sent, with nothing to say.
        case cancelled
    }

    /// A vote write ended without a rollback. The bill's rollback record ends with its latest vote, whose mark stays
    /// only while its outcome is unknown (APPF-30 step 2); while a newer vote waits, a stored vote becomes the row a
    /// refusal of that newer vote restores.
    private func voteWriteFinished(billId: String, token: UUID, end: WriteEnd) {
        guard let pending = unconfirmedVotes[billId] else { return }
        if pending.latest == token {
            unconfirmedVotes[billId] = nil
            if case .unconfirmed = end {} else {
                cache.setUnsavedVote(nil, for: billId)
            }
            publishUnsavedVotes()
        } else if case .stored(let storedVote, let votedAt) = end {
            unconfirmedVotes[billId] = UnconfirmedVote(baseline: .voted(storedVote), baselineVotedAt: votedAt, latest: pending.latest)
        }
    }

    /// The server refused the vote: put back the vote row from before it (with its own `votedAt`, and still not saved
    /// yet when it was) and return it, unless a newer vote on the bill is still waiting, whose own result then
    /// decides (nil).
    private func rollBackRefusedVote(billId: String, token: UUID) -> VoteState? {
        guard let pending = unconfirmedVotes[billId], pending.latest == token else { return nil }
        unconfirmedVotes[billId] = nil
        cache.setUnsavedVote(pending.baselineUnsaved, for: billId)
        defer { publishUnsavedVotes() }
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

    /// The server holds `vote` on `billId`. When that is the vote not saved yet (`unsavedVotes`), it is saved now:
    /// it leaves `unsavedVotes`, and `onUnsavedVoteConfirmed` and the civic refresh run, once (UX-49b). The same holds
    /// while a newer vote waits behind it (a reasons update for it, queued before the newer vote, was stored): it then
    /// leaves the newer vote's rollback record (`baselineUnsaved`), so a refusal of the newer vote restores it as
    /// saved. Another vote leaves it not saved yet.
    private func confirmUnsavedVote(billId: String, vote: VoteType) {
        if unconfirmedVotes[billId] == nil, cache.unsavedVote(for: billId)?.vote == vote {
            cache.setUnsavedVote(nil, for: billId)
            publishUnsavedVotes()
        } else if unconfirmedVotes[billId]?.baselineUnsaved?.vote == vote {
            unconfirmedVotes[billId]?.baselineUnsaved = nil
        } else {
            return
        }
        onUnsavedVoteConfirmed?(billId, vote)
        refreshCivicStatsAfterSavedVote()
    }

    /// Refreshes profile-derived metrics in the background after a vote is saved; a read already running is
    /// followed by one more, so this vote counts (UX-39 N11).
    private func refreshCivicStatsAfterSavedVote() {
        Task { [weak self] in await self?.civicScoreStore?.refresh(afterSavedVote: true) }
        Task { [weak self] in await self?.civicProfileStore?.refresh(afterSavedVote: true) }
    }

    // MARK: - Errors (UX-49)

    /// `lastError` when it is about one of `billIds` (a bill page's guids), else nil.
    func lastError(about billIds: [String]) -> String? {
        guard let lastError, billIds.contains(where: lastErrorBillIds.contains) else { return nil }
        return lastError
    }

    /// Sets `lastError` to `message`, about `billIds`.
    private func report(_ message: String, about billIds: [String]) {
        lastErrorBillIds = Set(billIds)
        lastError = message
    }

    /// Re-sends an already recorded vote with a new set of reasons (reasons picked or
    /// changed after the vote was tapped). The server stores the full row on every write,
    /// so the vote is sent again alongside the reasons.
    ///
    /// The update belongs to the bill's latest vote (`submitVote`) and waits for its write. When the server
    /// refuses that vote, the update is dropped without being sent (false, and `lastError` keeps the vote's
    /// text): it would send the vote the app rolled back, which the server could then store (APPF-27). A stored
    /// update of a vote not saved yet confirms that vote (`onUnsavedVoteConfirmed`, UX-49b).
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
        // A vote not saved yet is sent again with the reasons picked last (APPF-30 step 2).
        if var unsaved = cache.unsavedVote(for: cleaned), unsaved.vote == vote {
            unsaved.reasons = reasonKeys
            cache.setUnsavedVote(unsaved, for: cleaned)
        }
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
                // The update sends the whole row: a vote not saved yet is saved now (UX-49b).
                self?.confirmUnsavedVote(billId: cleaned, vote: vote)
                return .stored
            } catch {
                if APIErrorResponse.isCancellation(error) { return .notSaved }
                self?.report(Self.reasonsFailureMessage(for: error), about: [cleaned])
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
