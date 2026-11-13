import Combine
import SwiftUI
import UIKit
import UserNotifications

/// The Updates tab: the Weekly Brief, recent actions in Congress on bills you watch, and Passed and
/// Failed bills. Clear hides a row on this device, never votes, and offers Undo (spec D 2.1.3).
///
/// Set as a record (Civic Record spec 4.49): the page title on paper, the Weekly Brief's front page
/// first, then each section under a `SectionHeader` with ruled rows (`UpdatesRows.swift`), all in the
/// 16 pt list gutter. Every row opens its bill with the vote panel, a decided bill's too (project
/// decision 1); no row shows other people's votes (INT-11).
struct NotificationsView: View {
    let isActive: Bool

    @EnvironmentObject private var billAlertsStore: BillAlertsStore
    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var readState: AppReadState
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var userStore: UserStore
    @EnvironmentObject private var civicScoreStore: CivicScoreStore
    @EnvironmentObject private var voteStore: BillVoteStore
    @EnvironmentObject private var weeklyDigestStore: WeeklyDigestStore
    @AppStorage("BillBoard.pushPermission.prompted.v1") private var hasPromptedForPushPermission = false
    @AppStorage("BillBoard.pushPermission.primerDismissed.v1") private var hasDismissedPushPermissionPrimer = false
    @AppStorage(AppNotificationStorage.notificationsEnabledKey) private var notificationsEnabled = true
    @State private var updatesFeed = UpdatesFeedSnapshot.empty
    @State private var pushAuthorizationStatus: UNAuthorizationStatus?
    @State private var didRequestPushPermission = false
    @State private var refreshErrorMessage: String?

    private var passedBills: [Bill] { updatesFeed.passedBills }
    private var failedBills: [Bill] { updatesFeed.failedBills }
    private var activeAlerts: [BillAlert] { updatesFeed.activeAlerts }

    private var weeklyBriefSlot: WeeklyBriefSlot {
        Self.weeklyBriefSlot(
            isEnabled: weeklyDigestStore.settings.isEnabled,
            hasDigest: weeklyDigestStore.digest != nil,
            isLoading: weeklyDigestStore.isLoading,
            errorMessage: weeklyDigestStore.errorMessage,
            isShowingStaleDigest: weeklyDigestStore.isShowingStaleDigest,
            isBriefExpected: Self.isBriefExpected(userStore: userStore, civicScoreStore: civicScoreStore),
            followsSomething: Self.followsSomething(userStore: userStore),
            foundNoBrief: weeklyDigestStore.foundNoBriefThisWeek
        )
    }

    /// Explain what Billboard sends before iOS asks, and only ask when the user opts in.
    private var showsPushPermissionPrimer: Bool {
        notificationsEnabled
            && pushAuthorizationStatus == .notDetermined
            && !hasDismissedPushPermissionPrimer
            && !didRequestPushPermission
    }

    private func refreshPushAuthorizationStatus() async {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        pushAuthorizationStatus = status
    }

    private func requestPushPermission() {
        didRequestPushPermission = true
        hasPromptedForPushPermission = true
        // The app delegate requests authorization and registers for remote notifications.
        NotificationCenter.default.post(name: .billboardShouldPromptPushPermission, object: nil)
    }

    private func dismissPushPermissionPrimer() {
        withAnimation(.easeOut(duration: 0.2)) {
            hasDismissedPushPermissionPrimer = true
        }
    }

    private func refreshUpdates() async {
        await billsStore.load(
            forceRefresh: true,
            mode: .manifestOnly,
            historyWindow: appState.sessionBillboardHistoryWindow ?? .current
        )
        if weeklyDigestStore.settings.isEnabled {
            await weeklyDigestStore.refresh(profile: userStore.profile)
        }
        refreshUpdatesFeed()
        refreshErrorMessage = billsStore.loadErrorMessage
    }

    private func retryWeeklyDigest() {
        Task { await weeklyDigestStore.refresh(profile: userStore.profile, forceRefresh: true) }
    }

