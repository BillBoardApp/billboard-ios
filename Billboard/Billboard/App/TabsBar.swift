import SwiftUI

/// The signed-in app: the four tabs and the stores they share.
///
/// The tab bar is `BillboardTabBar`, deep links are routed by `PushDeepLinkRouter`, the
/// product tour runs in `ProductTutorialPresenter` and the badge counts come from
/// `TabBadgeCalculator`. On top of whichever tab is showing it presents the topic picker, the
/// location editor and the first-vote topic prompt, and hosts the undo toast (spec D 2.5.9).
struct TabsBar: View {
    private let userScope: String
    /// The tabs are on screen and usable (`SignedInGate.screen == .tabs` in `RootView`). TabsBar is
    /// mounted, hidden, earlier so bills can load behind the loading, setup and gate screens.
    private let isInteractive: Bool
    @StateObject private var readState: AppReadState
    @StateObject private var weeklyDigestStore: WeeklyDigestStore
    @EnvironmentObject private var userStore: UserStore
    @AppStorage(BillboardDisplayStorage.historyWindowDaysKey) private var billboardHistoryWindowDays = BillboardHistoryWindow.default.rawValue
    // Read to hold deep links back during the tour; `ProductTutorialPresenter` writes them.
    @AppStorage(ProductTutorialStorage.pendingAutoShowKey) private var pendingAutoShowTutorial = false
    @AppStorage(ProductTutorialStorage.replayRequestedKey) private var replayTutorialRequested = false

    init(userScope: String, isInteractive: Bool) {
        self.userScope = userScope
        self.isInteractive = isInteractive
        _readState = StateObject(
            wrappedValue: AppReadState(
                scope: .user(userScope),
                store: UserDefaultsReadStateStore()
            )
        )
        _weeklyDigestStore = StateObject(wrappedValue: WeeklyDigestStore(scope: userScope))
        _billsStore = StateObject(wrappedValue: BillsStore(cacheScope: userScope))
        _billVoteStore = StateObject(wrappedValue: BillVoteStore(scope: userScope))
        _billAlertsStore = StateObject(wrappedValue: BillAlertsStore(scope: userScope))
        _civicScoreStore = StateObject(wrappedValue: CivicScoreStore(scope: userScope))
    }

    @StateObject private var billsStore: BillsStore
    @StateObject private var billVoteStore: BillVoteStore
    @StateObject private var billAlertsStore: BillAlertsStore
    @StateObject private var civicScoreStore: CivicScoreStore
    @StateObject private var civicProfileStore = CivicProfileStore()
    @StateObject private var congressManifestStore = CongressMembersManifestStore()
    @State private var billBoardPath = NavigationPath()
    @State private var updatesPath = NavigationPath()
    @State private var congressPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    /// The Congress tab's search and filter: only the selected tab is built, so the tab cannot keep them.
    @State private var congressSearch = CongressSearchState()

    @StateObject private var appState = AppState()
    @State private var activeSheet: TabsSheet?
    @State private var isShowingTutorialOverlay = false
    @State private var hasCompletedInitialWeeklyDigestBootstrap = false
    @State private var profileDependentReconciliationTask: Task<Void, Never>?
    @State private var deferredHomeQueueRefreshTask: Task<Void, Never>?
    @State private var hasScheduledStartupHomeQueueRefresh = false
    @State private var badgeRecalculator = DebouncedRecalculator(
        debounceNanoseconds: TabsBar.badgeRefreshDebounceNanoseconds,
        priority: .utility
    )
    @State private var cachedHomeBadgeCount = 0
    @State private var cachedUpdatesBadgeCount = 0
    private static let badgeRefreshDebounceNanoseconds: UInt64 = 150_000_000
    /// The undo toast moves VoiceOver focus to its Undo button when it appears (spec D 2.1.2: Undo
    /// gets focus priority). The toast is laid over the tab's content, after all of it in reading
    /// order, so without this a VoiceOver user cannot reach Undo inside its 10 seconds.
    static let focusesUndoWhenVoiceOverRuns = true

    enum AppRoute: Hashable {
        /// A bill opened from a deep link, push or share link. The detail screen fetches the bill on
        /// demand when it is not loaded (APPF-26).
        case billDetail(BillLinkTarget)
        /// A Bills card opened by the tour's "Open this bill", in the mode a tap on the card uses.
        case queueBill(billID: UUID, mode: BillDetail.Mode)

        /// The bill page the route opens on the Bills tab. Both open with the vote bar, a decided bill
        /// too (project decision 1): a push, deep link or share link opens `.full`.
        @MainActor
        func billDetail(in billsStore: BillsStore) -> BillDetail {
            switch self {
            case .billDetail(let target):
                return BillDetail(billID: target.billID, linkGUID: target.guid)
            case .queueBill(let billID, let mode):
                return BillDetail(billID: billID, mode: mode, initialBill: billsStore.bill(for: billID))
            }
        }
    }

