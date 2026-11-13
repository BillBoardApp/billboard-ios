import Amplify
import AWSAPIPlugin
import Foundation

enum HTTPErrorBodyDebug {
    /// Best-effort extraction of HTTP response body from nested/underlying errors.
    /// Amplify's REST plugin returns the body on `AWSHTTPURLResponse`; other
    /// plugins sometimes stash it on an underlying error.
    static func extractResponseBody(from error: Error) -> Data? {
        if let apiError = error as? APIError,
           case let .httpStatusError(_, response) = apiError,
           let awsResponse = response as? AWSHTTPURLResponse,
           let body = awsResponse.body,
           !body.isEmpty {
            return body
        }

        // Walk a few levels of underlying errors.
        var current: Error? = error
        for _ in 0..<5 {
            guard let e = current else { break }

            if let data = extractData(from: e) {
                return data
            }

            if let amplify = e as? AmplifyError {
                current = amplify.underlyingError
                continue
            }

            if let api = e as? APIError {
                current = api.underlyingError
                continue
            }

            let ns = e as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
                current = underlying
                continue
            }

            break
        }

        return nil
    }

    static func bodyPrefixString(from error: Error, maxChars: Int = 800) -> String? {
        guard let data = extractResponseBody(from: error) else { return nil }
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        return String(str.prefix(maxChars))
    }

    private static func extractData(from error: Error) -> Data? {
        // 1) Check NSError userInfo for any Data payloads.
        let ns = error as NSError
        for (_, value) in ns.userInfo {
            if let data = value as? Data, !data.isEmpty {
                return data
            }
        }

        // 2) Best-effort reflection for common property names.
        let mirror = Mirror(reflecting: error)
        for child in mirror.children {
            guard let label = child.label else { continue }
            if label == "responseData" || label == "data" || label == "body",
               let data = child.value as? Data,
               !data.isEmpty {
                return data
            }
        }

        return nil
    }
}
