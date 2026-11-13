import SwiftUI

/// Your vote (Civic Record spec 3.13, 4.35): a ruled section between the bill's text and its Results. It
/// opens with "You haven't voted on this bill." until a vote is held ("Checking your vote…" while the vote
/// is read, "Couldn't check your vote on this bill." when that read failed), then the companion notes, the
/// Watch row and, after a vote made here, the optional reasons picker (its small form after an Abstain). The
/// vote itself is not repeated here at the default sizes: the vote panel (`BillVoteBar`) shows it, on every bill
/// page, a decided bill's too (Civic Record project decision 1). R2's "Vote saved" label, the vote badge and the
/// "Watch for changes" nudge are gone (project decision 9): the Watch row is in this section. No teal anywhere in it.
///
/// From xxxLarge up the panel's strips come here, first, in the panel's order (`movedRows`, spec 3.10, 3.13):
/// the refused vote's reason, the `.updatedOnly` caption, the coach mark; at the accessibility sizes the full
/// ballot stamp follows once voted, since the panel then holds one button.
struct BillYourVoteSection: View {
    /// The section's first line: where the user's vote on the bill stands.
    enum Standing: Equatable {
        /// No Yea, Nay or Abstain is held for the bill or its companion group: "You haven't voted on this bill."
        case notVoted
        /// The vote is being read (a cold start, a new device): "Checking your vote…".
        case checking
        /// Reading the vote failed: "Couldn't check your vote on this bill."
        case checkFailed
        /// A vote is held or was made here: no line (the vote bar shows it).
        case voted

        /// The line, or nil when a vote is held.
        var text: String? {
            switch self {
            case .notVoted: return BillYourVoteSection.notVotedText
            case .checking: return BillYourVoteSection.checkingText
            case .checkFailed: return VoteResultsFormatting.checkFailedText
            case .voted: return nil
            }
        }
    }

    let standing: Standing
    let isWatching: Bool
    /// The bill has a guid to watch.
    var canWatch: Bool = true
    let showsReasonPicker: Bool
    let selectedReasons: Set<VoteReason>
    let reasonVoteType: VoteType?
    /// The reasons the picker offers, in the person's order (`VoteReasonOrder`).
    let reasonOrder: [VoteReason]
    let onToggleReason: (VoteReason) -> Void
    let onSetWatch: (Bool) -> Void
    /// For a companion group (APPF-23): "These bills have identical text. Your vote counts once for both."
    var companionCaption: String?
    /// For a companion group whose members hold different votes (APPF-23): which one counts.
    var companionConflictNote: String?
    var showsRule = true
    /// The vote panel's rows that move here from xxxLarge up (`BillVoteBarModel.yourVoteRows`).
    var movedRows: BillVoteBarModel.YourVoteRows = .none
    /// When the shown vote was cast, for the full stamp's date.
    var votedAt: Date? = nil
    /// The full stamp's label for its first VoiceOver focus after a vote here.
    var stampFocusLabel: String? = nil
    /// The bill page's VoiceOver focus (the stamp and the refusal strip when they are rows here).
    var focus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil
    var onDismissCoachMark: () -> Void = {}
    var onGoToResults: () -> Void = {}

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    static let title = "Your vote"
    static let notVotedText = "You haven't voted on this bill."
    static let checkingText = "Checking your vote…"
    /// The section's scroll anchor: after a vote made on the page, its title goes to the top (spec 3.13).
    static let anchorID = "bill.yourVote"
    /// The refusal row's scroll anchor: from xxxLarge up the page scrolls to it (spec 3.10.2).
    static let refusalAnchorID = "bill.yourVote.refusal"
    /// Space above and below the dotted rule over the reasons picker.
    static let reasonsRuleSpacing: (above: CGFloat, below: CGFloat) = (18, 14)

