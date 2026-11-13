import Foundation

/// Helper for parsing ISO-8601-ish timestamps coming from multiple backends.
/// Supports fractional seconds, timezone offsets, and basic internet date time.
///
/// The formatters are created once and never mutated afterwards: formatter creation dominated
/// parsing the bills manifest (two `updatedAt` parses per item), and Foundation's
/// `ISO8601DateFormatter` and `DateFormatter` are thread-safe for parsing once configured, so
/// `parse` can run on any thread.
enum FlexibleISO8601 {
    nonisolated(unsafe) private static let internetDateTimeWithFractionalSeconds = makeISO8601Formatter(
        [.withInternetDateTime, .withFractionalSeconds]
    )
    nonisolated(unsafe) private static let internetDateTime = makeISO8601Formatter([.withInternetDateTime])

    /// One formatter per fallback format, tried in order.
    nonisolated private static let fallbackFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    nonisolated private static func makeISO8601Formatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }

    nonisolated static func parse(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        if let date = internetDateTimeWithFractionalSeconds.date(from: raw) { return date }
        if let date = internetDateTime.date(from: raw) { return date }

        for formatter in fallbackFormatters {
            if let date = formatter.date(from: raw) { return date }
        }

        return nil
    }
}
