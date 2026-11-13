import Amplify
import Foundation

/// Plain-language copy for failed loads. Distinguishes "the device is offline" from
/// other failures so screens never show raw SDK text.
enum UserFacingLoadError {
    nonisolated private static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .dataNotAllowed,
        .internationalRoamingOff,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .timedOut
    ]

    /// Message for a failed load of `subject` (e.g. "your bills", "this bill").
    nonisolated static func message(for error: Error, loading subject: String) -> String {
        if isConnectivityProblem(error) {
            return "Can't reach Billboard right now. Check your connection and try again."
        }
        return "We couldn't load \(subject) right now. Try again in a moment."
    }

    /// True when the error, or an error it wraps, means the server could not be reached.
    nonisolated static func isConnectivityProblem(_ error: Error) -> Bool {
        var current: Error? = error
        for _ in 0..<5 {
            guard let candidate = current else { break }

            if let urlError = candidate as? URLError {
                return connectivityCodes.contains(urlError.code)
            }

            if let apiError = candidate as? APIError {
                current = apiError.underlyingError
                continue
            }

            if let amplifyError = candidate as? AmplifyError {
                current = amplifyError.underlyingError
                continue
            }

            let nsError = candidate as NSError
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                current = underlying
                continue
            }

            break
        }
        return false
    }
}
