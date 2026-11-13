import SwiftUI
import XCTest
@testable import Billboard

/// `CivicScoreStore` and `CivicProfileStore` against a fake civic service, when they read again (UX-39
/// N11), and the R2 colours and copy of the civic cards (spec D 2.3.2, 2.4.2).
final class CivicStoresTests: XCTestCase {
    @MainActor
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "CivicStoresTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return defaults
    }

    @MainActor
    private func score(_ value: Int) -> CivicScore {
        let empty = CivicScore.empty
        return CivicScore(
            civicScore: value,
            totalVotes: 4,
            currentStreak: 2,
            longestStreak: 3,
            lastVotedAt: nil,
            recentVoteDays: nil,
            voteScore: value,
            streakBonus: 0,
            honorBonus: 0,
            coverageAreaCount: 1,
            rank: empty.rank,
            nextRank: nil,
            scoreToNextRank: 0,
            honors: []
        )
    }

    @MainActor
    func testScoreRefreshPublishesAndCachesTheScore() async throws {
        let defaults = try isolatedDefaults()
        let service = FakeCivicService()
        service.scoreResult = .success(score(42))
        let store = CivicScoreStore(scope: "user-1", userDefaults: defaults, service: service)

        await store.refresh()

        XCTAssertEqual(store.score.civicScore, 42)
        XCTAssertTrue(store.hasRefreshedOnce)
        XCTAssertNil(store.lastError)

        // A new store for the same user starts from the cached score.
        let restored = CivicScoreStore(scope: "user-1", userDefaults: defaults, service: FakeCivicService())
        XCTAssertEqual(restored.score.civicScore, 42)
    }

    @MainActor
    func testScoreRefreshFailureKeepsTheScoreAndReportsIt() async throws {
        let service = FakeCivicService()
        service.scoreResult = .failure(FakeServiceError())
        let store = CivicScoreStore(scope: "user-1", userDefaults: try isolatedDefaults(), service: service)

        await store.refresh()

        XCTAssertEqual(store.score, .empty)
        // R2's load-failure copy, shown in the Civic Rank sheet (UX-39 N11).
        XCTAssertEqual(store.lastError, "We couldn't load your Civic Rank right now. Try again in a moment.")
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testProfileRefreshFailureReportsIt() async {
        let service = FakeCivicService()
        service.profileResult = .failure(FakeServiceError())
        let store = CivicProfileStore(service: service)

        await store.refresh()

        XCTAssertEqual(store.lastError, "We couldn't load your Civic Profile right now. Try again in a moment.")
        XCTAssertFalse(store.hasRefreshedOnce)
    }

    // MARK: - Nothing false before the first read (UX-39 N11)

    /// Until the first read ends the score is `.empty` ("Citizen", top rank reached, 0 and 0): the phase says
    /// loading, then failed with R2's message, then loaded; a later failure keeps the score on screen.
    @MainActor
    func testScorePhaseIsLoadingThenFailedOrLoaded() async throws {
        let service = FakeCivicService()
        service.scoreResult = .failure(FakeServiceError())
        let store = CivicScoreStore(scope: "user-1", userDefaults: try isolatedDefaults(), service: service)
        XCTAssertEqual(store.phase, .loading)

        await store.refresh()
        XCTAssertEqual(store.phase, .failed("We couldn't load your Civic Rank right now. Try again in a moment."))

        service.scoreResult = .success(score(42))
        await store.refresh()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertNil(store.lastError)

        service.scoreResult = .failure(FakeServiceError())
        await store.refresh()
        XCTAssertEqual(store.phase, .loaded, "the last score stays")
        XCTAssertEqual(store.score.civicScore, 42)
    }

    /// The user's cached score is real: loaded at once, on the next launch.
    @MainActor
    func testACachedScoreIsLoadedAtOnce() async throws {
        let defaults = try isolatedDefaults()
        let service = FakeCivicService()
        service.scoreResult = .success(score(42))
        await CivicScoreStore(scope: "user-1", userDefaults: defaults, service: service).refresh()

        XCTAssertEqual(CivicScoreStore(scope: "user-1", userDefaults: defaults, service: FakeCivicService()).phase, .loaded)
        XCTAssertEqual(CivicScoreStore(scope: "user-2", userDefaults: defaults, service: FakeCivicService()).phase, .loading, "not another user's")
    }

    /// `CivicProfileResponse.empty` is a locked profile with 0 of 25 votes: not shown as the user's until
    /// the first read ends.
    @MainActor
    func testProfilePhaseIsLoadingThenFailedOrLoaded() async {
        let service = FakeCivicService()
        service.profileResult = .failure(FakeServiceError())
        let store = CivicProfileStore(service: service)
        XCTAssertEqual(store.phase, .loading)

        await store.refresh()
        XCTAssertEqual(store.phase, .failed("We couldn't load your Civic Profile right now. Try again in a moment."))

        let ready = CivicProfileResponse(axes: ["localVsFederal": 0.4], votesUsed: 30, totalVotesWithProfile: 30, minVotesRequired: 25, isReady: true)
        service.profileResult = .success(ready)
        await store.refresh()
        XCTAssertEqual(store.phase, .loaded)

        service.profileResult = .failure(FakeServiceError())
        await store.refresh()
        XCTAssertEqual(store.phase, .loaded, "the last profile stays")
        XCTAssertEqual(store.profile, ready)
    }

    /// A vote saved while a read runs may not be in it: the store reads once more when it ends, so the chips
    /// count the vote. Any other refresh asked for meanwhile joins the running read.
    @MainActor
    func testAVoteSavedDuringAReadIsReadAgainAfterIt() async throws {
        let service = SequencedCivicService()
        service.scores = [score(10), score(20)]
        let store = CivicScoreStore(scope: "user-1", userDefaults: try isolatedDefaults(), service: service)

        let running = Task { await store.refresh() }
        while service.scoreReads == 0 { await Task.yield() }
        await store.refresh()
        XCTAssertEqual(service.scoreReads, 1, "a plain refresh joins the running read")
        await store.refresh(afterSavedVote: true)
        service.gate.open()
        await running.value

        XCTAssertEqual(service.scoreReads, 2)
        XCTAssertEqual(store.score.civicScore, 20)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testAVoteSavedDuringAProfileReadIsReadAgainAfterIt() async {
        let service = SequencedCivicService()
        let locked = CivicProfileResponse(axes: [:], votesUsed: 24, totalVotesWithProfile: 24, minVotesRequired: 25, isReady: false)
        let ready = CivicProfileResponse(axes: ["localVsFederal": 0.4], votesUsed: 25, totalVotesWithProfile: 25, minVotesRequired: 25, isReady: true)
        service.profiles = [locked, ready]
        let store = CivicProfileStore(service: service)

        let running = Task { await store.refresh() }
        while service.profileReads == 0 { await Task.yield() }
        await store.refresh(afterSavedVote: true)
        service.gate.open()
        await running.value

        XCTAssertEqual(service.profileReads, 2)
        XCTAssertEqual(store.profile, ready)
    }

    /// The Civic Rank sheet, opened before the score came on a new device, starts the read and the launch
    /// read joins it; then the sheet is closed, which cancels its task. The read still ends and the score
    /// loads: the chips do not wait on "–" with no read left running.
    @MainActor
    func testAScoreReadOthersJoinedOutlivesTheCallerThatStartedIt() async throws {
        let service = CancellableCivicService()
        service.score = score(42)
        let store = CivicScoreStore(scope: "user-1", userDefaults: try isolatedDefaults(), service: service)

        let sheet = Task { await store.refresh() }
        while service.scoreReads == 0 { await Task.yield() }
        await store.refresh()
        sheet.cancel()
        service.answer()
        await sheet.value

        XCTAssertEqual(service.scoreReads, 1)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.score.civicScore, 42)
        XCTAssertFalse(store.isLoading)
    }

    /// The same for the Civic Profile: a screen that started the read goes away (a tab switched) after
    /// another refresh joined it.
    @MainActor
    func testAProfileReadOthersJoinedOutlivesTheCallerThatStartedIt() async {
        let service = CancellableCivicService()
        let ready = CivicProfileResponse(axes: ["localVsFederal": 0.4], votesUsed: 30, totalVotesWithProfile: 30, minVotesRequired: 25, isReady: true)
        service.profile = ready
        let store = CivicProfileStore(service: service)

        let screen = Task { await store.refresh() }
        while service.profileReads == 0 { await Task.yield() }
        await store.refresh()
        screen.cancel()
        service.answer()
        await screen.value

        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.profile, ready)
        XCTAssertFalse(store.isLoading)
    }

    // MARK: - A member page's read of your profile (UX-39 N11)

    private static let readyMember = CivicProfileResponse(
        axes: ["localVsFederal": 0.55, "privacyVsSecurity": 0.75],
        votesUsed: 40,
        totalVotesWithProfile: 40,
        minVotesRequired: 25,
        isReady: true
    )

    /// A member page whose read of your profile fails (offline, a timeout, a 5xx) reads it once and shows its
    /// "Couldn't load" line. The card's task used to be keyed on the store's state, which a failed read set back
    /// to "not read yet, not reading", so it started another read at once: about 200 requests in 2 seconds.
    @MainActor
    func testAMemberPageReadsYourProfileOnceWhenTheReadFails() {
        let service = ScriptedCivicService(profiles: [.failure(URLError(.notConnectedToInternet))])
        let store = CivicProfileStore(service: service)
        let host = AccessibilityTreeText.Host(
            ScrollView {
                CongressMemberCivicProfileCard(mode: .profile(Self.readyMember), memberName: "Jordan Ellis")
            }
            .environmentObject(store),
            size: CGSize(width: 390, height: 2000),
            settle: 0.1
        )
        defer { host.close() }

        host.run(1.5)

        XCTAssertEqual(service.profileReads, 1, "one read, not a loop of them")
        XCTAssertFalse(store.isLoading)
        guard case .failed = store.phase else { return XCTFail("phase \(store.phase)") }
        XCTAssertTrue(host.identifiers().contains("member.civicProfile.comparison.error"), "the Couldn't load line")
    }

    /// A member page opened after a read failed elsewhere (Profile, offline) reads your profile once more, so
    /// Compare to you can come back without a return to the app.
    @MainActor
    func testAMemberPageReadsYourProfileAgainAfterAnEarlierFailure() {
        let ready = CivicProfileResponse(axes: ["localVsFederal": 0.4], votesUsed: 30, totalVotesWithProfile: 30, minVotesRequired: 25, isReady: true)
        let service = ScriptedCivicService(profiles: [.failure(URLError(.timedOut)), .success(ready)])
        let store = CivicProfileStore(service: service)
        Task { await store.refresh() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard case .failed = store.phase else { return XCTFail("phase \(store.phase)") }

        let host = AccessibilityTreeText.Host(
            ScrollView {
                CongressMemberCivicProfileCard(mode: .profile(Self.readyMember), memberName: "Jordan Ellis")
            }
            .environmentObject(store),
            size: CGSize(width: 390, height: 2000),
            settle: 0.1
        )
        defer { host.close() }

        host.run(1.0)

        XCTAssertEqual(service.profileReads, 2)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertTrue(host.identifiers().contains("member.civicProfile.compare"), "Compare to you is offered")
    }

    /// A member without a chart (still loading, or locked) never reads your profile: there is nothing to compare.
    @MainActor
    func testAMemberPageWithoutAChartDoesNotReadYourProfile() {
        let service = ScriptedCivicService(profiles: [.failure(URLError(.notConnectedToInternet))])
        let store = CivicProfileStore(service: service)
        let locked = CivicProfileResponse(axes: [:], votesUsed: 3, totalVotesWithProfile: 3, minVotesRequired: 25, isReady: false)
        for mode in [CongressMemberCivicProfileCardMode.loading, .unavailable, .profile(locked)] {
            let host = AccessibilityTreeText.Host(
                CongressMemberCivicProfileCard(mode: mode, memberName: "Jordan Ellis").environmentObject(store),
                size: CGSize(width: 390, height: 1200),
                settle: 0.3
            )
            host.close()
        }
        XCTAssertEqual(service.profileReads, 0)
    }

    // MARK: - When the civic figures are read again (UX-39 N11)

    /// Billboard's day is New York's: 9:30 PM EDT is still the 27th though it is the 28th in UTC, and the
    /// next day starts at Eastern midnight, 25 hours later on the day daylight time ends.
    func testTheDayTurnsOverAtMidnightInNewYork() throws {
        let iso = ISO8601DateFormatter()
        func date(_ text: String) throws -> Date { try XCTUnwrap(iso.date(from: text)) }

        XCTAssertEqual(EasternDay.key(for: try date("2026-10-28T01:30:00Z")), "2026-10-27")
        XCTAssertEqual(EasternDay.key(for: try date("2026-10-28T04:00:00Z")), "2026-10-28")
        XCTAssertEqual(EasternDay.nextStart(after: try date("2026-10-28T01:30:00Z")), try date("2026-10-28T04:00:00Z"))
        XCTAssertEqual(EasternDay.nextStart(after: try date("2026-10-31T12:00:00Z")), try date("2026-11-01T04:00:00Z"))
        XCTAssertEqual(EasternDay.nextStart(after: try date("2026-11-01T04:00:00Z")), try date("2026-11-02T05:00:00Z"))
        XCTAssertEqual(EasternDay.key(for: try date("2026-11-02T04:30:00Z")), "2026-11-01")
    }

    /// Only a return from the background reads again: not launch, and not a Control Center pull or a system
    /// alert, which take the app through inactive only.
    func testOnlyAReturnFromTheBackgroundCounts() {
        var detector = ForegroundReturnDetector()
        XCTAssertFalse(detector.didReturn(to: .active), "launch")
        XCTAssertFalse(detector.didReturn(to: .inactive))
        XCTAssertFalse(detector.didReturn(to: .active), "Control Center")
        XCTAssertFalse(detector.didReturn(to: .inactive))
        XCTAssertFalse(detector.didReturn(to: .background))
        XCTAssertFalse(detector.didReturn(to: .inactive))
        XCTAssertTrue(detector.didReturn(to: .active), "back from the background")
        XCTAssertFalse(detector.didReturn(to: .inactive))
        XCTAssertFalse(detector.didReturn(to: .active), "once per return")
    }

    // MARK: - Civic Rank (Civic Record spec 4.65)

    @MainActor
    private func score(civicScore: Int, rank: CivicRank, next: CivicRank?, honors: [CivicHonor] = []) -> CivicScore {
        CivicScore(
            civicScore: civicScore,
            totalVotes: 52,
            currentStreak: 4,
            longestStreak: 9,
            lastVotedAt: nil,
            recentVoteDays: nil,
            voteScore: 260,
            streakBonus: 30,
            honorBonus: 50,
            coverageAreaCount: 4,
            rank: rank,
            nextRank: next,
            scoreToNextRank: next.map { $0.minScore - civicScore } ?? 0,
            honors: honors
        )
    }

    /// Progress is counted inside the current rank, so the bar and its words agree.
    @MainActor
    func testRankProgressIsCountedWithinTheRank() {
        let steward = CivicRank(id: "steward", title: "Steward", minScore: 250, approxVotesRequired: 40)
        let advocate = CivicRank(id: "advocate", title: "Advocate", minScore: 500, approxVotesRequired: 80)
        let summary = CivicRankSummary(score: score(civicScore: 340, rank: steward, next: advocate))

        XCTAssertEqual(summary.rankTitle, "Steward")
        XCTAssertEqual(summary.nextRankTitle, "Advocate")
        XCTAssertEqual(summary.progress, 90.0 / 250.0, accuracy: 0.0001)
        XCTAssertEqual(summary.progressText, "90 of 250 points to Advocate")
        XCTAssertEqual(summary.referenceText, "Advocate is about 80 votes.")
        XCTAssertEqual(summary.figures.map(\.label), ["Civic Score", "Bills voted", "Day streak", "Best streak"])
        XCTAssertEqual(summary.figures.map(\.answer), ["340", "52", "4", "9"])
        // UX-31 (project decision of 2026-10-29): the streak points are the best streak's, which never drop.
        XCTAssertEqual(summary.breakdown.map(\.label), ["Votes", "Best streak", "Honors"])
        XCTAssertEqual(summary.breakdown.map(\.answer), ["+260", "+30", "+50"])
        XCTAssertEqual(summary.coverageText, "4 issue areas represented")
    }

    @MainActor
    func testRankProgressStaysInsideTheBar() {
        let voice = CivicRank(id: "voice", title: "Voice", minScore: 100, approxVotesRequired: 10)
        let delegate = CivicRank(id: "delegate", title: "Delegate", minScore: 200, approxVotesRequired: 20)
        // A score under the rank's minimum (a stale cache) or past the next rank's (before the server moves the rank).
        XCTAssertEqual(CivicRankSummary(score: score(civicScore: 50, rank: voice, next: delegate)).progress, 0)
        XCTAssertEqual(CivicRankSummary(score: score(civicScore: 50, rank: voice, next: delegate)).progressText, "0 of 100 points to Delegate")
        XCTAssertEqual(CivicRankSummary(score: score(civicScore: 260, rank: voice, next: delegate)).progress, 1)
        // A rank with no estimate says nothing about votes.
        let unknown = CivicRank(id: "x", title: "Next", minScore: 300, approxVotesRequired: 0)
        XCTAssertNil(CivicRankSummary(score: score(civicScore: 150, rank: voice, next: unknown)).referenceText)
    }

    @MainActor
    func testTopRankHasAFullBarAndSaysSo() {
        let champion = CivicRank(id: "champion", title: "Champion", minScore: 1000, approxVotesRequired: 200)
        let summary = CivicRankSummary(score: score(civicScore: 1200, rank: champion, next: nil))
        XCTAssertNil(summary.nextRankTitle)
        XCTAssertEqual(summary.progress, 1)
        XCTAssertEqual(summary.progressText, "Top rank reached")
        XCTAssertNil(summary.referenceText)
    }

    @MainActor
    func testHonorsAreListedByName() {
        let citizen = CivicRank(id: "citizen", title: "Citizen", minScore: 0, approxVotesRequired: 0)
        let honors = [
            CivicHonor(id: "first-vote", title: "First vote", description: "", bonusScore: 10, category: "unlock"),
            CivicHonor(id: "ten-votes", title: "10 votes", description: "", bonusScore: 20, category: "participation")
        ]
        let summary = CivicRankSummary(score: score(civicScore: 30, rank: citizen, next: nil, honors: honors))
        XCTAssertEqual(summary.honors, ["First vote", "10 votes"])
    }

    // MARK: - Civic profile chart and copy (spec D 2.4.2)

    /// Civic Record spec 3.27: the chart is ink only, so two profiles are told apart by line style, the
    /// member solid and you dashed, never by hue.
    @MainActor
    func testRadarTellsTwoProfilesApartByLineStyle() {
        let datasets = CongressMemberCivicProfileCard.comparisonDatasets(member: .empty, user: .empty, memberName: "Tim Kaine")
        XCTAssertEqual(datasets.map(\.label), ["Tim Kaine", "You"])
        XCTAssertEqual(datasets.map(\.style), [.solid, .dashed])
        XCTAssertEqual(RadarChartDataset(profile: .empty, label: "You").style, .solid, "one profile is the solid line")
    }

    @MainActor
    func testRadarScoreLineSaysNotEnoughDataInsteadOfSignal() {
        XCTAssertEqual(RadarChartView.scoreText(subjectLabel: "You", score: 7), "You: 7/10")
        XCTAssertEqual(RadarChartView.scoreText(subjectLabel: "Member", score: nil), "Not enough data")
        XCTAssertEqual(RadarChartView.notEnoughDataText, "Not enough data")
    }

    @MainActor
    func testCivicProfileCopySaysThemeNotAxisOrSignal() {
        let copy = [
            CivicProfileCopy.title,
            CivicProfileCopy.missingThemesNote,
            CivicProfileCopy.basedOn(votes: 47),
            CivicProfileCopy.unlockPrompt(votesRemaining: 3),
            CivicProfileInfoCopy.title,
            CivicProfileInfoCopy.body
        ]
        for text in copy {
            for retired in ["axis", "axes", "signal", "dimension", "lean"] {
                XCTAssertNil(
                    text.range(of: "\\b\(retired)\\b", options: [.regularExpression, .caseInsensitive]),
                    "\"\(text)\" uses \(retired)"
                )
            }
        }
        XCTAssertEqual(CivicProfileCopy.title, "Your Civic Profile")
        XCTAssertEqual(CivicProfileCopy.missingThemesNote, "Some themes need more votes before they get a score.")
        XCTAssertEqual(CivicProfileCopy.basedOn(votes: 1), "Based on 1 vote")

        // Project decision of 2026-10-29: the server reads only the last 100 Yea or Nay votes on bills with theme
        // scores, so a count under the total of those votes says so; at or under 100 every vote counts.
        func profile(_ used: Int, of total: Int) -> CivicProfileResponse {
            CivicProfileResponse(axes: [:], votesUsed: used, totalVotesWithProfile: total, minVotesRequired: 25, isReady: used >= 25)
        }
        XCTAssertEqual(CivicProfileCopy.basedOn(profile(100, of: 312)), "Based on your last 100 votes")
        XCTAssertEqual(CivicProfileCopy.basedOn(profile(100, of: 101)), "Based on your last 100 votes")
        XCTAssertEqual(CivicProfileCopy.basedOn(profile(100, of: 100)), "Based on 100 votes")
        XCTAssertEqual(CivicProfileCopy.basedOn(profile(47, of: 47)), "Based on 47 votes")
        XCTAssertEqual(CivicProfileCopy.basedOn(profile(1, of: 1)), "Based on 1 vote")
        XCTAssertEqual(CivicProfileCopy.unlockPrompt(votesRemaining: 1), "Vote on 1 more bill to unlock your Civic Profile")
        XCTAssertTrue(CivicProfileInfoCopy.body.contains(RadarChartView.notEnoughDataText))
    }

    /// Compare to you on a member page says your chart is capped exactly when Profile does (project decision of
    /// 2026-10-29): "Your chart is based on your last 100 bill votes." beside "Based on your last 100 votes", by the
    /// one test in `CivicProfileCopy.isCapped`; otherwise its line is unchanged.
    @MainActor
    func testTheMemberPageSaysYourChartIsCappedWhenProfileDoes() {
        func profile(_ used: Int, of total: Int) -> CivicProfileResponse {
            CivicProfileResponse(axes: [:], votesUsed: used, totalVotesWithProfile: total, minVotesRequired: 25, isReady: used >= 25)
        }
        XCTAssertEqual(CongressMemberCivicProfileCopy.yourChartBasis(profile(100, of: 312)), "Your chart is based on your last 100 bill votes.")
        XCTAssertEqual(CongressMemberCivicProfileCopy.yourChartBasis(profile(100, of: 101)), "Your chart is based on your last 100 bill votes.")
        XCTAssertEqual(CongressMemberCivicProfileCopy.yourChartBasis(profile(100, of: 100)), "Your chart is based on 100 bill votes.")
        XCTAssertEqual(CongressMemberCivicProfileCopy.yourChartBasis(profile(47, of: 47)), "Your chart is based on 47 bill votes.")
        XCTAssertEqual(CongressMemberCivicProfileCopy.yourChartBasis(profile(1, of: 1)), "Your chart is based on 1 bill vote.")

        for (used, total) in [(100, 312), (100, 101), (100, 100), (99, 99), (47, 47), (25, 25), (1, 1)] {
            let user = profile(used, of: total)
            let profileSaysCapped = CivicProfileCopy.basedOn(user).contains("your last")
            let memberPageSaysCapped = CongressMemberCivicProfileCopy.yourChartBasis(user).contains("your last")
            XCTAssertEqual(profileSaysCapped, CivicProfileCopy.isCapped(user), "\(used) of \(total)")
            XCTAssertEqual(memberPageSaysCapped, profileSaysCapped, "\(used) of \(total): the two pages agree")
        }
    }
}

