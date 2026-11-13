import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders what the updates-empty slice changes (feature review N2, N5 and N10, pulled into 1.2), and attaches each
/// image for review: every use of `RecordNotice` with its title at subheadline size, the empty Updates tab with
/// the Weekly Brief's quiet line, and the startup failure screen with Try again and no framework error. Light and
/// dark, at the default size and AX5 (the startup screen also at AX3). No network, no credentials, no baselines.
@MainActor
final class QuietStatesRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String {
            let sizeName: String
            switch size {
            case .large: sizeName = "default"
            case .accessibility3: sizeName = "AX3"
            default: sizeName = "AX5"
            }
            return "\(scheme == .dark ? "dark" : "light")-\(sizeName)"
        }

        var style: UIUserInterfaceStyle { scheme == .dark ? .dark : .light }
    }

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility5),
        Variant(scheme: .dark, size: .accessibility5)
    ]

    private static let width: CGFloat = 390

    // MARK: - Empty-state titles (N10)

    /// The title is drawn in the `subheadline` role, under a `heading` section head, so NOTHING YET reads as a
    /// note rather than a second head; it used to be the `name` role, 20 pt bold condensed under a 22 pt head.
    func testTheNoticeTitleIsSubheadlineUnderTheSectionHead() throws {
        XCTAssertEqual(RecordNotice.titleRole, .subheadline)
        XCTAssertLessThan(RecordNotice.titleRole.size, TextRole.heading.size)
        XCTAssertLessThan(RecordNotice.titleRole.size, TextRole.name.size)
        for size in [DynamicTypeSize.large, .accessibility5] {
            XCTAssertLessThan(
                RecordNotice.titleRole.scaledSize(for: size),
                TextRole.heading.scaledSize(for: size),
                "the title stays below the section head at \(size)"
            )
        }

        // A one-line notice is shorter than it was: the title line is a subheadline line, not a 20 pt one.
        let notice = try height(of: RecordNotice(.nothingYet, title: "No recent actions"), size: .large)
        let stamp = try height(of: StatusStamp(.nothingYet), size: .large)
        let subheadlineLine = try height(of: Text("No recent actions").textRole(.subheadline), size: .large)
        let nameLine = try height(of: Text("No recent actions").textRole(.name), size: .large)
        XCTAssertLessThan(subheadlineLine, nameLine)
        XCTAssertEqual(notice, 1 + BillboardStyle.Space.l + stamp + BillboardStyle.Space.s + subheadlineLine + BillboardStyle.Space.xs, accuracy: 2)
    }

    /// Every notice in the app as its screen uses it (the same title, message and action), on paper in the list
    /// gutter: the Bills tab and Search; the bill page, Profile and Updates; Congress. At AX5 the COULDN'T LOAD
    /// stamp of a notice with an action wraps to two lines, and its box grows with it
    /// (`testAStampWithAnActionHoldsItsWrappedWordsAtAX5`).
    func testEveryRecordNoticeUseRenders() throws {
        let failedSearch = BillsSearch.Coverage.failed(message: "Can't reach Billboard right now. Check your connection and try again.")
        let words = try XCTUnwrap(BillsSearch.Query("medicare dental"))
        let number = try XCTUnwrap(BillsSearch.Query("H.R. 99999"))
        let unreachable = "Can't reach Billboard right now. Check your connection and try again."

        let groups: [(String, [AnyView])] = [
            ("bills-search", [
                AnyView(BillBoardLoadErrorState(message: unreachable, isRetrying: false, onRetry: {})),
                AnyView(BillBoardCaughtUpState(windowTitle: "1 week")),
                AnyView(BillsSearchNoResults(query: words, coverage: .everyBill)),
                AnyView(BillsSearchNoResults(query: number, coverage: failedSearch)),
                AnyView(BillsSearchCoverageNotice(coverage: failedSearch) {}),
                AnyView(RecordNotice(.nothingYet, title: SkippedBillsList.emptyTitle(window: .oneWeek)))
            ] + [BillsSearchList.watching, .voted, .passed, .topics].map { list in
                AnyView(RecordNotice(.nothingYet, title: BillCollectionList.emptyTitle(for: list)))
            } + [
                AnyView(RecordNotice(
                    .couldNotLoad,
                    title: CivicRankSheetContent.failedTitle,
                    message: unreachable,
                    action: .init(title: "Try again") {}
                ))
            ]),
            ("bill-profile-updates", [
                AnyView(RecordNotice(.couldNotLoad, title: "Couldn't load this bill.", message: "Check your connection and try again.")),
                AnyView(RecordNotice(.notFound, title: BillDetailMissingBillView.notFoundTitle)),
                AnyView(RecordNotice(.couldNotLoad, title: BillStatsHeatMapSection.couldNotLoadText)),
                AnyView(RecordNotice(
                    .couldNotLoad,
                    title: CivicProfileCopy.failedTitle,
                    message: unreachable,
                    action: .init(title: "Try again") {}
                )),
                AnyView(RecordNotice(.nothingYet, title: "No recent actions")),
                AnyView(RecordNotice(.nothingYet, title: "No passed bills")),
                AnyView(RecordNotice(.nothingYet, title: "No failed bills")),
                AnyView(WeeklyDigestErrorCard(message: unreachable, isShowingPreviousBrief: false, retry: {})),
                AnyView(RecordNotice(
                    .couldNotLoad,
                    title: "Couldn't open this bill",
                    message: "Try again in a moment.",
                    action: .init(title: "Try again") {}
                ))
            ]),
            ("congress", [
                AnyView(RecordNotice(
                    .nothingYet,
                    title: YourRepresentativesContent.needsLocationText,
                    action: .init(title: "Add address") {}
                )),
                AnyView(RecordNotice(
                    .notFound,
                    title: YourRepresentativesContent.notFoundText(region: "VA-11"),
                    action: .init(title: "Check address") {}
                )),
                AnyView(RecordNotice(
                    .couldNotLoad,
                    title: "Couldn't load your representatives",
                    message: YourRepresentativesContent.unavailableText,
                    action: .init(title: "Try again") {}
                )),
                AnyView(RecordNotice(.couldNotLoad, title: "Couldn't load the members you follow", message: CongressFollowedMembersSection.unavailableText)),
                AnyView(RecordNotice(.nothingYet, title: CongressFollowedMembersSection.emptyText)),
                AnyView(RecordNotice(
                    .nothingYet,
                    title: "Add your address to see the members from your state.",
                    action: .init(title: "Add address") {}
                )),
                AnyView(RecordNotice(.notFound, title: CongressMembersDirectoryView.noMatchText)),
                AnyView(RecordNotice(.nothingYet, title: "No members available")),
                AnyView(RecordNotice(.nothingYet, title: "No members")),
                AnyView(RecordNotice(.nothingYet, title: "No topic groups")),
                AnyView(RecordNotice(.nothingYet, title: "No life areas")),
                AnyView(RecordNotice(.nothingYet, title: "No bills in this topic group")),
                AnyView(RecordNotice(
                    .couldNotLoad,
                    title: CongressLoadErrorCard.title,
                    message: unreachable,
                    action: .init(title: "Try again") {}
                )),
                AnyView(RecordNotice(
                    .couldNotLoad,
                    title: CongressMemberLoadErrorView.title,
                    message: unreachable,
                    action: .init(title: "Try again") {}
                ))
            ])
        ]

        for (name, notices) in groups {
            for variant in Self.variants {
                // Drawn in windows, as on a phone: `ImageRenderer` squashes the action capsules at AX5 and clips
                // their titles, which a window does not. A window taller than about 2,700 points draws blank, so
                // the notices go on pages of at most 1,600 measured points; each window is 400 points taller than
                // its page, for the safe area and those capsules.
                for (index, page) in try pages(of: notices, variant: variant, maxHeight: 1600).enumerated() {
                    let content = Self.noticePage(page)
                    let measured = try render(content, variant: variant)
                    XCTAssertEqual(measured.width, Int(Self.width), "\(name) \(variant.name) keeps the screen's width")
                    let image = try snapshot(
                        AnyView(content.frame(maxHeight: .infinity, alignment: .top).background(BillboardColors.background)),
                        variant: variant,
                        height: CGFloat(measured.height) + 400
                    )
                    attach(image, name: "record-notice-uses-\(name)-\(variant.name)-\(index + 1)")
                }
            }
        }
    }

    /// Each notice with an action, alone, in a window, light and dark at AX5 and at the default size (project decision
    /// of 2026-10-29). At AX5 COULDN'T LOAD wraps to two lines, and its box used to stay one line tall, the words
    /// over its rules (Civic Profile, Civic Rank, Weekly Brief, Couldn't open this bill, Search, Your
    /// representatives, Congress and a member page). Now every pixel in the stamp's colour lies between the box's
    /// top and bottom rules. At the default size the box is still its one-line 20 pt. The NOTHING YET and NOT FOUND
    /// notices with an action are drawn too, for review: their dim ink is too close to the message's for this
    /// pixel check.
    func testAStampWithAnActionHoldsItsWrappedWordsAtAX5() throws {
        let unreachable = "Can't reach Billboard right now. Check your connection and try again."
        func tryAgain(_ title: String = "Try again") -> RecordNotice.Action { .init(title: title) {} }
        let notices: [(String, StatusStamp.Kind, AnyView)] = [
            ("civic-profile", .couldNotLoad, AnyView(RecordNotice(.couldNotLoad, title: CivicProfileCopy.failedTitle, message: unreachable, action: tryAgain()))),
            ("civic-rank", .couldNotLoad, AnyView(RecordNotice(.couldNotLoad, title: CivicRankSheetContent.failedTitle, message: unreachable, action: tryAgain()))),
            ("weekly-brief", .couldNotLoad, AnyView(WeeklyDigestErrorCard(message: unreachable, isShowingPreviousBrief: false, retry: {}))),
            ("couldnt-open-this-bill", .couldNotLoad, AnyView(RecordNotice(.couldNotLoad, title: "Couldn't open this bill", message: "Try again in a moment.", action: tryAgain()))),
            ("search-every-bill", .couldNotLoad, AnyView(BillsSearchCoverageNotice(coverage: .failed(message: unreachable)) {})),
            ("representatives-unavailable", .couldNotLoad, AnyView(RecordNotice(.couldNotLoad, title: "Couldn't load your representatives", message: YourRepresentativesContent.unavailableText, action: tryAgain()))),
            ("congress-load-error", .couldNotLoad, AnyView(CongressLoadErrorCard(message: unreachable, onRetry: {}))),
            ("member-load-error", .couldNotLoad, AnyView(RecordNotice(.couldNotLoad, title: CongressMemberLoadErrorView.title, message: unreachable, action: tryAgain()))),
            ("representatives-add-address", .nothingYet, AnyView(RecordNotice(.nothingYet, title: YourRepresentativesContent.needsLocationText, action: tryAgain("Add address")))),
            ("representatives-check-address", .notFound, AnyView(RecordNotice(.notFound, title: YourRepresentativesContent.notFoundText(region: "VA-11"), action: tryAgain("Check address")))),
            ("congress-add-address", .nothingYet, AnyView(RecordNotice(.nothingYet, title: "Add your address to see the members from your state.", action: tryAgain("Add address"))))
        ]
        let sizes = [
            Variant(scheme: .light, size: .accessibility5), Variant(scheme: .dark, size: .accessibility5),
            Variant(scheme: .light, size: .large), Variant(scheme: .dark, size: .large)
        ]
        for (name, stamp, notice) in notices {
            for variant in sizes {
                let page = Self.noticePage([notice])
                let measured = try render(page, variant: variant)
                let image = try snapshot(
                    AnyView(page.frame(maxHeight: .infinity, alignment: .top).background(BillboardColors.background)),
                    variant: variant,
                    height: CGFloat(measured.height) + 400
                )
                attach(image, name: "notice-with-action-\(name)-\(variant.name)")
                guard stamp == .couldNotLoad else { continue }

                let box = try StampBox(
                    in: image,
                    ink: stamp.paletteToken.resolved(dark: variant.scheme == .dark),
                    paper: BillboardPalette.background.resolved(dark: variant.scheme == .dark)
                )
                XCTAssertGreaterThan(box.height, 10, "\(name) \(variant.name): the stamp's rules were found")
                XCTAssertEqual(box.inkOutside, 0, "\(name) \(variant.name): the stamp's words cross its rules (\(box))")
                if variant.size == .large {
                    XCTAssertEqual(box.height, 20, accuracy: 1.5, "\(name) \(variant.name): one line, as before")
                }
            }
        }
    }

    /// Notices as a screen stacks them, on paper in the list gutter.
    private static func noticePage(_ notices: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(notices.indices, id: \.self) { notices[$0] }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `notices` in order, split into pages whose measured height stays under `maxHeight` (a single taller notice
    /// gets a page of its own).
    private func pages(of notices: [AnyView], variant: Variant, maxHeight: Int) throws -> [[AnyView]] {
        var pages: [[AnyView]] = []
        var page: [AnyView] = []
        for notice in notices {
            let candidate = page + [notice]
            if !page.isEmpty, try render(Self.noticePage(candidate), variant: variant).height > maxHeight {
                pages.append(page)
                page = [notice]
            } else {
                page = candidate
            }
        }
        if !page.isEmpty { pages.append(page) }
        return pages
    }

    // MARK: - The empty Updates tab (N2, N10)

    /// Updates for someone who follows nothing, once this week's check found no brief: one quiet line on how to
    /// get a Weekly Brief (no "Building your Weekly Brief" slip), then the three sections' NOTHING YET notices
    /// with quieter titles. Before the check finishes, no line: the server may still send them a brief from bills
    /// they voted on. The real `NotificationsView`, hosted in a window, not active, so it loads nothing itself.
    func testTheEmptyUpdatesTabSaysHowToGetABrief() throws {
        let followsNothing = UserProfile.placeholder().updating(id: "quiet-\(UUID().uuidString)")

        let (unchecked, uncheckedStore) = try updatesTab(profile: followsNothing)
        XCTAssertFalse(uncheckedStore.foundNoBriefThisWeek, "precondition: not checked yet")
        let beforeHost = AccessibilityTreeText.Host(unchecked, size: CGSize(width: Self.width, height: 1400), settle: 0.3)
        let before = beforeHost.text()
        beforeHost.close()
        XCTAssertFalse(before.contains(NotificationsView.weeklyBriefHowToGetOne), before)
        XCTAssertFalse(before.contains("Building your Weekly Brief"), before)

        for variant in Self.variants {
            let image = try snapshot(try checkedUpdatesTab(profile: followsNothing), variant: variant, height: variant.size == .large ? 844 : 2200)
            attach(image, name: "updates-empty-follows-nothing-\(variant.name)")
            try assertPaper(image, variant: variant)
            try assertInk(image, variant: variant)
        }

        let host = AccessibilityTreeText.Host(try checkedUpdatesTab(profile: followsNothing), size: CGSize(width: Self.width, height: 1400), settle: 0.3)
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(NotificationsView.weeklyBriefHowToGetOne), text)
        XCTAssertFalse(text.contains("Building your Weekly Brief"), text)
        XCTAssertTrue(host.identifiers().contains("updates.weeklyBrief.howToGetOne"))
        for title in ["No recent actions", "No passed bills", "No failed bills"] {
            XCTAssertTrue(text.contains("Nothing yet. \(title)."), "\(title): \(text)")
        }
    }

    /// Someone who follows a topic and has no brief this week (none loading) sees no line and no slip: the brief
    /// can come, and the slip shows only while it loads.
    func testTheUpdatesTabStaysQuietForAFollowerWithNoBriefYet() throws {
        let follower = UserProfile.placeholder().updating(id: "quiet-\(UUID().uuidString)", subscribedSubCategories: ["Energy"])
        let host = AccessibilityTreeText.Host(try checkedUpdatesTab(profile: follower), size: CGSize(width: Self.width, height: 1400), settle: 0.3)
        defer { host.close() }
        let text = host.text()
        XCTAssertFalse(text.contains(NotificationsView.weeklyBriefHowToGetOne), text)
        XCTAssertFalse(text.contains("Building your Weekly Brief"), text)
        XCTAssertTrue(text.contains("Nothing yet. No recent actions."), text)
    }

    /// Someone who follows nothing but has voted (decided 2026-10-29): billboard-backend's brief lists a bill
    /// they voted on that was updated that week (weeklyDigestBuilder's "voted_updated"), so while this week's brief
    /// loads Updates shows the existing "Building your Weekly Brief" slip, as it does for a follower. Someone who
    /// follows nothing and never voted still sees nothing while it loads. VoiceOver reads the slip as one element.
    /// Drawn in a window, light and dark at the default size, AX3 and AX5.
    func testTheBriefSlipShowsWhileItLoadsForAVoterWhoFollowsNothing() throws {
        let followsNothing = UserProfile.placeholder().updating(id: "quiet-\(UUID().uuidString)")
        for (name, votes) in [("voter", 3), ("never-voted", 0)] {
            let (view, digestStore) = try updatesTab(profile: followsNothing, civicScore: Self.score(totalVotes: votes), digestService: WaitingWeeklyDigestService())
            let loading = Task { @MainActor in await digestStore.refresh(profile: followsNothing) }
            defer { loading.cancel() }
            let started = expectation(description: "the brief is loading")
            Task { @MainActor in
                while !digestStore.isLoading { await Task.yield() }
                started.fulfill()
            }
            wait(for: [started], timeout: 5)

            if votes > 0 {
                for variant in Self.variants + [Variant(scheme: .light, size: .accessibility3)] {
                    let image = try snapshot(view, variant: variant, height: variant.size == .large ? 844 : 2200)
                    attach(image, name: "updates-brief-loading-\(name)-follows-nothing-\(variant.name)")
                    try assertPaper(image, variant: variant)
                }
            }

            let host = AccessibilityTreeText.Host(view, size: CGSize(width: Self.width, height: 1400), settle: 0.3)
            let text = host.text()
            let slip = host.elements().map(\.label).filter { $0.contains("Building your Weekly Brief") }
            host.close()
            XCTAssertTrue(digestStore.isLoading, "\(name): still loading")
            if votes > 0 {
                XCTAssertEqual(slip.count, 1, "\(name): one element: \(text)")
                XCTAssertTrue(slip[0].contains("Summarizing last week for you."), slip[0])
            } else {
                XCTAssertTrue(slip.isEmpty, "\(name): \(text)")
            }
            XCTAssertFalse(text.contains(NotificationsView.weeklyBriefHowToGetOne), "\(name): \(text)")
        }
    }

    // MARK: - Startup failure (N10)

    /// Plain words and no Try again (project decision of 2026-10-29: with amplify-swift 2.x a second configure in the
    /// same launch cannot succeed); never the framework's error ("AmplifyError: configuration file not found"),
    /// which goes to the log only. The address is a mail link. Drawn in a window, light and dark at the default
    /// size, AX3 and AX5; at AX5 on a small phone the screen scrolls rather than cut off the address. This test
    /// changed with that decision: it pinned the Try again button and its action.
    func testTheStartupFailureScreenSaysWhatToDoWithoutTryAgainOrAnError() throws {
        for variant in Self.variants + [Variant(scheme: .light, size: .accessibility3)] {
            let image = try snapshot(AnyView(StartupFailureView()), variant: variant, height: 844)
            attach(image, name: "startup-failure-\(variant.name)")
            XCTAssertEqual(Int(image.size.width), Int(Self.width))
        }

        // At AX5 on an iPhone SE's height, every word is still there to scroll to.
        let large = AccessibilityTreeText.Host(
            StartupFailureView().environment(\.dynamicTypeSize, .accessibility5),
            size: CGSize(width: 375, height: 667)
        )
        defer { large.close() }
        XCTAssertTrue(large.text().contains(StartupFailureView.message), large.text())

        let host = AccessibilityTreeText.Host(StartupFailureView(), size: CGSize(width: Self.width, height: 844))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Billboard can't start"), text)
        XCTAssertTrue(text.contains(StartupFailureView.message), text)
        XCTAssertFalse(text.contains("Error"), "no framework error on screen: \(text)")
        XCTAssertFalse(text.contains("Try again"), "no Try again: \(text)")
        XCTAssertFalse(host.identifiers().contains("startupFailure.retry"), "\(host.identifiers())")
        XCTAssertTrue(host.identifiers().contains("startupFailure.message"), "\(host.identifiers())")
    }

    /// A configure that throws is reported (and logged), never shown.
    func testStartupConfigurationReportsWhetherItWorked() {
        struct ConfigurationFailed: Error {}
        XCTAssertTrue(StartupConfiguration.attempt {})
        XCTAssertFalse(StartupConfiguration.attempt { throw ConfigurationFailed() })
    }

    // MARK: - Helpers

    /// The Updates tab with empty stores and `profile`, hydrated from the profile cache as at launch, and its
    /// Weekly Brief store, not refreshed yet. `civicScore` is the person's Civic Score as read from the server; nil
    /// leaves it not loaded.
    private func updatesTab(
        profile: UserProfile,
        civicScore: CivicScore? = nil,
        digestService: (any WeeklyDigestServicing)? = nil
    ) throws -> (AnyView, WeeklyDigestStore) {
        let scope = "quiet-states-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: scope))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: scope) }
        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)

        UserProfileDiskCache.store(try JSONEncoder().encode(profile), userId: profile.id)
        addTeardownBlock { @MainActor in UserStore.clearCachedProfile(userId: profile.id) }
        let userStore = UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService())
        userStore.hydrateCachedProfileIfAvailable(userId: profile.id)
        XCTAssertEqual(userStore.profile.id, profile.id)

        let digestStore = WeeklyDigestStore(
            scope: scope,
            defaults: defaults,
            digestService: digestService ?? EmptyWeeklyDigestService(),
            billsService: FakeBillsService(),
            votesService: FakeBillVotesService(),
            congressService: FakeCongressService()
        )
        XCTAssertNil(digestStore.digest)
        let civicService = FakeCivicService()
        let civicScoreStore = CivicScoreStore(scope: scope, userDefaults: defaults, service: civicService)
        if let civicScore {
            civicService.scoreResult = .success(civicScore)
            let read = expectation(description: "the Civic Score is read")
            Task { @MainActor in
                await civicScoreStore.refresh()
                read.fulfill()
            }
            wait(for: [read], timeout: 5)
            XCTAssertEqual(civicScoreStore.phase, .loaded)
        }
        let billsStore = BillsStore(bills: [], cacheScope: scope, service: FakeBillsService(), preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        let view = AnyView(
            NavigationStack { NotificationsView(isActive: false) }
                .environmentObject(BillAlertsStore(alerts: []))
                .environmentObject(billsStore)
                .environmentObject(AppReadState(scope: .user(scope), store: InMemoryReadStateStore()))
                .environmentObject(AppState())
                .environmentObject(userStore)
                .environmentObject(civicScoreStore)
                .environmentObject(voteStore)
                .environmentObject(digestStore)
        )
        return (view, digestStore)
    }

    /// `updatesTab` once this week's Weekly Brief check has run: the server has no brief for `profile`, and the
    /// device builds none (no bills changed).
    private func checkedUpdatesTab(profile: UserProfile) throws -> AnyView {
        let (view, digestStore) = try updatesTab(profile: profile)
        let checked = expectation(description: "this week's brief checked")
        Task { @MainActor in
            await digestStore.refresh(profile: profile)
            checked.fulfill()
        }
        wait(for: [checked], timeout: 10)
        XCTAssertNil(digestStore.digest)
        XCTAssertNil(digestStore.errorMessage)
        XCTAssertTrue(digestStore.foundNoBriefThisWeek)
        return view
    }


    private func height<Content: View>(of view: Content, size: DynamicTypeSize) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, size)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        return CGFloat(image.height)
    }

    private func render<Content: View>(_ view: Content, variant: Variant) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.width)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

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

    /// The view in a window on the test host's screen, drawn after it settles (lists draw only in a window), with the
    /// text size set on the host as Settings sets it.
    private func snapshot(_ view: AnyView, variant: Variant, height: CGFloat) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: Self.width, height: height))
        window.overrideUserInterfaceStyle = variant.style
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        host.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(variant.size)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The screen's left margin, below the bar, is paper in the variant's appearance.
    private func assertPaper(_ image: UIImage, variant: Variant, file: StaticString = #filePath, line: UInt = #line) throws {
        let paper = variant.scheme == .dark ? BillboardPalette.background.dark : BillboardPalette.background.light
        let margin = try SnapshotPixels.column(of: image, x: 4)
        XCTAssertTrue(
            margin.dropFirst(200).prefix(200).contains { SnapshotPixels.matches($0, paper, tolerance: 0.02) },
            "\(variant.name): paper in the margin",
            file: file,
            line: line
        )
    }

    /// The screen shows text in the variant's ink below the bar: not a blank page.
    private func assertInk(_ image: UIImage, variant: Variant, file: StaticString = #filePath, line: UInt = #line) throws {
        let ink = variant.scheme == .dark ? BillboardPalette.primaryText.dark : BillboardPalette.primaryText.light
        XCTAssertTrue(
            try SnapshotPixels.contains(image, ink, tolerance: 0.04, fromY: 140),
            "\(variant.name): ink below the bar",
            file: file,
            line: line
        )
    }

    private func attach(_ image: CGImage, name: String) {
        attach(UIImage(cgImage: image), name: name)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A stamp's box in a drawn notice, from the pixels in its colour: its top and bottom rules are the rows where that
/// colour runs at least 40 points unbroken (a letter never does), and `inkOutside` counts the pixels in that colour
/// above the top rule or below the bottom one, which are the stamp's words spilling over its box.
private struct StampBox: CustomStringConvertible {
    let top: Int
    let bottom: Int
    let inkOutside: Int

    var height: Double { Double(bottom - top + 1) }
    var description: String { "rules at \(top) and \(bottom), \(inkOutside) pixels outside" }

    init(in image: UIImage, ink: BillboardColorToken.RGBA, paper: BillboardColorToken.RGBA) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")

        // A pixel is in the stamp's colour when it lies at least halfway from the paper to that colour, and close
        // to the line between them (antialiased edges blend with the paper; the ink of the title and message
        // and the capsule's rule lie off that line).
        let toInk = [ink.red - paper.red, ink.green - paper.green, ink.blue - paper.blue]
        let length = toInk.reduce(0) { $0 + $1 * $1 }
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let index = (y * width + x) * 4
            let offset = [
                Double(pixels[index]) / 255 - paper.red,
                Double(pixels[index + 1]) / 255 - paper.green,
                Double(pixels[index + 2]) / 255 - paper.blue
            ]
            let along = zip(offset, toInk).reduce(0) { $0 + $1.0 * $1.1 } / length
            let off = zip(offset, toInk).reduce(0) { $0 + pow($1.0 - along * $1.1, 2) }.squareRoot()
            return along >= 0.45 && off <= 0.12
        }

        var ruleRows: [Int] = []
        var inkRows: [Int: Int] = [:]
        for y in 0..<height {
            var run = 0
            var longest = 0
            var count = 0
            for x in 0..<width {
                if isInk(x, y) {
                    run += 1
                    count += 1
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
            if count > 0 { inkRows[y] = count }
            if longest >= 40 { ruleRows.append(y) }
        }
        let top = try XCTUnwrap(ruleRows.min(), "no rule in the stamp's colour")
        let bottom = try XCTUnwrap(ruleRows.max(), "no rule in the stamp's colour")
        self.top = top
        self.bottom = bottom
        inkOutside = inkRows.filter { $0.key < top - 1 || $0.key > bottom + 1 }.values.reduce(0, +)
    }
}

/// A published brief read that takes as long as the test needs: it ends only when its task is cancelled, so the
/// Weekly Brief store stays loading.
private struct WaitingWeeklyDigestService: WeeklyDigestServicing {
    func fetchLatest() async throws -> WeeklyDigest? {
        try await Task.sleep(for: .seconds(60))
        return nil
    }
}
