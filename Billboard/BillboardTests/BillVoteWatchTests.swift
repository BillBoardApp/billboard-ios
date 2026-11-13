import XCTest
@testable import Billboard

/// Watch is its own control (spec D 2.1.5), checked against the real stores on fakes: a vote from
/// the bar passes `watch: nil`, so it never adds or removes a Watch row (on a companion group it
/// neither unwatches the other member nor adds a row on the vote target); only the Watch toggle
/// (`BillWatchPlan`) does.
@MainActor
final class BillVoteWatchTests: XCTestCase {
    private static let watchedGuid = "BILLS-119hr901"
    private static let unwatchedGuid = "BILLS-119hr902"
    private static let house = "BILLS-119hr900"
    private static let senate = "BILLS-119s456"

    func testAVoteFromTheBarWritesNoWatchPreference() async {
        var watched = companionTestBill(Self.watchedGuid)
        watched.userWatched = true
        let unwatched = companionTestBill(Self.unwatchedGuid)
        let stores = await makeStores(bills: [watched, unwatched], groups: [], watchedGuids: [Self.watchedGuid])
        XCTAssertEqual(stores.user.profile.watchedBillGUIDs, [Self.watchedGuid], "precondition: the profile holds the watch")
        let putsBefore = stores.userPreferences.putCalls.count
        let deletesBefore = stores.userPreferences.deleteCalls.count

        var writes: [Task<Bool, Never>] = []
        for choice in VoteChoice.allCases {
            for bill in [watched, unwatched] {
                // What the bar passes: leave watch as it is.
                if let write = stores.bills.vote(billID: bill.id, vote: UserVote(choice.voteType), watch: nil) {
                    writes.append(write)
                }
            }
        }
        for write in writes {
            _ = await write.value
        }
        await settle()

        XCTAssertEqual(stores.userPreferences.putCalls.count, putsBefore, "no Watch row was added")
        XCTAssertEqual(stores.userPreferences.deleteCalls.count, deletesBefore, "no Watch row was removed")
        XCTAssertTrue(stores.bills.isWatched(billID: watched.id))
        XCTAssertFalse(stores.bills.isWatched(billID: unwatched.id))
        XCTAssertEqual(stores.user.profile.watchedBillGUIDs, [Self.watchedGuid])
        XCTAssertEqual(stores.votes.setFeedbackCalls.count, 6, "every vote was still sent")
        await settleBillsCache(scope: stores.scope)
    }

    func testAVoteOnAGroupKeepsTheOtherMemberWatched() async {
        let group = BillCompanionGroup(primaryGuid: Self.house, memberGuids: [Self.house, Self.senate], relationship: "identical")
        let house = companionTestBill(Self.house)
        var senate = companionTestBill(Self.senate)
        senate.userWatched = true
        let stores = await makeStores(bills: [house, senate], groups: [group], watchedGuids: [Self.senate])
        let putsBefore = stores.userPreferences.putCalls.count
        let deletesBefore = stores.userPreferences.deleteCalls.count

        // The group is watched (its Senate member is); the vote goes to the House primary.
        XCTAssertTrue(stores.bills.isWatched(billID: house.id), "precondition: a group is watched when any member is")
        _ = await stores.bills.vote(billID: house.id, vote: .yea, watch: nil)?.value
        await settle()

        XCTAssertTrue(stores.bills.bill(forGUID: Self.senate)?.userWatched == true, "the other member stays watched")
        XCTAssertFalse(stores.bills.bill(forGUID: Self.house)?.userWatched == true, "the vote target is not marked watched")
        XCTAssertTrue(stores.bills.isWatched(billID: house.id))
        XCTAssertEqual(stores.userPreferences.putCalls.count, putsBefore, "no Watch row was added on the vote target")
        XCTAssertEqual(stores.userPreferences.deleteCalls.count, deletesBefore, "nothing was unwatched")
        XCTAssertEqual(stores.user.profile.watchedBillGUIDs, [Self.senate])
        XCTAssertEqual(stores.votes.setFeedbackCalls.count, 1, "the vote was still sent")
        await settleBillsCache(scope: stores.scope)
    }

