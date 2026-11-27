import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// UX-40 L4: the Civic Profile's six diverging theme bars (Civic Record spec 3.27, approved sample of 2026-11-23,
/// decisions D29 to D31). The bars' geometry at the ends, at the middle and either side of it; the approved words;
/// what VoiceOver reads on Profile and on a member page's Compare to you, as in the approved sample's transcript; and
/// renders at the default text size, AX3 and AX5, light and dark.
@MainActor
final class ThemeBarsTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String {
            let sizeName: String
            switch size {
            case .large: sizeName = "default"
            case .accessibility3: sizeName = "AX3"
            case .accessibility5: sizeName = "AX5"
            default: sizeName = "\(size)"
            }
            return "\(scheme == .dark ? "dark" : "light")-\(sizeName)"
        }

        /// AX5 is drawn on the narrowest phone Billboard supports.
        var width: CGFloat {
            size == .accessibility5 ? 375 : 390
        }
    }

    private static let variants: [Variant] = [ColorScheme.light, .dark].flatMap { scheme in
        [DynamicTypeSize.large, .accessibility3, .accessibility5].map { Variant(scheme: scheme, size: $0) }
    }

    // MARK: - Fixtures (the approved sample's)

    private static func axes(_ values: [Double?]) -> [String: Double] {
        var axes: [String: Double] = [:]
        for (axis, value) in zip(CivicProfileAxis.allCases, values) {
            if let value { axes[axis.rawValue] = value }
        }
        return axes
    }

    private static func counts(_ values: [Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(CivicProfileAxis.allCases.map(\.rawValue), values))
    }

    /// 47 votes; every theme past the 8-vote floor. Scores 7, 4, 7, 6, 5, 3: the 5 (0.45) draws a short bar to the
    /// left of the middle, the 6 (0.56) one to the right.
    private static let you = CivicProfileResponse(
        axes: axes([0.66, 0.37, 0.71, 0.56, 0.45, 0.21]),
        votesUsed: 47,
        totalVotesWithProfile: 47,
        minVotesRequired: 25,
        isReady: true,
        themesReady: 6,
        minThemesRequired: 3,
        minThemeVotes: 8,
        themeVotes: counts([31, 18, 26, 22, 11, 9])
    )

    /// 29 votes: Restrained / Intervene has only the floor's 8 votes and a long bar (9/10), and Privacy / Security has
    /// 3 votes, short of the floor, so no score.
    private static let youFewVotes = CivicProfileResponse(
        axes: axes([0.62, 0.48, 0.58, 0.41, 0.92, nil]),
        votesUsed: 29,
        totalVotesWithProfile: 29,
        minVotesRequired: 25,
        isReady: true,
        themesReady: 5,
        minThemesRequired: 3,
        minThemeVotes: 8,
        themeVotes: counts([19, 14, 17, 12, 8, 3])
    )

    /// A server without `themeVotes` (before it, or after a rollback): the same scores, no count line.
    private static let youWithoutCounts = CivicProfileResponse(
        axes: axes([0.66, 0.37, 0.71, 0.56, 0.45, nil]),
        votesUsed: 47,
        totalVotesWithProfile: 47,
        minVotesRequired: 25,
        isReady: true
    )

    private static let memberName = "Jordan Ellis"

    /// A fictional member: 33 votes, 3 sponsored and 4 cosponsored bills; scores 7, 5, 7, 6, 4, 8 and the votes and
    /// bills behind each theme.
    private static let member: CivicProfileResponse = {
        let evidence = [24, 15, 21, 17, 9, 12]
        let coverage = Dictionary(uniqueKeysWithValues: zip(CivicProfileAxis.allCases.map(\.rawValue), evidence).map { key, count in
            (key, CivicProfileAxisCoverage(evidenceCount: count, weightedEvidence: Double(count) * 0.8, isReady: true))
        })
        let diagnostics = CivicProfileDiagnostics(
            rollingWindow: 100,
            evidenceWeights: CivicProfileEvidenceWeights(voteYea: 1, voteNay: 1, sponsor: 0.5, cosponsor: 0.25),
            weightedEvidenceUsed: 35.5,
            totalWeightedEvidenceWithProfile: 52,
            minWeightedEvidenceRequired: 25,
            minAxisWeightedEvidenceRequired: 6,
            minAxesRequired: 3,
            axesWithSufficientSignal: 6,
            axisCoverage: coverage,
            readinessReasons: [],
            latestEvidenceAt: "2026-11-18T15:00:00Z"
        )
        return CivicProfileResponse(
            axes: axes([0.7, 0.4, 0.62, 0.56, 0.34, 0.82]),
            votesUsed: 33,
            totalVotesWithProfile: 50,
            sponsoredBillsUsed: 3,
            cosponsoredBillsUsed: 4,
            totalEvidenceUsed: 40,
            totalEvidenceWithProfile: 57,
            minEvidenceRequired: 25,
            minVotesRequired: 25,
            isReady: true,
            diagnostics: diagnostics
        )
    }()

    private static func profile(_ axis: CivicProfileAxis, _ value: Double) -> CivicProfileResponse {
        CivicProfileResponse(axes: [axis.rawValue: value], votesUsed: 30, totalVotesWithProfile: 30, minVotesRequired: 25, isReady: true)
    }

    // MARK: - Geometry

    /// A value's place on the track and its bar, from the middle to the value either way, at the ends, either side of
    /// the middle where a 5 and a 6 start (0.389 and 0.611), and at exactly halfway, where there is no bar. Values
    /// outside 0 to 1 are clamped to the ends.
    func testABarRunsFromTheMiddleToTheValue() {
        let cases: [(value: Double, x: CGFloat, left: CGFloat, right: CGFloat)] = [
            (0, 0, 0, 50),
            (0.389, 38.9, 38.9, 50),
            (0.5, 50, 50, 50),
            (0.611, 61.1, 50, 61.1),
            (1, 100, 50, 100),
            (-0.4, 0, 0, 50),
            (1.4, 100, 50, 100)
        ]
        for item in cases {
            XCTAssertEqual(ThemeBarTrack.x(for: item.value, minX: 0, maxX: 100), item.x, accuracy: 0.000_1, "x at \(item.value)")
            let edges = ThemeBarTrack.barEdges(value: item.value, minX: 0, maxX: 100)
            XCTAssertEqual(edges.left, item.left, accuracy: 0.000_1, "left edge at \(item.value)")
            XCTAssertEqual(edges.right, item.right, accuracy: 0.000_1, "right edge at \(item.value)")
        }
        // The track can start past 0.
        XCTAssertEqual(ThemeBarTrack.x(for: 0.25, minX: 1, maxX: 201), 51, accuracy: 0.000_1)
        XCTAssertEqual(ThemeBarTrack.barEdges(value: 0.25, minX: 1, maxX: 201).right, 101, accuracy: 0.000_1, "the middle")
    }

    /// The bars as drawn: one profile's 12 pt bar centred on the track, two profiles' 7 pt bars either side of it.
    /// A profile without a score draws no bar, and so does a score at exactly halfway; a theme where no profile has
    /// a score has a dashed track.
    func testWhereTheBarsAreDrawn() throws {
        let size = CGSize(width: 202, height: ThemeBarTrack.height(profileCount: 1))
        XCTAssertEqual(size.height, 20, "a 12 pt bar and the middle tick's 4 pt above and below")

        let single = ThemeBarTrack.barRects(for: [ThemeBarTrack.Mark(value: 0.75, style: .solid)], in: size)
        let bar = try XCTUnwrap(single.first ?? nil)
        XCTAssertEqual(bar.minX, 101, accuracy: 0.000_1, "from the middle")
        XCTAssertEqual(bar.maxX, 151, accuracy: 0.000_1, "to three quarters of the track")
        XCTAssertEqual(bar.height, ThemeBarTrack.barHeight)
        XCTAssertEqual(bar.midY, size.height / 2, accuracy: 0.000_1, "centred on the track")

        let left = try XCTUnwrap(ThemeBarTrack.barRects(for: [ThemeBarTrack.Mark(value: 0.25, style: .solid)], in: size).first ?? nil)
        XCTAssertEqual(left.minX, 51, accuracy: 0.000_1, "a score below halfway is a bar to the left")
        XCTAssertEqual(left.maxX, 101, accuracy: 0.000_1)

        XCTAssertEqual(ThemeBarTrack.barRects(for: [ThemeBarTrack.Mark(value: 0.5, style: .solid)], in: size), [nil], "no bar at exactly halfway")
        XCTAssertEqual(ThemeBarTrack.barRects(for: [nil], in: size), [nil], "no bar without a score")
        XCTAssertTrue(ThemeBarTrack(marks: [nil]).isEmpty, "a dashed track without a score")
        XCTAssertTrue(ThemeBarTrack(marks: [nil, nil]).isEmpty)
        XCTAssertFalse(ThemeBarTrack(marks: [ThemeBarTrack.Mark(value: 0.5, style: .solid)]).isEmpty, "halfway is a score: a solid track")

        let compareSize = CGSize(width: 202, height: ThemeBarTrack.height(profileCount: 2))
        XCTAssertEqual(compareSize.height, 25, "two 7 pt bars, the 3 pt gap and the overhang")
        let compare = ThemeBarTrack.barRects(
            for: [ThemeBarTrack.Mark(value: 0.75, style: .solid), ThemeBarTrack.Mark(value: 0.25, style: .dashed)],
            in: compareSize
        )
        let memberBar = try XCTUnwrap(compare[0])
        let yourBar = try XCTUnwrap(compare[1])
        XCTAssertEqual(memberBar.height, ThemeBarTrack.thinBarHeight)
        XCTAssertEqual(yourBar.height, ThemeBarTrack.thinBarHeight)
        XCTAssertEqual(memberBar.maxY + ThemeBarTrack.barGap, yourBar.minY, accuracy: 0.000_1, "the first above the track, the second under it")
        XCTAssertEqual(yourBar.maxX, 101, accuracy: 0.000_1)

        let oneMissing = ThemeBarTrack.barRects(for: [ThemeBarTrack.Mark(value: 0.75, style: .solid), nil], in: compareSize)
        XCTAssertNotNil(oneMissing[0])
        XCTAssertNil(oneMissing[1], "no bar for the profile without a score")
        XCTAssertFalse(ThemeBarTrack(marks: [ThemeBarTrack.Mark(value: 0.75, style: .solid), nil]).isEmpty)
    }

    // MARK: - Words (D31)

    func testTheApprovedWords() {
        XCTAssertEqual(ThemeBarsCopy.votes(12), "12 votes")
        XCTAssertEqual(ThemeBarsCopy.votes(1), "1 vote")
        XCTAssertEqual(ThemeBarsCopy.votes(0), "0 votes")
        XCTAssertEqual(ThemeBarsCopy.votesAndBills(9), "9 votes and bills")
        XCTAssertEqual(ThemeBarsCopy.votesAndBills(1), "1 vote or bill")
        XCTAssertEqual(ThemeBarsCopy.count(12, isMember: false), "12 votes")
        XCTAssertEqual(ThemeBarsCopy.count(9, isMember: true), "9 votes and bills")

        XCTAssertEqual(ThemeBarsCopy.scoreText(subjectLabel: "You", score: 7), "You: 7/10")
        XCTAssertEqual(ThemeBarsCopy.scoreText(subjectLabel: "Member", score: 7), "Member: 7/10")
        XCTAssertEqual(ThemeBarsCopy.notEnoughData, "Not enough data")

        let shortfall = ThemeBarsCopy.shortfall(count: 5, floor: 8, isMember: false)
        XCTAssertEqual(shortfall, "5 of 8 votes")
        XCTAssertEqual(ThemeBarsCopy.notEnoughDataLine(shortfall: shortfall), "Not enough data · 5 of 8 votes")
        XCTAssertEqual(ThemeBarsCopy.notEnoughDataLine(shortfall: nil), "Not enough data")
        XCTAssertNil(ThemeBarsCopy.shortfall(count: 5, floor: 8, isMember: true), "a member's line is Not enough data alone")
        XCTAssertNil(ThemeBarsCopy.shortfall(count: nil, floor: 8, isMember: false), "no count from the server")
        XCTAssertNil(ThemeBarsCopy.shortfall(count: 5, floor: nil, isMember: false), "no floor from the server")
        XCTAssertNil(ThemeBarsCopy.shortfall(count: 9, floor: 8, isMember: false), "never more than the floor")
        XCTAssertEqual(ThemeBarsCopy.shortfall(count: 0, floor: 1, isMember: false), "0 of 1 vote")

        XCTAssertEqual(ThemeBarsCopy.missingInCompare(subjectLabel: "You"), "You: Not enough data")
        XCTAssertEqual(ThemeBarsCopy.spokenLegendSample(ThemeChartDataset(profile: .empty, label: Self.memberName, style: .solid)), "Jordan Ellis, solid bar")
        XCTAssertEqual(ThemeBarsCopy.spokenLegendSample(ThemeChartDataset(profile: .empty, label: "You", style: .dashed)), "You, dashed bar")

        for text in [ThemeBarsCopy.votes(2), ThemeBarsCopy.votesAndBills(2), ThemeBarsCopy.notEnoughDataLine(shortfall: shortfall)] {
            for banned in ["axis", "axes", "lean", "signal", "spoke"] {
                XCTAssertNil(text.range(of: "\\b\(banned)\\b", options: [.regularExpression, .caseInsensitive]), "\"\(text)\" uses \(banned)")
            }
        }
    }

    /// The direction is said only to VoiceOver (D29) and comes from the value, as the bar is drawn: exactly halfway
    /// is "in the middle", and a displayed 5 just under halfway is toward the left-hand word.
    func testTheDirectionInWords() {
        XCTAssertEqual(ThemeBarsCopy.direction(.individualVsCommunity, value: 0.66), "toward Community")
        XCTAssertEqual(ThemeBarsCopy.direction(.individualVsCommunity, value: 0.2), "toward Individual")
        XCTAssertEqual(ThemeBarsCopy.direction(.individualVsCommunity, value: 0.5), "in the middle")

        for value in [0.389, 0.45, 0.499] {
            let fiveBelow = Self.profile(.interventionistVsRestrained, value)
            XCTAssertEqual(fiveBelow.displayScoreIfAvailable(for: .interventionistVsRestrained), 5, "\(value) shows as 5")
            XCTAssertEqual(
                ThemeBarsCopy.spokenSingle(.interventionistVsRestrained, dataset: ThemeChartDataset(profile: fiveBelow, label: "You"), count: nil, shortfall: nil),
                "Restrained to Intervene. You: 5/10, toward Restrained.",
                "\(value)"
            )
        }
        XCTAssertEqual(
            ThemeBarsCopy.spokenSingle(.individualVsCommunity, dataset: ThemeChartDataset(profile: Self.profile(.individualVsCommunity, 0.5), label: "You"), count: "12 votes", shortfall: nil),
            "Individual to Community. You: 5/10, in the middle. 12 votes."
        )
        XCTAssertEqual(
            ThemeBarsCopy.spokenSingle(.individualVsCommunity, dataset: ThemeChartDataset(profile: Self.profile(.individualVsCommunity, 0.611), label: "You"), count: nil, shortfall: nil),
            "Individual to Community. You: 6/10, toward Community."
        )
    }

    // MARK: - VoiceOver (the approved sample's voiceover.txt)

    /// "Profile: Your Civic Profile" in the approved sample.
    private static let spokenProfile = [
        "Your Civic Profile",
        "About the civic profile chart",
        "Based on 47 votes",
        "Individual to Community. You: 7/10, toward Community. 31 votes.",
        "Local to Federal. You: 4/10, toward Local. 18 votes.",
        "Free Market to Regulated. You: 7/10, toward Regulated. 26 votes.",
        "Keep as is to Change. You: 6/10, toward Change. 22 votes.",
        "Restrained to Intervene. You: 5/10, toward Restrained. 11 votes.",
        "Privacy to Security. You: 3/10, toward Privacy. 9 votes.",
        "Theme scores come from AI ratings of each bill."
    ]

    /// "Member page: Compare to you" in the approved sample.
    private static let spokenCompare = [
        "Civic Profile",
        "About the civic profile chart",
        "Based on 33 votes, 3 sponsored and 4 cosponsored bills",
        "Individual to Community. Jordan Ellis: 7/10, toward Community. You: 7/10, toward Community.",
        "Local to Federal. Jordan Ellis: 5/10, toward Local. You: 4/10, toward Local.",
        "Free Market to Regulated. Jordan Ellis: 7/10, toward Regulated. You: 7/10, toward Regulated.",
        "Keep as is to Change. Jordan Ellis: 6/10, toward Change. You: 6/10, toward Change.",
        "Restrained to Intervene. Jordan Ellis: 4/10, toward Restrained. You: 5/10, toward Restrained.",
        "Privacy to Security. Jordan Ellis: 8/10, toward Security. You: 3/10, toward Privacy.",
        "Jordan Ellis, solid bar",
        "You, dashed bar",
        "Your chart is based on 47 bill votes.",
        "Scores by theme",
        "Individual / Community: Member 7, You 7",
        "Local / Federal: Member 5, You 4",
        "Free Market / Regulated: Member 7, You 7",
        "Keep as is / Change: Member 6, You 6",
        "Restrained / Intervene: Member 4, You 5",
        "Privacy / Security: Member 8, You 3",
        "Theme scores come from AI ratings of each bill.",
        "Details",
        "Member only"
    ]

    /// "Profile: a theme with very few votes" in the approved sample.
    private static let spokenFewVotes = [
        "Your Civic Profile",
        "About the civic profile chart",
        "Based on 29 votes",
        "Individual to Community. You: 7/10, toward Community. 19 votes.",
        "Local to Federal. You: 5/10, toward Local. 14 votes.",
        "Free Market to Regulated. You: 6/10, toward Regulated. 17 votes.",
        "Keep as is to Change. You: 5/10, toward Keep as is. 12 votes.",
        "Restrained to Intervene. You: 9/10, toward Intervene. 8 votes.",
        "Privacy to Security. Not enough data. 3 of 8 votes.",
        "Theme scores come from AI ratings of each bill.",
        "Some themes need more votes before they get a score."
    ]

    /// Each theme's words on their own, from the copy functions.
    func testTheSpokenThemesMatchTheApprovedSample() {
        let you = ThemeChartDataset(profile: Self.you, label: "You")
        let few = ThemeChartDataset(profile: Self.youFewVotes, label: "You")
        let profileLines = CivicProfileAxis.allCases.map { axis in
            ThemeBarsCopy.spokenSingle(axis, dataset: you, count: Self.you.themeCount(for: axis).map(ThemeBarsCopy.votes), shortfall: nil)
        }
        XCTAssertEqual(profileLines, Array(Self.spokenProfile[3...8]))

        let fewLines = CivicProfileAxis.allCases.map { axis in
            ThemeBarsCopy.spokenSingle(
                axis,
                dataset: few,
                count: Self.youFewVotes.themeCount(for: axis).map(ThemeBarsCopy.votes),
                shortfall: ThemeBarsCopy.shortfall(count: Self.youFewVotes.themeCount(for: axis), floor: 8, isMember: false)
            )
        }
        XCTAssertEqual(fewLines, Array(Self.spokenFewVotes[3...8]))

        let datasets = CongressMemberCivicProfileCard.comparisonDatasets(member: Self.member, user: Self.you, memberName: Self.memberName)
        let compareLines = CivicProfileAxis.allCases.map { ThemeBarsCopy.spokenCompare($0, datasets: datasets) }
        XCTAssertEqual(compareLines, Array(Self.spokenCompare[3...8]))
    }

    /// What VoiceOver reads on Profile, in order, is the approved sample's transcript, with one theme short of votes
    /// too.
    func testProfileReadsAsTheApprovedSample() {
        for (profile, expected) in [(Self.you, Self.spokenProfile), (Self.youFewVotes, Self.spokenFewVotes)] {
            let host = AccessibilityTreeText.Host(
                CivicProfileCard(profile: profile, isLoading: false).padding(16),
                size: CGSize(width: 390, height: 2000),
                settle: 0.2
            )
            let spoken = host.elements().map(\.label).filter { !$0.isEmpty }
            host.close()
            XCTAssertEqual(spoken, expected)
        }
    }

    /// What VoiceOver reads on a member page after Compare to you, in order, is the approved sample's transcript.
    func testCompareToYouReadsAsTheApprovedSample() async throws {
        let service = FakeCivicService()
        service.profileResult = .success(Self.you)
        let store = CivicProfileStore(service: service)
        await store.refresh()
        XCTAssertTrue(store.profile.isReady, "your profile is loaded for Compare to you")

        let host = AccessibilityTreeText.Host(
            ScrollView {
                CongressMemberCivicProfileCard(mode: .profile(Self.member), memberName: Self.memberName)
                    .environmentObject(store)
            },
            size: CGSize(width: 390, height: 3000),
            settle: 0.3
        )
        defer { host.close() }
        XCTAssertTrue(host.activate("Compare to you", settle: 1), "tapped Compare to you")
        XCTAssertEqual(host.elements().map(\.label).filter { !$0.isEmpty }, Self.spokenCompare)
    }

    /// What each row shows under its bar on Profile and on a member page, as in the approved sample: the score and
    /// its count, and for a theme short of votes how far short it is. VoiceOver reads each row as one element, so
    /// these words come from the rows the view draws, not from the accessibility tree.
    func testTheRowsShowTheScoreAndCount() {
        XCTAssertEqual(ThemeBarsView(profile: Self.you).rows.map(\.figures.lines), [
            ["You: 7/10 · 31 votes"],
            ["You: 4/10 · 18 votes"],
            ["You: 7/10 · 26 votes"],
            ["You: 6/10 · 22 votes"],
            ["You: 5/10 · 11 votes"],
            ["You: 3/10 · 9 votes"]
        ])
        XCTAssertEqual(ThemeBarsView(profile: Self.you).rows.first?.figures, .score("You: 7/10", count: "31 votes"))

        let few = ThemeBarsView(profile: Self.youFewVotes).rows
        XCTAssertEqual(few.map(\.figures.lines), [
            ["You: 7/10 · 19 votes"],
            ["You: 5/10 · 14 votes"],
            ["You: 6/10 · 17 votes"],
            ["You: 5/10 · 12 votes"],
            ["You: 9/10 · 8 votes"],
            ["Not enough data · 3 of 8 votes"]
        ])
        XCTAssertEqual(few.last?.marks, [nil], "no bar without a score")

        let member = ThemeBarsView(profile: Self.member, scoreSubjectLabel: "Member").rows
        XCTAssertEqual(member.map(\.figures.lines), [
            ["Member: 7/10 · 24 votes and bills"],
            ["Member: 5/10 · 15 votes and bills"],
            ["Member: 7/10 · 21 votes and bills"],
            ["Member: 6/10 · 17 votes and bills"],
            ["Member: 4/10 · 9 votes and bills"],
            ["Member: 8/10 · 12 votes and bills"]
        ])
        XCTAssertEqual(member.first?.spokenText, "Individual to Community. Member: 7/10, toward Community. 24 votes and bills.")
    }

    /// From a server without the counts the rows show no count line and VoiceOver reads no count, and a theme
    /// without a score says only "Not enough data"; the scores are unchanged.
    func testWithoutCountsTheCountLineIsHidden() {
        let rows = ThemeBarsView(profile: Self.youWithoutCounts).rows
        XCTAssertEqual(rows.map(\.figures.lines), [["You: 7/10"], ["You: 4/10"], ["You: 7/10"], ["You: 6/10"], ["You: 5/10"], ["Not enough data"]])
        XCTAssertEqual(rows.first?.figures, .score("You: 7/10", count: nil), "no count line")

        let host = AccessibilityTreeText.Host(ThemeBarsView(profile: Self.youWithoutCounts).padding(16), size: CGSize(width: 390, height: 1400))
        let spoken = host.elements().map(\.label).filter { !$0.isEmpty }
        let strings = host.strings()
        host.close()
        XCTAssertEqual(spoken, [
            "Individual to Community. You: 7/10, toward Community.",
            "Local to Federal. You: 4/10, toward Local.",
            "Free Market to Regulated. You: 7/10, toward Regulated.",
            "Keep as is to Change. You: 6/10, toward Change.",
            "Restrained to Intervene. You: 5/10, toward Restrained.",
            "Privacy to Security. Not enough data."
        ])
        XCTAssertFalse(strings.contains { $0.contains("vote") }, "\(strings)")
    }

    /// In Compare to you, a theme where only one profile has a score says which one has none, in the row's words
    /// and to VoiceOver, so its missing bar is not read as the middle; a theme where neither has one says Not enough
    /// data; and a theme where both have one shows no words, the scores being in the table.
    func testCompareSaysWhichProfileHasNoScore() throws {
        let datasets = CongressMemberCivicProfileCard.comparisonDatasets(member: Self.member, user: Self.youWithoutCounts, memberName: Self.memberName)
        XCTAssertEqual(
            ThemeBarsCopy.spokenCompare(.privacyVsSecurity, datasets: datasets),
            "Privacy to Security. Jordan Ellis: 8/10, toward Security. You: not enough data."
        )
        let rows = ThemeBarsView(datasets: datasets).rows
        XCTAssertEqual(rows.map(\.figures.lines), [[], [], [], [], [], ["You: Not enough data"]])
        XCTAssertEqual(rows.last?.marks, [ThemeBarTrack.Mark(value: 0.82, style: .solid), nil], "only the member's bar")
        let text = AccessibilityTreeText.text(of: ThemeBarsView(datasets: datasets).padding(16), size: CGSize(width: 390, height: 1400))
        XCTAssertTrue(text.contains("Privacy to Security. Jordan Ellis: 8/10, toward Security. You: not enough data."), text)

        let neither = CongressMemberCivicProfileCard.comparisonDatasets(
            member: Self.profile(.individualVsCommunity, 0.7),
            user: Self.youWithoutCounts,
            memberName: Self.memberName
        )
        let privacy = try XCTUnwrap(ThemeBarsView(datasets: neither).rows.last)
        XCTAssertEqual(privacy.figures.lines, ["Not enough data"])
        XCTAssertEqual(privacy.marks, [nil, nil], "no bar, and a dashed track")
        XCTAssertEqual(privacy.spokenText, "Privacy to Security. Jordan Ellis: not enough data. You: not enough data.")
        XCTAssertEqual(ThemeBarsCopy.missingLines(.individualVsCommunity, datasets: neither), [], "both have a score")
        XCTAssertEqual(ThemeBarsCopy.missingLines(.localVsFederal, datasets: neither), ["Jordan Ellis: Not enough data"])
    }

    // MARK: - Renders

    /// One profile (yours, and a member's with its votes and bills), one theme short of votes, and Compare to you
    /// with its legend, light and dark, at the default size, AX3 and AX5 (on a 375 pt phone).
    func testTheBarsRenderInEveryVariant() throws {
        let compare = CongressMemberCivicProfileCard.comparisonDatasets(member: Self.member, user: Self.youFewVotes, memberName: Self.memberName)
        let samples: [(name: String, view: AnyView)] = [
            ("you", AnyView(ThemeBarsView(profile: Self.you, scoreSubjectLabel: "You"))),
            ("member", AnyView(ThemeBarsView(profile: Self.member, scoreSubjectLabel: "Member"))),
            ("few-votes", AnyView(ThemeBarsView(profile: Self.youFewVotes, scoreSubjectLabel: "You"))),
            ("compare", AnyView(VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                ThemeBarsView(datasets: compare)
                ThemeBarsLegend(datasets: compare)
            }))
        ]
        for variant in Self.variants {
            var heights: [String: Int] = [:]
            for sample in samples {
                let image = try render(sample.view.padding(16).background(BillboardColors.document), variant: variant)
                attach(image, name: "theme-bars-\(sample.name)-\(variant.name)")
                heights[sample.name] = image.height
                // Six rows, each with its words, track and figures: well over 6 x 44 pt at 2x.
                XCTAssertGreaterThan(image.height, 6 * 44 * 2, "\(sample.name) \(variant.name)")
                XCTAssertFalse(try isOneColour(image), "\(sample.name) \(variant.name) has content")
            }
            if variant.size == .accessibility5, let atAX5 = heights["you"] {
                let atDefault = try render(samples[0].view.padding(16), variant: Variant(scheme: variant.scheme, size: .large))
                XCTAssertGreaterThan(atAX5, atDefault.height, "nothing shrinks at AX5: the rows grow")
            }
        }
    }

    // MARK: - Helpers

    private func render<Content: View>(_ view: Content, variant: Variant) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: variant.width)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: variant.width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    /// Whether every pixel is the same colour (a failed drawing is one colour).
    private func isOneColour(_ image: CGImage) throws -> Bool {
        let width = image.width
        let height = image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        guard bytes.count >= 4 else { return true }
        let first = Array(bytes[0..<4])
        return !stride(from: 4, to: bytes.count, by: 4).contains { Array(bytes[$0..<($0 + 4)]) != first }
    }
}
