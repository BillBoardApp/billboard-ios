import Amplify
import Foundation

struct DeviceNotificationSettings: Codable, Equatable {
    var deviceID: String
    var notificationsEnabled: Bool
    var notifyNew: Bool
    var notifyUpdated: Bool
    var notifyAlert: Bool
    var notifyPassed: Bool
    var notifyFailed: Bool

    static let allEnabled = DeviceNotificationSettings(
        deviceID: "",
        notificationsEnabled: true,
        notifyNew: true,
        notifyUpdated: true,
        notifyAlert: true,
        notifyPassed: true,
        notifyFailed: true
    )

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case notificationsEnabled = "notifications_enabled"
        case notifyNew = "notify_new"
        case notifyUpdated = "notify_updated"
        case notifyAlert = "notify_alert"
        case notifyPassed = "notify_passed"
        case notifyFailed = "notify_failed"
    }
}

enum DeviceNotificationSettingsService {
    private static let path = "device-notification-settings"

    static func fetchSettings(deviceID: String) async throws -> DeviceNotificationSettings {
        let cleanedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedDeviceID.isEmpty else {
            throw APIServiceError.invalidPayload(path)
        }

        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn else {
            throw APIServiceError.notSignedIn
        }

        let data = try await APIClient.current.payload(
            .get,
            path,
            query: ["device_id": cleanedDeviceID],
            label: "DeviceNotificationSettingsService GET"
        )

        guard !data.isEmpty else {
            throw APIServiceError.invalidPayload(path)
        }

        return try APIDecoding.decode(DeviceNotificationSettings.self, from: data, decoder: .usingDefaultKeys(), label: "DeviceNotificationSettingsService GET")
    }

    static func updateSettings(_ settings: DeviceNotificationSettings) async throws -> DeviceNotificationSettings {
        let cleanedDeviceID = settings.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedDeviceID.isEmpty else {
            throw APIServiceError.invalidPayload(path)
        }

        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn else {
            throw APIServiceError.notSignedIn
        }

        let payload = DeviceNotificationSettings(
            deviceID: cleanedDeviceID,
            notificationsEnabled: settings.notificationsEnabled,
            notifyNew: settings.notifyNew,
            notifyUpdated: settings.notifyUpdated,
            notifyAlert: settings.notifyAlert,
            notifyPassed: settings.notifyPassed,
            notifyFailed: settings.notifyFailed
        )

        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(payload)

        let data = try await APIClient.current.payload(
            .put,
            path,
            body: bodyData,
            label: "DeviceNotificationSettingsService PUT"
        )

        guard !data.isEmpty else {
            throw APIServiceError.invalidPayload(path)
        }

        return try APIDecoding.decode(DeviceNotificationSettings.self, from: data, decoder: .usingDefaultKeys(), label: "DeviceNotificationSettingsService PUT")
    }
}
