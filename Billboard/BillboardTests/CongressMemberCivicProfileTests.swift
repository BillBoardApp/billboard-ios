import XCTest
@testable import Billboard

final class CongressMemberCivicProfileTests: XCTestCase {
    @MainActor
    func testDecodeCongressMemberCivicProfilePayload() throws {
        let json = """
        {
          "axes": {
            "individualVsCommunity": 0.65,
            "localVsFederal": 0.55
          },
          "votesUsed": 47,
          "totalVotesWithProfile": 80,
          "sponsoredBillsUsed": 12,
          "cosponsoredBillsUsed": 9,
          "totalEvidenceUsed": 68,
          "totalEvidenceWithProfile": 110,
          "minEvidenceRequired": 25,
          "isReady": true
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(CivicProfileResponse.self, from: data)

        XCTAssertEqual(decoded.votesUsed, 47)
        XCTAssertEqual(decoded.totalVotesWithProfile, 80)
        XCTAssertEqual(decoded.sponsoredBillsUsed, 12)
        XCTAssertEqual(decoded.cosponsoredBillsUsed, 9)
        XCTAssertEqual(decoded.totalEvidenceUsed, 68)
        XCTAssertEqual(decoded.totalEvidenceWithProfile, 110)
        XCTAssertEqual(decoded.minEvidenceRequired, 25)
        XCTAssertTrue(decoded.isReady)
        XCTAssertEqual(decoded.value(for: .individualVsCommunity), 0.65, accuracy: 0.0001)
        XCTAssertEqual(decoded.value(for: .localVsFederal), 0.55, accuracy: 0.0001)
        XCTAssertNil(decoded.displayScoreIfAvailable(for: .freeMarketVsRegulated))
    }

    @MainActor
    func testDecodeLockedCongressMemberCivicProfilePayload() throws {
        let json = """
        {
          "axes": {},
          "votesUsed": 9,
          "totalVotesWithProfile": 12,
          "sponsoredBillsUsed": 4,
          "cosponsoredBillsUsed": 7,
          "totalEvidenceUsed": 20,
          "totalEvidenceWithProfile": 28,
          "minEvidenceRequired": 25,
          "isReady": false
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(CivicProfileResponse.self, from: data)

        XCTAssertEqual(decoded.evidenceRemaining, 5)
        XCTAssertFalse(decoded.isReady)
    }

    @MainActor
    func testCivicProfileMiddleDisplaysAsFiveAndMissingAxesHaveNoScore() throws {
        let profile = CivicProfileResponse(
            axes: ["localVsFederal": 0.5],
            votesUsed: 25,
            totalVotesWithProfile: 25,
            minVotesRequired: 25,
            isReady: true
        )

        XCTAssertEqual(profile.displayScore(for: .localVsFederal), 5)
        XCTAssertEqual(profile.displayScoreIfAvailable(for: .localVsFederal), 5)
        XCTAssertNil(profile.displayScoreIfAvailable(for: .privacyVsSecurity))
    }

    @MainActor
    func testUserCivicProfileToleratesMissingAndNullAxes() throws {
        let json = #"{"axes":{"individualVsCommunity":0.65,"localVsFederal":null},"votesUsed":30,"totalVotesWithProfile":30,"minVotesRequired":25,"isReady":true}"#
        let decoded = try JSONDecoder().decode(CivicProfileResponse.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.axes.count, 1)
        XCTAssertNil(decoded.signalValue(for: .localVsFederal))
        XCTAssertNil(decoded.displayScoreIfAvailable(for: .privacyVsSecurity))
        XCTAssertEqual(decoded.axesWithoutSignal.count, 5)

        let noAxesJSON = #"{"votesUsed":3,"totalVotesWithProfile":3,"isReady":false}"#
        let noAxes = try JSONDecoder().decode(CivicProfileResponse.self, from: Data(noAxesJSON.utf8))
        XCTAssertTrue(noAxes.axes.isEmpty)
    }

    // MARK: - UX-32: what holds a locked profile (billboard-backend services/src/shared/civicProfileReadiness.ts)

    /// GET /civic-profile as the server sends it, read as the app reads it (`JSONDecoder.usingDefaultKeys()`).
    @MainActor
    private func userProfile(_ json: String) throws -> CivicProfileResponse {
        try JSONDecoder.usingDefaultKeys().decode(CivicProfileResponse.self, from: Data(json.utf8))
    }

    /// A server that sends none of UX-32's fields (an older backend): they are nil, the profile is the vote lock and
    /// nothing changes.
    @MainActor
    func testAProfileWithoutTheThemeFieldsHasNoThemeLock() throws {
        let decoded = try userProfile(#"{"axes":{},"votesUsed":12,"totalVotesWithProfile":12,"minVotesRequired":25,"isReady":false}"#)
        XCTAssertNil(decoded.lockedBy)
        XCTAssertNil(decoded.themesReady)
        XCTAssertNil(decoded.minThemesRequired)
        XCTAssertNil(decoded.minThemeVotes)
        XCTAssertFalse(decoded.isLockedByThemes)
        XCTAssertNil(CivicProfileCopy.themeLock(decoded))
        XCTAssertEqual(CivicProfileCopy.spokenUnlockPrompt(decoded), "Vote on 13 more bills to unlock your Civic Profile")

        for empty in [CivicProfileResponse.empty, CivicProfileResponse(axes: [:], votesUsed: 3, totalVotesWithProfile: 3, minVotesRequired: 25, isReady: false)] {
            XCTAssertNil(empty.lockedBy)
            XCTAssertNil(empty.themesReady)
            XCTAssertNil(empty.minThemesRequired)
            XCTAssertNil(empty.minThemeVotes)
            XCTAssertNil(CivicProfileCopy.themeLock(empty))
        }
    }

    /// UX-32's locked profile held by its themes: the four fields decode, and the line reads the server's numbers,
    /// as approved on 2026-10-29 ("It opens once 3 themes each have 8 of your votes. 2 of 3 so far.").
    @MainActor
    func testAProfileHeldByItsThemesSaysWhatTheyNeed() throws {
        let decoded = try userProfile(
            #"{"axes":{"individualVsCommunity":0.6,"localVsFederal":0.4},"votesUsed":30,"totalVotesWithProfile":30,"minVotesRequired":33,"isReady":false,"lockedBy":"themes","themesReady":2,"minThemesRequired":3,"minThemeVotes":8}"#
        )
        XCTAssertEqual(decoded.lockedBy, "themes")
        XCTAssertEqual(decoded.themesReady, 2)
        XCTAssertEqual(decoded.minThemesRequired, 3)
        XCTAssertEqual(decoded.minThemeVotes, 8)
        XCTAssertTrue(decoded.isLockedByThemes)
        XCTAssertEqual(decoded.votesRemaining, 3, "the vote prompt's N is still minVotesRequired - votesUsed")
        XCTAssertEqual(CivicProfileCopy.themeLock(decoded), "It opens once 3 themes each have 8 of your votes. 2 of 3 so far.")
        XCTAssertEqual(
            CivicProfileCopy.spokenUnlockPrompt(decoded),
            "Vote on 3 more bills to unlock your Civic Profile. It opens once 3 themes each have 8 of your votes. 2 of 3 so far."
        )

        // The numbers are the server's, not the app's.
        let other = try userProfile(
            #"{"axes":{},"votesUsed":40,"totalVotesWithProfile":40,"minVotesRequired":41,"isReady":false,"lockedBy":"themes","themesReady":0,"minThemesRequired":4,"minThemeVotes":6}"#
        )
        XCTAssertEqual(CivicProfileCopy.themeLock(other), "It opens once 4 themes each have 6 of your votes. 0 of 4 so far.")
    }

    /// The vote lock, a ready profile, a value the app does not know (the contract: read it as the vote lock), a
    /// value of the wrong type and a missing number all leave the card as it is, and none fails the profile.
    @MainActor
    func testOnlyTheThemeLockWithItsNumbersAddsTheLine() throws {
        let numbers = #""themesReady":1,"minThemesRequired":3,"minThemeVotes":8"#
        let votes = try userProfile(#"{"axes":{},"votesUsed":12,"totalVotesWithProfile":12,"minVotesRequired":25,"isReady":false,"lockedBy":"votes",\#(numbers)}"#)
        XCTAssertEqual(votes.lockedBy, "votes")
        XCTAssertFalse(votes.isLockedByThemes)
        XCTAssertNil(CivicProfileCopy.themeLock(votes))

        let ready = try userProfile(#"{"axes":{"individualVsCommunity":0.6},"votesUsed":40,"totalVotesWithProfile":40,"minVotesRequired":25,"isReady":true,"lockedBy":null,"themesReady":3,"minThemesRequired":3,"minThemeVotes":8}"#)
        XCTAssertNil(ready.lockedBy)
        XCTAssertTrue(ready.isReady)
        XCTAssertFalse(ready.isLockedByThemes)
        XCTAssertNil(CivicProfileCopy.themeLock(ready))

        let unknown = try userProfile(#"{"axes":{},"votesUsed":12,"totalVotesWithProfile":12,"minVotesRequired":25,"isReady":false,"lockedBy":"districts",\#(numbers)}"#)
        XCTAssertEqual(unknown.lockedBy, "districts", "kept as sent")
        XCTAssertFalse(unknown.isLockedByThemes, "an unknown value is the vote lock")
        XCTAssertNil(CivicProfileCopy.themeLock(unknown))

        let wrongType = try userProfile(#"{"axes":{},"votesUsed":30,"totalVotesWithProfile":30,"minVotesRequired":33,"isReady":false,"lockedBy":2,"themesReady":"2","minThemesRequired":3,"minThemeVotes":8}"#)
        XCTAssertNil(wrongType.lockedBy)
        XCTAssertNil(wrongType.themesReady)
        XCTAssertEqual(wrongType.minThemesRequired, 3)
        XCTAssertEqual(wrongType.votesRemaining, 3)
        XCTAssertNil(CivicProfileCopy.themeLock(wrongType))

        let missing = try userProfile(#"{"axes":{},"votesUsed":30,"totalVotesWithProfile":30,"minVotesRequired":33,"isReady":false,"lockedBy":"themes","minThemesRequired":3,"minThemeVotes":8}"#)
        XCTAssertTrue(missing.isLockedByThemes)
        XCTAssertNil(CivicProfileCopy.themeLock(missing), "no themesReady, no line")
    }

    // MARK: - Member card copy (spec D 2.4.2: themes, votes and bills; no signal or weights)

    @MainActor
    private func diagnostics(
        used: Double,
        required: Double,
        themesReady: Int,
        themesRequired: Int
    ) -> CivicProfileDiagnostics {
        CivicProfileDiagnostics(
            rollingWindow: 200,
            evidenceWeights: CivicProfileEvidenceWeights(voteYea: 1, voteNay: 1, sponsor: 0.5, cosponsor: 0.25),
            weightedEvidenceUsed: used,
            totalWeightedEvidenceWithProfile: used,
            minWeightedEvidenceRequired: required,
            minAxisWeightedEvidenceRequired: 3,
            minAxesRequired: themesRequired,
            axesWithSufficientSignal: themesReady,
            axisCoverage: [:],
            readinessReasons: [],
            latestEvidenceAt: nil
        )
    }

    @MainActor
    private func lockedProfile(diagnostics: CivicProfileDiagnostics?) -> CivicProfileResponse {
        CivicProfileResponse(
            axes: [:],
            votesUsed: 9,
            totalVotesWithProfile: 12,
            sponsoredBillsUsed: 4,
            cosponsoredBillsUsed: 7,
            totalEvidenceUsed: 20,
            totalEvidenceWithProfile: 28,
            minEvidenceRequired: 25,
            minVotesRequired: 25,
            isReady: false,
            diagnostics: diagnostics
        )
    }

    @MainActor
    func testLockedCardCopyTalksAboutVotesBillsAndThemes() {
        typealias Copy = CongressMemberCivicProfileCopy
        let withDiagnostics = lockedProfile(diagnostics: diagnostics(used: 12.5, required: 25, themesReady: 2, themesRequired: 4))
        let oneThemeShort = lockedProfile(diagnostics: diagnostics(used: 12, required: 25, themesReady: 3, themesRequired: 4))
        let themesReady = lockedProfile(diagnostics: diagnostics(used: 12, required: 25, themesReady: 4, themesRequired: 4))
        let noDiagnostics = lockedProfile(diagnostics: nil)

        XCTAssertEqual(Copy.lockedHeadline(withDiagnostics), "This chart appears once the member has enough votes and bills on 4 themes.")
        XCTAssertEqual(Copy.lockedHeadline(noDiagnostics), "This chart appears once the member has enough votes and bills on 3 themes.")
        XCTAssertEqual(Copy.basisNote, "Based on official votes (counted most) and the bills they sponsor or cosponsor.")
        XCTAssertEqual(Copy.lockedRemainingText(withDiagnostics), "Needs more votes or bills on 2 more themes.")
        XCTAssertEqual(Copy.lockedRemainingText(oneThemeShort), "Needs more votes or bills on 1 more theme.")
        XCTAssertEqual(Copy.lockedRemainingText(themesReady), "Needs more votes or bills.")
        XCTAssertEqual(Copy.progressText(withDiagnostics), "12.5 of 25 needed")
        XCTAssertEqual(Copy.evidenceSummary(withDiagnostics), "Based on 9 votes, 4 sponsored and 7 cosponsored bills")
        XCTAssertEqual(Copy.readinessText(noDiagnostics), "20 of 25 votes and bills available.")
        XCTAssertEqual(Copy.readinessText(withDiagnostics), "12.5 of 25 needed · 2 of 4 themes ready")
    }

    @MainActor
    func testThemeStatusAndEvidenceLines() {
        typealias Copy = CongressMemberCivicProfileCopy
        let ready = CivicProfileAxisCoverage(evidenceCount: 6, weightedEvidence: 5.5, isReady: true)
        let notReady = CivicProfileAxisCoverage(evidenceCount: 1, weightedEvidence: 1, isReady: false)

        XCTAssertEqual(Copy.themeStatus(score: 7, coverage: ready), "7/10")
        XCTAssertEqual(Copy.themeStatus(score: nil, coverage: ready), "Enough data")
        XCTAssertEqual(Copy.themeStatus(score: 7, coverage: notReady), "Not enough data")
        XCTAssertEqual(Copy.themeStatus(score: nil, coverage: nil), "Not enough data")
        XCTAssertEqual(Copy.scoreText(4), "4")
        XCTAssertEqual(Copy.scoreText(nil), "Not enough data")
        XCTAssertEqual(Copy.evidenceLabel("voteYea"), "Voted Yea")
        XCTAssertEqual(Copy.evidenceLabel("voteNay"), "Voted Nay")
        XCTAssertEqual(Copy.evidenceLabel("cosponsor"), "Cosponsor")
        XCTAssertTrue(Copy.evidenceLine(type: "voteYea", occurredAt: "2026-03-03T15:00:00Z").hasPrefix("Voted Yea · "))
        XCTAssertEqual(Copy.evidenceLine(type: "sponsor", occurredAt: "not a date"), "Sponsor · not a date")
        XCTAssertEqual(Copy.formatNumber(25), "25")
        XCTAssertEqual(Copy.formatNumber(12.34), "12.3")
    }

    @MainActor
    func testMemberCardCopyAvoidsBannedTerms() {
        typealias Copy = CongressMemberCivicProfileCopy
        let profiles = [
            lockedProfile(diagnostics: diagnostics(used: 12.5, required: 25, themesReady: 2, themesRequired: 4)),
            lockedProfile(diagnostics: nil)
        ]
        var copy = [Copy.basisNote, Copy.notEnoughData, Copy.themeStatus(score: nil, coverage: nil)]
        for profile in profiles {
            copy += [
                Copy.lockedHeadline(profile),
                Copy.lockedRemainingText(profile),
                Copy.progressText(profile),
                Copy.evidenceSummary(profile),
                Copy.readinessText(profile)
            ]
        }
        copy.append(Copy.evidenceLine(type: "voteNay", occurredAt: "2026-03-03T15:00:00Z"))

        for text in copy {
            for banned in ["signal", "weight", "evidence", "axis", "axes"] {
                XCTAssertNil(text.range(of: banned, options: .caseInsensitive), "\"\(text)\" contains \"\(banned)\"")
            }
        }
    }
}
