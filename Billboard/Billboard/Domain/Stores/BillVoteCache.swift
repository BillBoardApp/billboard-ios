import Foundation

/// A bounded, predictable cache for bill vote states.
///
/// - TTL: 90 days
/// - Bounded: maxEntries (oldest cachedAt evicted)
/// - Persistence: optional (UserDefaults)
///
/// INT-11: the cache 1.1 left holds every Updates Dismiss and Dismiss All of the last 90 days as an Abstain,
/// and 1.2 shows a held Abstain as "You abstained" with Results open. The first time 1.2 opens a persisted
/// cache it drops those rows (`droppedAbstainIds`) and the vote store reads them from the server again, which
/// holds the user's own Abstains and leaves the dismissals out.
///
/// APPF-30 step 2: beside the rows, a persisted map of the votes not saved yet (`UnsavedVote`, under
/// `<persistenceKey>.unconfirmed`), so a vote whose write failed with its outcome unknown is still known as not saved
/// after the page is left or the app relaunches. The rows' format is unchanged, so a 1.2 cache loads as it is.
final class BillVoteCache {
    struct Config {
        static let legacyPersistenceKey = "BillVoteCache.v1"
        var ttl: TimeInterval = 90 * 24 * 60 * 60
        var maxEntries: Int = 500
        var persistenceKey: String? = legacyPersistenceKey
    }

    enum Entry: Codable, Hashable {
        case voted(BillVote)
        case notVoted(cachedAt: Date)

        var cachedAt: Date {
            switch self {
            case .voted(let v): return v.cachedAt
            case .notVoted(let dt): return dt
            }
        }
    }

    /// A vote sent from this device that the server has not confirmed (APPF-30 step 2): its write is still out, or
    /// failed with its outcome unknown (offline, a timeout, a server error without a code). `BillVoteStore` keeps the
    /// map; the row itself stays an ordinary `.voted` entry.
    nonisolated struct UnsavedVote: Codable, Equatable, Sendable {
        var vote: VoteType
        /// When this device sent the vote, by the phone's clock: the optimistic row's `votedAt`. A server row with
        /// another vote, cast after it, is a later vote (from another device).
        var sentAt: Date
        /// The reasons sent with the vote (their raw values), sent again with it.
        var reasons: [String]
        /// The one automatic resend once the phone is back online has been used (project decision 2026-11-23).
        var autoResent: Bool
        /// The votes this device held on the bill before this one, back to the last row it knew as saved: the vote
        /// this one replaced, and any vote not saved yet in between. A server row with one of them is the vote a change
        /// replaced, which the change did not reach (project decision D4): it is told by its vote, so a phone clock
        /// that is behind the server's cannot make it look like a later vote.
        var replacedVotes: [VoteType] = []
    }

    private let config: Config
    private let defaults: UserDefaults
    private var entries: [String: Entry] = [:]

    /// The votes not saved yet, by the guid each was sent to (`UnsavedVote`). Persisted with the rows; cleared with
    /// them at sign-out (`clearPersistence`). A mark goes when its row is pruned, or after the rows' TTL.
    private(set) var unsavedVotes: [String: UnsavedVote] = [:]

    /// The bills whose Abstain row this cache dropped when it was created: the rows an earlier build left
    /// (INT-11, see the type's comment). Empty from the second launch of 1.2 on, and for a cache that is not
    /// persisted. `BillVoteStore.recheckEarlierAbstains()` reads them from the server.
    private(set) var droppedAbstainIds: [String] = []

    /// How many times each saved cache was cleared in this run of the app (`clearPersistence`, at sign-out and account
    /// deletion), and how many times every account's was (`clearAllUnsavedVotes`, a sign-out that does not know the
    /// account); and both counts for this cache when it was made.
    private static var clearCounts: [String: Int] = [:]
    private static var clearAllCount = 0
    private let clearCountAtInit: Int
    private let clearAllCountAtInit: Int

    /// False once this cache's account has signed out or been deleted since the cache was made: the cache then saves
    /// nothing more, so a read or a write that ends after sign-out leaves none of that account's rows or votes not saved
    /// yet on the device (APPF-30 step 2). The next sign-in makes a new cache, which saves as usual.
    var isAccountStillHere: Bool {
        Self.clearAllCount == clearAllCountAtInit && Self.clearCount(of: config.persistenceKey) == clearCountAtInit
    }

    private static func clearCount(of persistenceKey: String?) -> Int {
        persistenceKey.map { clearCounts[$0, default: 0] } ?? 0
    }

