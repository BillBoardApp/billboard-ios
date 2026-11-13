import Foundation
import SwiftUI
import UIKit

/// What the vote panel on bill detail shows (spec D 2.1.4; Civic Record spec 3.10), from the screen's
/// mode and the user's vote. Pure: `BillVoteBar` draws it and `BillDetail` acts on its tap results.
///
/// - `.full`, not voted: Yea, Nay and Abstain, equal size and weight, none selected.
/// - `.full`, voted: the ballot stamp ("YOU VOTED YEA", or "YOU ABSTAINED") with Change; Change shows
///   the three buttons again with the current choice ringed and marked "Your vote".
/// - `.updatedOnly` (an updated bill; an "updated" push may have cleared the vote): the caption "This
///   bill's summary changed. Vote again:" over the three buttons, until a vote made since the update
///   is known. Watch is left alone.
///
/// Every bill page shows the bar, decided bills (Passed, Failed, Became law) included: voting stays
/// open after Congress decides (Civic Record project decision 1).
struct BillVoteBarModel: Equatable {
    enum Layout: Equatable {
        /// The three buttons, with an optional caption above them and the current choice ringed
        /// while changing.
        case choose(caption: String?, selected: VoteChoice?)
        /// The ballot stamp ("You voted Yea" / "You voted Nay" / "You abstained") and Change.
        case collapsed(VoteChoice)
    }

    /// What tapping a vote button does.
    enum TapResult: Equatable {
        /// Record this vote.
        case vote(VoteChoice)
        /// The choice is already the vote: close the buttons without writing anything.
        case collapse
    }

    let mode: BillDetail.Mode
    /// The user's vote on this bill as the screen knows it (`shownChoice`): a choice made on this
    /// screen, a counted Yea or Nay from the stores, or an Abstain row the vote store holds.
    let choice: VoteChoice?
    /// The vote state is not known yet (not fetched).
    var isChecking: Bool = false
    /// Change was tapped: the buttons are open over a vote.
    var isChanging: Bool = false
    /// The shown Abstain was not chosen on this screen (the vote store held it: another device, a
    /// reinstall, an R1 swipe) and the bill is still on Bills on this device (`recordsHeldAbstain`).
    /// A tap on Abstain then records it again, which also takes the bill off Bills, instead of only
    /// closing the buttons.
    var recordsHeldAbstain: Bool = false

    // MARK: Copy and identifiers

    static let accessibilityLabel = "Vote"
    static let updatedCaption = "This bill's summary changed. Vote again:"
    static let checkingCaption = "Checking your vote…"
    static let changeTitle = "Change"
    static let compactTitle = "Vote"
    static let dialogTitle = "Your vote"
    static let coachMarkText = "Choose Yea, Nay or Abstain. You can change it later."
    static let coachMarkDismissTitle = "Not now"

    static let changeIdentifier = "bill.vote.change"
    static let compactIdentifier = "bill.vote.open"
    static let barIdentifier = "bill.vote.bar"
    static let coachMarkIdentifier = "bill.vote.coachMark"

    /// `bill.vote.yea`, `bill.vote.nay`, `bill.vote.abstain`.
    static func identifier(for choice: VoteChoice) -> String {
        "bill.vote.\(choice.rawValue)"
    }

    // MARK: Layout

    var layout: Layout {
        if let choice {
            return isChanging ? .choose(caption: nil, selected: choice) : .collapsed(choice)
        }
        if mode == .updatedOnly { return .choose(caption: Self.updatedCaption, selected: nil) }
        return .choose(caption: isChecking ? Self.checkingCaption : nil, selected: nil)
    }

    /// The three buttons are showing.
    var showsButtons: Bool {
        if case .choose = layout { return true }
        return false
    }

    /// The current vote while changing (drawn with a heavier ring and "Your vote"), else none.
    var selectedChoice: VoteChoice? {
        if case .choose(_, let selected) = layout { return selected }
        return nil
    }

    /// "You voted Yea", "You voted Nay" or "You abstained" when collapsed.
    var collapsedTitle: String? {
        if case .collapsed(let choice) = layout { return choice.confirmationMessage }
        return nil
    }

    func result(ofTapping tapped: VoteChoice) -> TapResult {
        if isChanging, tapped == choice, !(tapped == .abstain && recordsHeldAbstain) { return .collapse }
        return .vote(tapped)
    }

