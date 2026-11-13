import Combine
import Foundation

struct ReadStateSnapshot: Codable, Equatable {
    var readBillAlertIDs: Set<UUID>
    var dismissedBillIDs: Set<UUID>

    static let empty = ReadStateSnapshot(readBillAlertIDs: [], dismissedBillIDs: [])

    private enum CodingKeys: String, CodingKey {
        // Preserve on-disk/JSON compatibility with the previous key name.
        case readBillAlertIDs = "readCongressUpdateIDs"
        case dismissedBillIDs
    }
}

enum ReadStateScope: Hashable {
    case device
    case user(String)

    fileprivate var storageSuffix: String {
        switch self {
        case .device:
            return "device"
        case .user(let id):
            return "user_\(Self.sanitize(id))"
        }
    }

    private static func sanitize(_ value: String) -> String {
        // Keep keys deterministic and filesystem/JSON friendly.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped)
    }
}

protocol ReadStateStore {
    func load(scope: ReadStateScope) -> ReadStateSnapshot
    func save(_ snapshot: ReadStateSnapshot, scope: ReadStateScope)
}

final class UserDefaultsReadStateStore: ReadStateStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder.usingDefaultKeys()
    private static let keyPrefix = "BillBoard.readState.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(scope: ReadStateScope) -> ReadStateSnapshot {
        let key = Self.key(for: scope)
        guard let data = defaults.data(forKey: key) else { return .empty }
        return (try? decoder.decode(ReadStateSnapshot.self, from: data)) ?? .empty
    }

    func save(_ snapshot: ReadStateSnapshot, scope: ReadStateScope) {
        let key = Self.key(for: scope)
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(scope: ReadStateScope, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: scope))
    }

    private static func key(for scope: ReadStateScope) -> String {
        keyPrefix + scope.storageSuffix
    }
}

/// What the user has read and hidden on this device: read alerts, and dismissed bills (a skip on
/// Bills or a Clear on Updates, spec D 2.1). Stored per user in `UserDefaults`; never sent to the
/// server, so a skipped bill shows again on another device or after a reinstall.
@MainActor
final class AppReadState: ObservableObject {
    @Published private(set) var readBillAlertIDs: Set<UUID>
    @Published private(set) var dismissedBillIDs: Set<UUID>

    private let scope: ReadStateScope
    private let store: any ReadStateStore

    init(scope: ReadStateScope = .device, store: (any ReadStateStore)? = nil) {
        self.scope = scope
        self.store = store ?? UserDefaultsReadStateStore()

        let snapshot = self.store.load(scope: scope)
        self.readBillAlertIDs = snapshot.readBillAlertIDs
        self.dismissedBillIDs = snapshot.dismissedBillIDs
    }

    func exportSnapshot() -> ReadStateSnapshot {
        ReadStateSnapshot(readBillAlertIDs: readBillAlertIDs, dismissedBillIDs: dismissedBillIDs)
    }

    /// Marks an alert read. Returns true when it was unread, so an undo knows what to restore.
    @discardableResult
    func markBillAlertRead(_ id: UUID) -> Bool {
        guard !readBillAlertIDs.contains(id) else { return false }
        readBillAlertIDs.insert(id)
        persist()
        return true
    }

    /// Marks alerts unread again (Undo after a skip or Clear, spec D 2.1.2). One publish and one save.
    func markBillAlertsUnread(_ ids: [UUID]) {
        let read = ids.filter { readBillAlertIDs.contains($0) }
        guard !read.isEmpty else { return }
        readBillAlertIDs.subtract(read)
        persist()
    }

    func markBillDismissed(_ id: UUID) {
        guard !dismissedBillIDs.contains(id) else { return }
        dismissedBillIDs.insert(id)
        persist()
    }

    /// Dismisses (skips) bills on this device. Returns the ids that were not dismissed before, in
    /// order and without repeats, so an undo restores exactly what this call changed.
    @discardableResult
    func dismissAllBills(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        let newDismissals = ids.filter { !dismissedBillIDs.contains($0) && seen.insert($0).inserted }
        guard !newDismissals.isEmpty else { return [] }
        dismissedBillIDs.formUnion(newDismissals)
        persist()
        return newDismissals
    }

    /// Re-surface a previously dismissed bill (e.g., when a new push arrives for it).
    func undismissBill(_ id: UUID) {
        guard dismissedBillIDs.contains(id) else { return }
        dismissedBillIDs.remove(id)
        persist()
    }

    /// `undismissBill` for several bills (Undo, or Put back from Search bills). One publish and one save.
    func undismissBills(_ ids: [UUID]) {
        let dismissed = ids.filter { dismissedBillIDs.contains($0) }
        guard !dismissed.isEmpty else { return }
        dismissedBillIDs.subtract(dismissed)
        persist()
    }

    private func persist() {
        store.save(exportSnapshot(), scope: scope)
    }
}