    /// - Parameters:
    ///   - companions: The companion groups to use (APPF-23); the store's by default. The
    ///     `$companionGroupIndex` publisher passes the new index, since it fires before the store changes.
    ///   - dismissedBillIDs: The dismissals to use; the read state's by default. The `$dismissedBillIDs`
    ///     publisher passes the new set for the same reason.
    private func refreshUpdatesFeed(companions: CompanionGroupIndex? = nil, dismissedBillIDs: Set<UUID>? = nil) {
        updatesFeed = Self.updatesFeed(
            billsStore: billsStore,
            alerts: billAlertsStore.alerts,
            readState: readState,
            userProfile: userStore.profile,
            voteStore: voteStore,
            historyWindow: appState.sessionBillboardHistoryWindow ?? .current,
            companions: companions, dismissedBillIDs: dismissedBillIDs
        )
    }

    /// A Recent actions row (spec 4.53), with the bill's number when the bill is loaded.
    private func actionRow(_ alert: BillAlert) -> UpdatesActionRow {
        UpdatesActionRow(alert: alert, billNumber: alert.billID.flatMap { billsStore.bill(for: $0)?.officialBillNumber })
    }

    @ViewBuilder
    private func alertRowLinkOrButton(_ alert: BillAlert) -> some View {
        if let billID = alert.billID {
            NavigationLink(destination: { Self.billPage(billID) }) {
                actionRow(alert)
            }
            .simultaneousGesture(TapGesture().onEnded {
                readState.markBillAlertRead(alert.id)
                billAlertsStore.remove(alert.id)
            })
            .buttonStyle(RowButtonStyle())
            .navigationLinkIndicatorVisibility(.hidden)
        } else {
            Button {
                readState.markBillAlertRead(alert.id)
                billAlertsStore.remove(alert.id)
            } label: {
                actionRow(alert)
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    /// A Passed or Failed bills row (spec 4.53): it opens the bill with the vote panel, and Clear hides it.
    private func outcomeRowLink(_ bill: Bill) -> some View {
        NavigationLink(destination: { Self.billPage(bill.id) }) {
            UpdatesOutcomeRow(bill: bill)
        }
        .buttonStyle(RowButtonStyle())
        .navigationLinkIndicatorVisibility(.hidden)
        .updatesListRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                clearBill(bill)
            } label: {
                Label("Clear", systemImage: "xmark")
            }
        }
    }

    var body: some View {
        List {
            // The page title on paper under the compact masthead, with today's date (spec 3.21); its own
            // 4 pt inset puts it at 20 pt on the 16 pt list gutter.
            TimelineView(.everyMinute) { context in
                let dateline = MastheadDateline(date: context.date)
                PageTitle(title: "Updates", deck: dateline.date, deckAccessibilityLabel: dateline.spokenDate)
            }
            .updatesListRow()

            if showsPushPermissionPrimer {
                UpdatesPushPrimer(onEnable: requestPushPermission, onNotNow: dismissPushPermissionPrimer)
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
            }

            // The Weekly Brief first, as a front page with no section head (spec 4.49, 3.26). When an
            // earlier brief is on screen after a failed refresh, the line saying so sits above its slip.
            switch weeklyBriefSlot {
            case .hidden:
                EmptyView()
            case .brief(let staleError):
                if let staleError {
                    WeeklyDigestErrorCard(message: staleError, isShowingPreviousBrief: true, retry: retryWeeklyDigest)
                        .padding(.top, UpdatesLayout.headToContent)
                        .updatesListRow()
                }
                if let digest = weeklyDigestStore.digest {
                    Group {
                        if digest.isRead {
                            WeeklyDigestCompactCard(digest: digest)
                        } else {
                            WeeklyDigestPreviewCard(digest: digest)
                        }
                    }
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
                }
            case .loading:
                WeeklyDigestLoadingCard()
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
            case .howToGetOne:
                UpdatesSectionHint(text: Self.weeklyBriefHowToGetOne)
                    .accessibilityIdentifier("updates.weeklyBrief.howToGetOne")
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
            case .failed(let message):
                WeeklyDigestErrorCard(message: message, isShowingPreviousBrief: false, retry: retryWeeklyDigest)
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
            }

            // The Clear button sits on the title's baseline under the full-width rule (spec 3.5).
            SectionHeader(
                "Recent actions",
                trailing: activeAlerts.isEmpty ? .none : .button(
                    "Clear",
                    accessibilityLabel: "Clear recent actions",
                    accessibilityIdentifier: "updates.actions.clear",
                    action: { clearAllAlerts() }
                )
            )
            .padding(.top, UpdatesLayout.sectionSpacing)
            .updatesListRow()

            if activeAlerts.isEmpty {
                RecordNotice(.nothingYet, title: "No recent actions")
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
            } else {
                UpdatesSectionHint(text: Self.recentActionsHint)
                    .padding(.top, BillboardStyle.Space.s)
                    .updatesListRow()
                ForEach(activeAlerts) { alert in
                    alertRowLinkOrButton(alert)
                        .updatesListRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                clearAlert(alert)
                            } label: {
                                Label("Clear", systemImage: "xmark")
                            }
                        }
                }
            }

            // The Clear button sits on the title's baseline under the full-width rule (spec 3.5).
            SectionHeader(
                "Passed bills",
                trailing: passedBills.isEmpty ? .none : .button(
                    "Clear all",
                    accessibilityLabel: "Clear all passed bills",
                    accessibilityIdentifier: "updates.passed.clearAll",
                    action: { clearBills(passedBills) }
                )
            )
            .padding(.top, UpdatesLayout.sectionSpacing)
            .updatesListRow()

            if passedBills.isEmpty {
                RecordNotice(.nothingYet, title: "No passed bills")
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
            } else {
                ForEach(passedBills) { bill in
                    outcomeRowLink(bill)
                }
            }

            // The Clear button sits on the title's baseline under the full-width rule (spec 3.5).
            SectionHeader(
                "Failed bills",
                trailing: failedBills.isEmpty ? .none : .button(
                    "Clear all",
                    accessibilityLabel: "Clear all failed bills",
                    accessibilityIdentifier: "updates.failed.clearAll",
                    action: { clearBills(failedBills) }
                )
            )
            .padding(.top, UpdatesLayout.sectionSpacing)
            .updatesListRow()

            if failedBills.isEmpty {
                RecordNotice(.nothingYet, title: "No failed bills")
                    .padding(.top, UpdatesLayout.headToContent)
                    .updatesListRow()
            } else {
                ForEach(failedBills) { bill in
                    outcomeRowLink(bill)
                }
            }
        }
        .listStyle(.plain)
        // Rows keep their own measures (spec 2.8): no 44 pt floor that would centre a short row, such as
        // the hint, in extra space.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .refreshable {
            await refreshUpdates()
        }
        .billboardBackground()
        .overlay(alignment: .top) {
            BBErrorBanner(message: $refreshErrorMessage)
        }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard isActive else { return }
            refreshUpdatesFeed()
        }
        .onReceive(Self.billsDidChange(in: billsStore)) { _ in
            refreshUpdatesFeed()
        }
        .onReceive(billsStore.$companionGroupIndex) { companions in
            refreshUpdatesFeed(companions: companions)
        }
        .onReceive(Self.didChange(billAlertsStore.$alerts)) { _ in
            refreshUpdatesFeed()
        }
        .onReceive(readState.$dismissedBillIDs) { dismissedBillIDs in
            refreshUpdatesFeed(dismissedBillIDs: dismissedBillIDs)
        }
        .onReceive(Self.didChange(readState.$readBillAlertIDs)) { _ in
            refreshUpdatesFeed()
        }
        .onReceive(Self.didChange(voteStore.$statesByBillId)) { _ in
            refreshUpdatesFeed()
        }
        .onReceive(Self.didChange(userStore.$profile)) { _ in
            refreshUpdatesFeed()
        }
        .task(id: isActive) {
            // No system prompt here: the primer card asks only when the user opts in.
            guard isActive else { return }
            await refreshPushAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Picks up the answer to the system prompt, or a change made in iOS Settings.
            Task { await refreshPushAuthorizationStatus() }
        }
        .task(id: "\(isActive)|\(weeklyDigestStore.settings.isEnabled)") {
            guard isActive, weeklyDigestStore.settings.isEnabled else { return }
            await weeklyDigestStore.refresh(profile: userStore.profile)
        }
        .accessibilityIdentifier("updates.screen")
    }

    /// Clears one Passed or Failed row (spec D 2.1.3): every companion member is hidden on this device
    /// and no vote is written; the watch is removed when the Undo window closes.
    private func clearBill(_ bill: Bill) {
        billsStore.skipWithUndo(
            [.closedBill(bill.id)],
            message: .cleared(numbers: SkipUndoMessage.billNumbers(for: bill, companions: billsStore.companionGroupIndex)),
            readState: readState,
            alertsStore: billAlertsStore
        )
    }

    /// Clear all on Passed or Failed bills: one action, one Undo.
    private func clearBills(_ bills: [Bill]) {
        guard !bills.isEmpty else { return }
        billsStore.skipWithUndo(
            bills.map { .closedBill($0.id) },
            message: .clearedBills(count: bills.count),
            readState: readState,
            alertsStore: billAlertsStore
        )
    }

    /// Clears one action in Congress: marked read and removed, with Undo.
    private func clearAlert(_ alert: BillAlert) {
        billsStore.skipWithUndo(
            [.alert(alert.id)],
            message: .clearedActions(count: 1),
            readState: readState,
            alertsStore: billAlertsStore
        )
    }

    /// The section's Clear: marks the shown actions read and empties the store (as in R1), with Undo.
    private func clearAllAlerts() {
        let shown = activeAlerts
        guard !shown.isEmpty else { return }
        let center = UndoCenter.shared
        center.commitPending()
        let receipt = billsStore.clearAllAlerts(
            markingRead: shown.map(\.id),
            readState: readState,
            alertsStore: billAlertsStore
        )
        billsStore.registerUndo(
            for: receipt,
            message: .clearedActions(count: shown.count),
            readState: readState,
            alertsStore: billAlertsStore,
            undoCenter: center
        )
    }
}

