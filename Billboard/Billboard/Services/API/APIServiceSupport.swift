import Amplify
import AWSPluginsCore
import Foundation
import os

enum APIAuthVariant: String {
    case bearerID = "Bearer id"
    case bearerAccess = "Bearer access"
}

enum APIAuthCandidatePolicy {
    /// Send only the Cognito ID token. The API Gateway Cognito authorizer declares
    /// no authorization scopes, and without scopes it validates ID tokens only, so
    /// this is the default for every route.
    case idTokenOnly
    /// Send only the access token. Only for a route whose authorizer declares
    /// OAuth scopes (none do today).
    case accessTokenOnly
}

struct APIAuthCandidate: Equatable {
    let value: String
    let variant: APIAuthVariant
}

struct APIResolvedAuthCandidates {
    let candidates: [APIAuthCandidate]
    let sessionIsSignedIn: Bool
    let usedForceRefresh: Bool
}

enum APIAuthHeaders {
    /// The Authorization header value for `policy`, or an empty list when the
    /// session is signed out or has no Cognito tokens.
    static func candidates(
        from session: AuthSession,
        policy: APIAuthCandidatePolicy = .idTokenOnly
    ) throws -> [APIAuthCandidate] {
        guard session.isSignedIn else { return [] }
        guard let tokensProvider = session as? AuthCognitoTokensProvider else {
            return []
        }

        switch tokensProvider.getCognitoTokens() {
        case .success(let tokens):
#if DEBUG
            JWTDebug.logTokensOnce(accessToken: tokens.accessToken, idToken: tokens.idToken)
#endif
            switch policy {
            case .idTokenOnly:
                return [APIAuthCandidate(value: "Bearer \(tokens.idToken)", variant: .bearerID)]
            case .accessTokenOnly:
                return [APIAuthCandidate(value: "Bearer \(tokens.accessToken)", variant: .bearerAccess)]
            }
        case .failure:
            return []
        }
    }
}

// MARK: - Shared Request

