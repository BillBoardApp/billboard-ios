import SwiftUI
import UIKit

enum VoterMapLevel: String, CaseIterable, Identifiable {
    case national = "National"
    case state = "State"

    var id: String { rawValue }
}

/// One region's verified-voter result (state and district rollups count verified voters only).
struct VoterMapRegionStat: Equatable {
    let id: String
    let label: String
    /// 0 to 100 over Yea + Nay (the plain `yeaPct`, never a weighted value); nil with no votes.
    let yeaPct: Double?
    let yea: Int
    let nay: Int
    let decisionVotes: Int
    var abstainVotes: Int = 0

    init(id: String, label: String, yeaPct: Double?, yea: Int = 0, nay: Int = 0, decisionVotes: Int, abstainVotes: Int = 0) {
        self.id = id
        self.label = label
        self.yeaPct = yeaPct
        self.yea = yea
        self.nay = nay
        self.decisionVotes = decisionVotes
        self.abstainVotes = abstainVotes
    }

    /// A region with no rollup (no votes, or left out under the floor).
    static func empty(id: String, label: String) -> VoterMapRegionStat {
        VoterMapRegionStat(id: id, label: label, yeaPct: nil, decisionVotes: 0)
    }

    /// The region's rollup totals.
    init(id: String, label: String, totals: BillStatsService.VoteTotals) {
        self.init(
            id: id,
            label: label,
            yeaPct: totals.yeaPct,
            yea: totals.yea,
            nay: totals.nay,
            decisionVotes: totals.decisionVotes,
            abstainVotes: totals.abstain
        )
    }

    /// True when the region has at least `minDecisionVotes` Yea + Nay votes and a Yea share.
    func hasEnoughVotes(minDecisionVotes: Int) -> Bool {
        decisionVotes >= max(1, minDecisionVotes) && yeaPct != nil
    }
}

struct VoterMapSelection: Equatable {
    let regionId: String
    /// "Virginia · 55% Yea · 45% Nay · 9 verified votes", "VA-11 · Fewer than 5 votes so far".
    let text: String
    /// What VoiceOver reads, the map's value and the selection card's: `text` with the region in the one
    /// spoken form, "Virginia's 11th district · Fewer than 5 votes so far" (project decision of 2026-10-21).
    let spokenText: String
}

extension VoterMapSelection {
    /// The selection for a region's result, under the floor of `minDecisionVotes`.
    init(stat: VoterMapRegionStat, minDecisionVotes: Int) {
        func text(naming name: String) -> String {
            VoteResultsFormatting.mapSelectionText(
                name: name,
                yeaPct: stat.yeaPct,
                yea: stat.yea,
                nay: stat.nay,
                decisionVotes: stat.decisionVotes,
                floor: minDecisionVotes
            )
        }
        self.init(
            regionId: stat.id,
            text: text(naming: VoteResultsFormatting.regionDisplayName(id: stat.id, label: stat.label)),
            spokenText: text(naming: VoteResultsFormatting.regionSpokenName(id: stat.id, label: stat.label))
        )
    }
}

/// The vote map's colours (spec D 2.3.5): a CIELAB ramp from `voteNay` (0% Yea) through `mapNeutral`
/// (50/50) to `voteYea` (100% Yea), precomputed as 21 stops for each appearance, and a hatch on
/// `secondaryBackground` for regions under the floor, so "too few votes" never looks like 50/50.
///
/// Civic Record (spec 3.9): every state is outlined at full strength (0.75 pt `ink3` in light, `ink2` in
/// dark, 3:1 or more against the plate and the 50/50 fill), the user's state in a 2 pt dashed `ink`
/// line and the selected state in a 2.5 pt solid `ink` line, so weight and dash tell them apart.
enum VoterMapStyling {
    /// Every region's outline.
    static let outlineWidth: CGFloat = 0.75
    /// The user's state or district: dashed.
    static let highlightWidth: CGFloat = 2
    static let highlightDash: [CGFloat] = [3, 2]
    /// The selected region: solid.
    static let selectionWidth: CGFloat = 2.5