extension NotificationsView {
    /// Emits after each write to `billsStore.bills`. `$bills` sends before the write (willSet), so a
    /// handler that reads the store from it sees the old bills, and `bill(for:)` still reads the old
    /// lookups. This hops to the next main-queue turn, by when the write and the rest of the apply that
    /// made it (a manifest apply writes the merged bills, then reconciles votes) are done.
    static func billsDidChange(in billsStore: BillsStore) -> Publishers.ReceiveOn<Published<[Bill]>.Publisher, DispatchQueue> {
        didChange(billsStore.$bills)
    }

    /// Emits on the next main-queue turn after `publisher` sends. A store's `@Published` publisher sends
    /// before the store changes (willSet), so a handler that reads the store from it sees the old value; by
    /// the next turn the write is done (APPF-31: the profile, votes, alerts and read alerts).
    ///
    /// The result keeps its concrete type, with no `map` or `AnyPublisher`: `body` builds it again on every
    /// update, and `onReceive` keeps its subscription only while the new publisher equals the old one (the
    /// same subject on the main queue). An erased publisher is a new object each time, so every update
    /// resubscribed, and a resubscription replays the current value: one more full feed rebuild per handler.
    static func didChange<Value>(_ publisher: Published<Value>.Publisher) -> Publishers.ReceiveOn<Published<Value>.Publisher, DispatchQueue> {
        publisher.receive(on: DispatchQueue.main)
    }

