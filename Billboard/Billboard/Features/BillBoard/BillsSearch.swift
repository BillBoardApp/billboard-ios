import Combine
import Foundation

/// What Search finds (UX-39, feature review N9): every bill in the full manifest, by its number in the usual
/// spellings ("H.R. 1", "hr1", "HR-1", "House bill 1"), or by words in its headline, official title, topic (as
/// the app shows and people follow it), topic group, life areas, summary and breakdown. Case, accents and
/// word order don't matter: a bill matches when every word of the search is in it. No vote data is searched
/// or ranked (INT-11): matches keep the manifest's order.
enum BillsSearch {
    /// A search as typed, folded once.
    struct Query: Equatable {
        /// As typed, trimmed: what the no-results notice repeats.
        let text: String
        /// `text` folded: what a number search looks for in a bill's text.
        let foldedText: String
        /// The folded words, each of which a match must contain.
        let words: [String]
        /// The bill number the search reads as ("hr1"), or nil.
        let numberKey: String?

        /// Nil for an empty or blank search.
        init?(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            text = trimmed
            foldedText = BillsSearch.fold(trimmed)
            words = foldedText.split(whereSeparator: \.isWhitespace).map(String.init)
            numberKey = BillDisplayFormatting.billNumberQueryKey(trimmed)
        }

        /// The number as Congress writes it ("H.R. 1"), when the search reads as one.
        var officialNumber: String? {
            guard let numberKey else { return nil }
            let typeCode = String(numberKey.prefix { $0.isLetter })
            return BillDisplayFormatting.officialBillNumber(
                billType: typeCode,
                billNumber: String(numberKey.dropFirst(typeCode.count)),
                guid: nil
            )
        }
    }

