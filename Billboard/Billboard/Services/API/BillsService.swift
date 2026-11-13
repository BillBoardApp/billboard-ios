import Foundation

enum BillsService {
    private enum Paths {
        static let processedBill = "processed-bill"
    }

    /// Fetches the bills manifest and caches it in `BillsManifestCache.current`.
    /// - Parameter updatedAfter: When provided, only bills updated after this date are returned (windowed).
    ///   When nil, the full manifest is returned, through the snapshot delivery when the API offers one
    ///   (see `fetchBillsManifest(updatedAfter:)`).
    ///
    /// Runs off the main actor (`@concurrent`): the full manifest runs to tens of thousands of items, and
    /// decoding, merging and caching them on the main actor stalled the UI. Only the API request itself
    /// hops to the main actor (Amplify). It is not a detached task, so the task-local
    /// `APIClient.current`, `BillsManifestSnapshotClient.current` and `BillsManifestCache.current` still apply.
    @concurrent
    nonisolated static func getBillsManifest(updatedAfter: Date? = nil) async throws -> [BillsManifestItem] {
        guard let fetched = try await fetchBillsManifest(updatedAfter: updatedAfter) else { return [] }

        // A windowed fetch keeps a full copy full only when its window reaches back to the copy's last write.
        BillsManifestCache.current.store(fetched.items, fetched: updatedAfter.map { .windowed(updatedAfter: $0) } ?? .full)
        // Companion groups (APPF-23): every response lists all of them, so its list replaces the cached
        // one (`[]` clears it); a response without the field keeps the cached list.
        if let groups = fetched.companionGroups {
            BillsManifestCache.current.storeCompanionGroups(groups)
        }
        HomePerfTimeline.mark(
            "manifest_cache_write_completed",
            detail: "source=\(fetched.source) count=\(fetched.items.count)"
        )
        return fetched.items
    }

    nonisolated static func cachedBillsManifest() -> [BillsManifestItem]? {
        BillsManifestCache.current.items()
    }

    /// The companion groups of the latest manifest response that listed them (APPF-23); nil when none has.
    nonisolated static func cachedCompanionGroups() -> [BillCompanionGroup]? {
        BillsManifestCache.current.companionGroups()
    }

    /// Returns the cached manifest only if it is within `maxAge` seconds.
    /// Use this to avoid network refreshes when the cache is still fresh.
    nonisolated static func cachedBillsManifest(maxAge: TimeInterval) -> [BillsManifestItem]? {
        guard cachedBillsManifestIsFresh(maxAge: maxAge) else { return nil }
        return cachedBillsManifest()
    }

    nonisolated static func cachedBillsManifestIsFresh(maxAge: TimeInterval) -> Bool {
        BillsManifestCache.current.isFresh(maxAge: maxAge)
    }

    /// True when the cached manifest holds every bill (the last full fetch, kept current by windowed ones
    /// that left no gap; `BillsManifestCache`).
    nonisolated static func cachedBillsManifestIsFull() -> Bool {
        BillsManifestCache.current.coverage() == .full
    }

    nonisolated static func cachedBillsManifestIsFull(maxAge: TimeInterval) -> Bool {
        guard cachedBillsManifestIsFresh(maxAge: maxAge) else { return false }
        return cachedBillsManifestIsFull()
    }