    /// A choice in the "Your vote" dialog (the one Vote button at the accessibility sizes): the current vote,
    /// "Yea (your vote)", writes nothing, as tapping it while changing; any other choice is recorded.
    func dialogResult(ofTapping tapped: VoteChoice) -> TapResult {
        if tapped == choice, !(tapped == .abstain && recordsHeldAbstain) { return .collapse }
        return .vote(tapped)
    }

    /// The vote the bar and Your vote show: the choice made on this screen, else the counted Yea or
    /// Nay from the stores, else an Abstain the vote store holds (`BillVoteStore.heldVote(for:)`; its
    /// published state reports an Abstain as not voted). So a bill the user abstained on earlier, on
    /// this screen or another device, reopens as "You abstained · Change", not as a new vote.
    ///
    /// `.updatedOnly` (an updated bill, opened from Bills, Skipped or the weekly digest) asks for a new
    /// vote, so a held Abstain from before the update does not answer it: an "updated" push clears only
    /// the local row, and opening the bill fetches the server's row from before the update again. The
    /// bar keeps "This bill's summary changed. Vote again:" over the three buttons. An Abstain cast at
    /// or after the update (`heldVotedAt >= billUpdatedAt`, such as one made on the updated screen
    /// itself) does answer it and shows as "You abstained". When either time is unknown the Abstain
    /// is taken as older than the update.
    static func shownChoice(
        pending: VoteChoice?,
        counted: VoteChoice?,
        held: VoteType?,
        mode: BillDetail.Mode = .full,
        heldVotedAt: Date? = nil,
        billUpdatedAt: Date? = nil
    ) -> VoteChoice? {
        if let pending { return pending }
        if let counted { return counted }
        guard held == .abstain else { return nil }
        guard mode == .updatedOnly else { return .abstain }
        guard let heldVotedAt, let billUpdatedAt, heldVotedAt >= billUpdatedAt else { return nil }
        return .abstain
    }

    /// The counted vote (Yea or Nay) the stores hold for a bill in no companion group: the vote store's
    /// row (`BillVoteStore.vote(for:)`), else the bills store's copy of the bill (`Bill.userVote`). Both
    /// roll back a refused vote (APPF-27), so the bar never falls back to it.
    static func storedCountedVote(voteStoreState: VoteState, billVote: UserVote?) -> UserVote? {
        if case .voted(let voteType) = voteStoreState {
            return voteType.countsAsVote ? UserVote(voteType) : nil
        }
        guard let billVote, billVote.countsAsVote else { return nil }
        return billVote
    }

    /// `recordsHeldAbstain`: the bar shows an Abstain not chosen on this screen (no `pending`
    /// choice), on a bill still listed on Bills here (`isListedHere`: some bill of its card, every
    /// member of a companion group, is not dismissed on this device). Skips and dismissals stay on
    /// the device (spec D 2.1.1), so a bill abstained on elsewhere is listed here.
    static func recordsHeldAbstain(pending: VoteChoice?, shown: VoteChoice?, isListedHere: @autoclosure () -> Bool) -> Bool {
        pending == nil && shown == .abstain && isListedHere()
    }

    // MARK: Results gate (INT-11)

    /// Whether Results (every count of other users' votes on the bill) may show: after a Yea, Nay or
    /// Abstain, never after a Skip, a Clear or a dismissal, which write no row. `choice` is the bar's
    /// vote (`shownChoice`), `didJustVote` a vote cast on this screen, and `holdsRow` a vote row the stores
    /// hold for the bill or its companion group, Abstain included. A held row unlocks even where the
    /// `.updatedOnly` bar asks for a vote again: the server keeps a vote made before the bill's update,
    /// so a pre-update Abstain counts like a pre-update Yea or Nay (the default answer to project question 1).
    ///
    /// Decide this from `BillVoteStore.heldVote(for:)` and the bar's choice, never from
    /// `BillVoteStore.vote(for:)`, `Bill.userVoted` or `BillsStore.isVoted` alone: those report an Abstain
    /// as not voted. The server gates `GET /bill-stats` the same way and answers `RESULTS_LOCKED` until it
    /// holds the row; the app shows the lock until then (`BillResultsAccess`).
    static func unlocksResults(choice: VoteChoice?, didJustVote: Bool, holdsRow: Bool) -> Bool {
        choice != nil || didJustVote || holdsRow
    }

