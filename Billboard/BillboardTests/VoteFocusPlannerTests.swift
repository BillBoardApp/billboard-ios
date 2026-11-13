import XCTest
@testable import Billboard

/// Where the bill page moves VoiceOver focus around a vote, and what it announces (Civic Record spec 3.10.3,
/// 7.3), one test per transition of `VoteFocusPlanner`. The VoiceOver pass on a device (10.5) checks the same.
@MainActor
final class VoteFocusPlannerTests: XCTestCase {
    private static let october17: Date = {
        var components = DateComponents(year: 2026, month: 10, day: 17, hour: 12)
        components.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private func stamp(_ choice: VoteChoice) -> BallotStampCopy {
        BallotStampCopy(
            choice: choice,
            votedAt: Self.october17,
            now: Self.october17,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "America/New_York")!
        )
    }

    // MARK: Commit

    /// With VoiceOver running a commit says nothing yet: focus moves to the stamp once it settles, so the
    /// stamp's one-time label is what VoiceOver reads, and the two never talk over each other.
    func testACommitWithVoiceOverWaitsForTheStampAndGivesItItsOneTimeLabel() {
        var planner = VoteFocusPlanner()
        let plan = planner.handle(.committed(stamp(.yea), isChange: false, opensResults: true), voiceOverRunning: true)
        XCTAssertEqual(plan, .nothing, "no focus and no announcement at the commit")
        XCTAssertEqual(planner.oneTimeStampLabel, "You voted Yea on October 17.")
    }

    /// Without VoiceOver (a Switch Control or Voice Control commit) "You voted Yea." is announced at once.
    func testACommitWithoutVoiceOverAnnouncesTheVote() {
        var planner = VoteFocusPlanner()
        let plan = planner.handle(.committed(stamp(.yea), isChange: false, opensResults: true), voiceOverRunning: false)
        XCTAssertEqual(plan, VoteFocusPlanner.Plan(announcement: "You voted Yea."))
        XCTAssertNil(planner.oneTimeStampLabel)

        var abstain = VoteFocusPlanner()
        XCTAssertEqual(
            abstain.handle(.committed(stamp(.abstain), isChange: false, opensResults: true), voiceOverRunning: false).announcement,
            "You abstained."
        )
    }

    /// A change: "Your vote is now Nay." as the stamp's one-time label, or announced without VoiceOver.
    func testAChangeSaysYourVoteIsNow() {
        var withVoiceOver = VoteFocusPlanner()
        _ = withVoiceOver.handle(.committed(stamp(.nay), isChange: true, opensResults: false), voiceOverRunning: true)
        XCTAssertEqual(withVoiceOver.oneTimeStampLabel, "Your vote is now Nay.")

        var without = VoteFocusPlanner()
        XCTAssertEqual(
            without.handle(.committed(stamp(.nay), isChange: true, opensResults: false), voiceOverRunning: false).announcement,
            "Your vote is now Nay."
        )
    }

    // MARK: Settled

    /// The stamp settled (460 ms, 200 ms with Reduce Motion): focus moves to it, once.
    func testTheSettledStampTakesFocusOnce() {
        var planner = VoteFocusPlanner()
        _ = planner.handle(.committed(stamp(.yea), isChange: false, opensResults: true), voiceOverRunning: true)
        XCTAssertEqual(planner.handle(.settled, voiceOverRunning: true), VoteFocusPlanner.Plan(focus: .stamp))
        XCTAssertEqual(planner.handle(.settled, voiceOverRunning: true), .nothing, "a second settle moves nothing")
        XCTAssertEqual(planner.oneTimeStampLabel, "You voted Yea on October 17.", "the label lasts until focus leaves")
        XCTAssertEqual(planner.handle(.stampFocusLeft, voiceOverRunning: true), .nothing)
        XCTAssertNil(planner.oneTimeStampLabel, "then the stamp reads its usual label")
    }

    /// Without VoiceOver nothing moves focus when the stamp settles; and nothing settles without a commit.
    func testWithoutVoiceOverOrACommitTheStampTakesNoFocus() {
        var planner = VoteFocusPlanner()
        XCTAssertEqual(planner.handle(.settled, voiceOverRunning: true), .nothing, "no commit")
        _ = planner.handle(.committed(stamp(.yea), isChange: false, opensResults: true), voiceOverRunning: false)
        XCTAssertEqual(planner.handle(.settled, voiceOverRunning: false), .nothing)
    }

    // MARK: Stats arrived

