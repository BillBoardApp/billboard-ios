import Foundation

/// Why a bills-manifest snapshot could not be used. `BillsService` requests a new pointer once after
/// `isRejectedURL`; otherwise the error fails the manifest load.
nonisolated enum ManifestSnapshotError: Error, Equatable {
    /// `snapshotUrl` is not an https URL.
    case invalidURL
    /// The response was not HTTP.
    case notHTTP
    /// S3 answered with a status outside 2xx: 403 for an expired or revoked presigned URL, 400 for
    /// a malformed one.
    case httpStatus(Int)
    /// The body still starts with the gzip magic bytes: S3 served it without `Content-Encoding: gzip`,
    /// so URLSession did not decode it.
    case gzipBodyNotDecoded

    /// S3 rejected the presigned URL: 403 once it expired (or was revoked), 400 when it is malformed.
    /// A new pointer carries a new URL.
    var isRejectedURL: Bool {
        if case .httpStatus(let status) = self { return status == 403 || status == 400 }
        return false
    }

    /// A log-safe reason for `error`: never the URL, which carries the presigned signature.
    static func logReason(for error: Error) -> String {
        switch error {
        case let failure as ManifestSnapshotError:
            switch failure {
            case .invalidURL: return "snapshotUrl is not an https URL"
            case .notHTTP: return "response is not HTTP"
            case .httpStatus(let status): return "HTTP \(status)"
            case .gzipBodyNotDecoded: return "body is gzip without Content-Encoding"
            }
        case let urlError as URLError:
            return "URLError \(urlError.code.rawValue)"
        case is DecodingError:
            return "pointer does not decode"
        case let apiError as APIServiceError where apiError == .invalidPayload("bills-manifest"):
            return "snapshot body does not decode"
        default:
            return "unexpected \(String(describing: type(of: error)))"
        }
    }
}

/// Downloads the full bills manifest from the presigned S3 URL in a `BillsManifestSnapshotPointer`.
///
/// The URL carries its own signature, and S3 rejects a request that also carries an Authorization
/// header, so the download never goes through `APIClient` or Amplify (which add the Cognito token).
/// It uses a dedicated ephemeral `URLSession` with no cookie, credential or response cache storage,
/// and a request that sets no auth header. S3 serves the body with `Content-Encoding: gzip`, which
/// URLSession decodes before returning it.
///
/// `BillsService` reads `BillsManifestSnapshotClient.current`; tests replace it for one call tree with
/// `BillsManifestSnapshotClient.$current.withValue(...)`.
nonisolated struct BillsManifestSnapshotClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @TaskLocal static var current = BillsManifestSnapshotClient()

    /// Time allowed between bytes, and for the whole download (the snapshot runs to a few MB).
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 90

    /// The session configuration the live client uses.
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    static let liveSession = URLSession(configuration: makeSessionConfiguration())

    private let transport: Transport

    init(session: URLSession = BillsManifestSnapshotClient.liveSession) {
        transport = { request in try await session.data(for: request) }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    /// The GET for `url`: an Accept header and nothing else.
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The decoded body of a 2xx response; `ManifestSnapshotError` or the URLSession error otherwise.
    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await transport(Self.request(for: url))
        guard let http = response as? HTTPURLResponse else { throw ManifestSnapshotError.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw ManifestSnapshotError.httpStatus(http.statusCode) }
        guard !data.starts(with: [0x1F, 0x8B]) else { throw ManifestSnapshotError.gzipBodyNotDecoded }
        return data
    }
}
