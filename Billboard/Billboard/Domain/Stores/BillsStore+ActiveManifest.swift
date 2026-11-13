import Foundation

// MARK: - Active manifest bills

extension BillsStore {
    /// The entries updated inside the history window, then (APPF-23) the entries of their companion
    /// partners that are outside it, so a group's card can use its primary's bill when only the other
    /// member moved. Home still shows a group only when a member is in the window. With no groups this
    /// is the window filter alone.
    nonisolated static func visibleManifestEntries(
        from entries: [ManifestEntry],
        historyWindow: BillboardHistoryWindow,
        companions: CompanionGroupIndex = .empty
    ) -> [ManifestEntry] {
        let cutoff = Date(timeIntervalSinceNow: -historyWindow.timeInterval)
        let visible = entries.filter { entry in
            guard let updatedAtDate = entry.updatedAtDate else { return false }
            return updatedAtDate >= cutoff
        }
        guard !companions.isEmpty else { return visible }
        return visible + partnerEntries(of: visible, in: entries, companions: companions)
    }

    /// The entries of the members of `visible`'s groups that `visible` lacks, in group order. A member
    /// matches its plain guid, else a legacy text-version guid of the same bill.
    nonisolated static func partnerEntries(
        of visible: [ManifestEntry],
        in entries: [ManifestEntry],
        companions: CompanionGroupIndex
    ) -> [ManifestEntry] {
        var present = Set<String>()
        for entry in visible {
            if let member = companions.memberGuid(forGUID: entry.item.guid) { present.insert(member) }
        }
        var wanted: [String] = []
        for entry in visible {
            guard let group = companions.group(forGUID: entry.item.guid) else { continue }
            for member in group.memberGuids where present.insert(member).inserted {
                wanted.append(member)
            }
        }
        guard !wanted.isEmpty else { return [] }

        // Runs over the whole manifest, so one guid parse per entry: member guids are plain guids.
        let wantedSet = Set(wanted)
        var entryByMember: [String: ManifestEntry] = [:]
        for entry in entries {
            guard let member = CompanionGroupIndex.plainGuid(entry.item.guid), wantedSet.contains(member) else { continue }
            if entryByMember[member] == nil || member == entry.item.guid {
                entryByMember[member] = entry
            }
        }
        return wanted.compactMap { entryByMember[$0] }
    }

    nonisolated static func resolveManifestBills(
        manifestEntries: [ManifestEntry],
        billsByGuid: [String: Bill],
        billsByID: [UUID: Bill]
    ) -> [Bill] {
        manifestEntries.map { entry in
            let item = entry.item
            let manifestBill = entry.placeholderBill
            let normalizedGuid = item.guid.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = billsByGuid[normalizedGuid] {
                return mergedBillPreservingExistingContext(incoming: manifestBill, existing: existing, source: .manifestRow)
            }

            let itemID = UUID.deterministic(from: normalizedGuid)
            if let existingByID = billsByID[itemID] {
                return mergedBillPreservingExistingContext(incoming: manifestBill, existing: existingByID, source: .manifestRow)
            }

            return manifestBill
        }
    }

    nonisolated static func makeBillLookupByGuid(from bills: [Bill]) -> [String: Bill] {
        var billsByGuid: [String: Bill] = [:]
        billsByGuid.reserveCapacity(bills.count)

        for bill in bills {
            guard let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !guid.isEmpty else {
                continue
            }
            billsByGuid[guid] = bill
        }

        return billsByGuid
    }

    nonisolated static func makeBillLookupByID(from bills: [Bill]) -> [UUID: Bill] {
        Dictionary(uniqueKeysWithValues: bills.map { ($0.id, $0) })
    }
}
