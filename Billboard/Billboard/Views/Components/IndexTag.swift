import SwiftUI

/// The ink tab that replaces every coloured chip (Civic Record spec 3.3): an optional glyph and the
/// word in the `tagLabel` role (11 pt SF Pro Text semibold, capitals), both `ink2`, in a 1 pt `rule2`
/// box with `Radius.mark` corners and no fill. The glyph tells two kinds of the same word apart for
/// sighted readers (the topic "Housing" and the life area "Housing"); VoiceOver hears a spoken prefix
/// instead ("Topic: Housing", "Life area: Housing"). No hue: gold, purple and blue leave the chips.
///
/// At accessibility text sizes the word is set in sentence case without the tracking, and the glyph
/// goes above it when the two do not fit on one line, so a long word ("Healthcare", "Infrastructure")
/// stays whole in a phone-wide column instead of breaking as HEALTHCAR/E. A single word wider than the
/// column at AX5 ("Telecommunications") still wraps: tags never truncate or shrink (spec 7.2).
struct IndexTag: View {
    enum Kind: Equatable {
        case inTheNews
        case memberYouFollow
        case topic(String)
        case lifeArea(String)
        case identicalBills
        /// Any other tag: the word, an optional symbol (drawn in its outline form) and what VoiceOver
        /// reads (the word when nil).
        case custom(title: String, systemImage: String?, spoken: String?)

        var title: String {
            switch self {
            case .inTheNews: return "In the news"
            case .memberYouFollow: return "Member you follow"
            case let .topic(name): return name
            case let .lifeArea(name): return name
            case .identicalBills: return "Identical bills"
            case let .custom(title, _, _): return title
            }
        }

        /// One glyph per kind (spec 2.10): `newspaper`, `person`, `tag`, `house`, `doc.on.doc`.
        var systemImage: String? {
            switch self {
            case .inTheNews: return "newspaper"
            case .memberYouFollow: return "person"
            case .topic: return "tag"
            case .lifeArea: return "house"
            case .identicalBills: return "doc.on.doc"
            case let .custom(_, systemImage, _): return systemImage.map(IndexTag.outlineSymbol)
            }
        }

        var accessibilityLabel: String {
            switch self {
            case let .topic(name): return "Topic: \(name)"
            case let .lifeArea(name): return "Life area: \(name)"
            case let .custom(title, _, spoken): return spoken ?? title
            default: return title
            }
        }
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// A tag with any word and symbol.
    init(title: String, systemImage: String?, accessibilityLabel: String? = nil) {
        self.kind = .custom(title: title, systemImage: systemImage, spoken: accessibilityLabel)
    }

    /// Index tags draw outline symbols: "newspaper.fill" → "newspaper", "person.crop.circle.fill" →
    /// "person.crop.circle".
    nonisolated static func outlineSymbol(_ name: String) -> String {
        name.replacingOccurrences(of: ".fill", with: "")
    }

