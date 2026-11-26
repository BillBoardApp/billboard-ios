import SwiftUI

// MARK: - Vote results sections of `BillDetail`
//
// Results (everyone beside verified voters, the user's state and district, the map) is
// `BillResultsSection` in `BillResultsComparison.swift`; Why people voted, the sealed tally sheet and the
// Results area that chooses between them are here. How Congress voted is in `BillOfficialVotesSection.swift`
// and What happens next in `BillAfterVoteSection.swift`. Both show official Congress data, not other users'
// votes, so INT-11 does not seal them.

/// The Yea / Nay split of an official roll call (How Congress voted's tallies): the shared split
/// (`TallySplitBar`) under the 2 pt 50% tick, a `well` fill when the roll call has no Yea or Nay. A part:
/// the rows that draw it show the vote symbols and words. Hidden from VoiceOver.
struct CongressSplitBar: View {
    let yea: Int
    let nay: Int

    static let height = TallySplitBar.height
    static let gap = TallySplitBar.gap

    var body: some View {
        TallySplitBar(yea: Double(yea), nay: Double(nay), tick: .always, empty: .well)
    }
}

/// Why people voted, open (spec 4.46): anonymized reason counts for each side, never names. Two blocks
/// headed "✓ YEA (23)" and "✕ NAY (17)" in the vote colours over a heavy rule, each reason a ledger row
/// with "12 · 52%" in the figures face and a dotted rule under it, then the companion caption. Each reason
/// is one VoiceOver element: "Saves money: 12 people, 52 percent of Yea voters." Under the Results floor
/// (UX-34) it says "Not enough reasons shared yet." whatever the stats hold: the two heads would give the split.
struct BillVoteReasonsSection: View {
    let billStats: BillStatsService.BillStats?
    let isLoadingBillStats: Bool
    var showsRule = true

    static let title = "Why people voted"
    static let notEnoughText = "Not enough reasons shared yet."
    static let loadingText = "Updating reasons…"
    static let emptyText = "Reasons appear once enough people share why they voted. Names are never shown."

