import SwiftUI

/// A party marker: a circle in the party colour with the party letter (D, R, I) in `onFill`, in SF
/// Pro Text Bold (Civic Record spec 3.14; R2 used SF Pro Rounded). The letter carries the meaning, so
/// the colour is never the only cue; VoiceOver reads the party name ("Democrat"). Scales with Dynamic
/// Type.
///
/// Used standalone in directory filters, party rows and official-vote member lists. On a monogram the
/// same disc is `PartyDisc`, with a ring in the ground colour.
struct PartyBadge: View {
    enum Size: CaseIterable {
        /// For dense rows and inline text (18 pt at the default text size).
        case small
        /// For member headers and cards (24 pt at the default text size).
        case regular

        /// The diameter at the default text size.
        var baseDiameter: CGFloat {
            switch self {
            case .small: return 18
            case .regular: return 24
            }
        }
    }

    let party: PoliticalParty
    var size: Size = .regular

    @ScaledMetric(relativeTo: .caption2) private var smallDiameter: CGFloat = Size.small.baseDiameter
    @ScaledMetric(relativeTo: .footnote) private var regularDiameter: CGFloat = Size.regular.baseDiameter

    init(party: PoliticalParty, size: Size = .regular) {
        self.party = party
        self.size = size
    }

    /// Letter size as a share of the diameter.
    static let letterScale: CGFloat = PartyDisc.letterScale

    var body: some View {
        PartyDisc(party: party, diameter: size == .small ? smallDiameter : regularDiameter, ringColor: nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: party))
    }

    static func accessibilityLabel(for party: PoliticalParty) -> String {
        party.displayName
    }
}

/// The party disc (spec 3.14): the party colour with its letter in SF Pro Text Bold at 0.58 of the
/// diameter, in `onFill`. On a monogram it sits on a 2 pt ring in the ground colour, so it reads as
/// laid on top. Decoration on a monogram (which hides it from VoiceOver): the row's label says the
/// party, and every name next to a disc also has the party letter in text. This file and
/// `MemberMonogram` are the only places party colours are drawn.
struct PartyDisc: View {
    let party: PoliticalParty
    let diameter: CGFloat
    /// The ground behind the disc (the slip's sheet, the document); nil draws no ring.
    var ringColor: Color? = BillboardColors.cardBackground

    static let letterScale: CGFloat = 0.58
    static let ringWidth: CGFloat = 2

    var body: some View {
        Text(party.letter)
            .font(TextRole.Face.text.font(size: diameter * Self.letterScale, weight: .bold))
            .foregroundStyle(BillboardColors.onFill)
            .lineLimit(1)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(BillboardColors.party(party)))
            .background {
                if let ringColor {
                    Circle()
                        .fill(ringColor)
                        .padding(-Self.ringWidth)
                }
            }
            .fixedSize()
    }
}

#Preview("Party badges") {
    VStack(spacing: 12) {
        ForEach(PartyBadge.Size.allCases, id: \.self) { size in
            HStack(spacing: 8) {
                ForEach(PoliticalParty.allCases) { party in
                    PartyBadge(party: party, size: size)
                }
            }
        }
    }
    .padding()
    .background(BillboardColors.cardBackground)
}
