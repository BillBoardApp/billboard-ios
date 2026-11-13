import SwiftUI

/// A member in a list (the directory, "Find a member", the party and chamber pages): a `MemberRollRow`
/// with the 36 pt monogram, the name, the affiliation line led by the party letter ("D · SENATE · VA",
/// Civic Record spec 3.15) and the chevron; a member the user follows shows "Following" before it.
struct CongressMemberRow: View {
    private let data: DisplayData
    private let isSubscribed: Bool
    private let showsChevron: Bool
    private let insets: EdgeInsets

    struct DisplayData {
        let name: String
        let party: PoliticalParty?
        let affiliation: String?
        let spokenDescription: String
        let depictionImageUrl: URL?
    }

    init(member: CongressMember, isSubscribed: Bool = false, showsChevron: Bool = true, insets: EdgeInsets = RollRowInsets.standard) {
        let chamber = CongressMemberLabel.chamber(named: member.chamber)
        let state = member.stateCode ?? member.state
        data = DisplayData(
            name: member.name,
            party: member.party,
            affiliation: CongressMemberLabel.affiliation(party: member.party, state: state, district: member.district, chamber: chamber),
            spokenDescription: CongressMemberLabel.spokenDescription(
                name: member.name,
                party: member.party,
                state: state,
                district: member.district,
                chamber: chamber
            ),
            depictionImageUrl: member.imageUrl
        )
        self.isSubscribed = isSubscribed
        self.showsChevron = showsChevron
        self.insets = insets
    }

    init(manifest: CongressMemberManifestItem, isSubscribed: Bool = false, showsChevron: Bool = true, insets: EdgeInsets = RollRowInsets.standard) {
        let party = CongressMemberLabel.party(of: manifest)
        let chamber = CongressMemberLabel.chamber(of: manifest)
        data = DisplayData(
            name: manifest.name,
            party: party,
            affiliation: CongressMemberLabel.affiliation(party: party, state: manifest.state, district: manifest.district, chamber: chamber),
            spokenDescription: CongressMemberLabel.spokenDescription(
                name: manifest.name,
                party: party,
                state: manifest.state,
                district: manifest.district,
                chamber: chamber
            ),
            depictionImageUrl: manifest.depictionImageUrl
        )
        self.isSubscribed = isSubscribed
        self.showsChevron = showsChevron
        self.insets = insets
    }

    var body: some View {
        MemberRollRow(
            name: data.name,
            party: data.party,
            affiliation: data.affiliation,
            photoURL: data.depictionImageUrl,
            monogramSize: .row,
            trailing: showsChevron ? .chevron : .none,
            isFollowing: isSubscribed,
            insets: insets,
            accessibilityLabel: isSubscribed ? "\(data.spokenDescription), Following" : data.spokenDescription
        )
    }
}

/// One member on a roll sheet (Civic Record spec 3.14, 3.15): the monogram (the photo inside its ring
/// once it loads) with the party disc, then the name in the `name` role and the affiliation line in the
/// `docket` role (`ink3`) led by the party letter, so the party is never left to the small disc alone.
/// At the trailing edge: the chevron, a member's figure in `figureLarge` (`ink` above 0, `ink3` at 0)
/// for Your representatives, and "Following" (`caption` semibold, `ink2`) for a member the user follows.
///
/// At accessibility text sizes the row stacks: the monogram (and the chevron) on the first line, then
/// the name, the affiliation and the words that stood in the columns ("2 bills this week",
/// "Following") across the whole width, so a long name breaks between words, never inside one. The
/// monogram grows on the spec's `.title3` curve.
///
/// One VoiceOver element with the row's label, in the one spoken form (`CongressMemberLabel.spokenDescription`):
/// "Senator Tim Kaine, Democrat, Virginia, 2 bills this week"; the link around it adds the button trait.
struct MemberRollRow: View {
    enum Trailing: Equatable {
        /// Nothing at the trailing edge: the row's own button (Unfollow) stands beside it.
        case none
        case chevron
        /// Your representatives: the member's figure (nil while the bills load), then the chevron.
        case figure(Int?)
    }