    static func getProcessedBill(
        guid: String,
        congress: String? = nil,
        billType: String? = nil,
        billID: String? = nil
    ) async throws -> Bill {
        let normalizedGuid = guid.trimmingCharacters(in: .whitespacesAndNewlines)

        // If caller doesn't have locator fields, attempt to derive them from our guid format.
        // Example: BILLS-119hjres131eh -> congress=119, type=hjres, bill_id=131
        let derived = deriveLocator(from: normalizedGuid)
        let congressToUse = (congress?.isEmpty == false) ? congress : derived?.congress
        let billTypeToUse = (billType?.isEmpty == false) ? billType : derived?.billType
        let billIDToUse = (billID?.isEmpty == false) ? billID : derived?.billID

        #if DEBUG
        if derived != nil, congress == nil || billType == nil || billID == nil {
            print("[BillsService] derived locator from guid=\(normalizedGuid) -> congress=\(congressToUse ?? "(nil)") type=\(billTypeToUse ?? "(nil)") bill_id=\(billIDToUse ?? "(nil)")")
        }
        #endif

        // NOTE: The API Gateway/Lambda contract is:
        //   GET /processed-bill?guid=...&congress=...&type=...&bill_id=...
        // The response body is the processed bill itself (`ProcessedBillV1`); `APIClient` unwraps a
        // proxy `{"body": ...}` envelope if one reaches the app.
        //
        // Also: RESTRequest is responsible for query encoding; do not pre-encode values.
        var lastError: Error?
        let candidates: [[String: String]] = {
            var list: [[String: String]] = []

            // Most specific first (helps hit getByGuidWithLocator when data is partitioned).
            if let congressToUse, !congressToUse.isEmpty, let billTypeToUse, !billTypeToUse.isEmpty {
                list.append(["guid": normalizedGuid, "congress": congressToUse, "type": billTypeToUse])
            }

            // Guid-only baseline.
            list.append(["guid": normalizedGuid])

            // Locator-only (no guid) path in Lambda: congress/type/bill_id.
            if let congressToUse, !congressToUse.isEmpty,
               let billTypeToUse, !billTypeToUse.isEmpty,
               let billIDToUse, !billIDToUse.isEmpty {
                list.append(["congress": congressToUse, "type": billTypeToUse, "bill_id": billIDToUse])
            }

            return list
        }()

        for query in candidates {
            do {
                let data = try await APIClient.current.payload(
                    .get,
                    Paths.processedBill,
                    query: query,
                    label: "BillsService processed-bill",
                    authMode: .autoFetch
                )
                guard !data.isEmpty else { throw APIServiceError.invalidPayload(Paths.processedBill) }
                var bill = try decodeProcessedBill(from: data, guid: normalizedGuid)
                bill.guid = normalizedGuid
                bill.congress = congressToUse
                bill.billType = billTypeToUse
                bill.billID = billIDToUse
                return bill
            } catch {
                lastError = error
                if APIErrorDebug.httpStatusCode(from: error) == 404 {
                    continue
                }
                throw error
            }
        }

        throw lastError ?? APIServiceError.invalidPayload(Paths.processedBill)
    }

    /// The bill in a `GET /processed-bill` payload, decoded as the generated
    /// `UserAPIContractsV1.ProcessedBill` (CON-03). A payload the contract rejects is logged by
    /// `APIDecoding` (type, coding path, reason, and the requested `guid`, so the log names the bill),
    /// and surfaces as `APIServiceError.invalidPayload("processed-bill")`.
    static func decodeProcessedBill(from data: Data, guid: String? = nil) throws -> Bill {
        do {
            let dto = try APIDecoding.decode(
                UserAPIContractsV1.ProcessedBill.self,
                from: data,
                decoder: .convertingFromSnakeCase(dates: .iso8601),
                label: processedBillLogLabel(guid: guid)
            )
            return processedBill(from: dto)
        } catch {
            throw APIServiceError.invalidPayload(Paths.processedBill)
        }
    }

    /// The log label of a processed-bill decode: the requested guid when there is one.
    static func processedBillLogLabel(guid: String?) -> String {
        guard let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty else {
            return "BillsService processed-bill"
        }
        return "BillsService processed-bill guid=\(guid)"
    }

    nonisolated struct Locator: Sendable {
        let congress: String
        let billType: String
        let billID: String
    }

