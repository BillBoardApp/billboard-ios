import SwiftUI

/// One profile on the theme bars, told apart by line style rather than hue (Civic Record spec 3.27).
struct ThemeChartDataset {
    enum Style: Equatable {
        /// `ink` at 8% inside a 1 pt `ink` edge: your own profile, or the member on a member page.
        case solid
        /// A 1.5 pt `ink2` dashed outline (4 on, 3 off), nothing inside: "You" beside a member.
        case dashed
    }

    let profile: CivicProfileResponse
    let label: String
    var style: Style = .solid
}

/// The bars' words (UX-40 L4, approved copy D31): "theme", "votes" and, for a member, "votes and bills"; never
/// "axis", "lean" or "signal" (glossary 2.4.1).
enum ThemeBarsCopy {
    /// A theme without a score yet (spec D 2.4.2).
    static let notEnoughData = "Not enough data"

    /// The score beside a theme's bar: "You: 7/10", "Member: 7/10"; "Not enough data" for a theme without one.
    static func scoreText(subjectLabel: String, score: Int?) -> String {
        guard let score else { return notEnoughData }
        return "\(subjectLabel): \(score)/10"
    }

    /// Under your bar: "12 votes", "1 vote".
    static func votes(_ count: Int) -> String {
        count == 1 ? "1 vote" : "\(count) votes"
    }

    /// Under a member's bar: "9 votes and bills", "1 vote or bill".
    static func votesAndBills(_ count: Int) -> String {
        count == 1 ? "1 vote or bill" : "\(count) votes and bills"
    }

    /// The count line for a profile: votes for you, votes and bills for a member.
    static func count(_ count: Int, isMember: Bool) -> String {
        isMember ? votesAndBills(count) : votes(count)
    }

    /// What a theme without a score still has: "5 of 8 votes" (yours, when the server sends the count and the
    /// floor, and the count is under it); nil for a member, whose line is "Not enough data" alone.
    static func shortfall(count: Int?, floor: Int?, isMember: Bool) -> String? {
        guard !isMember, let count, let floor, count < floor else { return nil }
        return "\(count) of \(floor) vote\(floor == 1 ? "" : "s")"
    }

    /// The line under a theme without a score: "Not enough data · 5 of 8 votes", or "Not enough data".
    static func notEnoughDataLine(shortfall: String?) -> String {
        guard let shortfall else { return notEnoughData }
        return "\(notEnoughData) · \(shortfall)"
    }

    /// Which way a score is from the middle, for VoiceOver only (D29): "toward Community", "toward Individual", or
    /// "in the middle" for exactly halfway (0.5). Taken from the value, as the bar is drawn, so a 5 (0.389 up to
    /// 0.5) is toward the left-hand word and a 6 toward the right-hand one.
    static func direction(_ axis: CivicProfileAxis, value: Double) -> String {
        if abs(value - 0.5) < 0.000_001 { return "in the middle" }
        return value > 0.5 ? "toward \(axis.highLabel)" : "toward \(axis.lowLabel)"
    }

    /// The theme as VoiceOver opens its element: "Individual to Community."
    static func spokenTheme(_ axis: CivicProfileAxis) -> String {
        "\(axis.lowLabel) to \(axis.highLabel)."
    }

    /// One profile's part of a theme's element: "You: 7/10, toward Community." or "You: not enough data."
    static func spokenScore(_ axis: CivicProfileAxis, subjectLabel: String, value: Double?, score: Int?) -> String {
        guard let value, let score else { return "\(subjectLabel): \(notEnoughData.lowercased())." }
        return "\(scoreText(subjectLabel: subjectLabel, score: score)), \(direction(axis, value: value))."
    }

