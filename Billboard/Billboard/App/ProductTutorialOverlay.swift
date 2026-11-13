import SwiftUI

/// The product tour's card and spotlight, drawn over the tabs by `ProductTutorialPresenter`.
struct ProductTutorialOverlay: View {
    let step: ProductTutorial.Step
    let stepIndex: Int
    let totalSteps: Int
    let highlightRects: [CGRect]
    /// The Bills list has a card to open (step 3 reads "Open this bill" rather than "Got it").
    let hasFirstCard: Bool
    /// The tab capsule's frame in window coordinates (`TutorialAnchor.tabBar`), when measured.
    var tabBarFrame: CGRect? = nil
    let onBack: () -> Void
    let onPrimary: () -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The measured heights of the card's scrolling text and its fixed footer (progress and
    /// buttons), so the card can be as tall as its content where the screen has room.
    @State private var textHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// Where the step's title ends in the card's scrolling text: the card keeps "Tour", Skip tour and the
    /// title in view above its footer, and only the step's text scrolls.
    @State private var titleBottom: CGFloat = 0

    private var presentation: ProductTutorial.Presentation {
        ProductTutorial.presentation(for: step, index: stepIndex, totalSteps: totalSteps, hasFirstCard: hasFirstCard)
    }

    /// How far the spotlight reaches past the slip on every side. On the 16 pt list gutter this leaves the
    /// spotlight `spotlightScreenMargin` from the screen's edges, so the padding is the same on all four
    /// sides and the corners stay concentric (12 pt was clamped to 8 at the sides).
    static let spotlightPadding: CGFloat = 8

    /// The least room the spotlight keeps from the screen's edges (and under the status bar).
    static let spotlightScreenMargin: CGFloat = 8

    /// The spotlight's corner radius, concentric with the slip it frames (Civic Record spec 4.17): the
    /// slip's 16 plus the padding.
    static var spotlightCornerRadius: CGFloat {
        BillboardStyle.Radius.slip + spotlightPadding
    }

    /// The spotlight's outline: 2 pt white (spec 4.17). No glow.
    static let spotlightOutlineWidth: CGFloat = 2

