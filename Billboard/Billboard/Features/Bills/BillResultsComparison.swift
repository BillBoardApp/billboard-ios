import SwiftUI
import UIKit

// MARK: - Results, open (Civic Record spec 3.7, 4.41)

/// Results as a tally sheet: the title with the info button, the column heads over a heavy rule, a row
/// each for Everyone and Verified voters with its square split bar and 50% tick, the "You" marker, "The
/// line marks 50%.", the abstained line, the user's state and district as dotted-ruled lines, the
/// companion caption and the map plate. Only created once the user votes or abstains (`BillResultsArea`,
/// INT-11). Until the first stats arrive it says "Updating results…" alone (no row may claim there are no
/// votes yet); a failed load says so with Try again. After a vote on the page the sealed sheet shows
/// "Opening results…" instead (`SealedTally`), and this sheet grows its bars once when it replaces it.
///
/// Under the floor (UX-34) the sheet is one line under the heavy rule, "Results open at 5 votes" (no count of
/// the votes so far, project decision of 2026-10-29), with "✓ You voted Yea" (or "You abstained.") under it and the
/// companion caption: no split, no abstain count, no state or district and no map. The map shows only when a
/// state clears the floor (`Summary.showsMap`).
struct BillResultsSection: View {
    let billStats: BillStatsService.BillStats?
    let isLoadingBillStats: Bool
    let billStatsError: String?
    let userStateCode: String
    let userDistrictValue: String
    /// The user's vote, for the "You" marker (Yea or Nay) and "You abstained." (Abstain).
    var yourVote: VoteChoice? = nil
    /// The bars grow once when the first stats arrive after a vote on the page (spec 5.1).
    var growsOnFirstStats = false
    /// Try again after a failed load; nil draws none.
    var onRetry: (() -> Void)? = nil
    var showsRule = true
    /// The bill page's VoiceOver focus: the title is `.resultsHeader` ("Go to Results", spec 3.10.3).
    var titleFocus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil

    static let identifier = "bill.results"
    static let retryIdentifier = "bill.results.retry"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsInfo = false

    private var summary: VoteResultsFormatting.Summary? {
        billStats.map {
            VoteResultsFormatting.summary(for: $0, userStateCode: userStateCode, userDistrictValue: userDistrictValue)
        }
    }

    /// "Combined votes on H.R. 900 and S. 456" when the stats combine a companion group's votes
    /// (APPF-23): the server listed the members in `companionBillIds`.
    private var combinedVotesCaption: String? {
        BillDisplayFormatting.combinedVotesCaption(companionBillIds: billStats?.companionBillIds)
    }