    /// The sheets presented over the tabs (one at a time). Each has the system glass bar with system
    /// Cancel, Save and Done buttons in ink, and its content on paper (Civic Record spec 3.21, 4.7).
    enum TabsSheet: Identifiable, Equatable {
        case civicScore
        /// The topic picker, from `.billboardRequestTopicPicker` (the starter-feed banner).
        case topicPicker
        /// The location editor, from `.billboardRequestLocationEditor`.
        case locationEditor
        /// "Want more bills like this?" after the first saved vote, seeded from the voted bill.
        case firstVoteTopics(seedBillID: UUID?)

        var id: String {
            switch self {
            case .civicScore: return "civicScore"
            case .topicPicker: return "topicPicker"
            case .locationEditor: return "locationEditor"
            case .firstVoteTopics(let seedBillID): return "firstVoteTopics.\(seedBillID?.uuidString ?? "none")"
            }
        }
    }

    /// Whether a deep link may navigate now (see `DeepLinkGate`).
    private var isReadyForDeepLinkNavigation: Bool {
        DeepLinkGate.isReady(
            tabsInteractive: isInteractive,
            isCompletingOnboarding: userStore.isCompletingOnboarding,
            isProfileLoading: userStore.isLoading,
            isShowingTour: isShowingTutorialOverlay,
            pendingAutoShowTour: pendingAutoShowTutorial,
            replayTourRequested: replayTutorialRequested
        )
    }

    enum Tab: Int, CaseIterable {
        case home = 0
        case updates = 1
        case congress = 2
        case profile = 3

        var title: String {
            switch self {
            case .home: return "Bills"
            case .updates: return "Updates"
            case .congress: return "Congress"
            case .profile: return "Profile"
            }
        }

        /// The outline symbol of an unselected tab (Civic Record spec 2.10).
        var systemImage: String {
            switch self {
            case .home: return "doc.text"
            case .updates: return "bell"
            case .congress: return "building.columns"
            case .profile: return "person"
            }
        }

        /// The selected tab always shows the filled form, so selection is also a change of shape (spec
        /// 2.10). Bills is `doc.text`, which has one (`doc.text.magnifyingglass` had none).
        var selectedSystemImage: String {
            switch self {
            case .home: return "doc.text.fill"
            case .updates: return "bell.fill"
            case .congress: return "building.columns.fill"
            case .profile: return "person.fill"
            }
        }

        /// The tab button's id for the UI tests. The Bills tab keeps R1's `tab.billboard` (spec D 5.4).
        var accessibilityIdentifier: String {
            switch self {
            case .home: return "tab.billboard"
            case .updates: return "tab.updates"
            case .congress: return "tab.congress"
            case .profile: return "tab.profile"
            }
        }
    }

    private var selectedTab: Tab {
        Tab(rawValue: appState.selectedTab) ?? .home
    }

    @MainActor
    private func bootstrapWeeklyDigestIfNeeded() async {
        guard !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
        guard userStore.hasRefreshedOnce else { return }
        guard !userStore.isLoading else { return }
        guard !hasCompletedInitialWeeklyDigestBootstrap else { return }

        await weeklyDigestStore.refresh(profile: userStore.profile)
        hasCompletedInitialWeeklyDigestBootstrap = true
    }

    /// Waits for an in-flight bills load to finish. Stops early when the task is cancelled
    /// (callers check `Task.isCancelled` afterwards) and gives up after `timeout`; a `load`
    /// started while another is still running is skipped by `BillsStore` anyway.
    @MainActor
    private func waitForBillsStoreToBecomeIdle(timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while billsStore.isLoading, !Task.isCancelled, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        if billsStore.isLoading, !Task.isCancelled {
            HomePerfTimeline.mark("bills_idle_wait_timed_out")
        }
    }

    @MainActor
    private func shouldForceHomeQueueRefreshAfterUserRefresh() -> Bool {
        // If Home already restored a non-empty queue from disk, let that cached snapshot
        // render immediately and avoid paying for a second full manifest pass before the
        // tab becomes interactive. We'll still kick off a background refresh so the queue
        // catches up to the backend manifest, and we keep forcing a blocking refresh when
        // startup has no usable queue yet.
        if !billsStore.activeManifestBills.isEmpty {
            return false
        }

        if !billsStore.bills.isEmpty {
            return false
        }

        return true
    }

