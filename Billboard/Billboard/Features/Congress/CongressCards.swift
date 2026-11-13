import SwiftUI

/// The figures of a party or chamber page (Civic Record spec 4.58): Composition, Bills by topic group
/// and Bills by topic as ruled rows, each label in `body` and its figure in the docket face at the
/// trailing edge, dotted rules between rows (the ledger of spec 3.6 with mono figures, set with the
/// label first because the labels are names, not docket words). R2's `CongressKeyValueListCard`.
struct CongressFigureList: View {
    let rows: [(label: String, value: String)]
    /// Shown when there are no rows.
    var emptyText: String = "Not available"

    var body: some View {
        if rows.isEmpty {
            Text(emptyText)
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        DottedRule()
                    }
                    FigureRow(label: row.label, figure: row.value)
                }
            }
        }
    }
}

/// A party or chamber page's scrolling document (spec 4.58): the front matter, then the page's sections,
/// with the bar's inline title shown only once the front matter's title has scrolled under the bar, as on
/// the member page (`DocumentInlineTitle`), so the page never shows its title twice.
struct CongressDocumentScroll<Content: View>: View {
    let title: String
    var party: PoliticalParty? = nil
    let docket: String?
    @ViewBuilder let content: Content

    init(title: String, party: PoliticalParty? = nil, docket: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.party = party
        self.docket = docket
        self.content = content()
    }

    private static var coordinateSpace: String { "congressDocument" }

    /// The bottom of the front matter in the page's coordinates.
    @State private var titleBottom: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CongressDocumentFrontMatter(title: title, party: party, docket: docket)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named(Self.coordinateSpace)).maxY
                    } action: { bottom in
                        titleBottom = bottom
                    }

                content
            }
            .padding(.bottom, BillboardStyle.Space.xxl)
            .coordinateSpace(name: Self.coordinateSpace)
        }
        .modifier(DocumentInlineTitle(title: title, titleBottom: titleBottom))
    }
}

/// The front matter of a party or chamber page, set as a document (spec 4.58): an optional party disc,
/// the title in the `title` role, a docket line under it ("433 MEMBERS · 6 DELEGATES", "STATES: AK, AL"),
/// and the double rule.
struct CongressDocumentFrontMatter: View {
    let title: String
    var party: PoliticalParty? = nil
    let docket: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: BillboardStyle.Space.m) {
                if let party {
                    PartyBadge(party: party, size: .regular)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .textRole(.title)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let docket {
                Text(docket)
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            DoubleRule()
                .padding(.top, BillboardStyle.Space.l)
        }
        .padding(.horizontal, BillboardStyle.Space.xl)
        .padding(.top, BillboardStyle.Space.l)
    }
}

/// A label and a short figure on one line, the figure right-aligned in the docket face; at accessibility
/// sizes the figure goes under the label. Separate rows with `DottedRule`. One VoiceOver element.
struct FigureRow: View {
    let label: String
    let figure: String
    var isDim = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    labelText
                    figureText
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.m) {
                    labelText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    figureText
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(figure)")
    }

    private var labelText: some View {
        Text(label)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var figureText: some View {
        Text(figure)
            .textRole(.figure)
            .foregroundStyle(isDim ? BillboardColors.dimText : BillboardColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
