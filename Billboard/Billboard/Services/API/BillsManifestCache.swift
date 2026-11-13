import Foundation
import os

/// The device's copy of the bills manifest: every item as JSON in a file under Caches
/// (`DiskJSONCache`), plus when it was written, its size and how much of the manifest it covers
/// (small values in UserDefaults).
///
/// A full fetch replaces the copy and marks it `.full`. A windowed fetch is merged into a `.full`
/// copy (which stays full) when its window reaches back to the copy's last write, and otherwise
/// replaces the copy as `.windowed`. Nothing is dropped, so a `.full` copy holds every bill of the
/// last full fetch and every change since; before this, the cache kept at most 2,000 items yet still
/// recorded a full fetch as `.full`, and the store then treated a truncated copy as complete. Those
/// caches used other keys, which the next write removes.
///
/// A windowed fetch that does not reach back leaves a gap: someone who opened Search once (a full
/// copy) and then stayed away longer than the Bills tab's window (7 days by default) would keep a
/// "full" copy without the bills published or changed meanwhile, and Search, which trusts a full copy,
/// would say it looked for a bill "in every bill" when that bill exists. So that copy is replaced, and
/// the next screen that needs every bill (Search, a topic page) fetches the full manifest again.
///
/// 1.1's copy (`data.v4`, `coverage.v2`) was kept in the order it ranked bills by other users' vote
/// count, with the counts in it. 1.2 reads other keys (`data.v5`, `coverage.v3`), so an upgraded
/// install starts from a fresh fetch and never merges into that order, and deletes the old copy at
/// launch (`discardEarlierCachesInBackground`).
///
/// Writes are serialized (`writeLock`) and the coverage is only reported for the file it was
/// recorded with, so the coverage and the file always match.
///
/// The companion groups (APPF-23) are kept apart, under `companionGroupsKey`: every manifest response
/// lists all of them, so the latest list replaces the cached one, and a response without the field
/// (a server that predates them) leaves it. Adding them bumped neither the data nor the coverage key.
///
/// `BillsService` reads `BillsManifestCache.current`; tests give it their own keys for one call tree
/// with `BillsManifestCache.$current.withValue(BillsManifestCache(namespace:))`.
nonisolated struct BillsManifestCache: Sendable {
    nonisolated enum Coverage: String, Sendable {
        /// The bills updated inside one history window.
        case windowed
        /// Every bill in the manifest.
        case full
    }

    /// What one fetch asked for: the whole manifest, or the bills updated after a date.
    nonisolated enum Fetch: Equatable, Sendable {
        case full
        case windowed(updatedAfter: Date)

        var coverage: Coverage {
            switch self {
            case .full: .full
            case .windowed: .windowed
            }
        }
    }

    /// How far before the copy's last write a windowed fetch must start to keep a full copy full. A
    /// manifest row is dated by its bill's document, stored shortly before the row is written, so a row
    /// written while the last fetch ran can carry a date a little before that fetch was written.
    static let gapAllowance: TimeInterval = 60 * 60

    static let liveNamespace = "BillsService.billsManifest"

    /// Serializes the writes (`store`, `clear`, and clearing the coverage of a copy that does not
    /// decode). `store` reads the copy, merges into it and writes it back, and two fetches can finish
    /// at once (a Load More during a pull-to-refresh, the weekly digest's windowed fetch): unserialized,
    /// a windowed copy could replace a full one written in between, or be recorded as full. It is held
    /// across the encode and the file write, so readers do not take it; `coverage()` checks the file
    /// instead.
    private static let writeLock = OSAllocatedUnfairLock()

    @TaskLocal static var current = BillsManifestCache()

    let namespace: String
    var dataKey: String { "\(namespace).data.v5" }
    var timestampKey: String { "\(namespace).timestamp.v5" }
    var coverageKey: String { "\(namespace).coverage.v3" }
    /// The size of the file the coverage was recorded for.
    var byteCountKey: String { "\(namespace).bytes.v2" }
    /// The companion groups of the latest response that listed them (a file under Caches).
    var companionGroupsKey: String { "\(namespace).companionGroups.v1" }

    /// The keys of earlier caches, removed at launch and by the next write: the unversioned keys of the
    /// first cache (its items were a UserDefaults blob), the capped v3 cache, and 1.1's v4 cache (INT-11:
    /// ranked by vote count, counts included). Data keys are removed from both UserDefaults and Caches.
    var legacyDataKeys: [String] { ["\(namespace).data", "\(namespace).data.v3", "\(namespace).data.v4"] }
    var legacyDefaultsKeys: [String] {
        [
            "\(namespace).timestamp", "\(namespace).timestamp.v3", "\(namespace).coverage.v1",
            "\(namespace).timestamp.v4", "\(namespace).coverage.v2", "\(namespace).bytes.v1"
        ]
    }

    init(namespace: String = BillsManifestCache.liveNamespace) {
        self.namespace = namespace
    }

    // MARK: - Reading

    /// Every cached item, or nil when there is no readable copy. A copy that does not decode loses its
    /// coverage, so it is not taken for full (or windowed) again.
    func items() -> [BillsManifestItem]? {
        guard let data = DiskJSONCache.data(forKey: dataKey) else { return nil }
        if let items = Self.decodedItems(data) { return items }
        Self.writeLock.withLock {
            // Unless a write replaced the file since it was read.
            guard DiskJSONCache.byteCount(forKey: dataKey) == data.count else { return }
            UserDefaults.standard.removeObject(forKey: coverageKey)
        }
        return nil
    }

    /// True when the copy was written at most `maxAge` seconds ago.
    func isFresh(maxAge: TimeInterval) -> Bool {
        let timestamp = UserDefaults.standard.double(forKey: timestampKey)
        guard timestamp > 0 else { return false }
        let age = Date().timeIntervalSince1970 - timestamp
        return age >= 0 && age <= maxAge
    }

    /// How much of the manifest the copy covers, or nil when there is no usable copy: none was
    /// written, a write is in progress or was cut short, the file is gone (iOS purges Caches when
    /// storage runs low) or is not the one the coverage was recorded for, or it did not decode
    /// (`items()`). Checks the file's size, not its contents, so it is cheap on the main actor.
    func coverage() -> Coverage? {
        let defaults = UserDefaults.standard
        guard let recorded = defaults.string(forKey: coverageKey).flatMap(Coverage.init(rawValue:)) else { return nil }
        let byteCount = defaults.integer(forKey: byteCountKey)
        guard byteCount > 0, DiskJSONCache.byteCount(forKey: dataKey) == byteCount else { return nil }
        // `store` clears the coverage before it replaces the file and records the new coverage last,
        // so while the value is unchanged the file checked above is the one it describes.
        guard defaults.string(forKey: coverageKey) == recorded.rawValue else { return nil }
        return recorded
    }

    // MARK: - Writing

    /// Caches the items of one fetch: `.full` for a fetch of the whole manifest, `.windowed` with the
    /// fetch's `updatedAfter` for a windowed one. Returns the coverage of the copy now cached, or nil
    /// when it could not be written; the previous copy then stays, with its coverage (the file is
    /// written atomically).
    ///
    /// Serialized with the other writes (`writeLock`), so a windowed fetch is merged into the copy the
    /// previous write left, whichever fetch finishes first.
    @discardableResult
    func store(_ fetchedItems: [BillsManifestItem], fetched: Fetch) -> Coverage? {
        let source = fetched == .full ? "full" : "incremental"
        let incoming = Self.cacheEntries(from: Self.deduplicatedItems(fetchedItems))
        HomePerfTimeline.mark("manifest_cache_normalized", detail: "source=\(source) count=\(incoming.count)")
        return Self.writeLock.withLock {
            write(incoming, fetched: fetched, source: source)
        }
    }

    /// `store` under `writeLock`.
    private func write(_ incoming: [CacheEntry], fetched: Fetch, source: String) -> Coverage? {
        let entries: [CacheEntry]
        let coverage: Coverage
        // Keep a full copy warm with windowed updates that leave no gap, but do not merge windowed
        // fetches together across launches: replacing a windowed copy keeps stale items from reappearing.
        if case .windowed(let updatedAfter) = fetched, self.coverage() == .full,
           reachesBackToLastWrite(updatedAfter),
           let existingData = DiskJSONCache.data(forKey: dataKey),
           let existing = Self.decodedItems(existingData) {
            entries = Self.mergingIncremental(incoming, into: Self.cacheEntries(from: existing))
            coverage = .full
            HomePerfTimeline.mark("manifest_cache_merged_existing", detail: "source=\(source) count=\(entries.count)")
        } else {
            entries = incoming.sorted { $0.sortKey < $1.sortKey }
            coverage = fetched.coverage
            HomePerfTimeline.mark("manifest_cache_sorted", detail: "source=\(source) count=\(entries.count)")
        }

        guard let data = try? JSONEncoder().encode(entries.map(\.item)) else { return nil }
        HomePerfTimeline.mark("manifest_cache_encoded", detail: "source=\(source) bytes=\(data.count)")

        // The coverage is cleared while the file is replaced, so a copy whose write was cut short is
        // not taken for the new coverage. A failed write leaves the previous file as it was, so its
        // coverage is put back.
        let defaults = UserDefaults.standard
        let previousCoverage = defaults.string(forKey: coverageKey)
        defaults.removeObject(forKey: coverageKey)
        guard DiskJSONCache.store(data, forKey: dataKey) else {
            if let previousCoverage { defaults.set(previousCoverage, forKey: coverageKey) }
            HomePerfTimeline.mark("manifest_cache_write_failed", detail: "source=\(source) bytes=\(data.count)")
            return nil
        }
        defaults.set(data.count, forKey: byteCountKey)
        defaults.set(Date().timeIntervalSince1970, forKey: timestampKey)
        defaults.set(coverage.rawValue, forKey: coverageKey)
        removeLegacyCache()
        HomePerfTimeline.mark("manifest_cache_stored", detail: "source=\(source) bytes=\(data.count) coverage=\(coverage.rawValue)")
        return coverage
    }

    /// Whether a windowed fetch from `updatedAfter` covers every change since the copy was last written
    /// (with `gapAllowance` to spare), so merging it into a full copy leaves no gap.
    private func reachesBackToLastWrite(_ updatedAfter: Date) -> Bool {
        let lastWrite = UserDefaults.standard.double(forKey: timestampKey)
        guard lastWrite > 0 else { return false }
        return updatedAfter.timeIntervalSince1970 <= lastWrite - Self.gapAllowance
    }

    // MARK: - Companion groups

    /// The cached companion groups, or nil when none were stored (or the file is gone or unreadable).
    func companionGroups() -> [BillCompanionGroup]? {
        guard let data = DiskJSONCache.data(forKey: companionGroupsKey) else { return nil }
        return try? JSONDecoder().decode([BillCompanionGroup].self, from: data)
    }

    /// Replaces the cached companion groups with `groups`, the complete list of one response; `[]`
    /// clears them. Callers skip a response without the field, which keeps the cached list. Returns
    /// false when the file could not be written (the previous list stays).
    @discardableResult
    func storeCompanionGroups(_ groups: [BillCompanionGroup]) -> Bool {
        guard let data = try? JSONEncoder().encode(groups) else { return false }
        return Self.writeLock.withLock {
            DiskJSONCache.store(data, forKey: companionGroupsKey)
        }
    }

    /// Removes this cache's file and values (tests).
    func clear() {
        Self.writeLock.withLock {
            DiskJSONCache.removeData(forKey: companionGroupsKey)
            DiskJSONCache.removeData(forKey: dataKey)
            UserDefaults.standard.removeObject(forKey: timestampKey)
            UserDefaults.standard.removeObject(forKey: coverageKey)
            UserDefaults.standard.removeObject(forKey: byteCountKey)
        }
    }

    /// Deletes the earlier caches of this namespace (`legacyDataKeys`, `legacyDefaultsKeys`) on a utility
    /// task, so the launch that follows an update does not wait for the file system: the full manifest
    /// runs to tens of thousands of items. Nothing reads those keys any more, so the cache that is read
    /// is unaffected and no lock is needed. Safe to run on every launch; the returned task is for tests.
    @discardableResult
    func discardEarlierCachesInBackground() -> Task<Void, Never> {
        Task.detached(priority: .utility) { removeLegacyCache() }
    }

    func removeLegacyCache() {
        legacyDataKeys.forEach(DiskJSONCache.removeData(forKey:))
        legacyDefaultsKeys.forEach(UserDefaults.standard.removeObject(forKey:))
    }

    private static func decodedItems(_ data: Data) -> [BillsManifestItem]? {
        try? JSONDecoder.convertingFromSnakeCase().decode([BillsManifestItem].self, from: data)
    }

    // MARK: - Order

    /// Product order of the cached items: priority rank, then most recently updated, then guid. Never by
    /// vote count (INT-11); a count an old cache file or server still has is ignored and not written back.
    nonisolated struct SortKey: Comparable {
        let priorityRank: Int
        let updatedAt: Date
        let guid: String

        init(item: BillsManifestItem) {
            priorityRank = item.isPriority == true ? (item.priorityRank.flatMap { $0 > 0 ? $0 : nil } ?? Int.max) : Int.max
            updatedAt = FlexibleISO8601.parse(item.updatedAt) ?? .distantPast
            guid = item.guid
        }

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.priorityRank != rhs.priorityRank { return lhs.priorityRank < rhs.priorityRank }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.guid < rhs.guid
        }
    }

    nonisolated private struct CacheEntry {
        let item: BillsManifestItem
        let sortKey: SortKey

        init(item: BillsManifestItem) {
            self.item = item
            sortKey = SortKey(item: item)
        }
    }

    private static func cacheEntries(from items: [BillsManifestItem]) -> [CacheEntry] {
        items.map(CacheEntry.init)
    }

    /// `existing` without the items `incoming` replaces, with each incoming item inserted in order. An
    /// incoming item older than the existing item of its guid is left out: a windowed fetch that
    /// started before the full fetch it is merged into can carry older versions of its bills.
    private static func mergingIncremental(_ incoming: [CacheEntry], into existing: [CacheEntry]) -> [CacheEntry] {
        guard !incoming.isEmpty else { return existing }

        let existingUpdatedAt = Dictionary(existing.map { ($0.item.guid, $0.sortKey.updatedAt) }) { first, _ in first }
        let incoming = incoming.filter { entry in
            guard let current = existingUpdatedAt[entry.item.guid] else { return true }
            return entry.sortKey.updatedAt >= current
        }
        let incomingGUIDs = Set(incoming.map(\.item.guid))
        var merged = existing.filter { !incomingGUIDs.contains($0.item.guid) }
        merged.reserveCapacity(merged.count + incoming.count)
        for entry in incoming {
            merged.insert(entry, at: insertionIndex(for: entry.sortKey, in: merged))
        }
        return merged
    }

    private static func insertionIndex(for sortKey: SortKey, in entries: [CacheEntry]) -> Int {
        var lowerBound = 0
        var upperBound = entries.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if entries[midpoint].sortKey < sortKey {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    // MARK: - Normalization

    /// One item per guid: duplicates are merged, preferring the newer (then the more complete) item. The
    /// preferred item's life areas are kept as they are, an empty list included (UX-29), so an older
    /// duplicate cannot bring back a life area the server removed.
    static func deduplicatedItems(_ items: [BillsManifestItem]) -> [BillsManifestItem] {
        var byGuid: [String: BillsManifestItem] = [:]
        var order: [String] = []
        for rawItem in items {
            let item = canonicalItem(rawItem)
            if let existing = byGuid[item.guid] {
                byGuid[item.guid] = mergedItem(existing, item)
            } else {
                byGuid[item.guid] = item
                order.append(item.guid)
            }
        }
        #if DEBUG
        if order.count < items.count {
            print("[BillsManifestCache] deduplicated \(items.count - order.count) duplicate manifest items before caching")
        }
        #endif
        return order.compactMap { byGuid[$0] }
    }

    private static func mergedItem(_ lhs: BillsManifestItem, _ rhs: BillsManifestItem) -> BillsManifestItem {
        let preferred = shouldPrefer(lhs, over: rhs) ? lhs : rhs
        let fallback = preferred == lhs ? rhs : lhs

        return BillsManifestItem(
            guid: preferred.guid,
            congress: preferred.congress ?? fallback.congress,
            billType: preferred.billType ?? fallback.billType,
            billID: preferred.billID ?? fallback.billID,
            updatedAt: preferred.updatedAt ?? fallback.updatedAt,
            subCategories: canonicalizedValues(preferred.subCategories + fallback.subCategories),
            lifeAreas: preferred.lifeAreas,
            sponsors: canonicalizedValues(preferred.sponsors + fallback.sponsors),
            cosponsors: canonicalizedValues(preferred.cosponsors + fallback.cosponsors),
            isPriority: preferred.isPriority == true || fallback.isPriority == true,
            priorityRank: [preferred.priorityRank, fallback.priorityRank].compactMap { $0 }.min(),
            priorityReason: preferred.priorityReason ?? fallback.priorityReason,
            priorityExpiresAt: preferred.priorityExpiresAt ?? fallback.priorityExpiresAt,
            title: preferred.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback.title : preferred.title,
            billStatus: preferred.billStatus ?? fallback.billStatus,
            civicProfile: preferred.civicProfile ?? fallback.civicProfile
        )
    }

    private static func shouldPrefer(_ lhs: BillsManifestItem, over rhs: BillsManifestItem) -> Bool {
        switch (FlexibleISO8601.parse(lhs.updatedAt), FlexibleISO8601.parse(rhs.updatedAt)) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return completenessScore(lhs) >= completenessScore(rhs)
        }
    }

    private static func completenessScore(_ item: BillsManifestItem) -> Int {
        let hasTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        return hasTitle
            + item.subCategories.count
            + item.lifeAreas.count
            + item.sponsors.count
            + item.cosponsors.count
            + (item.billStatus == nil ? 0 : 1)
            + (item.civicProfile == nil ? 0 : 1)
    }

    private static func canonicalItem(_ item: BillsManifestItem) -> BillsManifestItem {
        BillsManifestItem(
            guid: item.guid.trimmingCharacters(in: .whitespacesAndNewlines),
            congress: trimmedOrNil(item.congress),
            billType: trimmedOrNil(item.billType),
            billID: trimmedOrNil(item.billID),
            updatedAt: trimmedOrNil(item.updatedAt),
            subCategories: canonicalizedValues(item.subCategories),
            lifeAreas: canonicalizedValues(item.lifeAreas),
            sponsors: canonicalizedValues(item.sponsors),
            cosponsors: canonicalizedValues(item.cosponsors),
            isPriority: item.isPriority,
            priorityRank: item.priorityRank,
            priorityReason: trimmedOrNil(item.priorityReason),
            priorityExpiresAt: trimmedOrNil(item.priorityExpiresAt),
            title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
            billStatus: trimmedOrNil(item.billStatus),
            civicProfile: item.civicProfile
        )
    }

    /// Trimmed, non-empty, unique values in case-insensitive order.
    static func canonicalizedValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)
        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            unique.append(cleaned)
        }
        return unique.sorted { lhs, rhs in
            let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
            if comparison == .orderedSame { return lhs < rhs }
            return comparison == .orderedAscending
        }
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }
        return cleaned
    }
}
