import SwiftUI

/// Search bills: find a bill by number, title or topic, or browse your lists (Watching, Voted,
/// Passed, Skipped, Topics, Life areas). Members moved to the Congress tab in R2.
///
/// Search looks through every bill (UX-39): opening it loads the full manifest, as topic pages do, with a
/// loading line until it is in and the COULDN'T LOAD notice with Try again when it fails. What matches is
/// `BillsSearch`'s.
///
/// Set as a list screen (Civic Record spec 4.24, frames 11 and 20): the search field in the system glass
/// bar, then "Your lists" as one roll sheet of ruled rows with mono counts (the six coloured tiles are
/// gone), or, while a search is typed, the results as slips under "Search results" with a mono counter.
/// 16 pt gutter. Every bill opens with the vote panel, a decided bill's too (project decision 1); no row
/// or slip shows other people's votes or a vote count (INT-11).
struct BillsSearchView: View {
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var voteStore: BillVoteStore
    @EnvironmentObject private var readState: AppReadState
    @EnvironmentObject private var appState: AppState
    @AppStorage(BillboardDisplayStorage.historyWindowDaysKey) private var billboardHistoryWindowDays = BillboardHistoryWindow.default.rawValue

    @State private var searchText: String = ""
    /// `searchText` once typing has paused (`searchDebounceNanoseconds`): the text the results follow.
    @State private var queryText: String = ""
    /// How many results the list shows. "Show more" adds a page; a new search starts over.
    @State private var visibleResultLimit = BillsSearchView.resultPageSize
    /// Whether every bill is loaded to search, set by `loadEveryBill()`.
    @State private var coverage: BillsSearch.Coverage = .loading
    /// The folded text of every bill, built once per version of the bills.
    @State private var searchIndex = BillsSearchIndex()

    /// How long the search text must stay still before the results follow it.
    private static let searchDebounceNanoseconds: UInt64 = 250_000_000
    /// Matches shown at first and added by each "Show more", so a broad search such as "h" does not
    /// lay out a card for every bill.
    private static let resultPageSize = 50

    private var query: BillsSearch.Query? {
        BillsSearch.Query(queryText)
    }

    private var isSearchActive: Bool {
        query != nil
    }

    /// `coverage`, or every bill as soon as the store has them (a topic page may have loaded them first).
    private var currentCoverage: BillsSearch.Coverage {
        billsStore.hasFullManifestCoverage ? .everyBill : coverage
    }

    private var companions: CompanionGroupIndex {
        billsStore.companionGroupIndex
    }

    /// Bills the user watches, one entry per companion group (APPF-23), latest vote first.
    private var watchList: [Bill] {
        companions.collapsed(billsStore.bills.filter(\.userWatched)).sorted { a, b in
            let da = a.lastVotedAt ?? Date.distantPast
            let db = b.lastVotedAt ?? Date.distantPast
            return da > db
        }
    }