    @ScaledMetric(relativeTo: .caption2) private var glyphSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var minHeight: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The word's role: `tagLabel` (capitals, +0.08 em), or at accessibility sizes `smallCaption`, the
    /// same face, size and weight in sentence case with no tracking.
    static func wordRole(at dynamicTypeSize: DynamicTypeSize) -> TextRole {
        dynamicTypeSize.isAccessibilitySize ? .smallCaption : .tagLabel
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.mark, style: .continuous)
        Group {
            if dynamicTypeSize.isAccessibilitySize, kind.systemImage != nil {
                // The glyph beside the word while both fit on one line, above it when they do not.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BillboardStyle.Space.xs) {
                        glyph
                        word.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        glyph
                        word
                    }
                }
            } else {
                HStack(spacing: BillboardStyle.Space.xs) {
                    glyph
                    word
                }
            }
        }
        .foregroundStyle(BillboardColors.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .frame(minHeight: minHeight)
        .overlay(shape.strokeBorder(BillboardColors.rule2, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.accessibilityLabel)
    }

    @ViewBuilder
    private var glyph: some View {
        if let systemImage = kind.systemImage {
            Image(systemName: systemImage)
                .font(TextRole.Face.text.font(size: glyphSize, weight: .medium))
                .accessibilityHidden(true)
        }
    }

    private var word: some View {
        Text(kind.title)
            .textRole(Self.wordRole(at: dynamicTypeSize))
            .multilineTextAlignment(.leading)
            // Never truncated (spec 2.5): a word wider than the column wraps.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The interactive tag (spec 3.3, 3.13.1, 3.18) for the topic picker and the reasons picker: a capsule
/// with the word in `ink`. Unselected, it has a 1 pt `controlRule` border and a `plus`; selected, an
/// `ink` fill, the word in `onFill` and a `checkmark`. The shape is the border, so Button Shapes adds
/// nothing; the hit area is at least 44 pt and VoiceOver hears the selected trait.
///
/// At AX5 the glyph sits 4 pt from the tag's start and 4 pt from the word (`Space.xs`), so the longest reasons,
/// "Constitutional" and "Sponsor/Party", stay whole in a 375 pt phone's column instead of breaking as
/// "Constitutiona / l" (project decision of 2026-10-29). The glyph is centred in the tag's straight middle; the word's
/// end keeps its 12 pt, where a wrapped tag's last line meets the rounded corner. With Bold Text on at AX5 the word is
/// also set at 93% (`TextRole.boldTextAX5Scale`), since Bold Text makes it about 6% wider. Below AX5 nothing changes:
/// with the 12 pt start and 6 pt after the glyph every reason word already fits that column at AX4, Bold Text or not.
///
/// At accessibility sizes a tag's corners are never rounder than a one-line tag's ends
/// (`shapeRadius(scaled:at:wordScale:)`), so a wrapped tag's last letter stays inside its shape.
struct SelectableTag: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    /// 34 pt at the default size, growing with the word (its hit area is at least 44 pt).
    static let height: CGFloat = 34

    @ScaledMetric(relativeTo: .subheadline) private var glyphSize: CGFloat = 12
    /// Scaled with the word, so a one-line tag is a capsule at every text size; capped at accessibility sizes by
    /// `shapeRadius(scaled:at:wordScale:)`.
    @ScaledMetric(relativeTo: .subheadline) private var scaledCornerRadius: CGFloat = SelectableTag.height / 2
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight

    /// The room after the word, at every size.
    static let trailingPadding: CGFloat = 12
    /// The room above and below the word.
    static let verticalPadding: CGFloat = 7

    /// The corner radius: `scaled` (17 pt, half the default height, scaled with the word) below the accessibility
    /// sizes, as before. At accessibility sizes it is at most a one-line tag's half height (the word's line plus 7 pt
    /// above and below), so a one-line tag is still a capsule and a wrapped tag's corners are as round as a one-line
    /// tag's ends. Scaled alone, 17 pt outgrows the tag, whose 7 pt do not grow: at AX5 it is about 50 pt on a 66 pt
    /// one-line tag, so on a two-line tag the corner cut through the end of the last line ("Taxes / Spending"'s "g").
    static func shapeRadius(scaled: CGFloat, at size: DynamicTypeSize, wordScale: CGFloat = 1) -> CGFloat {
        guard size.isAccessibilitySize else { return scaled }
        // The subheadline role's face (SF Pro, medium), as BillVoteBarModel measures the button role's line.
        let pointSize = TextRole.subheadline.scaledSize(for: size) * wordScale
        let line = UIFont.systemFont(ofSize: pointSize, weight: .medium).lineHeight
        // Rounded up, so a one-line tag's radius is never a hair under its half height: it stays a capsule.
        let oneLineHeight = max(height, (line + 2 * verticalPadding).rounded(.up))
        return min(scaled, oneLineHeight / 2)
    }

    /// The size from which the glyph's sides are 4 pt: AX5, the only size where a reason's word needs the room.
    static let compactGlyphSize: DynamicTypeSize = .accessibility5

    /// The room before the glyph: 12 pt, or 4 pt at AX5.
    static func leadingPadding(at size: DynamicTypeSize) -> CGFloat {
        size >= compactGlyphSize ? BillboardStyle.Space.xs : 12
    }

    /// The room between the glyph and the word: 6 pt, or 4 pt at AX5.
    static func glyphSpacing(at size: DynamicTypeSize) -> CGFloat {
        size >= compactGlyphSize ? BillboardStyle.Space.xs : 6
    }

    /// The word's size as a multiple of the subheadline role's: 93% at AX5 with Bold Text, else 1.
    private var wordScale: CGFloat {
        TextRole.boldTextAX5Scale(at: dynamicTypeSize, legibilityWeight: legibilityWeight)
    }

    var body: some View {
        let radius = Self.shapeRadius(scaled: scaledCornerRadius, at: dynamicTypeSize, wordScale: wordScale)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: action) {
            HStack(spacing: Self.glyphSpacing(at: dynamicTypeSize)) {
                Image(systemName: isSelected ? "checkmark" : "plus")
                    .font(TextRole.Face.text.font(size: glyphSize, weight: .bold))
                    .accessibilityHidden(true)
                Text(title)
                    .textRole(.subheadline, scale: wordScale)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? BillboardColors.onFill : BillboardColors.primaryText)
            .padding(.leading, Self.leadingPadding(at: dynamicTypeSize))
            .padding(.trailing, Self.trailingPadding)
            .padding(.vertical, Self.verticalPadding)
            .frame(minHeight: Self.height)
            .background {
                if isSelected {
                    shape.fill(BillboardColors.primaryText)
                } else {
                    shape.strokeBorder(BillboardColors.controlRule, lineWidth: 1)
                }
            }
            .contentShape(shape)
            .billboardMinimumHitTarget()
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(title)
        .accessibilityInputLabels([title])
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Tags") {
    VStack(alignment: .leading, spacing: 12) {
        FlowLayout(spacing: 6) {
            IndexTag(.inTheNews)
            IndexTag(.memberYouFollow)
            IndexTag(.topic("Healthcare"))
            IndexTag(.lifeArea("Housing"))
            IndexTag(.identicalBills)
        }
        HStack {
            SelectableTag(title: "Energy", isSelected: false) {}
            SelectableTag(title: "Housing", isSelected: true) {}
        }
    }
    .padding()
    .background(BillboardColors.cardBackground)
}