    init(scope: String? = nil, config: Config = .init(), defaults: UserDefaults = .standard) {
        var resolvedConfig = config
        if config.persistenceKey == Config.legacyPersistenceKey {
            resolvedConfig.persistenceKey = Self.persistenceKey(scope: scope)
        }

        self.config = resolvedConfig
        self.defaults = defaults
        self.clearCountAtInit = Self.clearCount(of: resolvedConfig.persistenceKey)
        self.clearAllCountAtInit = Self.clearAllCount
        if let key = resolvedConfig.persistenceKey {
            #if DEBUG
            // Keep unit tests isolated from the persisted local state of the app they run in. A defaults
            // suite a test made itself is isolated already, and may hold the cache of an earlier build.
            let isRunningTests = NSClassFromString("XCTest") != nil
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if isRunningTests && defaults === UserDefaults.standard {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: Self.earlierAbstainsDroppedKey(for: key))
                defaults.removeObject(forKey: Self.unsavedVotesKey(for: key))
                Self.clearLegacyPersistence(defaults: defaults)
            }
            #endif
            if key != Config.legacyPersistenceKey {
                Self.clearLegacyPersistence(defaults: defaults)
            }
            self.entries = Self.load(from: key, defaults: defaults)
            self.unsavedVotes = Self.loadUnsavedVotes(from: Self.unsavedVotesKey(for: key), defaults: defaults)
            prune(now: Date())
            droppedAbstainIds = dropEarlierAbstains(key: key)
        }
    }

    func getState(for billId: String, now: Date = Date()) -> VoteState {
        guard let entry = entries[billId] else { return .unknown }
        guard !isExpired(entry, now: now) else { return .unknown }

        switch entry {
        case .voted(let v):
            return .voted(v.vote)
        case .notVoted:
            return .notVoted
        }
    }

    /// The vote row cached for `billId` (with its `votedAt`), or nil when none is cached or it expired.
    func votedRow(for billId: String, now: Date = Date()) -> BillVote? {
        guard let entry = entries[billId], !isExpired(entry, now: now) else { return nil }
        if case .voted(let row) = entry { return row }
        return nil
    }

    func setVoted(billId: String, vote: VoteType, votedAt: Date, now: Date = Date()) {
        entries[billId] = .voted(BillVote(vote: vote, votedAt: votedAt, cachedAt: now))
        prune(now: now)
        persistIfNeeded()
    }

    func setNotVoted(billId: String, now: Date = Date()) {
        entries[billId] = .notVoted(cachedAt: now)
        prune(now: now)
        persistIfNeeded()
    }

    /// Removes the row only. A vote not saved yet keeps its mark: an "updated" push drops the app's copy of the vote,
    /// but the server keeps its row, so a later read can still confirm the vote (UX-49b).
    func remove(billId: String) {
        entries.removeValue(forKey: billId)
        persistIfNeeded()
    }

    /// The vote not saved yet on `billId`, or nil.
    func unsavedVote(for billId: String) -> UnsavedVote? {
        unsavedVotes[billId]
    }

    /// Marks the vote on `billId` as not saved yet, or (nil) clears its mark, and saves the map.
    func setUnsavedVote(_ unsaved: UnsavedVote?, for billId: String) {
        guard unsavedVotes[billId] != unsaved else { return }
        unsavedVotes[billId] = unsaved
        persistUnsavedVotesIfNeeded()
    }

    /// Remove expired entries and cap size to maxEntries. A vote not saved yet whose row goes loses its mark, and so
    /// does one sent longer ago than the TTL (its row went with a push, `remove(billId:)`, and was never read again).
    func prune(now: Date = Date()) {
        var prunedKeys: [String] = []

        // 1) TTL prune
        let expiredKeys = entries.compactMap { (key, entry) in
            isExpired(entry, now: now) ? key : nil
        }
        for key in expiredKeys { entries.removeValue(forKey: key) }
        prunedKeys += expiredKeys

        // 2) Bounded eviction (oldest cachedAt)
        if entries.count > config.maxEntries {
            let overflow = entries.count - config.maxEntries
            let keysByOldest = entries
                .sorted { $0.value.cachedAt < $1.value.cachedAt }
                .prefix(overflow)
                .map { $0.key }
            for key in keysByOldest { entries.removeValue(forKey: key) }
            prunedKeys += keysByOldest
        }

        // 3) The marks of the rows that went, and old marks.
        let staleMarks = Set(prunedKeys).union(unsavedVotes.compactMap { billId, unsaved in
            now.timeIntervalSince(unsaved.sentAt) > config.ttl ? billId : nil
        })
        let droppedMarks = staleMarks.filter { unsavedVotes[$0] != nil }
        guard !droppedMarks.isEmpty else { return }
        for billId in droppedMarks { unsavedVotes.removeValue(forKey: billId) }
        persistUnsavedVotesIfNeeded()
    }

    func snapshotStates(now: Date = Date()) -> [String: VoteState] {
        var result: [String: VoteState] = [:]
        result.reserveCapacity(entries.count)

        for (billId, entry) in entries {
            guard !isExpired(entry, now: now) else { continue }
            switch entry {
            case .voted(let v): result[billId] = .voted(v.vote)
            case .notVoted: result[billId] = .notVoted
            }
        }

        return result
    }

    /// Once per persisted cache: removes every Abstain row, saves the rest and returns the bills they were
    /// for. Every Abstain row an earlier build wrote counts, because the rows do not say which ones were an
    /// Updates Dismiss: 1.1 stored both the same way. A later launch finds the mark and drops nothing, so
    /// the Abstains 1.2 writes stay. Yea, Nay and not-voted rows are not touched.
    private func dropEarlierAbstains(key: String) -> [String] {
        let doneKey = Self.earlierAbstainsDroppedKey(for: key)
        guard !defaults.bool(forKey: doneKey) else { return [] }
        let abstainIds = entries.compactMap { billId, entry -> String? in
            guard case .voted(let row) = entry, row.vote == .abstain else { return nil }
            return billId
        }.sorted()
        for billId in abstainIds { entries.removeValue(forKey: billId) }
        if !abstainIds.isEmpty { persistIfNeeded() }
        defaults.set(true, forKey: doneKey)
        return abstainIds
    }

    private func isExpired(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.cachedAt) > config.ttl
    }

    private func persistIfNeeded() {
        guard let key = config.persistenceKey, isAccountStillHere else { return }
        Self.save(entries, to: key, defaults: defaults)
    }

    private func persistUnsavedVotesIfNeeded() {
        guard let key = config.persistenceKey, isAccountStillHere else { return }
        let marksKey = Self.unsavedVotesKey(for: key)
        guard !unsavedVotes.isEmpty else {
            defaults.removeObject(forKey: marksKey)
            return
        }
        if let data = try? JSONEncoder().encode(unsavedVotes) {
            defaults.set(data, forKey: marksKey)
        }
    }

    private static func loadUnsavedVotes(from key: String, defaults: UserDefaults) -> [String: UnsavedVote] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder.usingDefaultKeys().decode([String: UnsavedVote].self, from: data)) ?? [:]
    }

    private static func load(from key: String, defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder.usingDefaultKeys().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func save(_ entries: [String: Entry], to key: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    private static func persistenceKey(scope: String?) -> String {
        ScopedStorageKey.make(base: Config.legacyPersistenceKey, scope: scope)
    }

    /// The mark that `dropEarlierAbstains` has run for the cache saved under `persistenceKey`.
    static func earlierAbstainsDroppedKey(for persistenceKey: String) -> String {
        "\(persistenceKey).earlierAbstainsDropped"
    }

    /// Where the votes not saved yet of the cache saved under `persistenceKey` are saved (APPF-30 step 2).
    static func unsavedVotesKey(for persistenceKey: String) -> String {
        "\(persistenceKey).unconfirmed"
    }

    /// Sign-out and account deletion: the rows and the votes not saved yet go, so no mark reaches another account. A
    /// cache made before this saves nothing more (`isAccountStillHere`).
    static func clearPersistence(scope: String?, defaults: UserDefaults = .standard) {
        let key = persistenceKey(scope: scope)
        clearCounts[key, default: 0] += 1
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: earlierAbstainsDroppedKey(for: key))
        defaults.removeObject(forKey: unsavedVotesKey(for: key))
        if ScopedStorageKey.normalizedScope(scope) != nil {
            clearLegacyPersistence(defaults: defaults)
        }
    }

    static func clearLegacyPersistence(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Config.legacyPersistenceKey)
        defaults.removeObject(forKey: unsavedVotesKey(for: Config.legacyPersistenceKey))
    }

    /// A sign-out that does not know the account: every account's votes not saved yet go (APPF-30 step 2), and no cache
    /// made before this saves anything more (`isAccountStillHere`).
    static func clearAllUnsavedVotes(defaults: UserDefaults = .standard) {
        clearAllCount += 1
        let prefix = Config.legacyPersistenceKey
        let suffix = unsavedVotesKey(for: "")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) && key.hasSuffix(suffix) {
            defaults.removeObject(forKey: key)
        }
    }
}

extension BillVoteCache.UnsavedVote {
    /// A mark saved before `replacedVotes` existed loads with none.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vote = try container.decode(VoteType.self, forKey: .vote)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        reasons = try container.decode([String].self, forKey: .reasons)
        autoResent = try container.decode(Bool.self, forKey: .autoResent)
        replacedVotes = try container.decodeIfPresent([VoteType].self, forKey: .replacedVotes) ?? []
    }
}