    var body: some View {
        RecordSection(nil, showsRule: showsRule) {
            titleRow

            if let summary, let belowFloor = summary.belowFloor {
                VStack(alignment: .leading, spacing: 0) {
                    BillResultsBelowFloor(line: belowFloor, yourVote: yourVote)
                    if let combinedVotesCaption {
                        BillCombinedVotesCaption(text: combinedVotesCaption)
                            .padding(.top, BillboardStyle.Space.m)
                    }
                }
            } else if let summary {
                VStack(alignment: .leading, spacing: 0) {
                    BillResultsComparison(rows: summary.national, yourVote: yourVote, grows: growsOnFirstStats)
                    notes(summary)
                    localLines(summary)
                    if let combinedVotesCaption {
                        BillCombinedVotesCaption(text: combinedVotesCaption)
                            .padding(.top, BillboardStyle.Space.m)
                    }
                    // The map only with a state over the floor: otherwise every region would be hatched.
                    if summary.showsMap {
                        BillStatsHeatMapSection(
                            billStats: billStats,
                            isLoadingStats: isLoadingBillStats,
                            userStateCode: userStateCode,
                            userDistrictValue: userDistrictValue
                        )
                    }
                }
            } else if let billStatsError {
                unavailable(billStatsError)
            } else {
                updating
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
        .sheet(isPresented: $showsInfo) {
            BillResultsInfoSheet()
        }
    }

    /// "Results" and the info button. The button's 44 pt target overhangs the row, so the title sits
    /// where every other section's does, by the room around the glyph only, so the glyph keeps to the
    /// gutter at every size.
    private var titleRow: some View {
        let overhang = Self.infoTargetOverhang(for: dynamicTypeSize)
        return HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
            Text(VoteResultsFormatting.sectionTitle)
                .textRole(.heading)
                .foregroundStyle(BillboardColors.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocusTarget(titleFocus, equals: .resultsHeader)

            Spacer(minLength: 0)

            Button {
                showsInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .textRole(.body)
                    .imageScale(.large)
                    .foregroundStyle(BillboardColors.interactive)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .padding(.vertical, -overhang.height)
            .padding(.trailing, -overhang.width)
            .accessibilityLabel(VoteResultsFormatting.infoTitle)
            .accessibilityIdentifier("bill.results.info")
        }
    }

    /// How far the info button's 44 pt target reaches past its glyph on each side: half the room the glyph
    /// leaves in it (about 11 pt at the default size), none once the glyph is 44 pt or more (from AX1
    /// up). The glyph is the body role's size with the large symbol scale, as drawn.
    static func infoTargetOverhang(for dynamicTypeSize: DynamicTypeSize) -> CGSize {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: TextRole.body.scaledSize(for: dynamicTypeSize),
            weight: .regular,
            scale: .large
        )
        let glyph = UIImage(systemName: "info.circle", withConfiguration: configuration)?.size ?? .zero
        return CGSize(width: max(0, (44 - glyph.width) / 2), height: max(0, (44 - glyph.height) / 2))
    }

    /// INT-11's line while the first stats load: no rows that claim there are no votes.
    private var updating: some View {
        HStack(spacing: BillboardStyle.Space.s) {
            ProgressView()
                .controlSize(.small)
                .tint(BillboardColors.interactive)
                .accessibilityHidden(true)
            Text(VoteResultsFormatting.loadingText)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
            Text(message)
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button(VoteResultsFormatting.tryAgainTitle, action: onRetry)
                    .buttonStyle(BillboardButtonStyle(kind: .textButton))
                    .accessibilityIdentifier(Self.retryIdentifier)
            }
        }
    }

    /// Under the rows: "The line marks 50%." under bars that have the tick, the abstained count, and "You
    /// abstained." after the user did. (Everyone always has Yea or Nay votes here: under the floor the sheet is
    /// `BillResultsBelowFloor`.)
    @ViewBuilder
    private func notes(_ summary: VoteResultsFormatting.Summary) -> some View {
        let hasSplit = summary.national.contains { $0.value.percentages != nil }
        VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
            if hasSplit {
                Text(VoteResultsFormatting.majorityCaption)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.dimText)
            }
            if let abstainedText = summary.abstainedText {
                Text(abstainedText)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .accessibilityIdentifier("bill.results.abstained")
            }
            if yourVote == .abstain {
                Text(VoteResultsFormatting.youAbstainedText)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, BillboardStyle.Space.s)
    }