    @MainActor
    private func scheduleDeferredHomeQueueRefreshIfNeeded(reason: String = "post_user_refresh") {
        guard deferredHomeQueueRefreshTask == nil else { return }
        guard !hasScheduledStartupHomeQueueRefresh else { return }
        let historyWindow = selectedBillboardHistoryWindow
        hasScheduledStartupHomeQueueRefresh = true
        HomePerfTimeline.mark(
            "home_queue_refresh_deferred",
            detail: "historyWindow=\(historyWindow.rawValue) reason=\(reason)"
        )

        deferredHomeQueueRefreshTask = Task { @MainActor in
            defer { deferredHomeQueueRefreshTask = nil }
            await waitForBillsStoreToBecomeIdle()
            guard !Task.isCancelled else { return }
            HomePerfTimeline.mark(
                "home_queue_refresh_deferred_started",
                detail: "historyWindow=\(historyWindow.rawValue) reason=\(reason)"
            )
            await billsStore.load(
                forceRefresh: true,
                mode: .manifestOnly,
                historyWindow: historyWindow
            )
            HomePerfTimeline.markOnce(
                "home_queue_fully_updated",
                stage: "home_queue_fully_updated",
                detail: "source=deferred_refresh queue=\(billsStore.activeManifestBills.count) reason=\(reason)"
            )
        }
    }

    @MainActor
    private func reconcileProfileDependentStoresAfterUserRefresh() async {
        guard userStore.hasRefreshedOnce else { return }
        HomePerfTimeline.mark(
            "profile_reconciliation_started",
            detail: "hasCachedQueue=\(!billsStore.activeManifestBills.isEmpty)"
        )

        appState.isReconcilingHomeQueue = true
        defer {
            appState.isReconcilingHomeQueue = false
            appState.hasCompletedHomeQueueReconciliation = true
            HomePerfTimeline.mark(
                "profile_reconciliation_completed",
                detail: "activeManifestBills=\(billsStore.activeManifestBills.count)"
            )
        }

        if AppLaunchOptions.shouldStreamlineStartupForUITests {
            scheduleDeferredHomeQueueRefreshIfNeeded(reason: "ui_test_post_user_refresh")
            return
        }

        Task { @MainActor in
            await civicProfileStore.refresh()
        }

        if let deferredHomeQueueRefreshTask {
            await deferredHomeQueueRefreshTask.value
            guard shouldForceHomeQueueRefreshAfterUserRefresh() else { return }
        }

        guard shouldForceHomeQueueRefreshAfterUserRefresh() else {
            scheduleDeferredHomeQueueRefreshIfNeeded()
            return
        }

        await waitForBillsStoreToBecomeIdle()
        guard !Task.isCancelled else { return }
        HomePerfTimeline.mark(
            "home_queue_refresh_blocking_started",
            detail: "historyWindow=\(selectedBillboardHistoryWindow.rawValue)"
        )
        await billsStore.load(
            forceRefresh: true,
            mode: .manifestOnly,
            historyWindow: selectedBillboardHistoryWindow
        )
        HomePerfTimeline.markOnce(
            "home_queue_fully_updated",
            stage: "home_queue_fully_updated",
            detail: "source=blocking_refresh queue=\(billsStore.activeManifestBills.count)"
        )
    }

    @MainActor
    private func scheduleProfileDependentReconciliationIfReady() {
        guard userStore.hasRefreshedOnce, !userStore.isLoading else { return }
        guard profileDependentReconciliationTask == nil else { return }

        profileDependentReconciliationTask = Task { @MainActor in
            defer { profileDependentReconciliationTask = nil }
            await bootstrapWeeklyDigestIfNeeded()
            await reconcileProfileDependentStoresAfterUserRefresh()
        }
    }

    private func select(_ tab: Tab) {
        if selectedTab == tab {
            // Re-tap behavior: pop to root for the current tab.
            switch tab {
            case .home: billBoardPath = NavigationPath()
            case .updates: updatesPath = NavigationPath()
            case .congress: congressPath = NavigationPath()
            case .profile: profilePath = NavigationPath()
            }
        }
        appState.selectedTab = tab.rawValue
    }

    private var selectedBillboardHistoryWindow: BillboardHistoryWindow {
        appState.sessionBillboardHistoryWindow
            ?? BillboardHistoryWindow.from(rawValue: billboardHistoryWindowDays)
    }

    private func makeTabBadgeRefreshSnapshot() -> TabBadgeCalculator.Snapshot {
        TabBadgeCalculator.Snapshot(
            activeManifestBills: billsStore.activeManifestBills,
            allBills: billsStore.bills,
            alerts: billAlertsStore.alerts,
            dismissedBillIDs: readState.dismissedBillIDs,
            readBillAlertIDs: readState.readBillAlertIDs,
            userProfile: userStore.profile,
            unreadDigestCount: weeklyDigestStore.unreadDigestCount,
            historyWindow: selectedBillboardHistoryWindow,
            voteStatesByBillID: billVoteStore.statesByBillId,
            companions: billsStore.companionGroupIndex
        )
    }

    private func scheduleTabBadgeRefresh() {
        badgeRecalculator.schedule(
            snapshot: makeTabBadgeRefreshSnapshot,
            compute: { snapshot in
                TabBadgeCalculator.counts(for: snapshot)
            },
            apply: { counts in
                cachedHomeBadgeCount = counts.home
                cachedUpdatesBadgeCount = counts.updates
            }
        )
    }

    /// Pops anything pushed on the four tabs' navigation stacks.
    private func popAllTabsToRoot() {
        billBoardPath = NavigationPath()
        updatesPath = NavigationPath()
        congressPath = NavigationPath()
        profilePath = NavigationPath()
    }

