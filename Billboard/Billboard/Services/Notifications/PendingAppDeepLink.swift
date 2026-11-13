import Foundation

/// Persists a pending app deep link across cold launch so UI can consume it once ready.
/// Only well-formed bill guids (see `BillGuid`) are stored or returned.
enum PendingAppDeepLink {
    private static let key = "BillBoard.pendingAppDeepLink.billGuid.v1"

    static func saveBillGuid(_ guid: String, defaults: UserDefaults = .standard) {
        guard let validGuid = BillGuid.validated(guid) else { return }
        defaults.set(validGuid, forKey: key)
    }

    /// Loads and clears the pending bill guid.
    static func consumeBillGuid(defaults: UserDefaults = .standard) -> String? {
        let guid = defaults.string(forKey: key)
        defaults.removeObject(forKey: key)
        return BillGuid.validated(guid)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
