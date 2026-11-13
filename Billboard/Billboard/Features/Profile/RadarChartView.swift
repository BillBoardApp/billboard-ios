import SwiftUI

/// One profile on the radar chart, drawn by line style rather than hue (Civic Record spec 3.27).
struct RadarChartDataset {
    enum Style: Equatable {
        /// 2 pt `ink` outline, `ink` at 8% inside, 5 pt `ink` dots on the corners: your own profile, or
        /// the member on a member page.
        case solid
        /// 1.5 pt `ink2` dashes (4 on, 3 off), nothing inside: "You" beside a member.
        case dashed
    }

    let profile: CivicProfileResponse
    let label: String
    var style: Style = .solid
}

/// The Civic Profile radar chart (Civic Record spec 3.27), in ink only: a grid of three rings and six
/// spokes in `rule`, each profile a polygon told apart by line style (`RadarChartDataset.Style`), and at
/// the end of each spoke its theme in the `caption` role (`ink2`): "10 Community", the score when one
/// profile is drawn ("Member: 7/10", in `ink`), "1 Individual". The six theme hues are gone; the words
/// say which theme is which.
///
/// The labels wrap, never shrink (spec 7.2): the side labels take the room their widest line needs (at
/// most 28% of the width) and the plot gets the rest. At accessibility text sizes the labels leave the
/// chart, which stays a picture, and the themes are listed under it, each with its score, one per row;
/// a chart of two profiles lists nothing, because its caller shows the scores by theme.
///
/// VoiceOver reads each theme as one element ("Individual (1) to Community (10). Member: 7/10"); the
/// plot itself is hidden.
struct RadarChartView: View {
    let axes: [CivicProfileAxis]
    let showsScoresInAxisLabels: Bool
    private let datasets: [RadarChartDataset]

    init(
        profile: CivicProfileResponse,
        axes: [CivicProfileAxis] = CivicProfileAxis.allCases,
        scoreSubjectLabel: String = "You"
    ) {
        self.datasets = [RadarChartDataset(profile: profile, label: scoreSubjectLabel, style: .solid)]
        self.axes = axes
        self.showsScoresInAxisLabels = true
    }

    init(
        datasets: [RadarChartDataset],
        axes: [CivicProfileAxis] = CivicProfileAxis.allCases,
        showsScoresInAxisLabels: Bool = false
    ) {
        self.datasets = datasets
        self.axes = axes
        self.showsScoresInAxisLabels = showsScoresInAxisLabels
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The score line under a theme's name: "You: 7/10", or "Not enough data" when the theme has
    /// no score yet (spec D 2.4.2).
    static func scoreText(subjectLabel: String, score: Int?) -> String {
        guard let score else { return notEnoughDataText }
        return "\(subjectLabel): \(score)/10"
    }

    static let notEnoughDataText = "Not enough data"

    /// The plot's largest side.
    static let maximumPlotSize: CGFloat = 280

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                RadarPlot(axes: axes, datasets: datasets)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: Self.maximumPlotSize)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)

                if showsScoresInAxisLabels {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(axes.enumerated()), id: \.element) { index, axis in
                            if index > 0 {
                                DottedRule()
                            }
                            themeRow(axis)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
        } else {
            RadarLabelLayout(axisCount: axes.count) {
                RadarPlot(axes: axes, datasets: datasets)
                    .accessibilityHidden(true)
                ForEach(Array(axes.enumerated()), id: \.element) { index, axis in
                    AxisEndpointLabel(
                        axis: axis,
                        scoreText: scoreText(for: axis),
                        alignment: RadarLabelLayout.textAlignment(index: index, count: axes.count)
                    )
                }
            }
        }
    }

    /// A theme under the chart at accessibility sizes: "Individual (1) to Community (10)" and the score.
    private func themeRow(_ axis: CivicProfileAxis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(axis.explanation)
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let score = scoreText(for: axis) {
                Text(score)
                    .font(TextRole.Face.text.font(size: TextRole.body.scaledSize(for: dynamicTypeSize), weight: .semibold))
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AxisEndpointLabel.accessibilityText(axis: axis, scoreText: scoreText(for: axis)))
    }

    private func scoreText(for axis: CivicProfileAxis) -> String? {
        guard showsScoresInAxisLabels, let dataset = datasets.first else { return nil }
        return Self.scoreText(subjectLabel: dataset.label, score: dataset.profile.displayScoreIfAvailable(for: axis))
    }
}

/// The chart's drawing: three rings and the spokes in `rule`, then each profile's polygon in its style.
/// It fills its frame; the plot is the largest square that fits, centred.
struct RadarPlot: View {
    let axes: [CivicProfileAxis]
    let datasets: [RadarChartDataset]

    static let gridRings = 3
    static let vertexDotDiameter: CGFloat = 5
    static let solidLineWidth: CGFloat = 2
    static let dashedLineWidth: CGFloat = 1.5
    static let dash: [CGFloat] = [4, 3]
    static let solidFillOpacity = 0.08

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Room for the corner dots.
            let radius = max(0, side / 2 - Self.vertexDotDiameter / 2)
            let count = axes.count
            guard count >= 3, radius > 0 else { return }