    /// The Updates feed for the stores' current state. With companion groups (APPF-23) a vote on one
    /// member hides every member's Passed or Failed row and alerts, and a partner loaded only for
    /// Home's group card (outside `historyWindow`, not watched) is not listed.
    static func updatesFeed(
        billsStore: BillsStore,
        alerts: [BillAlert],
        readState: AppReadState,
        userProfile: UserProfile,
        voteStore: BillVoteStore,
        historyWindow: BillboardHistoryWindow = .current,
        companions: CompanionGroupIndex? = nil,
        dismissedBillIDs: Set<UUID>? = nil
    ) -> UpdatesFeedSnapshot {
        UpdatesDerivation.feedSnapshot(
            bills: billsStore.bills,
            alerts: alerts,
            dismissedBillIDs: dismissedBillIDs ?? readState.dismissedBillIDs,
            readBillAlertIDs: readState.readBillAlertIDs,
            userProfile: userProfile,
            voteLookup: { guid in voteStore.vote(for: guid) },
            billLookup: { billID in billsStore.bill(for: billID) },
            companions: companions ?? billsStore.companionGroupIndex,
            historyWindow: historyWindow
        )
    }
}

private extension View {
    /// A row of the Updates list (spec 4.49): in the 16 pt gutter, on paper, without the system separator
    /// (rows draw their own hairline). A link row also hides the system's disclosure chevron
    /// (`navigationLinkIndicatorVisibility(.hidden)` on the link): in a plain List it takes a trailing
    /// column, so the row would stop short of the gutter and a read Weekly Brief would show two chevrons.
    func updatesListRow() -> some View {
        self
            .padding(.horizontal, UpdatesLayout.gutter)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(BillboardColors.background)
    }
}