    /// A theme on one profile, one VoiceOver element: "Individual to Community. You: 7/10, toward Community. 12
    /// votes." Without a score: "Individual to Community. Not enough data. 5 of 8 votes."
    static func spokenSingle(_ axis: CivicProfileAxis, dataset: ThemeChartDataset, count: String?, shortfall: String?) -> String {
        let theme = spokenTheme(axis)
        let value = dataset.profile.signalValue(for: axis)
        let score = dataset.profile.displayScoreIfAvailable(for: axis)
        guard value != nil, score != nil else {
            guard let shortfall else { return "\(theme) \(notEnoughData)." }
            return "\(theme) \(notEnoughData). \(shortfall)."
        }
        let scoreLine = spokenScore(axis, subjectLabel: dataset.label, value: value, score: score)
        guard let count else { return "\(theme) \(scoreLine)" }
        return "\(theme) \(scoreLine) \(count)."
    }

    /// A theme in Compare to you, one VoiceOver element: "Individual to Community. Jordan Ellis: 7/10, toward
    /// Community. You: 4/10, toward Individual."
    static func spokenCompare(_ axis: CivicProfileAxis, datasets: [ThemeChartDataset]) -> String {
        let parts = datasets.map { dataset in
            spokenScore(
                axis,
                subjectLabel: dataset.label,
                value: dataset.profile.signalValue(for: axis),
                score: dataset.profile.displayScoreIfAvailable(for: axis)
            )
        }
        return ([spokenTheme(axis)] + parts).joined(separator: " ")
    }

    /// Under a theme in Compare to you when one profile has no score there, so a missing bar is not read as the
    /// middle: "You: Not enough data".
    static func missingInCompare(subjectLabel: String) -> String {
        "\(subjectLabel): \(notEnoughData)"
    }

    /// The legend's sample as VoiceOver reads it: "Jordan Ellis, solid bar", "You, dashed bar".
    static func spokenLegendSample(_ dataset: ThemeChartDataset) -> String {
        dataset.style == .solid ? "\(dataset.label), solid bar" : "\(dataset.label), dashed bar"
    }
}

/// The Civic Profile's themes as six diverging bars (UX-40 L4; Civic Record spec 3.27). Each theme is one row in the
/// rubric's fixed order, never sorted by score: its left-hand word (a score of 1) and right-hand word (10) in the
/// `caption` role (`ink2`), a track from one end to the other with a tick at the middle (halfway, neither end), and a
/// bar from the middle toward the profile's value, in ink on both sides (no vote, party or other hues). One profile
/// shows its score and count under the bar ("You: 7/10 · 31 votes"); a theme without a score has a dashed track and
/// "Not enough data · 5 of 8 votes". Two profiles (Compare to you) draw two thin bars per theme, the first solid and
/// the second a dashed outline, and leave the scores to the table under the chart.
///
/// At accessibility sizes the end words stack over the track (left-hand word first, right-hand word under it at
/// the trailing edge) and nothing shrinks. VoiceOver reads one element per theme with the direction in words.
struct ThemeBarsView: View {
    let axes: [CivicProfileAxis]
    private let datasets: [ThemeChartDataset]
    private let showsFigures: Bool

    /// One profile, its score and count under each bar ("You: 7/10 · 31 votes", "Member: 7/10 · 24 votes and bills").
    init(
        profile: CivicProfileResponse,
        axes: [CivicProfileAxis] = CivicProfileAxis.allCases,
        scoreSubjectLabel: String = "You"
    ) {
        self.axes = axes
        self.datasets = [ThemeChartDataset(profile: profile, label: scoreSubjectLabel, style: .solid)]
        self.showsFigures = true
    }

    /// Two profiles told apart by line style, the scores in the table under the chart.
    init(datasets: [ThemeChartDataset], axes: [CivicProfileAxis] = CivicProfileAxis.allCases) {
        self.axes = axes
        self.datasets = datasets
        self.showsFigures = false
    }

