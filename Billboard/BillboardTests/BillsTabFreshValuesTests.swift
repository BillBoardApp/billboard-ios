import Amplify
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// APPF-31: a store's `@Published` publisher fires before the new value is stored (willSet). The Bills tab
/// rebuilt its list from the stores inside those handlers, so after a change it could keep a list built
/// from the previous value. At a sign-in with no saved profile (a fresh install, a new phone, or after a
/// sign-out) the placeholder profile comes first and the saved one a moment later, so the tab kept the
/// starter feed (the newest bills of every type) until something else rebuilt it.
@MainActor
final class BillsTabFreshValuesTests: XCTestCase {
    private func houseBill(_ number: String, title: String) -> Bill {
        Bill(
            id: UUID.deterministic(from: "BILLS-119hr\(number)"),
            title: title,
            category: "Economic Policy",
            subCategory: "Energy",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 60 * 60)),
            billStatus: .new,
            guid: "BILLS-119hr\(number)",
            congress: "119",
            billType: "hr",
            billID: number,
            userVoted: false,
            isPriority: false
        )
    }

    /// One profile change while the list is on screen, with nothing else after it: Bill types turned down to
    /// joint resolutions only. The list must drop both House bills at once. Before APPF-31 it kept them, since
    /// the `$profile` handler rebuilt the list from the profile that was being replaced.
    func testTheListFollowsABillTypeChangeAtOnce() throws {
        let scope = "fresh-values-\(UUID().uuidString.prefix(8))"
        let bills = [
            houseBill("4101", title: "Rural Water Access Act"),
            houseBill("4102", title: "Small Business Filing Relief Act")
        ]
        let fixture = try hostedBillsTab(scope: scope, bills: bills, saved: PreferencesMutations.categoryItems(for: ["Energy"]))
        defer { fixture.host.close() }
        let host = fixture.host
        XCTAssertTrue(
            host.run(until: { host.text().contains("Rural Water Access Act") }, timeout: 10),
            "both House bills on Energy are listed while every bill type is allowed: \(host.text())"
        )

        fixture.userStore.updateSelectedBillContentTypes([.jointResolutions])
        XCTAssertTrue(
            host.run(until: { fixture.userStore.profile.selectedBillContentTypes == [.jointResolutions] }, timeout: 5),
            "the profile changed"
        )
        host.run(until: { host.text().contains("You're all caught up") }, timeout: 5)
        let text = host.text()
        XCTAssertTrue(text.contains("You're all caught up"), "the list follows the new bill types: \(text)")
        XCTAssertFalse(text.contains("Rural Water Access Act"), text)
        XCTAssertFalse(text.contains("Small Business Filing Relief Act"), text)
    }

    /// The sign-in path end to end: the refresh sets the bare profile (no preferences, so the starter feed)
    /// and then the saved one, which follows Energy but allows only joint resolutions. In this hosted run a
    /// later profile update also rebuilds the list, so this guards the outcome rather than reproducing the
    /// stale read (the test above does that).
    func testTheListFollowsTheSavedPreferencesThatArriveAfterSignIn() throws {
        let scope = "fresh-values-\(UUID().uuidString.prefix(8))"
        let bills = [
            houseBill("4101", title: "Rural Water Access Act"),
            houseBill("4102", title: "Small Business Filing Relief Act")
        ]
        let service = FakeBillsService()
        service.manifestResults = [.success(bills.map { bill in
            BillsManifestItem(
                guid: bill.guid!, congress: "119", billType: bill.billType, billID: bill.billID,
                updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600)),
                subCategories: ["Energy"], lifeAreas: [], sponsors: [], cosponsors: [],
                isPriority: bill.isPriority, title: bill.title, billStatus: bill.billStatus.rawValue
            )
        })]
        let stub = APIClient(transport: { request in
            guard await request.path == "me" else { throw URLError(.notConnectedToInternet) }
            return Data(#"{"adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#.utf8)
        })
        let billsStore = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        let saved = StaticPreferencesService(
            items: PreferencesMutations.categoryItems(for: ["Energy"])
                + PreferencesMutations.contentTypeItems(for: [.jointResolutions])
        )
        let userStore = UserStore(preferencesService: saved, congressService: FakeCongressService())
        var loaded = false
        Task { @MainActor in
            await APIClient.$current.withValue(stub) {
                await billsStore.load(forceRefresh: true, mode: .manifestOnly, historyWindow: .oneWeek)
            }
            loaded = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !loaded, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(loaded, "the bills loaded")

        let readState = AppReadState(scope: .user(scope), store: InMemoryReadStateStore())
        let appState = AppState()
        appState.hasCompletedHomeQueueReconciliation = true
        appState.isReconcilingHomeQueue = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        APIClient.$current.withValue(stub) {
            let host = AccessibilityTreeText.Host(
                NavigationStack { BillBoardTab() }
                    .environmentObject(readState)
                    .environmentObject(billsStore)
                    .environmentObject(appState)
                    .environmentObject(userStore)
                    .environmentObject(voteStore)
                    .environmentObject(BillAlertsStore(alerts: [])),
                size: scene.screen.bounds.size,
                settle: 1.0,
                scene: scene
            )
            defer { host.close() }

            // The refresh sets the bare profile (the account and its district, no preferences: the starter
            // feed), then the saved preferences.
            var signedIn = false
            Task { @MainActor in
                await APIClient.$current.withValue(stub) {
                    await userStore.refresh(userId: "fresh-\(scope)", attributes: [
                        AuthUserAttribute(.custom("state"), value: "VA"),
                        AuthUserAttribute(.custom("district"), value: "11")
                    ])
                }
                signedIn = true
            }
            XCTAssertTrue(host.run(until: { signedIn }, timeout: 10), "the sign-in refresh finished")
            XCTAssertEqual(userStore.profile.selectedBillContentTypes, [.jointResolutions], "the saved preferences arrived")

            host.run(until: { host.text().contains("You're all caught up") }, timeout: 5)
            let text = host.text()
            XCTAssertTrue(text.contains("You're all caught up"), "the list follows the saved preferences: \(text)")
            XCTAssertFalse(text.contains("Rural Water Access Act"), "no House bill once only joint resolutions are allowed: \(text)")
            XCTAssertFalse(text.contains("Small Business Filing Relief Act"), text)
        }
    }

    private struct HostedBillsTab {
        let host: AccessibilityTreeText.Host
        let userStore: UserStore
    }

    /// The real Bills tab over loaded bills and a signed-in profile built from `saved`, with the queue
    /// reconciliation done.
    private func hostedBillsTab(scope: String, bills: [Bill], saved: [PreferencesItem]) throws -> HostedBillsTab {
        let service = FakeBillsService()
        service.manifestResults = [.success(bills.map { bill in
            BillsManifestItem(
                guid: bill.guid!, congress: "119", billType: bill.billType, billID: bill.billID,
                updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600)),
                subCategories: ["Energy"], lifeAreas: [], sponsors: [], cosponsors: [],
                isPriority: bill.isPriority, title: bill.title, billStatus: bill.billStatus.rawValue
            )
        })]
        let stub = APIClient(transport: { request in
            guard await request.path == "me" else { throw URLError(.notConnectedToInternet) }
            return Data(#"{"adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#.utf8)
        })
        let billsStore = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: saved), congressService: FakeCongressService())
        var loaded = false
        Task { @MainActor in
            await APIClient.$current.withValue(stub) {
                await userStore.refresh(userId: "fresh-\(scope)", attributes: [
                    AuthUserAttribute(.custom("state"), value: "VA"),
                    AuthUserAttribute(.custom("district"), value: "11")
                ])
                await billsStore.load(forceRefresh: true, mode: .manifestOnly, historyWindow: .oneWeek)
            }
            loaded = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !loaded, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(loaded, "the stores loaded")

        let appState = AppState()
        appState.hasCompletedHomeQueueReconciliation = true
        appState.isReconcilingHomeQueue = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = AccessibilityTreeText.Host(
            NavigationStack { BillBoardTab() }
                .environmentObject(AppReadState(scope: .user(scope), store: InMemoryReadStateStore()))
                .environmentObject(billsStore)
                .environmentObject(appState)
                .environmentObject(userStore)
                .environmentObject(voteStore)
                .environmentObject(BillAlertsStore(alerts: [])),
            size: scene.screen.bounds.size,
            settle: 1.0,
            scene: scene
        )
        return HostedBillsTab(host: host, userStore: userStore)
    }
}
