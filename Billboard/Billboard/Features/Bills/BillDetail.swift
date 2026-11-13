import SwiftUI
import Foundation

struct BillDetail: View {
    /// Which vote bar the screen pins (spec D 2.1.4). Every bill page pins one, wherever it was opened
    /// from: a bill Congress has decided (Passed, Failed, Became law) stays open to votes (Civic Record
    /// project decision 1), so there is no read-only bill page. `init(opening:)` picks the mode for a
    /// listed item.
    enum Mode: Equatable {
        /// Yea, Nay and Abstain; "You voted Yea · Change" once voted. New and decided bills.
        case full
        /// An updated bill opened where it is listed as updated (Bills, Skipped, the Weekly Brief); an
        /// "updated" push may have cleared its vote: "This bill's summary changed. Vote again:" over
        /// the three buttons.
        case updatedOnly
    }

    /// The bill the screen was opened for.
    private let openedBillID: UUID
    /// The guid a deep link, push or share link opened (APPF-26), fetched when its bill is not loaded.
    private let linkGUID: String?
    var mode: Mode = .full

    @EnvironmentObject private var billsStore: BillsStore
    @State private var isPreparingBillDetails = true
    @State private var fallbackBill: Bill?
    @State private var hydrationErrorMessage: String?
    /// The bill whose content the screen shows (with the opened bill it was chosen for), fixed once
    /// its details are ready so a companion bill loaded later (a vote's placeholder, the In Congress
    /// fetch) does not swap the content.
    @State private var lockedContent: (openedID: UUID, contentID: UUID)?
    /// The on-demand load of a linked bill that is not loaded (APPF-26).
    @State private var linkedBillPhase: LinkedBillPhase = .idle
    /// The id the linked bill loaded under, when the API answered with another guid than the link's.
    @State private var linkedBillID: UUID?

    init(billID: UUID, mode: Mode = .full, initialBill: Bill? = nil, linkGUID: String? = nil) {
        self.openedBillID = billID
        self.mode = mode
        self.linkGUID = BillsStore.trimmedOrNil(linkGUID)
        _fallbackBill = State(initialValue: initialBill)
    }

    /// The opened bill: the linked bill's id once it loaded under another id, else the opened id.
    private var billID: UUID { linkedBillID ?? openedBillID }

    /// The companion group (APPF-23) of the opened bill, or nil. The screen shows the group for
    /// either member.
    private var companionGroup: BillCompanionGroup? {
        if let group = billsStore.companionGroup(forBillID: billID) { return group }
        guard let fallbackBill else { return nil }
        return billsStore.companionGroupIndex.group(for: fallbackBill)
    }

    /// The id of the group primary's loaded bill when the opened bill is another member; nil otherwise.
    private var loadedPrimaryBillID: UUID? {
        guard let group = companionGroup,
              let primary = billsStore.loadedBills(ofMember: group.primaryGuid).first,
              primary.id != billID else { return nil }
        return primary.id
    }

    private var lockedContentBillID: UUID? {
        guard let lockedContent, lockedContent.openedID == billID else { return nil }
        return lockedContent.contentID
    }

    /// The bill the screen shows: for a companion group, the primary's bill when it is loaded (its
    /// title, summary, breakdown and sponsor), else the opened bill.
    private var bill: Bill? {
        let contentID = lockedContentBillID ?? loadedPrimaryBillID ?? billID
        if contentID != billID, let content = billsStore.bill(for: contentID) { return content }
        return billsStore.bill(for: billID) ?? fallbackBill
    }

    private var canHydrateBillDetail: Bool {
        guard let guid = bill?.guid?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !guid.isEmpty
    }

    private var isBillDetailReady: Bool {
        Self.isDetailReady(bill, in: billsStore)
    }

    private func retryLoad() {
        Task { await prepareBillDetailsIfNeeded() }
    }

    @MainActor
    private func prepareBillDetailsIfNeeded() async {
        // A linked bill that is not loaded is fetched first; its arrival restarts this task (APPF-26).
        if bill == nil, linkGUID != nil {
            await loadLinkedBill()
            return
        }

        if lockedContentBillID == nil {
            let openedID = billID
            let contentID = await resolveContentBillID()
            guard !Task.isCancelled else { return }
            lockedContent = (openedID, contentID)
        }
        let contentID = lockedContentBillID ?? billID

        guard let bill else {
            isPreparingBillDetails = false
            return
        }
        guard !billsStore.isBillDetailHydrated(bill) else {
            isPreparingBillDetails = false
            return
        }
        guard canHydrateBillDetail else {
            isPreparingBillDetails = false
            return
        }

        isPreparingBillDetails = true
        hydrationErrorMessage = nil
        if billsStore.bill(for: contentID) != nil {
            // This screen shows the failure itself (with Retry), so skip the shared banner.
            hydrationErrorMessage = await billsStore.ensureHydrated(billID: contentID, reportsError: false)
        } else if let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
            do {
                let processed = try await BillsService.getProcessedBill(
                    guid: guid,
                    congress: bill.congress,
                    billType: bill.billType,
                    billID: bill.billID
                )
                billsStore.upsertProcessedBill(processed)
                fallbackBill = processed
            } catch {
                if APIErrorResponse.isCancellation(error) { return }
                hydrationErrorMessage = UserFacingLoadError.message(for: error, loading: "this bill")
                #if DEBUG
                print("[BillDetail] Failed to load bill guid=\(guid): \(APIErrorDebug.debugString(for: error))")
                #endif
            }
        }
        if let refreshedBill = billsStore.bill(for: billID) {
            fallbackBill = refreshedBill
        }
        isPreparingBillDetails = false
    }

    /// Fetches the linked bill on demand (APPF-26); `missingBillContent` shows the outcome.
    @MainActor
    private func loadLinkedBill() async {
        guard let linkGUID else { return }
        linkedBillPhase = .loading
        let result = await billsStore.loadLinkedBill(BillLinkTarget(billID: billID, guid: linkGUID))
        // A cancelled load leaves the screen as it is: it was left, or the bill arrived meanwhile.
        guard let phase = Self.linkedBillPhase(after: result) else { return }
        if case .loaded(let loadedID) = result {
            if loadedID != billID { linkedBillID = loadedID }
            // The screen's copy: a manifest load drops a bill outside the window from the store.
            fallbackBill = billsStore.bill(for: loadedID) ?? fallbackBill
        }
        linkedBillPhase = phase
    }

    /// The bill to show (APPF-23): a companion group's primary when its bill is loaded and its details
    /// load, else the opened bill.
    @MainActor
    private func resolveContentBillID() async -> UUID {
        guard let primaryID = loadedPrimaryBillID else { return billID }
        if let primary = billsStore.bill(for: primaryID), billsStore.hasBillDetails(primary) {
            return primaryID
        }
        isPreparingBillDetails = true
        let failure = await billsStore.ensureHydrated(billID: primaryID, reportsError: false)
        return failure == nil ? primaryID : billID
    }

    var body: some View {
        Group {
            if let bill = bill {
                if !isBillDetailReady && isPreparingBillDetails {
                    BillDetailLoadingView()
                } else if !isBillDetailReady {
                    BillDetailLoadErrorView(
                        title: "Couldn't load this bill.",
                        message: hydrationErrorMessage ?? "Check your connection and try again.",
                        retry: retryLoad
                    )
                } else {
                    BillDetailContent(bill: bill, billID: billID, mode: mode, companionGroup: companionGroup)
                }
            } else {
                BillDetailMissingBillView(content: Self.missingBillContent(linkGUID: linkGUID, phase: linkedBillPhase), retry: retryLoad)
            }
        }
        // Runs again when a newer manifest row marks the details stale (or the bill arrives), so they
        // are fetched again while the screen keeps showing them.
        .task(id: Self.hydrationTaskKey(billID: billID, bill: bill, in: billsStore)) {
            await prepareBillDetailsIfNeeded()
        }
        .onAppear {
            Self.endUndoWindow()
        }
        // The vote bar is the only bar at the bottom of a bill page, in every mode: the tab capsule leaves
        // as the page is pushed, comes back after it is popped and over a page pushed from it (a member
        // page), and stays put through a cancelled half swipe-back from either (project decision 3, spec 3.10).
        .hidesTabCapsuleWhileOnTop()
        // The glass bar in every state, loading, load error and not found included: a deep link, a push,
        // the Weekly Brief or a bill not loaded yet often opens the page in one of those, straight from a
        // navy tab root (spec 3.21, 4.6).
        .glassNavigationBar()
        .accessibilityIdentifier("bill.detail")
    }

    /// The inline title on the page's glass bar, once the bill's own title has scrolled under it.
    static let inlineTitle = "Bill"
    static let doneTitle = "Done"
    static let doneIdentifier = "bill.done"
    /// How long after a vote made on the page Your vote scrolls to the top (spec 3.13, 5.1).
    static let yourVoteScrollDelay: TimeInterval = 0.4
    /// How long after a refusal VoiceOver focus moves to the refusal strip: once the panel's 0.2 s
    /// cross-fade back has drawn it.
    static let refusalFocusDelay: TimeInterval = 0.25

    /// Whether a vote cast on the page scrolls Your vote to the top (spec 3.13): the first vote made here, as
    /// R2's post-vote scroll was (and again after a refused one, which clears `afterAVoteHere`). A Change
    /// after it, and Try again on "Results show once your vote is saved." (which sends the vote again from
    /// the Results area), leave the page where the user is.
    static func scrollsToYourVote(afterAVoteHere: Bool, isRetry: Bool) -> Bool {
        !afterAVoteHere && !isRetry
    }

    /// The vote panel's bottom padding inside its `safeAreaBar` (spec 3.10, 4.9): its bottom edge sits where
    /// the tab capsule's would, 24 pt above the screen's bottom edge on a phone with a home indicator, 12 pt
    /// with a Home button. A `safeAreaBar` stands its bar on the 34 pt home-indicator area (slice 0 spike), so
    /// the panel reaches 10 pt into it there. Only the panel's glass rim is in those 10 pt: its buttons end
    /// 10 pt above its bottom edge.
    static func panelBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        TabCapsuleLayout.bottomMargin(safeAreaBottom: safeAreaBottom) - safeAreaBottom
    }

    /// Posts `text` for VoiceOver as a queued announcement, so it waits for the current speech (spec 3.10.3).
    static func postQueuedAnnouncement(_ text: String) {
        let announcement = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    /// Opening a bill ends the undo window (spec D 2.1.2): every bill page pins the vote panel at the
    /// bottom edge where the undo toast sits (the tab capsule leaves the bill page), so the toast would
    /// cover Yea, Nay and Abstain, and a tap on Abstain would land on Undo. The pending skip or Clear
    /// commits, as on a tab switch.
    /// `center` nil means `UndoCenter.shared`.
    static func endUndoWindow(center: UndoCenter? = nil) {
        (center ?? .shared).commitPending()
    }
}

