import DeviceCheck
import Foundation

// The device and storage seams `AppAttestManager` works through (spec C3 3.10). Live implementations wrap
// `DCAppAttestService.shared`, `DCDevice.current`, the Keychain and UserDefaults; tests pass fakes.

// MARK: - App Attest

/// Apple's App Attest service for this install.
nonisolated protocol AppAttestProviding: Sendable {
    /// False on the Simulator, on devices without a Secure Enclave and in most app extensions.
    var isSupported: Bool { get }
    /// A new key in the Secure Enclave; returns its key ID in standard base64.
    func generateKey() async throws -> String
    /// The attestation object (CBOR) for `keyId` over `clientDataHash`; calls Apple's servers.
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    /// An assertion (CBOR) for `keyId` over `clientDataHash`; local, increments the key's counter.
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Apple's DeviceCheck token for this device (sent at sign-up only).
nonisolated protocol DeviceTokenProviding: Sendable {
    var isSupported: Bool { get }
    func generateToken() async throws -> Data
}

/// `DCAppAttestService.shared`. The class is not marked `Sendable`; the service is documented as safe to use
/// from any thread, so the wrapper is `@unchecked Sendable` (C3 3.10).
nonisolated final class LiveAppAttestProvider: AppAttestProviding, @unchecked Sendable {
    private var service: DCAppAttestService { DCAppAttestService.shared }

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

/// `DCDevice.current`, `@unchecked Sendable` for the same reason as `LiveAppAttestProvider`.
nonisolated final class LiveDeviceTokenProvider: DeviceTokenProviding, @unchecked Sendable {
    private var device: DCDevice { DCDevice.current }

    var isSupported: Bool { device.isSupported }

    func generateToken() async throws -> Data {
        try await device.generateToken()
    }
}

/// What a `DCAppAttestService` error means for the key (Apple's guidance, C3 3.10).
nonisolated enum AppAttestProviderFailure: Equatable, Sendable {
    /// `DCError.serverUnavailable`: keep the key and try again later.
    case serverUnavailable
    /// `DCError.invalidKey`: the key is gone (reinstall, device restore or migration). Discard it.
    case invalidKey
    /// Any other `DCError` (its code): discard the key and generate a new one.
    case otherDeviceCheck(Int)
    /// Not a DeviceCheck error. The key is kept.
    case other

    init(_ error: Error) {
        let code: Int
        if let deviceCheckError = error as? DCError {
            code = deviceCheckError.code.rawValue
        } else {
            let nsError = error as NSError
            guard nsError.domain == DCError.errorDomain else {
                self = .other
                return
            }
            code = nsError.code
        }
        switch code {
        case DCError.Code.serverUnavailable.rawValue:
            self = .serverUnavailable
        case DCError.Code.invalidKey.rawValue:
            self = .invalidKey
        default:
            self = .otherDeviceCheck(code)
        }
    }

    /// True when Apple's guidance is to discard the key (every `DCError` except `serverUnavailable`).
    var discardsKey: Bool {
        switch self {
        case .invalidKey, .otherDeviceCheck:
            return true
        case .serverUnavailable, .other:
            return false
        }
    }
}

// MARK: - Storage

/// The key of this install, as stored in the Keychain: JSON `{keyId, attested, environment, attestedAt}`
/// (spec C3 3.10). `keyId` is the wire form (base64url).
nonisolated struct AppAttestKeyRecord: Codable, Equatable, Sendable {
    var keyId: String
    var attested: Bool
    /// `production` or `development`, from `POST /app-attest/attest`; nil until attested.
    var environment: String?
    /// ISO-8601 time of the successful attestation; nil until attested.
    var attestedAt: String?

    init(keyId: String, attested: Bool, environment: String? = nil, attestedAt: String? = nil) {
        self.keyId = keyId
        self.attested = attested
        self.environment = environment
        self.attestedAt = attestedAt
    }
}

/// The result of reading the stored key.
nonisolated enum AppAttestStoredKey: Equatable, Sendable {
    case none
    case record(AppAttestKeyRecord)
    /// Something is stored but it is not a readable record; the manager deletes it.
    case unreadable
}

/// The two times that pause attestation (spec D 3.2): a back-off after a failed attestation (1 hour) and the
/// server's `clientMode: "off"` (6 hours).
nonisolated enum AppAttestTimer: String, CaseIterable, Sendable {
    case backoffUntil = "BillBoard.appAttest.backoffUntil.v1"
    case disabledUntil = "BillBoard.appAttest.disabledUntil.v1"
}

/// Where the manager keeps its state across launches.
nonisolated protocol AppAttestStoring: Sendable {
    func loadKey() -> AppAttestStoredKey
    /// False when the Keychain refused the write.
    func saveKey(_ record: AppAttestKeyRecord) -> Bool
    func deleteKey()
    func date(for timer: AppAttestTimer) -> Date?
    func setDate(_ date: Date?, for timer: AppAttestTimer)
}

/// The key in the Keychain (account `appattest.v1`, `afterFirstUnlockThisDeviceOnly`, so it never leaves the
/// device in a backup) and the timers in UserDefaults. Sign-out and account deletion leave both alone: the
/// key belongs to the install, not to an account (C3 3.10, D1).
nonisolated struct LiveAppAttestStorage: AppAttestStoring {
    static let keychainAccount = "appattest.v1"

    private let keychain: KeychainStore
    private let defaultsSuiteName: String?

    /// - Parameters:
    ///   - keychainService: The Keychain service; the app's service (bundle identifier) by default. Tests pass
    ///     their own.
    ///   - defaultsSuiteName: A UserDefaults suite for the timers; nil means `UserDefaults.standard`.
    init(keychainService: String = KeychainStore.appServiceName, defaultsSuiteName: String? = nil) {
        self.keychain = KeychainStore(service: keychainService, accessibility: .afterFirstUnlockThisDeviceOnly)
        self.defaultsSuiteName = defaultsSuiteName
    }

    private var defaults: UserDefaults {
        defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    func loadKey() -> AppAttestStoredKey {
        guard let data = keychain.data(account: Self.keychainAccount) else { return .none }
        guard let record = try? JSONDecoder().decode(AppAttestKeyRecord.self, from: data) else { return .unreadable }
        return .record(record)
    }

    func saveKey(_ record: AppAttestKeyRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        return keychain.set(data, account: Self.keychainAccount)
    }

    func deleteKey() {
        keychain.delete(account: Self.keychainAccount)
    }

    func date(for timer: AppAttestTimer) -> Date? {
        guard let seconds = defaults.object(forKey: timer.rawValue) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func setDate(_ date: Date?, for timer: AppAttestTimer) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: timer.rawValue)
        } else {
            defaults.removeObject(forKey: timer.rawValue)
        }
    }
}