    private func spotlightRect(_ rect: CGRect, in proxy: GeometryProxy) -> CGRect {
        Self.spotlightRect(around: rect, size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
    }

    /// The spotlight around `rect`: `spotlightPadding` out on every side, cut to `spotlightScreenMargin`
    /// inside the screen's safe area. `size` and `safeAreaInsets` are the overlay's. A slip taller than the
    /// screen or partly below it is framed where it shows: moving the whole frame up to fit put the cut-out
    /// over what is above the slip (the starter banner and the list line at AX3). Null when no part of the
    /// slip is on screen.
    static func spotlightRect(around rect: CGRect, size: CGSize, safeAreaInsets: EdgeInsets) -> CGRect {
        let expandedRect = rect.insetBy(dx: -spotlightPadding, dy: -spotlightPadding)
        let margin = spotlightScreenMargin
        // `size` is the overlay's safe area (the screen less the insets); the frames are in the screen's space.
        let safeBounds = CGRect(
            x: margin,
            y: safeAreaInsets.top + margin,
            width: max(0, size.width - 2 * margin),
            height: max(0, size.height - 2 * margin)
        )

        guard !safeBounds.isEmpty else { return expandedRect }

        let shown = expandedRect.intersection(safeBounds)
        guard !shown.isNull, shown.height >= minimumSpotlightHeight, shown.width > 0 else { return .null }
        return shown
    }

    /// The least of a slip worth framing: its docket line.
    static let minimumSpotlightHeight: CGFloat = 44

    /// The space between the card and the spotlight.
    static let cardClearance: CGFloat = 18
    /// The card's least height before its content is measured, and its floor after.
    static let minimumCardHeight: CGFloat = 190

    /// Where the card goes and how tall it is, and the spotlights as drawn beside it.
    struct Layout: Equatable {
        var placeCardAtTop: Bool
        /// The card's top edge, in the overlay's (the screen's) coordinates.
        var cardTop: CGFloat
        var cardHeight: CGFloat
        var spotlights: [CGRect]
    }

    /// The card's place and height (spec 4.17, 4.9) beside `spotlights` (`spotlightRect`s):
    /// - As tall as its content (`textHeight + footerHeight`), at most 60% of `visibleHeight`, on the side of the
    ///   spotlight where it fits, else the side with more room.
    /// - Never shorter than its footer (progress and buttons) plus the scrolling text down to the step's title
    ///   (`footerHeight + titleBottom`), so "Tour", Skip tour and the title stay in view and only the step's
    ///   text scrolls. At AX3 and AX5 the footer alone is taller than the old 190 pt floor: the title and text
    ///   were laid out under the buttons and Skip tour was cut off at the card's top.
    /// - Never taller than the room between `topInset` and `bottomInset`.
    /// Where the card is taller than the room beside the spotlight (a slip taller than the screen at AX5), the
    /// card goes below and the spotlight gives way: it keeps `cardClearance` from the card and frames the part
    /// of the slip above it, its docket line and title; a spotlight that would be shorter than
    /// `minimumSpotlightHeight` is dropped.
    /// Before the content is measured (`footerHeight` or `textHeight` 0) the card is 40% of the screen,
    /// between 260 and 400 pt.
    static func layout(
        spotlights: [CGRect],
        screenHeight: CGFloat,
        visibleHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        textHeight: CGFloat,
        footerHeight: CGFloat,
        titleBottom: CGFloat
    ) -> Layout {
        let measured = textHeight > 0 && footerHeight > 0
        let floor = measured ? max(minimumCardHeight, footerHeight + min(titleBottom, textHeight)) : minimumCardHeight
        let preferred = measured
            ? min(textHeight + footerHeight, max(visibleHeight * 0.6, floor))
            : min(max(visibleHeight * 0.40, 260), 400)
        let room = max(0, screenHeight - bottomInset - topInset)
        let bounds = spotlights.reduce(into: CGRect.null) { $0 = $0.isNull ? $1 : $0.union($1) }
        guard !bounds.isNull else {
            let height = min(room, max(floor, preferred))
            return Layout(placeCardAtTop: false, cardTop: screenHeight - bottomInset - height, cardHeight: height, spotlights: [])
        }

        let topCapacity = max(0, bounds.minY - topInset - cardClearance)
        let bottomCapacity = max(0, (screenHeight - bottomInset) - bounds.maxY - cardClearance)
        // The side where the whole card fits, else the side with more room. Where neither side holds even
        // the card's floor (a slip taller than the screen), below: the spotlight then keeps the slip's top.
        let fitHeight = max(floor, preferred)
        let placeCardAtTop: Bool = {
            if bottomCapacity >= fitHeight { return false }
            if topCapacity >= fitHeight { return true }
            if topCapacity >= floor && bottomCapacity < floor { return true }
            if bottomCapacity >= floor && topCapacity < floor { return false }
            if topCapacity < floor && bottomCapacity < floor { return false }
            return topCapacity > bottomCapacity
        }()
        let capacity = placeCardAtTop ? topCapacity : bottomCapacity
        let cardHeight = min(room, min(preferred, max(floor, capacity)))
        let cardTop = placeCardAtTop ? topInset : screenHeight - bottomInset - cardHeight

        let shown: [CGRect] = spotlights.compactMap { spotlight in
            var rect = spotlight
            if placeCardAtTop {
                let top = cardTop + cardHeight + cardClearance
                if rect.minY < top { rect = CGRect(x: rect.minX, y: top, width: rect.width, height: rect.maxY - top) }
            } else {
                let bottom = cardTop - cardClearance
                if rect.maxY > bottom { rect.size.height = bottom - rect.minY }
            }
            return rect.height >= minimumSpotlightHeight ? rect : nil
        }
        return Layout(placeCardAtTop: placeCardAtTop, cardTop: cardTop, cardHeight: cardHeight, spotlights: shown)
    }

    /// How far above the screen's bottom edge the card ends when it sits low (Civic Record spec 4.9): 10 pt
    /// above the tab capsule's measured top, or, before the capsule is measured, 98 pt (a 64 pt capsule
    /// 24 pt above the edge, plus 10). The capsule's frame is in window coordinates; `overlayTop` is where
    /// the overlay's top (the top of the screen) is in them, 0 when the window fills the screen.
    static func bottomInset(tabBarFrame: CGRect?, overlayTop: CGFloat = 0, screenHeight: CGFloat) -> CGFloat {
        guard let frame = tabBarFrame, !frame.isNull, !frame.isEmpty else {
            return TabCapsuleLayout.fallbackTourBottomInset
        }
        let top = frame.minY - overlayTop
        guard top > 0, top < screenHeight else { return TabCapsuleLayout.fallbackTourBottomInset }
        return screenHeight - top + TabCapsuleLayout.toastGap
    }

    var body: some View {
        GeometryReader { proxy in
            // The overlay covers the whole screen, from its top; the spotlight frames are in that space.
            let screenHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let topInset = proxy.safeAreaInsets.top + 12
            let bottomInset = Self.bottomInset(
                tabBarFrame: tabBarFrame,
                overlayTop: proxy.frame(in: .global).minY - proxy.safeAreaInsets.top,
                screenHeight: screenHeight
            )
            // As tall as the step's text and buttons (measured), at most 60% of the screen; where the room
            // beside the spotlight is smaller, the text scrolls inside the card and its scroll bar flashes.
            let layout = Self.layout(
                spotlights: highlightRects.map { spotlightRect($0, in: proxy) }.filter { !$0.isNull },
                screenHeight: screenHeight,
                visibleHeight: proxy.size.height,
                topInset: topInset,
                bottomInset: bottomInset,
                textHeight: textHeight,
                footerHeight: footerHeight,
                titleBottom: titleBottom
            )
            let spotlightRects = layout.spotlights
            let placeCardAtTop = layout.placeCardAtTop
            let cardHeight = layout.cardHeight
            // The swipe hint stays above this: the card's top when the card sits low, else the capsule's.
            let hintFloor = placeCardAtTop ? screenHeight - bottomInset : layout.cardTop

            ZStack {
                // Scrim with the spotlight cut out. The scrim takes taps, so the list underneath
                // cannot be used while the tour runs.
                ZStack {
                    Color.black.opacity(0.62)

                    ForEach(Array(spotlightRects.enumerated()), id: \.offset) { _, spotlight in
                        RoundedRectangle(cornerRadius: Self.spotlightCornerRadius, style: .continuous)
                            .frame(width: spotlight.width, height: spotlight.height)
                            .position(x: spotlight.midX, y: spotlight.midY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                .ignoresSafeArea()
                .accessibilityHidden(true)

                ZStack {
                    ForEach(Array(spotlightRects.enumerated()), id: \.offset) { _, spotlight in
                        TutorialSpotlightOutline()
                            .frame(width: spotlight.width, height: spotlight.height)
                            .position(x: spotlight.midX, y: spotlight.midY)
                            .allowsHitTesting(false)
                    }

                    if step.showsSwipeHint, let spotlight = spotlightRects.first {
                        TutorialSwipeHintLayout(spotlight: spotlight, floor: hintFloor) {
                            TutorialSwipeHint(reduceMotion: reduceMotion)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)

                // The tour card (Civic Record spec 4.17): a sheet with a 1 pt rule and the slip's radius, and no
                // shadow; the scrim separates it.
                card
                    .frame(height: cardHeight)
                    .background(BillboardColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
                            .strokeBorder(BillboardColors.separator, lineWidth: 1)
                    )
                    .frame(maxHeight: .infinity, alignment: placeCardAtTop ? .top : .bottom)
                    .padding(.horizontal, BillboardStyle.Space.l)
                    .padding(.top, placeCardAtTop ? topInset : 0)
                    .padding(.bottom, placeCardAtTop ? 0 : bottomInset)
            }
            .ignoresSafeArea()
        }
    }

    /// The step's text and buttons (spec 4.17): "Tour" in the docket face with "Skip tour" beside it, the step's
    /// title in the `name` role and its text in `body` `ink2`, then the progress as three 6 pt square
    /// segments (`controlOn` done, `well` to do) with "1 of 3", and Back (secondary) and Next, Open this bill
    /// or Got it (primary). No step symbols: the title carries the step. VoiceOver stays inside the card
    /// while the tour runs.
    private var card: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                    HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
                        Text(ProductTutorial.headerTitle)
                            .textRole(.docket)
                            .foregroundStyle(BillboardColors.dimText)
                            .accessibilityHidden(true)

                        Spacer(minLength: 0)

                        Button(ProductTutorial.skipTitle) {
                            onSkip()
                        }
                        .buttonStyle(BillboardButtonStyle(kind: .textButton))
                        .accessibilityIdentifier("tour.skip")
                    }

                    VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                        Text(presentation.title)
                            .textRole(.name)
                            .foregroundStyle(BillboardColors.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.frame(in: .named(Self.cardTextSpace)).maxY
                            } action: { titleBottom = $0 + BillboardStyle.Space.m }

                        Text(presentation.summary)
                            .textRole(.body)
                            .foregroundStyle(BillboardColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, BillboardStyle.Space.xl)
                .padding(.top, BillboardStyle.Space.m)
                .padding(.bottom, BillboardStyle.Space.m)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                .coordinateSpace(name: Self.cardTextSpace)
            }
            // A card shorter than its text scrolls; flash the bar so that is visible.
            .scrollIndicatorsFlash(trigger: stepIndex)
            .scrollIndicatorsFlash(onAppear: true)

            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                HStack(alignment: .center, spacing: BillboardStyle.Space.m) {
                    TourProgressSegments(stepIndex: stepIndex, totalSteps: totalSteps)
                    Text(presentation.progressFigure)
                        .textRole(.docket)
                        .foregroundStyle(BillboardColors.dimText)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.progressLabel)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BillboardStyle.Space.m) {
                        backButton
                        Spacer(minLength: 0)
                        primaryButton(fullWidth: false)
                    }
                    VStack(spacing: BillboardStyle.Space.s) {
                        primaryButton(fullWidth: true)
                        backButton
                    }
                }
            }
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.top, BillboardStyle.Space.m)
            .padding(.bottom, BillboardStyle.Space.xl)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("tour.card")
    }

    /// The card's scrolling text, for where the title ends in it.
    private static let cardTextSpace = "tour.card.text"

    /// Back is the secondary capsule at its own 44 pt (spec 3.16), centred beside the 50 pt primary: stretched
    /// to 50 pt, its 22 pt corners would be flatter than a capsule's, unlike Next beside it.
    @ViewBuilder
    private var backButton: some View {
        if let backTitle = presentation.backTitle {
            Button(backTitle) { onBack() }
                .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: false))
                .accessibilityIdentifier("tour.back")
        }
    }

    private func primaryButton(fullWidth: Bool) -> some View {
        Button(presentation.primaryTitle) { onPrimary() }
            .buttonStyle(BillboardButtonStyle(kind: .primary, fullWidth: fullWidth))
            .accessibilityIdentifier("tour.primary")
    }
}

