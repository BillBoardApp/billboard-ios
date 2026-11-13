import Foundation
import SwiftUI

enum CongressMemberCivicProfileCardMode: Equatable {
    case profile(CivicProfileResponse)
    case loading
    case unavailable
}

/// The member page's Civic Profile section (Civic Record spec 3.27, 4.59): a ruled document section
/// with the title and the ink info button, then the member's chart in ink and the AI note (UX-37). "Compare to you" adds your
/// chart as a dashed line, a legend by line style and the scores by theme; "Details" shows the data
/// behind the chart. A member without enough votes and bills shows the locked state with a square-ended
/// progress bar. No pie or lock symbols, no glow border, no hues.
struct CongressMemberCivicProfileCard: View {
    @EnvironmentObject private var civicProfileStore: CivicProfileStore

    let mode: CongressMemberCivicProfileCardMode
    /// The member's name, for the legend ("Tim Kaine" beside the solid line).
    var memberName: String = "Member"

    @State private var isShowingInfo = false
    @State private var isShowingComparison = false
    @State private var isShowingDetails = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let title = "Civic Profile"

    /// The member as the solid line and you as the dashed one (spec 3.27).
    static func comparisonDatasets(member: CivicProfileResponse, user: CivicProfileResponse, memberName: String) -> [RadarChartDataset] {
        [
            RadarChartDataset(profile: member, label: memberName, style: .solid),
            RadarChartDataset(profile: user, label: "You", style: .dashed)
        ]
    }