    /// The user's state and district: verified voters' result, or the prompt to add an address, each
    /// line closed by a dotted rule under a hairline.
    private func localLines(_ summary: VoteResultsFormatting.Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineRule()
            localLine(summary.state)
            DottedRule()
            if let district = summary.district {
                localLine(district)
                DottedRule()
            }
        }
        .padding(.top, BillboardStyle.Space.m)
    }

    @ViewBuilder
    private func localLine(_ line: VoteResultsFormatting.LocalLine) -> some View {
        switch line {
        case .result(let title, let spokenTitle, let value):
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                Text(value.percentages == nil ? value.text : keptTogether(value.text))
                    .textRole(value.percentages == nil ? .caption : .figureSmall)
                    .foregroundStyle(BillboardColors.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(spokenTitle): \(value.accessibilityText)")
            .accessibilityIdentifier("bill.results.local")
        case .needsAddress(let text):
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                    addressPrompt(text).fixedSize()
                    Spacer(minLength: BillboardStyle.Space.s)
                    addAddressButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    addressPrompt(text)
                    addAddressButton
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func addressPrompt(_ text: String) -> some View {
        Text(VoteResultsFormatting.needsAddressPrompt(text))
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var addAddressButton: some View {
        Button(VoteResultsFormatting.addAddressTitle) {
            NotificationCenter.default.post(name: .billboardRequestLocationEditor, object: nil)
        }
        .buttonStyle(BillboardButtonStyle(kind: .textLink))
        .accessibilityIdentifier("bill.results.addAddress")
    }
}

// MARK: - The tally (Everyone and Verified voters)

/// The tally sheet's measures (spec 3.7): figure columns of 60, 60 and 66 pt that scale with the figures,
/// 8 pt square bars with a 2 pt gap, 7 pt above a bar (the 50% tick stands 4 pt into that) and 4 pt below.
enum TallySheetMetrics {
    static let yeaColumn: CGFloat = 60
    static let nayColumn: CGFloat = 60
    static let votesColumn: CGFloat = 66
    /// Under the column heads, above their 1.5 pt rule.
    static let headRuleGap: CGFloat = 7
    /// Above each row's name.
    static let rowTop: CGFloat = 10
    /// Between a row and its bar block; with the tick's 4 pt overhang the bar is 7 pt under the row.
    static let barTop: CGFloat = 3
    /// The stacked form's blank, one dotted line under each name (spec 3.8.2).
    static let stackedBlank: CGFloat = 80
}

/// The column heads of the tally: an empty name column, "✓ YEA" and "✕ NAY" in the vote colours,
/// "VOTES" in ink 2, right-aligned over their columns, with the 1.5 pt heavy rule under them. Shared by
/// the open and the sealed sheet, so the sealed one shows what is inside. Hidden from VoiceOver: each row
/// reads its own figures.
struct TallyColumnHeads: View {
    @ScaledMetric(relativeTo: .callout) private var yeaColumn = TallySheetMetrics.yeaColumn
    @ScaledMetric(relativeTo: .callout) private var nayColumn = TallySheetMetrics.nayColumn
    @ScaledMetric(relativeTo: .callout) private var votesColumn = TallySheetMetrics.votesColumn

    static let votesTitle = "Votes"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                voteHead(.yea).frame(width: yeaColumn, alignment: .trailing)
                voteHead(.nay).frame(width: nayColumn, alignment: .trailing)
                Text(Self.votesTitle)
                    .textRole(.label)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize()
                    .frame(width: votesColumn, alignment: .trailing)
            }
            HeavyRule(width: 1.5)
                .padding(.top, TallySheetMetrics.headRuleGap)
        }
        .accessibilityHidden(true)
    }

    /// "✓ YEA" or "✕ NAY": a column head is a symbol and a word.
    private func voteHead(_ choice: VoteChoice) -> some View {
        HStack(spacing: 3) {
            Image(systemName: choice.symbolName)
            Text(choice.title)
        }
        .textRole(.label)
        .foregroundStyle(choice.color)
        .fixedSize()
    }
}

/// Everyone and Verified voters as tally rows: the name, then "61%", "39%" and "1,157" in the figures
/// face under the column heads, and the split bar under each row; the "You" marker under Everyone's bar.
/// Where the four columns do not fit (the accessibility sizes), each row stacks: the name, "61% Yea · 39%
/// Nay · 1,157 votes" on its own line, then the bar. Each row is one VoiceOver element: "Everyone: 61
/// percent Yea, 39 percent Nay, 1157 Yea or Nay votes. You voted Yea."
///
/// After a vote on the page the bars grow once from the centre gap (Yea toward the leading edge, Nay toward
/// the trailing one) and the figures roll up from 0, Everyone first and Verified voters 60 ms later; the
/// "You" marker fades in as they end. Later refreshes tween the figures and the widths, without growing
/// again. With Reduce Motion the final state shows at once.
struct BillResultsComparison: View {
    let rows: [VoteResultsFormatting.NationalRow]
    /// The user's vote: Yea or Nay draws the "You" marker under Everyone's bar.
    var yourVote: VoteChoice? = nil
    /// Grow the bars and roll the figures the first time the rows are on screen (spec 5.1). Read once, when
    /// the sheet first appears: it is the first stats after a vote here. Turned on later, under a sheet
    /// already shown (the user votes again on a page whose Results were open), it changes nothing, and the
    /// refresh after that vote tweens the figures like any other.
    var grows = false