    /// Lower case without accents, so "Medicare" finds "medicare" and "Peña" finds "pena".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
    }

    /// Everything a bill is found by, folded, one field per line: the headline, the official title, the topic
    /// shown on the bill, the topic group, the life areas, the summary and the breakdown. The manifest carries
    /// the headline, topic and life areas of every bill; the rest is there once a bill has been opened.
    static func searchableText(of bill: Bill) -> String {
        var fields = [bill.title, bill.officialTitle ?? "", bill.subCategory ?? "", bill.category]
        fields += bill.lifeAreas
        fields += [bill.summary, bill.billBreakdown?.searchableText ?? ""]
        return fold(fields.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// Whether `bill` (whose folded text is `text`) matches: its number, or a companion's (APPF-23), when the
    /// search reads as a bill number; else every word of the search in its text. A number search also matches
    /// text that names it as typed and whole ("H.R. 1" quoted in a headline), but not text that only holds the
    /// characters ("H.R. 1234", or "states 180" for "S 1").
    static func matches(_ bill: Bill, text: String, query: Query, companions: CompanionGroupIndex) -> Bool {
        if let numberKey = query.numberKey {
            return hasNumber(bill, numberKey: numberKey, companions: companions)
                || containsWhole(query.foldedText, in: text)
        }
        return query.words.allSatisfy { text.contains($0) }
    }

    /// Whether the bill's number, or a companion's (APPF-23), is `numberKey`.
    static func hasNumber(_ bill: Bill, numberKey: String, companions: CompanionGroupIndex) -> Bool {
        if bill.billNumberSearchKey == numberKey { return true }
        guard let group = companions.group(for: bill) else { return false }
        return group.memberGuids.contains {
            BillDisplayFormatting.billNumberSearchKey(billType: nil, billNumber: nil, guid: $0) == numberKey
        }
    }

    /// Whether `needle` is in `text` with no letter or digit right before or after it.
    static func containsWhole(_ needle: String, in text: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchStart = text.startIndex
        while searchStart < text.endIndex, let found = text.range(of: needle, range: searchStart..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    /// The matching bills, one entry per companion group: a group matches when either member does, and shows on
    /// the primary's bill when it is loaded. `textOf` gives a bill's `searchableText` (cached by the caller).
    /// Matches keep the given order, except that a number search lists the bills with that number (and their
    /// companions) before bills that only name it.
    static func results(
        in bills: [Bill],
        query: Query,
        companions: CompanionGroupIndex,
        textOf: (Bill) -> String = { searchableText(of: $0) }
    ) -> [Bill] {
        let matches = bills.filter { matches($0, text: textOf($0), query: query, companions: companions) }
        let grouped = withCompanions(matches, in: bills, companions: companions)
        guard let numberKey = query.numberKey else { return grouped }
        let numbered = grouped.filter { hasNumber($0, numberKey: numberKey, companions: companions) }
        guard !numbered.isEmpty, numbered.count < grouped.count else { return grouped }
        let numberedIDs = Set(numbered.map(\.id))
        return numbered + grouped.filter { !numberedIDs.contains($0.id) }
    }

    /// `matches` one entry per companion group, on the primary's bill when `bills` has it.
    private static func withCompanions(_ matches: [Bill], in bills: [Bill], companions: CompanionGroupIndex) -> [Bill] {
        guard !companions.isEmpty else { return matches }

        let matchedGroups = Set(matches.compactMap { companions.group(for: $0)?.primaryGuid })
        guard !matchedGroups.isEmpty else { return matches }
        let matchedIDs = Set(matches.map(\.id))
        let withPartners = bills.filter { bill in
            if let group = companions.group(for: bill) { return matchedGroups.contains(group.primaryGuid) }
            return matchedIDs.contains(bill.id)
        }
        return companions.collapsed(withPartners)
    }

    // MARK: - Every bill

    /// Whether Search has every bill to look through (the full manifest) yet.
    enum Coverage: Equatable {
        /// Every bill is loaded: a search that finds nothing found nothing.
        case everyBill
        /// The full manifest is loading; results so far come from the bills already on the phone.
        case loading
        /// The full manifest didn't load: results come from the bills already on the phone, and the error
        /// notice says why, with Try again.
        case failed(message: String)
    }

    /// The loading line while every bill loads.
    static let loadingText = "Loading every bill to search…"
    /// The error notice's title when every bill didn't load (the message is the load's own).
    static let loadFailedTitle = "Couldn't load every bill"

    /// The no-results notice's title: `No results for "medicare dental"`.
    static func noResultsTitle(for query: Query) -> String {
        "No results for \"\(query.text)\""
    }

    /// The no-results notice's message: what was searched, and in which bills.
    static func noResultsMessage(for query: Query, coverage: Coverage) -> String {
        let scope = coverage == .everyBill ? "every bill" : "the bills loaded so far"
        if let number = query.officialNumber {
            return "We looked for \(number) in \(scope). A bill shows up here once its text is published."
        }
        return "We looked in the number, title, topic and life areas of \(scope)."
    }
}

/// The bills Search looks through and their folded `searchableText`, built once per version of the store's
/// bills and manifest, so typing searches the full manifest without folding every bill again on each keystroke.
@MainActor
final class BillsSearchIndex {
    private var version: BillsStore.SearchVersion?
    private var entries: [(bill: Bill, text: String)] = []
    private var cachedResults: (version: BillsStore.SearchVersion, query: BillsSearch.Query, bills: [Bill])?

    /// The matches for `query`, reusing the index and the last result while `version` stays the same; `bills`
    /// gives the bills to index (`BillsStore.searchableBills()`) when it changed.
    func results(
        for query: BillsSearch.Query,
        version: BillsStore.SearchVersion,
        companions: CompanionGroupIndex,
        bills: () -> [Bill]
    ) -> [Bill] {
        if let cachedResults, cachedResults.version == version, cachedResults.query == query {
            return cachedResults.bills
        }
        if self.version != version {
            self.version = version
            entries = bills().map { ($0, BillsSearch.searchableText(of: $0)) }
        }
        var texts: [UUID: String] = [:]
        texts.reserveCapacity(entries.count)
        for entry in entries where texts[entry.bill.id] == nil {
            texts[entry.bill.id] = entry.text
        }
        let results = BillsSearch.results(in: entries.map(\.bill), query: query, companions: companions) { bill in
            texts[bill.id] ?? BillsSearch.searchableText(of: bill)
        }
        cachedResults = (version, query, results)
        return results
    }
}

extension BillsStore {
    /// Loads every bill for Search (UX-39), the full manifest as topic pages load it, and keeps the Bills tab's
    /// window. A load already running makes `load` return at once, so this waits for that one and asks again.
    /// - Returns: `.everyBill`, or `.failed` with the load's message. Search shows that in its own notice, so the
    ///   store's "Pull to refresh" banner is cleared: it would otherwise show on the next bill page opened.
    func loadEveryBillForSearch(historyWindow: BillboardHistoryWindow?) async -> BillsSearch.Coverage {
        for _ in 0..<3 {
            await ensureFullManifestLoaded(historyWindow: historyWindow)
            if hasFullManifestCoverage { return .everyBill }
            if Task.isCancelled { break }
            guard isLoading else { break }
            for await loading in $isLoading.values where !loading { break }
        }
        if hasFullManifestCoverage { return .everyBill }
        if errorMessage == Self.loadFailedBanner { errorMessage = nil }
        return .failed(message: loadErrorMessage ?? "We couldn't load every bill right now. Try again in a moment.")
    }
}
