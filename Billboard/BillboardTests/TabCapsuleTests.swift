import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Where the tab capsule sits and when it leaves (Civic Record spec 3.10, 3.22, 4.9; project decision 3):
/// 16 pt from the sides and 24 pt above the bottom edge (12 pt with a Home button), the Undo toast 10 pt
/// above it, hidden on the bill page and while the keyboard is up.
///
/// The hosted tests put the real `TabCapsuleHost` and a real `BillDetail` (fake services, no network) in a
/// window on the simulator's screen, push and pop the bill page, and read the capsule's four tabs from
/// the accessibility tree. They capture the window in light and dark for review and measure the capsule on
/// the captures (from the simulator's screen when asked, see `capture(_:name:)`).
@MainActor
final class TabCapsuleTests: XCTestCase {
    // MARK: - Layout

    func testTheCapsuleSits24PointsAboveTheBottomEdgeOr12WithAHomeButton() {
        // Face ID iPhones: 24 pt above the edge, inside the 34 pt home-indicator area; the content clears
        // the capsule 54 pt above its safe area.
        XCTAssertEqual(TabCapsuleLayout.bottomMargin(safeAreaBottom: 34), 24)
        XCTAssertEqual(TabCapsuleLayout.contentClearance(safeAreaBottom: 34), 54)
        // iPhone SE: no bottom safe area; the capsule is drawn 12 pt above the edge.
        XCTAssertEqual(TabCapsuleLayout.bottomMargin(safeAreaBottom: 0), 12)
        XCTAssertEqual(TabCapsuleLayout.contentClearance(safeAreaBottom: 0), 76)
        XCTAssertEqual(TabCapsuleLayout.sideMargin, 16)
        XCTAssertEqual(BillboardTabBar.height, 64)
        XCTAssertEqual(BillboardTabBar.selectionHeight, 56)
    }

    func testTheUndoToastSits10PointsAboveTheCapsuleOr24AboveTheEdge() {
        // Over the capsule: 10 pt above its top, which is 54 pt (76 pt) above the content's safe area.
        XCTAssertEqual(TabCapsuleLayout.toastBottomPadding(capsuleShown: true, keyboardShown: false, safeAreaBottom: 34), 64)
        XCTAssertEqual(TabCapsuleLayout.toastBottomPadding(capsuleShown: true, keyboardShown: false, safeAreaBottom: 0), 86)
        // Capsule hidden by the page: 24 pt above the edge (10 pt into the 34 pt home-indicator area), or 12.
        XCTAssertEqual(TabCapsuleLayout.toastBottomPadding(capsuleShown: false, keyboardShown: false, safeAreaBottom: 34), -10)
        XCTAssertEqual(TabCapsuleLayout.toastBottomPadding(capsuleShown: false, keyboardShown: false, safeAreaBottom: 0), 12)
        // Keyboard up: 10 pt above the keyboard.
        XCTAssertEqual(TabCapsuleLayout.toastBottomPadding(capsuleShown: false, keyboardShown: true, safeAreaBottom: 34), 10)
    }

    /// The capsule shows unless the screen hides it or the keyboard is up (on Search it would otherwise
    /// ride on top of the keyboard, slice 0 spike).
    func testTheCapsuleLeavesForTheBillPageAndTheKeyboard() {
        XCTAssertTrue(TabCapsuleLayout.showsCapsule(screenHidesCapsule: false, keyboardShown: false))
        XCTAssertFalse(TabCapsuleLayout.showsCapsule(screenHidesCapsule: true, keyboardShown: false))
        XCTAssertFalse(TabCapsuleLayout.showsCapsule(screenHidesCapsule: false, keyboardShown: true))
        XCTAssertFalse(TabCapsuleLayout.showsCapsule(screenHidesCapsule: true, keyboardShown: true))
    }

    /// One screen asking is enough: the preference is OR-reduced.
    func testTheHiddenPreferenceIsOrReduced() {
        func reduced(_ values: [Bool]) -> Bool {
            var value = TabCapsuleHiddenPreference.defaultValue
            for next in values {
                TabCapsuleHiddenPreference.reduce(value: &value) { next }
            }
            return value
        }
        XCTAssertFalse(reduced([]))
        XCTAssertFalse(reduced([false, false]))
        XCTAssertTrue(reduced([false, true, false]))
        XCTAssertTrue(reduced([true, false]))
    }

