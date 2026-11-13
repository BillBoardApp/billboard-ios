import Foundation

// MARK: - Linked bills (APPF-26)

/// Where a deep link, push or share link to a bill opens: the bill the detail screen shows, and the
/// guid it fetches from `GET /processed-bill` when that bill is not loaded (a bill outside the history
/// window that the user has neither voted on nor watched).
nonisolated struct BillLinkTarget: Hashable, Sendable {
    let billID: UUID
    let guid: String
}

/// The result of `BillsStore.loadLinkedBill(_:)`.
nonisolated enum LinkedBillLoad: Equatable, Sendable {
    /// The bill is in the store under `billID` (the target's id unless the API answered with another guid).
    case loaded(billID: UUID)
    /// The API reports no such bill (HTTP 404 for every locator `getProcessedBill` tries).
    case notFound
    /// The request failed for another reason; `message` is user-facing copy.
    case failed(message: String)
    /// The request was cancelled (the screen was left, or its task restarted). Nothing to report.
    case cancelled
}

extension BillsStore {
    /// The link target for `guid`: the companion group's primary when its bill is loaded, else the
    /// guid's own bill and id. Only the guid's own bill is fetched when missing; a group member opened
    /// on its own shows the group (APPF-23), as a loaded member does.
    func deepLinkTarget(forGUID guid: String) -> BillLinkTarget {
        let cleaned = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if let group = companionGroupIndex.group(forGUID: cleaned),
           let primary = loadedBills(ofMember: group.primaryGuid).first {
            let primaryGuid = Self.trimmedOrNil(primary.guid) ?? group.primaryGuid
            return BillLinkTarget(billID: primary.id, guid: primaryGuid)
        }
        return BillLinkTarget(billID: UUID.deterministic(from: cleaned), guid: cleaned)
    }

    /// The link target of a tapped push for `guids`: `deepLinkTarget(forGUID:)` of the first guid when
    /// the push names one bill, or only members of one companion group; nil when it names several bills
    /// (the Board tab opens).
    func pushDeepLinkTarget(forGUIDs guids: [String]) -> BillLinkTarget? {
        let cleaned = guids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = cleaned.first else { return nil }
        if cleaned.count > 1 {
            guard let group = companionGroupIndex.group(forGUID: first),
                  cleaned.allSatisfy({ companionGroupIndex.group(forGUID: $0) == group }) else { return nil }
        }
        return deepLinkTarget(forGUID: first)
    }

    /// Makes the linked bill available to the detail screen: the loaded bill when the store has it,
    /// else the processed bill fetched with the store's service (the same `GET /processed-bill` call as
    /// `ensureHydrated`, locator derived from the guid) and merged in with `upsertProcessedBill`, as
    /// the screen already does for a companion bill it fetches. Like any bill outside the history
    /// window, a later manifest load drops it unless it is voted or watched; the screen keeps its copy
    /// (and re-adds it to vote, `billIDForVoting`).
    ///
    /// A link with a legacy text-version guid (`BILLS-119hr6512ih`) opens the loaded bill of the same
    /// congress, type and number with the plain guid (manifest loads keep the plain guid), and a
    /// fetched bill keeps the guid of the bill the API answered with: the guid is the bill's vote
    /// identity. A link never opens a loaded legacy bill under another guid than its own.
    ///
    /// Only an HTTP 404 is `.notFound`; any other failure is `.failed` (the screen offers Retry), and
    /// a cancelled request is `.cancelled` (APPF-22).
    func loadLinkedBill(_ target: BillLinkTarget) async -> LinkedBillLoad {
        await restoreCachedStateIfNeeded()
        if let loaded = bill(for: target.billID) { return .loaded(billID: loaded.id) }
        let guid = target.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guid.isEmpty else { return .notFound }
        if let loaded = bill(forGUID: guid) ?? loadedBill(sameBillAs: guid) { return .loaded(billID: loaded.id) }

        do {
            var processed = try await service.getProcessedBill(guid: guid, congress: nil, billType: nil, billID: nil)
            processed.guid = answeredGuid(of: processed, requested: guid)
            // The bill may have been loaded while the request was in flight (a manifest load, another
            // screen); `upsertProcessedBill` merges into it, keeping the user's vote and watch.
            upsertProcessedBill(processed)
            return .loaded(billID: processed.id)
        } catch {
            if APIErrorResponse.isCancellation(error) { return .cancelled }
            if APIErrorDebug.httpStatusCode(from: error) == 404 { return .notFound }
            #if DEBUG
            print("[BillsStore] loadLinkedBill FAILED guid=\(guid) error=\(APIErrorDebug.debugString(for: error))")
            #endif
            return .failed(message: UserFacingLoadError.message(for: error, loading: "this bill"))
        }
    }

    /// The loaded bill with the congress, type and number of `guid` and a plain guid; nil when the guid
    /// has no locator or no such bill is loaded. A legacy text-version bill of it is never one: its
    /// guid is its vote identity, so a link is fetched (and opens the plain bill) instead.
    private func loadedBill(sameBillAs guid: String) -> Bill? {
        guard let key = Self.billIdentityKey(congress: nil, billType: nil, billID: nil, guid: guid) else { return nil }
        return bills.first {
            $0.guid?.last?.isNumber == true
                && Self.billIdentityKey(congress: $0.congress, billType: $0.billType, billID: $0.billID, guid: $0.guid) == key
        }
    }

    /// The guid of the bill `GET /processed-bill` answered for `requested`. `BillsService` keeps the
    /// requested guid on the bill but takes its id from the answered guid, and the API answers a
    /// legacy text-version guid with the plain bill (the locator fallback). For a bill answered under
    /// another id: the plain guid when the id is its, else the loaded bill's guid; else unchanged.
    private func answeredGuid(of processed: Bill, requested: String) -> String? {
        guard processed.id != UUID.deterministic(from: requested) else { return processed.guid }
        if let locator = BillsService.deriveLocator(from: requested) {
            let plain = "BILLS-\(locator.congress)\(locator.billType)\(locator.billID)"
            if UUID.deterministic(from: plain) == processed.id { return plain }
        }
        return Self.trimmedOrNil(bill(for: processed.id)?.guid) ?? processed.guid
    }
}
