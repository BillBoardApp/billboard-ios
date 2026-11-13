import SwiftUI

private struct ConditionalRefreshModifier: ViewModifier {
    let isEnabled: Bool
    let action: () async -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.refreshable {
                await action()
            }
        } else {
            content
        }
    }
}

/// The Bills tab: a search entry, the list of bills to act on (swipe left to skip, with Undo; spec D
/// 2.1), the starter feed's banner for a profile that follows no topics (2.5.4), and the controls that
/// widen the window.
struct BillBoardTab: View {
    @EnvironmentObject private var readState: AppReadState
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(BillboardDisplayStorage.historyWindowDaysKey) private var billboardHistoryWindowDays = BillboardHistoryWindow.default.rawValue

    @EnvironmentObject private var voteStore: BillVoteStore

    @EnvironmentObject private var billAlertsStore: BillAlertsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Aggregated Computation

    /// What closing a queue card's bill page does (`queueDetailReturnAction(for:)`).
    enum QueueDetailReturnAction: Equatable {
        /// A Congress action's card (`.alert`): mark the action read and take it off the list.
        case dismissAlert(UUID)
    }

    private struct PresentedQueueBillDetail {
        let billID: UUID
        let initialBill: Bill
        let mode: BillDetail.Mode
        let returnAction: QueueDetailReturnAction?
    }

    private var billboardSourceBills: [Bill] {
        billsStore.activeManifestBills
    }

    private func computeQueueSnapshot(for historyWindow: BillboardHistoryWindow) -> BillboardQueueSnapshot {
        let voteLookup: @Sendable (String) -> VoteState = BillBoardDerivedCollections.voteLookup(for: voteStore.statesByBillId)
        let voteIndex = UpdatesDerivation.voteIdentityIndex(
            for: billboardSourceBills,
            voteLookup: voteLookup,
            companions: billsStore.companionGroupIndex
        )

        return BillboardQueueDerivation.snapshot(
            bills: billboardSourceBills,
            dismissedBillIDs: readState.dismissedBillIDs,
            userProfile: userStore.profile,
            historyWindow: historyWindow,
            voteIndex: voteIndex,
            voteLookup: voteLookup
        )
    }

    private var snapshot: BillboardQueueSnapshot {
        derivedCollections.snapshot
    }

    private var nonVotedBills: [Bill] {
        snapshot.pendingBills
    }

    // Bills on the list: in the news first, then the newest, never by vote count (INT-11). The starter
    // feed pulls bills by followed members forward and caps the list.
    private var liveBoardItems: [BillBoardItem] {
        derivedCollections.liveBoardItems
    }

    private var boardItems: [BillBoardItem] {
        let liveItems = liveBoardItems
        if !liveItems.isEmpty { return liveItems }
        if isHomeQueueSyncing, !lastNonEmptyBoardItems.isEmpty {
            return lastNonEmptyBoardItems
        }
        return []
    }

    private var liveBoardItemIDs: [UUID] {
        liveBoardItems.map(\.id)
    }

    /// The companion group each queue card stands for (APPF-23), by card id, for `BillCard`.
    private var boardCardCompanions: [UUID: BillCompanionDisplay] {
        var lookup: [UUID: BillCompanionDisplay] = [:]
        for item in boardItems {
            if let display = item.companionDisplay {
                lookup[item.bill.id] = display
            }
        }
        return lookup
    }

    @State private var lastFullyHydratedKey: String = ""
    @State private var visibleCardIDs: Set<UUID> = []
    @State private var hasAnimatedBoardCards: Bool = false
    @State private var firstRenderedBoardTopID: UUID?
    @State private var hasAutoScrolledToFreshBoardTop: Bool = false
    @State private var lastNonEmptyBoardItems: [BillBoardItem] = []
    @State private var derivedCollections = BillBoardDerivedCollections.empty
    @State private var derivedCollectionsRecalculator = DebouncedRecalculator(priority: .utility)
    @State private var isExpandingHistoryWindow: Bool = false
    @State private var presentedQueueBillDetail: PresentedQueueBillDetail?
    /// The user whose starter banner was closed in this session (the stored date hides it on later
    /// launches).
    @State private var starterBannerClosedForUserID: String?