    // MARK: - Sheets (spec D 2.5.9)

    /// Presents `sheet` unless another sheet is up (a second request while one shows is dropped).
    private func presentSheet(_ sheet: TabsSheet) {
        guard activeSheet == nil else { return }
        activeSheet = sheet
    }

    /// Asks "Want more bills like this?" once per account, when the profile follows no topics and no life
    /// areas (spec D 2.5.6), on the bill page's event (Civic Record spec 4.39): a vote saved there, then Done
    /// or leaving the page (`FirstVoteTopicPromptTrigger`). No timer, so it never covers the reasons picker
    /// or the Results that just opened.
    private func presentFirstVoteTopicPrompt(_ request: FirstVoteTopicPromptTrigger.Request) {
        let userID = userStore.profile.id
        guard TopicPromptPolicy.presents(
            profile: userStore.profile,
            promptShown: FirstRunStorage.topicPromptShown(userID: userID),
            votedByUserID: request.userID,
            isInteractive: isInteractive,
            isShowingTour: isShowingTutorialOverlay,
            isSheetUp: activeSheet != nil
        ) else { return }

        FirstRunStorage.markTopicPromptShown(userID: userID)
        let seedBillID = request.votedGUID.trimmedNonEmpty.flatMap { billsStore.bill(forGUID: $0)?.id }
        activeSheet = .firstVoteTopics(seedBillID: seedBillID)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: TabsSheet) -> some View {
        switch sheet {
        case .civicScore:
            CivicScoreInfoOverlay(store: civicScoreStore)
        case .topicPicker:
            NavigationStack {
                TopicPickerView(context: .profile) {
                    activeSheet = nil
                }
                .glassNavigationBar()
            }
            .presentationBackground(BillboardColors.background)
            .environmentObject(userStore)
        case .locationEditor:
            NavigationStack {
                LocationEditorView(context: .profile) { _ in
                    activeSheet = nil
                }
                .glassNavigationBar()
            }
            .presentationBackground(BillboardColors.background)
            .environmentObject(userStore)
        case .firstVoteTopics(let seedBillID):
            FirstVoteTopicPrompt(seedBill: seedBillID.flatMap { billsStore.bill(for: $0) }) {
                activeSheet = nil
            }
            .environmentObject(userStore)
        }
    }

    // MARK: - Tour

    /// The tour's "Open this bill": opens the first card on Bills in the mode a tap on it uses
    /// (`BillDetail.Mode(opening:)`). The list is derived the way the Bills tab derives it.
    private func openFirstBillsCard() -> Bool {
        let input = BillBoardDerivedCollections.Input(
            bills: billsStore.activeManifestBills,
            dismissedBillIDs: readState.dismissedBillIDs,
            userProfile: userStore.profile,
            historyWindow: selectedBillboardHistoryWindow,
            voteStatesByBillID: billVoteStore.statesByBillId,
            companions: billsStore.companionGroupIndex
        )
        guard let item = BillBoardDerivedCollections.derive(from: input).liveBoardItems.first else {
            return false
        }

        appState.selectedTab = Tab.home.rawValue
        billBoardPath = NavigationPath()
        billBoardPath.append(AppRoute.queueBill(billID: item.bill.id, mode: BillDetail.Mode(opening: item.type)))
        return true
    }

    @ViewBuilder
    private var activeTabView: some View {
        switch selectedTab {
        case .home:
            NavigationStack(path: $billBoardPath) {
                BillBoardTab()
                    .tabRootBar(wordmark: .masthead) { presentSheet(.civicScore) }
                    .navigationDestination(for: AppRoute.self) { route in
                        route.billDetail(in: billsStore)
                    }
            }
        case .updates:
            NavigationStack(path: $updatesPath) {
                NotificationsView(isActive: true)
                    .tabRootBar(wordmark: .compact) { presentSheet(.civicScore) }
            }
        case .congress:
            NavigationStack(path: $congressPath) {
                CongressTab(isActive: true, search: $congressSearch)
                    .tabRootBar(wordmark: .compact) { presentSheet(.civicScore) }
                    .navigationDestination(for: CongressRoute.self) { route in
                        route.destination
                    }
            }
        case .profile:
            NavigationStack(path: $profilePath) {
                ProfileView(isActive: true)
                    .tabRootBar(wordmark: .compact) { presentSheet(.civicScore) }
            }
        }
    }