/// The tour's progress (spec 4.17): one 6 pt square-ended segment per step, `controlOn` for the steps reached
/// and `well` for those to come. Decoration; the figure beside it is read as "Step 1 of 3".
private struct TourProgressSegments: View {
    let stepIndex: Int
    let totalSteps: Int

    static let height: CGFloat = 6
    static let segmentWidth: CGFloat = 28
    static let gap: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<max(totalSteps, 0), id: \.self) { index in
                Rectangle()
                    .fill(index <= stepIndex ? BillboardColors.controlOn : BillboardColors.secondaryBackground)
                    .frame(width: Self.segmentWidth, height: Self.height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The spotlight's outline (Civic Record spec 4.17): a 2 pt white rule on the cut-out's edge, its corners
/// concentric with the slip. No glow: the scrim already sets the slip apart.
struct TutorialSpotlightOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: ProductTutorialOverlay.spotlightCornerRadius, style: .continuous)
            .stroke(BillboardColors.textOnNavy, lineWidth: ProductTutorialOverlay.spotlightOutlineWidth)
    }
}

/// The tour's swipe hint under the spotlighted slip (Civic Record spec 4.17, 3.19): `arrow.left` and
/// "Swipe left to skip" in `caption` ink on the opaque sheet of a `GlassCapsule`, nudging 12 pt left and
/// back every 1.2 s; still with Reduce Motion. Decoration: the step's text says the same.
/// `TutorialSwipeHintLayout` places it.
struct TutorialSwipeHint: View {
    let reduceMotion: Bool