    static let rowSpacing: CGFloat = BillboardStyle.Space.xl

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(axes, id: \.self) { axis in
                ThemeBarRow(axis: axis, datasets: datasets, showsFigures: showsFigures)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One theme: the end words, the track and, for one profile, the score and count.
private struct ThemeBarRow: View {
    let axis: CivicProfileAxis
    let datasets: [ThemeChartDataset]
    let showsFigures: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center, spacing: 6) {
            endWords
            ThemeBarTrack(marks: marks)
            if showsFigures {
                figures
            } else {
                ForEach(missingLines, id: \.self) { line in
                    captionText(line, color: BillboardColors.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }

    private var marks: [ThemeBarTrack.Mark?] {
        datasets.map { dataset in
            dataset.profile.signalValue(for: axis).map { ThemeBarTrack.Mark(value: $0, style: dataset.style) }
        }
    }

    // MARK: End words

    @ViewBuilder
    private var endWords: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedEndWords
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    captionText(axis.lowLabel, color: BillboardColors.secondaryText)
                        .fixedSize()
                    Spacer(minLength: BillboardStyle.Space.m)
                    captionText(axis.highLabel, color: BillboardColors.secondaryText)
                        .fixedSize()
                }
                stackedEndWords
            }
        }
    }

    private var stackedEndWords: some View {
        VStack(spacing: 2) {
            captionText(axis.lowLabel, color: BillboardColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            captionText(axis.highLabel, color: BillboardColors.secondaryText)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Score and count (one profile)

    private var dataset: ThemeChartDataset? {
        datasets.first
    }

    /// "31 votes" or "24 votes and bills"; nil when the server sent no count, and the count line is hidden.
    private var countText: String? {
        guard let profile = dataset?.profile, let count = profile.themeCount(for: axis) else { return nil }
        return ThemeBarsCopy.count(count, isMember: profile.isMemberProfile)
    }

    private var shortfall: String? {
        guard let profile = dataset?.profile else { return nil }
        return ThemeBarsCopy.shortfall(
            count: profile.themeCount(for: axis),
            floor: profile.minThemeVotes,
            isMember: profile.isMemberProfile
        )
    }

    @ViewBuilder
    private var figures: some View {
        if let dataset, let score = dataset.profile.displayScoreIfAvailable(for: axis) {
            let scoreText = ThemeBarsCopy.scoreText(subjectLabel: dataset.label, score: score)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    scoreLine(scoreText)
                    if let countText {
                        captionText(countText, color: BillboardColors.secondaryText)
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        scoreLine(scoreText)
                            .fixedSize()
                        if let countText {
                            captionText(" · \(countText)", color: BillboardColors.secondaryText)
                                .fixedSize()
                        }
                    }
                    VStack(alignment: .center, spacing: 2) {
                        scoreLine(scoreText)
                        if let countText {
                            captionText(countText, color: BillboardColors.secondaryText)
                        }
                    }
                }
            }
        } else {
            captionText(ThemeBarsCopy.notEnoughDataLine(shortfall: shortfall), color: BillboardColors.secondaryText)
        }
    }

    private func scoreLine(_ text: String) -> some View {
        Text(text)
            .font(TextRole.Face.text.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .semibold))
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func captionText(_ text: String, color: Color) -> some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Compare to you

    /// "You: Not enough data" for each profile without a score here, when the other has one; "Not enough data"
    /// when neither has.
    private var missingLines: [String] {
        guard datasets.count > 1, marks.contains(where: { $0 != nil }) else {
            return marks.allSatisfy({ $0 == nil }) ? [ThemeBarsCopy.notEnoughData] : []
        }
        return datasets.filter { $0.profile.signalValue(for: axis) == nil }
            .map { ThemeBarsCopy.missingInCompare(subjectLabel: $0.label) }
    }

    // MARK: VoiceOver

    private var spokenText: String {
        guard showsFigures, let dataset else {
            return ThemeBarsCopy.spokenCompare(axis, datasets: datasets)
        }
        return ThemeBarsCopy.spokenSingle(axis, dataset: dataset, count: countText, shortfall: shortfall)
    }
}

/// The drawing of one theme, decoration only (its row says everything in words): a 1 pt `rule` track from end to
/// end with short end ticks, each profile's bar from the middle to its value, and the middle tick on top, 2 pt
/// `ruleHeavy` standing 4 pt past the bars as on the Yea / Nay bar (`MajorityTick`). One profile: a 12 pt bar, `ink`
/// at 8% inside a 1 pt `ink` edge. Two: 7 pt bars either side of the track, the first that solid bar, the second a
/// 1.5 pt `ink2` dashed outline (4 on, 3 off) with nothing inside. No profile with a score: the track is dashed in
/// `rule2` and the middle tick is `rule2` too.
struct ThemeBarTrack: View {
    struct Mark: Equatable {
        /// 0 (the left-hand word) to 1 (the right-hand word).
        let value: Double
        let style: ThemeChartDataset.Style
    }