    /// Bills voted on in the last 30 days, one entry per companion group, latest first. Votes are
    /// matched by `UpdatesDerivation` (by guid or bill identity; a vote on one member counts for
    /// its group).
    private var votedRecent: [Bill] {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())
        let bills = billsStore.bills
        let store = voteStore
        let voteLookup: (String) -> VoteState = { store.vote(for: $0) }
        let voteIndex = UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: voteLookup, companions: companions)

        return companions.collapsed(bills.filter { bill in
            guard UpdatesDerivation.isUserVoted(bill, voteIndex: voteIndex, voteLookup: voteLookup) else { return false }
            if let last = bill.lastVotedAt, let cutoff = thirtyDaysAgo {
                return last >= cutoff
            }
            return false
        }).sorted { a, b in
            let da = a.lastVotedAt ?? Date.distantPast
            let db = b.lastVotedAt ?? Date.distantPast
            return da > db
        }
    }

    /// Bills the user skipped that are still in the Bills tab's window (spec D 2.1.2): put one back
    /// and it returns to the list.
    private var skippedItems: [BillBoardItem] {
        BillsSearchView.skippedItems(
            billsStore: billsStore,
            readState: readState,
            userProfile: userStore.profile,
            voteStore: voteStore,
            historyWindow: appState.sessionBillboardHistoryWindow ?? BillboardHistoryWindow.from(rawValue: billboardHistoryWindowDays)
        )
    }

    /// Bills that passed or became law on topics, life areas or members the user follows, one entry per
    /// companion group (`BillBoardDerivedCollections.passedSubscribed`).
    private var passedSubscribed: [Bill] {
        BillBoardDerivedCollections.passedSubscribed(bills: billsStore.bills, profile: userStore.profile, companions: companions)
    }

    /// Matching bills among every bill of the manifest, one entry per companion group (`BillsSearch.results`).
    private var searchResults: [Bill] {
        guard let query else { return [] }
        let store = billsStore
        return searchIndex.results(for: query, version: store.searchVersion, companions: companions) {
            store.searchableBills()
        }
    }

    private var historyWindow: BillboardHistoryWindow {
        appState.sessionBillboardHistoryWindow ?? BillboardHistoryWindow.from(rawValue: billboardHistoryWindowDays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                // While a search is typed, its results take the place of the lists, so they start at the top
                // of the screen; clearing the search brings the lists back.
                if isSearchActive {
                    searchResultsSection()
                } else {
                    yourLists
                }
            }
            .padding(.horizontal, BillsSearchLayout.gutter)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(BillboardColors.background.ignoresSafeArea())
        .navigationTitle("Search bills")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: BillsSearchView.searchPrompt)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .task(id: searchText) {
            await applySearchText()
        }
        // Keyed on the store's coverage, so Search loads every bill again if the store stops having them while
        // it is open (the Bills tab's fetch after a gap longer than its window replaces the full copy). Keyed on
        // the visit alone, Search kept saying it had looked in every bill when the store held only that window.
        .task(id: billsStore.hasFullManifestCoverage) {
            await loadEveryBill()
        }
    }

    /// Loads every bill to search (the full manifest) when the store doesn't have them: on opening, and again
    /// if the store loses them while Search is open. Try again calls it again.
    private func loadEveryBill() async {
        if billsStore.hasFullManifestCoverage {
            coverage = .everyBill
            return
        }
        coverage = .loading
        let result = await billsStore.loadEveryBillForSearch(historyWindow: appState.sessionBillboardHistoryWindow)
        guard !Task.isCancelled else { return }
        coverage = result
    }

    /// The search field's prompt (spec 4.24); the bar's title says what the screen is.
    static let searchPrompt = "Bill number, title or topic"

    /// Moves `searchText` to `queryText`. Clearing the search brings the lists back at once; typing waits
    /// for a pause, so a burst of keystrokes filters the bills and lays out the cards once.
    private func applySearchText() async {
        let text = searchText
        guard text != queryText else { return }
        if BillsSearch.Query(text) != nil {
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
        }
        queryText = text
        visibleResultLimit = Self.resultPageSize
    }

    /// "Your lists" (spec 4.24, frame 11): one roll sheet of six ruled rows, the same at every width.
    private var yourLists: some View {
        let watching = watchList
        let voted = votedRecent
        let passed = passedSubscribed
        let window = historyWindow
        return VStack(alignment: .leading, spacing: BillsSearchLayout.headToContent) {
            SectionHeader("Your lists")
            BillsSearchListsSheet(
                counts: [
                    .watching: watching.count,
                    .voted: voted.count,
                    .passed: passed.count,
                    .skipped: skippedItems.count
                ],
                window: window
            ) { list in
                switch list {
                case .watching:
                    BillCollectionQuickScreen(list: .watching, bills: watching)
                case .voted:
                    BillCollectionQuickScreen(list: .voted, bills: voted)
                case .passed:
                    BillCollectionQuickScreen(list: .passed, bills: passed)
                case .skipped:
                    SkippedBillsScreen()
                case .topics:
                    CongressCategoryInsightsListView()
                case .lifeAreas:
                    CongressLifeAreaInsightsListView()
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultsSection() -> some View {
        let results = searchResults
        let shownResults = Array(results.prefix(visibleResultLimit))

        if results.isEmpty {
            VStack(alignment: .leading, spacing: BillsSearchLayout.headToContent) {
                SectionHeader("Search results")
                if let query {
                    // NOT FOUND waits until every bill is in: while it loads, the loading line says so instead.
                    BillsSearchCoverageNotice(coverage: currentCoverage, onRetry: retryLoadingEveryBill)
                    if currentCoverage != .loading {
                        BillsSearchNoResults(query: query, coverage: currentCoverage)
                    }
                }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: BillsSearchLayout.slipSpacing) {
                BillsSearchResultsHeader(total: results.count, shown: shownResults.count)
                    .padding(.bottom, BillsSearchLayout.headToContent - BillsSearchLayout.slipSpacing)

                BillsSearchCoverageNotice(coverage: currentCoverage, onRetry: retryLoadingEveryBill)

                ForEach(shownResults) { bill in
                    NavigationLink {
                        // A bill outside the Bills tab's window is not in the store: the page starts from the
                        // manifest's copy, loads the rest and adds it when the person votes.
                        Self.billPage(bill.id, initialBill: bill)
                    } label: {
                        BillCard(bill: bill)
                    }
                    .buttonStyle(RowButtonStyle())
                }

                if shownResults.count < results.count {
                    showMoreResultsButton(count: Self.moreResultsCount(total: results.count, shown: shownResults.count))
                }
            }
            .environment(\.billCardCompanions, BillCompanionDisplay.lookup(for: shownResults, in: billsStore))
        }
    }

    private func retryLoadingEveryBill() {
        Task { await loadEveryBill() }
    }

    /// "12 results", or "Showing 50 of 1002 results" while the list is capped: what VoiceOver reads for
    /// the results' counter.
    static func resultCountText(total: Int, shown: Int) -> String {
        let noun = total == 1 ? "result" : "results"
        return shown < total ? "Showing \(shown) of \(total) \(noun)" : "\(total) \(noun)"
    }

    /// The counter in the results' section head (spec 4.24): "2 of 2", "50 of 1,002" (the `docket` role
    /// sets it in capitals).
    static func resultCounterText(total: Int, shown: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        let format: (Int) -> String = { formatter.string(from: NSNumber(value: $0)) ?? String($0) }
        return "\(format(shown)) of \(format(total))"
    }

    /// How many results "Show more" adds: a page, or what is left when that is less.
    static func moreResultsCount(total: Int, shown: Int) -> Int {
        max(0, min(resultPageSize, total - shown))
    }

    /// "Show 50 more" (spec 4.24): a secondary capsule under the slips.
    private func showMoreResultsButton(count: Int) -> some View {
        Button("Show \(count) more") {
            visibleResultLimit += Self.resultPageSize
        }
        .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: true))
        .padding(.top, BillboardStyle.Space.xs)
        .accessibilityIdentifier("search.results.showMore")
    }
}

/// Search's measures (spec 2.8, 3.5): the 16 pt list gutter, 12 pt from a section head to its content
/// and between slips.
enum BillsSearchLayout {
    static let gutter = BillboardStyle.Space.l
    static let headToContent = BillboardStyle.Space.m
    static let slipSpacing = BillboardStyle.Space.m
}

/// The lists Search opens (spec 4.24): each one's row title, sub-line and identifier.
enum BillsSearchList: String, CaseIterable, Identifiable {
    case watching
    case voted
    case passed
    case skipped
    case topics
    case lifeAreas

    var id: Self { self }

    var title: String {
        switch self {
        case .watching: return "Watching"
        case .voted: return "Voted"
        case .passed: return "Passed"
        case .skipped: return "Skipped"
        case .topics: return "Topics"
        case .lifeAreas: return "Life areas"
        }
    }

    /// The row's sub-line: "Bills you watch", "Last 30 days", "From the last week".
    func subtitle(window: BillboardHistoryWindow) -> String {
        switch self {
        case .watching: return "Bills you watch"
        case .voted: return "Last 30 days"
        case .passed: return "Passed or became law, on your topics"
        case .skipped: return "From the last \(Self.windowPhrase(window))"
        case .topics: return "Bills by topic group"
        case .lifeAreas: return "Bills by part of life"
        }
    }

    /// "week" for the one-week window, else its title ("2 weeks", "10 days"): "From the last week".
    static func windowPhrase(_ window: BillboardHistoryWindow) -> String {
        window == .oneWeek ? "week" : window.title
    }

    /// What VoiceOver reads for the row's count: "4 bills", "12 bills".
    static func spokenCount(_ count: Int) -> String {
        count == 1 ? "1 bill" : "\(count) bills"
    }

    /// `search.tile.watching` and so on: R2's tile ids, kept on the rows (spec 4.24).
    var accessibilityIdentifier: String {
        "search.tile.\(rawValue)"
    }
}

/// Search's lists as one roll sheet (spec 4.24, frame 11): a ruled row per list with its title
/// (`name`), its sub-line, its count in the docket face (Watching, Voted, Passed and Skipped; the
/// counts of the user's own lists, never of anyone's votes) and the chevron. No icon tiles, no tile
/// colours, no gradient; the same rows at every width.
struct BillsSearchListsSheet<Destination: View>: View {
    let counts: [BillsSearchList: Int]
    var window: BillboardHistoryWindow = .oneWeek
    @ViewBuilder let destination: (BillsSearchList) -> Destination

    var body: some View {
        RollSheet {
            RollRows(BillsSearchList.allCases) { _, list in
                let count = counts[list]
                NavigationLink {
                    destination(list)
                } label: {
                    RollLinkRow(
                        title: list.title,
                        subtitle: list.subtitle(window: window),
                        figure: count.map(String.init),
                        spokenFigure: count.map { BillsSearchList.spokenCount($0) }
                    )
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier(list.accessibilityIdentifier)
            }
        }
    }
}

/// The results' section head (spec 4.24, frame 20): "Search results" with the counter "2 OF 2" or
/// "50 OF 1,002", read as "Showing 50 of 1002 results".
struct BillsSearchResultsHeader: View {
    let total: Int
    let shown: Int

    var body: some View {
        SectionHeader(
            "Search results",
            trailing: .counter(
                BillsSearchView.resultCounterText(total: total, shown: shown),
                spoken: BillsSearchView.resultCountText(total: total, shown: shown)
            )
        )
    }
}

/// No match (spec 4.24): a `RecordNotice` with NOT FOUND, `No results for "medicare dental"` and what was
/// searched, in every bill or in the bills loaded so far (UX-39).
struct BillsSearchNoResults: View {
    let query: BillsSearch.Query
    var coverage: BillsSearch.Coverage = .everyBill

    var body: some View {
        RecordNotice(
            .notFound,
            title: BillsSearch.noResultsTitle(for: query),
            message: BillsSearch.noResultsMessage(for: query, coverage: coverage)
        )
        .accessibilityIdentifier("search.results.none")
    }
}

/// Above the results while Search doesn't have every bill (UX-39): the loading line while the full manifest
/// loads, or the COULDN'T LOAD notice with the load's message and Try again. Nothing once every bill is in.
struct BillsSearchCoverageNotice: View {
    let coverage: BillsSearch.Coverage
    let onRetry: () -> Void

    var body: some View {
        switch coverage {
        case .everyBill:
            EmptyView()
        case .loading:
            CongressLoadingLine(text: BillsSearch.loadingText)
                .accessibilityIdentifier("search.loadingEveryBill")
        case .failed(let message):
            RecordNotice(
                .couldNotLoad,
                title: BillsSearch.loadFailedTitle,
                message: message,
                action: .init(title: "Try again", accessibilityIdentifier: "search.loadEveryBill.retry", perform: onRetry)
            )
        }
    }
}

extension BillsSearchView {
    /// The Skipped list (spec D 2.1.2): dismissed cards of the Bills tab's loaded window that would be
    /// back on the list if put back, in list order. Bills the user abstained on are not skips and stay
    /// out of it.
    static func skippedItems(
        billsStore: BillsStore,
        readState: AppReadState,
        userProfile: UserProfile,
        voteStore: BillVoteStore,
        historyWindow: BillboardHistoryWindow
    ) -> [BillBoardItem] {
        let bills = billsStore.activeManifestBills
        return BillBoardDerivedCollections.skippedItems(from: BillBoardDerivedCollections.Input(
            bills: bills,
            dismissedBillIDs: readState.dismissedBillIDs,
            userProfile: userProfile,
            historyWindow: historyWindow,
            voteStatesByBillID: voteStore.statesByBillId,
            companions: billsStore.companionGroupIndex,
            abstainedGuids: billsStore.abstainedGuids(in: bills)
        ))
    }

    /// Put back: un-skips every bill the card stands for (each companion member), so it returns to
    /// the Bills list.
    static func putBack(_ item: BillBoardItem, billsStore: BillsStore, readState: AppReadState) {
        var ids = billsStore.companionMemberBillIDs(forBillID: item.bill.id)
        if item.id != item.bill.id { ids.append(item.id) }
        readState.undismissBills(ids)
    }
}

/// Bills you skipped, each with Put back (spec D 2.1.2, Civic Record 4.26). Live: a bill put back leaves
/// the list.
private struct SkippedBillsScreen: View {
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var voteStore: BillVoteStore
    @EnvironmentObject private var readState: AppReadState
    @EnvironmentObject private var appState: AppState
    @AppStorage(BillboardDisplayStorage.historyWindowDaysKey) private var billboardHistoryWindowDays = BillboardHistoryWindow.default.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var historyWindow: BillboardHistoryWindow {
        appState.sessionBillboardHistoryWindow ?? BillboardHistoryWindow.from(rawValue: billboardHistoryWindowDays)
    }

    private var items: [BillBoardItem] {
        BillsSearchView.skippedItems(
            billsStore: billsStore,
            readState: readState,
            userProfile: userStore.profile,
            voteStore: voteStore,
            historyWindow: historyWindow
        )
    }

    var body: some View {
        ScrollView {
            SkippedBillsList(items: items, window: historyWindow) { item in
                withAnimation(billboardQueueSettleAnimation(reduceMotion: reduceMotion)) {
                    BillsSearchView.putBack(item, billsStore: billsStore, readState: readState)
                }
            }
            .padding(.horizontal, BillsSearchLayout.gutter)
            .padding(.top, BillboardStyle.Space.l)
            .padding(.bottom, BillboardStyle.Space.xxl)
        }
        .background(BillboardColors.background.ignoresSafeArea())
        .navigationTitle("Skipped")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("search.skipped.screen")
    }
}

/// The Skipped list (spec 4.26): the section head "Skipped", the sentence that skipping is never a
/// vote, then each slip with a "Put back" capsule under it (`arrow.uturn.backward`). Empty: a
/// `RecordNotice` with NOTHING YET. A slip opens its bill with the vote panel.
struct SkippedBillsList: View {
    let items: [BillBoardItem]
    var window: BillboardHistoryWindow = .oneWeek
    let putBack: (BillBoardItem) -> Void

    static let sentence = "Skipping is never a vote. Put a bill back to see it on your Bills tab again."

    static func emptyTitle(window: BillboardHistoryWindow) -> String {
        "You haven't skipped any bills from the last \(BillsSearchList.windowPhrase(window))."
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: BillsSearchLayout.slipSpacing) {
            SectionHeader(
                "Skipped",
                trailing: items.isEmpty ? .none : .counter("\(items.count)", spoken: BillsSearchList.spokenCount(items.count))
            )

            if items.isEmpty {
                RecordNotice(.nothingYet, title: Self.emptyTitle(window: window))
            } else {
                Text(Self.sentence)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                        NavigationLink {
                            BillDetail(billID: item.bill.id, mode: BillDetail.Mode(opening: item.type))
                        } label: {
                            BillCard(bill: item.bill)
                        }
                        .buttonStyle(RowButtonStyle())

                        Button {
                            putBack(item)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.uturn.backward")
                                    .accessibilityHidden(true)
                                Text("Put back")
                            }
                        }
                        .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: false))
                        .accessibilityLabel(item.billNumbers.isEmpty ? "Put back" : "Put back \(item.billNumbers.map(SpokenForm.billNumber).joined(separator: " and "))")
                        .accessibilityInputLabels(["Put back"])
                        .accessibilityIdentifier("search.skipped.putBack.\(index)")
                    }
                }
            }
        }
        .environment(\.billCardCompanions, Self.companions(for: items))
    }

    private static func companions(for items: [BillBoardItem]) -> [UUID: BillCompanionDisplay] {
        var lookup: [UUID: BillCompanionDisplay] = [:]
        for item in items {
            if let display = item.companionDisplay {
                lookup[item.bill.id] = display
            }
        }
        return lookup
    }
}

