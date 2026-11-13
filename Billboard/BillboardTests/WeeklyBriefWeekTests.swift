import XCTest
@testable import Billboard

/// The Weekly Brief's week and its slot on Updates (feature review N2, pulled into 1.2 under UX-28). The server
/// names a brief by its release time from `toISOString()` ("2026-10-25T14:00:00.000Z"); the app named its week
/// in New York time ("2026-10-25T10:00:00-04:00"), so the two never matched as text and every Updates visit
/// downloaded the brief again. Weeks are now compared by release time, and read state, the UNREAD badge and the
/// once-a-week local notification follow the week, whoever wrote the brief. The loading slip shows only when a
/// brief is expected (the person follows or watches something); for someone who follows nothing, one quiet line
/// says how to get one, once this week's check found none.
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

    /// The local "Your Weekly Brief is ready" stays, once a week: the server's brief does not fire it again after
    /// the on-device brief for the same week did.
    func testTheLocalNotificationFiresOnceAWeekWhoeverWroteTheBrief() {
        let server = brief(id: Self.serverID)
        XCTAssertFalse(WeeklyDigestStore.shouldScheduleNotification(
            for: server, digestNotificationsEnabled: true, appNotificationsEnabled: true, lastNotifiedDigestID: Self.appID
        ))
        XCTAssertTrue(WeeklyDigestStore.shouldScheduleNotification(
            for: server, digestNotificationsEnabled: true, appNotificationsEnabled: true, lastNotifiedDigestID: "2026-10-18T10:00:00-04:00"
        ), "last week's notification does not cover this week")
        XCTAssertTrue(WeeklyDigestStore.shouldScheduleNotification(
            for: server, digestNotificationsEnabled: true, appNotificationsEnabled: true, lastNotifiedDigestID: nil
        ))
    }

    // MARK: - The store keeps this week's server brief

    /// The server's brief is downloaded once a week, not on every Updates visit, by this store and by the next
    /// launch's; its read state and the UNREAD badge carry over.
    func testTheServersBriefIsDownloadedOnceAndStaysRead() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let service = CountingWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        let (store, defaults, scope) = try makeStore(service: service)

        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(store.digest?.id, serverID(for: window))
        XCTAssertEqual(store.unreadDigestCount, 1, "the UNREAD front page counts in the badge")

        await store.refresh(profile: profile)
        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1, "each Updates visit used to download it again")

        store.markCurrentDigestRead()
        XCTAssertEqual(store.unreadDigestCount, 0)

        // The next launch reads the saved brief and does not download it either.
        let relaunched = WeeklyDigestStore(
            scope: scope,
            defaults: defaults,
            digestService: service,
            billsService: FakeBillsService(),
            votesService: FakeBillVotesService(),
            congressService: FakeCongressService()
        )
        await relaunched.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(relaunched.digest?.isRead, true)
        XCTAssertEqual(relaunched.unreadDigestCount, 0, "a read brief stays out of the badge")

        // A profile change still asks the server again, and the brief stays read.
        await relaunched.refresh(profile: profile, forceRefresh: true)
        XCTAssertEqual(service.fetchCount, 2)
        XCTAssertEqual(relaunched.digest?.isRead, true)
        XCTAssertEqual(relaunched.unreadDigestCount, 0)
    }

    /// A brief read as the on-device version stays read when the server's version of the same week arrives.
    func testReadStateCarriesFromTheOnDeviceBriefToTheServers() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let service = CountingWeeklyDigestService(digest: nil)
        let bills = FakeBillsService()
        bills.manifestResults = [.success([manifestItem(updatedAt: window.start.addingTimeInterval(24 * 60 * 60))])]
        let (store, _, _) = try makeStore(service: service, bills: bills)

        await store.refresh(profile: profile)
        let local = try XCTUnwrap(store.digest, "built on the device")
        XCTAssertEqual(local.source, .localFallback)
        XCTAssertEqual(local.id, window.id)
        store.markCurrentDigestRead()

        service.digest = brief(id: serverID(for: window), window: window)
        await store.refresh(profile: profile, forceRefresh: true)
        XCTAssertEqual(store.digest?.source, .remote)
        XCTAssertEqual(store.digest?.isRead, true, "the same week, already read")
        XCTAssertEqual(store.unreadDigestCount, 0)
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
        let service = CountingWeeklyDigestService(digest: nil)
        let (store, _, _) = try makeStore(service: service)
        let followsNothing = UserProfile.placeholder().updating(id: "user-1")
        XCTAssertFalse(store.foundNoBriefThisWeek, "not checked yet")

        await store.refresh(profile: followsNothing)
        XCTAssertNil(store.digest)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.foundNoBriefThisWeek)

        // The server builds one from a bill they voted on that changed: the brief replaces the line.
        service.digest = brief(id: serverID(for: window), window: window)
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

    private func brief(id: String, window: DigestPublicationWindow? = nil) -> WeeklyDigest {
        let window = window ?? WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        return WeeklyDigest(
            id: id,
            title: "Your Week in Congress",
            summary: "One bill you watch moved this week.",
            weekStart: window.start,
            weekEnd: window.end,
            publishedAt: window.releaseAt,
            source: .remote,
            isRead: false,
            stats: [],
            sections: []
        )
    }

    private func manifestItem(updatedAt: Date) -> BillsManifestItem {
        BillsManifestItem(
            guid: "BILLS-119hr1",
            congress: "119",
            billType: "hr",
            billID: "1",
            updatedAt: ISO8601DateFormatter().string(from: updatedAt),
            subCategories: ["Energy"],
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            title: "Grid Act",
            billStatus: "Updated"
        )
    }

    /// A store on its own defaults suite, with the app's notifications off so no local notification is posted.
    private func makeStore(
        service: CountingWeeklyDigestService,
        bills: FakeBillsService? = nil
    ) throws -> (WeeklyDigestStore, UserDefaults, String) {
        let scope = "weekly-brief-week-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: scope))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: scope) }
        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        let store = WeeklyDigestStore(
            scope: scope,
            defaults: defaults,
            digestService: service,
            billsService: bills ?? FakeBillsService(),
            votesService: FakeBillVotesService(),
            congressService: FakeCongressService()
        )
        return (store, defaults, scope)
    }
}

/// The published brief, counting how often it is asked for.
@MainActor
final class CountingWeeklyDigestService: WeeklyDigestServicing {
    var digest: WeeklyDigest?
    private(set) var fetchCount = 0

    init(digest: WeeklyDigest?) {
        self.digest = digest
    }

    func fetchLatest() async throws -> WeeklyDigest? {
        fetchCount += 1
        return digest
    }
}
