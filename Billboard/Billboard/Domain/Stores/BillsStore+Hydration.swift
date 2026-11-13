import Foundation

// MARK: - Hydration and merging

extension BillsStore {
    /// Emergency-only cap to prevent unbounded growth.
    nonisolated static let maxBillsInMemory = 2_000

    /// Where the incoming bill of a merge comes from, which decides what happens to the life areas the
    /// store holds (UX-29). A source that holds the bill's current life areas replaces them, an empty
    /// list included: the server gives a ceremonial resolution none, and a reprocess can change a bill's.
    /// Any other copy may lack them, so the store's stay as they are and a partial copy never strips a
    /// tag. The merge path says which it is, never the list itself, because `[]` is a real answer.
    nonisolated enum IncomingBillSource: Sendable {
        /// A bills-manifest row (`placeholderBill(from:)`): holds the current life areas. The Bills list's
        /// cards always take their row's (`resolveManifestBills`), so opening a bill does not change its
        /// card; the server writes a row's life areas as GET /processed-bill serves them.
        case manifestRow
        /// A bill the app loaded or built: a /processed-bill response (`isProcessedDetailHydrated ==
        /// true`) holds the current life areas; any other copy (a screen's copy, a stub) does not.
        case loadedBill
        /// A bill read back from the device's bills cache and merged into one loaded since it was written:
        /// does not hold them, even when it was a processed bill, because the loaded one is newer.
        case cachedBill
    }

    /// Ensure a given bill is hydrated with the processed-bill payload.
    /// This is used by detail views to refresh placeholder/manifest-only bills on demand.
    ///
    /// Returns a user-facing message when hydration failed (nil on success, cancellation,
    /// or when there is nothing to hydrate). Pass `reportsError: false` when the caller
    /// shows the returned message itself instead of the shared `errorMessage` banner.
    @discardableResult
    func ensureHydrated(billID: UUID, reportsError: Bool = true) async -> String? {
        guard let index = bills.firstIndex(where: { $0.id == billID }) else { return nil }

        // Avoid spamming the backend if we already have processed-only fields.
        // NOTE: The manifest may include `summary`/`soWhat`, so those are not reliable signals
        // that we have hydrated via /processed-bill.
        let current = bills[index]
        if Self.hasHydratedProcessedFields(current) { return nil }

        guard let guid = current.guid, !guid.isEmpty else { return nil }

        do {
            let processed = try await service.getProcessedBill(
                guid: guid,
                congress: current.congress,
                billType: current.billType,
                billID: current.billID
            )
            // `bills` may have changed while the request was in flight; look the bill up again.
            guard let latestIndex = bills.firstIndex(where: { $0.id == billID }) else { return nil }
            bills[latestIndex] = Self.mergeUserState(into: processed, from: bills[latestIndex], source: .loadedBill)
            applyRevoteFlagsIfNeeded()
            cacheBills(bills)
            return nil
        } catch {
            // Amplify reports a cancelled request as an `APIError` wrapping `URLError.cancelled`.
            if APIErrorResponse.isCancellation(error) { return nil }
            if reportsError {
                errorMessage = "Couldn't load this bill."
            }
            #if DEBUG
            print("[BillsStore] ensureHydrated FAILED billID=\(billID) guid=\(guid) error=\(APIErrorDebug.debugString(for: error))")
            #endif
            return UserFacingLoadError.message(for: error, loading: "this bill")
        }
    }

    /// The bill's processed details are current: loaded, and not superseded by a newer manifest row.
    /// When false, `ensureHydrated` fetches them (again).
    func isBillDetailHydrated(_ bill: Bill) -> Bool {
        Self.hasHydratedProcessedFields(bill)
    }

    /// The bill has processed details to show, current or not: a bill a newer manifest row marked
    /// stale keeps its details on screen (and offline) while they are fetched again.
    func hasBillDetails(_ bill: Bill) -> Bool {
        bill.isProcessedDetailHydrated == true || Self.hasProcessedDetailContent(bill)
    }