    var body: some View {
        RecordSection(Self.title, showsRule: showsRule) {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                movedRowsView

                if let line = standing.text {
                    Text(line)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let companionCaption {
                    Text(companionCaption)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bill.vote.companionCaption")
                }

                if let companionConflictNote {
                    BillCompanionConflictNote(text: companionConflictNote)
                }

                if canWatch {
                    watchRow
                }

                if showsReasonPicker {
                    // Set off from the Watch row by a dotted rule, 18 pt under the row and 14 pt over the
                    // picker (frames 5 and 22).
                    VStack(alignment: .leading, spacing: 0) {
                        DottedRule()
                        VoteReasonPicker(
                            selectedReasons: selectedReasons,
                            voteType: reasonVoteType,
                            order: reasonOrder,
                            onToggle: onToggleReason
                        )
                        .padding(.top, Self.reasonsRuleSpacing.below)
                    }
                    .padding(.top, Self.reasonsRuleSpacing.above - BillboardStyle.Space.m)
                }
            }
        }
    }

    /// The panel's rows, as slips of their own, then the full stamp.
    @ViewBuilder
    private var movedRowsView: some View {
        if let refusal = movedRows.refusal {
            VoteStrip(kind: .refusal(refusal), placement: .page, focus: focus)
                .id(Self.refusalAnchorID)
        }
        if let caption = movedRows.caption {
            VoteStrip(kind: .caption(caption), placement: .page)
        }
        if let coachMark = movedRows.coachMark {
            VoteStrip(kind: .coachMark(coachMark), placement: .page, onDismissCoachMark: onDismissCoachMark)
        }
        if let choice = movedRows.stamp {
            BallotStamp(
                copy: BallotStampCopy(choice: choice, votedAt: votedAt, locale: locale, timeZone: timeZone),
                stacked: true,
                cornerRadius: BillboardStyle.Radius.slip,
                accessibilityLabel: stampFocusLabel
            )
            .ballotStampAccessibility(focus: focus, onGoToResults: onGoToResults)
        }
    }