    /// Whether bill detail asks for Results now: only while they are unlocked, and not while a vote cast
    /// on the screen is still being sent, because the server answers `RESULTS_LOCKED` until it stores the
    /// vote, and the screen asks once it has (`refreshStatsAfterVoteSaved`).
    static func shouldFetchStats(unlocked: Bool, writeInFlight: Bool) -> Bool {
        unlocked && !writeInFlight
    }

    /// Whether bill detail asks for Results after a vote write ended: never after a refusal that rolled
    /// the vote back (the daily limit, App Attest and the other coded refusals store nothing, APPF-27),
    /// and never once Results are locked again. A vote kept after a failure that may not have been stored
    /// asks, and the server answers `RESULTS_LOCKED` until it holds the vote.
    static func fetchesStatsAfterWrite(result: VoteWriteResult, stillUnlocked: Bool) -> Bool {
        guard stillUnlocked else { return false }
        if case .rolledBack = result { return false }
        return true
    }

    /// The first-vote coach mark (spec D 2.5.5) shows over the three buttons of a bill not voted
    /// on yet, while the tour's flag is pending and the feature is on. Not while the vote is still being
    /// checked: the buttons are disabled then and the panel says "Checking your vote…" instead, which says
    /// why (spec 3.10 "Other states"; at the accessibility sizes Your vote holds nothing then). The tour's
    /// "Open this bill" often lands on a bill whose vote is not known yet; the coach mark follows once the
    /// check finds no vote. Still pending meanwhile: hiding it ends nothing. On an updated bill it shows too,
    /// after "This bill's summary changed. Vote again:" (project decision of 2026-10-21): the panel's one strip is
    /// then the caption (`panelStrip`), and from xxxLarge up Your vote stacks the caption and then the coach
    /// mark (`yourVoteRows`).
    func showsCoachMark(pending: Bool, featureEnabled: Bool = FeatureFlags.voteBarCoachMark) -> Bool {
        guard featureEnabled, pending, choice == nil, !isAwaitingVoteCheck else { return false }
        return showsButtons
    }

    /// The buttons sit under "This bill's summary changed. Vote again:" (an updated bill not voted on since
    /// its update).
    var asksToVoteAgain: Bool {
        layout == .choose(caption: Self.updatedCaption, selected: nil)
    }

    /// The vote is not known yet and the panel says "Checking your vote…": the three buttons are disabled
    /// (45%), and at the accessibility sizes the one button reads "Checking…". An updated bill asks for a
    /// vote again whatever the check finds, so its buttons stay enabled.
    var isAwaitingVoteCheck: Bool {
        layout == .choose(caption: Self.checkingCaption, selected: nil)
    }
}

// MARK: - The ballot (Civic Record spec 3.10, 3.11)

extension BillVoteBarModel {
    static let changingCaption = "Change your vote"
    static let cancelTitle = "Cancel"
    /// The second line under the current vote's word while changing.
    static let currentVoteLine = "Your vote"
    /// The coach mark at the accessibility sizes, where the panel holds one Vote button (spec 3.10.1).
    static let accessibilityCoachMarkText = "Tap Vote to choose Yea, Nay or Abstain. You can change it later."
    /// The one button at the accessibility sizes while the vote is checked.
    static let checkingTitle = "Checking…"
    static let compactHint = "Choose Yea, Nay or Abstain"
    /// The hint of Change and of the voted button at the accessibility sizes.
    static let changeHint = "Change your vote"
    static let changeInputLabels = ["Change", "Change your vote"]
    /// The ballot stamp's VoiceOver action (spec 3.10.3).
    static let goToResultsAction = "Go to Results"
    /// Queued when the stats for a vote made here arrive (spec 3.10.3), over the floor. Under it the floor
    /// line's own words are queued instead (UX-34), so VoiceOver never says "Results are open." over a sheet that
    /// says when they open.
    static let resultsOpenAnnouncement = "Results are open."
    /// Shown in the refusal strip when the vote store gave no text (it always does today).
    static let refusalFallbackText = "This vote wasn't saved. Try again."

    static let summaryIdentifier = "bill.vote.summary"
    static let captionIdentifier = "bill.vote.caption"
    static let coachMarkDismissIdentifier = "bill.vote.coachMark.dismiss"
    static let refusalIdentifier = "bill.vote.refusal"
    static let cancelIdentifier = "bill.vote.cancel"