// MARK: - The vote bar a listed bill opens with (Civic Record project decision 1)

extension BillDetail.Mode {
    /// A Bills or Skipped card, or the tour's "Open this bill" (the first Bills card): an updated bill
    /// asks for a new vote, and every other card opens with Yea, Nay and Abstain. That includes a
    /// decided bill (`.passed`: Passed, Failed or Became law; the Bills list does not queue one, but a
    /// vote on it is allowed) and a Congress action (`.alert`), which opens its bill's page.
    init(opening type: BillBoardItem.ItemType) {
        switch type {
        case .updated:
            self = .updatedOnly
        case .bill, .passed, .alert:
            self = .full
        }
    }

    /// A Weekly Brief item, by the state the brief gives its bill: an updated bill asks for a new vote,
    /// and a new or decided one (Passed, Failed, Became law) opens with Yea, Nay and Abstain.
    init(opening state: WeeklyDigestItem.BillState?) {
        switch state {
        case .updated:
            self = .updatedOnly
        case .new, .passed, .failed, .finalized, .none:
            self = .full
        }
    }
}

private struct BillDetailContent: View {
    let bill: Bill
    let billID: UUID
    let mode: BillDetail.Mode
    /// The companion group (APPF-23) the screen shows, or nil for a bill in no group.
    let companionGroup: BillCompanionGroup?

    @EnvironmentObject private var billsStore: BillsStore
    @EnvironmentObject private var voteStore: BillVoteStore
    @EnvironmentObject private var readState: AppReadState
    @EnvironmentObject private var userStore: UserStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Set by the tour's "Open this bill" until a vote is saved or the user taps Not now (spec D 2.5.5).
    @AppStorage(FirstRunStorage.voteCoachMarkPendingKey) private var voteCoachMarkPending = false

    @State private var isChangingVote = false
    @State private var didJustVote = false
    /// The vote chosen on this screen, Abstain included (the vote store publishes an abstention as
    /// not voted; `heldVote(for:)` still finds its row). Cleared when the server refuses it (APPF-27).
    @State private var pendingVote: UserVote?
    /// The votes cast here that the server has not answered, so a refused one rolls back (APPF-27).
    @State private var voteCasts = BillVoteCastLedger()
    /// The Watch controls' value until the stores reflect the toggle.
    @State private var watchOverride: Bool?
    /// Counts the votes that scroll Your vote to the top (spec 3.13): see `BillDetail.scrollsToYourVote`.
    @State private var yourVoteScrollCount = 0
    /// Where the bill's title ends, in the page's content: the bar shows "Bill" once it has scrolled under
    /// the bar (spec 4.28, `DocumentInlineTitle`).
    @State private var titleBottom: CGFloat = 0
    @State private var pendingReasons: Set<VoteReason> = []
    /// Reasons last sent to the server with the current vote.
    @State private var syncedReasons: Set<VoteReason> = []
    @State private var reasonSyncTask: Task<Void, Never>?
    @State private var statsRefreshTask: Task<Void, Never>?
    /// Set while the post-vote results refresh has not finished, so it can run again when the
    /// screen comes back after something (such as the sponsor page) was pushed on top.
    @State private var hasPendingStatsRefresh = false
    @State private var isOnScreen = false
    @State private var billStats: BillStatsService.BillStats?
    @State private var isLoadingBillStats = false
    @State private var billStatsError: String?
    /// The server answered `RESULTS_LOCKED` although the screen shows a vote (one not saved yet, INT-11):
    /// "Results show once your vote is saved." with Try again, until stats load or Results lock again.
    @State private var resultsAwaitingSave = false
    /// The page's last read of the user's vote failed (offline, a server error). While the vote state is
    /// still unknown the page then says "Couldn't check your vote on this bill." with Try again, instead
    /// of "Checking your vote…" for a read that has ended.
    @State private var voteCheckFailed = false
    /// Where the page moves VoiceOver focus on purpose (spec 3.10.3): the vote panel's first button (the
    /// sealed Results' "Go to vote buttons"), the stamp after a vote, the refusal strip after a refusal, the
    /// Results title (the stamp's "Go to Results").
    @AccessibilityFocusState private var voteFocus: VoteFocusTarget?
    /// Focus and announcements around a vote made here (`VoteFocusPlanner`).
    @State private var focusPlanner = VoteFocusPlanner()
    /// The vote just tapped, drawn inked for the moment before it becomes the stamp (spec 5.1).
    @State private var inkedVote: VoteChoice?
    /// Counts votes committed here: the one rigid haptic, and which commit the moment's timers belong to.
    @State private var voteCommits = 0
    /// The refused vote's reason (APPF-27, spec 3.10.2), shown in the panel (or Your vote) until the next vote
    /// tap or Change.
    @State private var refusalText: String?
    /// Counts refusals: the error haptic.
    @State private var refusals = 0
    /// Counts refusals shown as a row of Your vote (from xxxLarge up), which the page scrolls to.
    @State private var refusalScrollCount = 0
    /// The page's bottom safe area without the panel: 34 pt with a home indicator, 0 with a Home button.
    @State private var safeAreaBottom: CGFloat = 0
    /// A vote saved here, then Done or leaving the page, asks for the first-vote topic prompt (spec 4.39).
    @State private var topicPrompt = TopicPromptTriggerBox()

