import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Spec 3.21 and 4.6: every pushed screen has the system glass bar, never the navy of the tab root it came
/// from. The bill page is often pushed before its content is ready (a deep link, a push, the Weekly Brief,
/// a bill that is not loaded), so its load-error and not-found states are pushed here from a navy root,
/// drawn through UIKit in light and dark, and checked for a navy band.
@MainActor
final class BillPageBarTests: XCTestCase {
    private static let size = CGSize(width: 390, height: 844)

    private enum Page: Hashable {
        case bill(UUID)
    }

    /// A navy tab root with `page` pushed over it, with the stores the bill page reads.
    private func pushed(_ billID: UUID, bills: [Bill]) -> AnyView {
        let scope = "bill-page-bar-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        // The fake fails every processed-bill fetch, so a bill without its details shows the load error.
        let service = FakeBillsService()
        service.cachedManifest = []
        let billsStore = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        return AnyView(
            NavigationStack(path: .constant([Page.bill(billID)])) {
                ScrollView { PageTitle(title: "Updates") }
                    .billboardBackground()
                    .tabRootBar(wordmark: .compact) {}
                    .navigationDestination(for: Page.self) { page in
                        switch page {
                        case .bill(let id): BillDetail(billID: id)
                        }
                    }
            }
            .environmentObject(billsStore)
            .environmentObject(voteStore)
            .environmentObject(AppReadState(scope: .user(scope), store: InMemoryReadStateStore()))
            .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
            .environmentObject(CongressMembersManifestStore(service: FakeCongressService()))
            .environmentObject(CivicScoreStore(scope: scope, service: FakeCivicService()))
        )
    }

    private func unloadedBill() -> Bill {
        Bill(
            id: UUID.deterministic(from: "BILLS-119hr4321"),
            title: "Clean Energy Reporting Act",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600)),
            billStatus: .new,
            guid: "BILLS-119hr4321",
            userVoted: false,
            isProcessedDetailHydrated: false
        )
    }

    func testTheBillPageHasTheGlassBarInItsLoadErrorAndNotFoundStates() throws {
        let bill = unloadedBill()
        let states: [(name: String, view: AnyView, text: String)] = [
            ("load-error", pushed(bill.id, bills: [bill]), "Couldn't load this bill."),
            ("not-found", pushed(UUID(), bills: []), "Bill not found")
        ]
        let navy = BillboardPalette.navy.light
        for state in states {
            let text = AccessibilityTreeText.text(of: state.view, settle: 0.8)
            XCTAssertTrue(text.contains(state.text), "\(state.name): \(text)")
            for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                let image = try snapshot(state.view, style: style)
                let attachment = XCTAttachment(image: image)
                attachment.name = "bill-page-\(state.name)-\(styleName)"
                attachment.lifetime = .keepAlways
                add(attachment)
                // Down the left edge, the status bar and the bar included: no navy anywhere.
                let column = try SnapshotPixels.column(of: image, x: 6)
                XCTAssertFalse(
                    column.contains { SnapshotPixels.matches($0, navy, tolerance: 0.02) },
                    "\(state.name) \(styleName): the pushed bill page has no navy band"
                )
            }
        }
    }

    /// Hosts `view` in its own window with the given appearance and draws the window.
    private func snapshot(_ view: AnyView, style: UIUserInterfaceStyle) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
