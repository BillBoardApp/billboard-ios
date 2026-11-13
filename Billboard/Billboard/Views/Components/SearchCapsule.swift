import SwiftUI

/// The search capsule (Civic Record spec 3.17): the Bills tab's "Search bills" row and Congress's inline
/// "Find a member" field. A capsule of `sheet` with a 1 pt `controlRule` edge, 48 pt tall at the default
/// size and taller as the text grows, with `magnifyingglass` in `ink3` before `content` (the placeholder in
/// `ink3`, or the field). `trailingPadding` makes room for a field's clear button.
struct SearchCapsule<Content: View>: View {
    /// The capsule's height at the default text size; it grows with the text.
    static var height: CGFloat { 48 }

    var trailingPadding: CGFloat = BillboardStyle.Space.l
    @ViewBuilder let content: Content

    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16

    init(trailingPadding: CGFloat = BillboardStyle.Space.l, @ViewBuilder content: () -> Content) {
        self.trailingPadding = trailingPadding
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(TextRole.Face.text.font(size: glyphSize, weight: .medium))
                .foregroundStyle(BillboardColors.dimText)
                .accessibilityHidden(true)
            content
        }
        .padding(.leading, BillboardStyle.Space.l)
        .padding(.trailing, trailingPadding)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .background(Capsule().fill(BillboardColors.cardBackground))
        .overlay(Capsule().strokeBorder(BillboardColors.controlRule, lineWidth: 1))
        .contentShape(Capsule())
    }
}