    // MARK: - When the bill page counts as on top again

    /// A swipe-back that reveals the bill page (from a member page pushed over it) hides the capsule only
    /// once it completes: SwiftUI's `onAppear` ran at the start of the swipe, so a held half swipe that was
    /// then cancelled hid the capsule for the whole hold, with the member page still on screen (review
    /// harness, UI test on the simulator). A push or a pop with the Back button counts at once.
    func testTheBillPageCountsAsOnTopOnlyWhenASwipeBackToItCompletes() {
        var calls = 0
        SettledAppearanceProbe.pageWillAppear(transition: nil) { calls += 1 }
        XCTAssertEqual(calls, 1, "no transition: at once")

        let push = StubTransition(isInteractive: false)
        SettledAppearanceProbe.pageWillAppear(transition: push) { calls += 1 }
        XCTAssertEqual(calls, 2, "a push or the Back button: at once")
        XCTAssertTrue(push.completions.isEmpty)

        let cancelled = StubTransition(isInteractive: true)
        SettledAppearanceProbe.pageWillAppear(transition: cancelled) { calls += 1 }
        XCTAssertEqual(calls, 2, "a swipe-back that reveals the page: not while it is held")
        cancelled.isCancelled = true
        cancelled.finish()
        XCTAssertEqual(calls, 2, "a cancelled swipe-back: never")

        let completed = StubTransition(isInteractive: true)
        SettledAppearanceProbe.pageWillAppear(transition: completed) { calls += 1 }
        XCTAssertEqual(calls, 2)
        completed.finish()
        XCTAssertEqual(calls, 3, "a completed swipe-back: when it completes")
    }

    // MARK: - Hosted: push and pop a bill page

    /// The navigation path the test drives.
    @MainActor
    private final class Router: ObservableObject {
        @Published var path: [Int] = []
        @Published var showsSheet = false
    }

    private enum Page: Int {
        case bill = 1
        case member = 2
    }

    /// A Bills root (masthead and slips on paper) in a navigation stack that pushes a real bill page and,
    /// over it, a plain page, with the real capsule host around it, as `TabsBar` builds it.
    private struct Shell: View {
        @ObservedObject var router: Router
        let billID: UUID
        let undoCenter: UndoCenter
        let date: Date

        var body: some View {
            NavigationStack(path: $router.path) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MastheadBand(date: date)
                        VStack(spacing: 12) {
                            ForEach(0..<6) { index in
                                RollSheet {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(verbatim: "H.R. \(1200 + index) · House").textRole(.docket).foregroundStyle(BillboardColors.dimText)
                                        Text("Clean Energy Reporting Act of 2026, part \(index + 1)").textRole(.name)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(32)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .billboardBackground()
                .tabRootBar(wordmark: .masthead) {}
                .navigationDestination(for: Int.self) { value in
                    if value == Page.bill.rawValue {
                        BillDetail(billID: billID)
                    } else {
                        ScrollView { Text("A member page").padding(20) }
                            .billboardBackground()
                            .navigationTitle("Member")
                            .glassNavigationBar()
                    }
                }
            }
            .modifier(TabCapsuleHost(
                selectedTab: .home,
                homeBadgeCount: 3,
                updatesBadgeCount: 12,
                onSelect: { _ in },
                undoCenter: undoCenter
            ))
        }
    }

    private func bill() -> Bill {
        Bill(
            id: UUID.deterministic(from: "BILLS-119hr1234"),
            title: "Clean Energy Reporting Act",
            category: "Other",
            soWhat: "It changes how a thing works.",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600)),
            billStatus: .new,
            guid: "BILLS-119hr1234",
            userVoted: false,
            isPriority: true,
            isProcessedDetailHydrated: true
        )
    }