/// The Watching, Voted and Passed lists (spec 4.25): the list's section head with its count, then the
/// same slips as everywhere (the Voted list shows no vote mark: INT-11, project decision 5; its title
/// says what is on it). Empty: a `RecordNotice` with NOTHING YET and R2's sentence. Every bill opens with
/// the vote panel, a passed one too (project decision 1).
private struct BillCollectionQuickScreen: View {
    let list: BillsSearchList
    let bills: [Bill]

    @EnvironmentObject private var billsStore: BillsStore

    var body: some View {
        ScrollView {
            BillCollectionList(list: list, bills: bills)
                .padding(.horizontal, BillsSearchLayout.gutter)
                .padding(.top, BillboardStyle.Space.l)
                .padding(.bottom, BillboardStyle.Space.xxl)
                // A companion group's entry shows both numbers (APPF-23).
                .environment(\.billCardCompanions, BillCompanionDisplay.lookup(for: bills, in: billsStore))
        }
        .background(BillboardColors.background.ignoresSafeArea())
        .navigationTitle(list.title)
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
    }
}

/// A Watching, Voted or Passed list's content (spec 4.25).
struct BillCollectionList: View {
    let list: BillsSearchList
    let bills: [Bill]

    /// R2's sentence for an empty list.
    static func emptyTitle(for list: BillsSearchList) -> String {
        switch list {
        case .watching: return "You're not watching any bills."
        case .voted: return "No recent votes in the past 30 days"
        case .passed: return "No passed bills on topics you follow."
        case .skipped, .topics, .lifeAreas: return "Nothing here yet"
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: BillsSearchLayout.slipSpacing) {
            SectionHeader(
                list.title,
                trailing: bills.isEmpty ? .none : .counter("\(bills.count)", spoken: BillsSearchList.spokenCount(bills.count))
            )

            if bills.isEmpty {
                RecordNotice(.nothingYet, title: Self.emptyTitle(for: list))
            } else {
                ForEach(bills) { bill in
                    NavigationLink {
                        BillsSearchView.billPage(bill.id)
                    } label: {
                        BillCard(bill: bill)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
    }
}

extension BillsSearchView {
    /// The page a bill in Search's results, or in its Watching, Voted and Passed lists, opens: the full
    /// page with the vote bar, a decided bill's too (Civic Record project decision 1). `DecidedBillVotingTests`
    /// opens it from here.
    static func billPage(_ billID: UUID, initialBill: Bill? = nil) -> BillDetail {
        BillDetail(billID: billID, initialBill: initialBill)
    }
}
