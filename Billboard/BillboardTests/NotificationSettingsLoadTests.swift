import XCTest
@testable import Billboard

/// Profile > Notifications before the server's copy has loaded (UX-50). The switches used to start all On, and after
/// a failed load they stayed On and enabled. A flip saves all six values, so it turned back on the types the person had
/// turned off. They now start from the copy this device last saved, and stay disabled until the server's copy has
/// loaded once.
@MainActor
final class NotificationSettingsLoadTests: XCTestCase {
    private static let offline = URLError(.notConnectedToInternet)

    private let suiteName = "NotificationSettingsLoadTests.\(UUID().uuidString)"

    /// A throwaway suite, so no test touches the host app's `UserDefaults.standard`.
    private lazy var defaults: UserDefaults = {
        let suiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }()

    /// What a person who turned some types off has on this device: the master switch and the snapshot, both written
    /// by the store's last load or save.
    private func saveOnDevice(_ settings: DeviceNotificationSettings) {
        defaults.set(settings.notificationsEnabled, forKey: AppNotificationStorage.notificationsEnabledKey)
        PushPresentationSettings.save(settings, defaults: defaults)
    }

    private static var someTypesOff: DeviceNotificationSettings {
        var settings = DeviceNotificationSettings.allEnabled
        settings.notifyNew = false
        settings.notifyAlert = false
        return settings
    }

    private static func types(of settings: DeviceNotificationSettings) -> [Bool] {
        NotificationKind.allCases.map { $0.isOn(in: settings) }
    }

    // MARK: - Before any load

    func testTheSwitchesStartFromTheCopyThisDeviceSaved() {
        saveOnDevice(Self.someTypesOff)

        let store = NotificationSettingsStore(defaults: defaults, service: FakeDeviceNotificationSettingsService())

        XCTAssertTrue(store.settings.notificationsEnabled)
        XCTAssertEqual(Self.types(of: store.settings), [false, true, false, true, true], "New bills and Actions in Congress stay off")
        XCTAssertFalse(store.hasLoadedServerCopy)
    }

    func testWithNothingSavedEveryTypeStartsOn() {
        let store = NotificationSettingsStore(defaults: defaults, service: FakeDeviceNotificationSettingsService())
        XCTAssertEqual(store.settings, .allEnabled)

        defaults.set(false, forKey: AppNotificationStorage.notificationsEnabledKey)
        let masterOff = NotificationSettingsStore(defaults: defaults, service: FakeDeviceNotificationSettingsService())
        XCTAssertFalse(masterOff.settings.notificationsEnabled, "the master switch still comes from its own key")
        XCTAssertEqual(Self.types(of: masterOff.settings), [true, true, true, true, true])
    }

    // MARK: - Sign-out

    /// Sign-out forgets the switches this device saved, the master switch too. The next account to sign in here then
    /// starts from every switch on, and its bill pages' Watch row makes its promise, instead of reading the last
    /// account's "Notifications are off in Profile." The server keeps each account's own copy, which Profile loads.
    func testSignOutForgetsTheSavedSwitchesForTheNextAccount() {
        var saved = Self.someTypesOff
        saved.notificationsEnabled = false
        saveOnDevice(saved)
        let before = NotificationSettingsStore.savedSettings(defaults: defaults)
        XCTAssertFalse(before.notificationsEnabled, "precondition: the last account turned Notifications off")
        XCTAssertEqual(
            BillWatchNotificationBlock.make(permission: .authorized, settings: before, isWatching: true, hasAskedPermission: true),
            .notificationsOff
        )

        NotificationSettingsStore.clearSavedSettings(defaults: defaults)

        let after = NotificationSettingsStore.savedSettings(defaults: defaults)
        XCTAssertEqual(after, .allEnabled)
        XCTAssertNil(defaults.object(forKey: AppNotificationStorage.notificationsEnabledKey))
        XCTAssertNil(PushPresentationSettings.load(defaults: defaults))
        XCTAssertNil(
            BillWatchNotificationBlock.make(permission: .authorized, settings: after, isWatching: true, hasAskedPermission: true),
            "the Watch row makes its promise"
        )
        XCTAssertEqual(NotificationSettingsStore(defaults: defaults, service: FakeDeviceNotificationSettingsService()).settings, .allEnabled)
    }

    // MARK: - A failed load

    func testAFailedLoadKeepsTheSavedCopyAndEverySwitchDisabled() async {
        saveOnDevice(Self.someTypesOff)
        let service = FakeDeviceNotificationSettingsService()
        service.fetchResult = .failure(Self.offline)
        let store = NotificationSettingsStore(defaults: defaults, service: service)

        await store.load()

        XCTAssertEqual(store.errorMessage, NotificationSettingsStore.loadFailedMessage, "Pull down to try again")
        XCTAssertEqual(Self.types(of: store.settings), [false, true, false, true, true])
        XCTAssertFalse(store.hasLoadedServerCopy)

        let model = NotificationsSectionModel(permission: .authorized, store: store)
        XCTAssertFalse(model.isBusy, "the load has ended")
        XCTAssertTrue(model.isMasterOn, "the switch shows the saved value")
        XCTAssertTrue(model.isMasterDisabled)
        XCTAssertTrue(model.areKindTogglesDisabled)
        XCTAssertTrue(service.updateCalls.isEmpty)
    }

    /// "Turn on notifications" saves the master switch without going through the switches. Before the server's copy
    /// loads it sends the saved types, not every type On.
    func testAChangeBeforeTheFirstLoadSendsTheSavedTypes() async throws {
        var saved = Self.someTypesOff
        saved.notificationsEnabled = false
        saveOnDevice(saved)
        let service = FakeDeviceNotificationSettingsService()
        service.fetchResult = .failure(Self.offline)
        let store = NotificationSettingsStore(defaults: defaults, service: service)
        await store.load()

        await store.setNotificationsEnabled(true)

        let sent = try XCTUnwrap(service.updateCalls.last)
        XCTAssertTrue(sent.notificationsEnabled)
        XCTAssertEqual(Self.types(of: sent), [false, true, false, true, true])
    }

    // MARK: - A load that works

    func testALoadEnablesTheSwitchesAndALaterFailedLoadLeavesThemEnabled() async {
        saveOnDevice(Self.someTypesOff)
        var server = DeviceNotificationSettings.allEnabled
        server.notifyPassed = false
        let service = FakeDeviceNotificationSettingsService()
        service.fetchResult = .success(server)
        let store = NotificationSettingsStore(defaults: defaults, service: service)

        await store.load()

        XCTAssertTrue(store.hasLoadedServerCopy)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(Self.types(of: store.settings), [true, true, true, false, true], "the server's copy replaces the saved one")
        XCTAssertEqual(PushPresentationSettings.load(defaults: defaults)?.notifyPassed, false, "and is saved on the device")
        var model = NotificationsSectionModel(permission: .authorized, store: store)
        XCTAssertFalse(model.isMasterDisabled)
        XCTAssertFalse(model.areKindTogglesDisabled)

        service.fetchResult = .failure(Self.offline)
        await store.load()

        XCTAssertEqual(store.errorMessage, NotificationSettingsStore.loadFailedMessage)
        XCTAssertTrue(store.hasLoadedServerCopy, "the server's copy has loaded once")
        XCTAssertEqual(Self.types(of: store.settings), [true, true, true, false, true])
        model = NotificationsSectionModel(permission: .authorized, store: store)
        XCTAssertFalse(model.isMasterDisabled)
        XCTAssertFalse(model.areKindTogglesDisabled)
    }
}
