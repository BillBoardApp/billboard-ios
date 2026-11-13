import Foundation

// MARK: - Client

/// The REST client every API service uses.
///
/// Requests go through `APIRequest.withAuthFallback` (ID token, one forced refresh
/// on a 401, one retry of a GET after a transient failure). Every response takes the
/// same decode path: a proxy envelope (`{"body": "<json>"}`) is unwrapped once by
/// `APIEnvelope`, then the payload is decoded with a decoder from the `JSONDecoder`
/// factory, and a decode failure is logged before it is rethrown (`APIDecoding`).
///
/// Services read `APIClient.current`. Tests replace the transport for one call tree
/// with `APIClient.$current.withValue(APIClient(transport: ...)) { ... }`.
struct APIClient: Sendable {
    /// One request as the services describe it; the transport sends it.
    struct Request: Equatable, Sendable {
        let method: APIRequest.Method
        let path: String
        let queryParameters: [String: String]?
        let body: Data?
        let label: String
        let authMode: APIRequest.AuthMode
        let traceTimeline: Bool
        /// Headers this request adds to the ones every request carries, such as the App Attest
        /// header on `POST /feedback` (spec C3 3.10). They never replace `Authorization`, `Accept`,
        /// `Content-Type` or the app version header (`APIRequestHeaders`).
        let headers: [String: String]

        nonisolated init(
            method: APIRequest.Method,
            path: String,
            queryParameters: [String: String]?,
            body: Data?,
            label: String,
            authMode: APIRequest.AuthMode,
            traceTimeline: Bool,
            headers: [String: String] = [:]
        ) {
            self.method = method
            self.path = path
            self.queryParameters = queryParameters
            self.body = body
            self.label = label
            self.authMode = authMode
            self.traceTimeline = traceTimeline
            self.headers = headers
        }
    }

    typealias Transport = @Sendable (Request) async throws -> Data

    @TaskLocal static var current = APIClient()

    private let transport: Transport

    nonisolated init(transport: @escaping Transport = APIClient.liveTransport) {
        self.transport = transport
    }

    /// Sends a request and returns the response payload, with any proxy envelope unwrapped.
    ///
    /// A cancelled request, or any failure once the calling task is cancelled, throws `CancellationError`
    /// (APPF-22, `APIErrorResponse.cancellation(from:)`): Amplify reports a cancelled request as an
    /// `APIError` wrapping `URLError.cancelled`, and callers check for a cancellation to stay quiet when
    /// the screen that asked for the data is gone. Every other error passes through unchanged.
    ///
    /// - Parameters:
    ///   - method: HTTP method.
    ///   - path: API path (e.g. "bills-manifest").
    ///   - query: Query parameters. `RESTRequest` encodes them; do not pre-encode.
    ///   - body: JSON request body.
    ///   - label: Logging label for diagnostics (e.g. "BillsService bills-manifest").
    ///   - authMode: `.requireSignedIn` for Cognito routes; `.autoFetch` for routes a
    ///     signed-out session may call (it then sends no Authorization header).
    ///   - traceTimeline: Record auth and HTTP stages as Home startup timeline marks.
    ///   - headers: Extra headers for this request only (the App Attest header on `POST /feedback`).
    ///     They cannot replace `Authorization`, `Accept`, `Content-Type` or the app version header.
    @discardableResult
    func payload(
        _ method: APIRequest.Method = .get,
        _ path: String,
        query: [String: String]? = nil,
        body: Data? = nil,
        label: String,
        authMode: APIRequest.AuthMode = .requireSignedIn,
        traceTimeline: Bool = false,
        headers: [String: String] = [:]
    ) async throws -> Data {
        let request = Request(
            method: method,
            path: path,
            queryParameters: query,
            body: body,
            label: label,
            authMode: authMode,
            traceTimeline: traceTimeline,
            headers: headers
        )
        let data: Data
        do {
            data = try await transport(request)
        } catch {
            throw APIErrorResponse.cancellation(from: error) ?? error
        }
        return APIEnvelope.unwrap(data)
    }

    /// Sends a request and decodes the payload as `type`. A decode failure is logged
    /// under `label` and rethrown as the `DecodingError`.
    func response<T: Decodable>(
        _ type: T.Type,
        _ method: APIRequest.Method = .get,
        _ path: String,
        query: [String: String]? = nil,
        body: Data? = nil,
        label: String,
        authMode: APIRequest.AuthMode = .requireSignedIn,
        headers: [String: String] = [:],
        decoder: JSONDecoder
    ) async throws -> T {
        let data = try await payload(method, path, query: query, body: body, label: label, authMode: authMode, headers: headers)
        return try APIDecoding.decode(type, from: data, decoder: decoder, label: label)
    }

    nonisolated static let liveTransport: Transport = { request in
        try await APIRequest.withAuthFallback(
            method: request.method,
            path: request.path,
            queryParameters: request.queryParameters,
            body: request.body,
            label: request.label,
            authMode: request.authMode,
            extraHeaders: request.headers,
            fallbackError: APIServiceError.invalidPayload(request.path),
            traceTimeline: request.traceTimeline
        )
    }
}

// MARK: - Errors

/// The error API services throw for their own failures. HTTP, network and auth errors
/// from `APIRequest` pass through unchanged, except a cancelled request, which surfaces as
/// `CancellationError` (`APIClient.payload`). Descriptions are for logs; screens show
/// their own copy (see `UserFacingLoadError`).
nonisolated enum APIServiceError: LocalizedError, Equatable {
    case notSignedIn
    /// The response for `path` was empty or had no shape the service understands.
    case invalidPayload(_ path: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in. This endpoint requires Cognito User Pools auth."
        case .invalidPayload(let path):
            return "Unexpected response from /\(path)"
        }
    }
}

// MARK: - Proxy envelope

/// A Lambda proxy response that reached the app without API Gateway unwrapping it
/// carries the real payload in `body`, as a JSON string or as a JSON value.
nonisolated enum APIEnvelope {
    /// The payload inside an envelope, or `data` itself when it is not one.
    static func unwrap(_ data: Data) -> Data {
        payload(in: data) ?? data
    }

    /// The payload inside `{"body": "<json>"}` or `{"body": {...}}`, or nil when `data`
    /// is not an object with a non-empty `body`.
    static func payload(in data: Data) -> Data? {
        // Cheap byte check first so large payloads (the bills manifest runs to
        // megabytes) are not parsed twice.
        guard mayContainBodyKey(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["body"] else {
            return nil
        }

        if let bodyString = body as? String {
            let inner = Data(bodyString.utf8)
            return inner.isEmpty ? nil : inner
        }

        if JSONSerialization.isValidJSONObject(body) {
            return try? JSONSerialization.data(withJSONObject: body)
        }

        return nil
    }

    private static let bodyKey = Array(#""body""#.utf8)

    /// True when `data` starts with `{` and contains the bytes `"body"` somewhere.
    private static func mayContainBodyKey(_ data: Data) -> Bool {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard let first = data.first(where: { !whitespace.contains($0) }),
              first == UInt8(ascii: "{") else {
            return false
        }
        return data.withUnsafeBytes { haystack in
            bodyKey.withUnsafeBytes { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }
}
