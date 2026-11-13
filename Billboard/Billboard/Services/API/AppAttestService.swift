import Foundation
import os

// The two public App Attest routes (spec C3 3.2-3.3, 4.4), typed by hand: the contract generator emits only
// `ApiError`. Bodies follow the OpenAPI components `AppAttestChallengeRequest`, `AppAttestChallenge`,
// `AppAttestAttestRequest` and `AppAttestAttestResult` (samples in the platform's `contracts/fixtures/openapi/`).

// MARK: - Results

nonisolated enum AppAttestChallengePurpose: String, CaseIterable, Sendable {
    /// For registering a new key (`POST /app-attest/attest`).
    case attest
    /// For one assertion: a protected request or a sign-up.
    case assert
}

/// The answer of `POST /app-attest/challenge`.
nonisolated enum AppAttestChallengeResult: Equatable, Sendable {
    /// `clientMode: "on"`: a single-use challenge (base64url of 32 bytes), valid until `expiresAt`.
    case on(challenge: String, expiresAt: String?)
    /// `clientMode: "off"`: the server's kill switch (`APP_ATTEST_CLIENT_MODE=off`). Stop attesting for 6 hours.
    case off
}

/// The answer of `POST /app-attest/attest`.
nonisolated struct AppAttestRegistration: Equatable, Sendable {
    enum Status: String, Sendable {
        case attested
        /// A retry for a key registered before; nothing changed on the server.
        case alreadyAttested = "already_attested"
    }

    let status: Status
    /// `production` (TestFlight, App Store) or `development` (development-signed builds).
    let environment: String
}

/// How an App Attest route failed, as the manager acts on it (C3 3.3, 3.10).
nonisolated enum AppAttestServiceError: Error, Equatable, Sendable {
    /// 400 `APP_ATTEST_CHALLENGE_INVALID`: retry once with a new challenge and the same key.
    case challengeInvalid
    /// 400 `APP_ATTEST_REJECTED`: discard the key.
    case rejected
    /// 503 `APP_ATTEST_UNAVAILABLE`, 429, any other HTTP error (including a firewall block), or no network:
    /// keep the key and back off.
    case unavailable
    /// A 200 whose body is not the documented shape.
    case invalidResponse
}

// MARK: - Backend seam

/// The server side of `AppAttestManager`. Live: `AppAttestService` through `APIClient`; tests pass a fake.
nonisolated protocol AppAttestBackend: Sendable {
    func challenge(purpose: AppAttestChallengePurpose) async throws -> AppAttestChallengeResult
    /// `keyId` in wire form (base64url); `attestation` is the raw CBOR object (sent as standard base64).
    func register(keyId: String, challenge: String, attestation: Data) async throws -> AppAttestRegistration
    /// The upper-snake code of a failed protected request's error body (`APP_ATTEST_UNKNOWN_KEY`, ...), if any.
    func serverCode(of error: any Error) async -> String?
}

nonisolated struct LiveAppAttestBackend: AppAttestBackend {
    func challenge(purpose: AppAttestChallengePurpose) async throws -> AppAttestChallengeResult {
        try await AppAttestService.issueChallenge(purpose: purpose)
    }

    func register(keyId: String, challenge: String, attestation: Data) async throws -> AppAttestRegistration {
        try await AppAttestService.registerKey(keyId: keyId, challenge: challenge, attestation: attestation)
    }

    func serverCode(of error: any Error) async -> String? {
        await AppAttestService.serverCode(of: error)
    }
}

// MARK: - Service

/// `POST /app-attest/challenge` and `POST /app-attest/attest`. Both routes have no authorizer, so they use
/// `.autoFetch` and work signed out (first launch, sign-up).
enum AppAttestService {
    static let challengePath = "app-attest/challenge"
    static let attestPath = "app-attest/attest"

    static func issueChallenge(purpose: AppAttestChallengePurpose) async throws -> AppAttestChallengeResult {
        let body = try encoder.encode(ChallengeRequestDTO(purpose: purpose.rawValue))
        let data = try await post(challengePath, body: body)
        let result = try parseChallenge(data)
        if case .off = result {
            AppLog.api.info("[AppAttestService] challenge purpose=\(purpose.rawValue, privacy: .public): client mode off")
        }
        return result
    }

    /// Registers the key. `keyId` is the wire form; `attestation` the raw CBOR object.
    static func registerKey(keyId: String, challenge: String, attestation: Data) async throws -> AppAttestRegistration {
        let body = try encoder.encode(
            AttestRequestDTO(keyId: keyId, challenge: challenge, attestation: attestation.base64EncodedString())
        )
        let data = try await post(attestPath, body: body)
        return try parseRegistration(data)
    }

    /// The backend code in a failed request's error body, or nil.
    static func serverCode(of error: any Error) -> String? {
        APIErrorResponse.errorCode(from: error)
    }

    /// Maps a transport failure to `AppAttestServiceError`. A cancellation passes through unchanged.
    static func classify(_ error: Error) -> Error {
        if error is CancellationError || error is AppAttestServiceError { return error }
        switch serverCode(of: error).flatMap(AppAttestServerCode.init(rawValue:)) {
        case .challengeInvalid?:
            return AppAttestServiceError.challengeInvalid
        case .rejected?:
            return AppAttestServiceError.rejected
        default:
            return AppAttestServiceError.unavailable
        }
    }

    private static func post(_ path: String, body: Data) async throws -> Data {
        do {
            return try await APIClient.current.payload(
                .post,
                path,
                body: body,
                label: "AppAttestService \(path)",
                authMode: .autoFetch
            )
        } catch {
            throw classify(error)
        }
    }

    // MARK: - Bodies

    nonisolated static func parseChallenge(_ data: Data) throws -> AppAttestChallengeResult {
        guard let dto = try? JSONDecoder().decode(ChallengeDTO.self, from: data) else {
            throw AppAttestServiceError.invalidResponse
        }
        switch dto.clientMode {
        case "off":
            return .off
        case "on":
            guard let challenge = dto.challenge, AppAttestWire.isValidChallenge(challenge) else {
                throw AppAttestServiceError.invalidResponse
            }
            return .on(challenge: challenge, expiresAt: dto.expiresAt)
        default:
            throw AppAttestServiceError.invalidResponse
        }
    }

    nonisolated static func parseRegistration(_ data: Data) throws -> AppAttestRegistration {
        guard let dto = try? JSONDecoder().decode(AttestResultDTO.self, from: data),
              let status = AppAttestRegistration.Status(rawValue: dto.status),
              !dto.environment.isEmpty else {
            throw AppAttestServiceError.invalidResponse
        }
        return AppAttestRegistration(status: status, environment: dto.environment)
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Standard base64 carries "/"; keep it unescaped (the body is up to 16 KB).
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    nonisolated private struct ChallengeRequestDTO: Encodable {
        let purpose: String
    }

    nonisolated private struct ChallengeDTO: Decodable {
        let clientMode: String
        let challenge: String?
        let expiresAt: String?
    }

    nonisolated private struct AttestRequestDTO: Encodable {
        let keyId: String
        let challenge: String
        let attestation: String
    }

    nonisolated private struct AttestResultDTO: Decodable {
        let status: String
        let environment: String
    }
}
