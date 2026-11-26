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
/// device and no local notification is posted. A 204 means no brief this week, except in the half hour after the
/// release, a failed read keeps the brief on screen, and a brief for another week changes nothing. A brief app 1.2
/// built is never shown. The Updates badge counts an unopened brief on Sunday and Monday only, New York time.
///
/// The stores run on a fixed clock (`now`, a Wednesday), so no test depends on the day it runs.
@MainActor
final class WeeklyBriefWeekTests: XCTestCase {
    private static let serverID = "2026-10-25T14:00:00.000Z"
    private static let appID = "2026-10-25T10:00:00-04:00"
    /// Wednesday Oct 28 2026, noon in New York: the week released on Sunday Oct 25.
    private static let now = Date(timeIntervalSince1970: 1_793_203_200)

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
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
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
        let relaunched = relaunch(scope, defaults, service)
        await relaunched.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(relaunched.digest?.isRead, true)

        // Retry (a forced refresh) still asks the server again, and the brief stays read.
        await relaunched.refresh(profile: profile, forceRefresh: true)
        XCTAssertEqual(service.fetchCount, 2)
        XCTAssertEqual(relaunched.digest?.isRead, true)
    }

    /// The server writes each person's brief on Sunday and keeps it all week, so a change to the profile reads
    /// nothing: a refresh with the changed profile (an Updates visit) keeps this week's brief without asking the
    /// server. This covers the store only; that the tabs no longer force a refresh on a profile change
    /// (`TabsBar`, which has no unit test) is checked in review.
    func testAProfileChangeDoesNotReadTheBriefAgain() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
        let service = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        let (store, _, _) = try makeStore(service: service)
        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)

        let changed = profile.updating(subscribedSubCategories: ["Energy", "Health"], subscribedMemberIDs: [UUID()])
        await store.refresh(profile: changed)
        XCTAssertEqual(service.fetchCount, 1, "a profile change used to force a new read")
        XCTAssertEqual(store.digest?.id, serverID(for: window))
    }

    /// A brief app 1.2 built on the device and saved for this week is replaced by the server's, and stays read if it
    /// was opened.
    func testReadStateCarriesFromTheOnDeviceBriefToTheServers() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
        let service = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        var saved = brief(id: window.id, window: window, source: .localFallback)
        saved.isRead = true
        let (store, defaults, scope) = try makeStore(service: service, saved: saved)
        XCTAssertNil(store.digest, "1.2's brief, read, is saved but not shown")

        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1, "1.2's brief does not count as this week's")
        XCTAssertEqual(store.digest?.source, .remote)
        XCTAssertEqual(store.digest?.id, serverID(for: window))
        XCTAssertEqual(store.digest?.isRead, true, "the same week, already read")

        // The server's brief is saved in its place: the next launch keeps it and asks nothing.
        let relaunched = relaunch(scope, defaults, service)
        await relaunched.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(relaunched.digest?.source, .remote)
        XCTAssertEqual(relaunched.digest?.isRead, true)
    }

    /// The same for an unread 1.2 brief: neither early return takes it for this week's.
    func testAnUnreadOnDeviceBriefIsReplacedAndStaysUnread() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
        let service = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        let (store, _, _) = try makeStore(service: service, saved: brief(id: window.id, window: window, source: .localFallback))

        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(store.digest?.source, .remote)
        XCTAssertEqual(store.digest?.isRead, false)
    }

    /// A brief app 1.2 built can name a member by an id (REL-46 A4), so 1.3 never shows it: not when the first read
    /// fails, and not when the server answers with another week's brief. It stays on the device until the server
    /// answers for this week, so the server's brief still takes its read state.
    func testAnOnDeviceBriefIsNeverShown() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
        let lastWeek = Self.lastWeeksWindow()
        var saved = brief(id: window.id, window: window, source: .localFallback)
        saved.isRead = true
        let service = FakeWeeklyDigestService()
        service.result = .failure(URLError(.timedOut))
        let (store, defaults, scope) = try makeStore(service: service, saved: saved)

        await store.refresh(profile: profile)
        XCTAssertNil(store.digest, "a failed read shows no 1.2 brief")
        XCTAssertNotNil(store.errorMessage, "Updates says the brief could not be loaded")
        XCTAssertNil(relaunch(scope, defaults, service).digest, "nor does the next launch")

        service.answer(brief(id: serverID(for: lastWeek), window: lastWeek))
        await store.refresh(profile: profile)
        XCTAssertNil(store.digest, "another week's answer shows no 1.2 brief")

        service.answer(brief(id: serverID(for: window), window: window))
        await store.refresh(profile: profile)
        XCTAssertEqual(store.digest?.source, .remote)
        XCTAssertEqual(store.digest?.isRead, true, "1.2's read state, kept on the device until now")
        XCTAssertEqual(service.fetchCount, 3)
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
        XCTAssertEqual(store.noBriefReleaseID, WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now).id)
        XCTAssertTrue(store.foundNoBriefThisWeek)
        XCTAssertNil(relaunch(scope, defaults, EmptyWeeklyDigestService()).digest, "nothing left on the device")
    }

    /// From Sunday 10:00 to 10:30 AM ET the server may not have stored a person's brief yet (GenerateWeeklyDigests
    /// starts at 10:00; the first push run is at 10:30), so a 204 then is not "no brief this week": last week's
    /// brief stays on screen and on the device, nothing says there is none, and the next refresh asks again. From
    /// 10:30 a 204 means no brief this week.
    func testAnEmptyAnswerInTheHalfHourAfterTheReleaseChangesNothing() async throws {
        let release = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now).releaseAt
        let lastWeek = WeeklyDigestStore.latestPublishedWindow(relativeTo: release.addingTimeInterval(-60))
        let onScreen = brief(id: serverID(for: lastWeek), window: lastWeek)
        let clock = BriefClock(release)
        let service = FakeWeeklyDigestService()
        let (store, defaults, scope) = try makeStore(service: service, saved: onScreen, clock: clock)

        for (name, offset) in [("10:00 AM", 0.0), ("10:10 AM", 10 * 60.0), ("10:29:59 AM", 30 * 60.0 - 1)] {
            clock.now = release.addingTimeInterval(offset)
            await store.refresh(profile: profile)
            XCTAssertEqual(store.digest, onScreen, "\(name): last week's brief stays on screen")
            XCTAssertEqual(relaunch(scope, defaults, service).digest, onScreen, "\(name): and on the device")
            XCTAssertNil(store.noBriefReleaseID, name)
            XCTAssertFalse(store.foundNoBriefThisWeek, name)
            XCTAssertNil(store.errorMessage, name)
        }
        XCTAssertEqual(service.fetchCount, 3, "each refresh asks again")

        clock.now = release.addingTimeInterval(30 * 60)
        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 4)
        XCTAssertNil(store.digest, "10:30 AM: no brief this week")
        XCTAssertTrue(store.foundNoBriefThisWeek)
        XCTAssertNil(relaunch(scope, defaults, service).digest)
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
            relaunch(scope, defaults, service).digest?.id,
            serverID(for: lastWeek),
            "and on the device"
        )

        // The next refresh asks again.
        service.answer(brief(id: serverID(for: WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now))))
        await store.refresh(profile: profile)
        XCTAssertEqual(service.fetchCount, 2)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isShowingStaleDigest)
    }

    /// A brief the server returns for another week is not this week's and not a sign that there is none. The server
    /// answers for the week its own clock is in, so this is a phone whose clock is ahead of the server's (last week's
    /// brief) or behind it (this week's, published later than the phone's now) near a release. The brief on screen
    /// and the one on the device stay, no "no brief this week" and no error, and the next refresh asks again.
    func testABriefForAnotherWeekChangesNothing() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
        let lastWeek = Self.lastWeeksWindow()
        let future = WeeklyDigest(
            id: serverID(for: window),
            title: "Your Week in Congress",
            summary: "Published an hour from now.",
            weekStart: window.start,
            weekEnd: window.end,
            publishedAt: Self.now.addingTimeInterval(60 * 60),
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
            XCTAssertEqual(relaunch(scope, defaults, service).digest, onScreen, "\(name): and on the device")
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

    // MARK: - A return to the app

    /// The app left in the background before Sunday 10 AM ET still holds last week's brief. A return to the app
    /// after the release reads this week's, so the badge can count it; once it is here, or once this week's check
    /// found none, a return asks nothing. With Weekly Brief in Updates off, nothing is read.
    func testAReturnToTheAppReadsThisWeeksBriefOnce() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
        let lastWeek = Self.lastWeeksWindow()
        let sundayNoon = window.releaseAt.addingTimeInterval(2 * 60 * 60)
        let clock = BriefClock(sundayNoon)
        let service = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        let (store, _, _) = try makeStore(service: service, saved: brief(id: serverID(for: lastWeek), window: lastWeek), clock: clock)
        XCTAssertEqual(
            WeeklyDigestStore.unreadDigestCount(digest: store.digest, isEnabled: true, now: sundayNoon),
            0,
            "precondition: last week's brief"
        )

        await store.refreshOnReturnToApp(profile: profile)
        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(store.digest?.id, serverID(for: window))
        XCTAssertEqual(WeeklyDigestStore.unreadDigestCount(digest: store.digest, isEnabled: true, now: sundayNoon), 1)

        await store.refreshOnReturnToApp(profile: profile)
        XCTAssertEqual(service.fetchCount, 1, "this week's brief is here")

        // This week's check found none: a return asks nothing more.
        let empty = FakeWeeklyDigestService()
        let (none, _, _) = try makeStore(service: empty, clock: clock)
        await none.refresh(profile: profile)
        XCTAssertTrue(none.foundNoBriefThisWeek)
        await none.refreshOnReturnToApp(profile: profile)
        XCTAssertEqual(empty.fetchCount, 1)

        // Weekly Brief in Updates off.
        let off = FakeWeeklyDigestService(digest: brief(id: serverID(for: window), window: window))
        let (disabled, _, _) = try makeStore(service: off, clock: clock)
        disabled.setEnabled(false)
        await disabled.refreshOnReturnToApp(profile: profile)
        XCTAssertEqual(off.fetchCount, 0)
    }

    // MARK: - The Updates badge: Sunday and Monday only

    /// An unopened brief counts in the Updates badge from its release, Sunday 10:00 ET, through Monday 23:59:59 ET,
    /// and not from Tuesday 00:00 ET. The instants are written in UTC, so the clock changes on Mar 8 2026 (the
    /// brief's Monday ends 47 hours after its Sunday began) and Nov 1 2026 (49 hours) are checked against the clock.
    func testTheBriefCountsInTheBadgeOnSundayAndMondayOnly() throws {
        let weeks: [(name: String, sunday: String, beforeRelease: String, release: String, lastSecond: String, tuesday: String)] = [
            ("an ordinary week (EST)", "2026-11-15", "2026-11-15T14:59:59Z", "2026-11-15T15:00:00Z", "2026-11-17T04:59:59Z", "2026-11-17T05:00:00Z"),
            ("an ordinary week (EDT)", "2026-10-25", "2026-10-25T13:59:59Z", "2026-10-25T14:00:00Z", "2026-10-27T03:59:59Z", "2026-10-27T04:00:00Z"),
            ("clocks forward Mar 8 2026", "2026-03-08", "2026-03-08T13:59:59Z", "2026-03-08T14:00:00Z", "2026-03-10T03:59:59Z", "2026-03-10T04:00:00Z"),
            ("clocks back Nov 1 2026", "2026-11-01", "2026-11-01T14:59:59Z", "2026-11-01T15:00:00Z", "2026-11-03T04:59:59Z", "2026-11-03T05:00:00Z")
        ]
        for week in weeks {
            func at(_ text: String) throws -> Date { try XCTUnwrap(FlexibleISO8601.parse(text), text) }
            func count(_ digest: WeeklyDigest?, _ text: String) throws -> Int {
                let now = try at(text)
                return WeeklyDigestStore.unreadDigestCount(digest: digest, isEnabled: true, now: now)
            }
            let release = try at(week.release)
            let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: release)
            XCTAssertEqual(window.releaseAt, release, "\(week.name): the release is Sunday 10:00 ET")
            let unread = brief(id: serverID(for: window), window: window)

            XCTAssertEqual(try count(unread, week.beforeRelease), 0, "\(week.name): Sunday 9:59:59 ET")
            XCTAssertEqual(try count(unread, week.release), 1, "\(week.name): Sunday 10:00 ET")
            XCTAssertEqual(try count(unread, week.lastSecond), 1, "\(week.name): Monday 23:59:59 ET")
            XCTAssertEqual(try count(unread, week.tuesday), 0, "\(week.name): Tuesday 00:00 ET")
            XCTAssertEqual(try count(unread, week.sunday + "T23:00:00Z"), 1, "\(week.name): Sunday evening")

            // The app's own id for the week counts the same as the server's.
            XCTAssertEqual(try count(brief(id: window.id, window: window), week.release), 1, week.name)

            var read = unread
            read.isRead = true
            XCTAssertEqual(try count(read, week.release), 0, "\(week.name): a read brief")
            XCTAssertEqual(try count(nil, week.release), 0, "\(week.name): no brief")
            XCTAssertEqual(
                WeeklyDigestStore.unreadDigestCount(digest: unread, isEnabled: false, now: release),
                0,
                "\(week.name): Weekly Brief in Updates off"
            )

            // Last week's brief, still unread, does not count once this week's is out.
            let previous = WeeklyDigestStore.latestPublishedWindow(relativeTo: release.addingTimeInterval(-1))
            XCTAssertEqual(try count(brief(id: serverID(for: previous), window: previous), week.release), 0, "\(week.name): last week's brief")
        }
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
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
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
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
        return WeeklyDigestStore.latestPublishedWindow(relativeTo: window.releaseAt.addingTimeInterval(-60))
    }

    private func brief(
        id: String,
        window: DigestPublicationWindow? = nil,
        source: WeeklyDigest.Source = .remote,
        summary: String = "One bill you watch moved this week."
    ) -> WeeklyDigest {
        let window = window ?? WeeklyDigestStore.latestPublishedWindow(relativeTo: Self.now)
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
    /// app 1.2, left it), on `clock` (by default at `now`, a Wednesday).
    private func makeStore(
        service: any WeeklyDigestServicing,
        saved: WeeklyDigest? = nil,
        clock: BriefClock? = nil
    ) throws -> (WeeklyDigestStore, UserDefaults, String) {
        let clock = clock ?? BriefClock(Self.now)
        let scope = "weekly-brief-week-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: scope))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: scope) }
        if let saved {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            defaults.set(try encoder.encode(saved), forKey: "BillBoard.weeklyDigest.v1.digest.\(scope)")
        }
        let store = WeeklyDigestStore(scope: scope, defaults: defaults, digestService: service, now: { clock.now })
        return (store, defaults, scope)
    }

    /// The next launch's store on the same device, at `now`.
    private func relaunch(_ scope: String, _ defaults: UserDefaults, _ service: any WeeklyDigestServicing) -> WeeklyDigestStore {
        let now = Self.now
        return WeeklyDigestStore(scope: scope, defaults: defaults, digestService: service, now: { now })
    }
}

/// The Weekly Brief store's clock, which a test moves.
private final class BriefClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}