    var body: some View {
        RecordSection(nil) {
            HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
                Text(Self.title)
                    .textRole(.heading)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                CivicProfileInfoButton(isShowingInfo: $isShowingInfo)
            }

            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                    switch mode {
                    case .loading:
                        CongressLoadingLine(text: "Loading official vote history…")
                    case .unavailable:
                        Text("Official votes aren't available right now.")
                            .textRole(.body)
                            .foregroundStyle(BillboardColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    case .profile(let profile):
                        profileContent(profile: profile)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isShowingInfo ? 0 : 1)
                .modifier(AccessibilityHiddenWhile(isHidden: isShowingInfo))

                if isShowingInfo {
                    CivicProfileInfoOverlay {
                        isShowingInfo = false
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isShowingInfo)
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("member.civicProfile.card")
        // Reads your profile once for Compare to you, when the member's chart shows and no read has loaded it
        // or is running. Keyed on the member's chart alone: a key that included the store's state became true
        // again each time a failed read ended, so the card started another read at once, a loop of requests
        // for as long as the reads failed (offline, a timeout, a 5xx). A failed read shows "Couldn't load your
        // civic profile to compare"; the next visit to a member page reads again.
        .task(id: showsMemberChart) {
            guard showsMemberChart, !civicProfileStore.hasRefreshedOnce, !civicProfileStore.isLoading else { return }
            await civicProfileStore.refresh()
        }
    }

    /// The member's chart shows, so Compare to you may need your profile.
    private var showsMemberChart: Bool {
        guard case .profile(let profile) = mode else { return false }
        return profile.isReady
    }

    private func comparisonState(for memberProfile: CivicProfileResponse) -> ComparisonState {
        guard memberProfile.isReady else { return .hidden }

        if civicProfileStore.isLoading {
            return .loading
        }

        if civicProfileStore.profile.isReady {
            return .ready(civicProfileStore.profile)
        }

        if !civicProfileStore.hasRefreshedOnce {
            return civicProfileStore.lastError == nil ? .loading : .error
        }

        return .locked(votesRemaining: civicProfileStore.profile.votesRemaining)
    }

    @ViewBuilder
    private func profileContent(profile: CivicProfileResponse) -> some View {
        if profile.isReady {
            let comparisonState = comparisonState(for: profile)

            Text(CongressMemberCivicProfileCopy.evidenceSummary(profile))
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)

            if isShowingComparison, case .ready(let userProfile) = comparisonState {
                CongressMemberCivicProfileComparison(memberProfile: profile, userProfile: userProfile, memberName: memberName)
            } else {
                RadarChartView(profile: profile, scoreSubjectLabel: "Member")
                    .frame(maxWidth: 430)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Under the chart, alone or compared with yours (UX-37).
            CivicProfileAINote()

            buttons(showsCompare: comparisonState.isReady)

            if isShowingDetails {
                CivicProfileSignalDetails(profile: profile)
            }

            switch comparisonState {
            case .hidden, .ready:
                EmptyView()
            case .loading:
                CongressLoadingLine(text: "Loading your civic profile for comparison…")
                    .accessibilityIdentifier("member.civicProfile.comparison.loading")
            case .locked(let votesRemaining):
                Text("Vote on \(votesRemaining) more bill\(votesRemaining == 1 ? "" : "s") to compare yourself to this member.")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("member.civicProfile.comparison.locked")
            case .error:
                CivicProfileErrorLine(text: "Couldn't load your civic profile to compare. Try again later.")
                    .accessibilityIdentifier("member.civicProfile.comparison.error")
            }
        } else {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                Text(CongressMemberCivicProfileCopy.lockedHeadline(profile))
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(CongressMemberCivicProfileCopy.basisNote)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(CongressMemberCivicProfileCopy.lockedRemainingText(profile))
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    CivicProfileProgressBar(
                        progress: profile.weightedEvidenceRequirement > 0
                            ? profile.weightedEvidenceUsed / profile.weightedEvidenceRequirement
                            : 0
                    )
                    Text(CongressMemberCivicProfileCopy.progressText(profile))
                        .textRole(.docket)
                        .foregroundStyle(BillboardColors.dimText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                buttons(showsCompare: false)

                if isShowingDetails {
                    CivicProfileSignalDetails(profile: profile)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A container, so the controls inside keep their own ids.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("member.civicProfile.memberLocked")
        }
    }

    /// Details and Compare to you: secondary capsules side by side, or one under the other at
    /// accessibility sizes.
    @ViewBuilder
    private func buttons(showsCompare: Bool) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                detailToggleButton(fullWidth: true)
                if showsCompare { compareButton(fullWidth: true) }
            }
        } else {
            HStack(spacing: 10) {
                detailToggleButton(fullWidth: false)
                if showsCompare { compareButton(fullWidth: false) }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func compareButton(fullWidth: Bool) -> some View {
        Button(isShowingComparison ? "Member only" : "Compare to you") {
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingComparison.toggle()
            }
        }
        .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: fullWidth))
        .accessibilityIdentifier("member.civicProfile.compare")
        .accessibilityValue(isShowingComparison ? "member_only" : "compare_to_you")
    }

    private func detailToggleButton(fullWidth: Bool) -> some View {
        Button(isShowingDetails ? "Hide details" : "Details") {
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingDetails.toggle()
            }
        }
        .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: fullWidth))
        .accessibilityIdentifier("member.civicProfile.details")
        .accessibilityValue(isShowingDetails ? "shown" : "hidden")
    }
}

/// Compare to you on the member page (spec 3.27): the member solid and you dashed on one chart, the legend by line
/// style, what your chart is based on ("Your chart is based on 47 bill votes.", or "Your chart is based on your last
/// 100 bill votes." when your count is capped, as Profile says) and the scores by theme.
struct CongressMemberCivicProfileComparison: View {
    let memberProfile: CivicProfileResponse
    let userProfile: CivicProfileResponse
    let memberName: String

    var body: some View {
        let datasets = CongressMemberCivicProfileCard.comparisonDatasets(member: memberProfile, user: userProfile, memberName: memberName)
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            RadarChartView(datasets: datasets)
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity, alignment: .center)

            RadarLegend(datasets: datasets)

            Text(CongressMemberCivicProfileCopy.yourChartBasis(userProfile))
                .textRole(.caption)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)

            CivicProfileComparisonSummary(memberProfile: memberProfile, userProfile: userProfile)
        }
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("member.civicProfile.comparison")
    }
}