/// The transport behind `APIClient`; services call the client rather than this.
///
/// Sends one token (the ID token by default). A 401 on a signed-in session gets
/// one forced session refresh and one resend; a 403 is final. Idempotent GETs
/// get one retry after a short backoff on a network failure or an HTTP 5xx;
/// POST, PUT and DELETE are never retried.
///
/// Every request carries `X-Billboard-App-Version` (spec C3 3.8; only these API Gateway requests,
/// integration plan X16: never the presigned snapshot GET, the share site or push registration).
/// A 426 `APP_UPDATE_REQUIRED` posts `.billboardAppUpdateRequired` once per launch (spec D 2.8.1).
enum APIRequest {
    enum AuthResolutionError: LocalizedError {
        case notSignedIn
        case signedInWithoutTokens

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in."
            case .signedInWithoutTokens:
                return "Signed in, but no Cognito auth tokens were available."
            }
        }
    }

    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    enum AuthMode {
        /// Fetch a fresh session and generate candidates. Falls back to unauthenticated if no session.
        case autoFetch
        /// Use a pre-fetched session. Throws if not signed in.
        case requireSignedIn
    }

    /// Execute a REST request.
    ///
    /// - Parameters:
    ///   - method: HTTP method.
    ///   - path: API path (e.g. "bills-manifest").
    ///   - queryParameters: Optional query parameters.
    ///   - body: Optional request body.
    ///   - label: Logging label for diagnostics (e.g. "BillsService bills-manifest").
    ///   - authMode: How to obtain the Authorization header.
    ///   - authPolicy: Which Cognito token to send. Defaults to the ID token, the only
    ///     token the API's authorizer accepts.
    ///   - extraHeaders: Headers for this request only (the App Attest header on `POST /feedback`).
    ///     They never replace `Authorization`, `Accept`, `Content-Type` or the version header.
    ///   - fallbackError: Error to throw if no attempt produced a more specific one.
    ///   - traceTimeline: Record the auth and HTTP stages as Home startup timeline marks
    ///     (`HomePerfTimeline`, Debug only). Only the bills manifest request sets it.
    /// - Returns: Response data.
    static func withAuthFallback(
        method: Method = .get,
        path: String,
        queryParameters: [String: String]? = nil,
        body: Data? = nil,
        label: String,
        authMode: AuthMode = .autoFetch,
        authPolicy: APIAuthCandidatePolicy = .idTokenOnly,
        extraHeaders: [String: String] = [:],
        fallbackError: Error,
        traceTimeline: Bool = false
    ) async throws -> Data {
        var authResolution = try await resolveAuthCandidates(
            authMode: authMode,
            forceRefresh: false,
            label: label,
            authPolicy: authPolicy,
            traceTimeline: traceTimeline
        )
        var didRetryTransientFailure = false
        var lastError: Error?

        // At most three sends: the first, one after a forced session refresh on a
        // 401, and one retry of a GET after a transient failure.
        for attempt in 1...3 {
            let authorization = authResolution.candidates.first
            let variantLabel = authorization?.variant.rawValue ?? "none"

            AppLog.api.debug("[\(label, privacy: .public)] \(method.rawValue, privacy: .public) \(path, privacy: .public) attempt=\(attempt) auth=\(variantLabel, privacy: .public) query=\(String(describing: queryParameters ?? [:]), privacy: .private)")
            if traceTimeline {
                HomePerfTimeline.mark("manifest_http_attempt_started", detail: "attempt=\(attempt) auth=\(variantLabel)")
            }

            do {
                let data = try await send(
                    method: method,
                    path: path,
                    queryParameters: queryParameters,
                    body: body,
                    authorization: authorization,
                    extraHeaders: extraHeaders
                )
                AppLog.api.debug("[\(label, privacy: .public)] success attempt=\(attempt) bytes=\(data.count)")
                if traceTimeline {
                    HomePerfTimeline.mark(
                        "manifest_http_payload_received",
                        detail: "attempt=\(attempt) auth=\(variantLabel) bytes=\(data.count)"
                    )
                }
                return data
            } catch {
                // A cancelled request is neither retried nor logged as a failure (APPF-22).
                if let cancellation = APIErrorResponse.cancellation(from: error) { throw cancellation }
                lastError = error

                let status = APIErrorDebug.httpStatusCode(from: error)
                logFailure(error, status: status, label: label, method: method, path: path)

                // Under enforce the server refuses this build. The blocking update alert, once per launch.
                if isAppUpdateRequired(status: status, code: status == nil ? nil : APIErrorResponse.errorCode(from: error)) {
                    AppLog.api.error("[\(label, privacy: .public)] HTTP 426 APP_UPDATE_REQUIRED; asking for an update")
                    AppUpdateRequiredSignal.shared.post()
                }

                if status == 401,
                   authResolution.sessionIsSignedIn,
                   !authResolution.usedForceRefresh {
                    AppLog.api.info("[\(label, privacy: .public)] 401; refreshing the session and resending once")
                    if traceTimeline {
                        HomePerfTimeline.mark(
                            "manifest_http_attempt_retrying_auth",
                            detail: "attempt=\(attempt) auth=\(variantLabel) status=401 forceRefresh=true"
                        )
                    }
                    authResolution = try await resolveAuthCandidates(
                        authMode: authMode,
                        forceRefresh: true,
                        label: label,
                        authPolicy: authPolicy,
                        traceTimeline: traceTimeline
                    )
                    continue
                }

                if method == .get,
                   !didRetryTransientFailure,
                   isTransientFailure(error, status: status) {
                    didRetryTransientFailure = true
                    AppLog.api.info("[\(label, privacy: .public)] transient failure; retrying GET once")
                    try await Task.sleep(nanoseconds: UInt64.random(in: 300_000_000...700_000_000))
                    continue
                }

                throw error
            }
        }

        throw lastError ?? fallbackError
    }

    /// True for the minimum-version gate's answer: HTTP 426 with `APP_UPDATE_REQUIRED` (spec C3 3.8, 4.5).
    nonisolated static func isAppUpdateRequired(status: Int?, code: String?) -> Bool {
        status == 426 && code == AppAttestServerCode.appUpdateRequired.rawValue
    }

    private static func send(
        method: Method,
        path: String,
        queryParameters: [String: String]?,
        body: Data?,
        authorization: APIAuthCandidate?,
        extraHeaders: [String: String]
    ) async throws -> Data {
        let headers = APIRequestHeaders.make(
            authorization: authorization?.value,
            hasBody: body != nil,
            extraHeaders: extraHeaders,
            appVersion: APIRequestHeaders.appVersion
        )

        let request = RESTRequest(
            apiName: "myapi",
            path: path,
            headers: headers,
            queryParameters: queryParameters,
            body: body
        )

        switch method {
        case .get:
            return try await Amplify.API.get(request: request)
        case .post:
            return try await Amplify.API.post(request: request)
        case .put:
            return try await Amplify.API.put(request: request)
        case .delete:
            return try await Amplify.API.delete(request: request)
        }
    }

    /// Network failures (timeouts, lost or missing connectivity) and HTTP 5xx.
    static func isTransientFailure(_ error: Error, status: Int?) -> Bool {
        if let status {
            return (500...599).contains(status)
        }
        return APIErrorResponse.isNetworkFailure(error)
    }

    private static func logFailure(_ error: Error, status: Int?, label: String, method: Method, path: String) {
        if let status {
            if status == 404 {
                // Expected for some lookups (for example locator fallbacks).
                AppLog.api.info("[\(label, privacy: .public)] \(method.rawValue, privacy: .public) \(path, privacy: .public) HTTP 404")
            } else {
                AppLog.api.error("[\(label, privacy: .public)] \(method.rawValue, privacy: .public) \(path, privacy: .public) HTTP \(status)")
            }
            if let bodyPrefix = HTTPErrorBodyDebug.bodyPrefixString(from: error, maxChars: 300) {
                AppLog.api.debug("[\(label, privacy: .public)] body prefix: \(bodyPrefix, privacy: .private)")
            }
        } else {
            let description = String(describing: error)
            AppLog.api.error("[\(label, privacy: .public)] \(method.rawValue, privacy: .public) \(path, privacy: .public) failed: \(description, privacy: .private)")
        }
    }

    private static func resolveAuthCandidates(
        authMode: AuthMode,
        forceRefresh: Bool,
        label: String,
        authPolicy: APIAuthCandidatePolicy,
        traceTimeline: Bool
    ) async throws -> APIResolvedAuthCandidates {
        if traceTimeline {
            HomePerfTimeline.mark("manifest_auth_candidates_fetch_started", detail: "forceRefresh=\(forceRefresh)")
        }

        let session = try await Amplify.Auth.fetchAuthSession(
            options: forceRefresh ? .forceRefresh() : nil
        )

        guard session.isSignedIn else {
            switch authMode {
            case .autoFetch:
                if traceTimeline {
                    HomePerfTimeline.mark(
                        "manifest_auth_candidates_ready",
                        detail: "count=0 signedIn=false forceRefresh=\(forceRefresh)"
                    )
                }
                return APIResolvedAuthCandidates(
                    candidates: [],
                    sessionIsSignedIn: false,
                    usedForceRefresh: forceRefresh
                )
            case .requireSignedIn:
                throw AuthResolutionError.notSignedIn
            }
        }

        let candidates = (try? APIAuthHeaders.candidates(from: session, policy: authPolicy)) ?? []
        if !candidates.isEmpty {
            if traceTimeline {
                HomePerfTimeline.mark(
                    "manifest_auth_candidates_ready",
                    detail: "count=\(candidates.count) signedIn=true forceRefresh=\(forceRefresh)"
                )
            }
            return APIResolvedAuthCandidates(
                candidates: candidates,
                sessionIsSignedIn: true,
                usedForceRefresh: forceRefresh
            )
        }

        if !forceRefresh {
            AppLog.auth.info("[\(label, privacy: .public)] signed-in session had no tokens; force-refreshing")
            return try await resolveAuthCandidates(
                authMode: authMode,
                forceRefresh: true,
                label: label,
                authPolicy: authPolicy,
                traceTimeline: traceTimeline
            )
        }

        AppLog.auth.error("[\(label, privacy: .public)] session still has no tokens after refresh; invalidating")
        NotificationCenter.default.post(
            name: .billboardAuthSessionInvalidated,
            object: nil,
            userInfo: ["message": "Your session expired. Please sign in again."]
        )
        throw AuthResolutionError.signedInWithoutTokens
    }
}