    /// One per profile, nil for a profile without a score on this theme.
    let marks: [Mark?]

    static let barHeight: CGFloat = 12
    static let thinBarHeight: CGFloat = 7
    static let barGap: CGFloat = 3
    static let overhang: CGFloat = 4
    static let middleTickWidth: CGFloat = 2
    /// Room at each end for the end ticks' strokes.
    static let endInset: CGFloat = 1
    /// A bar narrower than this is not drawn (a score at exactly the middle has none).
    static let minimumBarWidth: CGFloat = 0.5
    /// The solid bar's fill: `ink` at 8%.
    static let solidFillOpacity = 0.08
    /// The dashed bar's outline: 1.5 pt, 4 on and 3 off.
    static let dashedLineWidth: CGFloat = 1.5
    static let dash: [CGFloat] = [4, 3]
    /// The track's dashes when no profile has a score on the theme.
    static let emptyTrackDash: [CGFloat] = [3, 3]

    /// No profile has a score on this theme: no bar, and the track is dashed.
    var isEmpty: Bool {
        marks.allSatisfy { $0 == nil }
    }

    /// The height of the bars: one 12 pt bar, or two 7 pt bars and the gap between them.
    static func barsHeight(profileCount: Int) -> CGFloat {
        profileCount > 1 ? 2 * thinBarHeight + barGap : barHeight
    }

    /// The drawing's height: the bars and the middle tick's overhang above and below them.
    static func height(profileCount: Int) -> CGFloat {
        barsHeight(profileCount: profileCount) + 2 * overhang
    }

    /// Where a value sits between the track's ends, clamped to them.
    static func x(for value: Double, minX: CGFloat, maxX: CGFloat) -> CGFloat {
        minX + CGFloat(min(max(value, 0), 1)) * (maxX - minX)
    }

    /// A bar's left and right edges: from the middle to the value, either way; empty at exactly the middle.
    static func barEdges(value: Double, minX: CGFloat, maxX: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let middle = (minX + maxX) / 2
        let end = x(for: value, minX: minX, maxX: maxX)
        return (min(middle, end), max(middle, end))
    }

    /// Each profile's bar in a drawing of `size`, in the order of `marks`: nil for a profile without a score, and
    /// for a score at exactly the middle, which has no bar. One profile's bar is centred on the track; two profiles'
    /// thin bars sit either side of it, the first above.
    static func barRects(for marks: [Mark?], in size: CGSize) -> [CGRect?] {
        let minX = endInset
        let maxX = size.width - endInset
        let midY = size.height / 2
        let isCompare = marks.count > 1
        return marks.enumerated().map { index, mark in
            guard let mark, maxX > minX else { return nil }
            let edges = barEdges(value: mark.value, minX: minX, maxX: maxX)
            guard edges.right - edges.left >= minimumBarWidth else { return nil }
            let height = isCompare ? thinBarHeight : barHeight
            let top: CGFloat
            if isCompare {
                top = index == 0 ? midY - barGap / 2 - height : midY + barGap / 2
            } else {
                top = midY - height / 2
            }
            return CGRect(x: edges.left, y: top, width: edges.right - edges.left, height: height)
        }
    }

    /// Draws one bar in its style: the solid one filled with an `ink` edge, the dashed one an `ink2` outline. The
    /// legend's samples are drawn the same way.
    static func drawBar(_ rect: CGRect, style: ThemeChartDataset.Style, in context: GraphicsContext) {
        switch style {
        case .solid:
            context.fill(Path(rect), with: .color(BillboardColors.primaryText.opacity(solidFillOpacity)))
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(BillboardColors.primaryText), lineWidth: 1)
        case .dashed:
            let inset = dashedLineWidth / 2
            context.stroke(
                Path(rect.insetBy(dx: inset, dy: inset)),
                with: .color(BillboardColors.secondaryText),
                style: StrokeStyle(lineWidth: dashedLineWidth, dash: dash)
            )
        }
    }

