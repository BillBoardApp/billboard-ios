import SwiftUI

/// "Map: verified voters": the Yea share of verified voters by state (national) or by district in
/// the user's state. State and district rollups count verified voters only (spec D 2.2), and the
/// fill uses the plain `yeaPct`. Regions under the floor are hatched (spec D 2.3.5).
///
/// Civic Record (spec 3.9): the sublabel in the `label` role, the National / state segmented control,
/// the map on a `plate` that bleeds 10 pt past the gutter, an 8 pt square ramp with mono labels, the hatch
/// key, the help line and a sheet card for the selected region. Never drawn while Results are sealed, nor when no
/// state clears the floor (`Summary.showsMap`); at the state level, a district map that would be all hatched
/// gives way to "Every district has fewer than 5 votes so far." (UX-34).
struct BillStatsHeatMapSection: View {
    let billStats: BillStatsService.BillStats?
    let isLoadingStats: Bool
    let userStateCode: String
    let userDistrictValue: String

    @State private var level: VoterMapLevel = .national
    @State private var geometry: VoterMapGeometry?
    @State private var selectedRegionID: String?
    @State private var isLoadingGeometry = false
    @State private var mapError: String?

    @ScaledMetric(relativeTo: .footnote) private var swatchWidth: CGFloat = 18
    @ScaledMetric(relativeTo: .footnote) private var swatchHeight: CGFloat = 14

    private var normalizedUserState: String? {
        VoterMapGeometryLoader.normalizedStateCode(userStateCode)
    }

    private var minDecisionVotes: Int {
        billStats?.resolvedComparison.minDecisionVotes ?? VoterMapStyling.defaultMinDecisionVotes
    }

    private var geometryLoadKey: String {
        "\(level.rawValue)|\(normalizedUserState ?? "")"
    }

    private var highlightedRegionIDs: Set<String> {
        switch level {
        case .national:
            guard let normalizedUserState else { return [] }
            return [normalizedUserState]
        case .state:
            guard let normalizedUserState,
                  let highlightedDistrictID = VoterMapStyling.canonicalDistrictRegionID(
                    stateCode: normalizedUserState,
                    rawDistrict: userDistrictValue
                  ) else { return [] }
            return [highlightedDistrictID]
        }
    }

    private var statsByRegion: [String: VoterMapRegionStat] {
        guard let geometry else { return [:] }

        switch level {
        case .national:
            return Dictionary(uniqueKeysWithValues: geometry.features.map { feature in
                let stat = billStats?.rollups.byState[feature.id].map {
                    VoterMapRegionStat(id: feature.id, label: feature.label, totals: $0.totals)
                } ?? .empty(id: feature.id, label: feature.label)
                return (feature.id, stat)
            })

        case .state:
            guard let normalizedUserState else { return [:] }

            var totalsByRegion: [String: BillStatsService.VoteTotals] = [:]
            if let byDistrict = billStats?.rollups.byDistrict {
                for rollup in byDistrict.values {
                    let rollupState = rollup.state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard rollupState == normalizedUserState else { continue }
                    guard let canonicalID = VoterMapStyling.canonicalDistrictRegionID(
                        stateCode: rollupState,
                        rawDistrict: rollup.district
                    ) else { continue }
                    totalsByRegion[canonicalID] = rollup.totals
                }
            }

            return Dictionary(uniqueKeysWithValues: geometry.features.map { feature in
                let stat = totalsByRegion[feature.id].map {
                    VoterMapRegionStat(id: feature.id, label: feature.label, totals: $0)
                } ?? .empty(id: feature.id, label: feature.label)
                return (feature.id, stat)
            })
        }
    }

    /// Whether a district in the user's state has `minDecisionVotes` Yea or Nay votes, so the state level's map
    /// has something to show.
    private var hasDistrictOverTheFloor: Bool {
        guard let normalizedUserState else { return false }
        return billStats?.rollups.byDistrict.values.contains { rollup in
            rollup.state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedUserState
                && VoteResultsFormatting.localValue(rollup.totals, floor: minDecisionVotes).percentages != nil
        } ?? false
    }