    /// Voice Control: the visible word, and the spoken label where it differs ("Tap Yea" works as well
    /// as "Tap Vote Yea"; spec 3.10, 3.16).
    static func inputLabels(for choice: VoteChoice) -> [String] {
        choice.accessibilityLabel == choice.title ? [choice.title] : [choice.title, choice.accessibilityLabel]
    }

    /// While changing, the current vote's button: "Vote Yea, your current vote".
    static func currentVoteAccessibilityLabel(_ choice: VoteChoice) -> String {
        "\(choice.accessibilityLabel), your current vote"
    }

    /// The refusal strip's one VoiceOver element: "Error: " and the refusal's text (spec 7.3).
    static func refusalAccessibilityLabel(_ text: String) -> String {
        "Error: \(text)"
    }

    /// What VoiceOver says after a vote here when it is not running (a Switch Control or Voice Control
    /// commit), queued: "You voted Yea.", "You abstained.", or after a change "Your vote is now Nay.".
    static func committedAnnouncement(_ choice: VoteChoice, isChange: Bool) -> String {
        isChange ? "Your vote is now \(choice.title)." : "\(choice.confirmationMessage)."
    }

    // MARK: Text sizes

    /// Where the panel's rows go at a text size (spec 3.10 "At large and accessibility sizes", 7.2).
    enum TextSizeClass: Equatable {
        /// Up to xxLarge: three buttons (the box above the word where it does not fit beside it); the
        /// coach mark, captions and refusal strip in the panel; the stamp beside Change.
        case regular
        /// xxxLarge: three buttons with the box above the word; the coach mark, the `.updatedOnly` caption
        /// and the refusal strip are rows of Your vote; the stamp and Change stacked in the panel.
        case extraLarge
        /// AX1 to AX5: one full-width button; the rows above and the full stamp are in Your vote.
        case accessibility

        init(_ size: DynamicTypeSize) {
            if size.isAccessibilitySize {
                self = .accessibility
            } else if size >= .xxxLarge {
                self = .extraLarge
            } else {
                self = .regular
            }
        }
    }

    /// An opaque strip at the top of the panel (spec 3.10, 3.10.1, 3.10.2).
    enum Strip: Equatable {
        /// The refused vote's reason (APPF-27), on a `danger` rule.
        case refusal(String)
        /// "Change your vote", with Cancel.
        case changing
        /// "Choose Yea, Nay or Abstain. You can change it later.", with Not now.
        case coachMark
        /// "This bill's summary changed. Vote again:" or "Checking your vote…".
        case caption(String)
    }

    /// The one strip over the panel's buttons or stamp, if any. One at a time, so the panel stays within a
    /// quarter of the screen (7.2), in the project's decision of 2026-10-21: the refusal first (it stays until the
    /// next vote tap), then "Change your vote", the caption ("This bill's summary changed. Vote again:" or
    /// "Checking your vote…"), then the coach mark. From xxxLarge up the refusal, the caption and the coach
    /// mark are rows of Your vote instead (`yourVoteRows`); only changing stays, with its Cancel. The one
    /// button at the accessibility sizes has no strip.
    func panelStrip(in sizeClass: TextSizeClass, refusal: String?, showsCoachMark: Bool) -> Strip? {
        let isChangingShown = isChanging && selectedChoice != nil
        switch sizeClass {
        case .accessibility:
            return nil
        case .extraLarge:
            return isChangingShown ? .changing : nil
        case .regular:
            if let refusal { return .refusal(refusal) }
            if isChangingShown { return .changing }
            if case .choose(let caption?, nil) = layout { return .caption(caption) }
            if showsCoachMark { return .coachMark }
            return nil
        }
    }

    /// The rows the panel hands to Your vote from xxxLarge up, first in the section in the panel's order
    /// (spec 3.13; project decision of 2026-10-21): the refusal, the caption, the coach mark, then the stamp.
    struct YourVoteRows: Equatable {
        var refusal: String?
        /// "This bill's summary changed. Vote again:". "Checking your vote…" is Your vote's own first line.
        var caption: String?
        /// The coach mark's words (the accessibility sizes' own at those sizes).
        var coachMark: String?
        /// The full ballot stamp, at the accessibility sizes once voted.
        var stamp: VoteChoice?

        static let none = YourVoteRows()

        var isEmpty: Bool { self == .none }
    }

