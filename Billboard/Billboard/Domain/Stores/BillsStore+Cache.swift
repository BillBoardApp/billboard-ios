import Foundation

// MARK: - Disk cache

extension BillsStore {
    nonisolated private static var billsDataCacheKey: String { "BillsStore.bills.data" }
    nonisolated private static var billsTimestampCacheKey: String { "BillsStore.bills.timestamp" }

    static func normalizedScope(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func clearCachedBills(scope: String?, defaults: UserDefaults = .standard) {
        let scopedDataKey = scopedCacheKey(billsDataCacheKey, scope: scope)
        let scopedTimestampKey = scopedCacheKey(billsTimestampCacheKey, scope: scope)

        DiskJSONCache.removeData(forKey: scopedDataKey)
        defaults.removeObject(forKey: scopedTimestampKey)

        if ScopedStorageKey.normalizedScope(scope) != nil {
            DiskJSONCache.removeData(forKey: billsDataCacheKey)
            defaults.removeObject(forKey: billsTimestampCacheKey)
        }
    }

    nonisolated private static func scopedCacheKey(_ base: String, scope: String?) -> String {
        ScopedStorageKey.make(base: base, scope: scope)
    }

    private func scopedCacheKey(_ base: String) -> String {
        Self.scopedCacheKey(base, scope: cacheScope)
    }

    /// The cached bills, with legacy topic names mapped to the current ones (LLM-10): `Bill` decodes
    /// with the synthesized `Codable` init, so a cache written before the label switch keeps old names.
    nonisolated static func cachedBills(scope: String?) -> [Bill]? {
        let key = scopedCacheKey(Self.billsDataCacheKey, scope: scope)
        guard let data = DiskJSONCache.data(forKey: key) else { return nil }
        let bills = try? JSONDecoder.usingDefaultKeys(dates: .iso8601).decode([Bill].self, from: data)
        return bills?.map { $0.canonicalizingTopics() }
    }

    private func cachedBills() -> [Bill]? {
        Self.cachedBills(scope: cacheScope)
    }

    /// The latest bills-cache write in each cache scope, by its data key.
    private static var latestCacheWrites: [String: Task<Void, Never>] = [:]

    /// The latest bills-cache write in `scope`, if any: tests await it instead of polling for the timestamp.
    static func latestBillsCacheWrite(scope: String?) -> Task<Void, Never>? {
        latestCacheWrites[scopedCacheKey(billsDataCacheKey, scope: scope)]
    }

    /// Writes `bills` to the disk cache off the main actor. Each write waits for the one before it in the same
    /// scope, so two quick writes can't finish out of order and leave the older bills on disk.
    func cacheBills(_ bills: [Bill]) {
        let billsToCache = bills
        let dataKey = scopedCacheKey(Self.billsDataCacheKey)
        let timestampKey = scopedCacheKey(Self.billsTimestampCacheKey)
        let previousWrite = Self.latestCacheWrites[dataKey]

        Self.latestCacheWrites[dataKey] = Task.detached(priority: .utility) {
            await previousWrite?.value
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(billsToCache) else { return }

            let defaults = UserDefaults.standard
            DiskJSONCache.store(data, forKey: dataKey)
            defaults.set(Date().timeIntervalSince1970, forKey: timestampKey)
        }
    }
}

// MARK: - Cache restore

extension BillsStore {
    /// The cached manifest and bills prepared for `restoreCachedStateIfNeeded`, off the main actor.
    nonisolated struct CacheRestoreSnapshot: Sendable {
        let deduplicatedManifest: [BillsManifestItem]
        let preparedManifestEntries: [ManifestEntry]
        let normalizedCachedBills: [Bill]
        let visibleManifestEntries: [ManifestEntry]
        let restoredBills: [Bill]?
        let resolvedActiveManifestBills: [Bill]
        /// The cached companion groups (APPF-23).
        let companionIndex: CompanionGroupIndex
    }

    /// Deduplicates the cached manifest, builds its entries and merges the visible entries' placeholder
    /// bills with the cached bills. Pure, so the restore runs it off the main actor. Both come out with
    /// current topic names (LLM-10): the manifest through `deduplicateManifest`, the bills here.
    ///
    /// The cached bills are ranked in the product order (`rankBillsForBoard`) before anything else uses
    /// them: 1.1 saved them in the order it ranked bills by other users' vote count (INT-11), and with no
    /// cached manifest, or for the voted and watched bills kept outside its window, that saved order is
    /// the order Search and the topic lists show.
    nonisolated static func cacheRestoreSnapshot(
        cachedManifest: [BillsManifestItem],
        cachedBills: [Bill],
        cachedCompanionGroups: [BillCompanionGroup] = [],
        historyWindow: BillboardHistoryWindow
    ) -> CacheRestoreSnapshot {
        let deduplicatedManifest = Self.deduplicateManifest(cachedManifest)
        let preparedManifestEntries = Self.preparedManifestEntries(from: deduplicatedManifest)
        let normalizedCachedBills = Self.normalizeAbstainVotes(
            in: rankBillsForBoard(Self.deduplicate(cachedBills.map { $0.canonicalizingTopics() }))
        )
        let companionIndex = CompanionGroupIndex(groups: cachedCompanionGroups)
        let visibleManifestEntries = Self.visibleManifestEntries(
            from: preparedManifestEntries,
            historyWindow: historyWindow,
            companions: companionIndex
        )

        let restoredBills: [Bill]?
        if !visibleManifestEntries.isEmpty {
            restoredBills = Self.mergeIncomingBillsPreservingProtected(
                visibleManifestEntries.map(\.placeholderBill),
                existing: normalizedCachedBills,
                source: .manifestRow
            )
        } else if !normalizedCachedBills.isEmpty {
            restoredBills = normalizedCachedBills
        } else {
            restoredBills = nil
        }

        let resolutionSourceBills = restoredBills ?? normalizedCachedBills
        let resolvedActiveManifestBills = Self.resolveManifestBills(
            manifestEntries: visibleManifestEntries,
            billsByGuid: Self.makeBillLookupByGuid(from: resolutionSourceBills),
            billsByID: Self.makeBillLookupByID(from: resolutionSourceBills)
        )

        return CacheRestoreSnapshot(
            deduplicatedManifest: deduplicatedManifest,
            preparedManifestEntries: preparedManifestEntries,
            normalizedCachedBills: normalizedCachedBills,
            visibleManifestEntries: visibleManifestEntries,
            restoredBills: restoredBills,
            resolvedActiveManifestBills: resolvedActiveManifestBills,
            companionIndex: companionIndex
        )
    }
}
