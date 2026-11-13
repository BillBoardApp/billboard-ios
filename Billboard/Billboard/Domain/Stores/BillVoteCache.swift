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

    private let config: Config
    private let defaults: UserDefaults
    private var entries: [String: Entry] = [:]

    /// The bills whose Abstain row this cache dropped when it was created: the rows an earlier build left
    /// (INT-11, see the type's comment). Empty from the second launch of 1.2 on, and for a cache that is not
    /// persisted. `BillVoteStore.recheckEarlierAbstains()` reads them from the server.
    private(set) var droppedAbstainIds: [String] = []

    init(scope: String? = nil, config: Config = .init(), defaults: UserDefaults = .standard) {
        var resolvedConfig = config
        if config.persistenceKey == Config.legacyPersistenceKey {
            resolvedConfig.persistenceKey = Self.persistenceKey(scope: scope)
        }

        self.config = resolvedConfig
        self.defaults = defaults
        if let key = resolvedConfig.persistenceKey {
            #if DEBUG
            // Keep unit tests isolated from the persisted local state of the app they run in. A defaults
            // suite a test made itself is isolated already, and may hold the cache of an earlier build.
            let isRunningTests = NSClassFromString("XCTest") != nil
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            if isRunningTests && defaults === UserDefaults.standard {
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: Self.earlierAbstainsDroppedKey(for: key))
                Self.clearLegacyPersistence(defaults: defaults)
            }
            #endif
            if key != Config.legacyPersistenceKey {
                Self.clearLegacyPersistence(defaults: defaults)
            }
            self.entries = Self.load(from: key, defaults: defaults)
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

    func remove(billId: String) {
        entries.removeValue(forKey: billId)
        persistIfNeeded()
    }

    /// Remove expired entries and cap size to maxEntries.
    func prune(now: Date = Date()) {
        if entries.isEmpty { return }

        // 1) TTL prune
        let expiredKeys = entries.compactMap { (key, entry) in
            isExpired(entry, now: now) ? key : nil
        }
        for key in expiredKeys { entries.removeValue(forKey: key) }

        // 2) Bounded eviction (oldest cachedAt)
        if entries.count > config.maxEntries {
            let overflow = entries.count - config.maxEntries
            let keysByOldest = entries
                .sorted { $0.value.cachedAt < $1.value.cachedAt }
                .prefix(overflow)
                .map { $0.key }
            for key in keysByOldest { entries.removeValue(forKey: key) }
        }
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
        guard let key = config.persistenceKey else { return }
        Self.save(entries, to: key, defaults: defaults)
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

    static func clearPersistence(scope: String?, defaults: UserDefaults = .standard) {
        let key = persistenceKey(scope: scope)
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: earlierAbstainsDroppedKey(for: key))
        if ScopedStorageKey.normalizedScope(scope) != nil {
            clearLegacyPersistence(defaults: defaults)
        }
    }

    static func clearLegacyPersistence(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Config.legacyPersistenceKey)
    }
}
