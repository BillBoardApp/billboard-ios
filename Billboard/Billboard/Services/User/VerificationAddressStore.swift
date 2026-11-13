import Foundation

struct VerificationAddressDraft: Codable, Equatable {
    let line1: String
    let line2: String?
    let city: String
    let state: String
    let zip: String
}

enum VerificationAddressStore {
    private static let legacyDefaultsKey = "verification.addressDraft.v1"
    private static let keychain = KeychainStore(accessibility: .systemDefault)
    private static let keychainAccountBase = "verification_address_draft"

    static func load(userId: String? = nil, defaults: UserDefaults = .standard) -> VerificationAddressDraft? {
        let scopedAccount = keychainAccount(for: userId)
        if let keychainData = keychain.data(account: scopedAccount),
           let decoded = try? JSONDecoder.usingDefaultKeys().decode(VerificationAddressDraft.self, from: keychainData) {
            return decoded
        }

        if let keychainData = keychain.data(account: keychainAccountBase),
           let decoded = try? JSONDecoder.usingDefaultKeys().decode(VerificationAddressDraft.self, from: keychainData) {
            if scopedAccount != keychainAccountBase {
                keychain.set(keychainData, account: scopedAccount)
            }
            keychain.delete(account: keychainAccountBase)
            defaults.removeObject(forKey: legacyDefaultsKey)
            return decoded
        }

        // Best-effort migration from any previously persisted defaults value.
        if let defaultsData = defaults.data(forKey: legacyDefaultsKey),
           let decoded = try? JSONDecoder.usingDefaultKeys().decode(VerificationAddressDraft.self, from: defaultsData) {
            keychain.set(defaultsData, account: scopedAccount)
            defaults.removeObject(forKey: legacyDefaultsKey)
            return decoded
        }

        return nil
    }

    static func save(
        line1: String,
        line2: String?,
        city: String,
        state: String,
        zip: String,
        userId: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        let cleanedLine1 = line1.trimmed
        let cleanedLine2 = line2.trimmedNonEmpty
        let cleanedCity = city.trimmed
        let cleanedState = state.uppercasedTrimmed
        let cleanedZip = zip.trimmed

        guard !cleanedLine1.isEmpty, !cleanedCity.isEmpty, !cleanedState.isEmpty, !cleanedZip.isEmpty else {
            clear(defaults: defaults)
            return
        }

        let draft = VerificationAddressDraft(
            line1: cleanedLine1,
            line2: cleanedLine2,
            city: cleanedCity,
            state: cleanedState,
            zip: cleanedZip
        )

        guard let encoded = try? JSONEncoder().encode(draft) else { return }
        keychain.set(encoded, account: keychainAccount(for: userId))
        keychain.delete(account: keychainAccountBase)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    static func clear(userId: String? = nil, defaults: UserDefaults = .standard) {
        keychain.delete(account: keychainAccount(for: userId))
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    /// Removes every stored address draft (all users). Only items whose account
    /// starts with this store's prefix are touched; the Keychain service string is
    /// shared with other stores (for example the device id), so a service-wide
    /// delete would wipe those too.
    static func clearAll(defaults: UserDefaults = .standard) {
        keychain.deleteAll(accountPrefix: keychainAccountBase)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    private static func keychainAccount(for userId: String?) -> String {
        guard let cleaned = userId.trimmedNonEmpty else {
            return keychainAccountBase
        }
        return "\(keychainAccountBase).\(cleaned)"
    }
}