    private var configuredBillboardHistoryWindow: BillboardHistoryWindow {
        BillboardHistoryWindow.from(rawValue: billboardHistoryWindowDays)
    }

    private var selectedBillboardHistoryWindow: BillboardHistoryWindow {
        appState.sessionBillboardHistoryWindow ?? configuredBillboardHistoryWindow
    }

    private var canExpandHistoryWindow: Bool {
        selectedBillboardHistoryWindow.canExpandFurther
    }

    private func expandHistoryWindowUntilResults(startFromNextWeek: Bool) async {
        guard canExpandHistoryWindow, !isExpandingHistoryWindow else { return }

        isExpandingHistoryWindow = true
        defer { isExpandingHistoryWindow = false }

        var historyWindow = selectedBillboardHistoryWindow
        var shouldContinue = startFromNextWeek || computeQueueSnapshot(for: historyWindow).pendingBills.isEmpty

        while shouldContinue, !Task.isCancelled, historyWindow.canExpandFurther {
            historyWindow = historyWindow.nextExpanded
            appState.sessionBillboardHistoryWindow = historyWindow
            await billsStore.load(forceRefresh: true, mode: .manifestOnly, historyWindow: historyWindow)
            shouldContinue = computeQueueSnapshot(for: historyWindow).pendingBills.isEmpty
        }
    }

    private var homeHydrationKey: String {
        "userRefreshed=\(userStore.hasRefreshedOnce)|userLoading=\(userStore.isLoading)|manifestBillsCount=\(billboardSourceBills.count)|loaded=\(billsStore.hasLoadedOnce)"
    }

    private var isInitialLoading: Bool {
        // Avoid showing the empty state while the initial data/preferences load is still in-flight.
        if userStore.isLoading && billboardSourceBills.isEmpty { return true }
        if billsStore.isLoading && billboardSourceBills.isEmpty { return true }
        if !billsStore.hasLoadedOnce && billboardSourceBills.isEmpty { return true }
        if !userStore.hasRefreshedOnce && billboardSourceBills.isEmpty { return true }
        return false
    }

    private var isHomeQueueSyncing: Bool {
        appState.isReconcilingHomeQueue
            || !appState.hasCompletedHomeQueueReconciliation
            || userStore.isLoading
            || !userStore.hasRefreshedOnce
            || billsStore.isLoading
            || !billsStore.hasLoadedOnce
    }

    private var shouldShowQueueSyncPlaceholder: Bool {
        boardItems.isEmpty && (isInitialLoading || isHomeQueueSyncing || isExpandingHistoryWindow)
    }

    private var isShowingStaleQueueWhileSyncing: Bool {
        liveBoardItems.isEmpty && !lastNonEmptyBoardItems.isEmpty && isHomeQueueSyncing
    }

    private func refreshCachedBoardItemsIfNeeded() {
        let currentItems = liveBoardItems
        if !currentItems.isEmpty {
            lastNonEmptyBoardItems = currentItems
        } else if !isHomeQueueSyncing {
            lastNonEmptyBoardItems = []
        }
    }

    /// The list's inputs as the stores hold them now.
    private func makeDerivedCollectionsInput() -> BillBoardDerivedCollections.Input {
        BillBoardDerivedCollections.Input(
            bills: billboardSourceBills,
            dismissedBillIDs: readState.dismissedBillIDs,
            userProfile: userStore.profile,
            historyWindow: selectedBillboardHistoryWindow,
            voteStatesByBillID: voteStore.statesByBillId,
            companions: billsStore.companionGroupIndex
        )
    }

