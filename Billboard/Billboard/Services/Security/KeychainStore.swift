import Foundation
import Security

/// Small wrapper over generic-password Keychain items for one service string.
///
/// Several stores share the app's bundle identifier as their service, so bulk
/// deletes are always scoped by account prefix (see `deleteAll(accountPrefix:)`).
struct KeychainStore: Sendable {
    enum Accessibility: Sendable {
        /// Leave `kSecAttrAccessible` unset, so the system default
        /// (`kSecAttrAccessibleWhenUnlocked`) applies.
        case systemDefault
        /// Readable after the first unlock following a reboot (so background
        /// work can use it), never migrated to another device by a backup.
        case afterFirstUnlockThisDeviceOnly

        nonisolated var attributeValue: CFString? {
            switch self {
            case .systemDefault:
                return nil
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    /// The service most app items live under.
    nonisolated static let appServiceName = Bundle.main.bundleIdentifier ?? "BillBoard"

    let service: String
    let accessibility: Accessibility

    nonisolated init(service: String = KeychainStore.appServiceName, accessibility: Accessibility) {
        self.service = service
        self.accessibility = accessibility
    }

    // MARK: - Read

    nonisolated func data(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    nonisolated func string(account: String) -> String? {
        guard let data = data(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Write

    /// Inserts or replaces the item. On replace, the configured accessibility is
    /// applied too, which upgrades items written before it was set.
    @discardableResult
    nonisolated func set(_ value: Data, account: String) -> Bool {
        let query = baseQuery(account: account)

        var updateAttributes: [String: Any] = [
            kSecValueData as String: value
        ]
        if let accessible = accessibility.attributeValue {
            updateAttributes[kSecAttrAccessible as String] = accessible
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus != errSecItemNotFound {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData as String] = value
        if let accessible = accessibility.attributeValue {
            addQuery[kSecAttrAccessible as String] = accessible
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    nonisolated func set(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return set(data, account: account)
    }

    /// Re-applies the configured accessibility to an existing item without
    /// touching its value. Returns false when there is nothing to update.
    @discardableResult
    nonisolated func applyAccessibility(account: String) -> Bool {
        guard let accessible = accessibility.attributeValue else { return false }
        let attributes: [String: Any] = [kSecAttrAccessible as String: accessible]
        let status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        return status == errSecSuccess
    }

    // MARK: - Delete

    nonisolated func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    /// Deletes every item under this service whose account name begins with
    /// `accountPrefix`. The Keychain has no prefix query, so this enumerates the
    /// service's items and deletes matches one by one; items owned by other
    /// stores under the same service are left alone.
    nonisolated func deleteAll(accountPrefix: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(accountPrefix) else { continue }
            delete(account: account)
        }
    }

    // MARK: - Helpers

    nonisolated private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
