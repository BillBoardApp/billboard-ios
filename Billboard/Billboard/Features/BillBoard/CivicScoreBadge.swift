import SwiftUI

/// Leading masthead chip: the Civic Score, a white star and the number (Civic Record spec 3.23); a dash
/// until the score has loaded, not a false 0 (UX-39 N11). Opens the Civic Rank sheet.
struct CivicScoreLeadingBadge: View {
    @EnvironmentObject private var civicScoreStore: CivicScoreStore
    let action: () -> Void

    var body: some View {
        let score = civicScoreStore.phase == .loaded ? civicScoreStore.score.civicScore : nil
        HeaderMetricBadge(
            value: HeaderMetricCopy.value(score),
            accessibilityLabel: HeaderMetricCopy.scoreLabel(score),
            largeContentIcon: Image(systemName: "star.fill"),
            action: action
        ) {
            Image(systemName: "star.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
        }
    }
}

/// Trailing masthead chip: the voting streak, tally marks and the number (spec 3.23; R2's flame is
/// gone). Always visible, including a zero streak; a dash until the score has loaded (UX-39 N11). Opens
/// the Civic Rank sheet.
struct StreakTrailingBadge: View {
    @EnvironmentObject private var civicScoreStore: CivicScoreStore
    let action: () -> Void

    /// The tally marks as a picture for the Large Content Viewer, drawn once.
    static let largeContentImage = TallyMarksGlyph.largeContentImage()
    private static let largeContentIcon = Image(uiImage: largeContentImage)

    var body: some View {
        let streak = civicScoreStore.phase == .loaded ? civicScoreStore.score.currentStreak : nil
        HeaderMetricBadge(
            value: HeaderMetricCopy.value(streak),
            accessibilityLabel: HeaderMetricCopy.streakLabel(streak),
            largeContentIcon: Self.largeContentIcon,
            action: action
        ) {
            TallyMarksGlyph()
        }
    }
}

/// The chips' figures and VoiceOver labels (spec 3.23): "Civic Score 48", "4-day streak". Before the score
/// has loaded (nil), a dash and "Civic Score, not loaded" (UX-39 N11).
enum HeaderMetricCopy {
    static let notLoadedValue = "–"

    static func value(_ figure: Int?) -> String {
        figure.map { "\($0)" } ?? notLoadedValue
    }

    static func scoreLabel(_ score: Int?) -> String {
        score.map { "Civic Score \($0)" } ?? "Civic Score, not loaded"
    }

    static func streakLabel(_ streak: Int?) -> String {
        streak.map { "\($0)-day streak" } ?? "Day streak, not loaded"
    }
}

/// Navigation-bar chip: a white glyph and the number in the docket face at 14 pt semibold, on the
/// navy bar (spec 3.23). Like system bar buttons it keeps a fixed size and offers the Large
/// Content Viewer at accessibility text sizes instead of growing inside the bar. The viewer shows
/// `largeContentIcon`: it needs an `Image`, and a drawn glyph such as the tally marks gives it none.
private struct HeaderMetricBadge<Glyph: View>: View {
    let value: String
    let accessibilityLabel: String
    let largeContentIcon: Image
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                glyph()
                    .accessibilityHidden(true)

                Text(value)
                    // Fixed in the bar like the tab labels (spec 3.23, 7.2); the Large Content Viewer
                    // shows it larger.
                    .font(TextRole.docket.font(size: 14).weight(.semibold)) // ui-rules:allow raw-font-size
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // White on the navy bar in both appearances, not teal or gold (teal means only Yea).
            .foregroundStyle(BillboardColors.textOnNavy)
            .padding(.horizontal, 4)
            .frame(height: 30)
            // A plain button is only tappable on its glyphs; make the whole chip and a 44 pt
            // square around it tappable without changing its size in the bar.
            .billboardMinimumHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows your civic rank details")
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(accessibilityLabel)
            } icon: {
                largeContentIcon
            }
        }
    }
}