    /// The counted vote (Yea or Nay): the one made here, else the stores'.
    private var currentVote: UserVote? {
        if let pendingVote, pendingVote.countsAsVote { return pendingVote }
        if let companionVote {
            // A group's vote is its counted row (the primary's, else the other member's).
            guard let vote = companionVote.effectiveVote, vote.countsAsVote else { return nil }
            return UserVote(vote)
        }
        return BillVoteBarModel.storedCountedVote(
            voteStoreState: billGuid.map { voteStore.vote(for: $0) } ?? .unknown,
            billVote: bill.userVote
        )
    }

    private var currentVoteType: VoteType? {
        currentVote?.voteType
    }

    private var currentVoteState: VoteState {
        if let voteType = currentVoteType {
            return .voted(voteType)
        }
        if let companionGroup {
            return companionVoteState(for: companionGroup)
        }
        // A bill with no guid has no vote row to read: its counted vote (above) is all there is.
        guard let billGuid else { return .notVoted }
        let state = voteStore.vote(for: billGuid)
        if case .unknown = state, !bill.userVoted, bill.userVote?.countsAsVote != true {
            return .unknown
        }
        return .notVoted
    }

    /// The vote state is unknown and its read has not ended: "Checking your vote…". Not once the read
    /// failed (`isVoteCheckFailed`).
    private var isCheckingVote: Bool {
        currentVoteState == .unknown && !voteCheckFailed
    }

    /// The vote state is unknown because its read failed: "Couldn't check your vote on this bill."
    private var isVoteCheckFailed: Bool {
        currentVoteState == .unknown && voteCheckFailed
    }

    /// The vote row the vote store holds for this bill, Abstain included (`vote(for:)` reports an
    /// Abstain as not voted): for a companion group, its counted row.
    private var heldVoteType: VoteType? {
        if let companionVote { return companionVote.effectiveVote }
        guard let billGuid else { return nil }
        return voteStore.heldVote(for: billGuid)
    }

    /// When the held row was cast (`BillVoteStore.heldVoteDate(for:)`; for a companion group, its
    /// counted row's), or nil when not known.
    private var heldVoteDate: Date? {
        if let companionVote {
            guard let guid = companionVote.countedRow?.guid else { return nil }
            return voteStore.heldVoteDate(for: guid)
        }
        guard let billGuid else { return nil }
        return voteStore.heldVoteDate(for: billGuid)
    }

    /// The first line of Your vote: "You haven't voted on this bill." until a vote is held or made here
    /// (an Abstain included, which the vote store reports as not voted), "Checking your vote…" while the
    /// vote is read and "Couldn't check your vote on this bill." when that read failed.
    private var yourVoteStanding: BillYourVoteSection.Standing {
        if pendingVote != nil || barChoice != nil || currentVoteType != nil || heldVoteType != nil {
            return .voted
        }
        switch currentVoteState {
        case .voted: return .voted
        case .notVoted: return .notVoted
        case .unknown: return voteCheckFailed ? .checkFailed : .checking
        }
    }

    /// The vote the bar shows: the one made here, else a counted vote, else an Abstain the vote store
    /// holds (so reopening a bill the user abstained on shows "You abstained" with Results open). In
    /// `.updatedOnly` a held Abstain cast before the bill's update (`storedAt`) asks for a vote again;
    /// one cast since, such as on this screen before, still shows.
    private var barChoice: VoteChoice? {
        BillVoteBarModel.shownChoice(
            pending: pendingVote.map { VoteChoice($0.voteType) },
            counted: currentVoteType.map(VoteChoice.init),
            held: heldVoteType,
            mode: mode,
            heldVotedAt: heldVoteDate,
            billUpdatedAt: FlexibleISO8601.parse(bill.storedAt)
        )
    }

    /// The Watch and Share glyphs' colour (`DocumentToolbarGlyph`), from the page's appearance.
    private var toolbarGlyphColor: Color? {
        DocumentToolbarGlyph.color(
            dark: colorScheme == .dark,
            increaseContrast: colorSchemeContrast == .increased,
            reduceTransparency: reduceTransparency
        )
    }

    private var voteBarModel: BillVoteBarModel {
        let choice = barChoice
        return BillVoteBarModel(
            mode: mode,
            choice: choice,
            isChecking: isCheckingVote,
            isChanging: isChangingVote,
            recordsHeldAbstain: BillVoteBarModel.recordsHeldAbstain(
                pending: pendingVote.map { VoteChoice($0.voteType) },
                shown: choice,
                isListedHere: !billsStore.isDismissed(billID: billID, readState: readState)
            )
        )
    }

    private var showsVoteCoachMark: Bool {
        voteBarModel.showsCoachMark(pending: voteCoachMarkPending)
    }

    private var sizeClass: BillVoteBarModel.TextSizeClass {
        BillVoteBarModel.TextSizeClass(dynamicTypeSize)
    }

    /// The panel's strips that are rows of Your vote from xxxLarge up, and the full stamp at the
    /// accessibility sizes (spec 3.10, 3.13).
    private var movedVoteRows: BillVoteBarModel.YourVoteRows {
        voteBarModel.yourVoteRows(in: sizeClass, refusal: refusalText, showsCoachMark: showsVoteCoachMark)
    }

    /// When the shown vote was cast, for the stamp's date: the held row's time, else the bill's.
    private var shownVoteDate: Date? {
        heldVoteDate ?? bill.lastVotedAt
    }

    /// Plays VoiceOver's part of a plan: moves focus, or posts a queued announcement.
    private func apply(_ plan: VoteFocusPlanner.Plan) {
        if let focus = plan.focus {
            voteFocus = focus
        }
        if let announcement = plan.announcement {
            BillDetail.postQueuedAnnouncement(announcement)
        }
    }

    private func handleFocusEvent(_ event: VoteFocusPlanner.Event) {
        apply(focusPlanner.handle(event, voiceOverRunning: UIAccessibility.isVoiceOverRunning))
    }

    // MARK: Watch (spec D 2.1.5)

    /// Every guid the bill's watch can sit on: each member of a companion group, and the bill's.
    private var watchGuids: [String] {
        var guids = companionGroup?.memberGuids ?? []
        if let billGuid { guids.append(billGuid) }
        return guids
    }

    /// Watched in the bills store (any member of a group) or in the profile.
    private var storeWatchValue: Bool {
        let isWatchedLocally = companionGroup == nil ? bill.userWatched : billsStore.isWatched(billID: bill.id)
        if isWatchedLocally { return true }
        let watched = Set(userStore.profile.watchedBillGUIDs)
        return watchGuids.contains(where: watched.contains)
    }

