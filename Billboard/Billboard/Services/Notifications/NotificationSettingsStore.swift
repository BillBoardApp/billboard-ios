import Foundation
import Combine

@MainActor
final class NotificationSettingsStore: ObservableObject {
    /// Shown when the server's copy could not be read (Profile can be pulled down to load again).
    static let loadFailedMessage = "Couldn't load your notification settings. Pull down to try again."
    /// Shown when a change could not be saved; the switch goes back to its previous position.
    static let saveFailedMessage = "Couldn't save that change. Check your connection and try again."

    @Published private(set) var settings: DeviceNotificationSettings = .allEnabled
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isSaving: Bool = false
    @Published var errorMessage: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings.notificationsEnabled = defaults.object(forKey: AppNotificationStorage.notificationsEnabledKey) as? Bool ?? true
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let deviceID = DeviceIdStore.getOrCreate()
        do {
            var loaded = try await DeviceNotificationSettingsService.fetchSettings(deviceID: deviceID)
            loaded.deviceID = deviceID
            settings = loaded
            persistLocalSettings(loaded)
        } catch {
            // Leaving the screen mid-load is not a failure (APPF-22).
            if APIErrorResponse.isCancellation(error) { return }
            // Keep local state as fallback when the backend is unreachable.
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
            var saved = try await DeviceNotificationSettingsService.updateSettings(next)
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
}