    static let growDuration = 0.45
    static let verifiedDelay = 0.06

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var yeaColumn = TallySheetMetrics.yeaColumn
    @ScaledMetric(relativeTo: .callout) private var nayColumn = TallySheetMetrics.nayColumn
    @ScaledMetric(relativeTo: .callout) private var votesColumn = TallySheetMetrics.votesColumn
    /// `grows` as it was when the sheet first appeared; nil until then.
    @State private var growsFromAppearance: Bool?
    /// Whether the rows are on screen (`isOnScreen(_:)`): the grow waits for it.
    @State private var rowsOnScreen = false
    /// The rows that have grown (all of them unless the sheet grows).
    @State private var grownRows: Set<VoteResultsFormatting.NationalRow.Group>?
    @State private var showsMarker: Bool?

    /// The "You" marker's vote: Yea or Nay only.
    private var markerChoice: VoteChoice? {
        yourVote == .yea || yourVote == .nay ? yourVote : nil
    }

    private var animates: Bool {
        (growsFromAppearance ?? grows) && !reduceMotion
    }

    private func progress(_ group: VoteResultsFormatting.NationalRow.Group) -> CGFloat {
        guard animates else { return 1 }
        return (grownRows ?? []).contains(group) ? 1 : 0
    }

    private var markerVisible: Bool {
        guard animates else { return true }
        return showsMarker ?? false
    }