    var body: some View {
        RecordSection(Self.title, showsRule: showsRule) {
            VStack(alignment: .leading, spacing: 0) {
                if let billStats, VoteResultsFormatting.isBelowFloor(billStats) {
                    note(Self.notEnoughText)
                } else if let reasonBreakdown = billStats?.reasonBreakdown {
                    if reasonBreakdown.yea.reasons.isEmpty && reasonBreakdown.nay.reasons.isEmpty {
                        note(Self.notEnoughText)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            reasonBlock(choice: .yea, side: reasonBreakdown.yea)
                            reasonBlock(choice: .nay, side: reasonBreakdown.nay)
                        }
                    }
                } else if isLoadingBillStats {
                    note(Self.loadingText)
                } else {
                    note(Self.emptyText)
                }

                if let combinedVotesCaption = BillDisplayFormatting.combinedVotesCaption(
                    companionBillIds: billStats?.companionBillIds
                ) {
                    BillCombinedVotesCaption(text: combinedVotesCaption)
                        .padding(.top, BillboardStyle.Space.m)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .textRole(.body)
            .foregroundStyle(BillboardColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reasonBlock(
        choice: VoteChoice,
        side: BillStatsService.ReasonSide
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VoteCountHead(choice: choice, count: side.voteCount)
                .padding(.bottom, 6)
            HeavyRule(width: 1.5)

            if side.reasons.isEmpty {
                note(Self.notEnoughText)
                    .padding(.vertical, 9)
            } else {
                ForEach(side.reasons, id: \.reasonKey) { reason in
                    reasonRow(reason, choice: choice)
                    DottedRule()
                }
            }
        }
    }

    private func reasonRow(_ reason: BillStatsService.ReasonBucket, choice: VoteChoice) -> some View {
        let name = reasonDisplayName(reason.reasonKey)
        let figures = "\(reason.count) · \(formattedPercent(reason.pct))"
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                Text(name)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize()
                Spacer(minLength: BillboardStyle.Space.s)
                Text(figures)
                    .textRole(.figure)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(figures)
                    .textRole(.figure)
                    .foregroundStyle(BillboardColors.primaryText)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            VoteResultsFormatting.reasonAccessibilityLabel(reason: name, count: reason.count, pct: reason.pct, choice: choice)
        )
    }

    private func reasonDisplayName(_ key: String) -> String {
        if let voteReason = VoteReason(rawValue: key) {
            return voteReason.title
        }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// The caption under stats that combine a companion group's votes (APPF-23): `caption`, ink 3, no glyph
/// (spec 3.7).
struct BillCombinedVotesCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.dimText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("bill.stats.combinedCaption")
    }
}

// MARK: - Results gate (INT-11)

/// Results and Why people voted as the bill page stacks them (spec 4.28): open, the tally sheet and the
/// reasons; otherwise both drawn sealed (`SealedTally`), which take no stats. Nothing built from other
/// users' votes is created while sealed: no blur, no placeholder figures, no map. After a vote on the page
/// Results are open but the stats for it have not arrived, so the sheet shows Opening (the seal lifted, a
/// spinner) and cross-fades to the tally sheet when they do. How Congress voted (the official roll calls)
/// is not gated: the page shows it further down either way.
struct BillResultsArea: View {
    let access: BillResultsAccess
    let billStats: BillStatsService.BillStats?
    let isLoadingBillStats: Bool
    let billStatsError: String?
    let userStateCode: String
    let userDistrictValue: String
    /// A vote was made on this screen: Results show Opening until its stats arrive, and the bars grow once.
    var didVoteHere = false
    /// The user's vote, for the "You" marker and "You abstained." on the open sheet.
    var yourVote: VoteChoice? = nil
    /// Try again on the sealed sheet: reads the vote again, or sends the unsaved vote again.
    var onTryAgain: () -> Void = {}
    /// Try again when the open sheet's stats failed to load.
    var onRetryStats: (() -> Void)? = nil
    /// The sealed sheet's VoiceOver action "Go to vote buttons".
    var onGoToVoteButtons: (() -> Void)? = nil
    /// The bill page's VoiceOver focus: the Results title is `.resultsHeader`, where the ballot stamp's
    /// "Go to Results" moves it (spec 3.10.3). Nil attaches none (render tests).
    var titleFocus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil

    /// The sealed sheet's state, or nil for the open sheet.
    var sealedState: SealedTallyState? {
        SealedTallyState(access: access, opening: didVoteHere && billStats == nil && billStatsError == nil)
    }

    var body: some View {
        let sealed = sealedState
        VStack(alignment: .leading, spacing: 0) {
            if let sealed {
                SealedTally(kind: .results, state: sealed, onTryAgain: onTryAgain, onGoToVoteButtons: onGoToVoteButtons, titleFocus: titleFocus)
                    .transition(.opacity)
                SealedTally(kind: .reasons, state: sealed, onGoToVoteButtons: onGoToVoteButtons)
                    .transition(.opacity)
            } else {
                BillResultsSection(
                    billStats: billStats,
                    isLoadingBillStats: isLoadingBillStats,
                    billStatsError: billStatsError,
                    userStateCode: userStateCode,
                    userDistrictValue: userDistrictValue,
                    yourVote: yourVote,
                    growsOnFirstStats: didVoteHere,
                    onRetry: onRetryStats,
                    titleFocus: titleFocus
                )
                .transition(.opacity)
                BillVoteReasonsSection(
                    billStats: billStats,
                    isLoadingBillStats: isLoadingBillStats
                )
                .transition(.opacity)
            }
        }
        // Opening cross-fades to the tally sheet when the stats arrive (spec 5.1), with Reduce Motion too.
        .animation(.easeInOut(duration: 0.2), value: sealed == nil)
    }
}

/// The sealed tally sheet (spec 3.8, as the project changed it): Results, or Why people voted, before the
/// user votes or abstains, drawn as the ruled sheet with blank cells under a SEALED stamp, so the page
/// shows what is inside without showing any of it. It takes no stats. Under the sheet: the line and the
/// plain reason, and Try again where there is something to try again.
///
/// - Results: the column heads and their heavy rule; "Everyone" and "Verified voters" with a 30 pt dotted
///   blank in each figure cell and an empty 8 pt bar; the stamp centred over the rows on the document's
///   colour. Where the columns do not fit, or the centred stamp would cover a row's name (the accessibility
///   sizes; from xLarge on a 375 pt phone), the rows stack, each blank becomes one 80 pt dotted line under the
///   name, and the stamp moves above the rows, on the leading gutter (frame 26).
/// - Why people voted: "✓ YEA" and "✕ NAY" over heavy rules, two dotted blank lines each, the stamp, and
///   "Reasons open after you vote." (nothing beside the spinner).
///
/// While the vote is checked, and in Opening, a spinner takes the stamp's place. The title is its own
/// header element; the sheet and its words are one element labelled "Sealed" (or the spinner's words)
/// with the line and the text as its value. Before a vote it has the action "Go to vote buttons".
struct SealedTally: View {
    enum Kind {
        case results
        case reasons
    }

    let kind: Kind
    let state: SealedTallyState
    var showsRule = true
    var onTryAgain: () -> Void = {}
    var onGoToVoteButtons: (() -> Void)? = nil
    /// Focus for the title (`.resultsHeader`, Results only); nil attaches none.
    var titleFocus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil

    /// INT-11's id for the sealed Results element (kept for the smoke UI tests).
    static let resultsIdentifier = "bill.results.locked"
    /// Opening is open Results waiting for their stats, not locked ones.
    static let openingIdentifier = "bill.results.opening"
    static let reasonsIdentifier = "bill.reasons.locked"
    static let tryAgainIdentifier = "bill.results.tryAgain"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var yeaColumn = TallySheetMetrics.yeaColumn
    @ScaledMetric(relativeTo: .callout) private var nayColumn = TallySheetMetrics.nayColumn
    @ScaledMetric(relativeTo: .callout) private var votesColumn = TallySheetMetrics.votesColumn
    @ScaledMetric(relativeTo: .callout) private var stackedBlank = TallySheetMetrics.stackedBlank

    private var title: String {
        kind == .results ? VoteResultsFormatting.sectionTitle : BillVoteReasonsSection.title
    }

    private var identifier: String {
        switch kind {
        case .results: return state == .opening ? Self.openingIdentifier : Self.resultsIdentifier
        case .reasons: return Self.reasonsIdentifier
        }
    }

    private var line: String? {
        kind == .results ? state.line : nil
    }

    private var text: String? {
        kind == .results ? state.text : state.reasonsText
    }

    var body: some View {
        // The title is drawn here rather than by `RecordSection`, at the same place, so it can take focus.
        RecordSection(nil, showsRule: showsRule) {
            Text(title)
                .textRole(.heading)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocusTarget(kind == .results ? titleFocus : nil, equals: .resultsHeader)
            VStack(alignment: .leading, spacing: 0) {
                sheetElement
                if kind == .results, state.offersTryAgain {
                    Button(VoteResultsFormatting.tryAgainTitle, action: onTryAgain)
                        .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: false))
                        .accessibilityIdentifier(Self.tryAgainIdentifier)
                        .padding(.top, BillboardStyle.Space.m)
                        .transition(.opacity)
                }
            }
            // The stamp and the spinner swap with a 0.2 s fade (spec 3.8.4); with Reduce Motion at once.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
        }
    }

