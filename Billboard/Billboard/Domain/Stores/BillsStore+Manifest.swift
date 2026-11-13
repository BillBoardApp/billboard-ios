import Foundation

// MARK: - Manifest normalization

extension BillsStore {
    /// One bill: its congress, bill type (normalized, so `house-bill` and `hr` match) and number.
    nonisolated struct BillIdentityKey: Hashable, Sendable {
        let congress: String
        let billType: String
        let billNumber: String

        /// The key as one string ("119|hr|900"), for sets of keys such as the vote identity index.
        var stringValue: String { "\(congress)|\(billType)|\(billNumber)" }
    }

    /// Congress.gov API type slugs the manifest sometimes carries instead of the type code.
    nonisolated private static let billTypeCodesBySlug: [String: String] = [
        "house-bill": "hr",
        "senate-bill": "s",
        "house-resolution": "hres",
        "senate-resolution": "sres",
        "house-joint-resolution": "hjres",
        "senate-joint-resolution": "sjres",
        "house-concurrent-resolution": "hconres",
        "senate-concurrent-resolution": "sconres"
    ]

    /// Deduplicate manifest items by guid, then merge the items of the same bill.
    ///
    /// The manifest can list one bill more than once: next to its current guid it keeps legacy guids
    /// with a GovInfo text-version suffix (`BILLS-119hr6512ih` next to `BILLS-119hr6512`), sometimes
    /// with the Congress.gov type slug (`house-bill`) instead of the type code (`hr`). Items with the
    /// same congress, normalized bill type and number are one bill: the unsuffixed guid is kept (else
    /// the guid that sorts first) and the text-version duplicate's sponsors, categories and priority
    /// are merged in. Life areas are the kept row's alone, an empty list included (UX-29, project default of
    /// 2026-10-29: the current row's life areas win over an older text-version row's), as a manifest row
    /// replaces a bill's (`IncomingBillSource.manifestRow`): a union kept a life area the server had
    /// taken off the current row, such as Medical Costs on H.Res. 1187 from `BILLS-119hres1187ih`.
    ///
    /// Bills of different types or numbers are never merged, even with the same number (H.R. 4500 and
    /// S. 4500 are different bills) or the same generated title. An item missing its congress, type or
    /// number takes it from its guid (`BillsService.deriveLocator`); one whose guid is not a GovInfo
    /// bill guid either passes through untouched.
    ///
    /// Companion bills (APPF-23: H.R. 900 and S. 456, identical bills in both chambers) are distinct
    /// bills and are never merged here: each keeps its item and its bill, and `CompanionGroupIndex`
    /// groups them for the surfaces that show one card.
    ///
    /// Topic labels come out under their current names (LLM-10, `canonicalizedTopicValues`), so a
    /// manifest or a manifest cache written before the label switch matches and shows new names.
    nonisolated static func deduplicateManifest(_ items: [BillsManifestItem]) -> [BillsManifestItem] {
        // Step 1: exact-guid dedup (cheap, handles manifest-merge duplicates).
        var seenGuids = Set<String>()
        let guidDeduped = items
            .filter { seenGuids.insert($0.guid).inserted }
            .map { canonicalManifestItem($0) }

        // Step 2: merge the items of one bill.
        var bestByKey: [BillIdentityKey: BillsManifestItem] = [:]
        var result: [BillsManifestItem] = []
        result.reserveCapacity(guidDeduped.count)
        var mergeCount = 0

        for item in guidDeduped {
            guard let key = billIdentityKey(congress: item.congress, billType: item.billType, billID: item.billID, guid: item.guid) else {
                result.append(item)
                continue
            }

            if let existing = bestByKey[key] {
                // `duplicate` is a text-version duplicate of the same bill, not a companion bill.
                let (keeper, duplicate) = prefersAsKeeper(item.guid, over: existing.guid) ? (item, existing) : (existing, item)
                bestByKey[key] = BillsManifestItem(
                    guid: keeper.guid,
                    congress: trimmedOrNil(keeper.congress) ?? duplicate.congress,
                    billType: trimmedOrNil(keeper.billType) ?? duplicate.billType,
                    billID: trimmedOrNil(keeper.billID) ?? duplicate.billID,
                    updatedAt: [keeper.updatedAt, duplicate.updatedAt].compactMap { $0 }.max(),
                    subCategories: canonicalizedTopicValues(keeper.subCategories + duplicate.subCategories),
                    lifeAreas: canonicalizedValues(keeper.lifeAreas),
                    sponsors: canonicalizedValues(keeper.sponsors + duplicate.sponsors),
                    cosponsors: canonicalizedValues(keeper.cosponsors + duplicate.cosponsors),
                    isPriority: keeper.isPriority == true || duplicate.isPriority == true,
                    priorityRank: [keeper.priorityRank, duplicate.priorityRank].compactMap { $0 }.min(),
                    priorityReason: keeper.priorityReason ?? duplicate.priorityReason,
                    priorityExpiresAt: keeper.priorityExpiresAt ?? duplicate.priorityExpiresAt,
                    title: keeper.title,
                    billStatus: keeper.billStatus ?? duplicate.billStatus,
                    civicProfile: keeper.civicProfile ?? duplicate.civicProfile
                )
                mergeCount += 1
            } else {
                bestByKey[key] = item
            }
        }

        // Append the merged bills in their original relative order.
        var emittedKeys = Set<BillIdentityKey>()
        for item in guidDeduped {
            guard let key = billIdentityKey(congress: item.congress, billType: item.billType, billID: item.billID, guid: item.guid),
                  emittedKeys.insert(key).inserted,
                  let merged = bestByKey[key] else { continue }
            result.append(merged)
        }

        // There is no title-based merge any more: generated titles are not unique, so it merged
        // distinct bills, and restricted to one bill it would repeat the merge above.

        #if DEBUG
        if mergeCount > 0 {
            print("[BillsStore] deduplicateManifest merged \(mergeCount) duplicate bill items from \(guidDeduped.count) manifest items")
        }
        #endif

        return result
    }

