import SwiftUI

/// A roll sheet (Civic Record spec 3.15): the slip that lists members, and every other short list of
/// rows you tap to open (How Congress works, See all members, Parties, Topic groups). A `sheet` fill,
/// a 1 pt `rule` inside the edge and `Radius.slip` corners, no shadow; optional column heads in the
/// `label` role (`ink3`, 9 pt above, 8 pt below, a hairline under them); then the rows, a hairline
/// between each two (`RollRows`). Rows carry their own padding.
///
/// At accessibility text sizes the column heads are hidden (spec 7.2): each row then says in words
/// what the column held ("2 bills this week"). The heads are hidden from VoiceOver at every size,
/// since every row's label already says it.
struct RollSheet<Content: View>: View {
    /// "MEMBER" over the names and "BILLS THIS WEEK" over the figures (the `label` role sets them in
    /// capitals).
    struct ColumnHeads: Equatable {
        let leading: String
        let trailing: String
    }

    var columnHeads: ColumnHeads? = nil
    @ViewBuilder let content: Content

    init(columnHeads: ColumnHeads? = nil, @ViewBuilder content: () -> Content) {
        self.columnHeads = columnHeads
        self.content = content()
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if let columnHeads, !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.m) {
                    Text(columnHeads.leading)
                    Spacer(minLength: 0)
                    Text(columnHeads.trailing)
                        .multilineTextAlignment(.trailing)
                }
                .textRole(.label)
                .foregroundStyle(BillboardColors.dimText)
                .padding(.leading, BillboardStyle.Space.l)
                .padding(.trailing, RollRowInsets.trailing)
                .padding(.top, 9)
                .padding(.bottom, BillboardStyle.Space.s)
                .accessibilityHidden(true)
                HairlineRule()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BillboardColors.cardBackground)
        .clipShape(shape)
        // Inside the edge, so nothing is drawn outside the sheet's frame.
        .overlay(shape.strokeBorder(BillboardColors.separator, lineWidth: 1))
    }
}

/// A roll sheet's rows with a hairline between each two (spec 3.15).
struct RollRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (_ index: Int, _ item: Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (_ index: Int, _ item: Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 {
                HairlineRule()
            }
            row(index, item)
        }
    }
}

/// The padding inside a roll-sheet row (the mockup's `.rep` and `.qrow`): 12 pt above and below, 16 pt
/// from the leading edge (where the slip's text starts), 14 pt from the trailing edge, where a chevron
/// or a figure sits.
enum RollRowInsets {
    static let vertical: CGFloat = 12
    static let leading: CGFloat = 16
    static let trailing: CGFloat = 14
    /// Between the row's parts.
    static let gap: CGFloat = 12

    static var standard: EdgeInsets {
        EdgeInsets(top: vertical, leading: leading, bottom: vertical, trailing: trailing)
    }
}

/// The trailing `chevron.right` of a row that opens a page, in `ink3`, scaled with the text. Decoration:
/// the row's button trait says it opens something.
struct RowChevron: View {
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 14

    var body: some View {
        Image(systemName: "chevron.right")
            .font(TextRole.Face.text.font(size: size, weight: .semibold))
            .foregroundStyle(BillboardColors.dimText)
            .accessibilityHidden(true)
    }
}

/// A ruled row that opens a page (spec 4.57, 4.58, 4.27): the title in the `name` role, an optional line
/// under it in the `caption` role (`ink2`), an optional figure in the docket face at the trailing edge
/// (a bill count), and the chevron. No symbol at the leading edge and no coloured border. At
/// accessibility sizes the figure goes under the title, so the title keeps the width.
///
/// One VoiceOver element: "Parties, Members and bills by party"; the link around it adds the button
/// trait.
struct RollLinkRow: View {
    let title: String
    var subtitle: String? = nil
    /// "12" beside "Agriculture and Food" in Topic groups.
    var figure: String? = nil
    /// What VoiceOver reads for the figure ("12 bills"); the figure itself when nil.
    var spokenFigure: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var accessibilityText: String {
        [title, subtitle, spokenFigure ?? figure]
            .compactMap { $0?.trimmedNonEmpty }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: RollRowInsets.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textRole(.name)
                    .foregroundStyle(BillboardColors.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let figure, dynamicTypeSize.isAccessibilitySize {
                    Text(spokenFigure ?? figure)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let figure, !dynamicTypeSize.isAccessibilitySize {
                Text(figure)
                    .textRole(.figure)
                    .foregroundStyle(BillboardColors.primaryText)
            }
            RowChevron()
        }
        .padding(RollRowInsets.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

#Preview("Roll sheet") {
    VStack(spacing: 16) {
        RollSheet {
            RollLinkRow(title: "Parties", subtitle: "Members and bills by party")
            HairlineRule()
            RollLinkRow(title: "House of Representatives", subtitle: "435 members")
        }
        RollSheet(columnHeads: .init(leading: "Topic group", trailing: "Bills")) {
            RollLinkRow(title: "Agriculture and Food", figure: "12", spokenFigure: "12 bills")
        }
    }
    .padding(16)
    .background(BillboardColors.background)
}
