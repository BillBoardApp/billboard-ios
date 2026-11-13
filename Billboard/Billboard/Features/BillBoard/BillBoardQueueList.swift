import SwiftUI

/// The Bills list: a swipeable slip per pending bill (swipe left to skip, spec D 2.1.1), the
/// "Show one more week" row and a jump back to the top. Slips fade in, 50 ms apart, the first time the
/// list mounts (opacity only; none with Reduce Motion, Civic Record spec 4.18, 5.2). The first slip is
/// the tour's spotlight (`TutorialAnchor.billsFirstCard`). The sync capsule and Jump to top are
/// `GlassCapsule`s (spec 3.19).
struct BillBoardQueueList: View {
    let items: [BillBoardItem]
    let isSyncing: Bool
    /// Showing the last non-empty queue while a refresh runs.
    let isShowingStaleQueue: Bool
    let canExpandHistoryWindow: Bool
    let isExpandingHistoryWindow: Bool
    /// Appear-animation state, owned by `BillBoardTab` so it survives the queue emptying.
    @Binding var visibleCardIDs: Set<UUID>
    @Binding var hasAnimatedBoardCards: Bool
    let onOpen: (BillBoardItem) -> Void
    let onSwipeLeft: (BillBoardItem) -> Void
    let onExpandHistory: () -> Void
    let onJumpToTop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Self.slipSpacing) {
            if isSyncing {
                // Fades in and out (0.2 s, spec 5.2); the slips under it are not animated.
                BillBoardSyncCapsule(isShowingStaleQueue: isShowingStaleQueue)
                    .frame(maxWidth: .infinity)
                    .transition(AnyTransition.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // Large cold-start caches can contain hundreds of queue items.
            // Keep card mounting lazy so startup stays responsive.
            LazyVStack(alignment: .leading, spacing: Self.slipSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    billFeedCard(index: index, item: item)
                }

                JumpToTopButton(action: onJumpToTop)
                    .frame(maxWidth: .infinity)
            }
            .background(alignment: .top) { scrollAnchors }

            // Show one more week (one control; the inline duplicate was removed in R2).
            if canExpandHistoryWindow {
                BillBoardExpandHistoryCard(
                    isExpanding: isExpandingHistoryWindow,
                    action: onExpandHistory
                )
            }
        }
    }

    /// The space between slips (spec 4.18).
    static let slipSpacing = BillboardStyle.Space.m

    /// Scroll anchors, kept out of the spaced stack: there each zero-height anchor added a gap, which put
    /// the first slip 36 pt under the mono line (and the sync capsule) where frame 1 has 12. The tour's
    /// anchor sits the spotlight's padding above the first slip, so scrolling to it shows the whole
    /// spotlight under the bar; the bills section starts at the first slip. (The slip itself carries only
    /// the tour's frame capture, so the anchor's identity does not change when the first slip does.)
    private var scrollAnchors: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).id(TutorialAnchor.billsFirstCard.scrollID)
            Color.clear.frame(height: ProductTutorialOverlay.spotlightPadding)
            Color.clear.frame(height: 0).id("billsSection")
        }
        .alignmentGuide(.top) { _ in ProductTutorialOverlay.spotlightPadding }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func billFeedCard(index: Int, item: BillBoardItem) -> some View {
        let bill = item.bill
        SwipeableTile(
            accessibilityIdentifier: "home.queue.card.\(index)",
            onTap: { onOpen(item) },
            swipeLeftAccessibilityName: Self.swipeActionName,
            onSwipeLeft: { onSwipeLeft(item) }
        ) {
            BillCard(bill: bill)
                .opacity(visibleCardIDs.contains(item.id) ? 1 : 0)
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: reduceMotion
                            ? AnyTransition.opacity
                            : AnyTransition.move(edge: .leading).combined(with: .opacity)
                    )
                )
                .onAppear {
                    // Animate only on the first real mount of the board.
                    // Subsequent tab switches should feel instant.
                    guard !visibleCardIDs.contains(item.id) else { return }

                    if hasAnimatedBoardCards {
                        _ = visibleCardIDs.insert(item.id)
                        return
                    }

                    // A 0.2 s fade, 50 ms apart; with Reduce Motion the slips are simply there.
                    if reduceMotion {
                        _ = visibleCardIDs.insert(item.id)
                    } else {
                        withAnimation(Animation.easeOut(duration: 0.2).delay(Double(min(index, 8)) * 0.05)) {
                            _ = visibleCardIDs.insert(item.id)
                        }
                    }

                    if index == 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            hasAnimatedBoardCards = true
                        }
                    }
                }
        }
        // The tour's spotlight on the first card (spec D 2.5.5). An overlay, so the card's identity
        // stays the same when another card becomes first.
        .overlay {
            if index == 0 {
                Color.clear
                    .tutorialAnchor(.billsFirstCard)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The name of what swiping a card left does, for every card type: the reveal behind the card
    /// and the VoiceOver action. A skip is never a vote.
    static let swipeActionName = "Skip"
}

/// "Updating your bills…" (or "Refreshing your bills…" while the last list shows) over the Bills
/// list while it syncs (spec 3.19, 4.22): a spinner in ink and the words on the opaque sheet of a
/// `GlassCapsule`. No circular arrows.
struct BillBoardSyncCapsule: View {
    /// The last list shows while a refresh runs.
    let isShowingStaleQueue: Bool

    var title: String {
        isShowingStaleQueue ? "Refreshing your bills…" : "Updating your bills…"
    }

    var body: some View {
        GlassCapsule(size: .compact) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(BillboardColors.interactive)
                    .accessibilityHidden(true)
                Text(title)
                    .textRole(.caption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.queue.syncCapsule")
    }
}

/// Jump to top, at the end of the Bills list (spec 3.19): `arrow.up` and the words in `caption`
/// semibold ink on the opaque sheet of a `GlassCapsule`, 44 pt tall.
struct JumpToTopButton: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 12

    var body: some View {
        Button(action: action) {
            GlassCapsule(size: .compact) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up")
                        .font(TextRole.Face.text.font(size: glyphSize, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Jump to top")
                        .textRole(.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("Jump to top")
    }
}