    /// The stats for the vote arrive: "Results are open.", queued, once; not for a change under Results that
    /// were already open.
    func testTheStatsForTheVoteAnnounceResultsAreOpenOnce() {
        var planner = VoteFocusPlanner()
        XCTAssertEqual(planner.handle(.statsArrived(belowFloor: nil), voiceOverRunning: true), .nothing, "stats on open, no vote here")
        _ = planner.handle(.committed(stamp(.yea), isChange: false, opensResults: true), voiceOverRunning: true)
        _ = planner.handle(.settled, voiceOverRunning: true)
        XCTAssertEqual(planner.handle(.statsArrived(belowFloor: nil), voiceOverRunning: true), VoteFocusPlanner.Plan(announcement: "Results are open."))
        XCTAssertEqual(planner.handle(.statsArrived(belowFloor: nil), voiceOverRunning: true), .nothing, "R2's second fetch 4 s later says nothing")

        var change = VoteFocusPlanner()
        _ = change.handle(.committed(stamp(.nay), isChange: true, opensResults: false), voiceOverRunning: true)
        XCTAssertEqual(change.handle(.statsArrived(belowFloor: nil), voiceOverRunning: true), .nothing, "Results were open already")
        XCTAssertEqual(BillVoteBarModel.resultsOpenAnnouncement, "Results are open.")
    }

    /// Under the floor (UX-34) the stats announce the floor line's words, not "Results are open.", which the
    /// Results element would then contradict; still once. The project decision of 2026-10-29 changed this test: the
    /// line has no count any more, so the announcement is "Results open at 5 Yea or Nay votes." (it was "… 3 so
    /// far."), the same for the first voter, a later one and an abstention.
    func testTheStatsUnderTheFloorAnnounceTheFloorLine() {
        let floorLine = VoteResultsFormatting.FloorLine(floor: 5)
        var planner = VoteFocusPlanner()
        _ = planner.handle(.committed(stamp(.yea), isChange: false, opensResults: true), voiceOverRunning: true)
        _ = planner.handle(.settled, voiceOverRunning: true)
        XCTAssertEqual(
            planner.handle(.statsArrived(belowFloor: floorLine), voiceOverRunning: true),
            VoteFocusPlanner.Plan(announcement: "Results open at 5 Yea or Nay votes.")
        )
        XCTAssertEqual(planner.handle(.statsArrived(belowFloor: floorLine), voiceOverRunning: true), .nothing, "once")

        // An abstention, without VoiceOver (Switch Control, Voice Control): the same line.
        var abstained = VoteFocusPlanner()
        _ = abstained.handle(.committed(stamp(.abstain), isChange: false, opensResults: true), voiceOverRunning: false)
        XCTAssertEqual(
            abstained.handle(.statsArrived(belowFloor: floorLine), voiceOverRunning: false),
            VoteFocusPlanner.Plan(announcement: "Results open at 5 Yea or Nay votes.")
        )

        var change = VoteFocusPlanner()
        _ = change.handle(.committed(stamp(.nay), isChange: true, opensResults: false), voiceOverRunning: true)
        XCTAssertEqual(change.handle(.statsArrived(belowFloor: floorLine), voiceOverRunning: true), .nothing, "Results were open already")
    }

    // MARK: Refused

    /// A refusal moves focus to the refusal strip and ends the moment: the stamp takes no focus, its one-time
    /// label is gone, and no "Results are open." follows.
    func testARefusalMovesFocusToTheStripAndEndsTheMoment() {
        var planner = VoteFocusPlanner()
        _ = planner.handle(.committed(stamp(.yea), isChange: false, opensResults: true), voiceOverRunning: true)
        XCTAssertEqual(planner.handle(.refused, voiceOverRunning: true), VoteFocusPlanner.Plan(focus: .refusal))
        XCTAssertNil(planner.oneTimeStampLabel)
        XCTAssertEqual(planner.handle(.settled, voiceOverRunning: true), .nothing, "no focus on a stamp that went back")
        XCTAssertEqual(planner.handle(.statsArrived(belowFloor: nil), voiceOverRunning: true), .nothing)

        var withoutVoiceOver = VoteFocusPlanner()
        XCTAssertEqual(withoutVoiceOver.handle(.refused, voiceOverRunning: false), VoteFocusPlanner.Plan(focus: .refusal))
    }

    // MARK: Actions

    /// The stamp's "Go to Results" goes to the Results title; the sealed sheet's "Go to vote buttons" to the
    /// first vote button.
    func testTheActionsMoveFocus() {
        var planner = VoteFocusPlanner()
        XCTAssertEqual(planner.handle(.goToResults, voiceOverRunning: true), VoteFocusPlanner.Plan(focus: .resultsHeader))
        XCTAssertEqual(planner.handle(.goToVoteButtons, voiceOverRunning: true), VoteFocusPlanner.Plan(focus: .voteButtons))
        XCTAssertEqual(BillVoteBarModel.goToResultsAction, "Go to Results")
        XCTAssertEqual(VoteResultsFormatting.goToVoteButtonsAction, "Go to vote buttons")
    }

    // MARK: Timings (spec 5.1)

    func testTheMomentsTimings() {
        XCTAssertEqual(BallotMoment.inkHold(reduceMotion: false), 0.18)
        XCTAssertEqual(BallotMoment.inkHold(reduceMotion: true), 0, "Reduce Motion: the cross-fade starts at once")
        XCTAssertEqual(BallotMoment.settled(reduceMotion: false), 0.46)
        XCTAssertEqual(BallotMoment.settled(reduceMotion: true), 0.2)
        XCTAssertEqual(BillDetail.yourVoteScrollDelay, 0.4)
    }
}