    nonisolated private static func hasProcessedDetailContent(_ bill: Bill) -> Bool {
        (bill.link?.isEmpty == false) || !bill.actions.isEmpty || !bill.committees.isEmpty
    }

    /// The hydration flag when it is set; `false` also marks hydrated details that a newer manifest
    /// row has superseded (`mergedHydrationFlag`), so they are fetched again. The content checks are
    /// for bills cached before the flag existed.
    nonisolated private static func hasHydratedProcessedFields(_ bill: Bill) -> Bool {
        if let isHydrated = bill.isProcessedDetailHydrated { return isHydrated }
        return hasProcessedDetailContent(bill)
    }

    /// Merges `incoming` into its loaded bill, or inserts it. An insert into a full store drops another
    /// bill to make room, never `incoming` or a bill in `otherKeptIDs` (`capBills(keeping:)`). A
    /// processed bill's life areas replace the loaded bill's; a screen's copy keeps them (UX-29).
    func upsertProcessedBill(_ incoming: Bill, alsoKeeping otherKeptIDs: Set<UUID> = []) {
        let normalizedGuid = incoming.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchIndex = bills.firstIndex { existing in
            if existing.id == incoming.id {
                return true
            }
            guard let normalizedGuid, !normalizedGuid.isEmpty else { return false }
            return existing.guid?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedGuid
        }

        if let matchIndex {
            bills[matchIndex] = Self.mergeUserState(into: incoming, from: bills[matchIndex], source: .loadedBill)
        } else {
            var normalized = incoming
            Self.normalizeAbstainVoteState(&normalized)
            bills.insert(normalized, at: 0)
            bills = Self.deduplicate(bills)
            if bills.count > Self.maxBillsInMemory {
                // The caller opens or votes on this bill (a linked bill, a screen's copy), so a full
                // store drops another bill instead of it.
                bills = Self.capBills(
                    bills,
                    limit: Self.maxBillsInMemory,
                    keeping: otherKeptIDs.union([normalized.id])
                )
            }
        }

        applyRevoteFlagsIfNeeded()
        cacheBills(bills)
    }

    /// Cap the bills array to `limit`, always preserving voted/watched bills.
    /// Prunes only from unvoted/unwatched bills using the product feed order.
    ///
    /// The bills with ids in `keptIDs` are never pruned: when the feed order would drop some, as
    /// many of the lowest-ranked other bills go instead (or, when voted, watched and kept bills fill
    /// `limit`, the kept ones are the bills over it). Otherwise the result is the same as without
    /// `keptIDs`.
    nonisolated static func capBills(_ bills: [Bill], limit: Int, keeping keptIDs: Set<UUID> = []) -> [Bill] {
        let (protected, prunable) = bills.reduce(into: ([Bill](), [Bill]())) { result, bill in
            if bill.userVoted || bill.userWatched {
                result.0.append(bill)
            } else {
                result.1.append(bill)
            }
        }
        let prunableLimit = max(0, limit - protected.count)
        var keptPrunable = Array(rankBillsForBoard(prunable).prefix(prunableLimit))
        let keptPrunableIDs = Set(keptPrunable.map(\.id))
        let missingKept = prunable.filter { keptIDs.contains($0.id) && !keptPrunableIDs.contains($0.id) }
        guard !missingKept.isEmpty else { return protected + keptPrunable }
        var room = missingKept.count
        for index in keptPrunable.indices.reversed() where room > 0 && !keptIDs.contains(keptPrunable[index].id) {
            keptPrunable.remove(at: index)
            room -= 1
        }
        return protected + missingKept + keptPrunable
    }