            for ring in 1...Self.gridRings {
                let ringRadius = radius * CGFloat(ring) / CGFloat(Self.gridRings)
                var grid = Path()
                for index in 0...count {
                    let point = RadarGeometry.point(center: center, radius: ringRadius, index: index % count, count: count)
                    if index == 0 { grid.move(to: point) } else { grid.addLine(to: point) }
                }
                grid.closeSubpath()
                context.stroke(grid, with: .color(BillboardColors.separator), lineWidth: 1)
            }

            for index in 0..<count {
                var spoke = Path()
                spoke.move(to: center)
                spoke.addLine(to: RadarGeometry.point(center: center, radius: radius, index: index, count: count))
                context.stroke(spoke, with: .color(BillboardColors.separator), lineWidth: 1)
            }

            for dataset in datasets {
                let values = availableValues(for: dataset.profile)
                guard values.count >= 3 else { continue }
                var outline = Path()
                for (offset, value) in (values + [values[0]]).enumerated() {
                    let point = RadarGeometry.point(center: center, radius: radius * CGFloat(value.normalizedValue), index: value.axisIndex, count: count)
                    if offset == 0 { outline.move(to: point) } else { outline.addLine(to: point) }
                }
                outline.closeSubpath()

                switch dataset.style {
                case .solid:
                    context.fill(outline, with: .color(BillboardColors.primaryText.opacity(Self.solidFillOpacity)))
                    context.stroke(outline, with: .color(BillboardColors.primaryText), style: StrokeStyle(lineWidth: Self.solidLineWidth, lineJoin: .round))
                    for value in values {
                        let point = RadarGeometry.point(center: center, radius: radius * CGFloat(value.normalizedValue), index: value.axisIndex, count: count)
                        let dot = Path(ellipseIn: CGRect(
                            x: point.x - Self.vertexDotDiameter / 2,
                            y: point.y - Self.vertexDotDiameter / 2,
                            width: Self.vertexDotDiameter,
                            height: Self.vertexDotDiameter
                        ))
                        context.fill(dot, with: .color(BillboardColors.primaryText))
                    }
                case .dashed:
                    context.stroke(
                        outline,
                        with: .color(BillboardColors.secondaryText),
                        style: StrokeStyle(lineWidth: Self.dashedLineWidth, lineJoin: .round, dash: Self.dash)
                    )
                }
            }
        }
    }

    private func availableValues(for profile: CivicProfileResponse) -> [(axisIndex: Int, normalizedValue: Double)] {
        axes.enumerated().compactMap { index, axis in
            guard let value = profile.signalValue(for: axis) else { return nil }
            return (axisIndex: index, normalizedValue: min(max(value, 0), 1))
        }
    }
}

/// Where the spokes point: the first straight up, then clockwise.
enum RadarGeometry {
    static func angle(index: Int, count: Int) -> CGFloat {
        CGFloat(index) / CGFloat(max(count, 1)) * 2 * .pi - .pi / 2
    }

    static func point(center: CGPoint, radius: CGFloat, index: Int, count: Int) -> CGPoint {
        let angle = angle(index: index, count: count)
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    /// A spoke that points straight up or down, whose label is centred over or under its corner.
    static func isVertical(index: Int, count: Int) -> Bool {
        abs(cos(angle(index: index, count: count))) < 0.01
    }
}

/// Lays out the plot (the first subview) and one label per spoke (the rest) around it: a label on a
/// spoke that points up or down is centred over or under its corner and as wide as the plot's middle; a
/// side label starts beside its corner and is as wide as the widest side label needs, at most 28% of the
/// width. The plot takes the width that is left (at most `RadarChartView.maximumPlotSize`), and the
/// height grows to fit the labels, so they wrap rather than shrink or overlap.
struct RadarLabelLayout: Layout {
    let axisCount: Int

    static let gap: CGFloat = 6
    static let maximumSideShare: CGFloat = 0.28
    /// A top or bottom label's width as a share of the plot: the width between the upper side corners
    /// (2 × cos 30° = 1.73 of the radius), so it never reaches over a side label.
    static let verticalLabelShare: CGFloat = 0.86

    static func textAlignment(index: Int, count: Int) -> HorizontalAlignment {
        if RadarGeometry.isVertical(index: index, count: count) { return .center }
        return cos(RadarGeometry.angle(index: index, count: count)) > 0 ? .leading : .trailing
    }

    struct Placement {
        var plot: CGRect
        var labels: [CGRect]
        var size: CGSize
    }

