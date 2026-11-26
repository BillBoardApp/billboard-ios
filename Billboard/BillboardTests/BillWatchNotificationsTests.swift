import SwiftUI
import UserNotifications
import XCTest
@testable import Billboard

/// Watch promises "Get notified when Congress acts on it." (UX-47). Turning it on shows iOS's notification prompt when
/// the app has never asked, once; when iOS permission, Profile's Notifications switch or its Actions in Congress
/// switch is off, the Watch row's caption says so instead of making the promise, and the watch is kept either way.
@MainActor
final class BillWatchNotificationsTests: XCTestCase {
    private static let guid = "BILLS-119hr903"

    // MARK: - What the caption says

    func testTheCaptionSaysWhyAWatchCantNotify() {
        let allOn = DeviceNotificationSettings.allEnabled
        var masterOff = allOn
        masterOff.notificationsEnabled = false
        var actionsOff = allOn
        actionsOff.notifyAlert = false
        var othersOff = allOn
        othersOff.notifyNew = false
        othersOff.notifyUpdated = false
        othersOff.notifyPassed = false
        othersOff.notifyFailed = false

        let cases: [(String, UNAuthorizationStatus?, DeviceNotificationSettings, Bool, Bool, BillWatchNotificationBlock?)] = [
            ("not read yet", nil, allOn, true, false, nil),
            ("allowed", .authorized, allOn, true, true, nil),
            ("allowed, not watching", .authorized, allOn, false, false, nil),
            ("allowed quietly", .provisional, allOn, true, true, nil),
            ("other types off", .authorized, othersOff, true, true, nil),
            ("denied", .denied, allOn, true, true, .permissionOff),
            ("denied, not watching", .denied, allOn, false, false, .permissionOff),
            ("denied comes first", .denied, masterOff, true, true, .permissionOff),
            ("not asked, Watch will ask", .notDetermined, allOn, false, false, nil),
            ("not asked, watched already", .notDetermined, allOn, true, false, .permissionNotAsked),
            ("not asked, asked before", .notDetermined, allOn, false, true, .permissionNotAsked),
            ("not asked, Watch will ask, Notifications off", .notDetermined, masterOff, false, false, .notificationsOff),
            ("Notifications off", .authorized, masterOff, true, true, .notificationsOff),
            ("Actions in Congress off", .authorized, actionsOff, true, true, .actionsInCongressOff),
            ("Actions in Congress off, not watching", .authorized, actionsOff, false, true, .actionsInCongressOff)
        ]
        for (name, permission, settings, isWatching, hasAsked, expected) in cases {
            let block = BillWatchNotificationBlock.make(
                permission: permission,
                settings: settings,
                isWatching: isWatching,
                hasAskedPermission: hasAsked
            )
            XCTAssertEqual(block, expected, name)
        }
    }

    func testTheCaptionsWords() {
        XCTAssertEqual(BillWatchCopy.rowSubtitle(blockedBy: nil), "Get notified when Congress acts on it.")
        XCTAssertEqual(
            BillWatchCopy.rowSubtitle(blockedBy: .permissionOff),
            "Notifications are off in iOS Settings. Turn them on there to get notified when Congress acts on it."
        )
        XCTAssertEqual(
            BillWatchCopy.rowSubtitle(blockedBy: .permissionNotAsked),
            "Billboard needs your permission before it can send notifications. Turn them on in Profile."
        )
        XCTAssertEqual(
            BillWatchCopy.rowSubtitle(blockedBy: .notificationsOff),
            "Notifications are off in Profile. Turn them on there to get notified when Congress acts on it."
        )
        XCTAssertEqual(
            BillWatchCopy.rowSubtitle(blockedBy: .actionsInCongressOff),
            "Actions in Congress notifications are off in Profile. Turn them on there to get notified when Congress acts on it."
        )
        // The permission lines start with Profile's.
        XCTAssertTrue(NotificationsSectionModel.deniedHint.hasPrefix("Notifications are off in iOS Settings."))
        XCTAssertTrue(NotificationsSectionModel.notAskedHint.hasPrefix("Billboard needs your permission before it can send notifications."))
    }