    /// Whether the bill (or any member of its group) is watched, as the Watch controls show it. A vote
    /// passes `watch: nil` and never changes it.
    private var currentWatchValue: Bool {
        watchOverride ?? storeWatchValue
    }

    private var canWatch: Bool {
        billGuid != nil
    }

    /// Results unlock after a Yea, Nay or Abstain (spec D 2.1.4, INT-11): the bar's vote, a vote cast on
    /// this screen, or a vote row the stores hold for the bill or its group, Abstain included, also one
    /// from before the bill's update. Never after a Skip, a Clear or a dismissal.
    private var hasVoted: Bool {
        BillVoteBarModel.unlocksResults(
            choice: barChoice,
            didJustVote: didJustVote,
            holdsRow: heldVoteType != nil || currentVoteType != nil
        )
    }

    /// What shows where Results go: Results, or Results and Why people voted drawn sealed, with why they
    /// are locked: no vote held, the vote state not known yet (`isCheckingVote`), or its read failed
    /// (`isVoteCheckFailed`).
    private var resultsAccess: BillResultsAccess {
        BillResultsAccess.make(
            unlocked: hasVoted,
            awaitingSave: resultsAwaitingSave,
            isChecking: isCheckingVote,
            checkFailed: isVoteCheckFailed,
            canRetry: retryChoice != nil
        )
    }

    /// The vote Try again sends again ("Results show once your vote is saved."): the one the bar shows,
    /// else the held row, else the counted vote.
    private var retryChoice: VoteChoice? {
        barChoice ?? heldVoteType.map(VoteChoice.init) ?? currentVoteType.map(VoteChoice.init)
    }

    /// A vote cast on this screen that the server has not answered yet.
    private var isVoteWriteInFlight: Bool {
        pendingVote != nil && voteCasts.latest != nil
    }

    private var billGuid: String? {
        let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (guid?.isEmpty == false) ? guid : nil
    }

    /// A companion group is shared by its primary's guid (APPF-23).
    private var shareURL: URL? {
        guard let guid = companionGroup?.primaryGuid ?? billGuid else { return nil }
        return BillShareURLBuilder.shareURL(forBillGuid: guid)
    }