    /// The bill an item or bill describes, or nil when its congress, type or number is missing and
    /// `guid` does not supply it. A missing field is taken from the guid (`BILLS-119hr6512ih` is
    /// congress 119, type hr, number 6512), so an item without them still matches its complete twin.
    nonisolated static func billIdentityKey(
        congress: String?,
        billType: String?,
        billID: String?,
        guid: String? = nil
    ) -> BillIdentityKey? {
        var congress = normalizedNumber(congress)
        var billType = normalizedBillType(billType)
        var billNumber = normalizedNumber(billID)
        if congress == nil || billType == nil || billNumber == nil,
           let guid, let locator = BillsService.deriveLocator(from: guid) {
            congress = congress ?? normalizedNumber(locator.congress)
            billType = billType ?? normalizedBillType(locator.billType)
            billNumber = billNumber ?? normalizedNumber(locator.billID)
        }
        guard let congress, let billType, let billNumber else { return nil }
        return BillIdentityKey(congress: congress, billType: billType, billNumber: billNumber)
    }

    /// The Congress.gov type code (`hr`, `s`, `hjres`, ...) for a type code in any case, a citation
    /// such as `H.R.`, or a Congress.gov slug such as `house-bill`; nil when empty.
    nonisolated static func normalizedBillType(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let code = billTypeCodesBySlug[trimmed] { return code }
        let letters = trimmed.filter { $0.isASCII && $0.isLetter }
        return letters.isEmpty ? nil : letters
    }

    /// A trimmed congress or bill number without leading zeros; nil when empty.
    nonisolated private static func normalizedNumber(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(trimmed) { return String(number) }
        return trimmed
    }

    /// Which of two guids of one bill to keep: the one without a GovInfo text-version suffix (it ends
    /// in the bill number), else the one that sorts first.
    nonisolated private static func prefersAsKeeper(_ candidate: String, over current: String) -> Bool {
        let candidateIsSuffixed = candidate.last?.isLetter == true
        let currentIsSuffixed = current.last?.isLetter == true
        if candidateIsSuffixed != currentIsSuffixed { return !candidateIsSuffixed }
        return candidate < current
    }