    /// The shell with its stores, as the app gives them, and the router that drives it.
    private func shell() throws -> (view: AnyView, router: Router) {
        let bill = bill()
        let scope = "tab-capsule-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedManifest = []
        let billsStore = BillsStore(bills: [bill], cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        let undoCenter = UndoCenter(isVoiceOverRunning: { false }, isSwitchControlRunning: { false }, announce: { _ in })
        addTeardownBlock { withExtendedLifetime((voteStore, undoCenter)) {} }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))
        let router = Router()
        let view = Shell(router: router, billID: bill.id, undoCenter: undoCenter, date: date)
            .environmentObject(billsStore)
            .environmentObject(voteStore)
            .environmentObject(AppReadState(scope: .user(scope), store: InMemoryReadStateStore()))
            .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
            .environmentObject(CongressMembersManifestStore(service: FakeCongressService()))
            .environmentObject(CivicScoreStore(scope: scope, service: FakeCivicService()))
            .tint(BillboardColors.interactive)
        return (AnyView(view), router)
    }

    private func screen() throws -> (scene: UIWindowScene, size: CGSize) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        return (scene, scene.screen.bounds.size)
    }

    private func capsuleShows(_ host: AccessibilityTreeText.Host) -> Bool {
        host.traits(of: "Updates") != nil && host.traits(of: "Profile") != nil
    }

    /// Project decision 3: the capsule leaves as a bill page is pushed and comes back after the pop. A page
    /// pushed over the bill page (a member page) shows it again, and popping back to the bill hides it.
    /// The four tab ids stay on the buttons.
    func testTheCapsuleHidesOnAPushedBillPageAndReturnsAfterThePop() throws {
        let (scene, size) = try screen()
        let (view, router) = try shell()
        let host = AccessibilityTreeText.Host(view, size: size, settle: 1.0, scene: scene)
        defer { host.close() }

        XCTAssertTrue(capsuleShows(host), "the capsule on the Bills root: \(host.text())")
        XCTAssertEqual(
            ["Bills", "Updates", "Congress", "Profile"].map { host.identifier(of: $0) },
            ["tab.billboard", "tab.updates", "tab.congress", "tab.profile"]
        )

        router.path = [Page.bill.rawValue]
        host.run(untilSettled: { !capsuleShows(host) && host.traits(of: BillVoteBarModel.accessibilityLabel) != nil })
        XCTAssertFalse(capsuleShows(host), "no capsule on the bill page: \(host.text())")
        XCTAssertNotNil(host.traits(of: BillVoteBarModel.accessibilityLabel), "the vote bar is the bottom bar: \(host.text())")

        router.path = [Page.bill.rawValue, Page.member.rawValue]
        host.run(untilSettled: { capsuleShows(host) })
        XCTAssertTrue(capsuleShows(host), "a page pushed over the bill page shows the capsule")

        router.path = [Page.bill.rawValue]
        host.run(untilSettled: { !capsuleShows(host) })
        XCTAssertFalse(capsuleShows(host), "back on the bill page, the capsule leaves again")

        router.path = []
        host.run(untilSettled: { capsuleShows(host) })
        XCTAssertTrue(capsuleShows(host), "the capsule returns after the pop")
    }

    // MARK: - Taps on the capsule

    /// Every point of the capsule takes its own taps (UIKit hit-tests the window there to the view that
    /// draws the capsule), down to its bottom edge, 24 pt above the screen's: none goes through the glass
    /// to the slips scrolled under it. In a `safeAreaBar`, which ended 34 pt above the edge, the
    /// capsule's lowest 10 pt hit-tested to the slips' scroll view.
    func testTheWholeCapsuleTakesTaps() throws {
        let (scene, size) = try screen()
        let (view, _) = try shell()
        let host = AccessibilityTreeText.Host(view, size: size, settle: 1.0, scene: scene)
        defer { host.close() }

        let bottom = size.height - TabCapsuleLayout.bottomMargin(safeAreaBottom: host.window.safeAreaInsets.bottom)
        // The Updates tab's column.
        let x = TabCapsuleLayout.sideMargin + (size.width - 2 * TabCapsuleLayout.sideMargin) * 3 / 8
        let middle = try XCTUnwrap(host.window.hitTest(CGPoint(x: x, y: bottom - 32), with: nil))
        XCTAssertFalse(isInScrollView(middle), "the capsule's middle: \(type(of: middle))")
        for height in [2.0, 6.0, 9.0, 12.0, 62.0] {
            let hit = try XCTUnwrap(host.window.hitTest(CGPoint(x: x, y: bottom - height), with: nil))
            XCTAssertFalse(isInScrollView(hit), "\(height) pt above the capsule's bottom, a tap goes to \(type(of: hit))")
            XCTAssertTrue(hit === middle, "\(height) pt above the capsule's bottom: \(type(of: hit)), not \(type(of: middle))")
        }
    }

    private func isInScrollView(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate is UIScrollView { return true }
            current = candidate.superview
        }
        return false
    }

    // MARK: - Lists end above the capsule

    private enum ListPage: Int {
        case list = 1
        case scroll = 2
        case form = 3
        case hidesCapsule = 4
    }

    /// Long content under the tabs, as `TabsBar` builds them: a root scroll view of slips with the list
    /// screens' 16 pt bottom margin, and pushed pages: a plain `List`, a scroll view, a `Form`, and a page
    /// that hides the capsule (as the bill page does). The root can present a sheet.
    private struct ListShell: View {
        @ObservedObject var router: Router
        let undoCenter: UndoCenter

        var body: some View {
            NavigationStack(path: $router.path) {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(0..<24) { index in
                            RollSheet { Text("Slip \(index)").frame(maxWidth: .infinity, minHeight: 72).padding(16) }
                        }
                    }
                    .padding(16)
                }
                .billboardBackground()
                .tabRootBar(wordmark: .masthead) {}
                .sheet(isPresented: $router.showsSheet) {
                    ScrollView { VStack { ForEach(0..<40) { Text("Sheet row \($0)").frame(height: 44) } } }
                        .withoutTabCapsuleClearance()
                }
                .navigationDestination(for: Int.self) { value in
                    switch ListPage(rawValue: value) {
                    case .list:
                        List(0..<40) { Text("Row \($0)") }.listStyle(.plain).navigationTitle("List").glassNavigationBar()
                    case .scroll:
                        ScrollView { VStack { ForEach(0..<40) { Text("Row \($0)").frame(maxWidth: .infinity, minHeight: 44) } } }
                            .navigationTitle("Scroll")
                            .glassNavigationBar()
                    case .form:
                        Form { ForEach(0..<40) { Text("Row \($0)") } }.navigationTitle("Form").glassNavigationBar()
                    case .hidesCapsule, nil:
                        ScrollView { VStack { ForEach(0..<40) { Text("Row \($0)").frame(maxWidth: .infinity, minHeight: 44) } } }
                            .navigationTitle("Bill")
                            .glassNavigationBar()
                            .hidesTabCapsule()
                    }
                }
            }
            .modifier(TabCapsuleHost(selectedTab: .home, homeBadgeCount: 3, updatesBadgeCount: 12, onSelect: { _ in }, undoCenter: undoCenter))
        }
    }

    /// The largest scroll view in `view`'s hierarchy that is showing.
    private func mainScrollView(in view: UIView) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else { return }
            if let scroll = view as? UIScrollView, scroll.window != nil { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.bounds.height * $0.bounds.width < $1.bounds.height * $1.bounds.width }
    }

    /// Scrolls `scroll` to its end and returns where its last content ends on the screen: a list's last
    /// row, or the end of a scroll view's content.
    private func contentEnd(of scroll: UIScrollView, host: AccessibilityTreeText.Host) -> CGFloat {
        let maxOffset = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, maxOffset)), animated: false)
        host.run(0.3)
        if let list = scroll as? UICollectionView {
            return list.visibleCells.map { $0.convert($0.bounds, to: host.window).maxY }.max() ?? .infinity
        }
        let frame = scroll.convert(scroll.bounds, to: host.window)
        return frame.minY + scroll.contentSize.height - scroll.contentOffset.y
    }

    /// Spec 4.9: scrolled to the end, the content of every list under the tabs ends at or above the
    /// capsule's top, on the root and on pushed pages alike, and keeps its own bottom margin (the root's
    /// 16 pt). Before, the scroll views inside the tabs' navigation stacks saw only the 34 pt
    /// home-indicator area and ended 54 pt lower, under the glass. A page that hides the capsule (the bill
    /// page) and a sheet presented from the tabs get no such margin.
    func testListsUnderTheTabsEndAboveTheCapsule() throws {
        let (scene, size) = try screen()
        let router = Router()
        let undoCenter = UndoCenter(isVoiceOverRunning: { false }, isSwitchControlRunning: { false }, announce: { _ in })
        let view = ListShell(router: router, undoCenter: undoCenter)
            .environmentObject(CivicScoreStore(scope: "tab-capsule-lists-\(UUID().uuidString)", service: FakeCivicService()))
        let host = AccessibilityTreeText.Host(view, size: size, settle: 1.0, scene: scene)
        defer { host.close() }
        let safeAreaBottom = host.window.safeAreaInsets.bottom
        let capsuleTop = size.height - TabCapsuleLayout.bottomMargin(safeAreaBottom: safeAreaBottom) - BillboardTabBar.height

        let root = try XCTUnwrap(mainScrollView(in: host.window), "the root's scroll view")
        let rootEnd = contentEnd(of: root, host: host)
        XCTAssertLessThanOrEqual(rootEnd, capsuleTop + 0.5, "the root's content ends at the capsule's top")
        XCTAssertGreaterThan(rootEnd, capsuleTop - 1, "and not higher")

        for page in [ListPage.list, .scroll, .form] {
            router.path = [page.rawValue]
            host.run(1.2)
            host.run(untilSettled: { mainScrollView(in: host.window) !== root })
            let scroll = try XCTUnwrap(mainScrollView(in: host.window), "\(page)")
            let end = contentEnd(of: scroll, host: host)
            XCTAssertLessThanOrEqual(end, capsuleTop + 0.5, "\(page): the last row ends at or above the capsule's top")
            XCTAssertGreaterThan(end, capsuleTop - 40, "\(page): close to it, not a screen above")
            router.path = []
            host.run(1.2)
            host.run(untilSettled: { mainScrollView(in: host.window) === root })
        }

        router.path = [ListPage.hidesCapsule.rawValue]
        host.run(1.5)
        host.run(untilSettled: { !capsuleShows(host) })
        XCTAssertFalse(capsuleShows(host), "the page hides the capsule")
        let bill = try XCTUnwrap(mainScrollView(in: host.window))
        XCTAssertEqual(bill.adjustedContentInset.bottom, safeAreaBottom, accuracy: 0.5, "no capsule, no clearance")
        router.path = []
        host.run(1.5)
        host.run(untilSettled: { mainScrollView(in: host.window) === root })

        router.showsSheet = true
        host.run(1.5)
        let sheet = try XCTUnwrap(host.window.rootViewController?.presentedViewController, "the sheet")
        let sheetScroll = try XCTUnwrap(mainScrollView(in: sheet.view), "the sheet's scroll view")
        XCTAssertEqual(
            sheetScroll.adjustedContentInset.bottom,
            sheetScroll.safeAreaInsets.bottom,
            accuracy: 0.5,
            "a sheet presented from the tabs ends at its own bottom"
        )
        router.showsSheet = false
        host.run(1.0)
    }

    // MARK: - The tour's anchor

    @MainActor
    private final class AnchorFrames {
        var frames: [TutorialAnchor: CGRect] = [:]
    }

    /// Spec 4.9: the tour measures the capsule (`TutorialAnchor.tabBar`) where it is on the screen, 16 pt
    /// in and 24 pt above the bottom edge (12 pt on a phone with a Home button), and so ends its card 10 pt
    /// above it. (The capsule is measured in window coordinates: in the tour's named space, a `safeAreaBar`'s
    /// content came out 62 pt too high.)
    func testTheTourMeasuresTheCapsuleWhereItIsOnTheScreen() throws {
        let (scene, size) = try screen()
        let (view, _) = try shell()
        let box = AnchorFrames()
        let measured = view
            .coordinateSpace(name: ProductTutorialStorage.coordinateSpaceName)
            .environment(\.tutorialFrameCaptureEnabled, true)
            .onPreferenceChange(TutorialAnchorFramePreferenceKey.self) { frames in
                box.frames = frames
            }
        let host = AccessibilityTreeText.Host(measured, size: size, settle: 1.0, scene: scene)
        defer { host.close() }

        let frame = try XCTUnwrap(box.frames[.tabBar], "the capsule is measured while the tour can run")
        let margin = TabCapsuleLayout.bottomMargin(safeAreaBottom: host.window.safeAreaInsets.bottom)
        XCTAssertEqual(frame.minX, 16, accuracy: 0.5)
        XCTAssertEqual(frame.width, size.width - 32, accuracy: 0.5)
        XCTAssertEqual(frame.height, 64, accuracy: 0.5)
        XCTAssertEqual(size.height - frame.maxY, margin, accuracy: 0.5, "\(margin) pt above the bottom edge")
        XCTAssertEqual(
            ProductTutorialOverlay.bottomInset(tabBarFrame: frame, screenHeight: size.height),
            BillboardTabBar.height + margin + TabCapsuleLayout.toastGap,
            accuracy: 0.5
        )
    }

    // MARK: - Captures of the glass on the screen

    /// The Bills root with the glass capsule over slips, the pushed bill page without it and the root after
    /// the pop, in light and dark, attached for review. The capsule's bottom edge is 24 pt above the
    /// screen's bottom edge (12 pt on a phone with a Home button) and its sides 16 pt in (measured in light,
    /// over paper), and the selected tab is opaque navy with its brand-teal stroke in both appearances.
    ///
    /// `ImageRenderer` cannot draw the navigation bars, so the window is captured whole: from the simulator's
    /// screen when `BB_SCREEN_CAPTURE_DIR` is set (`TEST_RUNNER_BB_SCREEN_CAPTURE_DIR` for xcodebuild; see
    /// `capture(_:name:)`), else with `drawHierarchy`, which places everything right but draws glass a little
    /// off (slice 0 spike), so the checks here avoid the glass's own colour.
    func testCapturesOfTheGlassCapsuleOnTheScreen() throws {
        let (scene, size) = try screen()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = style == .dark ? "dark" : "light"
            let (view, router) = try shell()
            let host = AccessibilityTreeText.Host(view, size: size, settle: 1.0, scene: scene)
            defer { host.close() }
            host.window.overrideUserInterfaceStyle = style
            host.run(1.0)

            let pixels = try ScreenPixels(capture(host, name: "tab-capsule-bills-root-\(name)"), size: size)
            let margin = TabCapsuleLayout.bottomMargin(safeAreaBottom: host.window.safeAreaInsets.bottom)
            // The capsule's middle row, the margin + 32 pt above the bottom edge.
            let middleY = size.height - margin - 32
            // Inside the selected Bills capsule (x from 20 pt), left of its symbol: opaque navy.
            assertColor(pixels.rgb(x: 28, y: middleY), BillboardPalette.navy.light.rgb, accuracy: 0.02, "opaque navy selection, \(name)")
            // Its brand-teal stroke at its leftmost point (20 to 21.5 pt).
            let stroke = pixels.rgb(x: 20.67, y: middleY)
            XCTAssertLessThan(stroke.red, 0.12, "teal stroke \(name): \(stroke)")
            XCTAssertGreaterThan(stroke.green, 0.6, "teal stroke \(name): \(stroke)")
            if style == .light {
                // Over paper the glass is far darker than the paper around it, so its edges show.
                let bottom = try XCTUnwrap(pixels.lastDarkRow(x: size.width / 2, from: size.height - 60, to: size.height), "capsule bottom")
                XCTAssertEqual(size.height - bottom, margin, accuracy: 1.5, "\(margin) pt above the bottom edge")
                let left = try XCTUnwrap(pixels.firstDarkColumn(y: middleY, from: 0, to: 60), "capsule left edge")
                XCTAssertEqual(left, 16, accuracy: 1.5, "16 pt from the side")
            }

            router.path = [Page.bill.rawValue]
            host.run(1.5)
            host.run(untilSettled: { !capsuleShows(host) })
            XCTAssertFalse(capsuleShows(host), "no capsule on the bill page, \(name)")
            _ = try capture(host, name: "bill-page-no-capsule-\(name)")
            router.path = []
            host.run(1.5)
            host.run(untilSettled: { capsuleShows(host) })
            XCTAssertTrue(capsuleShows(host), "the capsule is back, \(name)")
            _ = try capture(host, name: "tab-capsule-after-pop-\(name)")
        }
    }

    /// Captures the host's window and attaches the image.
    ///
    /// With `BB_SCREEN_CAPTURE_DIR` set, the test writes `<dir>/<name>.request` and waits up to 20 s for
    /// `<dir>/<name>.png`, which a watcher on the Mac makes with `xcrun simctl io <device> screenshot`: the
    /// simulator's real screen, identical to `XCUIScreen` (slice 0 spike), which a unit test may not call.
    /// Without it, the window is drawn with `drawHierarchy`.
    private func capture(_ host: AccessibilityTreeText.Host, name: String) throws -> UIImage {
        let image: UIImage
        if let directory = ProcessInfo.processInfo.environment["BB_SCREEN_CAPTURE_DIR"], !directory.isEmpty {
            let folder = URL(fileURLWithPath: directory)
            let png = folder.appendingPathComponent("\(name).png")
            try? FileManager.default.removeItem(at: png)
            try Data().write(to: folder.appendingPathComponent("\(name).request"))
            let deadline = Date().addingTimeInterval(20)
            var captured: UIImage?
            while captured == nil, Date() < deadline {
                host.run(0.25)
                // The watcher writes the file in one go; a partial file does not decode.
                captured = (try? Data(contentsOf: png)).flatMap(UIImage.init(data:))
            }
            image = try XCTUnwrap(captured, "no screen capture for \(name) in \(directory)")
        } else {
            let window = host.window
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.traitCollection.displayScale
            image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "screen-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    // MARK: - Helpers

    private func assertColor(
        _ sample: (red: Double, green: Double, blue: Double),
        _ expected: BillboardColorMath.RGB,
        accuracy: Double,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sample.red, expected.red, accuracy: accuracy, "red: \(message) \(sample)", file: file, line: line)
        XCTAssertEqual(sample.green, expected.green, accuracy: accuracy, "green: \(message) \(sample)", file: file, line: line)
        XCTAssertEqual(sample.blue, expected.blue, accuracy: accuracy, "blue: \(message) \(sample)", file: file, line: line)
    }
}

