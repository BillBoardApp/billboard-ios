import SwiftUI

/// Shown in place of the Bills list while the first sync runs and nothing is cached (Civic Record spec
/// 4.22, 3.20): a spinner in ink and R2's two lines. No skeletons, no shimmer.
struct BillBoardQueueSyncPlaceholder: View {
    var body: some View {
        VStack(spacing: BillboardStyle.Space.m) {
            ProgressView()
                .tint(BillboardColors.interactive)

            VStack(spacing: BillboardStyle.Space.xs) {
                Text("Updating your bills…")
                    .textRole(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(BillboardColors.primaryText)

                Text("Getting the latest bills.")
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            // The two lines read as one, so the smoke UI tests find the placeholder by its id.
            .accessibilityIdentifier("home.queue.syncing")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BillboardStyle.Space.xxxl)
    }
}

/// Shown in place of the Bills list when loading failed and nothing is cached (spec 4.22): a record
/// notice stamped COULDN'T LOAD, R2's message, and Retry as the primary action. No gold triangle.
struct BillBoardLoadErrorState: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            RecordNotice(.couldNotLoad, title: "Couldn't load your bills", message: message)

            Button(action: onRetry) {
                HStack(spacing: BillboardStyle.Space.s) {
                    if isRetrying {
                        ProgressView()
                            .tint(BillboardColors.onFill)
                    }
                    Text("Retry")
                }
            }
            .buttonStyle(BillboardButtonStyle(kind: .primary, fullWidth: false, drawsAsEnabled: isRetrying))
            .disabled(isRetrying)
            .accessibilityIdentifier("home.queue.retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A container of its own, so the id names the notice without replacing Retry's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.queue.loadError")
    }
}

/// Shown when the Bills list has nothing left to vote on in the selected window (spec 4.22): a record
/// notice stamped ALL CAUGHT UP in ink. No teal check.
struct BillBoardCaughtUpState: View {
    /// The window's title, lower case ("1 week").
    let windowTitle: String
    /// Whether pulling down can add another week (the window stops at a year).
    var canExpand: Bool = true

    /// "No bills left to vote on from the last 1 week. Pull down to add one more week, up to a year."
    var message: String {
        let left = "No bills left to vote on from the last \(windowTitle)."
        return canExpand ? "\(left) Pull down to add one more week, up to a year." : left
    }

    var body: some View {
        RecordNotice(.allCaughtUp, title: "You're all caught up", message: message)
            // The notice reads as one element with the stamp's word, so the smoke UI tests find it by id
            // (no element is labelled with the title alone). It holds no control whose id this could replace.
            .accessibilityIdentifier("home.queue.caughtUp")
    }
}

/// Adds one more week to the Bills list (spec 4.22): a plain row between two hairlines, "Show one more
/// week" in the `name` role, "Older bills you haven't voted on" under it in `ink3`, and a chevron (a
/// spinner while the week loads). No clock, no card.
struct BillBoardExpandHistoryCard: View {
    let isExpanding: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HairlineRule()
                HStack(spacing: BillboardStyle.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show one more week")
                            .textRole(.name)
                            .foregroundStyle(BillboardColors.primaryText)
                        Text("Older bills you haven't voted on")
                            .textRole(.caption)
                            .foregroundStyle(BillboardColors.dimText)
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isExpanding {
                        ProgressView()
                            .tint(BillboardColors.interactive)
                    } else {
                        RowChevron()
                    }
                }
                .padding(.vertical, BillboardStyle.Space.m)
                .frame(minHeight: 44)
                HairlineRule()
            }
            // Never shorter than its words: a flexible `minHeight` frame would let a stack squeeze it.
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier("home.queue.expandHistory")
        .accessibilityLabel("Show one more week")
        .accessibilityHint("Older bills you haven't voted on")
        .disabled(isExpanding)
    }
}

/// Above the starter feed (spec D 2.5.4; Civic Record spec 4.21), for a profile that follows no topics
/// or life areas: a paragraph on paper, not a card, with a hairline under it. "New this week." is a
/// condensed heading (it labels the list, so not New York), the line under it is `body` `ink2`, and
/// "Choose topics" is a secondary capsule that opens the topic picker. The close button (`xmark` in
/// `ink3`, a 44 pt target, "Hide for a week") hides the banner for 7 days.
struct StarterFeedBanner: View {
    let onChooseTopics: () -> Void
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var closeIconSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var tagGlyphSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: BillboardStyle.Space.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New this week.")
                        .textRole(.heading)
                        .foregroundStyle(BillboardColors.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("Follow topics to tailor your bills.")
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BillboardStyle.Space.xs)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(TextRole.Face.text.font(size: closeIconSize, weight: .semibold))
                        .foregroundStyle(BillboardColors.dimText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .padding(.trailing, -10)
                .accessibilityLabel("Hide for a week")
                .accessibilityInputLabels(["Hide for a week", "Close"])
                .accessibilityIdentifier("home.starterBanner.close")
            }

            Button(action: onChooseTopics) {
                HStack(spacing: 7) {
                    Image(systemName: "tag")
                        .font(TextRole.Face.text.font(size: tagGlyphSize, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Choose topics")
                }
            }
            .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: false))
            .accessibilityIdentifier("home.starterBanner.chooseTopics")
            .padding(.top, 10)
            .padding(.bottom, 14)

            HairlineRule()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Never shorter than its words and buttons, whatever height a stack offers.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.starterBanner")
    }
}