    private var userStateCode: String {
        userStore.profile.state
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private var userDistrictValue: String {
        userStore.profile.district
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sortedReasons(_ reasons: Set<VoteReason>) -> [VoteReason] {
        reasons.sorted { $0.rawValue < $1.rawValue }
    }

    /// The seed of the person's reason order (`VoteReasonOrder`): their account ID, else this device's.
    private var reasonOrderSeed: String {
        VoteReasonOrder.seed(accountID: userStore.profile.id)
    }

    /// The store's ID for this bill, adding the bill to the store first when the screen
    /// was opened from a copy the store does not hold (otherwise the vote would be dropped).
    private func billIDForVoting() -> UUID {
        if billsStore.bill(for: bill.id) == nil {
            billsStore.upsertProcessedBill(bill)
        }
        return bill.id
    }

    /// Records a vote from the bar. The vote passes `watch: nil`, so voting never watches or
    /// unwatches the bill or any member of its group (for a group, `watch == false` would unwatch the
    /// other members, and `true` would add a Watch row on the vote target). Yea and Nay are saved on
    /// tap, as before (APPF-11); Abstain also takes the bill off the Bills list but keeps the screen
    /// open, showing "You abstained" with Change. An Abstain held from elsewhere on a bill still on
    /// Bills here is recorded again when tapped (`BillVoteBarModel.recordsHeldAbstain`).
    private func castVote(_ choice: VoteChoice, isRetry: Bool = false) {
        let vote = UserVote(choice.voteType)
        let scrollsToYourVote = BillDetail.scrollsToYourVote(afterAVoteHere: didJustVote, isRetry: isRetry)
        let isChange = barChoice != nil
        let opensResults = billStats == nil
        let userID = userStore.profile.id

        reasonSyncTask?.cancel()
        reasonSyncTask = nil
        // The next vote tap ends a refusal's strip (spec 3.10.2).
        refusalText = nil
        withAnimation(reduceMotion ? nil : BallotMoment.ink) {
            pendingVote = vote
            isChangingVote = false
            // Try again on "Results show once your vote is saved." sends the shown vote again from Results:
            // no moment, the page stays where the user is.
            if !isRetry {
                inkedVote = choice
            }
        }
        if !isRetry {
            beginBallotMoment(choice, isChange: isChange, opensResults: opensResults)
        }

        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
            didJustVote = true
        }
        if scrollsToYourVote {
            yourVoteScrollCount += 1
        }

        // Only the reasons this vote offers go with it (N13: Need More Information only with an Abstain, the
        // others only with a Yea or Nay); a change between Yea and Nay keeps the picked ones. Reasons picked
        // afterwards are sent as an update.
        pendingReasons.formIntersection(VoteReason.offered(for: vote.voteType))
        let reasons = sortedReasons(pendingReasons)
        syncedReasons = pendingReasons
        let targetGuid = voteTargetGuid
        let write = billsStore.submitVote(
            billID: billIDForVoting(),
            vote: vote,
            watch: nil,
            reasons: reasons
        )
        var dismissed: [UUID] = []
        if choice == .abstain {
            // Every member of a companion group leaves the Bills list (just this bill otherwise).
            dismissed = billsStore.dismiss(billID: billID, readState: readState)
        }
        let syncTask = write.map { writeTask in
            let castToken = voteCasts.begin(dismissing: dismissed)
            return Task { @MainActor () -> VoteWriteResult in
                let result = await writeTask.value
                voteWriteEnded(castToken, result: result)
                return result
            }
        }

        Task {
            // The stamp and VoiceOver's focus on it say the vote is recorded; nothing is announced on save.
            await handleVoteSync(syncTask, savedMessage: nil, onSaved: {
                voteDidSave(choice, guid: targetGuid, userID: userID)
            })
        }
    }

    /// The one celebrated moment (spec 5.1): one rigid haptic (`voteCommits`), the tapped button inked for
    /// 180 ms, then the stamp in its place (`.smooth`, 0.28 s; with Reduce Motion a 0.2 s cross-fade that
    /// starts at once), and VoiceOver focus on the stamp once it has settled, or "You voted Yea." queued when
    /// VoiceOver is not running (`VoteFocusPlanner`).
    private func beginBallotMoment(_ choice: VoteChoice, isChange: Bool, opensResults: Bool) {
        voteCommits += 1
        let commit = voteCommits
        let reduceMotion = reduceMotion
        handleFocusEvent(.committed(
            BallotStampCopy(choice: choice, votedAt: Date()),
            isChange: isChange,
            opensResults: opensResults
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + BallotMoment.inkHold(reduceMotion: reduceMotion)) {
            guard voteCommits == commit, inkedVote != nil else { return }
            withAnimation(BallotMoment.morph(reduceMotion: reduceMotion)) {
                inkedVote = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + BallotMoment.settled(reduceMotion: reduceMotion)) {
            guard voteCommits == commit else { return }
            handleFocusEvent(.settled)
        }
    }

    /// A vote cast here ended. When the server refused it and the stores rolled it back (APPF-27), the
    /// screen drops its own choice too: the panel cross-fades back (0.2 s) to what it showed before (the
    /// three buttons for a first vote, the previous stamp for a change), Your vote and Results follow the
    /// restored vote (Results seal again), and a refused Abstain puts the bill back on the Bills list. The
    /// refusal's text (the daily limit's, from the vote store) shows in the panel, or first in Your vote
    /// from xxxLarge up, not in the top banner, with the error haptic and VoiceOver focus on it (spec 3.10.2).
    private func voteWriteEnded(_ castToken: UUID, result: VoteWriteResult) {
        guard case .rollBack(let undismiss) = voteCasts.finish(castToken, result: result) else { return }
        readState.undismissBills(undismiss)
        reasonSyncTask?.cancel()
        reasonSyncTask = nil
        syncedReasons = []
        let refusal = voteStore.lastError?.trimmedNonEmpty ?? BillVoteBarModel.refusalFallbackText
        voteStore.lastError = nil
        withAnimation(BallotMoment.rollback) {
            pendingVote = nil
            inkedVote = nil
            isChangingVote = false
            didJustVote = false
            refusalText = refusal
        }
        refusals += 1
        if sizeClass != .regular {
            refusalScrollCount += 1
        }
        // Once the strip is on screen (after the cross-fade), so VoiceOver can land on it.
        let plan = focusPlanner.handle(.refused, voiceOverRunning: UIAccessibility.isVoiceOverRunning)
        DispatchQueue.main.asyncAfter(deadline: .now() + BillDetail.refusalFocusDelay) {
            apply(plan)
        }
        // A vote that was not known before this one is checked again, so the bar does not stay on
        // "Checking your vote…"; a read that fails says so (`voteCheckFailed`). Errors stay out of the
        // banner, which keeps the refusal's text.
        if case .rolledBack(.unknown) = result {
            let guids = voteRowGuids
            voteCheckFailed = false
            Task {
                var failed = false
                for guid in Set(guids) {
                    if await voteStore.fetchVoteIfNeeded(for: guid, reportError: false) != nil {
                        failed = true
                    }
                }
                voteCheckFailed = failed
            }
        }
    }

    /// After a vote is stored: tells the app, ends the first-vote coach mark, and arms the first-vote topic
    /// prompt, which asks once Done is tapped or the page is left (spec 4.39). Nothing more is offered: the
    /// one-time "Watch for changes" nudge is gone (project decision 9), since the Watch row sits in Your vote.
    /// It also runs when the write ends after the page was left.
    private func voteDidSave(_ choice: VoteChoice, guid: String?, userID: String) {
        if let guid {
            NotificationCenter.default.post(
                name: .billboardVoteSaved,
                object: nil,
                userInfo: BillVoteBarModel.voteSavedUserInfo(guid: guid, vote: choice)
            )
        }
        FirstRunStorage.setVoteCoachMarkPending(false)
        topicPrompt.post(topicPrompt.trigger.voteSaved(FirstVoteTopicPromptTrigger.Request(userID: userID, votedGUID: guid)))
    }

    /// Done was tapped or the page was left: the first-vote topic prompt may ask now (spec 4.39).
    private func pageEnded(_ ending: FirstVoteTopicPromptTrigger.Ending) {
        topicPrompt.post(topicPrompt.trigger.pageEnded(ending))
    }

    /// The Watch toolbar button and toggle (the only controls that change watch).
    private func setWatch(_ watch: Bool) {
        guard watch != currentWatchValue else { return }
        let plan = BillWatchPlan.make(watch: watch, targetGuid: voteTargetGuid, memberGuids: watchGuids)
        if plan.addGuid != nil {
            // The store marks its bill watched when the profile changes; make sure it holds it.
            _ = billIDForVoting()
        }
        watchOverride = watch
        plan.apply(billID: billID, billsStore: billsStore, userStore: userStore)
        if storeWatchValue == watch {
            watchOverride = nil
        }
        HapticFeedback.selection()
        AccessibilityNotification.Announcement(BillWatchCopy.announcement(isWatching: watch)).post()
    }

    private func toggleReason(_ reason: VoteReason) {
        if pendingReasons.contains(reason) {
            pendingReasons.remove(reason)
        } else {
            guard pendingReasons.count < VoteReason.maxSelections else { return }
            pendingReasons.insert(reason)
        }
        scheduleReasonSync()
    }

    /// Debounces reason taps so picking several reasons sends one update.
    private func scheduleReasonSync() {
        reasonSyncTask?.cancel()
        reasonSyncTask = Task {
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            sendReasonUpdateIfNeeded()
        }
    }

    /// Sends any reasons that have not been saved yet (used when leaving the screen).
    private func flushReasonUpdate() {
        reasonSyncTask?.cancel()
        reasonSyncTask = nil
        sendReasonUpdateIfNeeded()
    }

    private func sendReasonUpdateIfNeeded() {
        guard let pendingVote, let reasonsGuid = voteTargetGuid else { return }
        let reasons = pendingReasons
        let previouslySynced = syncedReasons
        guard reasons != previouslySynced else { return }
        syncedReasons = reasons

        let store = voteStore
        let vote = pendingVote.voteType
        let orderedReasons = sortedReasons(reasons)
        let syncTask = Task { () -> VoteWriteResult in
            await store.updateReasons(billId: reasonsGuid, vote: vote, reasons: orderedReasons) ? .stored : .notSaved
        }
        Task {
            await handleVoteSync(syncTask, savedMessage: "Reasons saved", onFailure: {
                // Let the next change (or leaving the screen) try again.
                if syncedReasons == reasons {
                    syncedReasons = previouslySynced
                }
            })
        }
    }

    /// Waits for a vote or reasons write, then confirms it and refreshes the results.
    /// Failures are reported by `BillVoteStore.lastError` (shown in the error banner).
    /// `onSaved` runs once the write is stored, also after the screen was left.
    @MainActor
    private func handleVoteSync(
        _ syncTask: Task<VoteWriteResult, Never>?,
        savedMessage: String?,
        onSaved: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) async {
        guard let syncTask else { return }
        let result = await syncTask.value
        let saved = result == .stored
        if saved {
            onSaved?()
        }
        // The write finishes even after leaving the screen; only the UI follow-up is skipped.
        // If another screen was pushed on top, refresh the results when this one returns.
        guard isOnScreen else {
            if saved { hasPendingStatsRefresh = true }
            return
        }
        if saved {
            if let savedMessage {
                announceSaved(savedMessage)
            }
            refreshStatsAfterVoteSaved()
            return
        }
        onFailure?()
        // A vote kept after a failure may have been stored: ask (the server answers RESULTS_LOCKED until it
        // holds it). Never after a refusal that rolled the vote back, or once Results are locked again.
        if billStats == nil,
           BillVoteBarModel.fetchesStatsAfterWrite(result: result, stillUnlocked: hasVoted),
           let statsBillGuid {
            await loadBillStats(billGuid: statsBillGuid)
        }
    }

    /// "Reasons saved" for VoiceOver. A vote announces nothing on save: the ballot stamp, VoiceOver's focus on
    /// it and "Results are open." (under the floor, the floor line's words) say it (spec 3.10.3).
    @MainActor
    private func announceSaved(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    /// Reloads Results after a saved vote. Community totals are aggregated on the
    /// server shortly after the write, so check once more after a short delay.
    @MainActor
    private func refreshStatsAfterVoteSaved() {
        guard let statsBillGuid else { return }
        statsRefreshTask?.cancel()
        hasPendingStatsRefresh = true
        statsRefreshTask = Task {
            await loadBillStats(billGuid: statsBillGuid, forceRefresh: true)
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            await loadBillStats(billGuid: statsBillGuid, forceRefresh: true)
            guard !Task.isCancelled else { return }
            hasPendingStatsRefresh = false
        }
    }

    /// Loads Results, only while they are unlocked (INT-11), and keeps them only if they still are when
    /// the answer arrives. `RESULTS_LOCKED` (the server holds no vote from this user yet) drops any held
    /// stats, shows "Results show once your vote is saved." and reads the vote rows again.
    @MainActor
    private func loadBillStats(billGuid: String, forceRefresh: Bool = false) async {
        guard hasVoted else {
            clearBillStats()
            return
        }
        let cleanedGuid = billGuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedGuid.isEmpty else {
            clearBillStats()
            return
        }

        billStatsError = nil
        isLoadingBillStats = true
        defer { isLoadingBillStats = false }

        do {
            let stats = try await BillStatsService.fetchBillStats(
                billId: cleanedGuid,
                forceRefresh: forceRefresh,
                scope: statsScope
            )
            // Results may have locked again while the request was out (a refused vote rolled back).
            guard hasVoted else {
                clearBillStats()
                return
            }
            billStats = stats
            billStatsError = nil
            resultsAwaitingSave = false
            // The stats for a vote made here: "Results are open.", queued (spec 3.10.3); under the floor the
            // floor line's words (UX-34).
            handleFocusEvent(.statsArrived(belowFloor: VoteResultsFormatting.floorLine(for: stats)))
        } catch BillStatsService.FetchError.resultsLocked {
            billStats = nil
            billStatsError = nil
            resultsAwaitingSave = true
            // The screen then follows the rows the server holds (a vote still being sent is kept).
            await voteStore.refreshVotes(for: voteRowGuids)
        } catch {
            // A refresh replaced by a newer one, or a screen left mid-load, is not a failure (APPF-22).
            if APIErrorResponse.isCancellation(error) { return }
            #if DEBUG
            print("[BillDetail] Failed to load bill stats for \(cleanedGuid): \(APIErrorDebug.debugString(for: error))")
            #endif
            billStatsError = VoteResultsFormatting.unavailableText
        }
    }

    /// Try again on "Results show once your vote is saved.": sends the vote the screen shows again, and
    /// leaves the page where it is (the answer shows where Try again was tapped).
    private func retryUnsavedVote() {
        guard let retryChoice else { return }
        castVote(retryChoice, isRetry: true)
    }

    /// Try again under "Results aren't available right now.": asks for the stats again.
    private func retryStats() {
        guard let statsBillGuid else { return }
        Task { await loadBillStats(billGuid: statsBillGuid, forceRefresh: true) }
    }

    /// Try again on the sealed Results: reads the vote again after a failed read, else sends the
    /// unsaved vote again.
    private func resultsTryAgain() {
        if resultsAccess == .locked(.checkFailed) {
            Task { await loadVoteAndStats() }
        } else {
            retryUnsavedVote()
        }
    }

    /// Reads the user's vote row, then Results once they are unlocked. A cached "not voted" is read again
    /// (INT-11), so a vote made on another device or before a reinstall unlocks Results on open. Until the
    /// row is known, Results stay locked; a read that fails ends "Checking your vote…" (`voteCheckFailed`).
    @MainActor
    private func loadVoteAndStats() async {
        guard let statsBillGuid else {
            clearBillStats()
            return
        }
        voteCheckFailed = false
        let failure: String?
        if companionGroup != nil {
            // Every member's vote in one request: the group's vote may sit on either bill.
            failure = await voteStore.fetchVotes(for: voteRowGuids, revalidateNotVoted: true)
        } else {
            failure = await voteStore.fetchVoteIfNeeded(for: statsBillGuid, reportError: false, revalidateNotVoted: true)
        }
        voteCheckFailed = failure != nil
        // A vote cast here meanwhile asks once the server has stored it (`refreshStatsAfterVoteSaved`).
        guard BillVoteBarModel.shouldFetchStats(unlocked: hasVoted, writeInFlight: isVoteWriteInFlight) else {
            if !hasVoted { clearBillStats() }
            return
        }
        await loadBillStats(billGuid: statsBillGuid)
    }

    @MainActor
    private func clearBillStats() {
        billStats = nil
        billStatsError = nil
        isLoadingBillStats = false
    }

    /// Which section comes first under the front matter's double rule, and so draws no hairline of its
    /// own (spec 3.5): the first of Sponsor, Why it matters, the Breakdown (or Summary) and In Congress the
    /// bill has, else Your vote.
    private enum LeadSection {
        case sponsor, whyItMatters, breakdown, inCongress, yourVote
    }

    private var hasBreakdown: Bool {
        bill.billBreakdown?.hasContent == true
    }

    private var leadSection: LeadSection {
        if BillSponsorSection.isShown(for: bill) { return .sponsor }
        if BillSoWhatSection.isShown(for: bill) { return .whyItMatters }
        if hasBreakdown || !bill.summary.isEmpty { return .breakdown }
        if companionGroup != nil { return .inCongress }
        return .yourVote
    }

    var body: some View {
        let lead = leadSection
        ScrollViewReader { scrollProxy in
        ScrollView {
            // The document (spec 4.28): front matter, then ruled sections in this order. Results, Why
            // people voted, Compare with Congress and Done form the post-vote block, so Done never sits
            // between a vote and the Results it opened.
            VStack(alignment: .leading, spacing: 0) {
                BillFrontMatter(bill: bill, companion: companionDisplay) { bottom in
                    titleBottom = bottom
                }

                BillSponsorSection(bill: bill, showsRule: lead != .sponsor)

                BillSoWhatSection(bill: bill, showsRule: lead != .whyItMatters)

                // Bill Breakdown (or legacy summary fallback)
                // Each AI-written section ends with the AI note and Report a problem (UX-37).
                if let breakdown = bill.billBreakdown, breakdown.hasContent {
                    BillBreakdownSection(breakdown: breakdown, showsRule: lead != .breakdown, aiNote: ReportProblem.BillReference(bill: bill))
                } else if !bill.summary.isEmpty {
                    BillSummarySection(summary: bill.summary, showsRule: lead != .breakdown, aiNote: ReportProblem.BillReference(bill: bill))
                }

                // Each member of a companion group (APPF-23)
                if let companionGroup {
                    BillCompanionMembersSection(group: companionGroup, showsRule: lead != .inCongress)
                }

                // Your vote (the buttons are in the vote panel; from xxxLarge up its strips are rows here, and
                // at the accessibility sizes the stamp too)
                BillYourVoteSection(
                    standing: yourVoteStanding,
                    isWatching: currentWatchValue,
                    canWatch: canWatch,
                    showsReasonPicker: pendingVote != nil,
                    selectedReasons: pendingReasons,
                    reasonVoteType: pendingVote?.voteType,
                    reasonOrder: pendingVote.map { VoteReasonOrder.order(for: $0.voteType, seed: reasonOrderSeed) } ?? [],
                    onToggleReason: toggleReason,
                    onSetWatch: setWatch,
                    companionCaption: companionVoteCaption,
                    companionConflictNote: companionConflictNote,
                    showsRule: lead != .yourVote,
                    movedRows: movedVoteRows,
                    votedAt: shownVoteDate,
                    stampFocusLabel: focusPlanner.oneTimeStampLabel,
                    focus: $voteFocus,
                    onDismissCoachMark: dismissCoachMark,
                    onGoToResults: { handleFocusEvent(.goToResults) }
                )
                .id(BillYourVoteSection.anchorID)

                // Results (everyone beside verified voters) and Why people voted, drawn sealed until the
                // user votes or abstains (INT-11), then opening on the stats for the stored vote.
                BillResultsArea(
                    access: resultsAccess,
                    billStats: billStats,
                    isLoadingBillStats: isLoadingBillStats,
                    billStatsError: billStatsError,
                    userStateCode: userStateCode,
                    userDistrictValue: userDistrictValue,
                    didVoteHere: didJustVote,
                    yourVote: retryChoice,
                    onTryAgain: resultsTryAgain,
                    onRetryStats: retryStats,
                    onGoToVoteButtons: { handleFocusEvent(.goToVoteButtons) },
                    titleFocus: $voteFocus
                )

                // Post-vote: how Congress voted beside the user's vote, then Done.
                if didJustVote {
                    BillCongressVotedSection(bill: bill)
                    doneButton
                }

                // The official roll calls: never sealed (INT-11 seals only other users' votes).
                BillOfficialVotesSection(
                    bill: bill,
                    userStateCode: userStateCode,
                    userDistrictValue: userDistrictValue
                )

                // Committees (summary + activities)
                BillCommitteesSection(bill: bill)

                // Actions (deduped timeline)
                BillActionsSection(bill: bill)

                // Source: the bill on GovInfo
                BillLinkSection(bill: bill)
            }
            .padding(.bottom, BillboardStyle.Space.s)
            .coordinateSpace(.named(BillFrontMatter.pageSpace))
        }
        // Page text fades and blurs under the vote panel instead of being cut mid-line (spec 3.10).
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // The screen's title is always "Bill" (the back button and its menu on a page pushed from here, and
        // VoiceOver), but the bar shows it only once the bill's own title has scrolled under the bar (spec
        // 4.28, frames 4 to 8), as on every document page.
        .modifier(DocumentInlineTitle(title: BillDetail.inlineTitle, titleBottom: titleBottom))
        .onChange(of: yourVoteScrollCount) { _, count in
            guard count > 0 else { return }
            // Spec 3.13, 5.1: 0.4 s after the first vote made here, Your vote goes to the top of the visible
            // area. With Reduce Motion it jumps. Results' first row then shows above the vote panel after an
            // Abstain, whose reasons picker offers one reason, and after a Yea or Nay, whose picker shows three
            // reasons before More reasons (project decisions of 2026-10-21), on an iPhone SE's screen and on
            // 402 x 874 (tested).
            DispatchQueue.main.asyncAfter(deadline: .now() + BillDetail.yourVoteScrollDelay) {
                if reduceMotion {
                    scrollProxy.scrollTo(BillYourVoteSection.anchorID, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: 0.4)) {
                        scrollProxy.scrollTo(BillYourVoteSection.anchorID, anchor: .top)
                    }
                }
            }
        }
        .onChange(of: refusalScrollCount) { _, count in
            guard count > 0 else { return }
            // From xxxLarge up the refusal is the first row of Your vote: bring it into view (spec 3.10.2).
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                scrollProxy.scrollTo(BillYourVoteSection.refusalAnchorID, anchor: .top)
            }
        }
        } // ScrollViewReader
        .navigationBarTitleDisplayMode(.inline)
        // The vote panel on every bill, a decided one's too (Civic Record project decision 1), where the tab
        // capsule would be (the page hides it): the only bar at the page's bottom (spec 3.10, 4.9).
        .safeAreaBar(edge: .bottom, spacing: 0) {
            BillVoteBar(
                model: voteBarModel,
                showsCoachMark: showsVoteCoachMark,
                refusal: refusalText,
                votedAt: shownVoteDate,
                inked: inkedVote,
                animatesInk: true,
                stampFocusLabel: focusPlanner.oneTimeStampLabel,
                focus: $voteFocus,
                onVote: { castVote($0) },
                onChange: {
                    // Change starts the next vote: a refusal's strip goes (spec 3.10.2).
                    withAnimation(reduceMotion ? nil : BallotMoment.rollback) {
                        refusalText = nil
                        isChangingVote = true
                    }
                },
                onCollapse: {
                    withAnimation(reduceMotion ? nil : BallotMoment.rollback) { isChangingVote = false }
                },
                onDismissCoachMark: dismissCoachMark,
                onGoToResults: { handleFocusEvent(.goToResults) }
            )
            .padding(.horizontal, BillVoteBar.sideMargin)
            .padding(.bottom, BillDetail.panelBottomPadding(safeAreaBottom: safeAreaBottom))
        }
        .overlay(alignment: .bottom) {
            PanelRimTapGuard(safeAreaBottom: safeAreaBottom)
        }
        // One rigid haptic when a vote is committed (not on press-down), the error haptic on a refusal (spec 5.1).
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: voteCommits)
        .sensoryFeedback(.error, trigger: refusals)
        .onChange(of: voteFocus) { old, new in
            if old == .stamp, new != .stamp {
                handleFocusEvent(.stampFocusLeft)
            }
        }
        .task(id: statsBillGuid) {
            await loadVoteAndStats()
        }
        .onChange(of: hasVoted) { _, unlocked in
            guard !unlocked else { return }
            // Locked again (a refused vote rolled back): drop every result held and stop asking (INT-11).
            statsRefreshTask?.cancel()
            statsRefreshTask = nil
            hasPendingStatsRefresh = false
            clearBillStats()
            resultsAwaitingSave = false
        }
        .onChange(of: scenePhase) { _, phase in
            // The vote itself is saved on tap; only unsaved reason changes can be pending.
            if phase == .background {
                flushReasonUpdate()
            }
        }
        .onChange(of: storeWatchValue) { _, watched in
            // The stores caught up with the toggle.
            if watchOverride == watched {
                watchOverride = nil
            }
        }
        .onAppear {
            isOnScreen = true
            // Finish a post-vote results refresh that was cut short by a pushed screen.
            if hasPendingStatsRefresh {
                refreshStatsAfterVoteSaved()
            }
        }
        .onDisappear {
            // Also runs when a screen is pushed on top, not only when this one is dismissed.
            isOnScreen = false
            flushReasonUpdate()
            statsRefreshTask?.cancel()
            statsRefreshTask = nil
        }
        .overlay(alignment: .top) {
            // Errors not tied to the vote. While a vote is being sent its outcome is not known yet: a refusal's
            // text goes to the vote panel instead (spec 3.10.2, 3.19).
            BBErrorBanner(message: Binding(
                get: { voteCasts.latest == nil ? voteStore.lastError : nil },
                set: { voteStore.lastError = $0 }
            ))
            BBErrorBanner(message: Binding(
                get: { billsStore.errorMessage },
                set: { billsStore.errorMessage = $0 }
            ))
        }
        .toolbar {
            // Watch and Share in one glass group (spec 3.12, frames 4 to 8).
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canWatch {
                    watchButton
                }
                if let shareURL {
                    shareButton(shareURL)
                }
            }
        }
        .background {
            // The bottom safe area outside the vote panel's bar (34 pt with a home indicator, 0 with a Home
            // button), for the panel's margin; and when the page is taken off its stack, for the topic prompt.
            ZStack {
                Color.clear
                    .ignoresSafeArea(.keyboard)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.safeAreaInsets.bottom
                    } action: { bottom in
                        safeAreaBottom = bottom
                    }
                PageLeaveProbe { pageEnded(.left) }
                    .frame(width: 0, height: 0)
            }
            .accessibilityHidden(true)
        }
        // The document ground, full bleed (spec 4.28): no tint by status.
        .background(BillboardColors.document.ignoresSafeArea())
    }

    private func dismissCoachMark() {
        FirstRunStorage.setVoteCoachMarkPending(false)
    }

    /// Done, after the post-vote block (spec 3.13): a primary capsule, only after a vote made here. On a
    /// first vote ever, tapping it opens the topics sheet (spec 4.39).
    private var doneButton: some View {
        Button(BillDetail.doneTitle) {
            flushReasonUpdate()
            pageEnded(.done)
            dismiss()
        }
        .buttonStyle(BillboardButtonStyle(kind: .primary))
        .accessibilityIdentifier(BillDetail.doneIdentifier)
        .padding(.horizontal, BillboardStyle.Space.xl)
        .padding(.top, BillboardStyle.Space.s)
        .padding(.bottom, 24)
        .transition(reduceMotion ? .identity : .opacity)
    }

    /// Watch in the bar: binoculars and "Watch", or the filled binoculars and "Watching" (the glyph and the
    /// word carry the state, not a colour). A navigation-bar control: a fixed size, with the Large Content
    /// Viewer at accessibility text sizes.
    private var watchButton: some View {
        let isWatching = currentWatchValue
        let label = BillWatchCopy.toolbarLabel(isWatching: isWatching)
        let symbol = BillWatchCopy.symbolName(isWatching: isWatching)
        return Button {
            setWatch(!isWatching)
        } label: {
            DocumentToolbarLabel(title: label, systemImage: symbol, glyphColor: toolbarGlyphColor)
        }
        .accessibilityLabel(label)
        .accessibilityInputLabels([BillWatchCopy.toolbarLabel(isWatching: false), BillWatchCopy.toolbarLabel(isWatching: true)])
        .accessibilityAddTraits(isWatching ? .isSelected : [])
        .accessibilityIdentifier(BillWatchCopy.toolbarIdentifier)
        .documentToolbarLargeContent(label, systemImage: symbol)
    }

    private func shareButton(_ url: URL) -> some View {
        ShareLink(
            item: url,
            subject: Text(bill.title),
            message: Text("Take a look at this bill on Billboard.")
        ) {
            // Like system bar buttons it keeps a fixed size and offers the Large Content Viewer at
            // accessibility text sizes instead of growing.
            Image(systemName: "square.and.arrow.up")
                .foregroundStyleIfSet(toolbarGlyphColor)
        }
        .accessibilityLabel("Share bill")
        .documentToolbarLargeContent("Share bill", systemImage: "square.and.arrow.up")
    }
}