/// A screenshot's pixels in sRGB, addressed in points.
private struct ScreenPixels {
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    private let bytes: [UInt8]

    /// `size` is the screen's size in points; the image may be at any scale.
    init(_ image: UIImage, size: CGSize) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        width = cgImage.width
        height = cgImage.height
        scale = CGFloat(cgImage.width) / size.width
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        bytes = buffer
    }

    /// The colour of the pixel under the point `x`, `y`.
    func rgb(x: CGFloat, y: CGFloat) -> (red: Double, green: Double, blue: Double) {
        let column = min(width - 1, max(0, Int(x * scale)))
        let row = min(height - 1, max(0, Int(y * scale)))
        let index = (row * width + column) * 4
        return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255)
    }

    private func isDark(_ rgb: (red: Double, green: Double, blue: Double)) -> Bool {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue < 0.4
    }

    /// The bottom of the last dark pixel row at `x` between `from` and `to`, in points.
    func lastDarkRow(x: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat? {
        let column = Int(x * scale)
        var found: Int?
        for row in Int(from * scale)..<min(height, Int(to * scale)) where isDark(rgbAt(column, row)) {
            found = row
        }
        return found.map { CGFloat($0 + 1) / scale }
    }

    /// The left of the first dark pixel column at `y` between `from` and `to`, in points.
    func firstDarkColumn(y: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat? {
        let row = Int(y * scale)
        for column in Int(from * scale)..<min(width, Int(to * scale)) where isDark(rgbAt(column, row)) {
            return CGFloat(column) / scale
        }
        return nil
    }

    private func rgbAt(_ column: Int, _ row: Int) -> (red: Double, green: Double, blue: Double) {
        let index = (row * width + column) * 4
        return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255)
    }
}

