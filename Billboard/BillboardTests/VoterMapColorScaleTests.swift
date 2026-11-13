import XCTest
import SwiftUI
@testable import Billboard

/// The vote map's colours (spec D 2.3.5; Civic Record spec 3.9, 4.43): a CIELAB ramp from voteNay through
/// mapNeutral to voteYea, 21 stops per appearance, and a hatch (never a flat grey) under the floor. Civic
/// Record moves the 50/50 neutral to #BFC5CF / #4A5570, so the ramp's middle, its lightness and its
/// colour-blind separation are checked again here.
@MainActor
final class VoterMapColorScaleTests: XCTestCase {
    private func stat(yeaPct: Double?, decisionVotes: Int) -> VoterMapRegionStat {
        VoterMapRegionStat(id: "CA", label: "CA", yeaPct: yeaPct, decisionVotes: decisionVotes)
    }

    private func assertSame(_ a: BillboardColorToken.RGBA, _ b: BillboardColorToken.RGBA, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: 0.004, "red: \(message)", file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.004, "green: \(message)", file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.004, "blue: \(message)", file: file, line: line)
    }

    // MARK: - Ramp

    func testTheRampHasTwentyOneStopsPerAppearance() {
        XCTAssertEqual(VoterMapStyling.rampStopCount, 21)
        XCTAssertEqual(VoterMapStyling.rampTokens.count, 21)
        XCTAssertEqual(VoterMapStyling.rampColors.count, 21)
    }

    func testTheRampEndsAreTheVoteColoursAndTheMiddleIsMapNeutral() {
        for dark in [false, true] {
            let scheme = dark ? "dark" : "light"
            assertSame(VoterMapStyling.rampRGBA(index: 0, dark: dark), BillboardPalette.voteNay.resolved(dark: dark), "0% Yea is voteNay (\(scheme))")
            assertSame(VoterMapStyling.rampRGBA(index: 10, dark: dark), BillboardPalette.mapNeutral.resolved(dark: dark), "50/50 is mapNeutral (\(scheme))")
            assertSame(VoterMapStyling.rampRGBA(index: 20, dark: dark), BillboardPalette.voteYea.resolved(dark: dark), "100% Yea is voteYea (\(scheme))")
            assertSame(VoterMapStyling.rampTokens[0].resolved(dark: dark), BillboardPalette.voteNay.resolved(dark: dark), "token \(scheme)")
            assertSame(VoterMapStyling.rampTokens[20].resolved(dark: dark), BillboardPalette.voteYea.resolved(dark: dark), "token \(scheme)")
        }
    }

    /// The new midpoint (spec 2.1): the 50/50 stop is the Civic Record neutral in each appearance.
    func testTheFiftyFiftyStopIsTheCivicRecordNeutral() {
        assertSame(VoterMapStyling.rampRGBA(index: 10, dark: false), .hex(0xBFC5CF), "light 50/50")
        assertSame(VoterMapStyling.rampRGBA(index: 10, dark: true), .hex(0x4A5570), "dark 50/50")
        // Two stops either side, as the spec's mockup draws the ramp.
        assertSame(VoterMapStyling.rampRGBA(index: 2, dark: false), .hex(0xB36335), "light 10% Yea")
        assertSame(VoterMapStyling.rampRGBA(index: 12, dark: false), .hex(0xA0B3BE), "light 60% Yea")
        assertSame(VoterMapStyling.rampRGBA(index: 2, dark: true), .hex(0xD28B55), "dark 10% Yea")
        assertSame(VoterMapStyling.rampRGBA(index: 12, dark: true), .hex(0x4D6A83), "dark 60% Yea")
    }

    /// T7 (spec 10.2): the ramp's lightness runs one way from each end to the neutral, step by step: lighter
    /// toward 50/50 in light mode, darker toward it in dark mode. So a stop's lightness alone says how far it
    /// is from 50/50, for every kind of colour vision.
    func testTheLightnessIsMonotonicFromEachEndToTheNeutral() {
        for dark in [false, true] {
            let lightness = (0..<VoterMapStyling.rampStopCount).map {
                BillboardColorMath.lab(VoterMapStyling.rampRGBA(index: $0, dark: dark).rgb).l
            }
            for step in 1...10 {
                let towardNeutralFromNay = lightness[step] - lightness[step - 1]
                let towardNeutralFromYea = lightness[20 - step] - lightness[21 - step]
                if dark {
                    XCTAssertLessThan(towardNeutralFromNay, -1, "dark, step \(step) from Nay")
                    XCTAssertLessThan(towardNeutralFromYea, -1, "dark, step \(step) from Yea")
                } else {
                    XCTAssertGreaterThan(towardNeutralFromNay, 1, "light, step \(step) from Nay")
                    XCTAssertGreaterThan(towardNeutralFromYea, 1, "light, step \(step) from Yea")
                }
            }
        }
    }

    /// CVD (Machado 2009 at severity 1, CIEDE2000): each end stays at least 30 from the neutral in every kind
    /// of vision, and a stop 15 points or more from 50/50 on one side stays at least 15 from its mirror on
    /// the other side, so a 35% state never reads like a 65% one. Under the floor a hatch says so in words
    /// beside it (the legend), and the selection card names the numbers.
    func testTheRampHalvesStayApartForEveryKindOfVision() {
        for dark in [false, true] {
            let neutral = BillboardPalette.mapNeutral.resolved(dark: dark).rgb
            for end in [BillboardPalette.voteNay, BillboardPalette.voteYea] {
                for vision in BillboardColorMath.VisionDeficiency.allCases {
                    let distance = BillboardColorMath.deltaE2000(end.resolved(dark: dark).rgb, neutral, as: vision)
                    XCTAssertGreaterThanOrEqual(distance, 30, "end vs 50/50, dark: \(dark), \(vision)")
                }
            }
            for step in 3...10 {
                let nay = VoterMapStyling.rampRGBA(index: 10 - step, dark: dark).rgb
                let yea = VoterMapStyling.rampRGBA(index: 10 + step, dark: dark).rgb
                for vision in BillboardColorMath.VisionDeficiency.allCases {
                    let distance = BillboardColorMath.deltaE2000(nay, yea, as: vision)
                    XCTAssertGreaterThanOrEqual(distance, 15, "mirror stops \(step) from 50/50, dark: \(dark), \(vision)")
                }
            }
        }
    }

    func testEachHalfMovesSteadilyAwayFromFiftyFifty() {
        for dark in [false, true] {
            let neutral = BillboardColorMath.lab(BillboardPalette.mapNeutral.resolved(dark: dark).rgb)
            var previousNay = 0.0
            var previousYea = 0.0
            for step in 1...10 {
                let nay = BillboardColorMath.lab(VoterMapStyling.rampRGBA(index: 10 - step, dark: dark).rgb)
                let yea = BillboardColorMath.lab(VoterMapStyling.rampRGBA(index: 10 + step, dark: dark).rgb)
                let nayDistance = BillboardColorMath.deltaE2000(neutral, nay)
                let yeaDistance = BillboardColorMath.deltaE2000(neutral, yea)
                XCTAssertGreaterThan(nayDistance, previousNay, "step \(step) toward Nay (dark: \(dark))")
                XCTAssertGreaterThan(yeaDistance, previousYea, "step \(step) toward Yea (dark: \(dark))")
                previousNay = nayDistance
                previousYea = yeaDistance
            }
        }
    }

    /// T7 (spec D 2.3.6): each end of the ramp is at least dE 30 from the 50/50 colour.
    func testTheRampEndsStandApartFromFiftyFifty() {
        for dark in [false, true] {
            let neutral = BillboardPalette.mapNeutral.resolved(dark: dark).rgb
            for end in [BillboardPalette.voteNay, BillboardPalette.voteYea] {
                let distance = BillboardColorMath.deltaE2000(end.resolved(dark: dark).rgb, neutral, as: .normal)
                XCTAssertGreaterThanOrEqual(distance, 30, "dark: \(dark)")
            }
        }
    }

    func testRampIndexSnapsToFivePointSteps() {
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: 0), 0)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: 50), 10)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: 100), 20)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: 52), 10)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: 53), 11)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: 47.4), 9)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: -5), 0)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: 120), 20)
        XCTAssertEqual(VoterMapStyling.rampIndex(yeaPct: .nan), 10)
    }

    // MARK: - Fill and the floor

    func testEnoughVotesGetARampStop() {
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: 100, decisionVotes: 10), minDecisionVotes: 5), .ramp(20))
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: 0, decisionVotes: 5), minDecisionVotes: 5), .ramp(0))
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: 55, decisionVotes: 9), minDecisionVotes: 5), .ramp(11))
    }

    func testFewerThanTheFloorIsHatchedNeverFiftyFifty() {
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: 100, decisionVotes: 4), minDecisionVotes: 5), .hatched)
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: 50, decisionVotes: 4), minDecisionVotes: 5), .hatched)
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: nil, decisionVotes: 12), minDecisionVotes: 5), .hatched)
        XCTAssertEqual(VoterMapStyling.fill(for: nil, minDecisionVotes: 5), .hatched)
        XCTAssertEqual(VoterMapStyling.fill(for: .empty(id: "CA", label: "CA"), minDecisionVotes: 5), .hatched)
        XCTAssertNil(VoterMapStyling.color(for: .hatched))
        XCTAssertNotNil(VoterMapStyling.color(for: .ramp(10)))
    }

    func testTheFloorComesFromTheStats() {
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: 60, decisionVotes: 6), minDecisionVotes: 7), .hatched)
        XCTAssertEqual(VoterMapStyling.fill(for: stat(yeaPct: 60, decisionVotes: 7), minDecisionVotes: 7), .ramp(12))
        XCTAssertEqual(VoterMapStyling.defaultMinDecisionVotes, 5)
    }

    /// "Too few votes" never reads as 50/50 (R2's hatch recipe, kept by spec 2.1): the hatch's ground, the
    /// well, now stands well apart from the darker Civic Record neutral in every kind of vision, and its
    /// lines stand out from that ground, so the region reads as a pattern on a ground no ramp stop has.
    func testTheHatchStandsApartFromFiftyFifty() {
        XCTAssertEqual(VoterMapStyling.hatchOpacity, 0.35)
        for dark in [false, true] {
            let background = BillboardPalette.secondaryBackground.resolved(dark: dark).rgb
            let neutral = BillboardPalette.mapNeutral.resolved(dark: dark).rgb
            let line = BillboardColorMath.composite(
                BillboardPalette.dimText.resolved(dark: dark).rgb,
                alpha: VoterMapStyling.hatchOpacity,
                over: background
            )
            for vision in BillboardColorMath.VisionDeficiency.allCases {
                XCTAssertGreaterThanOrEqual(BillboardColorMath.deltaE2000(background, neutral, as: vision), 10, "ground vs 50/50, dark: \(dark), \(vision)")
            }
            XCTAssertGreaterThanOrEqual(BillboardColorMath.deltaE2000(line, background, as: .normal), 10, "lines vs ground, dark: \(dark)")
            // No ramp stop is the hatch's ground.
            for index in 0..<VoterMapStyling.rampStopCount {
                let stop = VoterMapStyling.rampRGBA(index: index, dark: dark).rgb
                XCTAssertGreaterThanOrEqual(BillboardColorMath.deltaE2000(stop, background, as: .normal), 10, "stop \(index), dark: \(dark)")
            }
        }
    }

    /// The outlines (spec 3.9): every region at 0.75 pt in `ink3` (light) or `ink2` (dark) at full strength,
    /// 3:1 or more against the plate and the 50/50 fill; the user's region 2 pt dashed and the selection
    /// 2.5 pt solid, both in ink.
    func testTheOutlinesReachThreeToOneOnThePlateAndTheNeutral() {
        XCTAssertEqual(VoterMapStyling.outlineWidth, 0.75)
        XCTAssertEqual(VoterMapStyling.highlightWidth, 2)
        XCTAssertEqual(VoterMapStyling.highlightDash, [3, 2])
        XCTAssertEqual(VoterMapStyling.selectionWidth, 2.5)
        XCTAssertEqual(VoterMapStyling.outlineToken(dark: false), BillboardPalette.dimText)
        XCTAssertEqual(VoterMapStyling.outlineToken(dark: true), BillboardPalette.secondaryText)
        for dark in [false, true] {
            for highContrast in [false, true] {
                let outline = VoterMapStyling.outlineToken(dark: dark).resolved(dark: dark, highContrast: highContrast).rgb
                for ground in [BillboardPalette.plate, BillboardPalette.mapNeutral] {
                    let ratio = BillboardColorMath.contrastRatio(outline, ground.resolved(dark: dark, highContrast: highContrast).rgb)
                    XCTAssertGreaterThanOrEqual(ratio, 3, "dark: \(dark), HC: \(highContrast)")
                }
            }
        }
    }

    func testHatchLinesCoverTheRegion() {
        XCTAssertFalse(VoterMapStyling.hatchPath(in: CGRect(x: 0, y: 0, width: 60, height: 30)).isEmpty)
        XCTAssertTrue(VoterMapStyling.hatchPath(in: .zero).isEmpty)
        XCTAssertTrue(VoterMapStyling.hatchPath(in: CGRect(x: 0, y: 0, width: 10, height: 10), spacing: 0).isEmpty)
    }

    // MARK: - Region stats

    func testARegionReadsThePlainYeaShareNeverTheWeightedOne() throws {
        let data = Data(#"{"votes":10,"yea":4,"nay":6,"abstain":0,"decisionVotes":10,"yeaPct":40,"weightedVotes":10,"weightedYea":8,"weightedNay":2,"weightedAbstain":0,"weightedDecisionVotes":10,"weightedYeaPct":80}"#.utf8)
        let totals = try JSONDecoder.convertingFromSnakeCase().decode(BillStatsService.VoteTotals.self, from: data)
        let stat = VoterMapRegionStat(id: "VA", label: "VA", totals: totals)
        XCTAssertEqual(stat.yeaPct, 40)
        XCTAssertEqual(stat.decisionVotes, 10)
        XCTAssertEqual(stat.yea, 4)
        XCTAssertEqual(stat.nay, 6)
        XCTAssertEqual(VoterMapStyling.fill(for: stat, minDecisionVotes: 5), .ramp(8))
    }
}
