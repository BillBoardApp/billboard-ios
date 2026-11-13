import SwiftUI

/// The engraved monogram that stands in for a member or the user (Civic Record spec 3.14), replacing
/// R2's person-glyph placeholders: a `well` circle with a 1 pt `rule2` outer ring and a 0.75 pt `rule`
/// inner ring inset 3 pt, and the initials in condensed SF Pro semibold at 0.38 of the diameter, `ink`,
/// +0.03 em (initials are a label, so never New York). A photo, when there is one, replaces the
/// initials inside the outer ring, and Smart Invert leaves it as it is. A member's monogram can carry
/// the `PartyDisc` at its bottom-trailing edge on a ring of the ground colour.
///
/// Decoration: hidden from VoiceOver, whose row label carries the name and the party.
struct MemberMonogram: View {
    /// The six sizes (spec 3.14, and 4.68 for Settings), each scaled with Dynamic Type on the `.title3`
    /// curve.
    enum Size: CaseIterable {
        /// 26 pt: the bill slip's stub.
        case stub
        /// 34 pt: the Settings header (spec 4.68), the size of R2's avatar there.
        case settings
        /// 36 pt: follow rows.
        case row
        /// 44 pt: roll sheets and the sponsor.
        case roll
        /// 56 pt: the Profile header.
        case profile
        /// 72 pt: the member page.
        case page

        var diameter: CGFloat {
            switch self {
            case .stub: return 26
            case .settings: return 34
            case .row: return 36
            case .roll: return 44
            case .profile: return 56
            case .page: return 72
            }
        }

        /// The party disc's diameter at this size: 12, 14, 19, 20, 24 pt (14 at the Settings size, which
        /// shows the user and so never has one).
        var discDiameter: CGFloat {
            switch self {
            case .stub: return 12
            case .settings, .row: return 14
            case .roll: return 19
            case .profile: return 20
            case .page: return 24
            }
        }
    }

    static let initialsScale: CGFloat = 0.38
    static let initialsTrackingEm: CGFloat = 0.03
    /// How far the disc reaches past the monogram's edge, as a share of its own diameter, so it
    /// overlaps the ring by about a fifth of its width.
    static let discOverhang: CGFloat = 0.22

    let name: String
    var size: Size = .roll
    var party: PoliticalParty? = nil
    /// The member's photo, when it has loaded.
    var photo: Image? = nil
    /// The ground under the monogram, for the ring behind the party disc.
    var groundColor: Color = BillboardColors.cardBackground

    @ScaledMetric private var diameter: CGFloat

    /// The diameter scales with Dynamic Type on the `.title3` curve (spec 3.14). Every row that shows one
    /// stacks at accessibility sizes, so none needs R2's gentler `.largeTitle` avatar curve any more.
    init(
        name: String,
        size: Size = .roll,
        party: PoliticalParty? = nil,
        photo: Image? = nil,
        groundColor: Color = BillboardColors.cardBackground
    ) {
        self.name = name
        self.size = size
        self.party = party
        self.photo = photo
        self.groundColor = groundColor
        _diameter = ScaledMetric(wrappedValue: size.diameter, relativeTo: .title3)
    }

    var body: some View {
        let fontSize = diameter * Self.initialsScale
        ZStack {
            Circle().fill(BillboardColors.secondaryBackground)
            if let photo {
                photo
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    // Smart Invert leaves photos as they are (spec 7.8).
                    .accessibilityIgnoresInvertColors()
            } else {
                Circle()
                    .inset(by: 3)
                    .strokeBorder(BillboardColors.separator, lineWidth: 0.75)
                Text(Self.initials(for: name))
                    .font(TextRole.Face.condensed.font(size: fontSize, weight: .semibold))
                    .tracking(Self.initialsTrackingEm * fontSize)
                    .foregroundStyle(BillboardColors.primaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            Circle().strokeBorder(BillboardColors.rule2, lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottomTrailing) {
            if let party {
                let disc = size.discDiameter * diameter / size.diameter
                PartyDisc(party: party, diameter: disc, ringColor: groundColor)
                    .offset(x: disc * Self.discOverhang, y: disc * Self.discOverhang)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Initials

    /// Titles left out of initials ("Sen. Mark R. Warner" → MW).
    private static let titles: Set<String> = ["sen", "senator", "rep", "representative", "del", "delegate", "res", "comm", "dr", "mr", "mrs", "ms", "hon"]
    /// Suffixes left out of initials ("Jordan Ellis Jr." → JE).
    private static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]

    /// The first letters of the first and last name words, skipping titles, middle initials and
    /// suffixes: "Sen. Mark R. Warner" → "MW", "Kaine, Tim" → "TK", "Jordan Ellis Jr." → "JE". One word
    /// gives one letter ("reader42" → "R"); a name with no letters gives "".
    static func initials(for name: String) -> String {
        var working = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Kaine, Tim" (and "Kaine, Tim, Jr."): the part after the first comma comes first.
        let commaParts = working.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if commaParts.count >= 2 {
            let rest = commaParts.dropFirst().filter { !isSuffix($0) }
            working = (rest + [commaParts[0]]).joined(separator: " ")
        }

        let words = working
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "_" })
            .map(String.init)
            .filter { word in
                let bare = word.lowercased()
                return !titles.contains(bare) && !isSuffix(bare) && word.contains(where: \.isLetter)
            }
        guard let first = words.first, let firstLetter = first.first(where: \.isLetter) else { return "" }
        // A middle initial is never the last name; the last word that is more than a letter is.
        let lastWords = words.dropFirst().filter { $0.filter(\.isLetter).count > 1 }
        guard let last = lastWords.last, let lastLetter = last.first(where: \.isLetter) else {
            return String(firstLetter).uppercased()
        }
        return (String(firstLetter) + String(lastLetter)).uppercased()
    }

    private static func isSuffix(_ word: String) -> Bool {
        suffixes.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")))
    }
}

#Preview("Monograms") {
    HStack(spacing: 16) {
        MemberMonogram(name: "Jordan Ellis", size: .stub, party: .republican)
        MemberMonogram(name: "Bernie Sanders", size: .row, party: .independent)
        MemberMonogram(name: "Sen. Tim Kaine", size: .roll, party: .democratic)
        MemberMonogram(name: "reader42", size: .profile)
        MemberMonogram(name: "Sen. Mark R. Warner", size: .page, party: .democratic)
    }
    .padding()
    .background(BillboardColors.cardBackground)
}