    var body: some View {
        Group {
            activeTabView
            .environmentObject(readState)
            .environmentObject(billsStore)
            .environmentObject(billVoteStore)
            .environmentObject(billAlertsStore)
            .environmentObject(weeklyDigestStore)
            .environmentObject(appState)
            .environmentObject(userStore)
            .environmentObject(civicScoreStore)
            .environmentObject(civicProfileStore)
            .environmentObject(congressManifestStore)
            // Links and buttons are navy ink app-wide (project decision, 2026-10-17).
            .tint(BillboardColors.interactive)
            .onAppear {
                HomePerfTimeline.startRun(
                    "tabs_bar_appeared",
                    detail: "selectedTab=\(selectedTab.rawValue)"
                )
                billsStore.connect(voteStore: billVoteStore)
                billsStore.connect(userStore: userStore)
                billVoteStore.connect(civicScoreStore: civicScoreStore, civicProfileStore: civicProfileStore)
                scheduleTabBadgeRefresh()
            }
            .task {
                HomePerfTimeline.mark("tabs_bar_bootstrap_task_started")
                if !AppLaunchOptions.shouldStreamlineStartupForUITests {
                    await congressManifestStore.load()
                    HomePerfTimeline.mark("congress_manifest_loaded")
                    await civicScoreStore.refresh()
                    HomePerfTimeline.mark("civic_score_loaded")
                    await bootstrapWeeklyDigestIfNeeded()
                    HomePerfTimeline.mark("weekly_digest_bootstrap_completed")
                }
                scheduleTabBadgeRefresh()
            }
            .task {
                // INT-11: read the Abstains an update from 1.1 left to the server again (once, quiet).
                guard !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
                await billVoteStore.recheckEarlierAbstains()
            }
            // The chips, the Civic Rank sheet and the Civic Profile on a return to the app and a new day.
            .refreshesCivicStats(score: civicScoreStore, profile: civicProfileStore)
            .onReceive(billsStore.$bills) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(billsStore.$activeManifestBills) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(billsStore.$companionGroupIndex) { _ in
                // The publisher fires before the store changes; the refresh reads the store later.
                scheduleTabBadgeRefresh()
            }
            .onReceive(billAlertsStore.$alerts) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(readState.$dismissedBillIDs) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(readState.$readBillAlertIDs) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(billVoteStore.$statesByBillId) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(userStore.$profile) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(appState.$sessionBillboardHistoryWindow) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(weeklyDigestStore.$digest) { _ in
                scheduleTabBadgeRefresh()
            }
            .onReceive(weeklyDigestStore.$settings) { _ in
                scheduleTabBadgeRefresh()
            }
            .onChange(of: billboardHistoryWindowDays) { _, _ in
                scheduleTabBadgeRefresh()
            }
            .onChange(of: userStore.profile.watchedBillGUIDs) { _, watched in
                billsStore.reconcileWatchesFromProfile(watched)
            }
            .onChange(of: billsStore.hasLoadedOnce) { _, loaded in
                // After bills finish loading, reconcile watches so locally watched bills
                // that predate the Watch preference type get backfilled to the backend.
                if loaded, userStore.hasRefreshedOnce {
                    billsStore.reconcileWatchesFromProfile(userStore.profile.watchedBillGUIDs)
                }
            }
            .onChange(of: userStore.hasRefreshedOnce) { _, refreshed in
                if refreshed, billsStore.hasLoadedOnce {
                    billsStore.reconcileWatchesFromProfile(userStore.profile.watchedBillGUIDs)
                }
                scheduleProfileDependentReconciliationIfReady()
            }
            .onChange(of: userStore.isLoading) { _, isLoading in
                if isLoading {
                    appState.isReconcilingHomeQueue = true
                    appState.hasCompletedHomeQueueReconciliation = false
                    return
                }
                scheduleProfileDependentReconciliationIfReady()
            }
            .onChange(of: userStore.profile) { oldProfile, newProfile in
                guard userStore.hasRefreshedOnce else { return }
                guard oldProfile != newProfile else { return }
                guard hasCompletedInitialWeeklyDigestBootstrap else { return }
                Task {
                    await weeklyDigestStore.refresh(profile: newProfile, forceRefresh: true)
                }
            }
            .onChange(of: appState.selectedTab) { _, _ in
                // A tab switch (by the tab bar, a link or the tour) ends the undo window (spec D 2.1.2).
                UndoCenter.shared.commitPending()
            }
        }
        // The tab capsule over the content, and the Undo toast 10 pt above it. While VoiceOver runs,
        // focus moves to Undo when the toast appears (spec D 2.1.2).
        .modifier(
            TabCapsuleHost(
                selectedTab: selectedTab,
                homeBadgeCount: cachedHomeBadgeCount,
                updatesBadgeCount: cachedUpdatesBadgeCount,
                onSelect: select,
                focusUndoWhenVoiceOverRuns: Self.focusesUndoWhenVoiceOverRuns
            )
        )
        .modifier(
            PushDeepLinkRouter(
                billsStore: billsStore,
                billAlertsStore: billAlertsStore,
                readState: readState,
                appState: appState,
                voteStore: billVoteStore,
                billBoardPath: $billBoardPath,
                isReadyForDeepLinks: isReadyForDeepLinkNavigation,
                onCacheRestoreReady: {
                    scheduleDeferredHomeQueueRefreshIfNeeded(reason: "startup_after_cache_restore")
                }
            )
        )
        .modifier(
            ProductTutorialPresenter(
                appState: appState,
                isShowing: $isShowingTutorialOverlay,
                canPresent: isInteractive,
                popToRoot: popAllTabsToRoot,
                openFirstBill: openFirstBillsCard
            )
        )
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .billboardRequestTopicPicker)) { _ in
            guard isInteractive else { return }
            presentSheet(.topicPicker)
        }
        .onReceive(NotificationCenter.default.publisher(for: .billboardRequestLocationEditor)) { _ in
            guard isInteractive else { return }
            presentSheet(.locationEditor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .billboardRequestCongressFollows)) { _ in
            // The Congress stack keeps its screens across tab switches; Members you follow is on its root.
            congressPath = NavigationPath()
            appState.selectedTab = Tab.congress.rawValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .billboardFirstVoteTopicPromptTrigger)) { note in
            guard let request = FirstVoteTopicPromptTrigger.Request(userInfo: note.userInfo) else { return }
            presentFirstVoteTopicPrompt(request)
        }
        .onDisappear {
            // Signed out or switched user: stop waiting on this scope's bills store, and end the
            // undo window so this account's pending skip is not offered to the next one.
            deferredHomeQueueRefreshTask?.cancel()
            profileDependentReconciliationTask?.cancel()
            UndoCenter.shared.commitPending()
        }
    }
}

