import XCTest
@testable import Billboard

/// Results on bill detail (spec D 2.2): the percent rule, everyone beside verified voters, the floor (UX-34:
/// under 5 Yea + Nay votes no split and no abstain count, and no two numbers shown that give away a group under
/// it), the fallback for a body without `comparison`, and the state, district and map lines.
@MainActor
final class VoteResultsFormattingTests: XCTestCase {
    // MARK: - Percent rule

    func testPercentagesRoundYeaAndGiveNayTheRest() {
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: 62.4, yea: 1, nay: 1), .init(yea: 62, nay: 38))
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: 62.5, yea: 1, nay: 1), .init(yea: 63, nay: 37))
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: 0.4, yea: 1, nay: 99), .init(yea: 0, nay: 100))
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: 99.6, yea: 99, nay: 1), .init(yea: 100, nay: 0))
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: 100, yea: 3, nay: 0), .init(yea: 100, nay: 0))
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: 0, yea: 0, nay: 3), .init(yea: 0, nay: 100))
    }

    func testPercentagesAlwaysAddUpToOneHundredWithNoDecimals() {
        var pct = 0.0
        while pct <= 100 {
            let shares = VoteResultsFormatting.percentages(yeaPct: pct, yea: 5, nay: 5)
            XCTAssertEqual((shares?.yea ?? -1) + (shares?.nay ?? -1), 100, "\(pct)")
            pct += 0.1
        }
    }

    func testPercentagesUseTheCountsWhenYeaPctIsMissing() {
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: nil, yea: 2, nay: 1), .init(yea: 67, nay: 33))
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: nil, yea: 1, nay: 1), .init(yea: 50, nay: 50))
    }

    func testPercentagesClampOutOfRangeValues() {
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: 140, yea: 1, nay: 0), .init(yea: 100, nay: 0))
        XCTAssertEqual(VoteResultsFormatting.percentages(yeaPct: -3, yea: 0, nay: 1), .init(yea: 0, nay: 100))
        XCTAssertNil(VoteResultsFormatting.percentages(yeaPct: .nan, yea: 1, nay: 1))
    }

    func testNoYeaOrNayVotesGivesNoPercentages() {
        XCTAssertNil(VoteResultsFormatting.percentages(yeaPct: nil, yea: 0, nay: 0))
        XCTAssertNil(VoteResultsFormatting.percentages(yeaPct: 50, yea: 0, nay: 0), "a stray yeaPct with no votes is ignored")
        let split = BillStatsService.VoteSplit(votes: 3, yea: 0, nay: 0, abstain: 3, decisionVotes: 0, yeaPct: nil)
        XCTAssertNil(VoteResultsFormatting.percentages(split))
        XCTAssertEqual(VoteResultsFormatting.splitValue(split), .noDecisionVotes)
        XCTAssertEqual(VoteResultsFormatting.RowValue.noDecisionVotes.text, "No Yea or Nay votes yet")
    }

    // MARK: - Copy

    func testCountsAndAbstentionCopy() {
        XCTAssertEqual(VoteResultsFormatting.voteCountText(1), "1 vote")
        XCTAssertEqual(VoteResultsFormatting.voteCountText(40), "40 votes")
        XCTAssertNil(VoteResultsFormatting.abstainedText(0))
        XCTAssertEqual(VoteResultsFormatting.abstainedText(1), "1 person abstained.")
        XCTAssertEqual(VoteResultsFormatting.abstainedText(6), "6 people abstained.")
        XCTAssertEqual(VoteResultsFormatting.fewerThanFloorText(5), "Fewer than 5 votes so far")
    }

    func testRowValueTextAndVoiceOver() {
        let value = VoteResultsFormatting.RowValue.split(.init(yea: 55, nay: 45), decisionVotes: 9)
        XCTAssertEqual(value.text, "55% Yea · 45% Nay · 9 votes")
        XCTAssertEqual(value.accessibilityText, "55 percent Yea, 45 percent Nay, 9 Yea or Nay votes")
        XCTAssertEqual(VoteResultsFormatting.RowValue.fewerThanFloor(5).accessibilityText, "Fewer than 5 votes so far")
        XCTAssertEqual(VoteResultsFormatting.RowValue.withheld.text, "Shown once more people vote")
        XCTAssertEqual(VoteResultsFormatting.RowValue.withheld.accessibilityText, "Shown once more people vote")
        XCTAssertNil(VoteResultsFormatting.RowValue.withheld.percentages)
    }

    /// Under the floor Results say only when they open (UX-34). The project decision of 2026-10-29 changed this test:
    /// it pinned "Results open at 5 votes · 3 votes so far", and the line now shows no count, because watching it
    /// before and after a friend votes would show whether they voted Yea or Nay or abstained. VoiceOver reads
    /// "Results open at 5 Yea or Nay votes."
    func testTheFloorLineSaysWhenResultsOpen() {
        typealias Line = VoteResultsFormatting.FloorLine
        XCTAssertEqual(Line(floor: 5).text, "Results open at 5 votes")
        XCTAssertEqual(Line(floor: 10).text, "Results open at 10 votes")
        XCTAssertEqual(Line(floor: 1).text, "Results open at 1 vote")
        XCTAssertEqual(Line(floor: 5).accessibilityText, "Results open at 5 Yea or Nay votes.")
        XCTAssertEqual(Line(floor: 1).accessibilityText, "Results open at 1 Yea or Nay vote.")
        for line in [Line(floor: 5), Line(floor: 10)] {
            XCTAssertFalse(line.text.contains("so far"), line.text)
            XCTAssertFalse(line.accessibilityText.contains("so far"), line.accessibilityText)
        }
    }

    /// The floor line as drawn binds the figure to its word (a no-break space), so at accessibility sizes it
    /// wraps between the sentence's words, never between "5" and "votes" (review of the privacy slice: AX3 drew
    /// "Results open at 5" / "votes …"). The project decision of 2026-10-29 changed this test: it no longer pins a
    /// "· 3 votes so far" part.
    func testTheFloorLineNeverSplitsAFigureFromItsWord() {
        typealias Line = VoteResultsFormatting.FloorLine
        let nbsp = "\u{00A0}"
        XCTAssertEqual(Line(floor: 5).displayText, "Results open at 5\(nbsp)votes")
        XCTAssertEqual(Line(floor: 1).displayText, "Results open at 1\(nbsp)vote")
        for line in [Line(floor: 5), Line(floor: 10)] {
            XCTAssertEqual(line.displayText.replacingOccurrences(of: nbsp, with: " "), line.text, "same words as text")
        }
    }

    /// The project decision of 2026-10-29 (UX-34): under the floor the line is the same whatever the count, from
    /// the first vote to the fourth, so no one can tell from it whether a friend voted Yea or Nay or abstained.
    func testTheFloorLineIsTheSameWhateverTheCountUnderTheFloor() throws {
        var lines: [VoteResultsFormatting.FloorLine] = []
        for decisionVotes in 0..<5 {
            for abstain in 0..<3 {
                let yea = decisionVotes / 2
                let nay = decisionVotes - yea
                let stats = try Self.stats(
                    totals: Self.totals(yea: yea, nay: nay, abstain: abstain, yeaPct: decisionVotes > 0 ? Double(yea * 100) / Double(decisionVotes) : nil),
                    comparison: #"{"allUsers":{"votes":\#(decisionVotes + abstain),"yea":\#(yea),"nay":\#(nay),"abstain":\#(abstain),"decisionVotes":\#(decisionVotes),"yeaPct":null},"verifiedWithheld":true,"minDecisionVotes":5}"#
                )
                let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "VA", userDistrictValue: "11")
                lines.append(try XCTUnwrap(summary.belowFloor, "\(decisionVotes) Yea or Nay, \(abstain) abstained"))
                XCTAssertEqual(VoteResultsFormatting.floorLine(for: stats), summary.belowFloor)
            }
        }
        XCTAssertEqual(Set(lines.map(\.text)), ["Results open at 5 votes"])
        XCTAssertEqual(Set(lines.map(\.accessibilityText)), ["Results open at 5 Yea or Nay votes."])
    }

    /// Feature review N1: a reason's share is of the side's voters (each picks up to 3), not of its reasons.
    func testAReasonIsReadAsAShareOfTheSidesVoters() {
        XCTAssertEqual(
            VoteResultsFormatting.reasonAccessibilityLabel(reason: "Saves money", count: 12, pct: 52, choice: .yea),
            "Saves money: 12 people, 52 percent of Yea voters."
        )
        XCTAssertEqual(
            VoteResultsFormatting.reasonAccessibilityLabel(reason: "Jobs", count: 1, pct: 12.5, choice: .nay),
            "Jobs: 1 person, 12.5 percent of Nay voters."
        )
    }

    /// The info sheet explains the floor (UX-34) without promising more than it gives (no "no one can work out how
    /// a few people voted": a unanimous 5 shows each vote), and the state level of the map says when every district
    /// is under it.
    func testTheInfoSheetExplainsTheFloor() {
        XCTAssertEqual(
            VoteResultsFormatting.infoFloorText(5),
            "Results open at 5 Yea or Nay votes. Any state, district or group with fewer than 5 stays hidden, and so "
                + "does any number that would give one away."
        )
        XCTAssertTrue(VoteResultsFormatting.infoText.contains(VoteResultsFormatting.infoFloorText(5)))
        XCTAssertEqual(VoteResultsFormatting.districtsUnderFloorText(5), "Every district has fewer than 5 votes so far.")
    }

    /// The info sheet says what verified means: an address that matched a district (feature review N1).
    func testTheInfoSheetSaysWhatVerifiedMeans() {
        XCTAssertEqual(VoteResultsFormatting.infoVerifiedText, "entered an address that matched a district.")
        XCTAssertTrue(VoteResultsFormatting.infoText.contains("Verified voters entered an address that matched a district."))
        XCTAssertFalse(VoteResultsFormatting.infoText.contains("home address"), "nothing confirms it is their home")
    }

    func testResultsCopyUsesTheGlossary() {
        let copy = [
            VoteResultsFormatting.sectionTitle,
            VoteResultsFormatting.everyoneTitle,
            VoteResultsFormatting.verifiedTitle,
            VoteResultsFormatting.loadingText,
            VoteResultsFormatting.unavailableText,
            VoteResultsFormatting.mapTitle,
            VoteResultsFormatting.infoText,
            VoteResultsFormatting.addressForStateText,
            VoteResultsFormatting.addressForDistrictText,
            VoteResultsFormatting.mapLegendAccessibilityValue(floor: 5),
            VoteResultsFormatting.withheldText,
            VoteResultsFormatting.districtsUnderFloorText(5),
            VoteResultsFormatting.FloorLine(floor: 5).text,
            VoteResultsFormatting.FloorLine(floor: 5).accessibilityText
        ]
        let banned = ["trend", "lean", "constituent", "weighted", "signal", "low sample", "decision vote"]
        for text in copy {
            for term in banned {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(term), "\"\(term)\" in \"\(text)\"")
            }
            XCTAssertFalse(text.contains("BillBoard"), "the app is Billboard: \(text)")
        }
        XCTAssertEqual(VoteResultsFormatting.sectionTitle, "Results")
        XCTAssertEqual(VoteResultsFormatting.mapTitle, "Map: verified voters")
    }

    // MARK: - National rows

    func testEveryoneAndVerifiedVotersSideBySide() throws {
        let stats = try Self.stats(
            totals: Self.totals(yea: 25, nay: 15, abstain: 6, yeaPct: 62.5),
            verified: Self.totals(yea: 7, nay: 5, abstain: 0, yeaPct: 58.3),
            comparison: #"{"allUsers":{"votes":46,"yea":25,"nay":15,"abstain":6,"decisionVotes":40,"yeaPct":62.5},"verified":{"votes":12,"yea":7,"nay":5,"abstain":0,"decisionVotes":12,"yeaPct":58.3},"verifiedWithheld":false,"minDecisionVotes":5}"#
        )
        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "", userDistrictValue: "")

        XCTAssertEqual(summary.national.map(\.group), [.everyone, .verified], "Everyone is listed first")
        XCTAssertEqual(summary.national.map(\.title), ["Everyone", "Verified voters"])
        XCTAssertEqual(summary.national[0].value, .split(.init(yea: 63, nay: 37), decisionVotes: 40))
        XCTAssertEqual(summary.national[1].value, .split(.init(yea: 58, nay: 42), decisionVotes: 12))
        XCTAssertEqual(summary.national[0].accessibilityLabel, "Everyone: 63 percent Yea, 37 percent Nay, 40 Yea or Nay votes")
        XCTAssertEqual(summary.abstainedText, "6 people abstained.")
        XCTAssertEqual(summary.minDecisionVotes, 5)
    }

    /// Everyone over the floor (UX-34 changed this test's Everyone from 4 votes, which "everyone is never
    /// withheld" pinned, to 6: under 5, Everyone is withheld too).
    func testWithheldVerifiedVotersSayFewerThanTheFloor() throws {
        let stats = try Self.stats(
            totals: Self.totals(yea: 4, nay: 2, abstain: 0, yeaPct: 66.7),
            verified: Self.totals(yea: 2, nay: 1, abstain: 0, yeaPct: 66.7),
            comparison: #"{"allUsers":{"votes":6,"yea":4,"nay":2,"abstain":0,"decisionVotes":6,"yeaPct":66.7},"verifiedWithheld":true,"minDecisionVotes":5}"#
        )
        let rows = VoteResultsFormatting.summary(for: stats, userStateCode: "", userDistrictValue: "").national

        XCTAssertEqual(rows[1].value, .fewerThanFloor(5))
        XCTAssertEqual(rows[1].value.text, "Fewer than 5 votes so far")
        XCTAssertEqual(rows[1].accessibilityLabel, "Verified voters: Fewer than 5 votes so far")
        XCTAssertEqual(rows[0].value, .split(.init(yea: 67, nay: 33), decisionVotes: 6))
    }

    /// The project's decision of 2026-10-28 (UX-34), replacing "everyone is never withheld": under 5 Yea + Nay
    /// votes there is no split and no abstain count anywhere in Results, only the floor line; at 5 they open.
    func testEveryoneAndTheAbstainLineAreWithheldUnderTheFloor() throws {
        let under = try Self.stats(
            totals: Self.totals(yea: 3, nay: 1, abstain: 2, yeaPct: 75),
            comparison: #"{"allUsers":{"votes":6,"yea":3,"nay":1,"abstain":2,"decisionVotes":4,"yeaPct":75},"verifiedWithheld":true,"minDecisionVotes":5}"#
        )
        XCTAssertTrue(VoteResultsFormatting.isBelowFloor(under))
        let summary = VoteResultsFormatting.summary(for: under, userStateCode: "VA", userDistrictValue: "11")
        XCTAssertEqual(summary.national, [], "no Everyone or Verified voters row")
        XCTAssertNil(summary.abstainedText, "no \"2 people abstained.\"")
        // The project decision of 2026-10-29 changed this line: no "· 4 votes so far".
        XCTAssertEqual(summary.belowFloor, .init(floor: 5))
        XCTAssertEqual(summary.belowFloor?.text, "Results open at 5 votes")
        XCTAssertFalse(summary.showsMap)

        let atTheFloor = try Self.stats(
            totals: Self.totals(yea: 3, nay: 2, abstain: 2, yeaPct: 60),
            comparison: #"{"allUsers":{"votes":7,"yea":3,"nay":2,"abstain":2,"decisionVotes":5,"yeaPct":60},"verifiedWithheld":true,"minDecisionVotes":5}"#
        )
        XCTAssertFalse(VoteResultsFormatting.isBelowFloor(atTheFloor))
        let open = VoteResultsFormatting.summary(for: atTheFloor, userStateCode: "", userDistrictValue: "")
        XCTAssertNil(open.belowFloor)
        XCTAssertEqual(open.national.first?.value, .split(.init(yea: 60, nay: 40), decisionVotes: 5))
        XCTAssertEqual(open.abstainedText, "2 people abstained.")

        // The floor is the comparison's, and a body without `comparison` reads its totals the same way.
        let fallback = try Self.stats(totals: Self.totals(yea: 2, nay: 2, abstain: 1, yeaPct: 50), comparison: nil)
        XCTAssertEqual(VoteResultsFormatting.summary(for: fallback, userStateCode: "", userDistrictValue: "").belowFloor, .init(floor: 5))
    }

    /// Everyone minus Verified voters is the unverified voters (UX-34): when that leaves 1 to 4 Yea or Nay
    /// votes the verified row is withheld, so the two rows never give away the smaller group's split. None
    /// left, or 5 or more, shows both.
    func testVerifiedVotersAreWithheldWhenEveryoneMinusThemIsUnderTheFloor() {
        func verifiedValue(everyone: (Int, Int), verified: (Int, Int)) -> VoteResultsFormatting.RowValue {
            let all = BillStatsService.VoteSplit(votes: everyone.0 + everyone.1, yea: everyone.0, nay: everyone.1, abstain: 0, decisionVotes: everyone.0 + everyone.1, yeaPct: nil)
            let ver = BillStatsService.VoteSplit(votes: verified.0 + verified.1, yea: verified.0, nay: verified.1, abstain: 0, decisionVotes: verified.0 + verified.1, yeaPct: nil)
            let comparison = BillStatsService.Comparison(allUsers: all, verified: ver, verifiedWithheld: false, minDecisionVotes: 5)
            return VoteResultsFormatting.nationalRows(comparison)[1].value
        }
        XCTAssertEqual(verifiedValue(everyone: (4, 3), verified: (3, 2)), .withheld, "2 unverified votes")
        XCTAssertEqual(verifiedValue(everyone: (6, 3), verified: (3, 2)), .withheld, "4 unverified votes")
        XCTAssertEqual(verifiedValue(everyone: (3, 2), verified: (3, 2)), .split(.init(yea: 60, nay: 40), decisionVotes: 5), "no unverified votes")
        XCTAssertEqual(verifiedValue(everyone: (6, 4), verified: (3, 2)), .split(.init(yea: 60, nay: 40), decisionVotes: 5), "5 unverified votes")
    }

    /// Everyone minus the states shown is everyone outside them (UX-34): when that leaves 1 to 4 Yea or Nay
    /// votes the state and district lines say "Shown once more people vote" and the map is hidden. The server
    /// already withholds verified voters when they minus the states would.
    func testRegionsAreWithheldWhenEveryoneMinusTheStatesShownIsUnderTheFloor() throws {
        let withheld = try Self.stats(
            totals: Self.totals(yea: 4, nay: 3, abstain: 1, yeaPct: 57.1),
            comparison: #"{"allUsers":{"votes":8,"yea":4,"nay":3,"abstain":1,"decisionVotes":7,"yeaPct":57.1},"verifiedWithheld":true,"minDecisionVotes":5}"#,
            byState: ["VA": Self.totals(yea: 3, nay: 2, abstain: 0, yeaPct: 60)],
            byDistrict: ["VA-11": ("VA", "VA-11", Self.totals(yea: 3, nay: 2, abstain: 0, yeaPct: 60))]
        )
        XCTAssertTrue(VoteResultsFormatting.withholdsRegions(withheld))
        let summary = VoteResultsFormatting.summary(for: withheld, userStateCode: "VA", userDistrictValue: "11")
        XCTAssertEqual(summary.state, .result(title: "Verified voters in VA", spokenTitle: "Verified voters in Virginia", value: .withheld))
        XCTAssertEqual(summary.district, .result(title: "Verified voters in VA-11", spokenTitle: "Verified voters in Virginia's 11th district", value: .withheld))
        XCTAssertFalse(summary.showsMap)
        XCTAssertEqual(summary.national[0].value, .split(.init(yea: 57, nay: 43), decisionVotes: 7), "Everyone still shows")

        // Every voter in the states shown: nothing outside to give away.
        let allInVirginia = try Self.stats(
            totals: Self.totals(yea: 3, nay: 2, abstain: 1, yeaPct: 60),
            comparison: #"{"allUsers":{"votes":6,"yea":3,"nay":2,"abstain":1,"decisionVotes":5,"yeaPct":60},"verifiedWithheld":true,"minDecisionVotes":5}"#,
            byState: ["VA": Self.totals(yea: 3, nay: 2, abstain: 1, yeaPct: 60)]
        )
        XCTAssertFalse(VoteResultsFormatting.withholdsRegions(allInVirginia))
        let shown = VoteResultsFormatting.summary(for: allInVirginia, userStateCode: "VA", userDistrictValue: "")
        XCTAssertEqual(shown.state, .result(title: "Verified voters in VA", spokenTitle: "Verified voters in Virginia", value: .split(.init(yea: 60, nay: 40), decisionVotes: 5)))
        XCTAssertTrue(shown.showsMap)
    }

    /// The map shows only over the floor with a state that clears it (UX-34): never all hatched.
    func testTheMapShowsOnlyWithAStateOverTheFloor() throws {
        let comparison = #"{"allUsers":{"votes":12,"yea":7,"nay":5,"abstain":0,"decisionVotes":12,"yeaPct":58.3},"verifiedWithheld":true,"minDecisionVotes":5}"#
        let noState = try Self.stats(comparison: comparison)
        XCTAssertFalse(VoteResultsFormatting.summary(for: noState, userStateCode: "VA", userDistrictValue: "").showsMap)
        let stateUnderTheFloor = try Self.stats(comparison: comparison, byState: ["VA": Self.totals(yea: 2, nay: 2, abstain: 0, yeaPct: 50)])
        XCTAssertFalse(VoteResultsFormatting.summary(for: stateUnderTheFloor, userStateCode: "VA", userDistrictValue: "").showsMap)
        let stateOverTheFloor = try Self.stats(comparison: comparison, byState: ["MD": Self.totals(yea: 3, nay: 3, abstain: 0, yeaPct: 50)])
        XCTAssertTrue(VoteResultsFormatting.summary(for: stateOverTheFloor, userStateCode: "VA", userDistrictValue: "").showsMap)
    }

    /// No two numbers Results show give away a group under the floor (UX-34), for every small electorate: up to
    /// 12 Yea or Nay votes from everyone, some of them verified, in Virginia (the user's state) and Maryland. The
    /// server's stats are modelled as it publishes them (states under 5 left out; verified voters withheld under
    /// 5, or when they minus the states shown leave 1 to 4). Everyone, verified voters, the user's state line and
    /// the map's states are the numbers shown; every difference between one of them and the shown groups inside
    /// it must be 0 or 5 or more. Under the floor nothing but the floor line shows.
    func testNoTwoNumbersShownGiveAwayAGroupUnderTheFloor() throws {
        let floor = 5
        func bucket(_ votes: Int) -> String {
            Self.totals(yea: votes / 2, nay: votes - votes / 2, abstain: 0, yeaPct: votes > 0 ? Double(votes / 2) * 100 / Double(votes) : nil)
        }
        func split(_ votes: Int) -> String {
            let yea = votes / 2
            let pct = votes > 0 ? "\(Double(yea) * 100 / Double(votes))" : "null"
            return #"{"votes":\#(votes),"yea":\#(yea),"nay":\#(votes - yea),"abstain":0,"decisionVotes":\#(votes),"yeaPct":\#(pct)}"#
        }
        var checked = 0
        for everyone in 0...12 {
            for verified in 0...everyone {
                for virginia in 0...verified {
                    for maryland in 0...(verified - virginia) {
                        let states = [("VA", virginia), ("MD", maryland)].filter { $0.1 >= floor }
                        let inShownStates = states.reduce(0) { $0 + $1.1 }
                        let outside = verified - inShownStates
                        let verifiedPublished = verified >= floor && !(outside > 0 && outside < floor)
                        let verifiedJSON = verifiedPublished ? #","verified":\#(split(verified)),"verifiedWithheld":false"# : #","verifiedWithheld":true"#
                        let stats = try Self.stats(
                            totals: bucket(everyone),
                            comparison: #"{"allUsers":\#(split(everyone))\#(verifiedJSON),"minDecisionVotes":5}"#,
                            byState: Dictionary(uniqueKeysWithValues: states.map { ($0.0, bucket($0.1)) })
                        )
                        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "VA", userDistrictValue: "")
                        let label = "everyone \(everyone), verified \(verified), VA \(virginia), MD \(maryland)"
                        checked += 1

                        if everyone < floor {
                            XCTAssertEqual(summary.national, [], label)
                            XCTAssertNil(summary.abstainedText, label)
                            XCTAssertFalse(summary.showsMap, label)
                            XCTAssertNotNil(summary.belowFloor, label)
                            continue
                        }
                        XCTAssertNil(summary.belowFloor, label)
                        // The numbers shown: Everyone, verified voters if their row has a split, the user's state
                        // line, and each state the map shows.
                        let verifiedShown = summary.national[1].value.percentages != nil ? verified : nil
                        var shownStates: [String: Int] = [:]
                        if case .result(_, _, let value) = summary.state, value.percentages != nil { shownStates["VA"] = virginia }
                        if summary.showsMap { for (code, votes) in states { shownStates[code] = votes } }
                        let stateSubsets: [[Int]] = [[], Array(shownStates.values)] + shownStates.values.map { [$0] }

                        func assertNotUnderTheFloor(_ difference: Int, _ what: String) {
                            XCTAssertFalse(difference > 0 && difference < floor, "\(what) = \(difference): \(label)")
                        }
                        if let verifiedShown {
                            assertNotUnderTheFloor(everyone - verifiedShown, "Everyone minus verified")
                        }
                        for subset in stateSubsets where !subset.isEmpty {
                            let inside = subset.reduce(0, +)
                            assertNotUnderTheFloor(everyone - inside, "Everyone minus states")
                            if let verifiedShown {
                                assertNotUnderTheFloor(verifiedShown - inside, "verified minus states")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1_000)
    }

    func testTheWithheldFlagWinsOverAStrayVerifiedSplit() {
        let split = BillStatsService.VoteSplit(votes: 6, yea: 4, nay: 2, abstain: 0, decisionVotes: 6, yeaPct: 66.7)
        let comparison = BillStatsService.Comparison(allUsers: split, verified: split, verifiedWithheld: true, minDecisionVotes: 7)
        XCTAssertEqual(VoteResultsFormatting.nationalRows(comparison)[1].value, .fewerThanFloor(7))
    }

    /// Abstentions alone are under the floor (UX-34 changed this test: they no longer show "3 people abstained."
    /// beside a "No Yea or Nay votes yet" row).
    func testAbstainOnlyResults() throws {
        let stats = try Self.stats(
            totals: Self.totals(yea: 0, nay: 0, abstain: 3, yeaPct: nil),
            verified: Self.totals(yea: 0, nay: 0, abstain: 1, yeaPct: nil),
            comparison: nil
        )
        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "", userDistrictValue: "")
        XCTAssertEqual(summary.national, [])
        XCTAssertNil(summary.abstainedText)
        XCTAssertEqual(summary.belowFloor?.text, "Results open at 5 votes")
    }

    /// No votes at all: the floor line without a count (UX-34 changed this test from a "No Yea or Nay votes yet"
    /// row). The state line is still worked out, under the floor, but Results do not draw it.
    func testNoVotesAtAll() throws {
        let stats = try Self.stats(
            totals: Self.totals(yea: 0, nay: 0, abstain: 0, yeaPct: nil),
            verified: Self.totals(yea: 0, nay: 0, abstain: 0, yeaPct: nil),
            comparison: #"{"allUsers":{"votes":0,"yea":0,"nay":0,"abstain":0,"decisionVotes":0,"yeaPct":null},"verifiedWithheld":true,"minDecisionVotes":5}"#
        )
        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "VA", userDistrictValue: "11")
        XCTAssertEqual(summary.national, [])
        XCTAssertNil(summary.abstainedText)
        XCTAssertEqual(summary.belowFloor, .init(floor: 5))
        XCTAssertEqual(summary.state, .result(title: "Verified voters in VA", spokenTitle: "Verified voters in Virginia", value: .fewerThanFloor(5)))
    }

    // MARK: - Fallback without `comparison` (a body without it)

    /// Everyone has 15 Yea or Nay votes here, 9 of them unverified (UX-34 changed it from 10: with 6 verified,
    /// the 4 unverified votes' split would show by subtraction, so the verified row is withheld).
    func testFallbackReadsTotalsAndTheVerifiedSegment() throws {
        let stats = try Self.stats(
            totals: Self.totals(yea: 12, nay: 3, abstain: 1, yeaPct: 80, weightedYeaPct: 83.3),
            verified: Self.totals(yea: 4, nay: 2, abstain: 0, yeaPct: 66.7, weightedYeaPct: 66.7),
            comparison: nil
        )
        XCTAssertNil(stats.comparison)
        let rows = VoteResultsFormatting.summary(for: stats, userStateCode: "", userDistrictValue: "").national
        XCTAssertEqual(rows[0].value, .split(.init(yea: 80, nay: 20), decisionVotes: 15), "the plain yeaPct, never the weighted one")
        XCTAssertEqual(rows[1].value, .split(.init(yea: 67, nay: 33), decisionVotes: 6))
    }

    func testFallbackWithholdsVerifiedVotersUnderFive() throws {
        let stats = try Self.stats(
            totals: Self.totals(yea: 8, nay: 2, abstain: 0, yeaPct: 80),
            verified: Self.totals(yea: 3, nay: 1, abstain: 0, yeaPct: 75),
            comparison: nil
        )
        let comparison = stats.resolvedComparison
        XCTAssertTrue(comparison.verifiedWithheld)
        XCTAssertNil(comparison.verified)
        XCTAssertEqual(comparison.minDecisionVotes, 5)
        XCTAssertEqual(VoteResultsFormatting.nationalRows(comparison)[1].value, .fewerThanFloor(5))
    }

    // MARK: - State and district

    func testMissingStateAsksForAnAddress() throws {
        let stats = try Self.stats(comparison: nil)
        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "  ", userDistrictValue: "11")
        XCTAssertEqual(summary.state, .needsAddress("Add your address in Profile to see your state"))
        XCTAssertNil(summary.district, "one prompt, not two")
    }

    func testMissingDistrictAsksForAnAddress() throws {
        let stats = try Self.stats(comparison: nil)
        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "va", userDistrictValue: "")
        XCTAssertEqual(summary.state, .result(title: "Verified voters in VA", spokenTitle: "Verified voters in Virginia", value: .fewerThanFloor(5)))
        XCTAssertEqual(summary.district, .needsAddress("Add your address in Profile to see your district"))
    }

    /// Everyone has 20 Yea or Nay votes here (UX-34 changed it from 10: Everyone minus the 9 in Virginia would
    /// have left 1, so the state line would be withheld).
    func testStateAndDistrictCountVerifiedVotersAndHonourTheFloor() throws {
        let stats = try Self.stats(
            comparison: #"{"allUsers":{"votes":22,"yea":12,"nay":8,"abstain":2,"decisionVotes":20,"yeaPct":60},"verified":{"votes":9,"yea":5,"nay":4,"abstain":0,"decisionVotes":9,"yeaPct":55.6},"verifiedWithheld":false,"minDecisionVotes":5}"#,
            byState: ["VA": Self.totals(yea: 5, nay: 4, abstain: 2, yeaPct: 55.4)],
            byDistrict: ["VA-11": ("VA", "VA-11", Self.totals(yea: 2, nay: 1, abstain: 0, yeaPct: 66.7))]
        )
        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "VA", userDistrictValue: "11")
        XCTAssertEqual(summary.state, .result(title: "Verified voters in VA", spokenTitle: "Verified voters in Virginia", value: .split(.init(yea: 55, nay: 45), decisionVotes: 9)))
        XCTAssertEqual(summary.district, .result(title: "Verified voters in VA-11", spokenTitle: "Verified voters in Virginia's 11th district", value: .fewerThanFloor(5)))
        if case .result(_, _, let value) = summary.state {
            XCTAssertEqual(value.text, "55% Yea · 45% Nay · 9 votes")
        }
    }

    /// The local lines print the place as a code and VoiceOver reads it in the one spoken form (project decision
    /// of 2026-10-21): "Verified voters in VA-11" is read "Verified voters in Virginia's 11th district", as
    /// Your representatives' counter and the member rows say a district.
    func testTheLocalLinesReadThePlaceInWords() throws {
        let stats = try Self.stats(comparison: nil)
        let cases: [(state: String, district: String, title: String, spoken: String)] = [
            ("VA", "11", "Verified voters in VA-11", "Verified voters in Virginia's 11th district"),
            ("va", "VA-011", "Verified voters in VA-11", "Verified voters in Virginia's 11th district"),
            ("AK", "At-Large", "Verified voters in AK at-large", "Verified voters in Alaska's at-large district"),
            ("WY", "0", "Verified voters in WY at-large", "Verified voters in Wyoming's at-large district"),
            ("VI", "AL", "Verified voters in VI at-large", "Verified voters in U.S. Virgin Islands' at-large district")
        ]
        for (state, district, title, spoken) in cases {
            let summary = VoteResultsFormatting.summary(for: stats, userStateCode: state, userDistrictValue: district)
            XCTAssertEqual(summary.district, .result(title: title, spokenTitle: spoken, value: .fewerThanFloor(5)), "\(state) \(district)")
            guard case .result(let stateTitle, let stateSpoken, _) = summary.state else {
                return XCTFail("\(state): a state line")
            }
            XCTAssertEqual(stateTitle, "Verified voters in \(state.uppercased())")
            XCTAssertEqual(stateSpoken, "Verified voters in \(USStateNames.name(forPostalCode: state) ?? "")")
        }
    }

    func testTheFloorComesFromTheComparison() throws {
        let stats = try Self.stats(
            comparison: #"{"allUsers":{"votes":12,"yea":7,"nay":3,"abstain":2,"decisionVotes":10,"yeaPct":70},"verifiedWithheld":true,"minDecisionVotes":10}"#,
            byState: ["VA": Self.totals(yea: 5, nay: 4, abstain: 0, yeaPct: 55.6)]
        )
        let summary = VoteResultsFormatting.summary(for: stats, userStateCode: "VA", userDistrictValue: "")
        XCTAssertEqual(summary.minDecisionVotes, 10)
        XCTAssertEqual(summary.state, .result(title: "Verified voters in VA", spokenTitle: "Verified voters in Virginia", value: .fewerThanFloor(10)))
        XCTAssertEqual(summary.national[1].value.text, "Fewer than 10 votes so far")
    }

    func testDistrictRollupMatchesEveryKeyAndDistrictForm() throws {
        let totals = Self.totals(yea: 6, nay: 4, abstain: 0, yeaPct: 60)
        let byKey = try Self.stats(byDistrict: ["VA-11": ("VA", "VA-11", totals)])
        let legacyKey = try Self.stats(byDistrict: ["VA|11": ("VA", "11", totals)])
        let odd = try Self.stats(byDistrict: ["x": ("va", "011", totals)])
        for (stats, userDistrict) in [(byKey, "11"), (byKey, "VA-11"), (legacyKey, "11"), (odd, "11th"), (byKey, "va-11")] {
            let rollup = VoteResultsFormatting.districtRollup(in: stats, stateCode: "VA", district: userDistrict)
            XCTAssertEqual(rollup?.totals.decisionVotes, 10, userDistrict)
            XCTAssertEqual(rollup?.totals.yeaPct, 60, userDistrict)
        }
        XCTAssertNil(VoteResultsFormatting.districtRollup(in: byKey, stateCode: "VA", district: "10"))
        XCTAssertNil(VoteResultsFormatting.districtRollup(in: byKey, stateCode: "MD", district: "11"))
        XCTAssertNil(VoteResultsFormatting.districtRollup(in: byKey, stateCode: "VA", district: " "))
    }

    func testDistrictLabels() {
        XCTAssertEqual(VoteResultsFormatting.districtLabel(stateCode: "VA", district: "11"), "VA-11")
        XCTAssertEqual(VoteResultsFormatting.districtLabel(stateCode: "va", district: "VA-011"), "VA-11")
        XCTAssertEqual(VoteResultsFormatting.districtLabel(stateCode: "AK", district: "At-Large"), "AK at-large")
        XCTAssertEqual(VoteResultsFormatting.districtLabel(stateCode: "AK", district: "0"), "AK at-large")
        XCTAssertEqual(VoteResultsFormatting.districtLabel(stateCode: "VA", district: ""), "VA")
    }

    // MARK: - Map

    /// A region shows no abstain count (UX-34 changed this test from "· 2 abstained"): Everyone's abstained line
    /// minus a region's would count the abstentions outside it.
    func testMapSelectionText() {
        XCTAssertEqual(
            VoteResultsFormatting.mapSelectionText(name: "Virginia", yeaPct: 55.4, yea: 5, nay: 4, decisionVotes: 9, floor: 5),
            "Virginia · 55% Yea · 45% Nay · 9 verified votes"
        )
        XCTAssertEqual(
            VoteResultsFormatting.mapSelectionText(name: "Virginia", yeaPct: 60, yea: 3, nay: 2, decisionVotes: 5, floor: 5),
            "Virginia · 60% Yea · 40% Nay · 5 verified votes"
        )
        XCTAssertEqual(
            VoteResultsFormatting.mapSelectionText(name: "VA-11", yeaPct: 100, yea: 4, nay: 0, decisionVotes: 4, floor: 5),
            "VA-11 · Fewer than 5 votes so far"
        )
        XCTAssertEqual(
            VoteResultsFormatting.mapSelectionText(name: "Ohio", yeaPct: nil, yea: 0, nay: 0, decisionVotes: 0, floor: 5),
            "Ohio · Fewer than 5 votes so far"
        )
    }

    /// The map's selection prints a district as a code and VoiceOver reads it in the one spoken form (project
    /// decision of 2026-10-21), on the map's value and the selection card's alike; a state is its name in both.
    func testTheMapSelectionReadsTheRegionInWords() {
        XCTAssertEqual(VoteResultsFormatting.regionSpokenName(id: "VA", label: "VA"), "Virginia")
        XCTAssertEqual(VoteResultsFormatting.regionSpokenName(id: "GU", label: "GU"), "Guam")
        XCTAssertEqual(VoteResultsFormatting.regionSpokenName(id: "VA-01", label: "VA-01"), "Virginia's 1st district")
        XCTAssertEqual(VoteResultsFormatting.regionSpokenName(id: "VA-11", label: "VA-11"), "Virginia's 11th district")
        XCTAssertEqual(VoteResultsFormatting.regionSpokenName(id: "AK-AL", label: "AK-AL"), "Alaska's at-large district")
        XCTAssertEqual(VoteResultsFormatting.regionSpokenName(id: "zz", label: ""), "zz", "no spoken form: as printed")

        let district = VoterMapSelection(
            stat: VoterMapRegionStat(id: "VA-11", label: "VA-11", yeaPct: 55.6, yea: 5, nay: 4, decisionVotes: 9, abstainVotes: 2),
            minDecisionVotes: 5
        )
        XCTAssertEqual(district.regionId, "VA-11")
        XCTAssertEqual(district.text, "VA-11 · 56% Yea · 44% Nay · 9 verified votes")
        XCTAssertEqual(district.spokenText, "Virginia's 11th district · 56% Yea · 44% Nay · 9 verified votes")

        let atLarge = VoterMapSelection(stat: .empty(id: "AK-AL", label: "AK-AL"), minDecisionVotes: 5)
        XCTAssertEqual(atLarge.text, "AK at-large · Fewer than 5 votes so far")
        XCTAssertEqual(atLarge.spokenText, "Alaska's at-large district · Fewer than 5 votes so far")

        let state = VoterMapSelection(stat: .empty(id: "VA", label: "VA"), minDecisionVotes: 5)
        XCTAssertEqual(state.text, "Virginia · Fewer than 5 votes so far")
        XCTAssertEqual(state.spokenText, state.text)
    }

    func testRegionNames() {
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "VA", label: "VA"), "Virginia")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "DC", label: "DC"), "District of Columbia")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "VA-01", label: "VA-01"), "VA-1")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "VA-11", label: "VA-11"), "VA-11")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "AK-AL", label: "AK-AL"), "AK at-large")
        XCTAssertEqual(VoteResultsFormatting.regionDisplayName(id: "zz", label: ""), "zz")
    }

    func testEveryStateAndDCHasAName() {
        let codes = ["AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS",
                     "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY",
                     "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV",
                     "WI", "WY"]
        XCTAssertEqual(codes.count, 51)
        for code in codes {
            XCTAssertNotNil(VoteResultsFormatting.stateName(code), code)
        }
        XCTAssertEqual(VoteResultsFormatting.stateName(" va "), "Virginia")
        XCTAssertNil(VoteResultsFormatting.stateName("XX"))
    }

    func testLegendVoiceOverDescribesTheScaleAndTheHatch() {
        XCTAssertEqual(
            VoteResultsFormatting.mapLegendAccessibilityValue(floor: 5),
            "Colour scale from 100 percent Nay in orange to 100 percent Yea in teal; hatched areas have fewer than 5 votes."
        )
    }

    // MARK: - Fixtures

    /// A `VoteBucket` as the server sends it; `weightedYeaPct` nil leaves every weighted field out.
    static func totals(yea: Int, nay: Int, abstain: Int, yeaPct: Double?, weightedYeaPct: Double? = nil) -> String {
        let pct = yeaPct.map { "\($0)" } ?? "null"
        var json = #""votes":\#(yea + nay + abstain),"yea":\#(yea),"nay":\#(nay),"abstain":\#(abstain),"decisionVotes":\#(yea + nay),"yeaPct":\#(pct)"#
        if let weightedYeaPct {
            json += #","weightedVotes":\#(yea + nay + abstain),"weightedYea":\#(yea),"weightedNay":\#(nay),"weightedAbstain":\#(abstain),"weightedDecisionVotes":\#(yea + nay),"weightedYeaPct":\#(weightedYeaPct)"#
        }
        return "{\(json)}"
    }

    static func stats(
        totals: String? = nil,
        verified: String? = nil,
        comparison: String? = nil,
        byState: [String: String] = [:],
        byDistrict: [String: (state: String, district: String, totals: String)] = [:]
    ) throws -> BillStatsService.BillStats {
        let empty = Self.totals(yea: 0, nay: 0, abstain: 0, yeaPct: nil)
        let totals = totals ?? empty
        let verified = verified ?? empty
        let states = byState.map { code, bucket in
            #""\#(code)":{"state":"\#(code)","totals":\#(bucket),"segments":{"verified":\#(bucket),"selfAttested":\#(empty)}}"#
        }.joined(separator: ",")
        let districts = byDistrict.map { key, value in
            #""\#(key)":{"state":"\#(value.state)","district":"\#(value.district)","totals":\#(value.totals),"segments":{"verified":\#(value.totals),"selfAttested":\#(empty)}}"#
        }.joined(separator: ",")
        var body = #"{"billId":"BILLS-119hr1ih","generatedAt":"2026-10-08T12:00:00.000Z","totals":\#(totals),"segments":{"verified":\#(verified),"selfAttested":\#(empty)},"rollups":{"byState":{\#(states)},"byDistrict":{\#(districts)}},"reasonBreakdown":null"#
        if let comparison {
            body += #","comparison":\#(comparison)"#
        }
        body += "}"
        return try JSONDecoder.convertingFromSnakeCase().decode(BillStatsService.BillStats.self, from: Data(body.utf8))
    }
}
