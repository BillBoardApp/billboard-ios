import SwiftUI

/// The ballot stamp (Civic Record spec 3.10 "BallotStamp", 5.1): what a vote button becomes once the vote
/// is cast, in place of R2's confetti and "You voted Yea" row. A double-ruled rectangle on an opaque
/// `sheet`, like a clerk's stamp: a 1.5 pt rule in the vote colour (2 pt with Increase Contrast) and an inner
/// 0.75 pt rule inset 4 pt; inside, the filled ballot box, "YOU VOTED YEA" (`stampLarge`), a 1 pt rule and
/// the date "OCT 17" (`docket`), all in the vote colour.
///
/// - `showsDate: false` is the no-date form: no rule and no date (no date is known, or the dated stamp does
///   not fit beside Change, as on a 375 pt phone).
/// - `stacked` sets the box over the words and the date under them, for the full stamp in Your vote at the
///   accessibility sizes (frame 24); the words wrap there.
/// - `dropsDateToFit` (the vote panel) shows the date only where the dated row fits in the width offered, else
///   the no-date row: one stamp view whatever the form, so it can take part in the vote's morph
///   (`BillVoteBar.morphID`), which a view inside a `ViewThatFits` cannot.
///
/// It is one accessibility element labelled "You voted Yea on October 17" (`accessibilityLabel` overrides it,
/// for the first focus after a vote). The caller adds the id, the "Go to Results" action and the focus.
struct BallotStamp: View {
    let copy: BallotStampCopy
    /// The stamp is at least this tall (the panel's control height), and as wide as offered.
    var minHeight: CGFloat = BillVoteBarModel.minimumControlHeight
    var showsDate = true
    var stacked = false
    /// The dated row where it fits in the width offered, else the no-date row; `showsDate` and `stacked` unused.
    var dropsDateToFit = false
    /// 20 pt in the vote panel (concentric with its 30 pt corners and 10 pt padding), 16 on the page.
    var cornerRadius: CGFloat = BillboardStyle.Radius.panel - BillVoteBar.panelPadding
    var accessibilityLabel: String? = nil

    static let ruleWidth: CGFloat = 1.5
    static let ruleWidthHighContrast: CGFloat = 2
    static let innerRuleInset: CGFloat = 4
    static let innerRuleWidth: CGFloat = 0.75
    static let horizontalPadding: CGFloat = 14
    /// From the rule before the date to the date.
    static let dateRuleGap: CGFloat = 10

    @Environment(\.colorSchemeContrast) private var contrast

    private var color: Color { copy.choice.color }

    private var ruleWidth: CGFloat {
        contrast == .increased ? Self.ruleWidthHighContrast : Self.ruleWidth
    }

    private var printedDate: String? {
        showsDate ? copy.printedDate : nil
    }

    var body: some View {
        controlStamp
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel ?? copy.accessibilityLabel)
    }

    private var controlStamp: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: max(0, cornerRadius - Self.innerRuleInset), style: .continuous)
        return Group {
            if dropsDateToFit {
                ViewThatFits(in: .horizontal) {
                    if let date = copy.printedDate {
                        rowContent(date: date)
                    }
                    // Also where neither fits, which happens only mid-morph, while the stamp grows out of the
                    // inked button: a row keeps its width, so the stamp grows from the no-date row's, never
                    // reflowing its words.
                    rowContent(date: nil)
                }
            } else if stacked {
                stackedContent(date: printedDate)
            } else {
                rowContent(date: printedDate)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, Self.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .background(shape.fill(BillboardColors.cardBackground))
        .overlay(shape.strokeBorder(color, lineWidth: ruleWidth))
        .overlay(inner.strokeBorder(color, lineWidth: Self.innerRuleWidth).padding(Self.innerRuleInset))
        .contentShape(shape)
    }

    /// The box, the words and, given a date, the rule and the date at the trailing edge, on one line.
    private func rowContent(date printedDate: String?) -> some View {
        HStack(spacing: BillboardStyle.Space.s) {
            BallotBox(choice: copy.choice, fill: .filled)
            Text(copy.title)
                .textRole(.stampLarge)
                .lineLimit(1)
                .fixedSize()
            if let printedDate {
                // At the trailing edge, 8 pt from the words at least: the rule, 10 pt, the date.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    dateText(printedDate)
                        .fixedSize()
                        .padding(.leading, Self.dateRuleGap)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(color)
                                .frame(width: 1)
                        }
                }
            }
        }
    }

    /// The box over the words, the date under them (Your vote at the accessibility sizes), 12 pt above and below.
    private func stackedContent(date printedDate: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BallotBox(choice: copy.choice, fill: .filled)
            Text(copy.title)
                .textRole(.stampLarge)
                .fixedSize(horizontal: false, vertical: true)
            if let printedDate {
                dateText(printedDate)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, BillVoteBarModel.controlLabelPadding)
    }

    private func dateText(_ date: String) -> some View {
        Text(date)
            .textRole(.docket)
    }
}

#Preview("Ballot stamps") {
    VStack(spacing: 12) {
        ForEach(VoteChoice.allCases) { choice in
            BallotStamp(copy: BallotStampCopy(choice: choice, votedAt: Date()))
        }
        BallotStamp(copy: BallotStampCopy(choice: .yea, votedAt: Date()), showsDate: false)
        BallotStamp(copy: BallotStampCopy(choice: .nay, votedAt: Date()), stacked: true, cornerRadius: BillboardStyle.Radius.slip)
    }
    .padding()
    .background(BillboardColors.document)
}
