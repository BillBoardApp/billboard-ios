import XCTest
@testable import Billboard

/// Deep links are untrusted input. Only the share-site host (Info.plist `SHARE_SITE_BASE_URL`)
/// and the `billboard://` scheme are accepted, and the guid must match
/// `^BILLS-[0-9]+[a-z]+[0-9]+[a-z]*$`. Everything else is rejected.
final class AppDeepLinkTests: XCTestCase {
    private let validGuid = "BILLS-119hjres131eh"

    // MARK: - billboard:// scheme

    @MainActor
    func testAppSchemeWithGuidQueryIsAccepted() throws {
        let url = try XCTUnwrap(URL(string: "billboard://bill?guid=\(validGuid)"))
        XCTAssertEqual(AppDeepLink(url: url), .bill(guid: validGuid))
    }

    @MainActor
    func testGuidWithoutVersionSuffixIsAccepted() throws {
        let url = try XCTUnwrap(URL(string: "billboard://bill?guid=BILLS-118s2025"))
        XCTAssertEqual(AppDeepLink(url: url), .bill(guid: "BILLS-118s2025"))
    }

    // MARK: - Share site

    @MainActor
    func testShareURLFromShareBuilderRoundTrips() throws {
        let url = try XCTUnwrap(BillShareURLBuilder.shareURL(forBillGuid: validGuid))
        XCTAssertEqual(AppDeepLink(url: url), .bill(guid: validGuid))
    }

    @MainActor
    func testSharePathOnConfiguredHostIsAccepted() throws {
        let host = try shareHost()
        let url = try XCTUnwrap(URL(string: "https://\(host)/b/\(validGuid)"))
        XCTAssertEqual(AppDeepLink(url: url), .bill(guid: validGuid))
    }

    @MainActor
    func testWebHostAllowListIsMatchedExactly() throws {
        let url = try XCTUnwrap(URL(string: "https://links.example.org/b/\(validGuid)"))

        XCTAssertEqual(AppDeepLink(url: url, allowedWebHosts: ["links.example.org"]), .bill(guid: validGuid))
        XCTAssertNil(AppDeepLink(url: url, allowedWebHosts: ["example.org"]))
        XCTAssertNil(AppDeepLink(url: url, allowedWebHosts: []))
    }

    // MARK: - Rejected hosts and schemes

    @MainActor
    func testSharePathOnOtherHostsIsRejected() throws {
        let host = try shareHost()
        let candidates = [
            "https://example.com/b/\(validGuid)",
            "https://\(host).example.com/b/\(validGuid)",
            "https://not\(host)/b/\(validGuid)",
            "https://\(host)@example.com/b/\(validGuid)"
        ]

        for candidate in candidates {
            let url = try XCTUnwrap(URL(string: candidate), candidate)
            XCTAssertNil(AppDeepLink(url: url), candidate)
        }
    }

    @MainActor
    func testOtherSchemesAreRejected() throws {
        let host = try shareHost()
        let candidates = [
            "ftp://\(host)/b/\(validGuid)",
            "file:///b/\(validGuid)",
            "otherapp://bill?guid=\(validGuid)"
        ]

        for candidate in candidates {
            let url = try XCTUnwrap(URL(string: candidate), candidate)
            XCTAssertNil(AppDeepLink(url: url), candidate)
        }
    }

    // MARK: - Guid validation

    @MainActor
    func testMalformedGuidsAreRejected() throws {
        let host = try shareHost()
        let malformed = [
            "hello",
            "BILLS-119hr",
            "BILLS-hr1",
            "119hr1",
            "BILLS-119hr1-ih",
            "BILLS-119hr1ih2",
            "BILLS-119hr1;x"
        ]

        for guid in malformed {
            let appURL = try XCTUnwrap(URL(string: "billboard://bill?guid=\(guid)"), guid)
            XCTAssertNil(AppDeepLink(url: appURL), appURL.absoluteString)

            let shareURL = try XCTUnwrap(URL(string: "https://\(host)/b/\(guid)"), guid)
            XCTAssertNil(AppDeepLink(url: shareURL), shareURL.absoluteString)
        }
    }

