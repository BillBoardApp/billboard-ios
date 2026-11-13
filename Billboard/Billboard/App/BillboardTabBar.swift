import SwiftUI

/// The tab capsule at the bottom of `TabsBar` (Civic Record spec 3.22, 4.4): four tabs in a navy-tinted
/// Liquid Glass capsule, 64 pt tall, the same navy in light and dark appearance, 16 pt from the screen
/// sides.
///
/// - Glass: `.regular` tinted navy at 0.85 (`BillboardPalette.tabGlassTintOpacity`), not
///   `.interactive()`: the moving selection capsule is the feedback, and a press is 0.6 opacity
///   (`RowButtonStyle`) with no scale and no haptic. No shadow and no slab: content scrolls under it.
/// - Selected tab: an opaque navy capsule, 56 pt, with a brand-teal stroke inside its edge (1.5 pt, 2 pt
///   with Increase Contrast), the filled symbol and a Bold label in brand teal. Selection shows four ways
///   (stroke, weight, filled shape and hue), so it survives Reduce Transparency, where the capsule is
///   navy on navy, and a colour-blind or greyscale view. Differentiate Without Color adds a 2 pt teal
///   underline under the label. The capsule moves with `.smooth(duration: 0.25)`; with Reduce Motion it
///   cross-fades instead.
/// - Unselected tabs: the outline symbol and a Medium label in `textOnNavyDim` (white 74%; 85% with
///   Increase Contrast).
/// - Fallbacks, drawn here so render tests can draw them (spec 2.9): Reduce Transparency or
///   `FeatureFlags.glassChrome` off, a solid navy capsule; Increase Contrast, solid navy with a 1 pt
///   white 30% edge.
/// - Fixed sizes, like the system tab bar: the Large Content Viewer (touch and hold at the
///   accessibility text sizes) shows a tab's symbol and title instead.
///
/// The four ids (`tab.billboard`, `tab.updates`, `tab.congress`, `tab.profile`) are on the buttons.
/// The capsule itself carries no id or other accessibility modifier: on a container that is not an
/// accessibility element, one replaces the ids of the buttons inside (slice 0 spike).
struct BillboardTabBar: View {
    let selectedTab: TabsBar.Tab
    let homeBadgeCount: Int
    let updatesBadgeCount: Int
    let onSelect: (TabsBar.Tab) -> Void

    /// The capsule's height.
    static let height: CGFloat = 64
    /// The room between the capsule's edge and the selected tab's capsule.
    static let inset: CGFloat = 4
    /// The selected tab's capsule: the capsule's height less the inset on both sides.
    static var selectionHeight: CGFloat { height - 2 * inset }
    /// The tab symbols' point size (fixed).
    static let iconSize: CGFloat = 22
    /// The box each symbol is centred in: the symbols differ in size, and a fixed box keeps the labels on
    /// one baseline and the badges in one place.
    static let iconBox = CGSize(width: 30, height: 26)
    static let selectionStrokeWidth: CGFloat = 1.5
    static let selectionStrokeWidthHighContrast: CGFloat = 2
    /// The Differentiate Without Color underline under the selected label.
    static let underlineSize = CGSize(width: 14, height: 2)

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var treatment: GlassChrome.Treatment {
        GlassChrome.treatment(
            glassChrome: FeatureFlags.glassChrome,
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TabsBar.Tab.allCases, id: \.self) { tab in
                TabButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    badgeCount: badgeCount(for: tab),
                    badgeAccessibilityValue: badgeAccessibilityValue(for: tab),
                    highContrast: treatment == .solidHighContrast,
                    selection: reduceMotion ? nil : selection,
                    action: { onSelect(tab) }
                )
            }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .modifier(TabCapsuleGround(treatment: treatment))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.25), value: selectedTab)
    }

    private func badgeCount(for tab: TabsBar.Tab) -> Int {
        switch tab {
        case .home: return homeBadgeCount
        case .updates: return updatesBadgeCount
        case .congress, .profile: return 0
        }
    }

    private func badgeAccessibilityValue(for tab: TabsBar.Tab) -> String {
        switch tab {
        case .home: return TabBadgeAccessibility.billsValue(count: homeBadgeCount)
        case .updates: return TabBadgeAccessibility.updatesValue(count: updatesBadgeCount)
        case .congress, .profile: return ""
        }
    }
}