    /// The name as shown: "Sen. Tim Kaine" in Your representatives, "Tim Kaine" elsewhere.
    let name: String
    /// The name the initials come from; `name` when nil.
    var monogramName: String? = nil
    let party: PoliticalParty?
    /// "D · Senate · VA" (`CongressMemberLabel.affiliation`).
    let affiliation: String?
    let photoURL: URL?
    var monogramSize: MemberMonogram.Size = .row
    var trailing: Trailing = .chevron
    var isFollowing = false
    /// The words for the figure column at accessibility sizes, where it goes under the name ("2 bills
    /// this week").
    var figureText: String? = nil
    var insets: EdgeInsets = RollRowInsets.standard
    /// The ground behind the party disc's ring: the sheet in a roll sheet, the document for the bill page's
    /// sponsor.
    var groundColor: Color = BillboardColors.cardBackground
    let accessibilityLabel: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The smallest width the figure column takes, so 0, 2 and 12 line up.
    static let figureMinimumWidth: CGFloat = 26

    /// Between the figure and the chevron: the row's gap plus 2, as frame 12 spaces them (`.rep` gap
    /// 12 px, `.chev` margin 2 px), so the loading dash and the chevron never read as an arrow.
    static let figureToChevron: CGFloat = RollRowInsets.gap + 2

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                sideBySide
            }
        }
        .padding(insets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var sideBySide: some View {
        HStack(alignment: .center, spacing: RollRowInsets.gap) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                nameText
                affiliationText
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isFollowing {
                followingText
            }
            switch trailing {
            case .none:
                EmptyView()
            case .chevron:
                RowChevron()
            case let .figure(count):
                HStack(alignment: .center, spacing: Self.figureToChevron) {
                    figure(count)
                    RowChevron()
                }
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            HStack(alignment: .center, spacing: RollRowInsets.gap) {
                avatar
                Spacer(minLength: 0)
                if trailing != .none {
                    RowChevron()
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                nameText
                affiliationText
                if case let .figure(count) = trailing, let figureText {
                    Text(figureText)
                        .textRole(.body)
                        .foregroundStyle((count ?? 0) > 0 ? BillboardColors.secondaryText : BillboardColors.dimText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isFollowing {
                    followingText
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var avatar: some View {
        CongressMemberAvatar(url: photoURL, name: monogramName ?? name, size: monogramSize, party: party, groundColor: groundColor)
    }

    private var nameText: some View {
        Text(name)
            .textRole(.name)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var affiliationText: some View {
        if let affiliation {
            Text(CongressMemberLabel.docketText(affiliation))
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var followingText: some View {
        Text("Following")
            .font(TextRole.Face.text.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .semibold))
            .foregroundStyle(BillboardColors.secondaryText)
            .fixedSize()
    }

    /// "2" in `ink`, "0" in `ink3`; a dash in `ink3` while the bills load (the row's label says
    /// "Updating…").
    private func figure(_ count: Int?) -> some View {
        Text(count.map(String.init) ?? "–")
            .textRole(.figureLarge)
            .foregroundStyle((count ?? 0) > 0 ? BillboardColors.primaryText : BillboardColors.dimText)
            .frame(minWidth: Self.figureMinimumWidth, alignment: .trailing)
            .fixedSize()
    }
}

/// A member's photo, or their monogram while it loads or when there is none (Civic Record spec 3.14):
/// a `MemberMonogram` of the member's initials, with the photo inside its ring once it arrives. Pass
/// the party for the party disc.
struct CongressMemberAvatar: View {
    let url: URL?
    let name: String
    var size: MemberMonogram.Size = .roll
    var party: PoliticalParty? = nil
    /// The ground behind the party disc's ring: the sheet in a roll sheet, the document on the member page.
    var groundColor: Color = BillboardColors.cardBackground

    var body: some View {
        if let url {
            AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                MemberMonogram(name: name, size: size, party: party, photo: phase.image, groundColor: groundColor)
            }
        } else {
            MemberMonogram(name: name, size: size, party: party, groundColor: groundColor)
        }
    }
}