    /// The outline's colour: `ink3` in light and `ink2` in dark, each at full strength.
    static func outlineToken(dark: Bool) -> BillboardColorToken {
        dark ? BillboardPalette.secondaryText : BillboardPalette.dimText
    }

    /// `outlineToken` as a colour for the appearance being drawn.
    static func outlineColor(dark: Bool) -> Color {
        dark ? BillboardColors.secondaryText : BillboardColors.dimText
    }

    /// The floor when the stats carry none (`BillStatsService.Comparison.defaultMinDecisionVotes`).
    static let defaultMinDecisionVotes = BillStatsService.Comparison.defaultMinDecisionVotes
    static let rampStopCount = 21
    /// The hatch lines are `dimText` at this opacity.
    static let hatchOpacity = 0.35
    static let hatchSpacing: CGFloat = 6
    static let hatchLineWidth: CGFloat = 1

    /// The ramp stop for `index` (0 = 100% Nay, 10 = 50/50, 20 = 100% Yea) in one appearance.
    static func rampRGBA(index: Int, dark: Bool) -> BillboardColorToken.RGBA {
        let clamped = min(max(index, 0), rampStopCount - 1)
        let middle = (rampStopCount - 1) / 2
        let nay = BillboardPalette.voteNay.resolved(dark: dark).rgb
        let neutral = BillboardPalette.mapNeutral.resolved(dark: dark).rgb
        let yea = BillboardPalette.voteYea.resolved(dark: dark).rgb
        let rgb: BillboardColorMath.RGB
        if clamped <= middle {
            rgb = BillboardColorMath.interpolateLab(from: nay, to: neutral, fraction: Double(clamped) / Double(middle))
        } else {
            rgb = BillboardColorMath.interpolateLab(from: neutral, to: yea, fraction: Double(clamped - middle) / Double(middle))
        }
        return BillboardColorToken.RGBA(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The 21 stops as dynamic tokens (light and dark), computed once.
    static let rampTokens: [BillboardColorToken] = (0..<rampStopCount).map { index in
        BillboardColorToken(light: rampRGBA(index: index, dark: false), dark: rampRGBA(index: index, dark: true))
    }

    /// The 21 stops as colours that follow the appearance, for the map and the legend gradient.
    static let rampColors: [Color] = rampTokens.map { Color(uiColor: $0.uiColor) }

    /// The stop for a Yea share: every 5 points, rounded (52% is the 50/50 stop, 53% the next).
    static func rampIndex(yeaPct: Double) -> Int {
        guard yeaPct.isFinite else { return (rampStopCount - 1) / 2 }
        let clamped = min(100, max(0, yeaPct))
        return Int((clamped / 100 * Double(rampStopCount - 1)).rounded())
    }

    /// How a region is drawn.
    enum Fill: Equatable {
        /// A ramp stop (`rampIndex(yeaPct:)`).
        case ramp(Int)
        /// Under the floor or no data: hatched `secondaryBackground`.
        case hatched
    }

    static func fill(for stat: VoterMapRegionStat?, minDecisionVotes: Int) -> Fill {
        guard let stat, stat.hasEnoughVotes(minDecisionVotes: minDecisionVotes), let pct = stat.yeaPct else {
            return .hatched
        }
        return .ramp(rampIndex(yeaPct: pct))
    }

    /// The ramp colour of a fill, nil for a hatched one.
    static func color(for fill: Fill) -> Color? {
        guard case .ramp(let index) = fill else { return nil }
        return rampColors[min(max(index, 0), rampColors.count - 1)]
    }

    /// Diagonal hatch lines covering `rect`, `spacing` apart.
    static func hatchPath(in rect: CGRect, spacing: CGFloat = hatchSpacing) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0, spacing > 0 else { return path }
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += spacing
        }
        return path
    }