/// A navigation transition whose completion the test runs (`finish()`).
@MainActor
private final class StubTransition: NSObject, UIViewControllerTransitionCoordinator {
    var isInteractive: Bool
    var isCancelled = false
    private(set) var completions: [(any UIViewControllerTransitionCoordinatorContext) -> Void] = []

    init(isInteractive: Bool) {
        self.isInteractive = isInteractive
    }

    func finish() {
        completions.forEach { $0(self) }
    }

    var isAnimated: Bool { true }
    var presentationStyle: UIModalPresentationStyle { .none }
    var initiallyInteractive: Bool { isInteractive }
    var isInterruptible: Bool { false }
    var transitionDuration: TimeInterval { 0.35 }
    var percentComplete: CGFloat { 0.5 }
    var completionVelocity: CGFloat { 1 }
    var completionCurve: UIView.AnimationCurve { .easeInOut }
    var containerView: UIView { UIView() }
    var targetTransform: CGAffineTransform { .identity }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }

    func animate(
        alongsideTransition animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
        completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?
    ) -> Bool {
        if let completion { completions.append(completion) }
        return true
    }

    func animateAlongsideTransition(
        in view: UIView?,
        animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
        completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?
    ) -> Bool {
        if let completion { completions.append(completion) }
        return true
    }

    func notifyWhenInteractionEnds(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}
    func notifyWhenInteractionChanges(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}
}