    private var selection: VoterMapSelection? {
        guard let selectedRegionID,
              let stat = statsByRegion[selectedRegionID] else {
            return nil
        }
        return VoterMapSelection(stat: stat, minDecisionVotes: minDecisionVotes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(VoteResultsFormatting.mapTitle)
                .textRole(.label)
                .foregroundStyle(BillboardColors.secondaryText)
                .accessibilityAddTraits(.isHeader)

            Picker("Map level", selection: $level) {
                Text("National").tag(VoterMapLevel.national)
                Text(normalizedUserState ?? "Your state").tag(VoterMapLevel.state)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Map level")
            .padding(.top, BillboardStyle.Space.s + 2)

            if level == .state && normalizedUserState == nil {
                Text(VoteResultsFormatting.addressForStateText)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, BillboardStyle.Space.m)
            } else if level == .state && !hasDistrictOverTheFloor {
                Text(VoteResultsFormatting.districtsUnderFloorText(minDecisionVotes))
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, BillboardStyle.Space.m)
                    .accessibilityIdentifier("bill.results.mapDistrictsUnderFloor")
            } else if let geometry {
                plate(geometry)
                legend
                Text(VoteResultsFormatting.mapHelpText(national: level == .national, outlinesYours: !highlightedRegionIDs.isEmpty))
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, BillboardStyle.Space.s + 2)
                if let selection {
                    selectionCard(selection)
                        .padding(.top, BillboardStyle.Space.s + 2)
                }
            } else if isLoadingGeometry {
                HStack(spacing: BillboardStyle.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BillboardColors.interactive)
                        .accessibilityHidden(true)
                    Text("Loading map…")
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, BillboardStyle.Space.m)
            } else {
                RecordNotice(.couldNotLoad, title: mapError ?? Self.couldNotLoadText)
                    .padding(.top, BillboardStyle.Space.s)
            }
        }
        .padding(.top, BillboardStyle.Space.xl)
        .task(id: geometryLoadKey) {
            await loadGeometryIfNeeded()
        }
        .onChange(of: level) { _, _ in
            selectedRegionID = nil
        }
    }

    static let couldNotLoadText = "The map couldn't load."

    /// The map on its plate (spec 3.9): `plate` fill, the slip radius and 10 pt inside, bleeding 10 pt past
    /// the document's gutter on each side so the map keeps its width.
    private func plate(_ geometry: VoterMapGeometry) -> some View {
        VoterChoroplethView(
            geometry: geometry,
            statsByRegion: statsByRegion,
            selectedRegionID: selection?.regionId,
            highlightedRegionIDs: highlightedRegionIDs,
            minDecisionVotes: minDecisionVotes,
            onSelectRegion: { selectedRegionID = $0 }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level == .national ? "Map of verified voters by state" : "Map of verified voters by district")
        .accessibilityValue(selection?.spokenText ?? "No region selected")
        .frame(maxWidth: .infinity)
        .padding(Self.platePadding)
        .background(
            RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
                .fill(BillboardColors.plate)
        )
        .padding(.horizontal, -Self.platePadding)
        .padding(.top, BillboardStyle.Space.m)
    }

    static let platePadding: CGFloat = 10

    /// The ramp (8 pt, square ends) from 100% Nay through 50/50 to 100% Yea, its three labels in the docket
    /// face, then the hatched swatch for "Fewer than 5 votes". The colour scale is never the only cue: the
    /// selection card names the numbers.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: VoterMapStyling.rampColors, startPoint: .leading, endPoint: .trailing))
                .frame(height: Self.rampHeight)

            VoterMapRampLabels()
                .padding(.top, 6)

            HStack(spacing: BillboardStyle.Space.s) {
                VoterMapHatchSwatch(cornerRadius: 2)
                    .frame(width: swatchWidth, height: swatchHeight)
                Text(VoteResultsFormatting.hatchKeyText(floor: minDecisionVotes))
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, BillboardStyle.Space.s + 2)
        }
        .padding(.top, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map legend")
        .accessibilityValue(VoteResultsFormatting.mapLegendAccessibilityValue(floor: minDecisionVotes))
        .accessibilityIdentifier("bill.results.mapLegend")
    }

    static let rampHeight: CGFloat = 8

    /// The selected region on a sheet card: `sheet` fill, a 1 pt rule, the slip radius.
    private func selectionCard(_ selection: VoterMapSelection) -> some View {
        Text(selection.text)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(BillboardStyle.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
                    .fill(BillboardColors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
                    .strokeBorder(BillboardColors.separator, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Selected region")
            .accessibilityValue(selection.spokenText)
            .accessibilityIdentifier("bill.results.mapSelection")
    }

    @MainActor
    private func loadGeometryIfNeeded() async {
        isLoadingGeometry = true
        mapError = nil
        defer { isLoadingGeometry = false }

        do {
            switch level {
            case .national:
                geometry = try await VoterMapGeometryLoader.shared.nationalGeometry()
            case .state:
                guard let normalizedUserState else {
                    geometry = nil
                    mapError = nil
                    return
                }
                geometry = try await VoterMapGeometryLoader.shared.districtGeometry(stateCode: normalizedUserState)
            }
        } catch {
            geometry = nil
            mapError = Self.couldNotLoadText
        }
    }
}

/// The map ramp's three labels (spec 3.9) in the docket face: "100% NAY" under the Nay end, "50/50" centred
/// on the ramp's midpoint, which is the 50/50 colour, and "100% YEA" under the Yea end. One row while it
/// keeps "50/50" centred with a character's room on each side; otherwise (the accessibility sizes) a line
/// each, at the same three places. "50/50" never breaks.
struct VoterMapRampLabels: View {
    static let nayText = "100% Nay"
    static let midText = "50/50"
    static let yeaText = "100% Yea"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            CentredRow(minimumGap: TextRole.docket.scaledSize(for: dynamicTypeSize)) {
                label(Self.nayText)
                label(Self.midText)
                label(Self.yeaText)
            }
            VStack(spacing: 2) {
                label(Self.nayText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                label(Self.midText)
                    .frame(maxWidth: .infinity)
                label(Self.yeaText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .textRole(.docket)
        .foregroundStyle(BillboardColors.secondaryText)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Three views on one row: the first at the leading edge, the second centred on the row, the third at the
/// trailing edge. Its ideal width keeps `minimumGap` between the centred view and the wider end, so a
/// `ViewThatFits` moves on where they would crowd it off the centre.
struct CentredRow: Layout {
    var minimumGap: CGFloat

    /// The narrowest row that keeps the middle centred with `minimumGap` on each side.
    static func idealWidth(leading: CGFloat, middle: CGFloat, trailing: CGFloat, minimumGap: CGFloat) -> CGFloat {
        2 * (max(leading, trailing) + minimumGap) + middle
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard sizes.count == 3 else { return .zero }
        let ideal = Self.idealWidth(leading: sizes[0].width, middle: sizes[1].width, trailing: sizes[2].width, minimumGap: minimumGap)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: .unspecified)
    }
}