    static func canonicalDistrictRegionID(stateCode: String, rawDistrict: String) -> String? {
        guard let normalizedState = VoterMapGeometryLoader.normalizedStateCode(stateCode) else { return nil }

        let trimmed = rawDistrict.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("AT-LARGE") {
            return "\(normalizedState)-AL"
        }

        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        let noStatePrefix = compact
            .replacingOccurrences(of: "\(normalizedState)-", with: "")
            .replacingOccurrences(of: normalizedState, with: "")

        if noStatePrefix == "AL" || noStatePrefix == "0" || noStatePrefix == "00" {
            return "\(normalizedState)-AL"
        }

        let digits = noStatePrefix.filter { $0.isNumber }
        if let value = Int(digits), value > 0 {
            return String(format: "%@-%02d", normalizedState, value)
        }

        return nil
    }
}

/// A hatched swatch: the map's "fewer than 5 votes" fill.
struct VoterMapHatchSwatch: View {
    var cornerRadius: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
            context.fill(shape, with: .color(BillboardColors.secondaryBackground))
            var hatch = context
            hatch.clip(to: shape)
            hatch.stroke(
                VoterMapStyling.hatchPath(in: rect, spacing: VoterMapStyling.hatchSpacing / 1.5),
                with: .color(BillboardColors.dimText.opacity(VoterMapStyling.hatchOpacity)),
                lineWidth: VoterMapStyling.hatchLineWidth
            )
            context.stroke(shape, with: .color(BillboardColors.separator), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

struct VoterChoroplethView: View {
    let geometry: VoterMapGeometry
    let statsByRegion: [String: VoterMapRegionStat]
    let selectedRegionID: String?
    let highlightedRegionIDs: Set<String>
    /// Regions with fewer Yea + Nay votes than this are hatched.
    var minDecisionVotes: Int = VoterMapStyling.defaultMinDecisionVotes
    let onSelectRegion: (String?) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var zoomScale: CGFloat = 1
    @State private var zoomScaleBase: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var panOffsetBase: CGSize = .zero

    private let minZoom: CGFloat = 0.75
    private let maxZoom: CGFloat = 5

    private var isZoomedIn: Bool {
        zoomScale > 1.01
    }

    var body: some View {
        GeometryReader { proxy in
            let transform = Transform(bounds: geometry.featureBounds, viewSize: proxy.size)

            ZStack {
                ZStack {
                    Canvas { context, size in
                        _ = size
                        let hatchColor = BillboardColors.dimText.opacity(VoterMapStyling.hatchOpacity)
                        let outline = VoterMapStyling.outlineColor(dark: colorScheme == .dark)
                        var highlighted: [Path] = []
                        var selected: Path?
                        for feature in geometry.features {
                            let stat = statsByRegion[feature.id]
                            let path = pathForFeature(feature, transform: transform)
                            let fill = VoterMapStyling.fill(for: stat, minDecisionVotes: minDecisionVotes)
                            if let color = VoterMapStyling.color(for: fill) {
                                context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
                            } else {
                                // Too few votes: hatched, never a flat grey that reads as 50/50.
                                context.fill(path, with: .color(BillboardColors.secondaryBackground), style: FillStyle(eoFill: true))
                                var hatch = context
                                hatch.clip(to: path, style: FillStyle(eoFill: true))
                                hatch.stroke(
                                    VoterMapStyling.hatchPath(in: path.boundingRect),
                                    with: .color(hatchColor),
                                    lineWidth: VoterMapStyling.hatchLineWidth
                                )
                            }
                            context.stroke(path, with: .color(outline), lineWidth: VoterMapStyling.outlineWidth)

                            if selectedRegionID == feature.id {
                                selected = path
                            } else if highlightedRegionIDs.contains(feature.id) {
                                highlighted.append(path)
                            }
                        }
                        // The user's region and the selection go on top, so no neighbour's outline covers them.
                        for path in highlighted {
                            context.stroke(
                                path,
                                with: .color(BillboardColors.primaryText),
                                style: StrokeStyle(lineWidth: VoterMapStyling.highlightWidth, dash: VoterMapStyling.highlightDash)
                            )
                        }
                        if let selected {
                            context.stroke(selected, with: .color(BillboardColors.primaryText), lineWidth: VoterMapStyling.selectionWidth)
                        }
                    }

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                let unscaledPoint = mapToUnscaledViewPoint(
                                    value.location,
                                    viewSize: proxy.size
                                )
                                let canvasPoint = transform.toCanvas(unscaledPoint)
                                let effectiveScale = max(transform.scale * Double(zoomScale), 0.0000001)
                                let tapTolerance = max(6.0, 22.0 / effectiveScale)
                                let selected = hitTest(canvasPoint, tolerance: tapTolerance)
                                onSelectRegion(selected)
                            }
                        )
                }
                .scaleEffect(zoomScale)
                .offset(panOffset)
                .clipped()
                // Only pan once zoomed in; at normal size drags must reach the enclosing
                // ScrollView so the page keeps scrolling. Taps on regions still work.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let raw = CGSize(
                                width: panOffsetBase.width + value.translation.width,
                                height: panOffsetBase.height + value.translation.height
                            )
                            panOffset = clampedPanOffset(raw, viewSize: proxy.size)
                        }
                        .onEnded { value in
                            let raw = CGSize(
                                width: panOffsetBase.width + value.translation.width,
                                height: panOffsetBase.height + value.translation.height
                            )
                            panOffset = clampedPanOffset(raw, viewSize: proxy.size)
                            panOffsetBase = panOffset
                        },
                    including: isZoomedIn ? .all : .subviews
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { amount in
                            let raw = zoomScaleBase * amount
                            zoomScale = min(max(raw, minZoom), maxZoom)
                            panOffset = clampedPanOffset(panOffset, viewSize: proxy.size)
                        }
                        .onEnded { amount in
                            let raw = zoomScaleBase * amount
                            zoomScale = min(max(raw, minZoom), maxZoom)
                            zoomScaleBase = zoomScale
                            panOffset = clampedPanOffset(panOffset, viewSize: proxy.size)
                            panOffsetBase = panOffset
                        }
                )