    /// Rebuilds the list. A store's `@Published` publisher fires before the store changes (willSet), so the
    /// inputs are read when the recalculation runs, on a later main-actor turn, once the change has landed
    /// (APPF-31; the tab badge in `TabsBar` reads them the same way). Read inside a handler, they were the old
    /// values: a Bill types change, or the saved preferences arriving at sign-in, left the previous list.
    /// - Parameter bills: The new manifest bills from `$activeManifestBills`, for the empty check below,
    ///   which runs at once; the store's by default.
    private func scheduleDerivedCollectionsRefresh(bills: [Bill]? = nil) {
        if (bills ?? billboardSourceBills).isEmpty {
            derivedCollectionsRecalculator.cancel()
            derivedCollections = .empty
            return
        }

        derivedCollectionsRecalculator.schedule(
            snapshot: makeDerivedCollectionsInput,
            compute: { input in
                BillBoardDerivedCollections.derive(from: input)
            },
            apply: { next in
                self.derivedCollections = next

                if !next.liveBoardItems.isEmpty {
                    HomePerfTimeline.markOnce(
                        "home_queue_visible",
                        stage: "home_queue_visible",
                        detail: "queue=\(next.liveBoardItems.count) sync=\(self.isHomeQueueSyncing)"
                    )
                }

                if !next.liveBoardItems.isEmpty,
                   self.appState.hasCompletedHomeQueueReconciliation,
                   self.userStore.hasRefreshedOnce,
                   !self.userStore.isLoading,
                   !self.billsStore.isLoading {
                    HomePerfTimeline.markOnce(
                        "home_queue_fully_updated",
                        stage: "home_queue_fully_updated",
                        detail: "queue=\(next.liveBoardItems.count) watch=\(next.watchList.count) voted=\(next.votedRecent.count)"
                    )
                }
            }
        )
    }

    /// Swiping a card left skips it (spec D 2.1.1): it is hidden on this device and never voted on. A
    /// companion group's card (APPF-23) hides every member; a Passed or Failed card's unwatch waits for
    /// the Undo window to close. The toast offers Undo for 4 seconds (10 with VoiceOver).
    private func handleQueueSwipe(_ item: BillBoardItem) {
        billsStore.skipWithUndo(
            [item.skipTarget],
            message: item.skipUndoMessage,
            readState: readState,
            alertsStore: billAlertsStore
        )
    }

    // MARK: - Starter feed (spec D 2.5.4)

    private var isStarterFeed: Bool {
        StarterFeed.isActive(for: userStore.profile)
    }

