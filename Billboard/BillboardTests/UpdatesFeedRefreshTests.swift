import Combine
import XCTest
@testable import Billboard

/// When the Updates screen rebuilds its feed after `BillsStore.bills` changes. `$bills` sends before
/// the write (willSet), so a handler that reads the store from it sees the old bills. A manifest
/// refresh whose reconcile finds no vote to apply no longer writes `bills` a second time, so the
/// handler's one run read the bills from before the refresh and Updates kept the old feed.
/// `NotificationsView.billsDidChange(in:)` is the publisher the screen subscribes to.
final class UpdatesFeedRefreshTests: XCTestCase {
    private static let guid = "BILLS-119hr101ih"

    private func manifestItem(status: String, updatedAt: Date) -> BillsManifestItem {
        BillsManifestItem(
            guid: Self.guid,
            congress: "119",
            billType: "hr",
            billID: "101",
            updatedAt: ISO8601DateFormatter().string(from: updatedAt),
            subCategories: [],
            lifeAreas: [],
            sponsors: [],
            cosponsors: [],
            isPriority: true, // so the placeholder profile's topics do not decide the feed
            priorityRank: 1,
            title: "A bill",
            billStatus: status
        )
    }

    private struct Fixture {
        let store: BillsStore
        let voteStore: BillVoteStore
        let voteCache: BillVoteCache
        let service: FakeBillsService
        let scope: String
    }