// MARK: - Companion group (APPF-23)

extension BillDetailContent {
    /// The group's vote under the vote matrix: the counted row, where a vote goes and any conflict.
    fileprivate var companionVote: CompanionVoteResolution? {
        companionGroup.map { billsStore.companionVote(for: $0) }
    }

    /// Where a vote's reasons go: a group's vote target (the member holding the vote, else the
    /// primary), else this bill's guid.
    fileprivate var voteTargetGuid: String? {
        companionVote?.targetGuid ?? billGuid
    }

    /// Every guid the user's vote row can sit on: each member of a companion group, and the bill's.
    fileprivate var voteRowGuids: [String] {
        (companionGroup?.memberGuids ?? []) + [billGuid].compactMap { $0 }
    }

    /// The guid the stats are fetched for: a group's primary (the server combines its members), else
    /// this bill's.
    fileprivate var statsBillGuid: String? {
        companionGroup?.primaryGuid ?? billGuid
    }

    fileprivate var statsScope: BillStatsService.Scope {
        companionGroup == nil ? .bill : .companions
    }

    /// The header's "H.R. 900 · S. 456" and status lead.
    fileprivate var companionDisplay: BillCompanionDisplay? {
        companionGroup.map { BillCompanionDisplay.make(for: $0, in: billsStore) }
    }