    private var signedInUserID: String? {
        let id = userStore.profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private var showsStarterBanner: Bool {
        guard isStarterFeed, let userID = signedInUserID else { return false }
        guard starterBannerClosedForUserID != userID else { return false }
        return !FirstRunStorage.isStarterBannerHidden(userID: userID)
    }

    private func hideStarterBanner() {
        guard let userID = signedInUserID else { return }
        FirstRunStorage.hideStarterBanner(userID: userID)
        withAnimation(billboardQueueSettleAnimation(reduceMotion: reduceMotion)) {
            starterBannerClosedForUserID = userID
        }
    }

    private func expandHistoryByOneWeek() {
        Task { await expandHistoryWindowUntilResults(startFromNextWeek: true) }
    }

    private static let topAnchorID = "homeTop"

    /// Scrolls the first slip to the top for the tour (its anchor is in the queue). The tour often begins
    /// while the queue is still being derived or synced; a scroll then found no anchor, the request was
    /// dropped, and at accessibility sizes the first slip stayed below the screen, so the spotlight framed
    /// the starter banner (integration review). So the request waits until the queue shows, and the queue's
    /// appearing tries again (`onChange(of: boardItems.isEmpty)`).
    private func scrollToTutorialAnchorIfNeeded(using proxy: ScrollViewProxy) {
        guard let anchor = appState.pendingTutorialAnchor, anchor.ownerTab == .home else { return }
        guard !boardItems.isEmpty else { return }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(anchor.scrollID, anchor: .top)
            }

            if self.appState.pendingTutorialAnchor == anchor {
                self.appState.pendingTutorialAnchor = nil
            }
        }
    }

    /// What closing the page a queue card opened does. Every bill's page has the vote bar and Watch, a
    /// decided bill's too (Civic Record project decision 1), so closing it changes nothing: it never skips the
    /// bill or undoes a Watch set on the page. (The queue does not list decided bills today.) A Congress
    /// action's card is marked read; no list builds one today.
    static func queueDetailReturnAction(for item: BillBoardItem) -> QueueDetailReturnAction? {
        switch item.type {
        case .alert(let alert):
            return .dismissAlert(alert.id)
        case .bill, .updated, .passed:
            return nil
        }
    }

    private func presentQueueBillDetail(for item: BillBoardItem) {
        presentedQueueBillDetail = PresentedQueueBillDetail(
            billID: item.bill.id,
            initialBill: item.bill,
            mode: BillDetail.Mode(opening: item.type),
            returnAction: Self.queueDetailReturnAction(for: item)
        )
    }

    private func handleQueueBillDetailDismissal() {
        guard let presentedQueueBillDetail else { return }
        defer { self.presentedQueueBillDetail = nil }

        guard let returnAction = presentedQueueBillDetail.returnAction else { return }

        withAnimation(billboardQueueSettleAnimation(reduceMotion: reduceMotion)) {
            switch returnAction {
            case .dismissAlert(let alertID):
                readState.markBillAlertRead(alertID)
                billAlertsStore.remove(alertID)
            }
        }
    }

    /// Load failure to show in place of the queue. Only when nothing can be shown:
    /// with cached cards on screen a failed refresh keeps the cards.
    private var homeLoadErrorMessage: String? {
        guard boardItems.isEmpty, !billsStore.isLoading, !isExpandingHistoryWindow else { return nil }
        return billsStore.loadErrorMessage
    }

    private func retryHomeLoad() {
        Task {
            await billsStore.load(
                forceRefresh: true,
                mode: .manifestOnly,
                historyWindow: selectedBillboardHistoryWindow
            )
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0).id(Self.topAnchorID)

                        // The masthead band under the navy bar: rule and dateline, full width (spec 3.21).
                        MastheadBand()

                        VStack(alignment: .leading, spacing: BillBoardQueueList.slipSpacing) {
                            // Search entry (your representatives moved to the Congress tab in R2).
                            BillsSearchEntryCard()

                            if showsStarterBanner {
                                StarterFeedBanner(
                                    onChooseTopics: {
                                        NotificationCenter.default.post(name: .billboardRequestTopicPicker, object: nil)
                                    },
                                    onClose: hideStarterBanner
                                )
                                .transition(.opacity)
                            }

                            BillBoardListLine(windowTitle: selectedBillboardHistoryWindow.title)

                            if let loadErrorMessage = homeLoadErrorMessage {
                                BillBoardLoadErrorState(
                                    message: loadErrorMessage,
                                    isRetrying: billsStore.isLoading,
                                    onRetry: retryHomeLoad
                                )
                            } else if shouldShowQueueSyncPlaceholder {
                                BillBoardQueueSyncPlaceholder()
                            } else if boardItems.isEmpty {
                                // ── All caught up ──
                                BillBoardCaughtUpState(
                                    windowTitle: selectedBillboardHistoryWindow.title.lowercased(),
                                    canExpand: canExpandHistoryWindow
                                )

                                // Load more
                                if canExpandHistoryWindow {
                                    BillBoardExpandHistoryCard(
                                        isExpanding: isExpandingHistoryWindow,
                                        action: expandHistoryByOneWeek
                                    )
                                }
                            } else {
                                // ── Active queue ──
                                BillBoardQueueList(
                                    items: boardItems,
                                    isSyncing: isHomeQueueSyncing,
                                    isShowingStaleQueue: isShowingStaleQueueWhileSyncing,
                                    canExpandHistoryWindow: canExpandHistoryWindow,
                                    isExpandingHistoryWindow: isExpandingHistoryWindow,
                                    visibleCardIDs: $visibleCardIDs,
                                    hasAnimatedBoardCards: $hasAnimatedBoardCards,
                                    onOpen: presentQueueBillDetail,
                                    onSwipeLeft: handleQueueSwipe,
                                    onExpandHistory: expandHistoryByOneWeek,
                                    onJumpToTop: {
                                        withAnimation { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
                                    }
                                )
                                .environment(\.billCardCompanions, boardCardCompanions)
                            }
                        }
                        // The list gutter (spec 2.8, 4.18): slips 16 pt from the screen's edges.
                        .padding(.horizontal, BillboardStyle.Space.l)
                        .padding(.top, 14)
                        // The capsule's safe area clears the last slip; this is the list's own margin.
                        .padding(.bottom, BillboardStyle.Space.l)
                    }
                }
                .scrollIndicators(.hidden)
                // Clamp content to viewport width to avoid horizontal scrolling.
                .frame(width: geo.size.width, alignment: .leading)
                .modifier(
                    ConditionalRefreshModifier(isEnabled: !isHomeQueueSyncing) {
                        if nonVotedBills.isEmpty && canExpandHistoryWindow {
                            await expandHistoryWindowUntilResults(startFromNextWeek: true)
                        } else {
                            await billsStore.load(
                                forceRefresh: true,
                                mode: .manifestOnly,
                                historyWindow: selectedBillboardHistoryWindow
                            )
                        }
                    }
                )
                .onAppear {
                    // If we were asked to scroll while Home wasn't visible yet.
                    refreshCachedBoardItemsIfNeeded()

                    if let target = appState.pendingHomeScrollTarget, !target.isEmpty {
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(target, anchor: .top) }
                            appState.pendingHomeScrollTarget = nil
                        }
                    }

                    scrollToTutorialAnchorIfNeeded(using: proxy)
                }
                .onChange(of: appState.pendingHomeScrollTarget) { _, target in
                    guard let target, !target.isEmpty else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    // Clear after handling so future taps can re-trigger.
                    DispatchQueue.main.async {
                        appState.pendingHomeScrollTarget = nil
                    }
                }
                .onChange(of: appState.pendingTutorialAnchor) { _, _ in
                    scrollToTutorialAnchorIfNeeded(using: proxy)
                }
                .onChange(of: boardItems.isEmpty) { _, isEmpty in
                    guard !isEmpty else { return }
                    scrollToTutorialAnchorIfNeeded(using: proxy)
                }
                .onChange(of: liveBoardItemIDs) { _, _ in
                    refreshCachedBoardItemsIfNeeded()
                }
                .onChange(of: isHomeQueueSyncing) { _, _ in
                    refreshCachedBoardItemsIfNeeded()
                }
                .onChange(of: boardItems.first?.id) { oldTopID, newTopID in
                    guard let newTopID else {
                        firstRenderedBoardTopID = nil
                        hasAutoScrolledToFreshBoardTop = false
                        return
                    }

                    if firstRenderedBoardTopID == nil {
                        firstRenderedBoardTopID = newTopID
                        return
                    }

                    guard oldTopID != nil, oldTopID != newTopID else { return }
                    guard !hasAutoScrolledToFreshBoardTop else { return }
                    guard userStore.hasRefreshedOnce, !userStore.isLoading, billsStore.hasLoadedOnce else { return }

                    // Cold start can restore an older cached queue immediately, then insert newer
                    // bills above the current viewport once refresh completes. Snap back to the
                    // real top once so freshly delivered bills are visible without manual scrolling.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                    firstRenderedBoardTopID = newTopID
                    hasAutoScrolledToFreshBoardTop = true
                }
                .onChange(of: billboardHistoryWindowDays) { _, _ in
                    firstRenderedBoardTopID = nil
                    hasAutoScrolledToFreshBoardTop = false
                    appState.sessionBillboardHistoryWindow = nil
                    Task {
                        await billsStore.load(
                            forceRefresh: true,
                            mode: .manifestOnly,
                            historyWindow: configuredBillboardHistoryWindow
                        )
                    }
                }
            }
        }
        .billboardBackground()
                .task(id: homeHydrationKey) {
                    guard userStore.hasRefreshedOnce else { return }
                    guard !userStore.isLoading else { return }

            let key = homeHydrationKey

            // Switching tabs cancels and re-runs this task. If nothing relevant changed since the
            // last successful run, skip repeating network work.
            if lastFullyHydratedKey == key { return }

            // Ensure we have manifests loaded (TabsBar should do this, but this keeps Home robust).
            if billboardSourceBills.isEmpty {
                guard !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
                await billsStore.load(
                    forceRefresh: false,
                    mode: .manifestOnly,
                    historyWindow: selectedBillboardHistoryWindow
                )
            }

            // Vote filtering relies on:
            // 1) BillVoteCache (persistent, 90-day TTL) — seeded into voteStore on init
            // 2) reconcileVotesFromCache() — called during BillsStore.load(), marks bills as
            //    userVoted if their vote is in the persistent cache
            // No batch pre-fetch needed here. Individual votes are fetched on-demand when
            // the user opens a bill detail (fetchVoteIfNeeded).

            guard !Task.isCancelled else { return }
                    guard billsStore.errorMessage == nil else { return }
                    lastFullyHydratedKey = key
                }
                .onAppear {
                    HomePerfTimeline.mark("billboard_tab_appeared")
                    scheduleDerivedCollectionsRefresh()
                }
                .onReceive(billsStore.$activeManifestBills) { bills in
                    scheduleDerivedCollectionsRefresh(bills: bills)
                }
                .onReceive(billsStore.$companionGroupIndex) { _ in
                    scheduleDerivedCollectionsRefresh()
                }
                .onReceive(readState.$dismissedBillIDs) { _ in
                    scheduleDerivedCollectionsRefresh()
                }
                .onReceive(voteStore.$statesByBillId) { _ in
                    scheduleDerivedCollectionsRefresh()
                }
                .onReceive(userStore.$profile) { _ in
                    scheduleDerivedCollectionsRefresh()
                }
                .onReceive(appState.$sessionBillboardHistoryWindow) { _ in
                    scheduleDerivedCollectionsRefresh()
                }
                .onChange(of: billboardHistoryWindowDays) { _, _ in
                    scheduleDerivedCollectionsRefresh()
                }
                .navigationDestination(
                    isPresented: Binding(
                        get: { presentedQueueBillDetail != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    handleQueueBillDetailDismissal()
                }
            )
        ) {
            if let presentedQueueBillDetail {
                BillDetail(
                    billID: presentedQueueBillDetail.billID,
                    mode: presentedQueueBillDetail.mode,
                    initialBill: presentedQueueBillDetail.initialBill
                )
            } else {
                EmptyView()
            }
        }
    }
}

/// The mono line over the Bills list (Civic Record spec 4.18): "LAST 1 WEEK · IN THE NEWS, THEN NEWEST"
/// in the `docket` role, `ink3` (the role sets the capitals). VoiceOver reads INT-11's sentence: "Bills
/// from the last 1 week. In the news first, then newest."
struct BillBoardListLine: View {
    /// The window's title as `BillboardHistoryWindow.title` gives it: "1 week", "10 days".
    let windowTitle: String

    var printed: String {
        "Last \(windowTitle.lowercased()) · In the news, then newest"
    }

    var spoken: String {
        "Bills from the last \(windowTitle.lowercased()). In the news first, then newest."
    }

    var body: some View {
        Text(printed)
            .textRole(.docket)
            .foregroundStyle(BillboardColors.dimText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .accessibilityLabel(spoken)
    }
}