/// A tab root's bar (Civic Record spec 3.21, 3.23, 3.24): navy, the Civic Score chip leading, the
/// `Wordmark` in the middle (30 pt on Bills, 26 pt on the other roots) and the streak chip trailing. Both
/// chips open the Civic Rank sheet. The chips sit in the system toolbar glass, in its dark appearance.
struct TabRootBar: ViewModifier {
    let wordmark: Wordmark.Size
    let onOpenCivicRank: () -> Void

    func body(content: Content) -> some View {
        content
            .navyNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CivicScoreLeadingBadge(action: onOpenCivicRank)
                        .fixedSize(horizontal: true, vertical: true)
                }

                ToolbarItem(placement: .principal) {
                    Wordmark(size: wordmark)
                }
                // The wordmark is set on the navy itself, not in a glass capsule of its own.
                .sharedBackgroundVisibility(.hidden)

                ToolbarItem(placement: .topBarTrailing) {
                    StreakTrailingBadge(action: onOpenCivicRank)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
    }
}

extension View {
    /// The bar of a tab root (spec 3.21): navy, the chips and the wordmark.
    func tabRootBar(wordmark: Wordmark.Size, onOpenCivicRank: @escaping () -> Void) -> some View {
        modifier(TabRootBar(wordmark: wordmark, onOpenCivicRank: onOpenCivicRank))
    }
}

// MARK: - Tab capsule placement (Civic Record spec 3.22, 4.9)

/// Set by a screen that hides the tab capsule while it shows: the bill page, whose vote panel is the only
/// bar at its bottom edge (project decision 3). OR-reduced, so one screen asking is enough. `TabCapsuleHost`
/// reads it with `onPreferenceChange`.
///
/// The slice 0 spike proved this on the simulator: the capsule hides as a bill page is pushed and comes
/// back about 0.3 to 0.4 s after the pop ends, and a half swipe-back that is cancelled, from the edge or
/// from mid-screen, never brings it back.
struct TabCapsuleHiddenPreference: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Hides the tab capsule while this screen shows (spec 3.10, 3.22).
    func hidesTabCapsule(_ hidden: Bool = true) -> some View {
        preference(key: TabCapsuleHiddenPreference.self, value: hidden)
    }

    /// Hides the tab capsule while this page is the top of its navigation stack (the bill page, project
    /// decision 3): it leaves as the page is pushed, comes back after the page is popped, and comes back
    /// over a page pushed from this one.
    ///
    /// The page counts as on top again only once it has really come back: when a page pushed over it is
    /// popped with the Back button (at the start of that pop, as on a push), or at the end of a swipe-back
    /// that completes. SwiftUI's `onAppear` runs as soon as a swipe-back starts to reveal the page, and its
    /// `onDisappear` only once a cancelled one has snapped back, so a held half swipe from a member page
    /// over a bill page, then cancelled, hid the capsule for the whole hold with the member page still on
    /// screen. A cancelled swipe-back from this page itself changes nothing (slice 0 spike).
    func hidesTabCapsuleWhileOnTop() -> some View {
        modifier(HidesTabCapsuleWhileOnTop())
    }

    /// For a sheet presented from a screen under the tabs: its lists end at its own bottom, not above the
    /// tab capsule. `TabCapsuleHost` gives every scroll view under the tabs a bottom content margin, and a
    /// sheet's content would inherit it from the screen that presents it.
    func withoutTabCapsuleClearance() -> some View {
        contentMargins(.bottom, 0, for: .scrollContent)
    }
}