/// Hides a view from VoiceOver while `isHidden` and adds nothing otherwise. `.accessibilityHidden(false)`
/// is not neutral: it shows again what a view inside hid, so the radar's plot became an empty VoiceOver
/// stop between the theme labels.
private struct AccessibilityHiddenWhile: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        if isHidden {
            content.accessibilityHidden(true)
        } else {
            content
        }
    }
}

private enum ComparisonState {
    case hidden
    case loading
    case ready(CivicProfileResponse)
    case locked(votesRemaining: Int)
    case error

    /// Your chart has loaded, so Compare to you can show it.
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// An error in the Civic Profile section (spec 2.10): `exclamationmark.circle` in `danger` and the words.
private struct CivicProfileErrorLine: View {
    let text: String

    @ScaledMetric(relativeTo: .callout) private var glyphSize: CGFloat = 16

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
            Image(systemName: "exclamationmark.circle")
                .font(TextRole.Face.text.font(size: glyphSize, weight: .semibold))
                .foregroundStyle(BillboardColors.danger)
                .accessibilityHidden(true)
            Text(text)
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The locked chart's progress (spec 3.27): a 6 pt square-ended bar, `controlOn` on `well`. Decoration:
/// the figures line under it says how far along it is.
struct CivicProfileProgressBar: View {
    /// 0 to 1.
    let progress: Double

    static let height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(BillboardColors.secondaryBackground)
                Rectangle()
                    .fill(BillboardColors.controlOn)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

/// The chart's legend when two profiles are drawn (spec 3.27): a 16 pt sample of each line style and
/// its name in `caption` `ink2`, centred.
struct RadarLegend: View {
    let datasets: [RadarChartDataset]

    static let sampleWidth: CGFloat = 16

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(datasets.enumerated()), id: \.offset) { _, dataset in
                HStack(spacing: 6) {
                    LineSample(style: dataset.style)
                        .frame(width: Self.sampleWidth, height: 2)
                    Text(dataset.label)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dataset.style == .solid ? "\(dataset.label), solid line" : "\(dataset.label), dashed line")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private struct LineSample: View {
        let style: RadarChartDataset.Style

        var body: some View {
            Canvas { context, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                switch style {
                case .solid:
                    context.stroke(line, with: .color(BillboardColors.primaryText), lineWidth: RadarPlot.solidLineWidth)
                case .dashed:
                    context.stroke(
                        line,
                        with: .color(BillboardColors.secondaryText),
                        style: StrokeStyle(lineWidth: RadarPlot.dashedLineWidth, dash: RadarPlot.dash)
                    )
                }
            }
        }
    }
}

/// "Data behind this chart": how much data there is, each theme's status and the member's recent votes
/// and bills, as ruled rows on the document (no box).
private struct CivicProfileSignalDetails: View {
    let profile: CivicProfileResponse

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            HairlineRule()

            VStack(alignment: .leading, spacing: 4) {
                Text("Data behind this chart")
                    .textRole(.label)
                    .foregroundStyle(BillboardColors.dimText)
                    .accessibilityAddTraits(.isHeader)

                Text(CongressMemberCivicProfileCopy.readinessText(profile))
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(CivicProfileAxis.allCases.enumerated()), id: \.element) { index, axis in
                    if index > 0 {
                        DottedRule()
                    }
                    let coverage = profile.coverage(for: axis)
                    FigureRow(
                        label: "\(axis.lowLabel) / \(axis.highLabel)",
                        figure: CongressMemberCivicProfileCopy.themeStatus(
                            score: profile.displayScoreIfAvailable(for: axis),
                            coverage: coverage
                        ),
                        isDim: coverage?.isReady != true
                    )
                }
            }