                if abs(zoomScale - 1) > 0.02 {
                    VStack {
                        HStack {
                            Spacer()
                            BBActionButton(
                                title: "Reset",
                                action: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        zoomScale = 1
                                        zoomScaleBase = 1
                                        panOffset = .zero
                                        panOffsetBase = .zero
                                    }
                                },
                                // Over the map, so an opaque capsule (Civic Record spec 3.16).
                                kind: .panelSecondary,
                                expandToMaxWidth: false
                            )
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
        }
        .aspectRatio(geometry.featureBounds.width / max(1, geometry.featureBounds.height), contentMode: .fit)
    }

    private func hitTest(_ point: VoterMapPoint, tolerance: Double) -> String? {
        for feature in geometry.features {
            guard bboxContains(feature.bbox, point: point, padding: tolerance) else { continue }
            if isPoint(point, inside: feature) {
                return feature.id
            }
        }
        return nearestFeatureID(to: point, maxDistance: tolerance)
    }

    private func nearestFeatureID(to point: VoterMapPoint, maxDistance: Double) -> String? {
        var bestID: String?
        var bestDistance = maxDistance

        for feature in geometry.features {
            guard bboxContains(feature.bbox, point: point, padding: maxDistance) else { continue }
            let distance = distanceToFeature(point, feature: feature)
            if distance < bestDistance {
                bestDistance = distance
                bestID = feature.id
            }
        }

        return bestID
    }

    private func isPoint(_ point: VoterMapPoint, inside feature: VoterMapFeature) -> Bool {
        for polygon in feature.polygons {
            guard let outer = polygon.rings.first, isPoint(point, insideRing: outer) else { continue }
            let inHole = polygon.rings.dropFirst().contains { ring in
                isPoint(point, insideRing: ring)
            }
            if !inHole {
                return true
            }
        }
        return false
    }

    private func isPoint(_ point: VoterMapPoint, insideRing ring: [VoterMapPoint]) -> Bool {
        guard ring.count >= 3 else { return false }

        var isInside = false
        var j = ring.count - 1

        for i in 0..<ring.count {
            let xi = ring[i].x
            let yi = ring[i].y
            let xj = ring[j].x
            let yj = ring[j].y

            let intersects = ((yi > point.y) != (yj > point.y))
                && (point.x < ((xj - xi) * (point.y - yi) / max(yj - yi, 0.0000001) + xi))
            if intersects {
                isInside.toggle()
            }
            j = i
        }

        return isInside
    }

    private func distanceToFeature(_ point: VoterMapPoint, feature: VoterMapFeature) -> Double {
        if isPoint(point, inside: feature) {
            return 0
        }

        var best = Double.greatestFiniteMagnitude
        for polygon in feature.polygons {
            for ring in polygon.rings where ring.count >= 2 {
                for i in 0..<ring.count {
                    let a = ring[i]
                    let b = ring[(i + 1) % ring.count]
                    let distance = pointToSegmentDistance(point: point, a: a, b: b)
                    if distance < best {
                        best = distance
                    }
                }
            }
        }

        return best
    }

    private func pointToSegmentDistance(point: VoterMapPoint, a: VoterMapPoint, b: VoterMapPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if abs(dx) < 0.0000001, abs(dy) < 0.0000001 {
            let vx = point.x - a.x
            let vy = point.y - a.y
            return sqrt(vx * vx + vy * vy)
        }

        let tRaw = ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)
        let t = min(1, max(0, tRaw))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        let vx = point.x - projX
        let vy = point.y - projY
        return sqrt(vx * vx + vy * vy)
    }

    private func bboxContains(_ bbox: VoterMapBoundingBox, point: VoterMapPoint, padding: Double) -> Bool {
        point.x >= (bbox.minX - padding)
            && point.x <= (bbox.maxX + padding)
            && point.y >= (bbox.minY - padding)
            && point.y <= (bbox.maxY + padding)
    }

    private func mapToUnscaledViewPoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let centerX = viewSize.width / 2
        let centerY = viewSize.height / 2

        let localX = point.x - centerX - panOffset.width
        let localY = point.y - centerY - panOffset.height
        let unscaledX = localX / max(zoomScale, 0.0000001)
        let unscaledY = localY / max(zoomScale, 0.0000001)

        return CGPoint(x: centerX + unscaledX, y: centerY + unscaledY)
    }

    private func clampedPanOffset(_ proposed: CGSize, viewSize: CGSize) -> CGSize {
        guard zoomScale > 1 else { return .zero }
        let maxX = (viewSize.width * (zoomScale - 1)) / 2
        let maxY = (viewSize.height * (zoomScale - 1)) / 2

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func pathForFeature(_ feature: VoterMapFeature, transform: Transform) -> Path {
        var path = Path()

        for polygon in feature.polygons {
            for ring in polygon.rings where !ring.isEmpty {
                for (index, point) in ring.enumerated() {
                    let mapped = transform.toView(point)
                    if index == 0 {
                        path.move(to: mapped)
                    } else {
                        path.addLine(to: mapped)
                    }
                }
                path.closeSubpath()
            }
        }

        return path
    }
}

private struct Transform {
    let bounds: VoterMapBoundingBox
    let scale: Double
    let offsetX: Double
    let offsetY: Double

    init(bounds: VoterMapBoundingBox, viewSize: CGSize) {
        self.bounds = bounds

        let widthScale = Double(viewSize.width) / max(1, bounds.width)
        let heightScale = Double(viewSize.height) / max(1, bounds.height)
        scale = min(widthScale, heightScale)

        let contentWidth = bounds.width * scale
        let contentHeight = bounds.height * scale

        offsetX = (Double(viewSize.width) - contentWidth) / 2
        offsetY = (Double(viewSize.height) - contentHeight) / 2
    }

    func toView(_ point: VoterMapPoint) -> CGPoint {
        CGPoint(
            x: offsetX + ((point.x - bounds.minX) * scale),
            y: offsetY + ((point.y - bounds.minY) * scale)
        )
    }

    func toCanvas(_ point: CGPoint) -> VoterMapPoint {
        let x = ((Double(point.x) - offsetX) / max(scale, 0.0000001)) + bounds.minX
        let y = ((Double(point.y) - offsetY) / max(scale, 0.0000001)) + bounds.minY
        return VoterMapPoint(x: x, y: y)
    }
}