/// `hidesTabCapsuleWhileOnTop()`: on top from the first appearance until the page disappears, and on top
/// again when it has come back (`SettledAppearanceProbe`).
private struct HidesTabCapsuleWhileOnTop: ViewModifier {
    @State private var isOnTop = true

    func body(content: Content) -> some View {
        content
            .background {
                SettledAppearanceProbe { isOnTop = true }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .onDisappear { isOnTop = false }
            .hidesTabCapsule(isOnTop)
    }
}

/// Calls `onAppear` when the page it is on appears, except at the start of an interactive transition (a
/// swipe-back that reveals the page): then only when that transition completes, never when it is
/// cancelled. A view controller in the page, so UIKit forwards the page's appearance to it.
struct SettledAppearanceProbe: UIViewControllerRepresentable {
    let onAppear: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onAppear = onAppear
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onAppear = onAppear
    }

    final class Controller: UIViewController {
        var onAppear: () -> Void = {}

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            SettledAppearanceProbe.pageWillAppear(transition: transitionCoordinator) { [weak self] in
                self?.onAppear()
            }
        }
    }

    /// Calls `onAppear` now, unless `transition` is interactive: then when it completes, and never if it
    /// is cancelled.
    static func pageWillAppear(transition: (any UIViewControllerTransitionCoordinator)?, onAppear: @escaping () -> Void) {
        guard let transition, transition.isInteractive else {
            onAppear()
            return
        }
        transition.animate(alongsideTransition: nil) { context in
            guard !context.isCancelled else { return }
            onAppear()
        }
    }
}

/// Where the tab capsule and the Undo toast sit (spec 3.19, 3.22, 4.9).
///
/// The spec puts the capsule 24 pt above the screen's bottom edge on a Face ID iPhone, as the system tab
/// bar sits, inside the 34 pt home-indicator area, and 12 pt above it on a phone with a Home button (no
/// bottom safe area). The content under the tabs clears it by `contentClearance`: from the bottom of its
/// safe area up to the capsule's top.
enum TabCapsuleLayout {
    /// From the screen's sides.
    static let sideMargin: CGFloat = 16
    /// Above the bottom edge on a phone with a home indicator.
    static let homeIndicatorMargin: CGFloat = 24
    /// Above the bottom edge on a phone with a Home button.
    static let homeButtonMargin: CGFloat = 12
    /// Between the capsule's top and the Undo toast.
    static let toastGap: CGFloat = 10

    /// The least bottom safe area taken for a home indicator. `safeAreaBottom` is measured, and with no home
    /// indicator it can come back a hair off zero (on the bill page at AX4 on a 375 x 667 window it put the vote
    /// panel 24 pt above the edge instead of 12); a home indicator's is 34 pt (20 or more in any orientation).
    static let homeIndicatorThreshold: CGFloat = 1

    /// The capsule's distance from the bottom edge, for a bottom safe area of `safeAreaBottom`.
    static func bottomMargin(safeAreaBottom: CGFloat) -> CGFloat {
        safeAreaBottom >= homeIndicatorThreshold ? homeIndicatorMargin : homeButtonMargin
    }

    /// From the bottom of the content's safe area up to the capsule's top: 54 pt on a Face ID iPhone
    /// (64 + 24 - 34), 76 pt with a Home button (64 + 12).
    static func contentClearance(safeAreaBottom: CGFloat) -> CGFloat {
        BillboardTabBar.height + bottomMargin(safeAreaBottom: safeAreaBottom) - safeAreaBottom
    }

    /// The Undo toast's bottom padding inside the content's safe area: 10 pt above the capsule's top, or
    /// above the keyboard; where the capsule is hidden and no keyboard is up, the capsule's own margin
    /// above the bottom edge (24 pt, or 12 pt).
    static func toastBottomPadding(capsuleShown: Bool, keyboardShown: Bool, safeAreaBottom: CGFloat) -> CGFloat {
        if capsuleShown { return contentClearance(safeAreaBottom: safeAreaBottom) + toastGap }
        if keyboardShown { return toastGap }
        return bottomMargin(safeAreaBottom: safeAreaBottom) - safeAreaBottom
    }

    /// Where the tour's card ends when the capsule's frame is not known: 10 pt above a capsule 24 pt
    /// above the bottom edge (64 + 24 + 10).
    static let fallbackTourBottomInset: CGFloat = BillboardTabBar.height + homeIndicatorMargin + toastGap

    /// The capsule is shown unless the screen hides it (the bill page) or the keyboard is up. A system
    /// tab bar stays down under the keyboard; this capsule would ride on top of it (on Search, the
    /// members directory and every form under the tabs), so it leaves while the keyboard shows.
    static func showsCapsule(screenHidesCapsule: Bool, keyboardShown: Bool) -> Bool {
        !screenHidesCapsule && !keyboardShown
    }
}

