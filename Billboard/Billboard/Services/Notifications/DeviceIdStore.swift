import Foundation
import os

/// Stable per-install device identifier used for push registration and
/// per-device notification settings.
///
/// Stored in the Keychain as after-first-unlock, this-device-only, so it is
/// readable by background work after a reboot and never restored onto a
/// different device from a backup. Older builds also kept a copy in
/// UserDefaults; that copy is migrated into the Keychain and then removed.
enum DeviceIdStore {
    private static let userDefaultsKey = "BillBoard.deviceId.v1"
    private static let keychain = KeychainStore(accessibility: .afterFirstUnlockThisDeviceOnly)
    private static let keychainAccount = "device_id"
    private static var didUpgradeAccessibility = false

    static func getOrCreate() -> String {
        if let existing = load(), !existing.isEmpty {
            return existing
        }

        let created = UUID().uuidString.lowercased()
        save(created)
        return created
    }

    static func load() -> String? {
        if let keychainValue = keychain.string(account: keychainAccount),
           let trimmed = keychainValue.trimmedNonEmpty {
            upgradeAccessibilityIfNeeded()
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            return trimmed
        }

        if let defaultsValue = UserDefaults.standard.string(forKey: userDefaultsKey),
           let trimmed = defaultsValue.trimmedNonEmpty {
            // Migrate the legacy UserDefaults copy into the Keychain.
            save(trimmed)
            return trimmed
        }

        return nil
    }

    static func save(_ deviceId: String) {
        guard let trimmed = deviceId.trimmedNonEmpty else { return }

        if keychain.set(trimmed, account: keychainAccount) {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        } else {
            // Keep a fallback copy so the id stays stable if the Keychain is
            // unavailable (for example before first unlock).
            AppLog.store.error("DeviceIdStore: Keychain write failed; keeping UserDefaults fallback")
            UserDefaults.standard.set(trimmed, forKey: userDefaultsKey)
        }
    }

    /// Items written by older builds used the system default accessibility.
    /// Re-apply the current setting once per launch.
    private static func upgradeAccessibilityIfNeeded() {
        guard !didUpgradeAccessibility else { return }
        didUpgradeAccessibility = true
        keychain.applyAccessibility(account: keychainAccount)
    }
}
