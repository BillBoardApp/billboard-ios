import Foundation

/// Which Congress and session a date falls in (Civic Record spec 3.21). Computed, never typed, so the
/// Bills masthead's dateline, the Congress deck line and any "119th Congress" copy roll over by
/// themselves when a new Congress meets.
///
/// A Congress meets on January 3 of every odd year (20th Amendment) and has two sessions, one per
/// year. In the America/New_York time zone, let `y` be the date's year, minus 1 when the date is
/// before January 3; the Congress is `(y - 1789) / 2 + 1` (integer division) and the session is the
/// 1st when `y` is odd, else the 2nd. Saturday, October 17, 2026 is in the 119th Congress, 2nd
/// session; January 3, 2027 starts the 120th Congress, 1st session.
nonisolated enum CongressCalendar {
    /// Congress keeps Washington's calendar.
    static let timeZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!

    /// A Congress and its session.
    struct Session: Equatable, Sendable {
        /// The Congress, such as 119.
        let congress: Int
        /// The session, 1 or 2.
        let session: Int

        /// "119th Congress".
        var congressTitle: String { "\(SpokenForm.ordinal(congress)) Congress" }

        /// "2nd session".
        var sessionTitle: String { "\(SpokenForm.ordinal(session)) session" }

        /// "119th Congress · 2nd session": the masthead's right-hand dateline (the `dateline` role
        /// sets it in capitals).
        var title: String { "\(congressTitle) · \(sessionTitle)" }

        /// "119th Congress, 2nd session": what VoiceOver reads for `title`.
        var spokenTitle: String { "\(congressTitle), \(sessionTitle)" }
    }

    /// The Congress and session on `date`.
    static func session(on date: Date) -> Session {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 1789
        let isBeforeJanuaryThird = parts.month == 1 && (parts.day ?? 1) < 3
        let sessionYear = isBeforeJanuaryThird ? year - 1 : year
        let congress = (sessionYear - 1789) / 2 + 1
        let session = sessionYear % 2 == 1 ? 1 : 2
        return Session(congress: congress, session: session)
    }
}
