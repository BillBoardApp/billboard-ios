import Foundation
import os

enum AdultEligibilityStatus: String, Codable {
    case attestedAdult = "attested_adult"
    case selfReportedUnder18 = "self_reported_under18"
    case unknown
}

enum AccountDeletionStatus: String, Codable {
    case notRequested = "not_requested"
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
}

struct ComplianceSnapshot: Equatable {
    let adultStatus: AdultEligibilityStatus
    let adultMethod: String?
    let adultStatusSetAt: String?
    let deletionStatus: AccountDeletionStatus
    let canWrite: Bool
}

struct AccountDeletionSnapshot: Equatable {
    let deletionStatus: AccountDeletionStatus
    let deletionRequestedAt: String?
    let deletionCompletedAt: String?
    let deletionError: String?
}

enum AccountComplianceService {
    enum ServiceError: UserFacingError, Equatable {
        case invalidPayload
        case attestationNotApplied
        /// The associated detail comes from the backend or the app and is for logs
        /// only; `errorDescription` is fixed user copy.
        case accountDeletionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPayload:
                return "We couldn't read the server's response. Please try again."
            case .attestationNotApplied:
                return "Age verification did not complete. Please try again."
            case .accountDeletionFailed:
                return "We couldn't finish deleting your account. Please try again."
            }
        }
    }

    static func fetchMe() async throws -> ComplianceSnapshot {
        let data = try await APIClient.current.payload(
            .get,
            "me",
            label: "AccountComplianceService me"
        )

        let decoded: MeDTO = try decodeResponse(from: data, label: "AccountComplianceService me")
        let snapshot = decoded.snapshot
        AppLog.api.debug("[AccountComplianceService me] userId=\(decoded.userId ?? "(nil)", privacy: .private) adultStatus=\(snapshot.adultStatus.rawValue, privacy: .public) deletionStatus=\(snapshot.deletionStatus.rawValue, privacy: .public) canWrite=\(snapshot.canWrite)")
        return snapshot
    }

    static func submitAdultAttestation(isAdult: Bool) async throws -> ComplianceSnapshot {
        struct Payload: Encodable { let isAdult: Bool }
        let body = try JSONEncoder().encode(Payload(isAdult: isAdult))

        let data = try await APIClient.current.payload(
            .post,
            "adult-attestation",
            body: body,
            label: "AccountComplianceService adult-attestation"
        )

        let snapshot = try await decodeAdultAttestationSnapshot(from: data)
        AppLog.api.debug("[AccountComplianceService adult-attestation] adultStatus=\(snapshot.adultStatus.rawValue, privacy: .public) canWrite=\(snapshot.canWrite)")
        return snapshot
    }

    /// Opts in to the backend deleting the Cognito user as the last step of
    /// `DELETE /account-data`. The backend only does so for clients that ask,
    /// because older builds delete the user themselves and fail if it is already
    /// gone; this build tolerates that (`AuthManager.deleteCurrentAccount`).
    /// The handler accepts the `X-Billboard-Delete-Sign-In` header or this query
    /// parameter with "1" or "true"; `APIClient` sends no per-request headers,
    /// so the query parameter carries it.
    static let deleteAccountDataQueryParameters: [String: String] = ["deleteSignIn": "1"]

    static func deleteAccountData() async throws -> AccountDeletionSnapshot {
        let data = try await APIClient.current.payload(
            .delete,
            "account-data",
            query: deleteAccountDataQueryParameters,
            label: "AccountComplianceService account-data delete"
        )

        let decoded: AccountDataDTO = try decodeResponse(from: data, label: "AccountComplianceService account-data delete")
        if decoded.deletionStatus == .failed {
            let detail = decoded.deletionError ?? "Account deletion failed."
            AppLog.api.error("[AccountComplianceService account-data delete] deletion failed: \(detail, privacy: .private)")
            throw ServiceError.accountDeletionFailed(detail)
        }
        return decoded.snapshot
    }

    static func fetchAccountDataStatus() async throws -> AccountDeletionSnapshot {
        let data = try await APIClient.current.payload(
            .get,
            "account-data/status",
            label: "AccountComplianceService account-data status"
        )

        let decoded: AccountDataDTO = try decodeResponse(from: data, label: "AccountComplianceService account-data status")
        return decoded.snapshot
    }

    private struct MeDTO: Decodable {
        let userId: String?
        let adultStatus: AdultEligibilityStatus?
        let adultMethod: String?
        let adultStatusSetAt: String?
        let deletionStatus: AccountDeletionStatus?
        let canWrite: Bool?

        var snapshot: ComplianceSnapshot {
            ComplianceSnapshot(
                adultStatus: adultStatus ?? .unknown,
                adultMethod: adultMethod,
                adultStatusSetAt: adultStatusSetAt,
                deletionStatus: deletionStatus ?? .notRequested,
                canWrite: canWrite ?? false
            )
        }
    }

    private struct AdultAttestationDTO: Decodable {
        let adultStatus: AdultEligibilityStatus?
        let adultMethod: String?
        let adultStatusSetAt: String?
        let canWrite: Bool?

        var snapshot: ComplianceSnapshot {
            ComplianceSnapshot(
                adultStatus: adultStatus ?? .unknown,
                adultMethod: adultMethod,
                adultStatusSetAt: adultStatusSetAt,
                deletionStatus: .notRequested,
                canWrite: canWrite ?? false
            )
        }
    }

    private struct AdultAttestationEnvelopeDTO: Decodable {
        let snapshot: AdultAttestationDTO?
        let compliance: AdultAttestationDTO?
        let result: AdultAttestationDTO?
        let item: AdultAttestationDTO?
        let data: AdultAttestationDTO?

        var resolvedSnapshot: ComplianceSnapshot? {
            snapshot?.snapshot
                ?? compliance?.snapshot
                ?? result?.snapshot
                ?? item?.snapshot
                ?? data?.snapshot
        }
    }

    private struct AccountDataDTO: Decodable {
        let deletionStatus: AccountDeletionStatus?
        let deletionRequestedAt: String?
        let deletionCompletedAt: String?
        let deletionError: String?

        var snapshot: AccountDeletionSnapshot {
            AccountDeletionSnapshot(
                deletionStatus: deletionStatus ?? .notRequested,
                deletionRequestedAt: deletionRequestedAt,
                deletionCompletedAt: deletionCompletedAt,
                deletionError: deletionError
            )
        }
    }

    private static func decodeResponse<T: Decodable>(from data: Data, label: String) throws -> T {
        if let parsed = try? APIDecoding.decode(T.self, from: data, decoder: .convertingFromSnakeCase(), label: label) {
            return parsed
        }

        throw ServiceError.invalidPayload
    }

    private static func decodeResponseIfPresent<T: Decodable>(from data: Data) -> T? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder.convertingFromSnakeCase().decode(T.self, from: data)
    }

    private static func decodeAdultAttestationSnapshot(from data: Data) async throws -> ComplianceSnapshot {
        if let decoded: AdultAttestationDTO = decodeResponseIfPresent(from: data) {
            return decoded.snapshot
        }

        if let decoded: MeDTO = decodeResponseIfPresent(from: data) {
            return decoded.snapshot
        }

        if let envelope: AdultAttestationEnvelopeDTO = decodeResponseIfPresent(from: data),
           let snapshot = envelope.resolvedSnapshot {
            return snapshot
        }

        return try await fetchMe()
    }
}