    /// What VoiceOver hears after a toggle (UX-47, D8 (b)): turning Watch on says why it can't notify, one line per
    /// block, and nothing when nothing blocks it; turning it off is said as before, whatever blocks a watch.
    func testTheAnnouncementSaysWhyANewWatchCantNotify() {
        let expected: [(BillWatchNotificationBlock, String)] = [
            (.permissionOff, "Watching this bill. Notifications are off in iOS Settings. Turn them on there to get notified when Congress acts on it."),
            (.permissionNotAsked, "Watching this bill. Billboard needs your permission before it can send notifications. Turn them on in Profile."),
            (.notificationsOff, "Watching this bill. Notifications are off in Profile. Turn them on there to get notified when Congress acts on it."),
            (
                .actionsInCongressOff,
                "Watching this bill. Actions in Congress notifications are off in Profile. Turn them on there to get notified when Congress acts on it."
            )
        ]
        for (block, line) in expected {
            XCTAssertEqual(BillWatchCopy.announcement(isWatching: true, blockedBy: block), line, "\(block)")
            XCTAssertEqual(BillWatchCopy.announcement(isWatching: false, blockedBy: block), "Stopped watching this bill", "off, \(block)")
        }
        XCTAssertNil(BillWatchCopy.announcement(isWatching: true, blockedBy: nil), "nothing blocks it: the switch says it is on")
        XCTAssertEqual(BillWatchCopy.announcement(isWatching: false, blockedBy: nil), "Stopped watching this bill")
    }

    func testWatchAsksOnlyWhenTheAppNeverHas() {
        XCTAssertTrue(BillWatchNotificationBlock.asksPermission(permission: .notDetermined, hasAskedPermission: false))
        XCTAssertFalse(BillWatchNotificationBlock.asksPermission(permission: .notDetermined, hasAskedPermission: true), "asked once already")
        XCTAssertFalse(BillWatchNotificationBlock.asksPermission(permission: nil, hasAskedPermission: false))
        for answered in [UNAuthorizationStatus.authorized, .denied, .provisional, .ephemeral] {
            XCTAssertFalse(BillWatchNotificationBlock.asksPermission(permission: answered, hasAskedPermission: false), "\(answered.rawValue)")
        }
    }

    /// The caption reads the switches this device last saved, as Profile starts from them (UX-50).
    func testTheSavedSwitchesAreRead() throws {
        let notifications = try fakeNotifications(.authorized)
        var saved = DeviceNotificationSettings.allEnabled
        saved.notifyAlert = false
        NotificationSettingsStore.saveLocally(saved, defaults: notifications.defaults)

        let block = BillWatchNotificationBlock.make(
            permission: .authorized,
            settings: NotificationSettingsStore.savedSettings(defaults: notifications.defaults),
            isWatching: true,
            hasAskedPermission: true
        )

        XCTAssertEqual(block, .actionsInCongressOff)

        // The master switch has a key of its own, which Profile writes beside the types.
        saved.notificationsEnabled = false
        NotificationSettingsStore.saveLocally(saved, defaults: notifications.defaults)
        XCTAssertFalse(NotificationSettingsStore.savedSettings(defaults: notifications.defaults).notificationsEnabled)
        XCTAssertEqual(
            BillWatchNotificationBlock.make(
                permission: .authorized,
                settings: NotificationSettingsStore.savedSettings(defaults: notifications.defaults),
                isWatching: true,
                hasAskedPermission: true
            ),
            .notificationsOff
        )
    }

    // MARK: - The bill page

    // The page tests are not async: a hosted page needs the main run loop, which an async test holds.

    /// iOS has never asked: turning Watch on shows the prompt, once, and keeps the watch. Turning it off and on again
    /// does not ask again.
    func testTurningWatchOnAsksForNotificationsOnce() throws {
        let notifications = try fakeNotifications(.notDetermined)
        let page = billPage(watched: false, notifications: notifications)
        try APIClient.$current.withValue(Self.offlineClient()) {
            let host = AccessibilityTreeText.Host(page.view, size: CGSize(width: 390, height: 5000), settle: 0.5)
            defer { host.close() }
            let before = try XCTUnwrap(host.label(ofIdentifier: BillWatchCopy.rowIdentifier), host.text())
            XCTAssertTrue(before.contains(BillWatchCopy.rowSubtitle), "turning Watch on will ask, so the promise stands: \(before)")
            XCTAssertEqual(notifications.prompts, 0, "nothing asks before the tap")

            XCTAssertTrue(host.activate(identifier: BillWatchCopy.rowIdentifier), host.text())
            XCTAssertTrue(host.run(until: { notifications.prompts == 1 && page.preferences.putCalls.count == 1 }), host.text())

            XCTAssertTrue(notifications.defaults.bool(forKey: AppNotificationStorage.pushPermissionPromptedKey), "asked once, for good")
            XCTAssertEqual(page.user.profile.watchedBillGUIDs, [Self.guid], "the watch is kept")
            // Still not answered (the fake never answers): the caption says so.
            XCTAssertTrue(
                host.run(until: { host.label(ofIdentifier: BillWatchCopy.rowIdentifier)?.contains(BillWatchCopy.rowSubtitle(blockedBy: .permissionNotAsked)) == true }),
                host.label(ofIdentifier: BillWatchCopy.rowIdentifier) ?? host.text()
            )

            XCTAssertTrue(host.activate(identifier: BillWatchCopy.rowIdentifier), "off")
            XCTAssertTrue(host.run(until: { page.preferences.deleteCalls.count == 1 }), host.text())
            XCTAssertTrue(host.activate(identifier: BillWatchCopy.rowIdentifier), "and on again")
            XCTAssertTrue(host.run(until: { page.preferences.putCalls.count == 2 }), host.text())
            host.run(0.3)

            XCTAssertEqual(notifications.prompts, 1, "asked only once")
        }
    }

