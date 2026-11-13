import Amplify
import XCTest
@testable import Billboard

/// APPF-22: a cancelled request surfaces as `CancellationError` at the API layer (`APIClient.payload`),
/// so no screen reports it as a failed load, while every other failure still reaches the screen as
/// before. The store tests run each store's live service against a recording transport: once with a
/// request cancelled the way Amplify reports it, and once with a timeout (unchanged behaviour).
final class CancellationSurfacingTests: XCTestCase {
    /// The shapes a cancelled request takes on its way out of Amplify and URLSession.
    private var cancelledRequestErrors: [Error] {
        [
            URLError(.cancelled),
            APIError.networkError("cancelled", nil, URLError(.cancelled)),
            APIError.operationError("Operation cancelled", "", OperationCancelledError()),
            NSError(domain: "Amplify.APIError", code: 0, userInfo: [NSUnderlyingErrorKey: URLError(.cancelled)]),
            CancellationError()
        ]
    }

    private static let timeout = URLError(.timedOut)

    @MainActor
    private func failingClient(with error: Error) -> APIClient {
        let transport = RecordingTransport()
        transport.failure = { _ in error }
        return transport.client
    }

    @MainActor
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "CancellationSurfacingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return defaults
    }

    // MARK: - API layer

    @MainActor
    func testACancelledRequestSurfacesAsCancellationError() async {
        for cancelled in cancelledRequestErrors {
            do {
                _ = try await failingClient(with: cancelled).payload(.get, "civic-score", label: "test")
                XCTFail("Expected CancellationError for \(cancelled)")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(cancelled) surfaced as \(error)")
            }
        }
    }

    @MainActor
    func testOtherFailuresPassThroughUnchanged() async {
        let failures: [Error] = [
            Self.timeout,
            URLError(.notConnectedToInternet),
            APIServiceError.invalidPayload("civic-score"),
            FakeServiceError()
        ]
        for failure in failures {
            do {
                _ = try await failingClient(with: failure).payload(.get, "civic-score", label: "test")
                XCTFail("Expected \(failure)")
            } catch {
                XCTAssertFalse(error is CancellationError, "\(failure) became a cancellation")
                XCTAssertEqual(String(describing: error), String(describing: failure))
            }
        }
    }

    /// A request whose task was cancelled (the screen was left) is a cancellation whatever it failed
    /// with: the screen that would report the failure is gone.
    @MainActor
    func testAnyFailureOfACancelledTaskSurfacesAsCancellationError() async {
        let gate = Gate()
        let client = APIClient(transport: { _ in
            await gate.wait()
            throw URLError(.timedOut)
        })
        let request = Task { @MainActor in
            try await client.payload(.get, "civic-score", label: "test")
        }
        request.cancel()
        gate.open()

        do {
            _ = try await request.value
            XCTFail("Expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    @MainActor
    func testIsCancellationRecognizesEveryCancelledShape() {
        for cancelled in cancelledRequestErrors {
            XCTAssertTrue(APIErrorResponse.isCancellation(cancelled), "\(cancelled)")
        }
        XCTAssertFalse(APIErrorResponse.isCancellation(Self.timeout))
        XCTAssertFalse(APIErrorResponse.isCancellation(APIError.networkError("offline", nil, URLError(.notConnectedToInternet))))
        XCTAssertFalse(APIErrorResponse.isCancellation(FakeServiceError()))
    }

    // MARK: - Stores on their live services

    @MainActor
    func testCivicScoreAndProfileStayQuietWhenTheirRequestIsCancelled() async throws {
        for cancelled in cancelledRequestErrors {
            let scoreStore = CivicScoreStore(scope: "user-1", userDefaults: try isolatedDefaults(), service: CivicService.Live())
            let profileStore = CivicProfileStore(service: CivicService.Live())
            await APIClient.$current.withValue(failingClient(with: cancelled)) {
                await scoreStore.refresh()
                await profileStore.refresh()
            }
            XCTAssertNil(scoreStore.lastError, "\(cancelled)")
            XCTAssertNil(profileStore.lastError, "\(cancelled)")
            XCTAssertFalse(scoreStore.isLoading)
            XCTAssertFalse(profileStore.isLoading)
        }

        let scoreStore = CivicScoreStore(scope: "user-1", userDefaults: try isolatedDefaults(), service: CivicService.Live())
        let profileStore = CivicProfileStore(service: CivicService.Live())
        await APIClient.$current.withValue(failingClient(with: Self.timeout)) {
            await scoreStore.refresh()
            await profileStore.refresh()
        }
        // R2's offline copy, now shown in the Civic Rank sheet and on Profile (UX-39 N11).
        XCTAssertEqual(scoreStore.lastError, "Can't reach Billboard right now. Check your connection and try again.", "a real failure is still reported")
        XCTAssertEqual(profileStore.lastError, "Can't reach Billboard right now. Check your connection and try again.")
    }

    @MainActor
    func testVoteStatusLoadsStayQuietWhenTheirRequestIsCancelled() async {
        func makeStore() -> BillVoteStore {
            BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: BillVotesService.Live())
        }

        for cancelled in cancelledRequestErrors {
            let store = makeStore()
            let message = await APIClient.$current.withValue(failingClient(with: cancelled)) {
                await store.fetchVotes(for: ["BILLS-119hr1", "BILLS-119hr2"])
                return await store.fetchVoteIfNeeded(for: "BILLS-119hr3")
            }
            XCTAssertNil(store.lastError, "\(cancelled)")
            XCTAssertNil(message, "\(cancelled)")
        }

        let store = makeStore()
        await APIClient.$current.withValue(failingClient(with: Self.timeout)) {
            await store.fetchVotes(for: ["BILLS-119hr1", "BILLS-119hr2"])
        }
        XCTAssertEqual(store.lastError, BillVoteStore.loadVotesFailedMessage)
        let message = await APIClient.$current.withValue(failingClient(with: Self.timeout)) {
            await store.fetchVoteIfNeeded(for: "BILLS-119hr3")
        }
        XCTAssertEqual(message, BillVoteStore.checkVoteFailedMessage)
    }

    @MainActor
    func testWeeklyBriefStaysQuietAndBuildsNothingWhenItsRequestIsCancelled() async throws {
        for cancelled in cancelledRequestErrors + [Self.timeout] {
            let defaults = try isolatedDefaults()
            defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
            let bills = FakeBillsService()
            let store = WeeklyDigestStore(
                scope: "cancellation-tests",
                defaults: defaults,
                digestService: WeeklyDigestService.Live(),
                billsService: bills,
                votesService: FakeBillVotesService(),
                congressService: FakeCongressService()
            )
            let profile = UserProfile.placeholder().updating(id: "user-1", subscribedSubCategories: ["Energy"])

            await APIClient.$current.withValue(failingClient(with: cancelled)) {
                await store.refresh(profile: profile, forceRefresh: true)
            }

            XCTAssertNil(store.errorMessage, "\(cancelled)")
            XCTAssertFalse(store.isLoading)
            if cancelled is URLError, (cancelled as? URLError)?.code == .timedOut {
                // Unchanged: an unreachable published brief falls back to building one on the device.
                XCTAssertEqual(bills.manifestRequests.count, 1, "the timeout falls back to the local build")
            } else {
                XCTAssertTrue(bills.manifestRequests.isEmpty, "a cancelled refresh does not go on to build locally: \(cancelled)")
            }
        }
    }

    /// The local build swallows vote and bill fetch failures; a refresh cancelled during them must not
    /// build and persist a brief from the bills it did not load.
    @MainActor
    func testACancelledLocalBuildPersistsNoBrief() async throws {
        let window = WeeklyDigestStore.latestPublishedWindow(relativeTo: Date())
        let moved = ISO8601DateFormatter().string(from: window.start.addingTimeInterval(24 * 60 * 60))
        let item = BillsManifestItem(
            guid: "BILLS-119hr77",
            congress: "119",
            billType: "hr",
            billID: "77",
            updatedAt: moved,
            subCategories: ["Energy"],
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            title: "Bill 77",
            billStatus: "Updated"
        )
        let profile = UserProfile.placeholder().updating(id: "user-1", subscribedSubCategories: ["Energy"])

        func makeStore(votes: any BillVotesServicing, defaults: UserDefaults) -> WeeklyDigestStore {
            let bills = FakeBillsService()
            bills.manifestResults = [.success([item])]
            return WeeklyDigestStore(
                scope: "cancellation-tests",
                defaults: defaults,
                digestService: EmptyWeeklyDigestService(),
                billsService: bills,
                votesService: votes,
                congressService: FakeCongressService()
            )
        }

        // Unchanged: without a cancellation the brief is built from the same data.
        let builtDefaults = try isolatedDefaults()
        builtDefaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        let built = makeStore(votes: FakeBillVotesService(), defaults: builtDefaults)
        await built.refresh(profile: profile, forceRefresh: true)
        XCTAssertNotNil(built.digest, "the control build produces a brief")

        let defaults = try isolatedDefaults()
        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        let store = makeStore(votes: TaskCancellingVotesService(), defaults: defaults)
        let refresh = Task { @MainActor in
            await store.refresh(profile: profile, forceRefresh: true)
        }
        await refresh.value

        XCTAssertNil(store.digest, "no brief from a cancelled build")
        XCTAssertNil(store.errorMessage)
        let reopened = makeStore(votes: FakeBillVotesService(), defaults: defaults)
        XCTAssertNil(reopened.digest, "nothing was persisted")
    }

    @MainActor
    func testMembersDirectoryStaysQuietWhenItsLoadIsCancelled() async {
        for cancelled in cancelledRequestErrors {
            let service = FakeCongressService()
            service.manifestResult = .failure(cancelled)
            let store = CongressMembersManifestStore(service: service)

            await store.load(forceRefresh: true)

            XCTAssertNil(store.errorMessage, "\(cancelled)")
            XCTAssertFalse(store.isLoading)
        }

        let service = FakeCongressService()
        service.manifestResult = .failure(Self.timeout)
        let store = CongressMembersManifestStore(service: service)
        await store.load(forceRefresh: true)
        XCTAssertEqual(store.errorMessage, "Could not load members right now.")
    }

    @MainActor
    func testProfilePreferencesLoadStaysQuietWhenItIsCancelled() async {
        for failure in cancelledRequestErrors + [Self.timeout] {
            let preferences = FakePreferencesService()
            preferences.getPreferencesError = failure
            let store = UserStore(preferencesService: preferences, congressService: FakeCongressService())

            // The compliance check before the preferences load goes through `APIClient`; an empty
            // response fails to decode and is only logged.
            await APIClient.$current.withValue(RecordingTransport().client) {
                await store.refresh(userId: "cancellation-tests-user", attributes: [])
            }

            if failure is URLError, (failure as? URLError)?.code == .timedOut {
                XCTAssertEqual(store.errorMessage, "Could not load your preferences right now.", "a real failure is still reported")
            } else {
                XCTAssertNil(store.errorMessage, "\(failure)")
            }
            XCTAssertFalse(store.isLoading)
        }
    }

    /// RootView's bootstrap task is cancelled when the launch screen's Try Again restarts it. A
    /// cancelled preferences load is not a finished refresh, so the user keeps the launch screen
    /// instead of being sent to "Where do you vote?" from a half-loaded profile. A finished refresh
    /// decides it as before. (R2: setup depends only on the state and district, spec D 2.5.3, so this
    /// account has no district.)
    @MainActor
    func testACancelledBootstrapRefreshDoesNotSendAnOnboardedUserToOnboarding() async {
        let userId = "cancellation-tests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            UserStore.clearCachedProfile(userId: userId)
            UserDefaults.standard.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        }
        let preferences = HangingPreferencesService()
        let store = UserStore(preferencesService: preferences, congressService: FakeCongressService())
        let me = Data(#"{"userId":"\#(userId)","adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#.utf8)
        let transport = RecordingTransport()
        transport.responses = [me, me]
        let attributes = [
            AuthUserAttribute(.custom("state"), value: "CA")
        ]

        let bootstrap = Task { @MainActor in
            await APIClient.$current.withValue(transport.client) {
                await store.refresh(userId: userId, attributes: attributes)
            }
        }
        for _ in 0..<10_000 where !preferences.isWaiting { await Task.yield() }
        XCTAssertTrue(preferences.isWaiting, "precondition: the preferences load is in flight")
        XCTAssertTrue(store.canPerformUserWrites, "precondition: compliance loaded")
        XCTAssertTrue(store.needsOnboarding, "precondition: the base profile has no district")

        bootstrap.cancel() // Try Again: `bootstrapAttempt += 1` cancels the running bootstrap task.
        await bootstrap.value

        XCTAssertFalse(store.shouldShowOnboarding, "a user whose preferences load was cancelled is not sent to setup")
        XCTAssertFalse(store.hasRefreshedOnce, "the launch screen stays until a refresh finishes")
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage, "a cancelled load is not reported")

        // The retried bootstrap finishes (this user has no district): setup shows as before.
        preferences.hangs = false
        await APIClient.$current.withValue(transport.client) {
            await store.refresh(userId: userId, attributes: attributes)
        }
        XCTAssertTrue(store.hasRefreshedOnce)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.shouldShowOnboarding, "a finished refresh still decides onboarding")
    }
}

/// A `GET /preferences` still in flight when its task is cancelled; it then throws `CancellationError`,
/// as `APIClient.payload` surfaces a cancelled request. Answers with no preferences once `hangs` is false.
@MainActor
private final class HangingPreferencesService: PreferencesServicing {
    var hangs = true
    private(set) var isWaiting = false

    func getPreferences() async throws -> [PreferencesItem] {
        guard hangs else { return [] }
        isWaiting = true
        defer { isWaiting = false }
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return []
    }

    func putPreferences(_ items: [PreferencesItem]) async throws {}
    func deletePreferences(_ items: [PreferencesItem]) async throws {}
}

/// Cancels the task that asks for vote states, then fails the request as a cancelled one would.
@MainActor
private final class TaskCancellingVotesService: BillVotesServicing {
    func fetchFeedback(billIds: [String]) async throws -> [String: BillVotesService.RemoteVoteState] {
        withUnsafeCurrentTask { $0?.cancel() }
        throw CancellationError()
    }

    func fetchFeedback(billId: String) async throws -> BillVotesService.RemoteVoteState {
        withUnsafeCurrentTask { $0?.cancel() }
        throw CancellationError()
    }

    func setFeedback(billId: String, feedback: VoteType, reasons: [String]) async throws {}
}