    func testOnlyTheWatchToggleUnwatchesAGroup() async {
        let group = BillCompanionGroup(primaryGuid: Self.house, memberGuids: [Self.house, Self.senate], relationship: "identical")
        let house = companionTestBill(Self.house)
        var senate = companionTestBill(Self.senate)
        senate.userWatched = true
        let stores = await makeStores(bills: [house, senate], groups: [group], watchedGuids: [Self.senate])

        let plan = BillWatchPlan.make(watch: false, targetGuid: Self.house, memberGuids: group.memberGuids)
        plan.apply(billID: house.id, billsStore: stores.bills, userStore: stores.user)
        await settle()

        XCTAssertFalse(stores.bills.isWatched(billID: house.id))
        XCTAssertFalse(stores.user.profile.watchedBillGUIDs.contains(Self.senate))
        let deleted = stores.userPreferences.deleteCalls.flatMap { $0 }
        XCTAssertEqual(deleted.map(\.preference), [Self.senate], "one DELETE /preferences for the watched member")
        XCTAssertEqual(deleted.map(\.type), ["Watch"])
        await settleBillsCache(scope: stores.scope)
    }

    func testTheWatchToggleAddsOneWatch() async {
        let bill = companionTestBill(Self.unwatchedGuid)
        let stores = await makeStores(bills: [bill], groups: [], watchedGuids: [])

        BillWatchPlan.make(watch: true, targetGuid: Self.unwatchedGuid, memberGuids: [Self.unwatchedGuid])
            .apply(billID: bill.id, billsStore: stores.bills, userStore: stores.user)
        await settle()

        XCTAssertEqual(stores.user.profile.watchedBillGUIDs, [Self.unwatchedGuid])
        let added = stores.userPreferences.putCalls.flatMap { $0 }.filter { $0.type == "Watch" }
        XCTAssertEqual(added.map(\.preference), [Self.unwatchedGuid])
        // The tab shell reconciles the bills store from the profile.
        stores.bills.reconcileWatchesFromProfile(stores.user.profile.watchedBillGUIDs)
        XCTAssertTrue(stores.bills.isWatched(billID: bill.id))
        await settleBillsCache(scope: stores.scope)
    }

    // MARK: - Helpers

    private struct Stores {
        let bills: BillsStore
        let user: UserStore
        let userPreferences: FakePreferencesService
        let votes: FakeBillVotesService
        let scope: String
    }

    /// A bills store connected to a vote store and to a user store whose profile watches
    /// `watchedGuids` and may write (an attested adult), each on fakes.
    private func makeStores(bills: [Bill], groups: [BillCompanionGroup], watchedGuids: [String]) async -> Stores {
        let userId = "vote-bar-tests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            UserStore.clearCachedProfile(userId: userId)
            UserDefaults.standard.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        }
        let userPreferences = FakePreferencesService()
        userPreferences.preferences = PreferencesMutations.watchItems(for: watchedGuids)
        let user = UserStore(preferencesService: userPreferences, congressService: FakeCongressService())
        let me = Data(#"{"userId":"\#(userId)","adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#.utf8)
        let transport = RecordingTransport()
        transport.responses = [me, me]
        await APIClient.$current.withValue(transport.client) {
            await user.refresh(userId: userId, attributes: [])
        }
        XCTAssertTrue(user.canPerformUserWrites, "precondition: the user may write")

        let scope = "vote-bar-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedGroups = groups
        service.cachedManifest = []
        let store = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let votes = FakeBillVotesService()
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        store.connect(voteStore: voteStore)
        store.connect(userStore: user)
        // The bills store holds both stores weakly; keep them for the whole test.
        addTeardownBlock { withExtendedLifetime((voteStore, user)) {} }
        await store.restoreCachedStateIfNeeded()
        return Stores(bills: store, user: user, userPreferences: userPreferences, votes: votes, scope: scope)
    }

    /// Lets the stores' fire-and-forget writes run.
    private func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }
}
