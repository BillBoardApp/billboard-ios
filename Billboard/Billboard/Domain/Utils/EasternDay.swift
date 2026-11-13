import Foundation

/// The day in America/New_York (UX-39 N11): when it turns over while the app is open, the Civic Score,
/// the streak and the Civic Profile are read again, so last night's figures do not stay up all morning.
nonisolated enum EasternDay {
    static let timeZone = CongressCalendar.timeZone

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "2026-10-28": the Eastern calendar day `date` falls on.
    static func key(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The Eastern midnight that starts the day after `date`'s (a 23- or 25-hour day across a clock change).
    static func nextStart(after date: Date) -> Date {
        let calendar = calendar
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(24 * 3600)
    }
}