    /// A store connected to an empty vote store that has loaded a manifest holding the bill as new.
    /// The service answers its next `getBillsManifest` call with the bill as passed.
    @MainActor
    private func makeLoadedStore() async -> Fixture {
        let scope = "updates-feed-refresh-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.manifestResults = [
            .success([manifestItem(status: "New", updatedAt: Date().addingTimeInterval(-2 * 60 * 60))]),
            .success([manifestItem(status: "Passed", updatedAt: Date().addingTimeInterval(-60 * 60))])
        ]
        let voteCache = BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil))
        let voteStore = BillVoteStore(cache: voteCache, service: FakeBillVotesService())
        let store = BillsStore(cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        store.connect(voteStore: voteStore)
        // The bills store holds the vote store weakly; keep it for the whole test.
        addTeardownBlock { withExtendedLifetime(voteStore) {} }

        await store.load(historyWindow: .oneWeek)
        await settleBillsCache(scope: scope)
        return Fixture(store: store, voteStore: voteStore, voteCache: voteCache, service: service, scope: scope)
    }

    /// Runs what was already queued on the main queue, which is where the publisher delivers.
    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func feed(of store: BillsStore, voteStore: BillVoteStore) -> UpdatesFeedSnapshot {
        NotificationsView.updatesFeed(
            billsStore: store,
            alerts: [],
            readState: AppReadState(scope: .user("updates-feed-refresh-tests"), store: InMemoryReadStateStore()),
            userProfile: .placeholder(),
            voteStore: voteStore,
            historyWindow: .oneWeek
        )
    }

    @MainActor
    func testFeedAfterARefreshWithNoVotesToReconcileListsTheBillThatPassed() async {
        let fixture = await makeLoadedStore()
        let (store, voteStore) = (fixture.store, fixture.voteStore)
        XCTAssertEqual(feed(of: store, voteStore: voteStore).passedBills.map(\.guid), [], "new before the refresh")

        // The Updates screen is up: it rebuilds its feed from the store each time the publisher fires.
        var feeds: [UpdatesFeedSnapshot] = []
        let subscription = NotificationsView.billsDidChange(in: store).sink { _ in
            feeds.append(self.feed(of: store, voteStore: voteStore))
        }
        await drainMainQueue()
        feeds.removeAll() // the subscription's first value, delivered for the current bills

        await store.load(forceRefresh: true, historyWindow: .oneWeek)
        await drainMainQueue()
        await settleBillsCache(scope: fixture.scope)

        XCTAssertEqual(fixture.service.manifestRequests.count, 2)
        XCTAssertEqual(store.bills.first?.billStatus, .passed)
        XCTAssertFalse(feeds.isEmpty, "the refresh wrote the bills")
        XCTAssertEqual(feeds.last?.passedBills.map(\.guid), [Self.guid], "the feed the screen ends on lists it")
        subscription.cancel()
    }

    @MainActor
    func testFeedAfterARefreshThatReconcilesAVoteSeesTheReconciledBills() async {
        let fixture = await makeLoadedStore()
        let store = fixture.store
        // The vote store learned a vote that the bill does not carry yet; the refresh's reconcile applies it.
        fixture.voteCache.setVoted(billId: Self.guid, vote: .yea, votedAt: Date())

        var observed: [Bool?] = []
        let subscription = NotificationsView.billsDidChange(in: store).sink { _ in
            observed.append(store.bill(forGUID: Self.guid)?.userVoted)
        }
        await drainMainQueue()
        observed.removeAll()

        await store.load(forceRefresh: true, historyWindow: .oneWeek)
        await drainMainQueue()
        await settleBillsCache(scope: fixture.scope)

        XCTAssertEqual(store.bill(forGUID: Self.guid)?.userVoted, true, "the reconcile marked the bill voted")
        XCTAssertFalse(observed.isEmpty)
        XCTAssertEqual(observed.last, true, "the last run reads the bills after the reconcile, not the merged ones")
        subscription.cancel()
    }

    @MainActor
    func testBillsDidChangeDeliversAfterTheWriteAndTheLookupsHaveFollowed() async {
        let scope = "updates-feed-refresh-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let original = companionTestBill(Self.guid)
        let store = BillsStore(
            bills: [original],
            cacheScope: scope,
            service: FakeBillsService(),
            preferencesService: FakePreferencesService()
        )
        var seen: [BillStatus?] = []
        let subscription = NotificationsView.billsDidChange(in: store).sink { _ in
            seen.append(store.bill(for: original.id)?.billStatus)
        }
        await drainMainQueue()
        XCTAssertEqual(seen, [.new], "the current bills are delivered when the screen subscribes")
        seen.removeAll()

        var passed = original
        passed.billStatus = .passed
        store.bills = [passed]
        XCTAssertEqual(seen, [], "not inside the write, where the lookups still hold the old bill")
        await drainMainQueue()

        XCTAssertEqual(seen, [.passed], "one delivery, once the write and its lookups are done")
        subscription.cancel()
    }

    /// APPF-31: Updates rebuilds its feed when the profile changes, reading `userStore.profile`. Straight from
    /// `$profile` that read gets the profile being replaced; through `didChange` it gets the new one.
    @MainActor
    func testDidChangeDeliversTheProfileOnceItIsStored() async {
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        var direct: [[BillContentTypePreference]] = []
        var deferred: [[BillContentTypePreference]] = []
        let directSubscription = userStore.$profile.sink { _ in direct.append(userStore.profile.selectedBillContentTypes) }
        let deferredSubscription = NotificationsView.didChange(userStore.$profile).sink { _ in
            deferred.append(userStore.profile.selectedBillContentTypes)
        }
        await drainMainQueue()
        direct.removeAll()
        deferred.removeAll()

        userStore.updateSelectedBillContentTypes([.jointResolutions])
        for _ in 0..<20 where userStore.profile.selectedBillContentTypes != [.jointResolutions] {
            await drainMainQueue()
        }
        await drainMainQueue()

        XCTAssertEqual(userStore.profile.selectedBillContentTypes, [.jointResolutions], "the profile changed")
        XCTAssertEqual(direct.first, [], "a handler on $profile itself reads the profile being replaced")
        XCTAssertEqual(deferred.first, [.jointResolutions], "didChange delivers once the new profile is stored")
        directSubscription.cancel()
        deferredSubscription.cancel()
    }
}