    /// Deduplicate bills by ID, keeping only the first occurrence.
    nonisolated static func deduplicate(_ bills: [Bill]) -> [Bill] {
        let originalCount = bills.count
        var seenIds = Set<UUID>()
        let deduplicated = bills.filter { bill in
            let isNew = !seenIds.contains(bill.id)
            if isNew {
                seenIds.insert(bill.id)
            }
            return isNew
        }
        let duplicatesRemoved = originalCount - deduplicated.count
        if duplicatesRemoved > 0 {
            #if DEBUG
            print("[BillsStore] deduplicate() removed \(duplicatesRemoved) duplicate bills (original: \(originalCount), deduplicated: \(deduplicated.count))")
            #endif
        }
        return deduplicated
    }

    /// Normalize legacy abstain rows so abstain is treated as non-voted locally.
    nonisolated static func normalizeAbstainVotes(in bills: [Bill]) -> [Bill] {
        bills.map { bill in
            var normalized = bill
            normalizeAbstainVoteState(&normalized)
            return normalized
        }
    }

    nonisolated static func normalizeAbstainVoteState(_ bill: inout Bill) {
        guard let vote = bill.userVote, !vote.countsAsVote else { return }
        bill.userVoted = false
        bill.userVote = nil
        bill.lastVotedAt = nil
    }

    nonisolated private static func mergeUserState(
        into incoming: [Bill],
        from existing: [Bill],
        source: IncomingBillSource
    ) -> [Bill] {
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return incoming.map { bill in
            guard let old = existingById[bill.id] else { return bill }
            return mergeUserState(into: bill, from: old, source: source)
        }
    }

    /// `incoming` merged into the `existing` bills, then the existing voted and watched bills it lacks.
    /// `source` says where `incoming` came from: manifest rows replace the life areas they cover (UX-29).
    nonisolated static func mergeIncomingBillsPreservingProtected(
        _ incoming: [Bill],
        existing: [Bill],
        source: IncomingBillSource
    ) -> [Bill] {
        var merged = mergeUserState(into: incoming, from: existing, source: source)
        let mergedIDs = Set(merged.map(\.id))

        // Preserve locally watched/voted bills that may be outside the current
        // manifest window so quick-access counts don't oscillate across launches.
        let protected = existing.filter { bill in
            (bill.userVoted || bill.userWatched) && !mergedIDs.contains(bill.id)
        }
        if !protected.isEmpty {
            merged.append(contentsOf: Self.normalizeAbstainVotes(in: protected))
        }

        merged = Self.deduplicate(merged)
        if merged.count > Self.maxBillsInMemory {
            merged = Self.capBills(merged, limit: Self.maxBillsInMemory)
        }
        return merged
    }

    nonisolated private static func mergeUserState(into incoming: Bill, from existing: Bill, source: IncomingBillSource) -> Bill {
        var merged = Self.mergedBillPreservingExistingContext(incoming: incoming, existing: existing, source: source)
        Self.normalizeAbstainVoteState(&merged)
        return merged
    }

