import SwiftUI

/// Label-and-answer rows set like a ledger (Civic Record spec 3.6): the Bill Breakdown, Committees,
/// Actions, member basics and Civic Rank. The label is in the `docket` role, `ink3`, in a
/// fixed column; the answer is `prose` (the Breakdown) or `body` in `ink`. Rows sit 10 pt apart above
/// and below, separated by dotted rules, with no rule above the first.
///
/// At accessibility text sizes, or when the label column would take more than 30% of the row, a row
/// puts its label above its answer. Each row is one VoiceOver element: "Who: The Department of
/// Energy would write the report."
struct Ledger: View {
    /// The label column's width at the default text size (it scales with the label).
    enum Column: CGFloat {
        /// WHO, WHAT, HOW, WHEN, WHERE, WHY.
        case breakdown = 62
        /// Action dates: "FEB 10".
        case dates = 56
        /// Profile topics.
        case topics = 78
        /// Member basics and Civic Rank.
        case wide = 96
        /// In Congress: SPONSOR and LATEST ACTION ("LATEST ACTION" is about 102 pt in the docket face, so
        /// it broke onto two lines in `wide`). In a row narrower than about 347 pt (an iPhone SE's), the
        /// 30% rule puts the labels above the answers.
        case inCongress = 104
    }

    /// One row: the label in sentence case (the docket role sets it in capitals) and the answer. Labels
    /// repeat (two House committees, two actions on Feb 10), so rows are told apart by position.
    struct Row: Equatable {
        let label: String
        let answer: String
        /// A second line under the answer (`caption`, `ink3`), such as an action's type.
        var detail: String? = nil
        /// What VoiceOver reads for the label when it is set differently from how it is said: an action's
        /// date with the year on a second line is read "Feb 10, 2025". Nil reads the label.
        var spokenLabel: String? = nil

        init(_ label: String, _ answer: String, detail: String? = nil, spokenLabel: String? = nil) {
            self.label = label
            self.answer = answer
            self.detail = detail
            self.spokenLabel = spokenLabel
        }

        /// "Who: The Department of Energy would write the report."
        var accessibilityLabel: String {
            [spokenLabel ?? label, answer, detail]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { $0.offset == 0 ? "\($0.element):" : $0.element }
                .joined(separator: " ")
        }
    }

    let rows: [Row]
    var column: Column = .wide
    /// `prose` for the Breakdown, `body` for every other ledger.
    var answerRole: TextRole = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keyed by position: a label is not unique (Committees, Actions), and a repeated key made
            // SwiftUI draw one row twice or drop one.
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    DottedRule()
                }
                LedgerRow(label: row.label, column: column, accessibilityLabel: row.accessibilityLabel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.answer)
                            .textRole(answerRole)
                            .foregroundStyle(BillboardColors.primaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = row.detail, !detail.isEmpty {
                            Text(detail)
                                .textRole(.caption)
                                .foregroundStyle(BillboardColors.dimText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, index == 0 ? 2 : 10)
                .padding(.bottom, 10)
            }
        }
    }
}

/// One ledger row with any answer (a committee with its dated activities, a row of tags): the label in
/// the docket column, the answer beside it, or under it at accessibility sizes and in narrow rows.
/// Separate rows with `DottedRule`. One VoiceOver element: pass the label it reads, or the row's text
/// is combined.
struct LedgerRow<Answer: View>: View {
    let label: String
    var column: Ledger.Column = .wide
    var accessibilityLabel: String? = nil
    @ViewBuilder let answer: Answer

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The label column, scaled with the label (spec 3.6).
    @ScaledMetric private var labelWidth: CGFloat

    init(label: String, column: Ledger.Column = .wide, accessibilityLabel: String? = nil, @ViewBuilder answer: () -> Answer) {
        self.label = label
        self.column = column
        self.accessibilityLabel = accessibilityLabel
        self.answer = answer()
        _labelWidth = ScaledMetric(wrappedValue: column.rawValue, relativeTo: .caption)
    }