/// The capsule's ground under each treatment (spec 2.9): navy-tinted glass, solid navy, or solid navy
/// with a 1 pt white 30% edge.
private struct TabCapsuleGround: ViewModifier {
    let treatment: GlassChrome.Treatment

    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        switch treatment {
        case .glass:
            content
                .glassEffect(.regular.tint(BillboardColors.navy.opacity(BillboardPalette.tabGlassTintOpacity)), in: shape)
        case .solid:
            content
                .background(shape.fill(BillboardColors.navy))
        case .solidHighContrast:
            content
                .background(shape.fill(BillboardColors.navy))
                .overlay(shape.strokeBorder(BillboardColors.textOnNavy.opacity(0.3), lineWidth: 1).accessibilityHidden(true))
        }
    }
}

/// One tab of the capsule, with an optional count badge.
private struct TabButton: View {
    let tab: TabsBar.Tab
    let isSelected: Bool
    let badgeCount: Int
    /// "3 bills to vote on"; empty for no badge.
    let badgeAccessibilityValue: String
    let highContrast: Bool
    /// The namespace the selected capsule moves in; nil with Reduce Motion, where it cross-fades.
    let selection: Namespace.ID?
    let action: () -> Void

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var symbol: String {
        isSelected ? tab.selectedSystemImage : tab.systemImage
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(TextRole.Face.text.font(size: BillboardTabBar.iconSize, weight: .semibold))
                    .frame(width: BillboardTabBar.iconBox.width, height: BillboardTabBar.iconBox.height)
                    .overlay(alignment: .topLeading) {
                        // The badge starts 6 pt right of the symbol's middle, 4 pt above its box. The guides
                        // sit on the ZStack: conditional content drops an explicit alignment guide.
                        ZStack {
                            if badgeCount > 0 {
                                TabBadge(count: badgeCount)
                            }
                        }
                        .alignmentGuide(.leading) { _ in -(BillboardTabBar.iconBox.width / 2 + 6) }
                        .alignmentGuide(.top) { _ in 4 }
                    }
                    .accessibilityHidden(true)

                Text(tab.title)
                    .textRole(.tabLabel)
                    .fontWeight(isSelected ? .bold : .medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .overlay(alignment: .bottom) {
                        if isSelected, differentiateWithoutColor {
                            Capsule()
                                .fill(BillboardColors.brandTeal)
                                .frame(width: BillboardTabBar.underlineSize.width, height: BillboardTabBar.underlineSize.height)
                                .offset(y: BillboardTabBar.underlineSize.height + 1)
                                .accessibilityHidden(true)
                        }
                    }
            }
            // Brand teal is 7.20:1 on the navy capsule; white 74% is at least 6.68:1 on the glass.
            .foregroundStyle(isSelected ? BillboardColors.brandTeal : BillboardColors.textOnNavyDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    selectedCapsule
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(tab.title)
        .accessibilityValue(badgeAccessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
        .accessibilityShowsLargeContentViewer {
            Label(tab.title, systemImage: symbol)
        }
    }

    /// The opaque navy capsule behind the selected tab, stroked in brand teal inside its edge.
    @ViewBuilder
    private var selectedCapsule: some View {
        let capsule = Capsule(style: .continuous)
            .fill(BillboardColors.navy)
            .overlay(
                Capsule(style: .continuous).strokeBorder(
                    BillboardColors.brandTeal,
                    lineWidth: highContrast ? BillboardTabBar.selectionStrokeWidthHighContrast : BillboardTabBar.selectionStrokeWidth
                )
            )
            .accessibilityHidden(true)
        if let selection {
            capsule.matchedGeometryEffect(id: "tab.selection", in: selection)
        } else {
            capsule.transition(.opacity)
        }
    }
}

/// A tab's count: a white capsule with navy mono numerals, at least 18 pt tall and 19 pt wide, at the
/// symbol's top trailing corner. Hidden from VoiceOver; the tab's value says it.
private struct TabBadge: View {
    let count: Int

    var body: some View {
        Text(TabBadgeAccessibility.badgeText(count: count))
            .textRole(.badge)
            .foregroundStyle(BillboardColors.navy)
            .padding(.horizontal, 5)
            .frame(minWidth: 19, minHeight: 18)
            .background(Capsule(style: .continuous).fill(BillboardColors.textOnNavy))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// What VoiceOver reads as a tab's value for its badge count, and what the badge shows.
enum TabBadgeAccessibility {
    /// "1 bill to vote on", "3 bills to vote on"; empty for none.
    static func billsValue(count: Int) -> String {
        guard count > 0 else { return "" }
        return count == 1 ? "1 bill to vote on" : "\(count) bills to vote on"
    }

    /// "1 update", "3 updates"; empty for none.
    static func updatesValue(count: Int) -> String {
        guard count > 0 else { return "" }
        return count == 1 ? "1 update" : "\(count) updates"
    }

    /// The badge's numerals: the count, capped at "99+".
    static func badgeText(count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}