    /// "These bills have identical text. Your vote counts once for both."
    fileprivate var companionVoteCaption: String? {
        companionGroup.map {
            BillDisplayFormatting.companionVoteCaption(memberCount: $0.memberGuids.count, isIdentical: $0.isIdentical)
        }
    }

    /// Set when the user holds different votes on two members; names the one that counts.
    fileprivate var companionConflictNote: String? {
        guard let conflict = companionVote?.conflict else { return nil }
        return BillDisplayFormatting.companionConflictNote(
            countedGuid: conflict.counted.memberGuid,
            countedVote: conflict.counted.vote,
            otherGuid: conflict.other.memberGuid,
            otherVote: conflict.other.vote
        )
    }

    /// A group with no counted vote: unknown until any member's vote state is known.
    fileprivate func companionVoteState(for group: BillCompanionGroup) -> VoteState {
        let resolution = companionVote
        let isUnknown = group.memberGuids.allSatisfy { voteStore.vote(for: $0) == .unknown }
        if isUnknown, resolution?.countedRow == nil, resolution?.isVoted != true {
            return .unknown
        }
        return .notVoted
    }
}

// MARK: - The panel's rim

/// Takes taps on the part of the vote panel that reaches into the home-indicator area, so they do not reach the
/// page under the glass. A `safeAreaBar` takes touches only above the bottom safe area, and the panel sits 24 pt
/// above the screen's edge, 10 pt into the 34 pt area (`BillDetail.panelBottomPadding`): measured on the iOS 27
/// simulator, a tap on the panel's bottom 10 pt went to the scroll view. Only the panel's glass rim is there (its
/// buttons end 10 pt above its edge), so a tap there does nothing, as on the rest of the rim. Nothing is drawn.
private struct PanelRimTapGuard: View {
    let safeAreaBottom: CGFloat