    /// `incoming` with the context `existing` holds: the user's vote and watch, hydrated details a
    /// manifest row lacks, and the life areas unless `source` holds the current ones (UX-29).
    nonisolated static func mergedBillPreservingExistingContext(
        incoming: Bill,
        existing: Bill,
        source: IncomingBillSource = .loadedBill
    ) -> Bill {
        let mergedStoredAt = preferredStoredAt(incoming: incoming.storedAt, existing: existing.storedAt)
        let mergedPriority = incoming.isPriority || existing.isPriority
        // A /processed-bill response is the whole document: its official votes replace the cached
        // ones, and a missing vote clears them (REL-31: a repaired bill loses a misparsed tally).
        let incomingIsProcessed = incoming.isProcessedDetailHydrated == true

        return Bill(
            id: incoming.id,
            title: preferredTitle(incoming: incoming.title, existing: existing.title),
            officialTitle: preferredText(incoming: incoming.officialTitle, existing: existing.officialTitle),
            category: preferredCategory(incoming: incoming.category, existing: existing.category),
            subCategory: incoming.subCategory ?? existing.subCategory,
            summary: preferredRequiredText(incoming: incoming.summary, existing: existing.summary),
            soWhat: preferredRequiredText(incoming: incoming.soWhat, existing: existing.soWhat),
            billBreakdown: incoming.billBreakdown ?? existing.billBreakdown,
            storedAt: mergedStoredAt,
            link: preferredText(incoming: incoming.link, existing: existing.link),
            actions: incoming.actions.isEmpty ? existing.actions : incoming.actions,
            committees: incoming.committees.isEmpty ? existing.committees : incoming.committees,
            lifeAreas: mergedLifeAreas(incoming: incoming, existing: existing, source: source),
            billStatus: preferredBillStatus(
                incoming: incoming.billStatus,
                incomingStoredAt: incoming.storedAt,
                existing: existing.billStatus,
                existingStoredAt: existing.storedAt
            ),
            guid: incoming.guid ?? existing.guid,
            congress: incoming.congress ?? existing.congress,
            billType: incoming.billType ?? existing.billType,
            billID: incoming.billID ?? existing.billID,
            sponsorMemberID: incoming.sponsorMemberID ?? existing.sponsorMemberID,
            relatedMemberIDs: mergedMemberIDs(incoming: incoming, existing: existing),
            passedHouse: incoming.passedHouse || existing.passedHouse,
            passedSenate: incoming.passedSenate || existing.passedSenate,
            userVoted: existing.userVoted,
            userWatched: existing.userWatched,
            userVote: existing.userVote,
            lastVotedAt: existing.lastVotedAt,
            userYeaCount: existing.userYeaCount,
            userNayCount: existing.userNayCount,
            isPriority: mergedPriority,
            priorityRank: preferredPriorityRank(incoming: incoming.priorityRank, existing: existing.priorityRank),
            priorityReason: preferredText(incoming: incoming.priorityReason, existing: existing.priorityReason),
            priorityExpiresAt: preferredText(incoming: incoming.priorityExpiresAt, existing: existing.priorityExpiresAt),
            congressHouseYeaCount: incomingIsProcessed
                ? incoming.congressHouseYeaCount : incoming.congressHouseYeaCount ?? existing.congressHouseYeaCount,
            congressHouseNayCount: incomingIsProcessed
                ? incoming.congressHouseNayCount : incoming.congressHouseNayCount ?? existing.congressHouseNayCount,
            congressSenateYeaCount: incomingIsProcessed
                ? incoming.congressSenateYeaCount : incoming.congressSenateYeaCount ?? existing.congressSenateYeaCount,
            congressSenateNayCount: incomingIsProcessed
                ? incoming.congressSenateNayCount : incoming.congressSenateNayCount ?? existing.congressSenateNayCount,
            officialVotes: incomingIsProcessed ? incoming.officialVotes : incoming.officialVotes ?? existing.officialVotes,
            isProcessedDetailHydrated: mergedHydrationFlag(incoming: incoming, existing: existing)
        )
    }

    /// The incoming life areas when `source` holds the bill's current ones, even none (a ceremonial
    /// resolution's since 2026-10-29); else the existing ones. Until UX-29 (project decision 2026-10-28)
    /// this was always the union of both, so a life area the server removed never left a device that
    /// held it (H.Res. 1187, Community Health Workers Week, kept "Medical Costs").
    nonisolated private static func mergedLifeAreas(incoming: Bill, existing: Bill, source: IncomingBillSource) -> [String] {
        let incomingHoldsCurrentLifeAreas: Bool
        switch source {
        case .manifestRow:
            incomingHoldsCurrentLifeAreas = true
        case .loadedBill:
            incomingHoldsCurrentLifeAreas = incoming.isProcessedDetailHydrated == true
        case .cachedBill:
            incomingHoldsCurrentLifeAreas = false
        }
        return canonicalizedValues(incomingHoldsCurrentLifeAreas ? incoming.lifeAreas : existing.lifeAreas)
    }