    /// The figures are blank while the sheet waits to grow (its rows are not yet on screen, perhaps just
    /// under the vote panel): scaled by a progress of 0 they read "0%  0%  0", the words of a bill with no
    /// Yea or Nay votes, while VoiceOver read the real ones. They roll up from 0 once the grow starts.
    private var figuresOpacity: Double {
        animates && grownRows == nil ? 0 : 1
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            table
            stacked
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: rows)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bill.results.national")
        .onAppear {
            if growsFromAppearance == nil {
                growsFromAppearance = grows
            }
            grow()
        }
        // The page stacks every section, so the sheet appears when it is inserted, perhaps below the fold;
        // the bars grow when the rows come on screen (spec 5.1, 4.40).
        .onGeometryChange(for: Bool.self, of: Self.isOnScreen) { onScreen in
            rowsOnScreen = onScreen
            grow()
        }
    }

    /// Whether half the rows (or half the visible height, for rows taller than it) are inside the nearest
    /// scroll view's visible bounds. Rows outside a scroll view are on screen when they appear.
    nonisolated static func isOnScreen(_ proxy: GeometryProxy) -> Bool {
        guard let visible = proxy.bounds(of: .scrollView) else { return true }
        let rows = CGRect(origin: .zero, size: proxy.size)
        let shown = rows.intersection(visible)
        guard !shown.isNull, rows.height > 0 else { return false }
        return shown.height >= min(rows.height, visible.height) / 2
    }

    /// Runs the grow once: the first time the rows are on screen after a vote here.
    private func grow() {
        guard animates, rowsOnScreen, grownRows == nil else { return }
        grownRows = []
        showsMarker = false
        withAnimation(.easeOut(duration: Self.growDuration)) {
            _ = grownRows?.insert(.everyone)
        }
        withAnimation(.easeOut(duration: Self.growDuration).delay(Self.verifiedDelay)) {
            _ = grownRows?.insert(.verified)
        }
        withAnimation(.easeOut(duration: 0.2).delay(Self.growDuration)) {
            showsMarker = true
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            TallyColumnHeads()
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        name(row)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        figures(row.value, progress: progress(row.group))
                            .opacity(figuresOpacity)
                    }
                    .padding(.top, TallySheetMetrics.rowTop)
                    bar(row)
                        .padding(.top, TallySheetMetrics.barTop)
                    marker(for: row)
                }
                .modifier(TallyRowAccessibility(row: row, yourVote: markerChoice))
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeavyRule(width: 1.5)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    name(row)
                        .fixedSize(horizontal: false, vertical: true)
                    stackedFigures(row.value, progress: progress(row.group))
                        .opacity(figuresOpacity)
                    bar(row)
                    marker(for: row)
                }
                .padding(.top, TallySheetMetrics.rowTop)
                .modifier(TallyRowAccessibility(row: row, yourVote: markerChoice))
            }
        }
    }

    private func name(_ row: VoteResultsFormatting.NationalRow) -> some View {
        Text(row.title)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
    }

    private func figure(_ text: String, value: Int) -> some View {
        Text(text)
            .textRole(.figure)
            .foregroundStyle(BillboardColors.primaryText)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value)))
            .fixedSize()
    }

    /// The three figure cells: "61%", "39%", "1,157"; "0%", "0%", "0" with no Yea or Nay votes; or
    /// "Fewer than 5 votes so far" (or "Shown once more people vote") across them.
    @ViewBuilder
    private func figures(_ value: VoteResultsFormatting.RowValue, progress: CGFloat) -> some View {
        switch value {
        case .split(let percentages, let decisionVotes):
            let yea = Int((CGFloat(percentages.yea) * progress).rounded())
            let nay = Int((CGFloat(percentages.nay) * progress).rounded())
            let votes = Int((CGFloat(decisionVotes) * progress).rounded())
            figure("\(yea)%", value: yea).frame(width: yeaColumn, alignment: .trailing)
            figure("\(nay)%", value: nay).frame(width: nayColumn, alignment: .trailing)
            figure(votes.formatted(), value: votes).frame(width: votesColumn, alignment: .trailing)
        case .noDecisionVotes:
            figure("0%", value: 0).frame(width: yeaColumn, alignment: .trailing)
            figure("0%", value: 0).frame(width: nayColumn, alignment: .trailing)
            figure("0", value: 0).frame(width: votesColumn, alignment: .trailing)
        case .fewerThanFloor, .withheld:
            Text(value.text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize()
                .frame(width: yeaColumn + nayColumn + votesColumn, alignment: .trailing)
        }
    }

    /// "61% Yea · 39% Nay · 1,157 votes" on its own line, or the row's words.
    @ViewBuilder
    private func stackedFigures(_ value: VoteResultsFormatting.RowValue, progress: CGFloat) -> some View {
        switch value {
        case .split(let percentages, let decisionVotes):
            let yea = Int((CGFloat(percentages.yea) * progress).rounded())
            let shown = VoteResultsFormatting.RowValue.split(
                .init(yea: yea, nay: Int((CGFloat(percentages.nay) * progress).rounded())),
                decisionVotes: Int((CGFloat(decisionVotes) * progress).rounded())
            )
            Text(keptTogether(shown.text))
                .textRole(.figure)
                .foregroundStyle(BillboardColors.primaryText)
                .contentTransition(.numericText(value: Double(yea)))
                .fixedSize(horizontal: false, vertical: true)
        case .noDecisionVotes, .fewerThanFloor, .withheld:
            Text(value.text)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func bar(_ row: VoteResultsFormatting.NationalRow) -> some View {
        if let percentages = row.value.percentages {
            VoteSplitBar(percentages: percentages, progress: progress(row.group))
        } else {
            TallyBlankBar()
        }
    }

    /// Under Everyone's bar, on the user's side: a 4 pt ink tick and "✓ You voted Yea" at the leading end,
    /// or "✕ You voted Nay" at the trailing end, in the vote colour with its symbol and word.
    @ViewBuilder
    private func marker(for row: VoteResultsFormatting.NationalRow) -> some View {
        if row.group == .everyone, let choice = markerChoice {
            let leading = choice == .yea
            let size = TextRole.caption.scaledSize(for: dynamicTypeSize)
            VStack(alignment: leading ? .leading : .trailing, spacing: 2) {
                BillboardColors.primaryText
                    .frame(width: 1.5, height: 4)
                HStack(spacing: 3) {
                    Image(systemName: choice.symbolName)
                    Text(choice.confirmationMessage)
                }
                .font(TextRole.caption.face.font(size: size, weight: .semibold))
                .foregroundStyle(choice.color)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .opacity(markerVisible ? 1 : 0)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Under the floor (UX-34)

/// Results under the floor: the tally sheet's heavy rule, then one line in the row's place, "Results open at
/// 5 votes", with "✓ You voted Yea" under it (the marker's words, without a bar to sit on) or "You abstained.".
/// No split, no abstain count, no count of the votes so far (project decision of 2026-10-29). The line and the
/// marker are one VoiceOver element: "Results open at 5 Yea or Nay votes. You voted Yea."
struct BillResultsBelowFloor: View {
    let line: VoteResultsFormatting.FloorLine
    /// The user's vote: Yea or Nay draws the marker's words, Abstain "You abstained.".
    var yourVote: VoteChoice? = nil

    static let identifier = "bill.results.belowFloor"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var markerChoice: VoteChoice? {
        yourVote == .yea || yourVote == .nay ? yourVote : nil
    }

    private var accessibilityLabel: String {
        SpokenSentences.join([line.accessibilityText, markerChoice?.confirmationMessage])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeavyRule(width: 1.5)
            VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                // A narrow line breaks between the sentence's words, and the figure never leaves its word.
                Text(line.displayText)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                // The marker's words, as under Everyone's bar: "✓ You voted Yea" in the vote colour.
                if let markerChoice {
                    HStack(spacing: 3) {
                        Image(systemName: markerChoice.symbolName)
                        Text(markerChoice.confirmationMessage)
                    }
                    .font(TextRole.caption.face.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .semibold))
                    .foregroundStyle(markerChoice.color)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, TallySheetMetrics.rowTop)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(Self.identifier)

            if yourVote == .abstain {
                Text(VoteResultsFormatting.youAbstainedText)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, BillboardStyle.Space.s)
            }
        }
    }
}

/// "61% Yea · 39% Nay · 1,157 votes" with no-break spaces inside each part, so a narrow line breaks only
/// after a "·" and a figure never leaves its word.
private func keptTogether(_ figures: String) -> String {
    figures
        .components(separatedBy: " · ")
        .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
        .joined(separator: "\u{00A0}· ")
}

/// A tally row as one VoiceOver element with its id: "Everyone: 61 percent Yea, 39 percent Nay, 1157 Yea or
/// Nay votes. You voted Yea." (the "You" part only on Everyone's row).
private struct TallyRowAccessibility: ViewModifier {
    let row: VoteResultsFormatting.NationalRow
    let yourVote: VoteChoice?

    private var label: String {
        guard row.group == .everyone, let yourVote else { return row.accessibilityLabel }
        return "\(row.accessibilityLabel). \(yourVote.confirmationMessage)."
    }

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("bill.results.\(row.group.rawValue)")
    }
}

/// The split bar under a tally row (spec 3.7): the shared split (`TallySplitBar`) in proportion to Yea and
/// Nay only, under the 2 pt `MajorityTick` at half the bar's width, or a 1 pt `rule2` border with no tick when
/// there are no Yea or Nay votes. `progress` grows the segments from the centre gap (spec 5.1). A part: the
/// row beside it carries the vote symbols, words and figures. Hidden from VoiceOver.
struct VoteSplitBar: View {
    let percentages: VoteResultsFormatting.Percentages?
    var progress: CGFloat = 1

    static let height = TallySplitBar.height
    static let gap = TallySplitBar.gap

    var body: some View {
        TallySplitBar(
            yea: Double(percentages?.yea ?? 0),
            nay: Double(percentages?.nay ?? 0),
            progress: progress,
            tick: .whenVotes,
            empty: .outline
        )
    }
}

/// An empty tally bar: 8 pt with a 1 pt `rule2` border and no fill or tick, in the same 16 pt block as a
/// split bar with its tick. The sealed sheet's bars, and a row with no Yea or Nay votes to draw.
struct TallyBlankBar: View {
    var body: some View {
        Rectangle()
            .strokeBorder(BillboardColors.rule2, lineWidth: 1)
            .frame(height: VoteSplitBar.height)
            .padding(.vertical, MajorityTick.overhang)
            .accessibilityHidden(true)
    }
}

/// The (i) sheet: who each row counts (spec D 2.2), the floor (UX-34) and the tick (Civic Record spec 4.44).
struct BillResultsInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(Text(VoteResultsFormatting.everyoneTitle).bold()) \(VoteResultsFormatting.infoEveryoneText)")
                    Text("\(Text(VoteResultsFormatting.verifiedTitle).bold()) \(VoteResultsFormatting.infoVerifiedText)")
                    Text(VoteResultsFormatting.infoOnceText)
                    Text(VoteResultsFormatting.infoLocalText)
                    Text(VoteResultsFormatting.infoFloorText(BillStatsService.Comparison.defaultMinDecisionVotes))
                    Text(VoteResultsFormatting.infoTickText)
                }
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .billboardBackground()
            .navigationTitle(VoteResultsFormatting.infoTitle)
            .navigationBarTitleDisplayMode(.inline)
            .glassNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("bill.results.info.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Paper under the sheet's glass bar (spec 4.7).
        .presentationBackground(BillboardColors.background)
        .accessibilityIdentifier("bill.results.infoSheet")
    }
}