    /// Every strip that applies, stacked in the panel's order: where the panel shows the first of them, Your
    /// vote has room for each, so an updated bill with the coach mark pending shows the caption and then the
    /// coach mark, as a refused vote shows the refusal and then the coach mark.
    func yourVoteRows(in sizeClass: TextSizeClass, refusal: String?, showsCoachMark: Bool) -> YourVoteRows {
        guard sizeClass != .regular else { return .none }
        var rows = YourVoteRows()
        rows.refusal = refusal
        if asksToVoteAgain {
            rows.caption = Self.updatedCaption
        }
        if showsCoachMark {
            rows.coachMark = sizeClass == .accessibility ? Self.accessibilityCoachMarkText : Self.coachMarkText
        }
        if sizeClass == .accessibility {
            rows.stamp = choice
        }
        return rows
    }

    /// The one full-width button at the accessibility sizes (spec 3.10).
    enum AccessibilityButton: Equatable {
        /// "Vote", the primary capsule: opens the "Your vote" dialog.
        case vote
        /// "Checking…", disabled.
        case checking
        /// The voted capsule, "Yea · Change" (or "Change" where that does not fit): opens the same dialog.
        case voted(VoteChoice)
    }

    var accessibilityButton: AccessibilityButton {
        if let choice { return .voted(choice) }
        return isAwaitingVoteCheck ? .checking : .vote
    }

    // MARK: Control heights

    /// The least height of a panel control (vote buttons, the stamp, Change, the one button).
    static let minimumControlHeight: CGFloat = 50
    /// The room above and below a control's label.
    static let controlLabelPadding: CGFloat = 12

    /// Every control in the panel is `max(50, label line height + 2 × 12)` pt tall (spec 3.10): 50 pt at the
    /// default size and growing with the label, not a 50 pt height scaled by the text size (revision 1's
    /// about 160 pt at AX5).
    static func controlHeight(lineHeight: CGFloat) -> CGFloat {
        max(minimumControlHeight, (lineHeight + 2 * controlLabelPadding).rounded(.up))
    }

    /// `controlHeight(lineHeight:)` for the `button` role's line at a text size.
    static func controlHeight(for size: DynamicTypeSize) -> CGFloat {
        let pointSize = TextRole.button.scaledSize(for: size)
        return controlHeight(lineHeight: UIFont.systemFont(ofSize: pointSize, weight: .semibold).lineHeight)
    }
}

/// The ballot stamp's words and date (Civic Record spec 3.10 "BallotStamp"): "YOU VOTED YEA" (the stamp
/// roles set the capitals), a rule and "OCT 17". The date is when the vote was cast
/// (`BillVoteStore.heldVoteDate(for:)`, or the bill's `lastVotedAt`); without one the rule and the date are
/// left out (the no-date form). A vote from another year carries its year.
struct BallotStampCopy: Equatable {
    let choice: VoteChoice
    /// "Oct 17", or nil for the no-date form.
    let printedDate: String?
    /// "October 17", or nil.
    let spokenDate: String?

    init(choice: VoteChoice, votedAt: Date?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) {
        self.choice = choice
        guard let votedAt else {
            printedDate = nil
            spokenDate = nil
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: votedAt) == calendar.component(.year, from: now)
        printedDate = Self.format(votedAt, sameYear ? "MMMd" : "MMMdyyyy", locale: locale, timeZone: timeZone)
        spokenDate = Self.format(votedAt, sameYear ? "MMMMd" : "MMMMdyyyy", locale: locale, timeZone: timeZone)
    }

    /// "You voted Yea", "You voted Nay", "You abstained".
    var title: String { choice.confirmationMessage }

    /// "You voted Yea on October 17", "You abstained on October 17"; "You voted Yea" with no date.
    var accessibilityLabel: String {
        spokenDate.map { "\(title) on \($0)" } ?? title
    }

    /// The stamp's label for its first focus after a vote made here (spec 3.10.3): "You voted Yea on
    /// October 17.", or after a change "Your vote is now Nay.".
    func committedLabel(isChange: Bool) -> String {
        isChange ? BillVoteBarModel.committedAnnouncement(choice, isChange: true) : "\(accessibilityLabel)."
    }

    private static func format(_ date: Date, _ template: String, locale: Locale, timeZone: TimeZone) -> String {
        DocketDate.string(date, template: template, locale: locale, timeZone: timeZone)
    }
}

// MARK: - The vote moment (Civic Record spec 5.1)