            if !profile.evidence.isEmpty {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    Text("Recent votes and bills")
                        .textRole(.label)
                        .foregroundStyle(BillboardColors.dimText)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(Array(profile.evidence.prefix(6).enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            DottedRule()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title?.trimmedNonEmpty ?? item.billGuid)
                                .textRole(.body)
                                .foregroundStyle(BillboardColors.primaryText)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(CongressMemberCivicProfileCopy.evidenceLine(type: item.evidenceType, occurredAt: item.occurredAt))
                                .textRole(.docket)
                                .foregroundStyle(BillboardColors.dimText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        // A container, so the controls inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("member.civicProfile.details.panel")
    }
}

/// The "Scores by theme" table's head (spec 3.27): the title and the MEMBER and YOU column heads in the
/// `label` role, `ink3`. At accessibility sizes the column heads go (each row says them) and the title
/// wraps, never truncates (spec 2.5, 7.2).
struct CivicProfileScoresHead: View {
    let columnWidth: CGFloat

    static let title = "Scores by theme"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
            Text(Self.title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Member")
                    .frame(width: columnWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Text("You")
                    .frame(width: columnWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .textRole(.label)
        .foregroundStyle(BillboardColors.dimText)
    }
}

/// "Scores by theme" beside your chart (spec 3.27): column heads MEMBER and YOU in the `label` role,
/// then one row per theme, the theme in `body` and the scores in the `figure` face, right-aligned,
/// dotted rules between rows. A theme without enough data shows a dash, and VoiceOver says "not enough
/// data". At accessibility sizes the scores go under the theme in words.
struct CivicProfileComparisonSummary: View {
    let memberProfile: CivicProfileResponse
    let userProfile: CivicProfileResponse

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var columnWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CivicProfileScoresHead(columnWidth: columnWidth)
                .padding(.bottom, BillboardStyle.Space.s)

            HeavyRule(width: 1.5)

            ForEach(Array(CivicProfileAxis.allCases.enumerated()), id: \.element) { index, axis in
                if index > 0 {
                    DottedRule()
                }
                row(axis)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func row(_ axis: CivicProfileAxis) -> some View {
        let theme = "\(axis.lowLabel) / \(axis.highLabel)"
        let member = memberProfile.displayScoreIfAvailable(for: axis)
        let user = userProfile.displayScoreIfAvailable(for: axis)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(theme)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.primaryText)
                    Text(Self.accessibilitySizeScores(member: member, user: user))
                        .textRole(.figure)
                        .foregroundStyle(BillboardColors.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                    Text(theme)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    figure(member)
                    figure(user)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme): Member \(Self.spoken(member)), You \(Self.spoken(user))")
    }

    private func figure(_ score: Int?) -> some View {
        Text(Self.printed(score))
            .textRole(.figure)
            .foregroundStyle(score == nil ? BillboardColors.dimText : BillboardColors.primaryText)
            .frame(width: columnWidth, alignment: .trailing)
    }

    static func printed(_ score: Int?) -> String {
        score.map(String.init) ?? "–"
    }

    /// The scores under a theme at accessibility sizes, "Member 7 · You 6", with no-break spaces inside
    /// "Member 7" and "You 6" and before the dot, so the line can break only after the dot.
    static func accessibilitySizeScores(member: Int?, user: Int?) -> String {
        "Member\u{00A0}\(printed(member))\u{00A0}· You\u{00A0}\(printed(user))"
    }

    static func spoken(_ score: Int?) -> String {
        score.map(String.init) ?? CongressMemberCivicProfileCopy.notEnoughData.lowercased()
    }
}

/// The member civic profile card's copy (spec D 2.4.2, glossary 2.4.1): "theme" for an axis,
/// "votes and bills" for evidence, and no weights, so a reader never sees "signal" or "weighted
/// evidence".
enum CongressMemberCivicProfileCopy {
    /// Shown when the chart is locked: "Based on official votes (counted most) and the bills
    /// they sponsor or cosponsor."
    static let basisNote = "Based on official votes (counted most) and the bills they sponsor or cosponsor."

    /// "This chart appears once the member has enough votes and bills on 3 themes."
    static func lockedHeadline(_ profile: CivicProfileResponse) -> String {
        let themes = max(profile.axesRequirement, 3)
        return "This chart appears once the member has enough votes and bills on \(themes) themes."
    }

    /// "Based on 12 votes, 3 sponsored and 4 cosponsored bills".
    static func evidenceSummary(_ profile: CivicProfileResponse) -> String {
        let sponsored = profile.sponsoredBillsUsed ?? 0
        let cosponsored = profile.cosponsoredBillsUsed ?? 0
        return "Based on \(profile.votesUsed) votes, \(sponsored) sponsored and \(cosponsored) cosponsored bills"
    }

    /// Under your chart in Compare to you: "Your chart is based on 47 bill votes.", or "Your chart is based on your
    /// last 100 bill votes." when your count is capped, by the same test as Profile's "Based on your last 100 votes"
    /// (`CivicProfileCopy.isCapped`).
    static func yourChartBasis(_ profile: CivicProfileResponse) -> String {
        if CivicProfileCopy.isCapped(profile) {
            return "Your chart is based on your last \(profile.votesUsed) bill votes."
        }
        return "Your chart is based on \(profile.votesUsed) bill vote\(profile.votesUsed == 1 ? "" : "s")."
    }

    /// "Needs more votes or bills on 2 more themes." or "Needs more votes or bills."
    static func lockedRemainingText(_ profile: CivicProfileResponse) -> String {
        let themesRemaining = max(0, profile.axesRequirement - profile.axesWithSufficientSignal)
        if themesRemaining > 0 {
            return "Needs more votes or bills on \(themesRemaining) more \(themesRemaining == 1 ? "theme" : "themes")."
        }
        return "Needs more votes or bills."
    }

    /// Under the progress bar: "12 of 25 needed".
    static func progressText(_ profile: CivicProfileResponse) -> String {
        "\(formatNumber(profile.weightedEvidenceUsed)) of \(formatNumber(profile.weightedEvidenceRequirement)) needed"
    }

    /// The first line of "Data behind this chart".
    static func readinessText(_ profile: CivicProfileResponse) -> String {
        guard let diagnostics = profile.diagnostics else {
            return "\(profile.evidenceUsed) of \(profile.evidenceRequirement) votes and bills available."
        }
        let used = formatNumber(diagnostics.weightedEvidenceUsed)
        let required = formatNumber(diagnostics.minWeightedEvidenceRequired)
        return "\(used) of \(required) needed · \(diagnostics.axesWithSufficientSignal) of \(diagnostics.minAxesRequired) themes ready"
    }

    /// A theme's status: its score ("7/10"), "Enough data" when ready without a score, or
    /// "Not enough data".
    static func themeStatus(score: Int?, coverage: CivicProfileAxisCoverage?) -> String {
        guard let coverage, coverage.isReady else { return notEnoughData }
        if let score { return "\(score)/10" }
        return "Enough data"
    }

    /// A score in the comparison list, or "Not enough data".
    static func scoreText(_ score: Int?) -> String {
        score.map { "\($0)" } ?? notEnoughData
    }

    static let notEnoughData = "Not enough data"

    /// "Voted Yea · Mar 3, 2026".
    static func evidenceLine(type: String, occurredAt: String) -> String {
        "\(evidenceLabel(type)) · \(shortDate(occurredAt))"
    }

    static func evidenceLabel(_ value: String) -> String {
        switch value {
        case "voteYea": return "Voted Yea"
        case "voteNay": return "Voted Nay"
        case "sponsor": return "Sponsor"
        case "cosponsor": return "Cosponsor"
        default: return value
        }
    }

    private static func shortDate(_ value: String) -> String {
        guard let date = FlexibleISO8601.parse(value) else { return value }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    /// Whole numbers without decimals, otherwise one decimal.
    static func formatNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.000_001 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}

#Preview {
    CongressMemberCivicProfileCard(
        mode: .profile(
            CivicProfileResponse(
                axes: [
                    "individualVsCommunity": 0.7,
                    "localVsFederal": 0.4,
                    "freeMarketVsRegulated": 0.6,
                    "traditionalVsProgressive": 0.5,
                    "interventionistVsRestrained": 0.3,
                    "privacyVsSecurity": 0.8,
                ],
                votesUsed: 33,
                totalVotesWithProfile: 50,
                minVotesRequired: 25,
                isReady: true
            )
        )
    )
    .padding()
    .environmentObject(CivicProfileStore())
}
