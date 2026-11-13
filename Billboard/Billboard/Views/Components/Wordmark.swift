import SwiftUI

/// BILL/BOARD set in type (Civic Record spec 3.24), replacing R2's opaque navy banner image: "BILL"
/// in `textOnNavy` and "BOARD" in `brandTeal`, SF Pro Black condensed at +0.015 em, 30 pt on the Bills
/// masthead and 26 pt everywhere else, at a fixed size (the bar does not grow). Transparent, so it sits
/// on navy glass or opaque navy alike; it is only ever placed on navy, the one ground brand teal is
/// allowed on (7.20:1). VoiceOver reads "Billboard", a header.
struct Wordmark: View {
    enum Size {
        /// 30 pt: the Bills masthead.
        case masthead
        /// 26 pt: the other tab roots and the screens before the tabs.
        case compact

        var role: TextRole {
            switch self {
            case .masthead: return .wordmark
            case .compact: return .wordmarkCompact
            }
        }
    }

    var size: Size = .compact

    var body: some View {
        Text("\(Text("BILL").foregroundStyle(BillboardColors.textOnNavy))\(Text("BOARD").foregroundStyle(BillboardColors.brandTeal))")
            .textRole(size.role)
            .lineLimit(1)
            .fixedSize()
            // One element that says the name in words, not the capitals letter by letter.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Billboard")
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Wordmark") {
    VStack(spacing: 16) {
        Wordmark(size: .masthead)
        Wordmark(size: .compact)
    }
    .padding()
    .background(BillboardColors.navy)
}