extension NotificationsView {
    /// What the top of Updates shows for the Weekly Brief.
    enum WeeklyBriefSlot: Equatable {
        /// Nothing: the brief is off in Profile, or none came this week and none is being built.
        case hidden
        /// The brief: its UNREAD front page or, once opened, its row. `staleError` is the line saying an earlier
        /// week's brief is on screen because this week's could not be loaded.
        case brief(staleError: String?)
        /// "Building your Weekly Brief", while the brief the person can expect is loading.
        case loading
        /// Nothing followed or watched, and this week's check found no brief: one quiet line on how to get one.
        case howToGetOne
        /// COULDN'T LOAD with Retry, when there is no brief to show.
        case failed(message: String)
    }

    /// The quiet line for someone who follows nothing a brief is built from (feature review N2).
    static let weeklyBriefHowToGetOne = "Follow topics or members to get a Weekly Brief."

    /// Whether the account follows something a brief is built from (`WeeklyDigestStore.followsSomething`). The
    /// profile's follows count once they are the account's: a finished profile load without an error, or the copy
    /// saved on the device (the rule `UserStore.lacksLocationAfterRefresh` uses). A first launch whose preferences
    /// request failed has the account's id and no follows, and that person may follow topics.
    static func followsSomething(userStore: UserStore) -> Bool {
        WeeklyDigestStore.followsSomething(
            userStore.profile,
            followsAreKnown: userStore.hasRefreshedOnce && userStore.errorMessage == nil
        )
    }

    /// Whether the person has voted, from the Civic Score's Bills voted (`totalVotes`, server read or this user's
    /// cached copy), or nil before the score has loaded.
    static func hasVoted(civicScoreStore: CivicScoreStore) -> Bool? {
        guard civicScoreStore.phase == .loaded else { return nil }
        return civicScoreStore.score.totalVotes > 0
    }

    /// Whether Updates shows the brief's loading slip for this account (`WeeklyDigestStore.isBriefExpected`): it
    /// follows something a brief is built from, or has voted.
    static func isBriefExpected(userStore: UserStore, civicScoreStore: CivicScoreStore) -> Bool {
        WeeklyDigestStore.isBriefExpected(
            for: userStore.profile,
            followsAreKnown: userStore.hasRefreshedOnce && userStore.errorMessage == nil,
            hasVoted: hasVoted(civicScoreStore: civicScoreStore)
        )
    }

    /// The Weekly Brief's slot at the top of Updates. A brief on hand always shows. Without one, the loading slip
    /// shows only while a brief is expected (`isBriefExpected`): the person follows something a brief is built from
    /// or has voted, since the server's brief also lists bills they voted on that were updated that week. For
    /// someone who follows no topics, life areas or members, watches no bills and never voted, it flashed on every
    /// visit and came to nothing (feature review N2), so they see nothing while it loads. Someone who follows
    /// nothing (`followsSomething` false) gets one quiet line on how to get a brief once this week's check found
    /// none (`foundNoBrief`), kept while Updates checks again. A failed check is COULDN'T LOAD for everyone, as the
    /// brief might have come.
    static func weeklyBriefSlot(
        isEnabled: Bool,
        hasDigest: Bool,
        isLoading: Bool,
        errorMessage: String?,
        isShowingStaleDigest: Bool,
        isBriefExpected: Bool,
        followsSomething: Bool,
        foundNoBrief: Bool
    ) -> WeeklyBriefSlot {
        guard isEnabled else { return .hidden }
        if hasDigest {
            // A failed refresh matters only when the brief on screen is from an earlier week.
            let staleError = !isLoading && isShowingStaleDigest ? errorMessage : nil
            return .brief(staleError: staleError)
        }
        let howToGetOne = !followsSomething && foundNoBrief
        if isLoading {
            // Checking again keeps the line this week's earlier check put up.
            if howToGetOne { return .howToGetOne }
            return isBriefExpected ? .loading : .hidden
        }
        if let errorMessage { return .failed(message: errorMessage) }
        return howToGetOne ? .howToGetOne : .hidden
    }

    /// The hint over Recent actions. Its rows are bills the user has not voted on, and each opens with the
    /// vote bar, so it does not say that no vote is needed.
    static let recentActionsHint = "Things Congress did on bills you watch."

    /// The page an Updates row opens (Recent actions, Passed bills and Failed bills): the full
    /// page with the vote bar, a decided bill's too (Civic Record project decision 1). `DecidedBillVotingTests`
    /// opens it from here.
    static func billPage(_ billID: UUID) -> BillDetail {
        BillDetail(billID: billID)
    }
}