    /// How far the hint nudges left.
    static let nudge: CGFloat = 12
    /// One nudge, out and back.
    static let period: TimeInterval = 1.2

    @State private var isNudged = false
    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 13

    var body: some View {
        GlassCapsule(size: .compact) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.left")
                    .font(TextRole.Face.text.font(size: glyphSize, weight: .semibold))
                Text("Swipe left to skip")
                    .textRole(.caption)
            }
        }
        .fixedSize()
        .offset(x: reduceMotion || !isNudged ? 0 : -Self.nudge)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: Self.period / 2).repeatForever(autoreverses: true)) {
                isNudged = true
            }
        }
    }
}

/// Places the tour's swipe hint where it hides none of the spotlighted slip's title (Civic Record spec
/// 4.17): centred under the slip, `gap` below the spotlight; or, where the tour card leaves no room there
/// (the accessibility sizes, a short screen), `gap` above the card, over the foot of the slip (its stub),
/// and never higher than the spotlight's top. Centred on the slip, the hint's words covered the end of
/// the title at the default size and its whole second line at AX3.
struct TutorialSwipeHintLayout: Layout {
    /// The spotlight, in the overlay's (the screen's) coordinates.
    let spotlight: CGRect
    /// The lowest the hint may reach: the tour card's top when the card sits below the spotlight, else the
    /// top of the room above the tab capsule.
    let floor: CGFloat

    /// The space between the hint and the spotlight, or the card.
    static let gap: CGFloat = 12

    /// The hint's top edge for a hint `hintHeight` tall.
    static func hintTop(spotlight: CGRect, hintHeight: CGFloat, floor: CGFloat) -> CGFloat {
        let underSpotlight = spotlight.maxY + gap
        let overFloor = floor - gap - hintHeight
        return max(spotlight.minY, min(underSpotlight, overFloor))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let top = Self.hintTop(spotlight: spotlight, hintHeight: size.height, floor: floor)
            subview.place(
                at: CGPoint(x: bounds.minX + spotlight.midX, y: bounds.minY + top),
                anchor: .top,
                proposal: ProposedViewSize(size)
            )
        }
    }
}