    nonisolated static func canonicalizedValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            unique.append(cleaned)
        }

        return unique.sorted { lhs, rhs in
            let cmp = lhs.localizedCaseInsensitiveCompare(rhs)
            if cmp == .orderedSame { return lhs < rhs }
            return cmp == .orderedAscending
        }
    }

    /// `canonicalizedValues` of topic labels with each legacy name replaced by its current one
    /// (`SubscriptionsConfig.canonicalTopic`), so a list holding both names keeps one (LLM-10).
    nonisolated static func canonicalizedTopicValues(_ values: [String]) -> [String] {
        canonicalizedValues(values.map(SubscriptionsConfig.canonicalTopic))
    }

    nonisolated private static func canonicalManifestItem(_ item: BillsManifestItem) -> BillsManifestItem {
        BillsManifestItem(
            guid: item.guid,
            congress: item.congress?.trimmingCharacters(in: .whitespacesAndNewlines),
            billType: item.billType?.trimmingCharacters(in: .whitespacesAndNewlines),
            billID: item.billID?.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: item.updatedAt?.trimmingCharacters(in: .whitespacesAndNewlines),
            subCategories: canonicalizedTopicValues(item.subCategories),
            lifeAreas: canonicalizedValues(item.lifeAreas),
            sponsors: canonicalizedValues(item.sponsors),
            cosponsors: canonicalizedValues(item.cosponsors),
            isPriority: item.isPriority,
            priorityRank: item.priorityRank,
            priorityReason: item.priorityReason?.trimmingCharacters(in: .whitespacesAndNewlines),
            priorityExpiresAt: item.priorityExpiresAt?.trimmingCharacters(in: .whitespacesAndNewlines),
            title: item.title,
            billStatus: item.billStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
            civicProfile: item.civicProfile
        )
    }

    /// A fetched manifest normalized for `load`, off the main actor.
    nonisolated struct ManifestUpdate: Sendable {
        nonisolated struct Changes: Sendable {
            let preparedEntries: [ManifestEntry]
            /// The entries inside the history window.
            let visibleEntries: [ManifestEntry]
            /// The visible entries' placeholder bills merged with the existing bills.
            let mergedBills: [Bill]
            let resolvedActiveManifestBills: [Bill]
        }

        /// The deduplicated manifest.
        let manifest: [BillsManifestItem]
        /// The companion groups (APPF-23) to use with it.
        let companionIndex: CompanionGroupIndex
        /// Nil when the manifest and its groups are equivalent to the ones the store has.
        let changes: Changes?
    }

    /// Deduplicates `fetched` and, unless it and `companionGroups` match `current` and
    /// `currentCompanionIndex`, builds its entries and merges their placeholder bills into
    /// `existingBills`. The visible entries include each visible grouped bill's partners, so a group's
    /// card has its primary's bill even when only the other member is in the window. Pure, so `load`
    /// runs it off the main actor.
    nonisolated static func manifestUpdate(
        for fetched: [BillsManifestItem],
        companionGroups: [BillCompanionGroup] = [],
        replacing current: [BillsManifestItem],
        currentCompanionIndex: CompanionGroupIndex = .empty,
        existingBills: [Bill],
        historyWindow: BillboardHistoryWindow
    ) -> ManifestUpdate {
        let manifest = deduplicateManifest(fetched)
        let companionIndex = CompanionGroupIndex(groups: companionGroups)
        guard !manifestsAreEquivalent(manifest, current, lhsGroups: companionIndex, rhsGroups: currentCompanionIndex) else {
            return ManifestUpdate(manifest: manifest, companionIndex: companionIndex, changes: nil)
        }

        let preparedEntries = preparedManifestEntries(from: manifest)
        let visibleEntries = visibleManifestEntries(
            from: preparedEntries,
            historyWindow: historyWindow,
            companions: companionIndex
        )
        let mergedBills = mergeIncomingBillsPreservingProtected(
            visibleEntries.map(\.placeholderBill),
            existing: existingBills,
            source: .manifestRow
        )
        let resolvedActiveManifestBills = resolveManifestBills(
            manifestEntries: visibleEntries,
            billsByGuid: makeBillLookupByGuid(from: mergedBills),
            billsByID: makeBillLookupByID(from: mergedBills)
        )
        return ManifestUpdate(
            manifest: manifest,
            companionIndex: companionIndex,
            changes: ManifestUpdate.Changes(
                preparedEntries: preparedEntries,
                visibleEntries: visibleEntries,
                mergedBills: mergedBills,
                resolvedActiveManifestBills: resolvedActiveManifestBills
            )
        )
    }

    nonisolated static func preparedManifestEntries(from items: [BillsManifestItem]) -> [ManifestEntry] {
        items.map { item in
            ManifestEntry(
                item: item,
                updatedAtDate: FlexibleISO8601.parse(item.updatedAt),
                placeholderBill: placeholderBill(from: item)
            )
        }
    }

    /// True when the manifests list the same items with the same fields and, when given, the same
    /// companion groups: a change to the groups alone is a change (APPF-23).
    nonisolated static func manifestsAreEquivalent(
        _ lhs: [BillsManifestItem],
        _ rhs: [BillsManifestItem],
        lhsGroups: CompanionGroupIndex = .empty,
        rhsGroups: CompanionGroupIndex = .empty
    ) -> Bool {
        guard lhs.count == rhs.count, lhsGroups == rhsGroups else { return false }

        for (left, right) in zip(lhs, rhs) {
            guard left.guid == right.guid,
                  left.congress == right.congress,
                  left.billType == right.billType,
                  left.billID == right.billID,
                  left.updatedAt == right.updatedAt,
                  left.subCategories == right.subCategories,
                  left.lifeAreas == right.lifeAreas,
                  left.sponsors == right.sponsors,
                  left.cosponsors == right.cosponsors,
                  left.isPriority == right.isPriority,
                  left.priorityRank == right.priorityRank,
                  left.priorityReason == right.priorityReason,
                  left.priorityExpiresAt == right.priorityExpiresAt,
                  left.title == right.title,
                  left.billStatus == right.billStatus,
                  left.civicProfile == right.civicProfile else {
                return false
            }
        }

        return true
    }

    /// The bill a manifest item stands for until its processed bill is loaded. Its topic is the item's
    /// first label under its current name (LLM-10), also for an item that did not pass through
    /// `deduplicateManifest`.
    nonisolated static func placeholderBill(from item: BillsManifestItem) -> Bill {
        let id = UUID.deterministic(from: item.guid)

        let subCategories = canonicalizedTopicValues(item.subCategories)
        let lifeAreas = canonicalizedValues(item.lifeAreas)
        let sponsors = canonicalizedValues(item.sponsors)
        let cosponsors = canonicalizedValues(item.cosponsors)

        let subCategory = subCategories.first
        let mappedCategory = categoryForManifestSubcategory(subCategory)

        let sponsorMemberID = sponsors.first.map { UUID.deterministic(from: $0) }
        let relatedMemberIDs = memberIDs(from: sponsors + cosponsors)

        return Bill(
            id: id,
            title: item.title,
            category: mappedCategory ?? (subCategory ?? "Other"),
            subCategory: subCategory,
            summary: "",
            soWhat: "",
            storedAt: item.updatedAt,
            lifeAreas: lifeAreas,
            billStatus: BillStatus(rawValue: item.billStatus ?? "") ?? .new,
            guid: item.guid,
            congress: item.congress,
            billType: item.billType,
            billID: item.billID,
            sponsorMemberID: sponsorMemberID,
            relatedMemberIDs: relatedMemberIDs,
            userVoted: false,
            userWatched: false,
            isPriority: item.isPriority ?? false,
            priorityRank: item.priorityRank,
            priorityReason: item.priorityReason,
            priorityExpiresAt: item.priorityExpiresAt,
            isProcessedDetailHydrated: false
        )
    }

    /// The topic group of a topic. Lists the legacy names next to their new ones (LLM-10) so a caller
    /// that did not canonicalize still gets the group; must agree with `SubscriptionsConfig.subcategoryGroups`.
    nonisolated private static func categoryForManifestSubcategory(_ subCategory: String?) -> String? {
        guard let subCategory = trimmedOrNil(subCategory) else { return nil }

        switch subCategory {
        case "Fiscal Policy",
            "Monetary Policy",
            "Labor and Employment",
            "Trade and Globalization",
            "Social Welfare":
            return "Economic Policy"
        case "Healthcare",
            "Education",
            "Housing",
            "Civil Rights and Liberties",
            "Social Justice", // legacy name of "Civil Rights and Liberties"
            "Family and Gender Policy":
            return "Social Policy"
        case "Climate Change",
            "Energy",
            "Conservation and Natural Resources",
            "Pollution Control":
            return "Environmental and Energy Policy"
        case "Diplomacy",
            "Military and Defense",
            "Trade and Sanctions",
            "Immigration and Border Control",
            "Humanitarian Intervention":
            return "Foreign Policy and Defense"
        case "Constitutional and Legal Issues",
            "Elections and Voting",
            "Transparency and Accountability",
            "Local vs. Federal Power":
            return "Governance and Institutional Policy"
        case "Technology Regulation",
            "Transportation",
            "Research and Innovation",
            "Telecommunications":
            return "Science, Technology, and Infrastructure"
        case "Religion and State",
            "Heritage and Identity",
            "Identity Politics", // legacy name of "Heritage and Identity"
            "Freedom of Speech and Press",
            "Ethics in Policy":
            return "Cultural and Ethical Issues"
        default:
            return nil
        }
    }

    nonisolated private static func memberIDs(from rawMemberIDs: [String]) -> [UUID]? {
        let ids = canonicalizedValues(rawMemberIDs).map { UUID.deterministic(from: $0) }
        return ids.isEmpty ? nil : ids
    }
}