    /// Turning Watch on where the watch can't notify: once iOS's permission is read, VoiceOver hears "Watching this
    /// bill. " and the row's caption, once (D8 (b)). Nothing when nothing blocks it, and nothing while iOS's prompt is
    /// about to show (the app has never asked).
    func testTurningWatchOnSaysWhyItCantNotify() throws {
        var masterOff = DeviceNotificationSettings.allEnabled
        masterOff.notificationsEnabled = false
        var actionsOff = DeviceNotificationSettings.allEnabled
        actionsOff.notifyAlert = false
        let cases: [(String, UNAuthorizationStatus, Bool, DeviceNotificationSettings?, BillWatchNotificationBlock?)] = [
            ("iOS permission off", .denied, true, nil, .permissionOff),
            ("not asked, asked before", .notDetermined, true, nil, .permissionNotAsked),
            ("Notifications off", .authorized, true, masterOff, .notificationsOff),
            ("Actions in Congress off", .authorized, true, actionsOff, .actionsInCongressOff),
            ("allowed", .authorized, true, nil, nil),
            ("the prompt is about to show", .notDetermined, false, nil, nil)
        ]
        for (name, permission, askedBefore, saved, block) in cases {
            let notifications = try fakeNotifications(permission)
            notifications.defaults.set(askedBefore, forKey: AppNotificationStorage.pushPermissionPromptedKey)
            if let saved {
                NotificationSettingsStore.saveLocally(saved, defaults: notifications.defaults)
            }
            let page = billPage(watched: false, notifications: notifications)
            let spoken = SpokenLines()
            try APIClient.$current.withValue(Self.offlineClient()) {
                let host = AccessibilityTreeText.Host(
                    recording(page.view, spoken),
                    size: CGSize(width: 390, height: 5000),
                    settle: 0.5
                )
                defer { host.close() }
                XCTAssertEqual(spoken.lines, [], "\(name): nothing before the tap")

                XCTAssertTrue(host.activate(identifier: BillWatchCopy.rowIdentifier), "\(name): \(host.text())")
                XCTAssertTrue(host.run(until: { page.preferences.putCalls.count == 1 }), "\(name): \(host.text())")
                host.run(0.3)

                let expected = try block.map { [try XCTUnwrap(BillWatchCopy.announcement(isWatching: true, blockedBy: $0))] } ?? []
                XCTAssertEqual(spoken.lines, expected, name)
                XCTAssertEqual(spoken.linesNow, [], "\(name): nothing is said at once")
                XCTAssertEqual(notifications.prompts, askedBefore ? 0 : 1, "\(name): the prompt only when never asked")
                XCTAssertEqual(page.user.profile.watchedBillGUIDs, [Self.guid], "\(name): the watch is kept")
            }
        }
    }

    /// Turning Watch off is said as before ("Stopped watching this bill", at once), never with a block's words,
    /// whatever blocks a watch.
    func testTurningWatchOffSaysNoBlock() throws {
        let notifications = try fakeNotifications(.denied)
        notifications.defaults.set(true, forKey: AppNotificationStorage.pushPermissionPromptedKey)
        let page = billPage(watched: true, notifications: notifications)
        let spoken = SpokenLines()
        APIClient.$current.withValue(Self.offlineClient()) {
            let host = AccessibilityTreeText.Host(
                recording(page.view, spoken),
                size: CGSize(width: 390, height: 5000),
                settle: 0.5
            )
            defer { host.close() }
            XCTAssertTrue(host.activate(identifier: BillWatchCopy.rowIdentifier), host.text())
            XCTAssertTrue(host.run(until: { page.preferences.deleteCalls.count == 1 }), host.text())
            host.run(0.3)

            XCTAssertEqual(spoken.linesNow, ["Stopped watching this bill"], "the stop is said at once, as before")
            XCTAssertEqual(spoken.lines, [], "no block's words after a stop")
            XCTAssertEqual(page.user.profile.watchedBillGUIDs, [])
        }
    }

