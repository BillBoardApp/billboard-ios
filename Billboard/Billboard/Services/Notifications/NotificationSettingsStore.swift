import Foundation
import Combine

@MainActor
final class NotificationSettingsStore: ObservableObject {
    /// Shown when the server's copy could not be read (Profile can be pulled down to load again).
    static let loadFailedMessage = "Couldn't load your notification settings. Pull down to try again."
    /// Shown when a change could not be saved; the switch goes back to its previous position.
    static let saveFailedMessage = "Couldn't save that change. Check your connection and try again."

    @Published private(set) var settings: DeviceNotificationSettings
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isSaving: Bool = false
    @Published var errorMessage: String?
    /// The server's copy has loaded at least once (UX-50). Until then `settings` is the copy this device last
    /// saved, which may be out of date, and the switches stay off limits: any change saves all six values.
    @Published private(set) var hasLoadedServerCopy: Bool = false

    private let defaults: UserDefaults
    private let service: any DeviceNotificationSettingsServicing

    init(
        defaults: UserDefaults = .standard,
        service: any DeviceNotificationSettingsServicing = DeviceNotificationSettingsService.Live()
    ) {
        self.defaults = defaults
        self.service = service
        self.settings = Self.savedSettings(defaults: defaults)
    }

    /// The settings as this device last saved them (UX-50): the master switch from its own key, and the five types
    /// from the snapshot `persistLocalSettings` keeps. Every switch is on when nothing is saved yet. The bill page's
    /// Watch row reads them too (UX-47).
    static func savedSettings(defaults: UserDefaults) -> DeviceNotificationSettings {
        var settings = DeviceNotificationSettings.allEnabled
        if let saved = PushPresentationSettings.load(defaults: defaults) {
            settings.notifyNew = saved.notifyNew
            settings.notifyUpdated = saved.notifyUpdated
            settings.notifyAlert = saved.notifyAlert
            settings.notifyPassed = saved.notifyPassed
            settings.notifyFailed = saved.notifyFailed
        }
        settings.notificationsEnabled = defaults.object(forKey: AppNotificationStorage.notificationsEnabledKey) as? Bool ?? true
        return settings
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let deviceID = DeviceIdStore.getOrCreate()
        do {
            var loaded = try await service.fetchSettings(deviceID: deviceID)
            loaded.deviceID = deviceID
            settings = loaded
            hasLoadedServerCopy = true
            persistLocalSettings(loaded)
        } catch {
            // Leaving the screen mid-load is not a failure (APPF-22).
            if APIErrorResponse.isCancellation(error) { return }
            // Keep the copy on screen. Until one load has worked, the switches stay off limits (UX-50).
            errorMessage = Self.loadFailedMessage
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        await persistChange { next in
            next.notificationsEnabled = enabled
        }
    }

    func setNotifyNew(_ enabled: Bool) async {
        await persistChange { next in
            next.notifyNew = enabled
        }
    }

    func setNotifyUpdated(_ enabled: Bool) async {
        await persistChange { next in
            next.notifyUpdated = enabled
        }
    }

    func setNotifyAlert(_ enabled: Bool) async {
        await persistChange { next in
            next.notifyAlert = enabled
        }
    }

    func setNotifyPassed(_ enabled: Bool) async {
        await persistChange { next in
            next.notifyPassed = enabled
        }
    }

    func setNotifyFailed(_ enabled: Bool) async {
        await persistChange { next in
            next.notifyFailed = enabled
        }
    }

    private func persistChange(_ mutate: (inout DeviceNotificationSettings) -> Void) async {
        if settings.deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.deviceID = DeviceIdStore.getOrCreate()
        }

        let previous = settings
        var next = settings
        mutate(&next)

        settings = next
        persistLocalSettings(next)

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            var saved = try await service.updateSettings(next)
            saved.deviceID = settings.deviceID
            settings = saved
            persistLocalSettings(saved)
        } catch {
            settings = previous
            persistLocalSettings(previous)
            errorMessage = Self.saveFailedMessage
#if DEBUG
            print("[NotificationSettingsStore] save failed: \(APIErrorDebug.debugString(for: error))")
#endif
        }
    }

    /// Mirrors the settings locally so foreground pushes respect both the master switch
    /// and the per-type toggles (see `PushPresentationSettings`).
    private func persistLocalSettings(_ settings: DeviceNotificationSettings) {
        defaults.set(settings.notificationsEnabled, forKey: AppNotificationStorage.notificationsEnabledKey)
        PushPresentationSettings.save(settings, defaults: defaults)
    }

    /// Sign-out: forgets the switches this device saved, the master switch and the types' snapshot, so the next
    /// account to sign in here starts from every switch on (`savedSettings`), not from the last account's. The
    /// server keeps each account's own copy, which Profile loads. Profile and the bill page's Watch row read this
    /// copy until then (UX-47, UX-50).
    static func clearSavedSettings(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AppNotificationStorage.notificationsEnabledKey)
        PushPresentationSettings.clear(defaults: defaults)
    }
}