/// The timings of the one celebrated moment (spec 5.1), timed from the release that commits the vote.
enum BallotMoment {
    /// How long the tapped button stays inked before it becomes the stamp; with Reduce Motion the
    /// cross-fade starts at once.
    static func inkHold(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.18
    }

    /// The inked button becoming the stamp: a cross-fade while the button's frame moves and grows into the
    /// stamp's (`BillVoteBar.morphID`), `.smooth` over 0.28 s; with Reduce Motion a 0.2 s opacity cross-fade.
    static func morph(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.28)
    }

    /// When the stamp has settled and VoiceOver focus moves to it: 460 ms, 200 ms with Reduce Motion.
    static func settled(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.2 : 0.46
    }

    /// Inking: the fill goes solid and the inner rule draws in over 120 ms.
    static let ink = Animation.easeOut(duration: 0.12)
    /// A refused vote: the stamp cross-fades back to what the panel showed before.
    static let rollback = Animation.easeInOut(duration: 0.2)
}

// MARK: - VoiceOver focus (Civic Record spec 3.10.3)

/// Where the bill page moves VoiceOver focus on purpose: SwiftUI does not move it to a view that replaces
/// the one the user touched (the stamp replaces the button).
enum VoteFocusTarget: Hashable {
    /// The vote panel's first button (Yea, or Vote at the accessibility sizes).
    case voteButtons
    /// The ballot stamp: in the panel, or in Your vote at the accessibility sizes.
    case stamp
    /// The refusal strip.
    case refusal
    /// The Results title.
    case resultsHeader
}

/// The bill page's focus and announcements around a vote (spec 3.10.3), as a pure state machine: in, a vote
/// committed here, the stamp settled, the stats for the vote arrived, a refusal, the stamp's and the sealed
/// sheet's actions, and whether VoiceOver is running; out, where focus goes and what is announced (queued,
/// so it waits for the current speech).
///
/// - Commit, VoiceOver running: nothing yet; once the stamp settles, focus moves to it, and its label for
///   that first focus is "You voted Yea on October 17." ("Your vote is now Nay." after a change). No
///   announcement, so the two never talk over each other.
/// - Commit, VoiceOver not running (Switch Control, Voice Control): "You voted Yea." is announced at once.
/// - The stats for that vote arrive: "Results are open.", once per vote that opened them; under the floor (UX-34)
///   the floor line's words instead, "Results open at 5 Yea or Nay votes." (project decision of 2026-10-29).
/// - Refused: focus moves to the refusal strip; nothing waits any more.
/// - "Go to Results" on the stamp: focus moves to the Results title; "Go to vote buttons" on the sealed sheet:
///   to the first vote button.
struct VoteFocusPlanner: Equatable {
    enum Event: Equatable {
        /// A vote was recorded on the page. `opensResults`: Results were not open before it.
        case committed(BallotStampCopy, isChange: Bool, opensResults: Bool)
        /// The stamp has settled (460 ms after the commit, 200 ms with Reduce Motion).
        case settled
        /// The stats for the stored vote arrived; `belowFloor` is the line Results show under the floor (UX-34),
        /// nil over it.
        case statsArrived(belowFloor: VoteResultsFormatting.FloorLine?)
        /// The server refused the vote (APPF-27).
        case refused
        /// VoiceOver focus left the stamp: its one-time label is spent.
        case stampFocusLeft
        /// The stamp's "Go to Results".
        case goToResults
        /// The sealed sheet's "Go to vote buttons".
        case goToVoteButtons
    }

    struct Plan: Equatable {
        var focus: VoteFocusTarget?
        var announcement: String?

        static let nothing = Plan()
    }

    /// A commit whose stamp has not settled yet, and whether VoiceOver ran at the commit.
    private(set) var awaitingSettle = false
    /// A commit that opened Results, whose stats have not arrived yet.
    private(set) var awaitingStats = false
    /// The stamp's label for its first focus after a commit, until focus leaves it.
    private(set) var oneTimeStampLabel: String?