    /// A watch whose save fails before iOS's permission is read (offline): the stores put the watch back and the
    /// Watch row says so (UX-48), and VoiceOver hears only that, never "Watching this bill. " with a block's words.
    func testAFailedWatchSaysNoBlock() throws {
        let notifications = try fakeNotifications(.denied)
        notifications.defaults.set(true, forKey: AppNotificationStorage.pushPermissionPromptedKey)
        let page = billPage(watched: false, notifications: notifications)
        page.preferences.putError = URLError(.notConnectedToInternet)
        let spoken = SpokenLines()
        try APIClient.$current.withValue(Self.offlineClient()) {
            let host = AccessibilityTreeText.Host(recording(page.view, spoken), size: CGSize(width: 390, height: 5000), settle: 0.5)
            defer { host.close() }
            // The page has read the permission once; the next read, after the tap, comes after the failure.
            notifications.permissionDelay = .milliseconds(600)
            let failure = BillWatchCopy.saveFailedText(isWatching: true)

            XCTAssertTrue(host.activate(identifier: BillWatchCopy.rowIdentifier), host.text())
            XCTAssertTrue(host.run(until: { host.label(ofIdentifier: BillWatchCopy.errorIdentifier) != nil }), host.text())
            XCTAssertEqual(try XCTUnwrap(host.label(ofIdentifier: BillWatchCopy.errorIdentifier)), failure)
            host.run(1)

            XCTAssertEqual(spoken.lines, [failure], "the failure only")
            XCTAssertEqual(spoken.linesNow, [])
            XCTAssertEqual(page.user.profile.watchedBillGUIDs, [], "the watch was put back")
        }
    }

    /// A watched bill whose watch can't notify on this device: the Watch row's caption says why, and the watch stays.
    func testTheWatchRowSaysWhenNotificationsAreOff() throws {
        var masterOff = DeviceNotificationSettings.allEnabled
        masterOff.notificationsEnabled = false
        var actionsOff = DeviceNotificationSettings.allEnabled
        actionsOff.notifyAlert = false
        let cases: [(String, UNAuthorizationStatus, DeviceNotificationSettings?, BillWatchNotificationBlock?)] = [
            ("iOS permission off", .denied, nil, .permissionOff),
            ("Notifications off", .authorized, masterOff, .notificationsOff),
            ("Actions in Congress off", .authorized, actionsOff, .actionsInCongressOff),
            ("allowed", .authorized, nil, nil)
        ]
        for (name, permission, saved, block) in cases {
            let notifications = try fakeNotifications(permission)
            notifications.defaults.set(true, forKey: AppNotificationStorage.pushPermissionPromptedKey)
            if let saved {
                NotificationSettingsStore.saveLocally(saved, defaults: notifications.defaults)
            }
            let page = billPage(watched: true, notifications: notifications)
            APIClient.$current.withValue(Self.offlineClient()) {
                let host = AccessibilityTreeText.Host(page.view, size: CGSize(width: 390, height: 5000), settle: 0.5)
                defer { host.close() }
                let caption = BillWatchCopy.rowSubtitle(blockedBy: block)

                XCTAssertTrue(
                    host.run(until: { host.label(ofIdentifier: BillWatchCopy.rowIdentifier)?.contains(caption) == true }),
                    "\(name): \(host.label(ofIdentifier: BillWatchCopy.rowIdentifier) ?? host.text())"
                )
                XCTAssertEqual(notifications.prompts, 0, "\(name): nothing asks")
                XCTAssertEqual(page.preferences.deleteCalls.count, 0, "\(name): the watch stays")
            }
        }
    }

    // MARK: - Helpers

    /// The lines the page said to VoiceOver: queued (`announceToVoiceOver`) and at once (`announceToVoiceOverNow`).
    @MainActor
    private final class SpokenLines {
        private(set) var lines: [String] = []
        private(set) var linesNow: [String] = []

        var announce: @MainActor @Sendable (String) -> Void {
            { [self] line in lines.append(line) }
        }