    func placement(width: CGFloat, subviews: Subviews) -> Placement {
        let labels = Array(subviews.dropFirst())
        let count = labels.count
        let sideIndices = (0..<count).filter { !RadarGeometry.isVertical(index: $0, count: count) }
        let sideIdeal = sideIndices.map { labels[$0].sizeThatFits(.unspecified).width }.max() ?? 0
        let sideWidth = min(ceil(sideIdeal), width * Self.maximumSideShare)
        let plotSide = max(0, min(RadarChartView.maximumPlotSize, width - 2 * (sideWidth + Self.gap)))
        let radius = plotSide / 2
        let verticalWidth = max(0, plotSide * Self.verticalLabelShare)

        // Each label's size at its width.
        let sizes: [CGSize] = (0..<count).map { index in
            let proposal = RadarGeometry.isVertical(index: index, count: count) ? verticalWidth : sideWidth
            let fitted = labels[index].sizeThatFits(ProposedViewSize(width: proposal, height: nil))
            return CGSize(width: proposal, height: fitted.height)
        }

        // Frames around a centre at y = 0, then shifted down so the topmost edge is at 0.
        let centerX = width / 2
        var frames: [CGRect] = []
        for index in 0..<count {
            let corner = RadarGeometry.point(center: CGPoint(x: centerX, y: 0), radius: radius, index: index, count: count)
            let size = sizes[index]
            let frame: CGRect
            if RadarGeometry.isVertical(index: index, count: count) {
                let above = corner.y < 0
                frame = CGRect(
                    x: corner.x - size.width / 2,
                    y: above ? corner.y - Self.gap - size.height : corner.y + Self.gap,
                    width: size.width,
                    height: size.height
                )
            } else {
                let toTheRight = corner.x > centerX
                frame = CGRect(
                    x: toTheRight ? corner.x + Self.gap : corner.x - Self.gap - size.width,
                    y: corner.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            }
            frames.append(frame)
        }
        let plotFrame = CGRect(x: centerX - radius, y: -radius, width: plotSide, height: plotSide)
        let top = min(plotFrame.minY, frames.map(\.minY).min() ?? 0)
        let bottom = max(plotFrame.maxY, frames.map(\.maxY).max() ?? 0)
        return Placement(
            plot: plotFrame.offsetBy(dx: 0, dy: -top),
            labels: frames.map { $0.offsetBy(dx: 0, dy: -top) },
            size: CGSize(width: width, height: bottom - top)
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        return placement(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let placement = placement(width: bounds.width, subviews: subviews)
        subviews[0].place(
            at: CGPoint(x: bounds.minX + placement.plot.minX, y: bounds.minY + placement.plot.minY),
            proposal: ProposedViewSize(placement.plot.size)
        )
        for (index, frame) in placement.labels.enumerated() where index + 1 < subviews.count {
            subviews[index + 1].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

/// A theme at the end of its spoke: "10 Community", the score when there is one, "1 Individual", in the
/// `caption` role (`ink2`, the score in `ink` semibold). One VoiceOver element.
private struct AxisEndpointLabel: View {
    let axis: CivicProfileAxis
    let scoreText: String?
    let alignment: HorizontalAlignment

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text("10 \(axis.highLabel)")
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)

            if let scoreText {
                Text(scoreText)
                    .font(TextRole.Face.text.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .semibold))
                    .foregroundStyle(BillboardColors.primaryText)
            }

            Text("1 \(axis.lowLabel)")
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
        }
        .multilineTextAlignment(textAlignment)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(axis: axis, scoreText: scoreText))
    }

    /// "Individual (1) to Community (10). You: 7/10".
    static func accessibilityText(axis: CivicProfileAxis, scoreText: String?) -> String {
        guard let scoreText else { return axis.explanation }
        return "\(axis.explanation). \(scoreText)"
    }
}

#Preview("Single") {
    RadarChartView(
        profile: CivicProfileResponse(
            axes: [
                "individualVsCommunity": 0.65,
                "localVsFederal": 0.55,
                "freeMarketVsRegulated": 0.7,
                "traditionalVsProgressive": 0.6,
                "interventionistVsRestrained": 0.45,
                "privacyVsSecurity": 0.75,
            ],
            votesUsed: 47,
            totalVotesWithProfile: 52,
            minVotesRequired: 25,
            isReady: true
        )
    )
    .frame(width: 350)
    .padding()
}

#Preview("Compare") {
    RadarChartView(
        datasets: [
            RadarChartDataset(
                profile: CivicProfileResponse(
                    axes: [
                        "individualVsCommunity": 0.70,
                        "localVsFederal": 0.40,
                        "freeMarketVsRegulated": 0.62,
                        "traditionalVsProgressive": 0.56,
                        "interventionistVsRestrained": 0.34,
                        "privacyVsSecurity": 0.82,
                    ],
                    votesUsed: 33,
                    totalVotesWithProfile: 50,
                    minVotesRequired: 25,
                    isReady: true
                ),
                label: "Tim Kaine",
                style: .solid
            ),
            RadarChartDataset(
                profile: CivicProfileResponse(
                    axes: [
                        "individualVsCommunity": 0.52,
                        "localVsFederal": 0.61,
                        "freeMarketVsRegulated": 0.48,
                        "traditionalVsProgressive": 0.66,
                        "interventionistVsRestrained": 0.44,
                        "privacyVsSecurity": 0.57,
                    ],
                    votesUsed: 47,
                    totalVotesWithProfile: 52,
                    minVotesRequired: 25,
                    isReady: true
                ),
                label: "You",
                style: .dashed
            )
        ]
    )
    .frame(width: 350)
    .padding()
}