    var body: some View {
        Canvas { context, size in
            let minX = Self.endInset
            let maxX = size.width - Self.endInset
            let midY = size.height / 2
            guard maxX > minX else { return }
            let barsHeight = Self.barsHeight(profileCount: marks.count)
            let hasNoScore = isEmpty

            var track = Path()
            track.move(to: CGPoint(x: minX, y: midY))
            track.addLine(to: CGPoint(x: maxX, y: midY))
            if hasNoScore {
                context.stroke(track, with: .color(BillboardColors.rule2), style: StrokeStyle(lineWidth: 1, dash: Self.emptyTrackDash))
            } else {
                context.stroke(track, with: .color(BillboardColors.separator), lineWidth: 1)
            }

            for endX in [minX, maxX] {
                var tick = Path()
                tick.move(to: CGPoint(x: endX, y: midY - barsHeight / 2))
                tick.addLine(to: CGPoint(x: endX, y: midY + barsHeight / 2))
                context.stroke(tick, with: .color(hasNoScore ? BillboardColors.rule2 : BillboardColors.separator), lineWidth: 1)
            }

            for (mark, rect) in zip(marks, Self.barRects(for: marks, in: size)) {
                guard let mark, let rect else { continue }
                Self.drawBar(rect, style: mark.style, in: context)
            }

            let middle = (minX + maxX) / 2
            let tick = CGRect(x: middle - Self.middleTickWidth / 2, y: 0, width: Self.middleTickWidth, height: size.height)
            context.fill(Path(tick), with: .color(hasNoScore ? BillboardColors.rule2 : BillboardColors.ruleHeavy))
        }
        .frame(height: Self.height(profileCount: marks.count))
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

#Preview("One profile") {
    ThemeBarsView(
        profile: CivicProfileResponse(
            axes: [
                "individualVsCommunity": 0.66,
                "localVsFederal": 0.37,
                "freeMarketVsRegulated": 0.71,
                "traditionalVsProgressive": 0.56,
                "interventionistVsRestrained": 0.45
            ],
            votesUsed: 47,
            totalVotesWithProfile: 47,
            minVotesRequired: 25,
            isReady: true,
            minThemeVotes: 8,
            themeVotes: [
                "individualVsCommunity": 31,
                "localVsFederal": 18,
                "freeMarketVsRegulated": 26,
                "traditionalVsProgressive": 22,
                "interventionistVsRestrained": 11,
                "privacyVsSecurity": 5
            ]
        )
    )
    .frame(width: 358)
    .padding()
}

#Preview("Compare to you") {
    ThemeBarsView(
        datasets: [
            ThemeChartDataset(
                profile: CivicProfileResponse(
                    axes: [
                        "individualVsCommunity": 0.70,
                        "localVsFederal": 0.40,
                        "freeMarketVsRegulated": 0.62,
                        "traditionalVsProgressive": 0.56,
                        "interventionistVsRestrained": 0.34,
                        "privacyVsSecurity": 0.82
                    ],
                    votesUsed: 33,
                    totalVotesWithProfile: 50,
                    minVotesRequired: 25,
                    isReady: true
                ),
                label: "Jordan Ellis",
                style: .solid
            ),
            ThemeChartDataset(
                profile: CivicProfileResponse(
                    axes: [
                        "individualVsCommunity": 0.66,
                        "localVsFederal": 0.37,
                        "freeMarketVsRegulated": 0.71,
                        "traditionalVsProgressive": 0.56,
                        "interventionistVsRestrained": 0.45
                    ],
                    votesUsed: 47,
                    totalVotesWithProfile: 47,
                    minVotesRequired: 25,
                    isReady: true
                ),
                label: "You",
                style: .dashed
            )
        ]
    )
    .frame(width: 358)
    .padding()
}