    var body: some View {
        let reach = -BillDetail.panelBottomPadding(safeAreaBottom: safeAreaBottom)
        if reach > 0 {
            Color.clear
                .frame(height: reach)
                .contentShape(Rectangle())
                .onTapGesture {}
                .padding(.horizontal, BillVoteBar.sideMargin)
                .padding(.bottom, TabCapsuleLayout.bottomMargin(safeAreaBottom: safeAreaBottom))
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - First-vote topic prompt (spec 4.39)

/// Holds the page's `FirstVoteTopicPromptTrigger` in a reference, so a vote whose write ends after the page was
/// left still reaches it, and posts what it fires.
private final class TopicPromptTriggerBox {
    var trigger = FirstVoteTopicPromptTrigger()

    func post(_ request: FirstVoteTopicPromptTrigger.Request?) {
        guard let request else { return }
        NotificationCenter.default.post(
            name: .billboardFirstVoteTopicPromptTrigger,
            object: nil,
            userInfo: request.userInfo
        )
    }
}

/// Calls `onLeft` when the page it is on is taken off its navigation stack (Back, a swipe back that
/// completes, Done, a path reset); not when a page is pushed over it, a swipe back is cancelled or the tab
/// changes. A view controller in the page, so UIKit forwards the page's appearance to it.
///
/// UIKit sets `isMovingFromParent` only during the page controller's own callbacks, not the ones it forwards
/// to its children, so the probe remembers the page (its ancestor directly in a navigation controller) and,
/// when it disappears, asks whether the page is still in one. A cancelled swipe back never disappears.
struct PageLeaveProbe: UIViewControllerRepresentable {
    let onLeft: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onLeft = onLeft
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onLeft = onLeft
    }

    final class Controller: UIViewController {
        var onLeft: () -> Void = {}
        private weak var page: UIViewController?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            page = PageLeaveProbe.page(of: self)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if PageLeaveProbe.hasLeftItsStack(page) {
                onLeft()
            }
        }
    }

    /// The controller's ancestor directly in a navigation controller (the page), or nil.
    static func page(of controller: UIViewController) -> UIViewController? {
        var current: UIViewController? = controller
        while let candidate = current {
            if candidate.parent is UINavigationController { return candidate }
            current = candidate.parent
        }
        return nil
    }

    /// The page is no longer in a navigation controller: it was popped.
    static func hasLeftItsStack(_ page: UIViewController?) -> Bool {
        guard let page else { return false }
        return !(page.parent is UINavigationController)
    }
}