/// Civic reads answered in turn from `scores` and `profiles`; the first read of each kind waits at `gate`.
@MainActor
private final class SequencedCivicService: CivicServicing {
    let gate = Gate()
    var scores: [CivicScore] = []
    var profiles: [CivicProfileResponse] = []
    private(set) var scoreReads = 0
    private(set) var profileReads = 0

    func fetchCivicScore() async throws -> CivicScore {
        scoreReads += 1
        let read = scoreReads
        if read == 1 { await gate.wait() }
        return scores[min(read, scores.count) - 1]
    }

    func fetchCivicProfile() async throws -> CivicProfileResponse {
        profileReads += 1
        let read = profileReads
        if read == 1 { await gate.wait() }
        return profiles[min(read, profiles.count) - 1]
    }
}

/// Civic reads that wait for `answer()` and, like URLSession's, throw `CancellationError` when the task
/// that runs them is cancelled first.
@MainActor
private final class CancellableCivicService: CivicServicing {
    var score: CivicScore = .empty
    var profile: CivicProfileResponse = .empty
    private var isAnswered = false
    private(set) var scoreReads = 0
    private(set) var profileReads = 0

    func answer() { isAnswered = true }

    func fetchCivicScore() async throws -> CivicScore {
        scoreReads += 1
        try await waitForAnswer()
        return score
    }

    func fetchCivicProfile() async throws -> CivicProfileResponse {
        profileReads += 1
        try await waitForAnswer()
        return profile
    }

    private func waitForAnswer() async throws {
        while !isAnswered { try await Task.sleep(for: .milliseconds(1)) }
    }
}

/// Civic Profile reads that each take a few milliseconds, as a request does, and end with the next of
/// `profiles` (the last one repeats). Counts the reads.
@MainActor
private final class ScriptedCivicService: CivicServicing {
    private let profiles: [Result<CivicProfileResponse, Error>]
    private(set) var profileReads = 0

    init(profiles: [Result<CivicProfileResponse, Error>]) {
        self.profiles = profiles
    }

    func fetchCivicScore() async throws -> CivicScore { .empty }

    func fetchCivicProfile() async throws -> CivicProfileResponse {
        profileReads += 1
        let outcome = profiles[min(profileReads, profiles.count) - 1]
        try await Task.sleep(for: .milliseconds(5))
        return try outcome.get()
    }
}