    var body: some View {
        LedgerRowLayout(
            labelWidth: labelWidth,
            alwaysStacks: dynamicTypeSize.isAccessibilitySize
        ) {
            Text(label)
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            // One subview for the layout, whatever the answer holds.
            VStack(alignment: .leading, spacing: 2) {
                answer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LedgerRowAccessibility(label: accessibilityLabel))
    }

    private struct LedgerRowAccessibility: ViewModifier {
        let label: String?

        func body(content: Content) -> some View {
            if let label {
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
    }
}

/// Places a ledger row's two subviews: label and answer side by side on their first baselines, 12 pt
/// apart, the label in a fixed column; or stacked 4 pt apart when `alwaysStacks` is set or the column
/// would be wider than 30% of the row.
struct LedgerRowLayout: Layout {
    let labelWidth: CGFloat
    var alwaysStacks = false

    static let gap: CGFloat = 12
    static let stackedGap: CGFloat = 4
    static let maximumLabelShare: CGFloat = 0.3

    /// Whether a row of `width` puts its label above its answer.
    func stacks(in width: CGFloat?) -> Bool {
        if alwaysStacks { return true }
        guard let width, width.isFinite, width > 0 else { return false }
        return labelWidth > Self.maximumLabelShare * width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width
        if stacks(in: width) {
            let label = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let answer = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(width: width ?? max(label.width, answer.width), height: label.height + Self.stackedGap + answer.height)
        }
        let placement = sideBySide(width: width, subviews: subviews)
        return CGSize(width: width ?? (labelWidth + Self.gap + placement.answerSize.width), height: placement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if stacks(in: bounds.width) {
            let label = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: label.height))
            let answer = subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + label.height + Self.stackedGap),
                proposal: ProposedViewSize(width: bounds.width, height: answer.height)
            )
            return
        }
        let placement = sideBySide(width: bounds.width, subviews: subviews)
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + placement.labelY),
            proposal: ProposedViewSize(width: labelWidth, height: placement.labelSize.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + labelWidth + Self.gap, y: bounds.minY + placement.answerY),
            proposal: ProposedViewSize(width: placement.answerSize.width, height: placement.answerSize.height)
        )
    }

    private struct SideBySide {
        let labelSize: CGSize
        let answerSize: CGSize
        let labelY: CGFloat
        let answerY: CGFloat
        let height: CGFloat
    }

    /// Lines up the label's and the answer's first baselines.
    private func sideBySide(width: CGFloat?, subviews: Subviews) -> SideBySide {
        let labelProposal = ProposedViewSize(width: labelWidth, height: nil)
        let answerWidth = width.map { max(0, $0 - labelWidth - Self.gap) }
        let answerProposal = ProposedViewSize(width: answerWidth, height: nil)
        let labelSize = subviews[0].sizeThatFits(labelProposal)
        let answerSize = subviews[1].sizeThatFits(answerProposal)
        let labelBaseline = subviews[0].dimensions(in: labelProposal)[VerticalAlignment.firstTextBaseline]
        let answerBaseline = subviews[1].dimensions(in: answerProposal)[VerticalAlignment.firstTextBaseline]
        let baseline = max(labelBaseline, answerBaseline)
        let labelY = baseline - labelBaseline
        let answerY = baseline - answerBaseline
        let height = max(labelY + labelSize.height, answerY + answerSize.height)
        return SideBySide(
            labelSize: labelSize,
            answerSize: CGSize(width: answerWidth ?? answerSize.width, height: answerSize.height),
            labelY: labelY,
            answerY: answerY,
            height: height
        )
    }
}

#Preview("Ledger") {
    Ledger(
        rows: [
            .init("Who", "The Department of Energy would write the report."),
            .init("What", "A yearly public report on clean energy grants."),
            .init("When", "Starts in fiscal year 2027.")
        ],
        column: .breakdown,
        answerRole: .prose
    )
    .padding(20)
    .background(BillboardColors.document)
}
