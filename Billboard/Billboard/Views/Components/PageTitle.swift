import SwiftUI

/// A tab root's page title on paper, under the compact navy masthead (Civic Record spec 3.21): the title
/// in the `display` role (40 pt condensed heavy) in `ink`, a header, and an optional deck line under it
/// in the `docket` role (mono capitals) in `ink3`. Updates, Congress and Profile; Bills has the
/// masthead band instead. The title wraps at large sizes, never shrinks.
///
/// Spaced as frames 9, 12 and 15 look, not as their CSS reads: the mockup sets the title at
/// line-height 1 (18 pt above, 8 pt to the deck), while SwiftUI's line box adds the font's whole ascent
/// and descent around the capitals, which put the title 3 pt lower and the deck 5.5 pt further down.
/// 15 pt above and 2.5 pt to the deck put the capitals 24.3 pt under the navy and the deck's capitals
/// 15 pt under the title's baseline, as in the frames. 4 pt below.
///
/// It is inset 4 pt from the screen's gutter, as the mockup's `.pagetitle` is inside its 16 pt list
/// gutter, so the title starts at 20 pt, in line with the masthead rule and the dateline.
struct PageTitle: View {
    let title: String
    /// "Sat, Oct 17, 2026" (Updates), "119th Congress · House 435 · Senate 100" (Congress); nil for none.
    var deck: String? = nil
    /// What VoiceOver reads for the deck when its written form is abbreviated.
    var deckAccessibilityLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text(title)
                .textRole(.display)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let deck {
                Text(deck)
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(deckAccessibilityLabel ?? deck)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 15)
        .padding(.bottom, 4)
    }
}

/// The Congress page title's deck line (spec 3.21): "119th Congress · House 435 · Senate 100", the
/// counts are the members list's voting seats (`CongressTabModel.chamberCounts`: no delegates, so
/// "House 433" while two seats are vacant). Before the list has loaded it is the Congress alone.
enum CongressDeck {
    static func text(session: CongressCalendar.Session, houseCount: Int, senateCount: Int) -> String {
        guard houseCount > 0 || senateCount > 0 else { return session.congressTitle }
        return "\(session.congressTitle) · House \(houseCount) · Senate \(senateCount)"
    }

    /// "119th Congress. House, 435 members. Senate, 100 members."
    static func spokenText(session: CongressCalendar.Session, houseCount: Int, senateCount: Int) -> String {
        guard houseCount > 0 || senateCount > 0 else { return "\(session.congressTitle)." }
        return "\(session.congressTitle). House, \(members(houseCount)). Senate, \(members(senateCount))."
    }

    private static func members(_ count: Int) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }
}

#Preview("Page titles") {
    VStack(spacing: 0) {
        PageTitle(title: "Updates", deck: "Sat, Oct 17, 2026")
        PageTitle(title: "Congress", deck: "119th Congress · House 435 · Senate 100")
        PageTitle(title: "Profile")
    }
    .padding(.horizontal, 16)
    .background(BillboardColors.background)
}