// MARK: - Headers

/// The headers of one API request (`APIRequest.send`). Pure, for `APIRequestShapeTests`.
nonisolated enum APIRequestHeaders {
    static let acceptName = "Accept"
    static let authorizationName = "Authorization"
    static let contentTypeName = "Content-Type"
    static let appVersionName = AppAttestWire.appVersionHeader

    /// This build's `CFBundleShortVersionString` as `X-Billboard-App-Version` carries it, or nil when it is
    /// not a valid `AppVersion` (then the header is left out).
    static let appVersion: String? = AppAttestWire.currentAppVersion

    /// Names a request's extra headers may not set, in lower case (header names are case-insensitive).
    static let reservedNames: Set<String> = [acceptName, authorizationName, contentTypeName, appVersionName].reduce(into: []) {
        $0.insert($1.lowercased())
    }

    /// `Accept: application/json`, `Authorization` when there is a token, `Content-Type: application/json`
    /// with a body, `X-Billboard-App-Version` when the version is known, and every extra header whose name
    /// is not one of those (in any letter case): an extra header can never replace or add the token.
    static func make(
        authorization: String?,
        hasBody: Bool,
        extraHeaders: [String: String],
        appVersion: String?
    ) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in extraHeaders where !reservedNames.contains(name.lowercased()) {
            headers[name] = value
        }
        headers[acceptName] = "application/json"
        if let authorization {
            headers[authorizationName] = authorization
        }
        if hasBody {
            headers[contentTypeName] = "application/json"
        }
        if let appVersion {
            headers[appVersionName] = appVersion
        }
        return headers
    }
}

