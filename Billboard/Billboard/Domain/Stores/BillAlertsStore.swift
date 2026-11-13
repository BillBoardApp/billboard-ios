import Combine
import Foundation

/// Recent "Action in Congress" alerts, cached per user. Alerts come in, from the cache and from pushes,
/// with legacy topic names mapped to the current ones (LLM-10, `BillAlert.canonicalizingTopics()`).
@MainActor
final class BillAlertsStore: ObservableObject {
    @Published private(set) var alerts: [BillAlert]
    private let scope: String?

    private enum CacheKeys {
        static let legacyAlertsData = "BillAlertsStore.alerts.data"
        static let legacyAlertsTimestamp = "BillAlertsStore.alerts.timestamp"
    }

    init(scope: String? = nil, alerts: [BillAlert]? = nil) {
        self.scope = ScopedStorageKey.normalizedScope(scope)
        if self.scope != nil {
            Self.clearLegacyCache()
        }
        if let alerts {
            self.alerts = alerts.map { $0.canonicalizingTopics() }
        } else if let cached = Self.cachedAlerts(scope: self.scope) {
            self.alerts = cached
        } else {
            self.alerts = []
        }
    }

    func ingest(_ incoming: BillAlert) {
        let alert = incoming.canonicalizingTopics()
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
            // If the same alert arrives again, keep the newest timestamp.
            if alert.date > alerts[index].date {
                alerts[index] = alert
            }
        } else {
            alerts.append(alert)
        }

        // Keep newest first for quick access.
        alerts.sort { $0.date > $1.date }

        // Prevent unbounded growth.
        if alerts.count > 200 {
            alerts = Array(alerts.prefix(200))
        }

        cacheAlerts(alerts)
    }

    /// Removes the alert with `id`. Returns it with its position, so an undo can put it back
    /// (`restore(_:)`); nil when no alert has that id.
    @discardableResult
    func remove(_ id: UUID) -> RemovedBillAlert? {
        guard let index = alerts.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = RemovedBillAlert(alert: alerts[index], index: index)
        alerts.removeAll { $0.id == id }
        cacheAlerts(alerts)
        return removed
    }

    /// Removes every alert. Returns them with their positions, for `restore(_:)`.
    @discardableResult
    func clearAll() -> [RemovedBillAlert] {
        guard !alerts.isEmpty else { return [] }
        let removed = alerts.enumerated().map { RemovedBillAlert(alert: $0.element, index: $0.offset) }
        alerts.removeAll()
        cacheAlerts(alerts)
        return removed
    }

    /// Puts removed alerts back where they were (Undo, spec D 2.1.2): in order of their old positions,
    /// so a list nothing else changed comes back exactly as it was. An alert that is already back (the
    /// same push arrived again) is left as it is.
    func restore(_ removed: [RemovedBillAlert]) {
        var restored = alerts
        var changed = false
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            guard !restored.contains(where: { $0.id == entry.alert.id }) else { continue }
            restored.insert(entry.alert, at: min(max(entry.index, 0), restored.count))
            changed = true
        }
        guard changed else { return }
        alerts = restored
        cacheAlerts(alerts)
    }

    // MARK: - Caching

    private static func cachedAlerts(scope: String?) -> [BillAlert]? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: alertsDataKey(scope: scope)) else { return nil }
        let alerts = try? JSONDecoder.usingDefaultKeys(dates: .iso8601).decode([BillAlert].self, from: data)
        return alerts?.map { $0.canonicalizingTopics() }
    }

    private func cacheAlerts(_ alerts: [BillAlert]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(alerts) {
            let defaults = UserDefaults.standard
            defaults.set(data, forKey: Self.alertsDataKey(scope: scope))
            defaults.set(Date().timeIntervalSince1970, forKey: Self.alertsTimestampKey(scope: scope))
        }
    }

    private static func alertsDataKey(scope: String?) -> String {
        ScopedStorageKey.make(base: CacheKeys.legacyAlertsData, scope: scope)
    }

    private static func alertsTimestampKey(scope: String?) -> String {
        ScopedStorageKey.make(base: CacheKeys.legacyAlertsTimestamp, scope: scope)
    }

    static func clearCache(scope: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: alertsDataKey(scope: scope))
        defaults.removeObject(forKey: alertsTimestampKey(scope: scope))

        if ScopedStorageKey.normalizedScope(scope) != nil {
            clearLegacyCache(defaults: defaults)
        }
    }

    static func clearLegacyCache(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: CacheKeys.legacyAlertsData)
        defaults.removeObject(forKey: CacheKeys.legacyAlertsTimestamp)
    }
}

/// An alert taken out of `BillAlertsStore` and the position it had, kept by an undo record.
struct RemovedBillAlert: Equatable {
    let alert: BillAlert
    let index: Int
}