    @MainActor
    func testEncodedPathTraversalInGuidQueryIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "billboard://bill?guid=BILLS-119hr1%2F..%2F..%2Fadmin"))
        XCTAssertNil(AppDeepLink(url: url))
    }

    @MainActor
    func testMissingGuidIsRejected() throws {
        let host = try shareHost()
        let candidates = [
            "billboard://bill",
            "billboard://bill?guid=",
            "https://\(host)/b/",
            "https://\(host)/"
        ]

        for candidate in candidates {
            let url = try XCTUnwrap(URL(string: candidate), candidate)
            XCTAssertNil(AppDeepLink(url: url), candidate)
        }
    }

    // MARK: - Companion groups (APPF-23)

    /// A link to either member of a companion group parses as that bill; the router then opens the
    /// group on its primary when the primary's bill is loaded, else on the linked bill.
    @MainActor
    func testLinkToTheOtherMemberOpensThePrimaryOnlyWhenItIsLoaded() async throws {
        let house = "BILLS-119hr900"
        let senate = "BILLS-119s456"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let url = try XCTUnwrap(URL(string: "billboard://bill?guid=\(senate)"))
        XCTAssertEqual(AppDeepLink(url: url), .bill(guid: senate))

        let (loaded, _, scopeA) = await makeCompanionStore(
            bills: [companionTestBill(house), companionTestBill(senate)],
            groups: [group]
        )
        XCTAssertEqual(loaded.deepLinkBillID(forGUID: senate), UUID.deterministic(from: house))
        XCTAssertEqual(loaded.deepLinkBillID(forGUID: "BILLS-119s456is"), UUID.deterministic(from: house))
        XCTAssertEqual(loaded.deepLinkBillID(forGUID: "BILLS-119hr1"), UUID.deterministic(from: "BILLS-119hr1"))

        let (primaryMissing, _, scopeB) = await makeCompanionStore(bills: [companionTestBill(senate)], groups: [group])
        XCTAssertEqual(primaryMissing.deepLinkBillID(forGUID: senate), UUID.deterministic(from: senate))

        let (ungrouped, _, scopeC) = await makeCompanionStore(
            bills: [companionTestBill(house), companionTestBill(senate)],
            groups: []
        )
        XCTAssertEqual(ungrouped.deepLinkBillID(forGUID: senate), UUID.deterministic(from: senate), "no groups: today's routing")

        // Nothing here writes the bills cache (only votes, watches and loads do).
        _ = (scopeA, scopeB, scopeC)
    }

    // MARK: - When a link may open (DeepLinkGate)

    /// A link (push, share link, `billboard://`) navigates only once the tabs are usable and the tour
    /// is over. Until then it waits in `PendingAppDeepLink` / `PendingPushDeepLink` and opens later
    /// (spec D 5.2: links held during the new tour and setup).
    @MainActor
    func testLinksOpenOnlyWhenTheTabsAreUsableAndNoTourIsPending() {
        XCTAssertTrue(isReady())
        XCTAssertFalse(isReady(tabsInteractive: false), "loading, age gate, ineligible or setup screen")
        XCTAssertFalse(isReady(isCompletingOnboarding: true), "setup's success panel, before its Continue")
        XCTAssertFalse(isReady(isProfileLoading: true))
        XCTAssertFalse(isReady(isShowingTour: true), "the tour is on screen")
        XCTAssertFalse(isReady(pendingAutoShowTour: true), "setup asked for the tour; it has not started yet")
        XCTAssertFalse(isReady(replayTourRequested: true))
    }

    /// The first-run sequence: setup, its success panel, the tabs with the tour, then the tour ends.
    /// A link that arrived at any point opens only at the end.
    @MainActor
    func testALinkArrivingDuringFirstRunWaitsForTheEndOfTheTour() {
        let sequence: [(String, Bool)] = [
            ("setup form", isReady(tabsInteractive: false, isCompletingOnboarding: true)),
            ("success panel, tour requested", isReady(tabsInteractive: false, isCompletingOnboarding: true, pendingAutoShowTour: true)),
            ("tabs shown, tour about to start", isReady(pendingAutoShowTour: true)),
            ("tour on screen", isReady(isShowingTour: true)),
            ("tour finished", isReady())
        ]
        XCTAssertEqual(sequence.map(\.1), [false, false, false, false, true], "\(sequence)")
    }

    @MainActor
    private func isReady(
        tabsInteractive: Bool = true,
        isCompletingOnboarding: Bool = false,
        isProfileLoading: Bool = false,
        isShowingTour: Bool = false,
        pendingAutoShowTour: Bool = false,
        replayTourRequested: Bool = false
    ) -> Bool {
        DeepLinkGate.isReady(
            tabsInteractive: tabsInteractive,
            isCompletingOnboarding: isCompletingOnboarding,
            isProfileLoading: isProfileLoading,
            isShowingTour: isShowingTour,
            pendingAutoShowTour: pendingAutoShowTour,
            replayTourRequested: replayTourRequested
        )
    }

    // MARK: - Helpers

    /// Host of the configured share site, taken from the same source the app uses.
    @MainActor
    private func shareHost() throws -> String {
        let shareURL = try XCTUnwrap(
            BillShareURLBuilder.shareURL(forBillGuid: validGuid),
            "SHARE_SITE_BASE_URL is not configured"
        )
        return try XCTUnwrap(shareURL.host)
    }
}
