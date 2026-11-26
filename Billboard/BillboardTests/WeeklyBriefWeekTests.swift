import XCTest
@testable import Billboard

/// The Weekly Brief's week and its slot on Updates (feature review N2, pulled into 1.2 under UX-28). The server
/// names a brief by its release time from `toISOString()` ("2026-10-25T14:00:00.000Z"); the app named its week
/// in New York time ("2026-10-25T10:00:00-04:00"), so the two never matched as text and every Updates visit
/// downloaded the brief again. Weeks are now compared by release time, and read state follows the week. The loading
/// slip shows only when a brief is expected (the person follows or watches something); for someone who follows
/// nothing, one quiet line says how to get one, once this week's check found none.
///
/// Since 1.3 (UX-28, a project decision of 2026-11-23) the brief is the server's only: no brief is built on the
/// device and no local notification is posted. A 204 means no brief this week, a failed read keeps the brief on
/// screen, and a brief for another week changes nothing.
@MainActor
final class WeeklyBriefWeekTests: XCTestCase {
    private static let serverID = "2026-10-25T14:00:00.000Z"
    private static let appID = "2026-10-25T10:00:00-04:00"

    // MARK: - Same week, either id

    func testTheServersIDAndTheAppsIDNameTheSameWeek() throws {
        XCTAssertTrue(WeeklyDigestStore.isSameRelease(Self.serverID, Self.appID))
        XCTAssertTrue(WeeklyDigestStore.isSameRelease(Self.appID, Self.serverID))
        XCTAssertTrue(WeeklyDigestStore.isSameRelease(Self.serverID, Self.serverID))
        XCTAssertFalse(WeeklyDigestStore.isSameRelease(Self.serverID, "2026-10-18T14:00:00.000Z"), "the week before")
        XCTAssertFalse(WeeklyDigestStore.isSameRelease(Self.appID, "2026-11-01T10:00:00-05:00"), "the week after")
        // Ids that are not dates are compared as text.
        XCTAssertTrue(WeeklyDigestStore.isSameRelease("digest-1", "digest-1"))
        XCTAssertFalse(WeeklyDigestStore.isSameRelease("digest-1", Self.serverID))

        // The app's own window id for that Sunday is the same release as the server's.
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: try XCTUnwrap(FlexibleISO8601.parse("2026-10-28T12:00:00Z")))
        XCTAssertEqual(window.id, Self.appID)
        XCTAssertTrue(WeeklyDigestStore.isSameRelease(window.id, Self.serverID))
    }

    // MARK: - The store keeps this week's server brief

    /// The server's brief is downloaded once a week, not on every Updates visit, by this store and by the next
    /// launch's; its read state carries over.
    func testTheServersBriefIsDownloadedOnceAndStaysRead() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let service = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        let (store, defaults, scope) = try makeStore(service: service)

        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(store.digest?.id, serverID(for: window))
        XCTAssertEqual(store.digest?.isRead, false)

        await store.refresh(profile: profile)
        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1, "each Updates visit used to download it again")

        store.markCurrentDigestRead()
        XCTAssertEqual(store.digest?.isRead, true)

        // The next launch reads the saved brief and does not download it either.
        let relaunched = WeeklyDigestStore(scope: scope, defaults: defaults, digestService: service)
        await relaunched.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(relaunched.digest?.isRead, true)

        // Retry (a forced refresh) still asks the server again, and the brief stays read.
        await relaunched.refresh(profile: profile, forceRefresh: true)
        XCTAssertEqual(service.fetchCount, 2)
        XCTAssertEqual(relaunched.digest?.isRead, true)
    }

    /// A brief app 1.2 built on the device and saved for this week is replaced by the server's, and stays read if it
    /// was opened.
    func testReadStateCarriesFromTheOnDeviceBriefToTheServers() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let service = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        var saved = brief(id: window.id, window: window, source: .localFallback)
        saved.isRead = true
        let (store, defaults, scope) = try makeStore(service: service, saved: saved)
        XCTAssertEqual(store.digest?.source, .localFallback, "precondition: 1.2's brief, read, is on screen")

        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1, "1.2's brief does not count as this week's")
        XCTAssertEqual(store.digest?.source, .remote)
        XCTAssertEqual(store.digest?.id, serverID(for: window))
        XCTAssertEqual(store.digest?.isRead, true, "the same week, already read")

        // The server's brief is saved in its place: the next launch keeps it and asks nothing.
        let relaunched = WeeklyDigestStore(scope: scope, defaults: defaults, digestService: service)
        await relaunched.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(relaunched.digest?.source, .remote)
        XCTAssertEqual(relaunched.digest?.isRead, true)
    }

    /// The same for 1.2's brief kept in memory and on the device: neither early return takes it for this week's.
    func testAnUnreadOnDeviceBriefIsReplacedAndStaysUnread() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let service = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        let (store, _, _) = try makeStore(service: service, saved: brief(id: window.id, window: window, source: .localFallback))

        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(store.digest?.source, .remote)
        XCTAssertEqual(store.digest?.isRead, false)
    }

    // MARK: - The server's answer

    /// A 204 means the server has no brief for this person this week: the brief on screen goes, nothing is left
    /// on the device, the store remembers this week's check found none, and nothing else is asked for (the
    /// on-device builder read bills, votes and members here).
    func testAnEmptyAnswerMeansNoBriefThisWeekAndAsksNothingElse() async throws {
        let lastWeek = Self.lastWeeksWindow()
        let (store, defaults, scope) = try makeStore(
            service: WeeklyDigestService.Live(),
            saved: brief(id: serverID(for: lastWeek), window: lastWeek)
        )
        XCTAssertNotNil(store.digest, "precondition: last week's brief is on screen")
        let transport = RecordingTransport()

        await APIClient.$current.withValue(transport.client) {
            await store.refresh(profile: profile)
        }

        XCTAssertEqual(transport.requests.map(\.path), ["weekly-digests/latest"], "the brief's read alone")
        XCTAssertNil(store.digest)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.noBriefReleaseID, WeeklyDigestStore.latestPublishedWindow(relativeTo: Date()).id)
        XCTAssertTrue(store.foundNoBriefThisWeek)
        XCTAssertNil(WeeklyDigestStore(scope: scope, defaults: defaults, digestService: EmptyWeeklyDigestService()).digest, "nothing left on the device")
    }

    /// A failed read says so and keeps last week's brief on screen, marked as an earlier week's; it is not taken
    /// for "no brief this week".
    func testAFailedReadKeepsTheBriefOnScreenAndSaysSo() async throws {
        let lastWeek = Self.lastWeeksWindow()
        let service = FakeWeeklyDigestService()
        service.result = .failure(URLError(.timedOut))
        let (store, defaults, scope) = try makeStore(service: service, saved: brief(id: serverID(for: lastWeek), window: lastWeek))

        await store.refresh(profile: profile)

        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(store.errorMessage, "Can't reach Billboard right now. Check your connection and try again.")
        XCTAssertEqual(store.digest?.id, serverID(for: lastWeek), "the stale brief stays on screen")
        XCTAssertTrue(store.isShowingStaleDigest)
        XCTAssertNil(store.noBriefReleaseID)
        XCTAssertFalse(store.foundNoBriefThisWeek)
        XCTAssertEqual(
            WeeklyDigestStore(scope: scope, defaults: defaults, digestService: service).digest?.id,
            serverID(for: lastWeek),
            "and on the device"
        )

        // The next refresh asks again.
        service.answer(brief(id: serverID(for: WeeklyDigestStore.latestPublishedWindow(relativeTo: Date()))))
        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 2)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isShowingStaleDigest)
    }

    /// A brief the server returns for another week (last week's, read before this week's is stored, or one
    /// published later than now) is not this week's and not a sign that there is none: the brief on screen and the
    /// one on the device stay, no "no brief this week" and no error, and the next refresh asks again.
    func testABriefForAnotherWeekChangesNothing() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let lastWeek = Self.lastWeeksWindow()
        let future = WeeklyDigest(
            id: serverID(for: window),
            title: "Your Week in Congress",
            summary: "Published an hour from now.",
            weekStart: window.start,
            weekEnd: window.end,
            publishedAt: Date().addingTimeInterval(60 * 60),
            source: .remote,
            isRead: false,
            stats: [],
            sections: []
        )
        let answers: [(String, WeeklyDigest)] = [
            ("last week's", brief(id: serverID(for: lastWeek), window: lastWeek, summary: "Last week, as the server has it.")),
            ("published later", future)
        ]
        for (name, answer) in answers {
            let twoWeeksAgo = WeeklyDigestStore.latestPublishedWindow(relativeTo: lastWeek.releaseAt.addingTimeInterval(-60))
            var onScreen = brief(id: serverID(for: twoWeeksAgo), window: twoWeeksAgo)
            onScreen.isRead = true
            let service = FakeWeeklyDigestService(digest: answer)
            let (store, defaults, scope) = try makeStore(service: service, saved: onScreen)

            await store.refresh(profile: profile)

            XCTAssertEqual(service.fetchCount, 1, name)
            XCTAssertEqual(store.digest, onScreen, "\(name): the brief on screen stays as it was")
            XCTAssertEqual(WeeklyDigestStore(scope: scope, defaults: defaults, digestService: service).digest, onScreen, "\(name): and on the device")
            XCTAssertNil(store.noBriefReleaseID, name)
            XCTAssertFalse(store.foundNoBriefThisWeek, name)
            XCTAssertNil(store.errorMessage, name)

            await store.refresh(profile: profile)
            XCTAssertEqual(service.fetchCount, 2, "\(name): the next refresh asks again")
        }

        // With no brief on screen, nothing shows: not the other week's brief, and no "no brief this week".
        let service = FakeWeeklyDigestService(digest: answers[0].1)
        let (store, _, _) = try makeStore(service: service)
        await store.refresh(profile: profile)
        XCTAssertNil(store.digest)
        XCTAssertFalse(store.foundNoBriefThisWeek)
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - Is a brief expected?

    func testFollowingSomethingMeansTopicsLifeAreasMembersOrWatchedBills() {
        let known = UserProfile.placeholder().updating(id: "user-1")
        func expected(_ profile: UserProfile) -> Bool { WeeklyDigestStore.followsSomething(profile, followsAreKnown: true) }
        XCTAssertFalse(expected(known), "nothing followed or watched")
        XCTAssertFalse(expected(known.updating(subscribedSubCategories: [" "])))
        XCTAssertTrue(expected(known.updating(subscribedSubCategories: ["Energy"])))
        XCTAssertTrue(expected(known.updating(subscribedLifeAreas: ["Taxes"])))
        XCTAssertTrue(expected(known.updating(subscribedMemberIDs: [UUID()])))
        XCTAssertTrue(expected(known.updating(watchedBillGUIDs: ["BILLS-119hr1"])))
        XCTAssertTrue(expected(.placeholder()), "a profile not loaded yet: no quiet line before it is known")
        XCTAssertTrue(
            WeeklyDigestStore.followsSomething(known, followsAreKnown: false),
            "follows that did not load are not 'follows nothing'"
        )
    }

    /// A brief is expected for someone who follows something, or who has voted (decided 2026-10-29, from
    /// billboard-backend's weeklyDigestBuilder: its "voted_updated" bucket lists a bill the person voted on that was
    /// updated that week, with no follows needed). Votes not known yet count as voted, as unknown follows do.
    func testABriefIsExpectedForSomeoneWhoFollowsSomethingOrHasVoted() {
        let followsNothing = UserProfile.placeholder().updating(id: "user-1")
        let follower = followsNothing.updating(subscribedSubCategories: ["Energy"])
        XCTAssertFalse(WeeklyDigestStore.isBriefExpected(for: followsNothing, followsAreKnown: true, hasVoted: false), "follows nothing, never voted")
        XCTAssertTrue(WeeklyDigestStore.isBriefExpected(for: followsNothing, followsAreKnown: true, hasVoted: true), "follows nothing, voted")
        XCTAssertTrue(WeeklyDigestStore.isBriefExpected(for: followsNothing, followsAreKnown: true, hasVoted: nil), "votes not known yet")
        XCTAssertTrue(WeeklyDigestStore.isBriefExpected(for: follower, followsAreKnown: true, hasVoted: false), "a follower who never voted")
        XCTAssertTrue(WeeklyDigestStore.isBriefExpected(for: followsNothing, followsAreKnown: false, hasVoted: false), "follows not known yet")
    }

    /// Whether the person has voted comes from the Civic Score's Bills voted, once the score has loaded (read from
    /// the server or this user's cached copy); before that it is not known.
    func testHasVotedReadsTheCivicScoresBillsVoted() async throws {
        func store(totalVotes: Int) throws -> (CivicScoreStore, FakeCivicService) {
            let scope = "weekly-brief-voted-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: scope))
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: scope) }
            let service = FakeCivicService()
            service.scoreResult = .success(Self.score(totalVotes: totalVotes))
            return (CivicScoreStore(scope: scope, userDefaults: defaults, service: service), service)
        }

        let (voter, _) = try store(totalVotes: 3)
        XCTAssertNil(NotificationsView.hasVoted(civicScoreStore: voter), "not loaded yet")
        await voter.refresh()
        XCTAssertEqual(NotificationsView.hasVoted(civicScoreStore: voter), true)

        let (newcomer, _) = try store(totalVotes: 0)
        await newcomer.refresh()
        XCTAssertEqual(NotificationsView.hasVoted(civicScoreStore: newcomer), false)

        let (offline, service) = try store(totalVotes: 3)
        service.scoreResult = .failure(URLError(.notConnectedToInternet))
        await offline.refresh()
        XCTAssertNil(NotificationsView.hasVoted(civicScoreStore: offline), "a failed first read: not known")
    }

    /// A first launch (no profile saved on the device) whose preferences request fails keeps the account's id with
    /// no follows. That person may follow topics, so Updates does not tell them to follow topics.
    func testFollowsThatDidNotLoadDoNotCountAsFollowingNothing() async {
        let userId = "weekly-brief-week-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            UserStore.clearCachedProfile(userId: userId)
            UserDefaults.standard.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        }
        let preferences = FakePreferencesService()
        preferences.getPreferencesError = URLError(.timedOut)
        let failed = UserStore(preferencesService: preferences, congressService: FakeCongressService())
        // The compliance check before the preferences load goes through `APIClient`; an empty response fails to
        // decode and is only logged.
        await APIClient.$current.withValue(RecordingTransport().client) {
            await failed.refresh(userId: userId, attributes: [])
        }
        XCTAssertEqual(failed.profile.id, userId, "precondition: the account's id")
        XCTAssertTrue(failed.profile.subscribedSubCategories.isEmpty, "precondition: no follows loaded")
        XCTAssertNotNil(failed.errorMessage, "precondition: the preferences load failed")
        XCTAssertTrue(NotificationsView.followsSomething(userStore: failed))

        // The same account once its preferences load (it follows nothing): the quiet line can show.
        preferences.getPreferencesError = nil
        await APIClient.$current.withValue(RecordingTransport().client) {
            await failed.refresh(userId: userId, attributes: [])
        }
        XCTAssertNil(failed.errorMessage)
        XCTAssertFalse(NotificationsView.followsSomething(userStore: failed))
    }

    // MARK: - This week's check found no brief

    /// Someone who follows nothing and has no brief this week: the store remembers that this week's check found
    /// none, until a brief arrives.
    func testTheStoreRemembersThatThisWeeksCheckFoundNoBrief() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let service = FakeWeeklyDigestService()
        let (store, _, _) = try makeStore(service: service)
        let followsNothing = UserProfile.placeholder().updating(id: "user-1")
        XCTAssertFalse(store.foundNoBriefThisWeek, "not checked yet")

        await store.refresh(profile: followsNothing)
        XCTAssertNil(store.digest)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.foundNoBriefThisWeek)

        // The server builds one from a bill they voted on that changed: the brief replaces the line.
        service.answer(brief(id: serverID(for: window), window: window))
        await store.refresh(profile: followsNothing)
        XCTAssertEqual(store.digest?.id, serverID(for: window))
        XCTAssertFalse(store.foundNoBriefThisWeek)
    }

    // MARK: - The slot on Updates

    func testTheLoadingSlipShowsOnlyWhenABriefIsExpected() {
        func slot(
            isEnabled: Bool = true,
            hasDigest: Bool = false,
            isLoading: Bool = false,
            errorMessage: String? = nil,
            isShowingStaleDigest: Bool = false,
            isBriefExpected: Bool = true,
            followsSomething: Bool? = nil,
            foundNoBrief: Bool = false
        ) -> NotificationsView.WeeklyBriefSlot {
            NotificationsView.weeklyBriefSlot(
                isEnabled: isEnabled,
                hasDigest: hasDigest,
                isLoading: isLoading,
                errorMessage: errorMessage,
                isShowingStaleDigest: isShowingStaleDigest,
                isBriefExpected: isBriefExpected,
                // Someone who follows something always expects a brief; by default the two go together.
                followsSomething: followsSomething ?? isBriefExpected,
                foundNoBrief: foundNoBrief
            )
        }
        let error = "Can't reach Billboard right now."

        // Someone who follows something: as before.
        XCTAssertEqual(slot(isLoading: true), .loading)
        XCTAssertEqual(slot(), .hidden, "no brief this week and none loading")
        XCTAssertEqual(slot(foundNoBrief: true), .hidden, "no brief this week")
        XCTAssertEqual(slot(isLoading: true, foundNoBrief: true), .loading)
        XCTAssertEqual(slot(errorMessage: error), .failed(message: error))
        XCTAssertEqual(slot(hasDigest: true), .brief(staleError: nil))
        XCTAssertEqual(slot(hasDigest: true, errorMessage: error, isShowingStaleDigest: true), .brief(staleError: error))
        XCTAssertEqual(slot(hasDigest: true, errorMessage: error), .brief(staleError: nil), "this week's brief needs no warning")
        XCTAssertEqual(slot(hasDigest: true, isLoading: true, errorMessage: error, isShowingStaleDigest: true), .brief(staleError: nil))

        // Someone who follows nothing: never the slip. While the brief loads, nothing: the server may still send
        // one from bills they voted on, and the quiet line flashed before it. The line once this week's check
        // found none, kept while Updates checks again.
        XCTAssertEqual(slot(isLoading: true, isBriefExpected: false), .hidden, "follows nothing, loading: no quiet line")
        XCTAssertEqual(slot(isBriefExpected: false), .hidden, "not checked yet")
        XCTAssertEqual(slot(isBriefExpected: false, foundNoBrief: true), .howToGetOne)
        XCTAssertEqual(slot(isLoading: true, isBriefExpected: false, foundNoBrief: true), .howToGetOne)
        XCTAssertEqual(slot(errorMessage: error, isBriefExpected: false), .failed(message: error), "the brief might have come")
        XCTAssertEqual(slot(errorMessage: error, isBriefExpected: false, foundNoBrief: true), .failed(message: error))
        XCTAssertEqual(slot(hasDigest: true, isBriefExpected: false), .brief(staleError: nil), "a brief on hand still shows")

        // Someone who follows nothing but has voted (decided 2026-10-29): the server's brief lists bills they
        // voted on that were updated that week, so the slip while it loads; the quiet line once this week's check
        // found none, kept while Updates checks again.
        XCTAssertEqual(slot(isLoading: true, followsSomething: false), .loading, "voted, follows nothing, loading")
        XCTAssertEqual(slot(followsSomething: false), .hidden, "not checked yet")
        XCTAssertEqual(slot(followsSomething: false, foundNoBrief: true), .howToGetOne)
        XCTAssertEqual(slot(isLoading: true, followsSomething: false, foundNoBrief: true), .howToGetOne, "checking again keeps the line")
        XCTAssertEqual(slot(errorMessage: error, followsSomething: false), .failed(message: error))
        XCTAssertEqual(slot(hasDigest: true, followsSomething: false), .brief(staleError: nil))

        // Weekly Brief in Updates switched off in Profile: nothing.
        XCTAssertEqual(slot(isEnabled: false, isLoading: true), .hidden)
        XCTAssertEqual(slot(isEnabled: false, isBriefExpected: false, foundNoBrief: true), .hidden)

        XCTAssertEqual(NotificationsView.weeklyBriefHowToGetOne, "Follow topics or members to get a Weekly Brief.")
    }

    // MARK: - Helpers

    /// A Civic Score with `totalVotes` Bills voted.
    private static func score(totalVotes: Int) -> CivicScore {
        CivicScore(
            civicScore: totalVotes * 10,
            totalVotes: totalVotes,
            currentStreak: 0,
            longestStreak: 0,
            lastVotedAt: nil,
            recentVoteDays: nil,
            voteScore: totalVotes * 10,
            streakBonus: 0,
            honorBonus: 0,
            coverageAreaCount: 0,
            rank: CivicRank(id: "citizen", title: "Citizen", minScore: 0, approxVotesRequired: 0),
            nextRank: nil,
            scoreToNextRank: 0,
            honors: []
        )
    }

    private var profile: UserProfile { UserProfile.placeholder().updating(id: "user-1", subscribedSubCategories: ["Energy"]) }

    /// The id the server writes for `window`: its release time from `toISOString()`.
    private func serverID(for window: DigestPublicationWindow) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: window.releaseAt)
    }

    /// Last week's window: the one before this week's release.
    private static func lastWeeksWindow() -> DigestPublicationWindow {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        return WeeklyDigestStore.latestPublishedWindow(relativeTo: window.releaseAt.addingTimeInterval(-60))
    }

    private func brief(
        id: String,
        window: DigestPublicationWindow? = nil,
        source: WeeklyDigest.Source = .remote,
        summary: String = "One bill you watch moved this week."
    ) -> WeeklyDigest {
        let window = window ?? WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        return WeeklyDigest(
            id: id,
            title: "Your Week in Congress",
            summary: summary,
            weekStart: window.start,
            weekEnd: window.end,
            publishedAt: window.releaseAt,
            source: source,
            isRead: false,
            stats: [],
            sections: []
        )
    }

    /// A store on its own defaults suite, with `saved` as the brief saved on the device (as an earlier launch, or
    /// app 1.2, left it).
    private func makeStore(
        service: any WeeklyDigestServicing,
        saved: WeeklyDigest? = nil
    ) throws -> (WeeklyDigestStore, UserDefaults, String) {
        let scope = "weekly-brief-week-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: scope))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: scope) }
        if let saved {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            defaults.set(try encoder.encode(saved), forKey: "BillBoard.weeklyDigest.v1.digest.\(scope)")
        }
        let store = WeeklyDigestStore(scope: scope, defaults: defaults, digestService: service)
        return (store, defaults, scope)
    }
}