// MARK: - Decoding

/// Nonisolated so services can decode large payloads (the bills manifest) off the main actor.
nonisolated enum APIDecoding {
    /// Decodes `type`, logging the decode failure (type, coding path, reason)
    /// through `AppLog.api` before rethrowing it.
    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        decoder: JSONDecoder = .usingDefaultKeys(),
        label: String
    ) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            AppLog.decodingFailure(error, decoding: type, label: label)
            throw error
        }
    }
}

// MARK: - Error Responses

enum APIErrorResponse {
    /// Raw body of an HTTP error response, when Amplify kept it.
    static func body(from error: Error) -> Data? {
        HTTPErrorBodyDebug.extractResponseBody(from: error)
    }

    /// Machine-readable error code from a backend error body such as
    /// `{"error": "ADULT_STATUS_LOCKED", "message": "..."}` (optionally wrapped in a
    /// proxy `body` string). Only upper-snake-case codes are returned; free-text
    /// messages are never surfaced, since they are not written for users.
    static func errorCode(from error: Error) -> String? {
        guard let data = body(from: error),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let code = errorCode(in: object) {
            return code
        }

        if let wrappedData = APIEnvelope.payload(in: data),
           let wrappedObject = try? JSONSerialization.jsonObject(with: wrappedData) as? [String: Any] {
            return errorCode(in: wrappedObject)
        }

        return nil
    }