        var announceNow: @MainActor @Sendable (String) -> Void {
            { [self] line in linesNow.append(line) }
        }
    }

    /// `view` with both of VoiceOver's announcement paths recorded by `spoken`.
    private func recording(_ view: AnyView, _ spoken: SpokenLines) -> some View {
        view
            .environment(\.announceToVoiceOver, spoken.announce)
            .environment(\.announceToVoiceOverNow, spoken.announceNow)
    }

    /// iOS permission and the device's saved switches for the page, on a defaults suite of its own, and the prompts
    /// it was asked to show.
    @MainActor
    private final class FakeNotifications {
        var permission: UNAuthorizationStatus
        /// How long reading the permission takes.
        var permissionDelay: Duration = .zero
        let defaults: UserDefaults
        private(set) var prompts = 0

        init(permission: UNAuthorizationStatus, defaults: UserDefaults) {
            self.permission = permission
            self.defaults = defaults
        }

        var access: WatchNotificationAccess {
            WatchNotificationAccess(
                permission: { [self] in
                    if permissionDelay > .zero {
                        try? await Task.sleep(for: permissionDelay)
                    }
                    return permission
                },
                defaults: defaults,
                showPrompt: { [self] in prompts += 1 }
            )
        }
    }

    /// Fake notifications on a new defaults suite, removed in teardown.
    private func fakeNotifications(_ permission: UNAuthorizationStatus) throws -> FakeNotifications {
        let suiteName = "watch-notifications-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return FakeNotifications(permission: permission, defaults: defaults)
    }

    /// The pages' own requests (the vote, the member) fail as offline.
    private static func offlineClient() -> APIClient {
        APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
    }

    private struct BillPage {
        let view: AnyView
        let user: UserStore
        let preferences: FakePreferencesService
    }

    /// A bill page for one bill, watched or not, its stores on fakes and a signed-in user who may write.
    private func billPage(watched: Bool, notifications: FakeNotifications) -> BillPage {
        let preferences = FakePreferencesService()
        preferences.preferences = PreferencesMutations.watchItems(for: watched ? [Self.guid] : [])
        let user = signedInUserNow(preferences)
        // A bill the page shows without fetching it (it has its text's link).
        let bill = Bill(
            id: UUID.deterministic(from: Self.guid),
            title: "Bill \(Self.guid)",
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            link: "https://www.govinfo.gov/app/details/BILLS-119hr903ih",
            billStatus: .new,
            guid: Self.guid,
            userVoted: false,
            userWatched: watched
        )
        let scope = "watch-notifications-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedManifest = []
        let billsStore = BillsStore(bills: [bill], cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        billsStore.connect(userStore: user)
        // The bills store holds both stores weakly; keep them for the whole test.
        addTeardownBlock { withExtendedLifetime((voteStore, user, notifications)) {} }
        let view = NavigationStack { BillDetail(billID: bill.id) }
            .environment(\.watchNotificationAccess, notifications.access)
            .environmentObject(billsStore)
            .environmentObject(voteStore)
            .environmentObject(AppReadState(scope: .user("watch-notifications-tests"), store: InMemoryReadStateStore()))
            .environmentObject(user)
            .environmentObject(CongressMembersManifestStore(service: FakeCongressService()))
        return BillPage(view: AnyView(view), user: user, preferences: preferences)
    }

    /// A signed-in user store on `preferences` whose account may write (an attested adult), with the profile loaded
    /// on the main run loop. Its cached profile is removed in teardown.
    private func signedInUserNow(_ preferences: FakePreferencesService) -> UserStore {
        let userId = "watch-notifications-tests-\(UUID().uuidString)"
        addTeardownBlock { @MainActor in
            UserStore.clearCachedProfile(userId: userId)
            UserDefaults.standard.removeObject(forKey: "\(AccountComplianceStorage.cachedAdultStatusKeyPrefix)\(userId)")
        }
        let user = UserStore(preferencesService: preferences, congressService: FakeCongressService())
        let me = Data(#"{"userId":"\#(userId)","adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#.utf8)
        let transport = RecordingTransport()
        transport.responses = [me, me]
        APIClient.$current.withValue(transport.client) {
            Task { await user.refresh(userId: userId, attributes: []) }
        }
        let deadline = Date().addingTimeInterval(5)
        while !user.hasRefreshedOnce, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(user.hasRefreshedOnce, "precondition: the profile loaded")
        XCTAssertTrue(user.canPerformUserWrites, "precondition: the user may write")
        return user
    }
}
