import CryptoKit
import Foundation
import os
import Amplify

private actor PushRegistrationCoordinator {
    private var inFlightKeys: Set<String> = []

    func begin(_ key: String) -> Bool {
        if inFlightKeys.contains(key) {
            return false
        }

        inFlightKeys.insert(key)
        return true
    }

    func end(_ key: String) {
        inFlightKeys.remove(key)
    }
}

struct PushRegistrationService {
    enum PushRegistrationError: LocalizedError {
        case notSignedIn
        case noTokens
        case invalidResponse
        case httpError(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in."
            case .noTokens:
                return "Signed in, but no Cognito tokens were available."
            case .invalidResponse:
                return "Invalid HTTP response."
            case .httpError(let status, _):
                return "Register device failed with HTTP \(status)."
            }
        }
    }

    private let logger = AppLog.push
    private static let legacyLastRegisteredTokenKey = "PushRegistrationService.lastRegisteredToken"
    private static let lastRegisteredTokenPrefix = "PushRegistrationService.lastRegisteredToken."
    private static let coordinator = PushRegistrationCoordinator()

    struct RegisterDevicePayload: Codable {
        let deviceId: String
        let platform: String
        let pushToken: String

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case platform
            case pushToken = "push_token"
        }

        init(deviceId: String, pushTokenHex: String) {
            self.deviceId = deviceId
            self.platform = "ios"
            self.pushToken = pushTokenHex
        }
    }

    /// Calls `POST {USER_API_BASE_URL}register-device` for the signed-in user.
    /// Best-effort helper used by the app: only works when signed in.
    ///
    /// Sends the Cognito ID token (the only token the API's authorizer accepts).
    /// A 401 gets one forced session refresh and one resend; any other failure,
    /// including 403, is final.
    func registerDeviceIfSignedIn(apnsTokenHex: String) async throws {
        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn else {
            throw PushRegistrationError.notSignedIn
        }
        let currentUser = try await Amplify.Auth.getCurrentUser()
        guard let authorization = try APIAuthHeaders.candidates(from: session).first else {
            throw PushRegistrationError.noTokens
        }

        let trimmedToken = apnsTokenHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedToken.isEmpty else { return }
        let registrationKey = Self.lastRegisteredTokenKey(for: currentUser.userId)
        // Only a fingerprint of the token is kept in UserDefaults; the token itself
        // lives in the Keychain (`PushTokenStore`).
        let tokenFingerprint = Self.fingerprint(of: trimmedToken)

        if tokenFingerprint == UserDefaults.standard.string(forKey: registrationKey) {
            logger.debug("register-device -> skipped (token unchanged)")
            return
        }

        let attemptKey = "\(registrationKey)|\(trimmedToken)"
        let didStartAttempt = await Self.coordinator.begin(attemptKey)
        guard didStartAttempt else {
            logger.debug("register-device -> skipped (registration already in flight)")
            return
        }
        defer {
            Task {
                await Self.coordinator.end(attemptKey)
            }
        }

        let baseURL = try UserAPIBaseURL.resolve()
        let url = baseURL.appendingPathComponent("register-device")

        let deviceId = DeviceIdStore.getOrCreate()
        let payload = RegisterDevicePayload(deviceId: deviceId, pushTokenHex: trimmedToken)

        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(payload)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var authorizationValue = authorization.value
        for attempt in 1...2 {
            request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PushRegistrationError.invalidResponse
            }

            if http.statusCode == 200 {
                UserDefaults.standard.removeObject(forKey: Self.legacyLastRegisteredTokenKey)
                UserDefaults.standard.set(tokenFingerprint, forKey: registrationKey)
                logger.debug("register-device -> success")
                return
            }

            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body length=\(data.count)>"
            logger.error("register-device -> failed (status=\(http.statusCode, privacy: .public), attempt=\(attempt)) body=\(body, privacy: .private)")

            if http.statusCode == 401, attempt == 1 {
                let refreshed = try await Amplify.Auth.fetchAuthSession(options: .forceRefresh())
                guard let refreshedAuthorization = try APIAuthHeaders.candidates(from: refreshed).first else {
                    throw PushRegistrationError.noTokens
                }
                authorizationValue = refreshedAuthorization.value
                continue
            }

            throw PushRegistrationError.httpError(status: http.statusCode, body: body)
        }

        throw PushRegistrationError.noTokens
    }

    static func clearCachedRegistrations(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyLastRegisteredTokenKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(lastRegisteredTokenPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func fingerprint(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func lastRegisteredTokenKey(for userId: String) -> String {
        let cleaned = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return legacyLastRegisteredTokenKey }
        return "\(lastRegisteredTokenPrefix)\(cleaned)"
    }
}