    /// Hydrated when either side is, except that a manifest placeholder newer than the hydrated
    /// details (its `storedAt` is the processed bill's newer `storedAt`) marks them stale: `false`, so
    /// the next `ensureHydrated` fetches them again. The details stay on the bill until then.
    nonisolated private static func mergedHydrationFlag(incoming: Bill, existing: Bill) -> Bool? {
        if hasHydratedProcessedFields(incoming) { return true }
        guard hasHydratedProcessedFields(existing) else {
            return incoming.isProcessedDetailHydrated ?? existing.isProcessedDetailHydrated
        }
        guard let incomingDate = FlexibleISO8601.parse(incoming.storedAt),
              let existingDate = FlexibleISO8601.parse(existing.storedAt) else { return true }
        return incomingDate <= existingDate
    }

    nonisolated private static func mergedMemberIDs(incoming: Bill, existing: Bill) -> [UUID]? {
        let merged = canonicalizedMemberIDs(
            existing.subscriptionMemberIDs + incoming.subscriptionMemberIDs
        )
        return merged.isEmpty ? nil : merged
    }

    nonisolated private static func canonicalizedMemberIDs(_ memberIDs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var unique: [UUID] = []
        unique.reserveCapacity(memberIDs.count)

        for memberID in memberIDs where seen.insert(memberID).inserted {
            unique.append(memberID)
        }

        return unique.sorted { $0.uuidString < $1.uuidString }
    }

    nonisolated private static func preferredStoredAt(incoming: String?, existing: String?) -> String? {
        guard let incoming = trimmedOrNil(incoming) else { return trimmedOrNil(existing) }
        guard let existing = trimmedOrNil(existing) else { return incoming }

        let incomingDate = FlexibleISO8601.parse(incoming)
        let existingDate = FlexibleISO8601.parse(existing)

        switch (incomingDate, existingDate) {
        case let (left?, right?):
            return left >= right ? incoming : existing
        case (_?, nil):
            return incoming
        case (nil, _?):
            return existing
        case (nil, nil):
            return incoming
        }
    }

    nonisolated private static func preferredTitle(incoming: String, existing: String) -> String {
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedIncoming.isEmpty || trimmedIncoming == "Untitled Bill" {
            let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedExisting.isEmpty {
                return trimmedExisting
            }
        }
        return trimmedIncoming.isEmpty ? existing : trimmedIncoming
    }

    nonisolated private static func preferredCategory(incoming: String, existing: String) -> String {
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedIncoming.isEmpty { return trimmedExisting }
        if trimmedIncoming == "Other", !trimmedExisting.isEmpty, trimmedExisting != "Other" {
            return trimmedExisting
        }
        return trimmedIncoming
    }

    nonisolated private static func preferredText(incoming: String?, existing: String?) -> String? {
        trimmedOrNil(incoming) ?? trimmedOrNil(existing)
    }

    nonisolated private static func preferredRequiredText(incoming: String, existing: String) -> String {
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIncoming.isEmpty {
            return trimmedIncoming
        }

        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedExisting
    }

    nonisolated static func trimmedOrNil(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    nonisolated private static func preferredPriorityRank(incoming: Int?, existing: Int?) -> Int? {
        [incoming, existing]
            .compactMap { $0 }
            .filter { $0 > 0 }
            .min()
    }

    nonisolated static func preferredBillStatus(
        incoming: BillStatus,
        incomingStoredAt: String? = nil,
        existing: BillStatus,
        existingStoredAt: String? = nil
    ) -> BillStatus {
        func rank(for status: BillStatus) -> Int {
            switch status {
            case .new:
                return 0
            case .updated:
                return 1
            case .passed, .failed:
                return 2
            case .finalized:
                return 3
            }
        }

        let incomingRank = rank(for: incoming)
        let existingRank = rank(for: existing)
        if incomingRank != existingRank {
            return incomingRank > existingRank ? incoming : existing
        }
        if incoming == existing {
            return incoming
        }

        let incomingDate = FlexibleISO8601.parse(incomingStoredAt) ?? .distantPast
        let existingDate = FlexibleISO8601.parse(existingStoredAt) ?? .distantPast
        return incomingDate >= existingDate ? incoming : existing
    }
}
