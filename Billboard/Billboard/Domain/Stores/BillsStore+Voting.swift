import Foundation

// MARK: - Voting and watching

extension BillsStore {
    /// Mark a bill as requiring a revote (resets local vote state).
    /// This is used for "Updated" pushes where the user must re-read and re-vote.
    func requireRevote(billID: UUID) {
        requiresRevoteIDs.insert(billID)
        applyRevoteFlagIfPresent(billID: billID)
    }

    /// Remove a bill from the watchlist (e.g., after a passed bill is viewed/dismissed). For a bill in
    /// a companion group (APPF-23) the watch is removed from every member.
    func unwatch(billID: UUID) {
        if let group = companionGroup(forBillID: billID) {
            unwatchMembers(of: group, except: nil)
            return
        }
        guard let index = bills.firstIndex(where: { $0.id == billID }),
              bills[index].userWatched else { return }
        bills[index].userWatched = false
        cacheBills(bills)

        // Sync unwatch to backend preferences.
        if let guid = bills[index].guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            userStore?.removeWatch(guid: guid)
        }
    }

    /// Unwatches every loaded bill of `group`'s members that is watched, except `excludedID`.
    private func unwatchMembers(of group: BillCompanionGroup, except excludedID: UUID?) {
        let memberIDs = Set(group.memberGuids.flatMap { loadedBills(ofMember: $0).map(\.id) })
        var removedGuids: [String] = []
        performActiveManifestBillsBatchUpdate {
            for index in bills.indices where memberIDs.contains(bills[index].id) && bills[index].id != excludedID {
                guard bills[index].userWatched else { continue }
                bills[index].userWatched = false
                if let guid = bills[index].guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
                    removedGuids.append(guid)
                }
            }
        }
        guard !removedGuids.isEmpty else { return }
        cacheBills(bills)
        removedGuids.forEach { userStore?.removeWatch(guid: $0) }
    }

    /// Record a vote and optional watch flag for a bill.
    @discardableResult
    func vote(billID: UUID, yea: Bool, watch: Bool, reasons: [VoteReason] = []) -> Task<Bool, Never>? {
        // Backwards-compatible wrapper that maps the old boolean API to the new enum API
        let userVote: UserVote = yea ? .yea : .nay
        return vote(billID: billID, vote: userVote, watch: watch, reasons: reasons)
    }

    /// Record a vote using the `UserVote` enum (supports `.yea`, `.nay`, and `.abstain`).
    ///
    /// For a bill in a companion group (APPF-23) the vote goes to the group's vote target
    /// (`companionVote(for:)`): the member that already holds the user's vote, else the primary. Only
    /// that member's bill, vote row, watch and `type=bill` preference are written; `watch == false`
    /// also removes the watch from the other members. The `type=bill` preference is written only once the
    /// server stores the vote (`saveBillPreference`).
    ///
    /// `watch == nil` leaves every member's watch as it is: no Watch row is added or removed and no
    /// local flag changes. The vote bar passes nil (spec D 2.1.5: a vote never changes watch). Passing
    /// the current value instead would add a Watch row on the vote target of a group that is watched
    /// only on another member.
    ///
    /// Returns the server sync task (true once the vote is stored), or nil when the bill is
    /// not in the store or has no guid to sync with.
    @discardableResult
    func vote(billID: UUID, vote: UserVote, watch: Bool?, reasons: [VoteReason] = []) -> Task<Bool, Never>? {
        guard let write = submitVote(billID: billID, vote: vote, watch: watch, reasons: reasons) else { return nil }
        return Task { await write.value == .stored }
    }

    /// `vote(billID:vote:watch:reasons:)` with the write's full result. A vote the server refuses is rolled
    /// back here as in the vote store (APPF-27); bill detail uses the result to drop its own choice.
    @discardableResult
    func submitVote(billID: UUID, vote: UserVote, watch: Bool?, reasons: [VoteReason] = []) -> Task<VoteWriteResult, Never>? {
        guard let index = bills.firstIndex(where: { $0.id == billID }) else { return nil }
        guard let group = companionGroupIndex.group(for: bills[index]) else {
            return recordVote(on: bills[index], at: index, vote: vote, watch: watch, reasons: reasons)
        }

        let targetGuid = companionVote(for: group).targetGuid
        let target = voteTarget(forGuid: targetGuid, cardIndex: index)
        let syncTask = recordVote(on: target.bill, at: target.index, vote: vote, watch: watch, reasons: reasons)
        if watch == false {
            unwatchMembers(of: group, except: target.bill.id)
        }
        return syncTask
    }

    /// The bill to record a group vote on, and its index in `bills`: the bill with `targetGuid`, else a
    /// placeholder for it (from its manifest item, else from the card's bill) that has no index yet.
    private func voteTarget(forGuid targetGuid: String, cardIndex: Int) -> (bill: Bill, index: Int?) {
        if let index = bills.firstIndex(where: { $0.guid?.trimmingCharacters(in: .whitespacesAndNewlines) == targetGuid }) {
            return (bills[index], index)
        }
        let placeholder: Bill
        if let item = manifestItems.first(where: { $0.guid == targetGuid }) {
            placeholder = Self.placeholderBill(from: item)
        } else {
            let card = bills[cardIndex]
            let locator = BillsService.deriveLocator(from: targetGuid)
            placeholder = Bill(
                id: UUID.deterministic(from: targetGuid),
                title: card.title,
                category: card.category,
                subCategory: card.subCategory,
                soWhat: "",
                lifeAreas: card.lifeAreas,
                billStatus: .new,
                guid: targetGuid,
                congress: locator?.congress,
                billType: locator?.billType,
                billID: locator?.billID,
                userVoted: false,
                isProcessedDetailHydrated: false
            )
        }
        return (placeholder, nil)
    }

    /// `vote(billID:vote:watch:reasons:)` on `bill`, which is at `index` in `bills` (nil for a placeholder
    /// that is not there yet): the whole per-bill write. The changes are made on a copy and written once,
    /// because every write to `bills` rebuilds both bill lookups. A nil `watch` leaves the bill's watch
    /// (local flag and Watch row) as it is.
    private func recordVote(on bill: Bill, at index: Int?, vote: UserVote, watch: Bool?, reasons: [VoteReason]) -> Task<VoteWriteResult, Never>? {
        var updated = bill
        let isCountedVote = vote.countsAsVote

        // Update watch/vote timestamp
        updated.userVoted = isCountedVote
        if let watch {
            updated.userWatched = watch
        }

        // Adjust community counts: if the user had a previous recorded vote, decrement it
        if let previous = updated.userVote {
            switch previous {
            case .yea:
                updated.userYeaCount = max(0, updated.userYeaCount - 1)
            case .nay:
                updated.userNayCount = max(0, updated.userNayCount - 1)
            case .abstain:
                break
            }
        }

        // Assign new vote and increment corresponding community count (abstain does not affect counts)
        updated.userVote = isCountedVote ? vote : nil
        switch vote {
        case .yea:
            updated.userYeaCount += 1
        case .nay:
            updated.userNayCount += 1
        case .abstain:
            break
        }

        updated.lastVotedAt = isCountedVote ? Date() : nil
        if let index {
            bills[index] = updated
        } else {
            bills.append(updated)
        }
        cacheBills(bills)

        let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guid, !guid.isEmpty else { return nil }

        // Sync to BillVoteStore so callers don't need to update both stores manually.
        let voteType: VoteType
        switch vote {
        case .yea: voteType = .yea
        case .nay: voteType = .nay
        case .abstain: voteType = .abstain
        }
        let store = voteStore
        let writeToken = UUID()
        latestVoteWrites[guid] = writeToken
        let billID = updated.id
        let preferencesService = preferencesService
        let syncTask = Task { [weak self] () -> VoteWriteResult in
            let result = await store?.submitVote(billId: guid, vote: voteType, reasons: reasons) ?? .notSaved
            self?.voteWriteEnded(guid: guid, billID: billID, token: writeToken, result: result)
            if result == .stored {
                Self.saveBillPreference(guid: guid, using: preferencesService)
            }
            return result
        }

        // Sync watch state to backend preferences (nil: the caller leaves watch alone).
        if let watch {
            if watch {
                userStore?.addWatch(guid: guid)
            } else {
                userStore?.removeWatch(guid: guid)
            }
        }

        return syncTask
    }

    /// Saves the `type=bill` preference row for a vote the server stored (best-effort, in its own task so
    /// the vote's result is not held up). The server follows a bill with that row: `userMatcher` sends the
    /// bill's alert pushes to users with a Bill or Watch row on it, and the weekly brief lists the bill
    /// under "You're watching this". So it is sent only once the vote is stored: a refused vote that rolls
    /// back must leave no follow (APPF-27), and neither does a vote whose outcome is unknown.
    ///
    /// Backend contract for Bills SetPreferences: preference is the bill guid (e.g. "BILLS-119hr900is"),
    /// type "bill" (the server stores it as "Bill"), and category must be "" (empty string).
    private static func saveBillPreference(guid: String, using preferencesService: any PreferencesServicing) {
        let billPreference = PreferencesItem(
            subCategory: nil,
            preference: guid,
            category: "",
            type: "bill"
        )
        Task {
            do {
                #if DEBUG
                print("[BillsStore] vote -> PUT /preferences type=bill category=\"\" preference=\(guid)")
                #endif
                try await preferencesService.putPreferences([billPreference])
                #if DEBUG
                print("[BillsStore] vote -> preferences sync success")
                #endif
            } catch {
                // Best-effort: ignore failures (offline / signed out / backend issues).
                #if DEBUG
                print("[BillsStore] vote -> preferences sync failed: \(PreferencesService.debugString(for: error))")
                #endif
            }
        }
    }

    /// A vote write recorded by `recordVote` ended. When the server refused the vote and the vote store
    /// rolled it back, the bill's vote goes back to the restored row too (APPF-27), unless a newer vote on
    /// the guid was recorded since (its own result decides). The Bills list, Updates, Search's Voted list
    /// and bill detail read these fields.
    func voteWriteEnded(guid: String, billID: UUID, token: UUID, result: VoteWriteResult) {
        guard latestVoteWrites[guid] == token else { return }
        latestVoteWrites[guid] = nil
        guard case .rolledBack(let restored) = result,
              let index = bills.firstIndex(where: { $0.id == billID }) else { return }

        var bill = bills[index]
        let restoredVote: UserVote?
        if case .voted(let voteType) = restored, voteType.countsAsVote {
            restoredVote = UserVote(voteType)
        } else {
            restoredVote = nil
        }
        // Undo the refused vote's local count and count the restored vote again (as `recordVote` counts).
        switch bill.userVote {
        case .yea?: bill.userYeaCount = max(0, bill.userYeaCount - 1)
        case .nay?: bill.userNayCount = max(0, bill.userNayCount - 1)
        case .abstain?, nil: break
        }
        switch restoredVote {
        case .yea?: bill.userYeaCount += 1
        case .nay?: bill.userNayCount += 1
        case .abstain?, nil: break
        }
        bill.userVoted = restoredVote != nil
        bill.userVote = restoredVote
        bill.lastVotedAt = restoredVote == nil ? nil : (voteStore?.heldVoteDate(for: guid) ?? bill.lastVotedAt)
        bills[index] = bill
        cacheBills(bills)
    }

    /// Cross-reference the connected BillVoteStore's persistent cache to mark
    /// bills as voted. Closes the gap on cold start where BillVoteCache knows
    /// about votes but Bill.userVoted is false.
    ///
    /// Scans `bills` without writing and assigns them once, only when a bill changes. Every write to
    /// `bills` rebuilds both bill lookups, even one that stores the same value, so a write per bill
    /// would take time quadratic in the number of bills.
    func reconcileVotesFromCache() {
        guard let voteStore else { return }
        func voteStateDiffers(_ bill: Bill, from previous: Bill) -> Bool {
            bill.userVoted != previous.userVoted
                || bill.userVote != previous.userVote
                || bill.lastVotedAt != previous.lastVotedAt
        }

        var reconciled: [(index: Int, bill: Bill)] = []
        var changed = false
        for index in bills.indices {
            let previous = bills[index]
            var bill = previous
            Self.normalizeAbstainVoteState(&bill)
            if !bill.userVoted,
               let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines),
               !guid.isEmpty {
                if voteStore.vote(for: guid).countsAsVote {
                    bill.userVoted = true
                }
                // Only a bill with a guid to look up counts toward saving the bills cache; one without
                // is still normalized above.
                changed = changed || voteStateDiffers(bill, from: previous)
            }
            if voteStateDiffers(bill, from: previous) {
                reconciled.append((index, bill))
            }
        }
        guard !reconciled.isEmpty else { return }

        var updated = bills
        for (index, bill) in reconciled {
            updated[index] = bill
        }
        bills = updated
        if changed {
            cacheBills(bills)
        }
    }

    /// Reconcile watched status bidirectionally between backend preferences and local cache.
    ///
    /// - Marks local bills as watched if the backend knows about them (new device / cross-device sync).
    /// - Backfills locally watched bills to the backend if they're missing (pre-existing watches
    ///   that were set before the Watch preference type existed).
    func reconcileWatchesFromProfile(_ watchedGUIDs: [String]) {
        let backendSet = Set(watchedGUIDs)
        var changed = false

        // 1) Backend → Local: mark bills as watched that the backend knows about.
        performActiveManifestBillsBatchUpdate {
            for i in bills.indices {
                guard let guid = bills[i].guid?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !guid.isEmpty else { continue }
                if backendSet.contains(guid) && !bills[i].userWatched {
                    bills[i].userWatched = true
                    changed = true
                }
            }
        }

        // 2) Local → Backend: find locally watched bills not yet in backend and push them up.
        var missingFromBackend: [String] = []
        for bill in bills {
            guard bill.userWatched,
                  let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !guid.isEmpty,
                  !backendSet.contains(guid) else { continue }
            missingFromBackend.append(guid)
        }

        if !missingFromBackend.isEmpty {
            if let userStore, userStore.canPerformUserWrites {
                // Do not roll back optimistic watch state on backfill failures.
                // Rolling back here causes a profile -> reconcile -> addWatch retry loop when
                // backend writes are forbidden (e.g., temporary auth/config mismatch).
                userStore.addWatches(guids: missingFromBackend, rollbackOnFailure: false)
                #if DEBUG
                print("[BillsStore] backfilled \(missingFromBackend.count) local watches to backend")
                #endif
            } else {
                #if DEBUG
                print("[BillsStore] skipped watch backfill; user writes are currently ineligible")
                #endif
            }
        }

        if changed {
            cacheBills(bills)
        }
    }

    // MARK: - Companion groups (APPF-23)

    /// The group's vote under the vote matrix, from the vote store and the cached bills, including
    /// rows stored under a legacy text-version guid of a member. `isVoted` is also true when a
    /// member's cached bill is marked voted.
    func companionVote(for group: BillCompanionGroup) -> CompanionVoteResolution {
        let resolution = CompanionGroupIndex.voteResolution(for: group) { member in
            heldVoteRow(member: member)
        }
        let billMarkedVoted = group.memberGuids.contains { member in
            loadedBills(ofMember: member).contains { $0.userVoted || $0.userVote?.countsAsVote == true }
        }
        guard billMarkedVoted, !resolution.isVoted else { return resolution }
        return CompanionVoteResolution(
            group: resolution.group,
            countedRow: resolution.countedRow,
            targetGuid: resolution.targetGuid,
            conflict: resolution.conflict,
            isVoted: true
        )
    }

    /// `companionVote(for:)` for the group of the bill with this id; nil when it is in no group.
    func companionVote(forBillID billID: UUID) -> CompanionVoteResolution? {
        companionGroup(forBillID: billID).map(companionVote(for:))
    }

    /// Where a vote on this bill, a change to it or its reasons go: the group's vote target, else the
    /// bill's own guid. Nil when the bill is not loaded and in no group.
    func voteTargetGUID(forBillID billID: UUID) -> String? {
        if let resolution = companionVote(forBillID: billID) { return resolution.targetGuid }
        return bill(for: billID)?.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the bill, or any member of its group, has a counted vote (in the vote store or on a
    /// cached bill).
    func isVoted(billID: UUID) -> Bool {
        if let resolution = companionVote(forBillID: billID) { return resolution.isVoted }
        guard let bill = bill(for: billID) else { return false }
        if bill.userVoted || bill.userVote?.countsAsVote == true { return true }
        guard let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty else { return false }
        return voteStore?.vote(for: guid).countsAsVote == true
    }

    /// True when the bill, or any member of its group, is watched.
    func isWatched(billID: UUID) -> Bool {
        if let group = companionGroup(forBillID: billID) {
            return group.memberGuids.contains { member in loadedBills(ofMember: member).contains(where: \.userWatched) }
        }
        return bill(for: billID)?.userWatched == true
    }

    /// Guids whose vote row is an Abstain, among `bills`: a bill's guid when the vote store holds an
    /// Abstain on it, and every member guid of a companion group whose counted row is an Abstain. The
    /// Skipped list leaves these out: an Abstain from bill detail also dismisses the bill, but it is a
    /// vote, not a skip (spec D 2.1.4).
    func abstainedGuids(in bills: [Bill]) -> Set<String> {
        guard let voteStore else { return [] }
        var guids = Set<String>()
        var checkedGroups = Set<String>()
        for bill in bills {
            if let group = companionGroupIndex.group(for: bill) {
                guard checkedGroups.insert(group.primaryGuid).inserted else { continue }
                if let row = companionVote(for: group).countedRow, row.vote == .abstain {
                    guids.formUnion(group.memberGuids)
                    guids.insert(row.guid)
                }
                continue
            }
            guard let guid = Self.trimmedOrNil(bill.guid), voteStore.heldVote(for: guid) == .abstain else { continue }
            guids.insert(guid)
        }
        return guids
    }

    /// Dismisses every bill the card stands for, on this device only (an abstain from bill detail, or
    /// a passed bill or alert opened from Bills and left). Never writes a vote. Returns the bills it
    /// dismissed that were not dismissed before (a refused Abstain puts them back, APPF-27).
    @discardableResult
    func dismiss(billID: UUID, readState: AppReadState) -> [UUID] {
        readState.dismissAllBills(companionMemberBillIDs(forBillID: billID))
    }

    /// True when every bill the card stands for is dismissed on this device (what
    /// `dismiss(billID:readState:)` does); false while any of them can still show on Bills.
    func isDismissed(billID: UUID, readState: AppReadState) -> Bool {
        let dismissed = readState.dismissedBillIDs
        return companionMemberBillIDs(forBillID: billID).allSatisfy(dismissed.contains)
    }

    /// The guids whose votes an "updated" push for `guid` clears (`BillVoteStore.clearVote(for:)` and
    /// `requireRevote(billID:)` on each), asking the user to vote again; empty when the push is
    /// information only. A bill in no group: `[guid]` (today's rule). A grouped bill: only when `guid`
    /// is the member holding the counted vote, and then every member's row, counted row first, so the
    /// other row does not become the counted one; an update to the other member leaves the vote.
    func revoteGUIDs(forUpdatedPushGUID guid: String) -> [String] {
        let cleaned = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        guard let group = companionGroupIndex.group(forGUID: cleaned) else { return [cleaned] }
        guard let counted = companionVote(for: group).countedRow,
              counted.memberGuid == companionGroupIndex.memberGuid(forGUID: cleaned) else { return [] }
        let otherRows = group.memberGuids.compactMap(heldVoteRow(member:)).map(\.guid).filter { $0 != counted.guid }
        return [counted.guid] + otherRows
    }

    /// The row the user holds on `member`: in the vote store under the member's guid, else on a loaded
    /// bill of the member (its guid in the vote store, then its cached vote).
    private func heldVoteRow(member: String) -> CompanionVoteRow? {
        if let vote = voteStore?.heldVote(for: member) {
            return CompanionVoteRow(memberGuid: member, guid: member, vote: vote)
        }
        for bill in loadedBills(ofMember: member) {
            guard let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty else { continue }
            if let vote = voteStore?.heldVote(for: guid) {
                return CompanionVoteRow(memberGuid: member, guid: guid, vote: vote)
            }
            if let userVote = bill.userVote {
                return CompanionVoteRow(memberGuid: member, guid: guid, vote: Self.voteType(for: userVote))
            }
        }
        return nil
    }

    nonisolated private static func voteType(for userVote: UserVote) -> VoteType {
        switch userVote {
        case .yea: return .yea
        case .nay: return .nay
        case .abstain: return .abstain
        }
    }

    func applyRevoteFlagsIfNeeded() {
        guard !requiresRevoteIDs.isEmpty else { return }
        performActiveManifestBillsBatchUpdate {
            for id in requiresRevoteIDs {
                applyRevoteFlagIfPresent(billID: id)
            }
        }
    }

    private func applyRevoteFlagIfPresent(billID: UUID) {
        guard let index = bills.firstIndex(where: { $0.id == billID }) else { return }
        // Keep watch state and backend history, but require a fresh local vote decision.
        bills[index].userVoted = false
        bills[index].userVote = nil
        bills[index].lastVotedAt = nil
    }
}

// MARK: - Skip and Clear (spec D 2.1.1-2.1.3)

/// What one skip on Bills, or one Clear on Updates, hides. A skip is never a vote.
enum SkipTarget: Equatable {
    /// A new or updated bill's card: every bill the card stands for is dismissed.
    case openBill(UUID)
    /// A Passed or Failed bill (a Bills card or an Updates row): dismissed now, and its watch is
    /// removed when the action commits (`commitSkip(_:)`), so Undo never has to re-add a watch.
    case closedBill(UUID)
    /// An Action in Congress alert: marked read and removed from `BillAlertsStore`.
    case alert(UUID)
}

/// What a skip or Clear changed on this device, so `restoreSkip(_:readState:alertsStore:)` can put
/// back exactly that and `commitSkip(_:)` can run the deferred unwatch. Holds no vote: none is written.
struct SkipReceipt: Equatable {
    /// Bills this action dismissed that were not dismissed before (every companion member).
    var dismissedBillIDs: [UUID] = []
    /// Alerts this action marked read that were unread before.
    var readAlertIDs: [UUID] = []
    /// Alerts this action removed, with their positions in `BillAlertsStore`.
    var removedAlerts: [RemovedBillAlert] = []
    /// Bills whose watch is removed when the action commits (Passed or Failed bills).
    var pendingUnwatchBillIDs: [UUID] = []

    /// One receipt for a batch (Clear all registers one undo record).
    mutating func append(_ other: SkipReceipt) {
        dismissedBillIDs += other.dismissedBillIDs.filter { !dismissedBillIDs.contains($0) }
        readAlertIDs += other.readAlertIDs.filter { !readAlertIDs.contains($0) }
        removedAlerts += other.removedAlerts
        pendingUnwatchBillIDs += other.pendingUnwatchBillIDs.filter { !pendingUnwatchBillIDs.contains($0) }
    }
}

extension BillsStore {
    /// Skips (Bills) or clears (Updates) `target` on this device and returns what changed. It never
    /// calls `vote(...)`, the vote store or the preferences service; a Passed or Failed bill's unwatch
    /// waits for `commitSkip(_:)`.
    @discardableResult
    func skip(_ target: SkipTarget, readState: AppReadState, alertsStore: BillAlertsStore? = nil) -> SkipReceipt {
        switch target {
        case .openBill(let billID):
            return SkipReceipt(dismissedBillIDs: readState.dismissAllBills(companionMemberBillIDs(forBillID: billID)))
        case .closedBill(let billID):
            return SkipReceipt(
                dismissedBillIDs: readState.dismissAllBills(companionMemberBillIDs(forBillID: billID)),
                pendingUnwatchBillIDs: [billID]
            )
        case .alert(let alertID):
            var receipt = SkipReceipt()
            if readState.markBillAlertRead(alertID) {
                receipt.readAlertIDs = [alertID]
            }
            if let removed = alertsStore?.remove(alertID) {
                receipt.removedAlerts = [removed]
            }
            return receipt
        }
    }

    /// Updates' Clear on a Passed or Failed row (spec D 2.1.3): every companion member is dismissed on
    /// this device, no vote is written (R1 wrote Abstain here), and the unwatch waits for the commit.
    @discardableResult
    func clearFromUpdates(billID: UUID, readState: AppReadState) -> SkipReceipt {
        skip(.closedBill(billID), readState: readState)
    }

    /// Updates' "Clear" on the Congress-action section: marks `readAlertIDs` read and removes every
    /// alert from the store (as before), returning what changed.
    @discardableResult
    func clearAllAlerts(markingRead readAlertIDs: [UUID], readState: AppReadState, alertsStore: BillAlertsStore) -> SkipReceipt {
        var receipt = SkipReceipt()
        receipt.readAlertIDs = readAlertIDs.filter { readState.markBillAlertRead($0) }
        receipt.removedAlerts = alertsStore.clearAll()
        return receipt
    }

    /// Undo: puts back exactly what `receipt` changed (dismissals, read flags, removed alerts). The
    /// lists are derived from that state, so each card or row returns to its place.
    func restoreSkip(_ receipt: SkipReceipt, readState: AppReadState, alertsStore: BillAlertsStore? = nil) {
        readState.undismissBills(receipt.dismissedBillIDs)
        readState.markBillAlertsUnread(receipt.readAlertIDs)
        alertsStore?.restore(receipt.removedAlerts)
    }

    /// Commit: runs the deferred side effects, which are the unwatches of Passed or Failed bills
    /// (one DELETE /preferences each, through `unwatch(billID:)`).
    func commitSkip(_ receipt: SkipReceipt) {
        for billID in receipt.pendingUnwatchBillIDs {
            unwatch(billID: billID)
        }
    }

    /// Skips or clears `targets` as one action and registers it with the undo center (4 s toast; only
    /// the latest action is undoable, and a new one commits the previous). `undoCenter` nil means
    /// `UndoCenter.shared`.
    @discardableResult
    func skipWithUndo(
        _ targets: [SkipTarget],
        message: SkipUndoMessage,
        readState: AppReadState,
        alertsStore: BillAlertsStore? = nil,
        undoCenter: UndoCenter? = nil
    ) -> SkipReceipt {
        // Commit the previous action before this one changes anything, so its commit never sees this
        // action's dismissals.
        let center = undoCenter ?? .shared
        center.commitPending()
        var receipt = SkipReceipt()
        for target in targets {
            receipt.append(skip(target, readState: readState, alertsStore: alertsStore))
        }
        registerUndo(for: receipt, message: message, readState: readState, alertsStore: alertsStore, undoCenter: center)
        return receipt
    }

    /// Registers `receipt` as the undoable action: Undo calls `restoreSkip`, commit calls `commitSkip`.
    func registerUndo(
        for receipt: SkipReceipt,
        message: SkipUndoMessage,
        readState: AppReadState,
        alertsStore: BillAlertsStore? = nil,
        undoCenter: UndoCenter? = nil
    ) {
        (undoCenter ?? .shared).register(UndoAction(
            message: message.text,
            accessibilityMessage: message.accessibilityText,
            undo: { [weak self, weak readState, weak alertsStore] in
                guard let self, let readState else { return }
                self.restoreSkip(receipt, readState: readState, alertsStore: alertsStore)
            },
            commit: { [weak self] in
                self?.commitSkip(receipt)
            }
        ))
    }
}