    /// True for a transport failure (offline, timeout, lost connection) as opposed
    /// to an HTTP error response.
    static func isNetworkFailure(_ error: Error) -> Bool {
        let transientCodes: Set<URLError.Code> = [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet
        ]

        var current: Error? = error
        for _ in 0..<4 {
            guard let candidate = current else { return false }
            if let urlError = candidate as? URLError {
                return transientCodes.contains(urlError.code)
            }
            if let apiError = candidate as? APIError, case let .networkError(_, _, underlying) = apiError {
                guard let urlError = underlying as? URLError else { return true }
                return transientCodes.contains(urlError.code)
            }
            if let amplifyError = candidate as? AmplifyError {
                current = amplifyError.underlyingError
                continue
            }
            current = (candidate as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }

    /// True when `error`, or an error it wraps, is a cancellation: Swift's `CancellationError`,
    /// URLSession's `URLError.cancelled`, which a cancelled task's request throws instead, or
    /// Amplify's `OperationCancelledError`, which a cancelled Amplify operation reports.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        var current: Error? = error
        for _ in 0..<4 {
            guard let candidate = current else { return false }
            if candidate is CancellationError || candidate is OperationCancelledError { return true }
            if let urlError = candidate as? URLError { return urlError.code == .cancelled }
            if let apiError = candidate as? APIError, case let .networkError(_, _, underlying) = apiError {
                current = underlying
                continue
            }
            if let amplifyError = candidate as? AmplifyError {
                current = amplifyError.underlyingError
                continue
            }
            current = (candidate as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return false
    }

    /// The `CancellationError` a failed request surfaces as when it was cancelled, else nil (APPF-22).
    ///
    /// A request counts as cancelled when its error is a cancellation (`isCancellation`: Amplify reports
    /// one as an `APIError` wrapping `URLError.cancelled`) or when the calling task was cancelled, since
    /// the screen that asked for it is gone. Callers then only need to check for `CancellationError`.
    nonisolated static func cancellation(from error: Error) -> CancellationError? {
        if let cancellation = error as? CancellationError { return cancellation }
        if Task.isCancelled || isCancellation(error) { return CancellationError() }
        return nil
    }

    private static func errorCode(in object: [String: Any]) -> String? {
        for key in ["error", "code", "errorCode"] {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: #"^[A-Z][A-Z0-9_]{1,63}$"#, options: .regularExpression) != nil {
                return trimmed
            }
        }
        return nil
    }
}

// MARK: - Error Debug

enum APIErrorDebug {
    static func httpStatusCode(from error: Error) -> Int? {
        guard let apiError = error as? APIError else { return nil }
        if case let .httpStatusError(status, _) = apiError {
            return status
        }
        return nil
    }

    static func debugString(for error: Error) -> String {
        if let apiError = error as? APIError {
            var parts: [String] = []
            parts.append(apiError.errorDescription)
            parts.append("Suggestion: \(apiError.recoverySuggestion)")

            if case let .httpStatusError(_, response) = apiError {
                if let url = response.url?.absoluteString {
                    parts.append("URL: \(url)")
                }

                let headers = response.allHeaderFields
                if !headers.isEmpty {
                    let headerLines = headers
                        .map { "\($0.key): \($0.value)" }
                        .sorted()
                        .joined(separator: "\n")
                    parts.append("Response headers:\n\(headerLines)")
                }
            }

            if let underlying = apiError.underlyingError {
                parts.append("Underlying: \(underlying.localizedDescription)")
            }

            if let bodyPrefix = HTTPErrorBodyDebug.bodyPrefixString(from: error) {
                parts.append("Response body prefix: \(bodyPrefix)")
            }

            return parts.joined(separator: "\n")
        }

        if let amplifyError = error as? AmplifyError {
            var parts: [String] = []
            parts.append(amplifyError.errorDescription)
            parts.append("Suggestion: \(amplifyError.recoverySuggestion)")
            if let underlying = amplifyError.underlyingError {
                parts.append("Underlying: \(underlying.localizedDescription)")
            }
            return parts.joined(separator: "\n")
        }

        let ns = error as NSError
        return "\(ns.domain) (code \(ns.code)): \(ns.localizedDescription)"
    }
}
