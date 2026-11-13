import Foundation
import os

/// Last APNs device token this install received.
///
/// Kept in the Keychain (after first unlock, this device only) rather than
/// UserDefaults. A value left in UserDefaults by an older build is moved into
/// the Keychain on first read and then deleted.
enum PushTokenStore {
    private static let legacyDefaultsKey = "BillBoard.pushToken.apns.v1"
    private static let keychain = KeychainStore(accessibility: .afterFirstUnlockThisDeviceOnly)
    private static let keychainAccount = "apns_token"

    static func load(defaults: UserDefaults = .standard) -> String? {
        if let token = keychain.string(account: keychainAccount)?.trimmedNonEmpty {
            return token
        }

        guard let legacyToken = defaults.string(forKey: legacyDefaultsKey)?.trimmedNonEmpty else {
            return nil
        }

        if keychain.set(legacyToken, account: keychainAccount) {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
        return legacyToken
    }

    static func save(_ token: String, defaults: UserDefaults = .standard) {
        guard let trimmed = token.trimmedNonEmpty else { return }

        if keychain.set(trimmed, account: keychainAccount) {
            defaults.removeObject(forKey: legacyDefaultsKey)
        } else {
            AppLog.push.error("PushTokenStore: Keychain write failed; token not persisted")
        }
    }

    static func clear(defaults: UserDefaults = .standard) {
        keychain.delete(account: keychainAccount)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}