    mutating func handle(_ event: Event, voiceOverRunning: Bool) -> Plan {
        switch event {
        case let .committed(stamp, isChange, opensResults):
            awaitingSettle = true
            awaitingStats = opensResults
            if voiceOverRunning {
                oneTimeStampLabel = stamp.committedLabel(isChange: isChange)
                return .nothing
            }
            oneTimeStampLabel = nil
            return Plan(announcement: BillVoteBarModel.committedAnnouncement(stamp.choice, isChange: isChange))
        case .settled:
            guard awaitingSettle else { return .nothing }
            awaitingSettle = false
            return voiceOverRunning ? Plan(focus: .stamp) : .nothing
        case let .statsArrived(belowFloor):
            guard awaitingStats else { return .nothing }
            awaitingStats = false
            return Plan(announcement: belowFloor?.accessibilityText ?? BillVoteBarModel.resultsOpenAnnouncement)
        case .refused:
            awaitingSettle = false
            awaitingStats = false
            oneTimeStampLabel = nil
            return Plan(focus: .refusal)
        case .stampFocusLeft:
            oneTimeStampLabel = nil
            return .nothing
        case .goToResults:
            return Plan(focus: .resultsHeader)
        case .goToVoteButtons:
            return Plan(focus: .voteButtons)
        }
    }
}

// MARK: - Results gate (INT-11)

/// What bill detail shows where Results (and Why people voted) go. Only `.open` draws anything built
/// from other users' votes; the locked states draw the sealed tally sheet (`SealedTally`), which takes
/// no stats.
///
/// Every bill page has the vote bar, a decided bill's too (Civic Record project decision 1), so a locked
/// page is always one vote away from opening: there is no "voting closed" state.
enum BillResultsAccess: Equatable {
    /// Why Results are locked. The sealed sheet draws each with its own copy (`SealedTallyState`).
    enum LockReason: Equatable {
        /// No Yea, Nay or Abstain is held for the bill or its companion group: "Vote to see results".
        case notVoted
        /// The vote state is not known yet (`currentVoteState == .unknown`: a cold start, a new device,
        /// the vote store still loading): "Checking your vote…", as the vote bar says. A vote held on
        /// another device opens Results once its row is read.
        case checking
        /// The vote state is not known and reading it failed (offline, a server error): "Couldn't check
        /// your vote on this bill.", with Try again, which reads it again. The page stops saying
        /// "Checking your vote…" so it never waits on a read that has ended.
        case checkFailed

        /// The sealed sheet's main sentence.
        var text: String {
            switch self {
            case .notVoted: return VoteResultsFormatting.lockText
            case .checking: return BillVoteBarModel.checkingCaption
            case .checkFailed: return VoteResultsFormatting.checkFailedText
            }
        }
    }

    /// Results and Why people voted.
    case open
    /// Locked until the user votes or abstains (INT-11), for this reason.
    case locked(LockReason)
    /// The vote shows here but the server answered `RESULTS_LOCKED`: "Results show once your vote is
    /// saved.", with Try again when the screen has a vote to send again (`canRetry`).
    case awaitingSave(canRetry: Bool)

    /// `unlocked` is `BillVoteBarModel.unlocksResults`, `awaitingSave` the server's `RESULTS_LOCKED`,
    /// `isChecking` an unknown vote state still being read, `checkFailed` an unknown vote state whose read
    /// failed, and `canRetry` a vote shown to send again. Locked wins over awaiting save, and an unknown
    /// vote state never unlocks: only a vote does.
    static func make(
        unlocked: Bool,
        awaitingSave: Bool,
        isChecking: Bool,
        checkFailed: Bool = false,
        canRetry: Bool
    ) -> BillResultsAccess {
        guard unlocked else {
            if checkFailed { return .locked(.checkFailed) }
            return .locked(isChecking ? .checking : .notVoted)
        }
        if awaitingSave { return .awaitingSave(canRetry: canRetry) }
        return .open
    }

    var isOpen: Bool { self == .open }

    /// The sealed sheet offers Try again: a vote to send again (`.awaitingSave(canRetry: true)`), or a vote
    /// read to make again (`.locked(.checkFailed)`).
    var offersTryAgain: Bool {
        self == .awaitingSave(canRetry: true) || self == .locked(.checkFailed)
    }

    /// The sealed sheet's main sentence; nil when open.
    var lockText: String? {
        switch self {
        case .open: return nil
        case .locked(let reason): return reason.text
        case .awaitingSave: return VoteResultsFormatting.awaitingSaveText
        }
    }
}

// MARK: - Refused votes (APPF-27)

/// Bill detail's record of the votes cast on the screen that the server has not answered. Only the
/// latest cast's result can change the screen; an earlier one's is overtaken by the newer vote.
struct BillVoteCastLedger: Equatable {
    enum Outcome: Equatable {
        /// Nothing changes: the vote was stored, kept after a failure, or a newer vote decides.
        case keep
        /// The server refused the vote and the stores rolled it back: drop the screen's choice (the bar,
        /// Your vote and Results then show the restored vote), and put these bills back on the Bills list
        /// (an Abstain cast here took them off).
        case rollBack(undismiss: [UUID])
    }

