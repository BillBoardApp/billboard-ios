import Foundation
import os

/// Unified logging for the app, backed by `os.Logger`.
///
/// Filter in Console.app, or with `log stream --predicate 'subsystem == "<bundle id>"'`.
/// Interpolated values are redacted in release logs unless marked `privacy: .public`,
/// so keep user identifiers, emails, tokens, query strings and response bodies private.
enum AppLog {
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.billboardproject.app"

    /// REST requests, retries, HTTP failures and decode failures.
    nonisolated static let api = Logger(subsystem: subsystem, category: "api")
    /// Sign-in, sign-out, session and account lifecycle.
    nonisolated static let auth = Logger(subsystem: subsystem, category: "auth")
    /// APNs registration and push handling.
    nonisolated static let push = Logger(subsystem: subsystem, category: "push")
    /// Local persistence: Keychain, on-disk caches and stores.
    nonisolated static let store = Logger(subsystem: subsystem, category: "store")
    /// MetricKit crash, hang and resource-exception summaries.
    nonisolated static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}

// MARK: - Decode failures

extension AppLog {
    /// Logs why a response could not be decoded: the target type, the failing
    /// coding path and the decoder's explanation. The type, key and path are
    /// field names and are logged publicly; the debug description can quote
    /// response values, so it stays private.
    nonisolated static func decodingFailure(
        _ error: Error,
        decoding type: Any.Type,
        label: String,
        logger: Logger = AppLog.api
    ) {
        let typeName = String(describing: type)

        guard let decodingError = error as? DecodingError else {
            let detail = String(describing: error)
            logger.error("[\(label, privacy: .public)] decode \(typeName, privacy: .public) failed: \(detail, privacy: .private)")
            return
        }

        switch decodingError {
        case .typeMismatch(let expected, let context):
            let expectedName = String(describing: expected)
            let path = codingPathDescription(context.codingPath)
            logger.error("[\(label, privacy: .public)] decode \(typeName, privacy: .public) typeMismatch expected=\(expectedName, privacy: .public) path=\(path, privacy: .public) detail=\(context.debugDescription, privacy: .private)")
        case .valueNotFound(let expected, let context):
            let expectedName = String(describing: expected)
            let path = codingPathDescription(context.codingPath)
            logger.error("[\(label, privacy: .public)] decode \(typeName, privacy: .public) valueNotFound expected=\(expectedName, privacy: .public) path=\(path, privacy: .public) detail=\(context.debugDescription, privacy: .private)")
        case .keyNotFound(let key, let context):
            let path = codingPathDescription(context.codingPath)
            logger.error("[\(label, privacy: .public)] decode \(typeName, privacy: .public) keyNotFound key=\(key.stringValue, privacy: .public) path=\(path, privacy: .public) detail=\(context.debugDescription, privacy: .private)")
        case .dataCorrupted(let context):
            let path = codingPathDescription(context.codingPath)
            logger.error("[\(label, privacy: .public)] decode \(typeName, privacy: .public) dataCorrupted path=\(path, privacy: .public) detail=\(context.debugDescription, privacy: .private)")
        @unknown default:
            let detail = String(describing: decodingError)
            logger.error("[\(label, privacy: .public)] decode \(typeName, privacy: .public) failed: \(detail, privacy: .private)")
        }
    }

    /// Renders a coding path as `bills[3].status`, or `(root)` when empty.
    nonisolated static func codingPathDescription(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "(root)" }

        var description = ""
        for key in codingPath {
            if let index = key.intValue {
                description += "[\(index)]"
            } else if description.isEmpty {
                description = key.stringValue
            } else {
                description += ".\(key.stringValue)"
            }
        }
        return description
    }
}