    /// "Watch this bill — Get notified when Congress acts on it.", on the `controlOn` toggle.
    private var watchRow: some View {
        Toggle(isOn: Binding(get: { isWatching }, set: { onSetWatch($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(BillWatchCopy.rowTitle)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                Text(BillWatchCopy.rowSubtitle)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .billboardToggle()
        .accessibilityIdentifier(BillWatchCopy.rowIdentifier)
    }
}

/// The note shown when the user voted differently on two members of a companion group before they were
/// combined: `info.circle` in ink 2 and R2's words, with no box (spec 3.13).
private struct BillCompanionConflictNote: View {
    let text: String

    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 13

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
            Image(systemName: "info.circle")
                .font(TextRole.Face.text.font(size: glyphSize, weight: .semibold))
                .foregroundStyle(BillboardColors.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bill.vote.companionConflict")
    }
}

/// Why Yea?, Why Nay? or Why Abstain? (spec 3.13.1): up to three optional reasons, as selectable tags (ink, a
/// plain plus; selected, an ink fill with a checkmark, never teal), with the "1 of 3" counter in the docket face.
///
/// Shorter after a vote (project decisions of 2026-10-21): the first three reasons, then a "More reasons" text button
/// that shows the rest, so Results show right after a Yea or Nay on every phone (all of them put Results about
/// 350 pt under the panel on a 375 x 667 phone). A reason the user picked always stays visible.
///
/// The order is the person's own (`VoteReasonOrder`, project decision of 2026-10-28): shuffled once per person and the
/// same every time, so no reason is first for everyone, and never by how often others pick a reason (INT-11). A Yea
/// or Nay offers every reason but Need More Information, which contradicts it; an Abstain offers only Need More
/// Information, in a small picker with no counter and no More reasons (feature review N13).
struct VoteReasonPicker: View {
    let selectedReasons: Set<VoteReason>
    let voteType: VoteType?
    /// The reasons offered, in the person's order (`VoteReasonOrder.order(for:seed:)`).
    let order: [VoteReason]
    let onToggle: (VoteReason) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "More reasons" was tapped: every reason shows.
    @State private var showsAll = false
    /// The first reason "More reasons" showed, for VoiceOver's focus, as the button it replaced is gone.
    @AccessibilityFocusState private var focusedReason: VoteReason?

    /// The tags that cannot be chosen once three are: dimmed, as R2 did.
    static let unavailableOpacity: Double = 0.45

    /// How many reasons show before "More reasons", from the start of the person's order: three, the project's
    /// number. On a 375 pt phone each takes a line of its own, and on an iPhone SE (375 x 667, a 20 pt status
    /// bar, no home indicator) the first row of Results still shows above the panel after the post-vote
    /// scroll, as on a 402 x 874 phone (`BillDetailRenderTests`).
    static let leadingCount = 3
    static let moreTitle = "More reasons"
    static let moreIdentifier = "bill.feedback.more"

    /// The reasons shown, in `order`: all of them once expanded; otherwise the first `leadingCount` and any the
    /// user picked.
    static func shownReasons(order: [VoteReason], selected: Set<VoteReason>, expanded: Bool) -> [VoteReason] {
        guard !expanded else { return order }
        return order.enumerated()
            .filter { $0.offset < leadingCount || selected.contains($0.element) }
            .map(\.element)
    }

    /// "More reasons"'s VoiceOver hint: "Shows 10 more reasons."
    static func moreHint(hidden: Int) -> String {
        hidden == 1 ? "Shows 1 more reason." : "Shows \(hidden) more reasons."
    }

    /// "Why Yea? (optional)", "Why Abstain? (optional)".
    static func title(for voteType: VoteType?) -> String {
        guard let voteType else { return "Why? (optional)" }
        return "Why \(voteType.feedbackValue)? (optional)"
    }

    static func counterText(selected: Int) -> String {
        "\(selected) of \(VoteReason.maxSelections)"
    }

    /// The counter shows only where there are more reasons than can be chosen (not after an Abstain).
    static func showsCounter(order: [VoteReason]) -> Bool {
        order.count > VoteReason.maxSelections
    }

    /// The fewest people who must pick a reason on one side before Why people voted shows it (the server's
    /// `BILL_STATS_REASON_MIN_COUNT`).
    static let shownReasonMinimum = 5

    /// Says how reasons are shown before any is picked (feature review N1).
    static let hint = "Choose up to \(VoteReason.maxSelections) reasons. They're shown only as anonymous counts of "
        + "\(shownReasonMinimum) or more. You can skip this."

    /// After an Abstain: the server counts only a Yea's or a Nay's reasons in Why people voted.
    static let abstainHint = "It isn't shown to other people. You can skip this."

    static func hint(for voteType: VoteType?) -> String {
        voteType == .abstain ? abstainHint : hint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            if Self.showsCounter(order: order) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                        titleText.fixedSize()
                        Spacer(minLength: BillboardStyle.Space.s)
                        counter.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                        titleText
                        counter
                    }
                }
            } else {
                titleText
            }

            Text(Self.hint(for: voteType))
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            let shown = Self.shownReasons(order: order, selected: selectedReasons, expanded: showsAll)
            FlowLayout(spacing: BillboardStyle.Space.s) {
                ForEach(shown, id: \.self) { reason in
                    let isSelected = selectedReasons.contains(reason)
                    let unavailable = !isSelected && selectedReasons.count >= VoteReason.maxSelections
                    SelectableTag(title: reason.title, isSelected: isSelected) {
                        onToggle(reason)
                    }
                    .disabled(unavailable)
                    .opacity(unavailable ? Self.unavailableOpacity : 1)
                    .accessibilityFocused($focusedReason, equals: reason)
                    .accessibilityIdentifier("bill.feedback.\(reason.rawValue)")
                }
            }
            .padding(.top, BillboardStyle.Space.xs)

            let hidden = order.filter { !shown.contains($0) }
            if !hidden.isEmpty {
                Button(Self.moreTitle) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsAll = true }
                    focusedReason = hidden.first
                }
                .buttonStyle(BillboardButtonStyle(kind: .textButton))
                .accessibilityHint(Self.moreHint(hidden: hidden.count))
                .accessibilityIdentifier(Self.moreIdentifier)
            }
        }
    }

    private var titleText: some View {
        Text(Self.title(for: voteType))
            .textRole(.name)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var counter: some View {
        Text(Self.counterText(selected: selectedReasons.count))
            .textRole(.docket)
            .foregroundStyle(BillboardColors.dimText)
            // Its own element, so the label is read as written: a label set on the text itself would take
            // the docket face's capitals ("1 OF 3 CHOSEN").
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.counterText(selected: selectedReasons.count)) chosen")
    }
}