/// Floats the tab capsule over the tabs' content (spec 3.22, 4.9), so content scrolls under the glass,
/// and hosts the Undo toast 10 pt above the capsule's top.
///
/// The capsule is drawn in an overlay that reaches into the home-indicator area, not in a `safeAreaBar`.
/// A `safeAreaBar` stands its bar on that area, 34 pt above the edge; drawn 10 pt lower to sit 24 pt
/// above it, the bottom 10 pt of the capsule (the lower edge of each tab and its inset) fell outside the
/// bar's frame, so taps there went through the glass to the slip or row under it.
///
/// The capsule leaves (slides down and fades in 0.2 s; with Reduce Motion it fades) while a screen hides
/// it (`TabCapsuleHiddenPreference`: the bill page) and while the keyboard is up, and comes back after.
///
/// While it shows, every scroll view and list under the tabs, pushed pages included, ends at the
/// capsule's top: a bottom content margin of `TabCapsuleLayout.contentClearance` (spec 4.9 deleted the
/// fixed spacers that did this). A bar's safe area outside the tabs' navigation stacks does not reach
/// the scroll views inside them, which saw only the 34 pt home-indicator area, so the last 22 to 54 pt
/// of every list sat under the glass. Each screen keeps its own margin under its last item.
struct TabCapsuleHost: ViewModifier {
    let selectedTab: TabsBar.Tab
    let homeBadgeCount: Int
    let updatesBadgeCount: Int
    let onSelect: (TabsBar.Tab) -> Void
    var focusUndoWhenVoiceOverRuns = false
    /// nil means `UndoCenter.shared`.
    var undoCenter: UndoCenter? = nil

    @State private var screenHidesCapsule = false
    @State private var keyboardShown = false
    /// The container's bottom safe area without the keyboard: 34 pt on a Face ID iPhone, 0 with a Home button.
    @State private var safeAreaBottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCapsule: Bool {
        TabCapsuleLayout.showsCapsule(screenHidesCapsule: screenHidesCapsule, keyboardShown: keyboardShown)
    }

    /// The capsule leaves and comes back in 0.2 s: a slide and fade, or a fade with Reduce Motion.
    private let animation = Animation.easeInOut(duration: 0.2)

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TabCapsuleHiddenPreference.self) { hidden in
                guard hidden != screenHidesCapsule else { return }
                withAnimation(animation) { screenHidesCapsule = hidden }
            }
            .contentMargins(
                .bottom,
                showsCapsule ? TabCapsuleLayout.contentClearance(safeAreaBottom: safeAreaBottom) : 0,
                for: .scrollContent
            )
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .undoToastHost(
                center: undoCenter,
                bottomPadding: TabCapsuleLayout.toastBottomPadding(
                    capsuleShown: showsCapsule,
                    keyboardShown: keyboardShown,
                    safeAreaBottom: safeAreaBottom
                ),
                focusUndoWhenVoiceOverRuns: focusUndoWhenVoiceOverRuns
            )
            .overlay(alignment: .bottom) {
                if showsCapsule {
                    BillboardTabBar(
                        selectedTab: selectedTab,
                        homeBadgeCount: homeBadgeCount,
                        updatesBadgeCount: updatesBadgeCount,
                        onSelect: onSelect
                    )
                    .tutorialAnchor(.tabBar)
                    .padding(.horizontal, TabCapsuleLayout.sideMargin)
                    .padding(.bottom, TabCapsuleLayout.bottomMargin(safeAreaBottom: safeAreaBottom))
                    // Measured from the screen's bottom edge, and never lifted by the keyboard.
                    .ignoresSafeArea(.all, edges: .bottom)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background {
                // The bottom safe area, without the keyboard's.
                Color.clear
                    .ignoresSafeArea(.keyboard)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.safeAreaInsets.bottom
                    } action: { bottom in
                        safeAreaBottom = bottom
                    }
                    .accessibilityHidden(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                setKeyboardShown(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                setKeyboardShown(false)
            }
    }

    private func setKeyboardShown(_ shown: Bool) {
        guard shown != keyboardShown else { return }
        withAnimation(animation) { keyboardShown = shown }
    }
}

/// Whether a deep link may navigate now. Pure, for `AppDeepLinkTests`.
///
/// `TabsBar` is mounted, hidden, while the profile loads and while "Where do you vote?", the age gate
/// or another root screen is up (`SignedInGate`), and the tour spotlights the Bills tab. A link that
/// arrives during any of those waits (in `PendingAppDeepLink` or `PendingPushDeepLink`) until the tabs
/// are usable and the tour is over. The setup screen stays up after the district is saved until its
/// Continue, so `isCompletingOnboarding` holds links too.
enum DeepLinkGate {
    static func isReady(
        tabsInteractive: Bool,
        isCompletingOnboarding: Bool,
        isProfileLoading: Bool,
        isShowingTour: Bool,
        pendingAutoShowTour: Bool,
        replayTourRequested: Bool
    ) -> Bool {
        tabsInteractive
            && !isCompletingOnboarding
            && !isProfileLoading
            && !isShowingTour
            && !pendingAutoShowTour
            && !replayTourRequested
    }
}
