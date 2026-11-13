import Foundation

/// The dates Civic Record prints in the docket and dateline faces: the slips' stubs, the bill page's
/// Actions ledger, Updates' Recent actions rows, the ballot stamp and the masthead. One rule for all of
/// them: the reader's region, from a template ("MMMd" gives "Oct 14" in the US and "14 Oct" in the UK).
/// Updates' rows were fixed to US order while the masthead above them and the slips followed the region,
/// so on an English (UK) phone the same Congress action read "14 OCT" on a slip and "OCT 14" in Updates.
/// `en_US_POSIX` stays only for parsing and for the Weekly Brief's server text.
nonisolated enum DocketDate {
    /// `date` from `template` in `locale` and `timeZone`. Formatters are made once per template, locale and
    /// time zone: a list draws many slips, each asking twice per render.
    static func string(_ date: Date, template: String, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        formatter(template, locale: locale, timeZone: timeZone).string(from: date)
    }

    /// A month and day ("Oct 14") as printed, and as VoiceOver reads it ("October 14"); with the year
    /// ("Oct 14, 2025", "October 14, 2025") when `date` is not in `now`'s year. The year is compared in
    /// `timeZone` for `date` and in `nowTimeZone` for `now` (a calendar day is read in UTC).
    static func monthDay(
        _ date: Date,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        nowTimeZone: TimeZone? = nil
    ) -> (printed: String, spoken: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var nowCalendar = Calendar(identifier: .gregorian)
        nowCalendar.timeZone = nowTimeZone ?? timeZone
        let sameYear = calendar.component(.year, from: date) == nowCalendar.component(.year, from: now)
        return (
            string(date, template: sameYear ? "MMMd" : "MMMdyyyy", locale: locale, timeZone: timeZone),
            string(date, template: sameYear ? "MMMMd" : "MMMMdyyyy", locale: locale, timeZone: timeZone)
        )
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    private static func formatter(_ template: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(timeZone.identifier)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter
    }
}
