import Foundation
import os

enum DistrictVerificationService {
    /// Every description here is fixed app copy; backend `error`/`message`
    /// strings are never passed through to the UI.
    enum ServiceError: UserFacingError, Equatable {
        case notSignedIn
        case invalidPayload
        case invalidInput(String)
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Your session expired. Please sign in again."
            case .invalidPayload:
                return "We couldn't read the verification result. Please try again."
            case .invalidInput(let message), .requestFailed(let message):
                return message
            }
        }
    }

    private static let path = "district-verification"

    static func fetchStatus() async throws -> DistrictVerificationStatus {
        try await APIClient.current.response(
            DistrictVerificationStatus.self,
            .get,
            path,
            label: "DistrictVerificationService \(path)",
            decoder: .usingDefaultKeys()
        )
    }

    static func submitManualSelection(state: String, district: String) async throws -> DistrictVerificationStatus {
        let cleanedState = normalizedState(state)
        guard !cleanedState.isEmpty else {
            throw ServiceError.invalidInput("State is required.")
        }

        let normalizedDistrict = try normalizeDistrictForAPI(district, state: cleanedState)

        let payload = ManualSelectionRequest(
            state: cleanedState,
            district: normalizedDistrict
        )

        AppLog.api.debug("[DistrictVerificationService] POST \(path, privacy: .public) manual state=\(cleanedState, privacy: .private) district=\(normalizedDistrict, privacy: .private)")

        return try await submit(payload)
    }

    static func submitAddress(
        line1: String,
        line2: String? = nil,
        city: String,
        state: String,
        zip: String,
        claimedDistrict: String? = nil
    ) async throws -> DistrictVerificationStatus {
        let cleanedLine1 = line1.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedState = normalizedState(state)
        let cleanedZip = normalizedZip(zip)

        guard !cleanedLine1.isEmpty else {
            throw ServiceError.invalidInput("Street address is required.")
        }
        guard !cleanedCity.isEmpty else {
            throw ServiceError.invalidInput("City is required.")
        }
        guard !cleanedState.isEmpty else {
            throw ServiceError.invalidInput("State is required.")
        }
        guard !cleanedZip.isEmpty else {
            throw ServiceError.invalidInput("ZIP code must be 5 digits.")
        }

        let cleanedLine2 = line2?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedClaimedDistrict = claimedDistrict?.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload = AddressVerificationRequest(
            line1: cleanedLine1,
            line2: (cleanedLine2?.isEmpty == false) ? cleanedLine2 : nil,
            city: cleanedCity,
            state: cleanedState,
            zip: cleanedZip,
            claimedDistrict: (cleanedClaimedDistrict?.isEmpty == false) ? cleanedClaimedDistrict : nil
        )

        AppLog.api.debug("[DistrictVerificationService] POST \(path, privacy: .public) address state=\(cleanedState, privacy: .private) zip=\(cleanedZip, privacy: .private)")

        return try await submit(payload)
    }

    @discardableResult
    static func removeAddressByManualSelection(state: String, district: String) async throws -> DistrictVerificationStatus {
        try await submitManualSelection(state: state, district: district)
    }

    private static func submit<T: Encodable>(_ payload: T) async throws -> DistrictVerificationStatus {
        let body = try JSONEncoder().encode(payload)
        do {
            return try await APIClient.current.response(
                DistrictVerificationStatus.self,
                .post,
                path,
                body: body,
                label: "DistrictVerificationService \(path)",
                decoder: .usingDefaultKeys()
            )
        } catch {
            throw mapServiceError(from: error)
        }
    }

    private static func normalizedState(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func normalizedZip(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let plusFourRange = trimmed.range(of: #"^\d{5}-\d{4}$"#, options: .regularExpression) {
            return String(trimmed[plusFourRange]).prefix(5).description
        }
        if trimmed.range(of: #"^\d{5}$"#, options: .regularExpression) != nil {
            return trimmed
        }
        return ""
    }

    static func normalizeDistrictForAPI(_ rawDistrict: String, state: String) throws -> String {
        let trimmed = rawDistrict.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceError.invalidInput("District is required.")
        }

        let upper = trimmed.uppercased()
        if upper.contains("AT-LARGE") || upper == "AL" || upper == "0" || upper == "00" {
            return "AL"
        }

        if let fullMatch = upper.range(of: #"^[A-Z]{2}-?(AL|\d{1,2})$"#, options: .regularExpression) {
            let normalized = String(upper[fullMatch]).replacingOccurrences(of: " ", with: "")
            if normalized.hasPrefix(state) {
                let suffix = normalized.replacingOccurrences(of: state, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if suffix == "AL" {
                    return "AL"
                }
                if let n = Int(suffix), n > 0 {
                    return String(n)
                }
            }
            return normalized
        }

        if let numeric = Int(upper.filter { $0.isNumber }), numeric > 0 {
            return String(numeric)
        }

        throw ServiceError.invalidInput("Invalid district format. Use values like 12 or At-Large.")
    }

    /// The copy for an address the Census geocoder could not match (spec D 2.5.3).
    static let addressNotFoundMessage = "We couldn't find that address. Check it, or choose your district instead."

    /// Maps a failed submit to local copy. The backend's `error`/`message` text is
    /// logged, never shown; known backend codes get their own copy (spec D 2.8.4:
    /// 429 `VERIFICATION_RATE_LIMITED`, through `AuthErrorMessages.message(forBackendCode:)`).
    static func mapServiceError(from error: Error) -> Error {
        if error is ServiceError || error is CancellationError {
            return error
        }

        if let bodyPrefix = HTTPErrorBodyDebug.bodyPrefixString(from: error, maxChars: 300) {
            AppLog.api.error("[DistrictVerificationService] submit failed body=\(bodyPrefix, privacy: .private)")
        }

        if let code = APIErrorResponse.errorCode(from: error),
           let copy = AuthErrorMessages.message(forBackendCode: code) {
            return ServiceError.requestFailed(copy)
        }

        guard let status = APIErrorDebug.httpStatusCode(from: error) else {
            if APIErrorResponse.isNetworkFailure(error) {
                return ServiceError.requestFailed(AuthErrorMessages.network)
            }
            return ServiceError.requestFailed("We couldn't verify your district. Please try again.")
        }

        switch status {
        case 400:
            return ServiceError.invalidInput("Check the address or district you entered and try again.")
        case 401:
            return ServiceError.notSignedIn
        case 403:
            return ServiceError.requestFailed("This account can't update its district right now.")
        case 422:
            return ServiceError.invalidInput(addressNotFoundMessage)
        case 429:
            return ServiceError.requestFailed(AuthErrorMessages.tooManyAttempts)
        case 500...599:
            return ServiceError.requestFailed("District verification is unavailable right now. Please try again in a moment.")
        default:
            return ServiceError.requestFailed("We couldn't verify your district. Please try again.")
        }
    }

    private struct ManualSelectionRequest: Encodable {
        let state: String
        let district: String
    }

    private struct AddressVerificationRequest: Encodable {
        let line1: String
        let line2: String?
        let city: String
        let state: String
        let zip: String
        let claimedDistrict: String?
    }
}