    /// The latest cast's token, until its result arrives.
    private(set) var latest: UUID?
    /// The bills that Abstains cast here (not answered yet) took off the Bills list.
    private(set) var dismissedBillIDs: [UUID] = []

    /// Records a cast that `dismissed` these bills (an Abstain), and returns its token.
    mutating func begin(dismissing dismissed: [UUID] = []) -> UUID {
        let token = UUID()
        latest = token
        dismissedBillIDs += dismissed.filter { !dismissedBillIDs.contains($0) }
        return token
    }

    /// What the result of the cast `token` changes on the screen.
    mutating func finish(_ token: UUID, result: VoteWriteResult) -> Outcome {
        guard token == latest else { return .keep }
        latest = nil
        let dismissed = dismissedBillIDs
        dismissedBillIDs = []
        guard case .rolledBack(let restored) = result else { return .keep }
        // A restored Abstain row (stored earlier) still keeps the bill off the list.
        return .rollBack(undismiss: restored == .voted(.abstain) ? [] : dismissed)
    }
}

// MARK: - Watch

/// What one tap on a Watch control writes (spec D 2.1.5). Votes never change watch; only these
/// toggles do.
///
/// Watching adds the watch to one guid: a companion group's vote target (the member holding the
/// vote, else the primary), else the bill's. Stopping removes it from the bill (every loaded member
/// of a group, `BillsStore.unwatch`) and from every guid the profile may hold for it.
struct BillWatchPlan: Equatable {
    /// `UserStore.addWatch(guid:)`.
    let addGuid: String?
    /// `BillsStore.unwatch(billID:)`.
    let unwatchBill: Bool
    /// `UserStore.removeWatch(guid:)` for each (a no-op for a guid the profile does not hold).
    let removeGuids: [String]

    static func make(watch: Bool, targetGuid: String?, memberGuids: [String]) -> BillWatchPlan {
        let target = BillsStore.trimmedOrNil(targetGuid)
        if watch {
            return BillWatchPlan(addGuid: target, unwatchBill: false, removeGuids: [])
        }
        var seen = Set<String>()
        let guids = (memberGuids + [target].compactMap { $0 })
            .compactMap { BillsStore.trimmedOrNil($0) }
            .filter { seen.insert($0).inserted }
        return BillWatchPlan(addGuid: nil, unwatchBill: true, removeGuids: guids)
    }
}

extension BillWatchPlan {
    /// Writes the plan through the stores: the profile's watch rows (`PUT`/`DELETE /preferences`,
    /// type Watch) and the bills store's local flags. The bills store marks an added watch on its
    /// bill when the profile changes (`BillsStore.reconcileWatchesFromProfile`).
    func apply(billID: UUID, billsStore: BillsStore, userStore: UserStore) {
        if let addGuid {
            userStore.addWatch(guid: addGuid)
        }
        if unwatchBill {
            billsStore.unwatch(billID: billID)
        }
        for guid in removeGuids {
            userStore.removeWatch(guid: guid)
        }
    }
}

/// The Watch controls' copy and identifiers (spec D 2.1.5).
enum BillWatchCopy {
    static let toolbarIdentifier = "bill.watch.toggle"
    static let rowIdentifier = "bill.watch.row"
    static let rowTitle = "Watch this bill"
    static let rowSubtitle = "Get notified when Congress acts on it."

    /// "Watch" / "Watching": the toolbar button's label.
    static func toolbarLabel(isWatching: Bool) -> String {
        isWatching ? "Watching" : "Watch"
    }

    static func symbolName(isWatching: Bool) -> String {
        isWatching ? "binoculars.fill" : "binoculars"
    }

    /// Announced after a toggle.
    static func announcement(isWatching: Bool) -> String {
        isWatching ? "Watching this bill" : "Stopped watching this bill"
    }
}

// MARK: - Vote saved event

extension BillVoteBarModel {
    /// `userInfo` of `.billboardVoteSaved`: the guid the vote was written to and the vote.
    static func voteSavedUserInfo(guid: String, vote: VoteChoice) -> [AnyHashable: Any] {
        ["guid": guid, "vote": vote.voteType.rawValue]
    }
}