    /// The congress, type and number in a GovInfo bill guid (`BILLS-119hjres131eh`), or nil for any
    /// other guid. Nonisolated: manifest deduplication runs off the main actor.
    nonisolated static func deriveLocator(from guid: String) -> Locator? {
        let trimmed = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("BILLS-") else { return nil }
        let rest = String(trimmed.dropFirst("BILLS-".count))

        // Expected: <digits><letters><digits><optional trailing letters>
        // ex: 119hjres131eh
        let pattern = "^(\\d+)([A-Za-z]+)(\\d+)([A-Za-z]*)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(rest.startIndex..<rest.endIndex, in: rest)
        guard let match = regex.firstMatch(in: rest, options: [], range: range), match.numberOfRanges >= 4 else { return nil }

        func group(_ idx: Int) -> String? {
            let r = match.range(at: idx)
            guard r.location != NSNotFound, let sr = Range(r, in: rest) else { return nil }
            return String(rest[sr])
        }

        guard let congress = group(1), !congress.isEmpty,
              let type = group(2), !type.isEmpty,
              let billID = group(3), !billID.isEmpty else { return nil }

        return Locator(congress: congress, billType: type.lowercased(), billID: billID)
    }
}

// MARK: - Processed-bill mapping

extension BillsService {
    /// The bill in a processed-bill payload. Its topic labels are read under their current names
    /// (LLM-10): a bill stored before the label switch may still carry a legacy name.
    private static func processedBill(from dto: UserAPIContractsV1.ProcessedBill) -> Bill {
        let subCategories = SubscriptionsConfig.canonicalTopics(dto.subCategories)
        let subCategory = subCategories.first

        return Bill(
            id: UUID.deterministic(from: dto.guid),
            title: dto.title,
            officialTitle: dto.officialTitle,
            category: processedBillCategory(guid: dto.guid, subCategories: subCategories),
            subCategory: subCategory,
            summary: dto.summary ?? "",
            soWhat: dto.soWhat,
            billBreakdown: BillBreakdown(dto: dto.billBreakdown),
            storedAt: dto.storedAt,
            link: dto.link,
            actions: dto.actions?.map(Bill.BillAction.init(dto:)) ?? [],
            committees: dto.committees?.map(Bill.BillCommittee.init(dto:)) ?? [],
            lifeAreas: dto.lifeAreas,
            billStatus: processedBillStatus(dto.billStatus),
            sponsorMemberID: dto.sponsors.first.map { UUID.deterministic(from: $0) },
            relatedMemberIDs: processedBillMemberIDs(sponsors: dto.sponsors, cosponsors: dto.cosponsors),
            userVoted: false,
            userWatched: false,
            isPriority: dto.isPriority ?? false,
            priorityRank: dto.priorityRank,
            priorityReason: dto.priorityReason,
            priorityExpiresAt: dto.priorityExpiresAt,
            officialVotes: dto.officialVotes.map(Bill.OfficialVotesBreakdown.init(dto:)),
            isProcessedDetailHydrated: true
        )
    }

    /// Category group for the bill's first sub-category, else that sub-category, else "Other".
    /// Expects current topic names (`SubscriptionsConfig.subcategoryGroups` lists only those).
    private static func processedBillCategory(guid: String, subCategories: [String]) -> String {
        let subCategory = subCategories.first
        let mappedCategory = SubscriptionsConfig.subcategoryGroups
            .first(where: { group in
                guard let subCategory else { return false }
                return group.value.contains(subCategory)
            })?.key

        #if DEBUG
        print("[BillsService] processed-bill mapped guid=\(guid) subCategories=\(subCategories) -> category=\(mappedCategory ?? "(nil)") subCategory=\(subCategory ?? "(nil)")")
        #endif

        return mappedCategory ?? (subCategory ?? "Other")
    }

    private static func processedBillStatus(_ rawStatus: String?) -> BillStatus {
        let raw = (rawStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.contains("final") { return .finalized }
        if raw.contains("fail") { return .failed }
        if raw.contains("pass") { return .passed }
        if raw.contains("update") { return .updated }
        if raw.contains("new") { return .new }
        return .new
    }

    private static func processedBillMemberIDs(sponsors: [String], cosponsors: [String]) -> [UUID]? {
        let relatedMemberIDs = BillsManifestCache.canonicalizedValues(sponsors + cosponsors)
            .map { UUID.deterministic(from: $0) }
        return relatedMemberIDs.isEmpty ? nil : relatedMemberIDs
    }
}