    /// The sheet and the words under it: one VoiceOver element.
    private var sheetElement: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .results:
                // At the accessibility sizes the rows stack and the stamp moves above them (spec 3.8.2).
                if dynamicTypeSize.isAccessibilitySize {
                    resultsStacked
                } else {
                    ViewThatFits(in: .horizontal) {
                        resultsTable
                        resultsStacked
                    }
                }
            case .reasons:
                reasonsSheet
            }
            words
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoteResultsFormatting.sealedAccessibilityLabel(state))
        .accessibilityValue(VoteResultsFormatting.sealedAccessibilityValue(state, reasons: kind == .reasons) ?? "")
        .accessibilityActions {
            if state.offersGoToVoteButtons, let onGoToVoteButtons {
                Button(VoteResultsFormatting.goToVoteButtonsAction, action: onGoToVoteButtons)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    /// The line ("Vote to see results", `name`) and the text (`body`, ink 2), 16 pt under the sheet.
    @ViewBuilder
    private var words: some View {
        if line != nil || text != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let line {
                    Text(line)
                        .textRole(.name)
                        .foregroundStyle(BillboardColors.primaryText)
                }
                if let text {
                    Text(text)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, BillboardStyle.Space.l)
            .transition(.opacity)
        }
    }

    // MARK: Results

    private static let rowNames = [VoteResultsFormatting.everyoneTitle, VoteResultsFormatting.verifiedTitle]

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            TallyColumnHeads()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.rowNames, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            rowName(name)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            blank.frame(width: yeaColumn, alignment: .trailing)
                            blank.frame(width: nayColumn, alignment: .trailing)
                            blank.frame(width: votesColumn, alignment: .trailing)
                        }
                        .padding(.top, TallySheetMetrics.rowTop)
                        TallyBlankBar()
                            .padding(.top, TallySheetMetrics.barTop)
                    }
                }
            }
            .overlay { overlaidMark }
            stampClearance
        }
    }

    /// Not drawn, no height: the widest row name on each side of the SEALED stamp and its backing. It makes the
    /// table's ideal width what the centred stamp needs to clear the names, so `ViewThatFits` takes the stacked
    /// form as soon as the stamp would cover one ("Verified voters" at xLarge on a 375 pt phone, xxLarge on
    /// 402 pt). Always the stamp, never the spinner: it sits between the rows, and the sheet keeps one form
    /// from checking to sealed.
    private var stampClearance: some View {
        HStack(spacing: 0) {
            widestRowName
            StatusStamp(.sealed, size: .seal)
                .padding(.horizontal, Self.markBackingPadding)
            widestRowName
        }
        .fixedSize()
        .frame(height: 0)
        .hidden()
        .accessibilityHidden(true)
    }

    private var widestRowName: some View {
        ZStack {
            ForEach(Self.rowNames, id: \.self) { rowName($0) }
        }
    }

    private var resultsStacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            stackedMark
            HeavyRule(width: 1.5)
            ForEach(Self.rowNames, id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    rowName(name)
                        .fixedSize(horizontal: false, vertical: true)
                    DottedRule()
                        .frame(width: stackedBlank)
                        .padding(.vertical, 8)
                    TallyBlankBar()
                }
                .padding(.top, TallySheetMetrics.rowTop)
            }
        }
    }

    private func rowName(_ name: String) -> some View {
        Text(name)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
    }

    /// A figure cell left blank: 30 pt of dotted rule, 3 pt above the row's baseline.
    private var blank: some View {
        DottedRule()
            .frame(width: 30)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
    }

    // MARK: Why people voted

    private var reasonsSheet: some View {
        let stampAbove = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 0) {
            if stampAbove {
                stackedMark
            }
            VStack(alignment: .leading, spacing: 14) {
                reasonsBlock(.yea)
                reasonsBlock(.nay)
            }
            .overlay {
                if !stampAbove { overlaidMark }
            }
        }
    }

    /// "✓ YEA" or "✕ NAY" over a heavy rule, then two blank dotted lines.
    private func reasonsBlock(_ choice: VoteChoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: choice.symbolName)
                Text(choice.title)
            }
            .textRole(.label)
            .foregroundStyle(choice.color)
            .padding(.bottom, 6)
            HeavyRule(width: 1.5)
            blankLine(fraction: 1)
            blankLine(fraction: 0.62)
        }
    }

    private func blankLine(fraction: CGFloat) -> some View {
        GeometryReader { geometry in
            DottedRule()
                .frame(width: geometry.size.width * fraction)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 18)
    }

    // MARK: The mark

    /// The document-coloured backing's reach past the mark's sides.
    private static let markBackingPadding = BillboardStyle.Space.m

    /// Over the rows: the mark centred on the document's colour, so the blanks stop at its edge.
    private var overlaidMark: some View {
        mark
            .padding(.vertical, 6)
            .padding(.horizontal, Self.markBackingPadding)
            .background(BillboardColors.document)
    }

    /// Above the stacked rows (the accessibility sizes, frame 26): the mark on the leading gutter, under the
    /// title like the rows' names, with no backing (nothing runs behind it).
    private var stackedMark: some View {
        mark
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, BillboardStyle.Space.m)
    }

    /// The SEALED stamp, or a spinner where the vote is checked and in Opening.
    private var mark: some View {
        Group {
            if let spinnerText = state.spinnerText {
                HStack(spacing: BillboardStyle.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BillboardColors.interactive)
                        .accessibilityHidden(true)
                    // Why people voted shows the spinner alone: Results above say what it waits for.
                    if kind == .results {
                        // Wraps at the largest sizes: one line wider than the column would widen the
                        // whole page past its gutters (spec 7.2).
                        Text(spinnerText)
                            .textRole(.caption)
                            .foregroundStyle(BillboardColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            } else {
                StatusStamp(.sealed, size: .seal)
                    .transition(.opacity)
            }
        }
    }
}

private func formattedPercent(_ value: Double?) -> String {
    guard let value else { return "—" }
    let rounded = round(value * 10) / 10
    if abs(rounded.rounded() - rounded) < 0.05 {
        return "\(Int(rounded.rounded()))%"
    }
    return String(format: "%.1f%%", rounded)
}
