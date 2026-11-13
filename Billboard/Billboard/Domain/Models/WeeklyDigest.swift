import Foundation

enum WeeklyDigestSchedule {
    nonisolated static let timeZoneIdentifier = "America/New_York"
    nonisolated static let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: -5 * 60 * 60)!
    nonisolated static let releaseHour = 10
    nonisolated static let releaseMinute = 0

    nonisolated static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

struct WeeklyDigest: Identifiable, Codable, Equatable {
    enum Source: String, Codable {
        case remote
        case localFallback = "local_fallback"
    }

    let id: String
    let title: String
    let summary: String
    let weekStart: Date
    let weekEnd: Date
    let publishedAt: Date
    let source: Source
    var isRead: Bool
    let stats: [WeeklyDigestStat]
    let sections: [WeeklyDigestSection]

    nonisolated var publishedLabel: String {
        WeeklyDigestDateFormatter.publishedDate(publishedAt)
    }

    nonisolated var totalItemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }
}

struct WeeklyDigestStat: Identifiable, Codable, Equatable {
    enum Accent: String, Codable {
        case attention
        case movement
        case representative
        case discovery
        case neutral
    }

    let id: String
    let label: String
    let value: String
    let accent: Accent
}

struct WeeklyDigestSection: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case needsAttention = "needs_attention"
        case movedThisWeek = "moved_this_week"
        case representatives = "representatives"
        case worthQuickLook = "worth_quick_look"
    }

    let kind: Kind
    let title: String
    let subtitle: String?
    let items: [WeeklyDigestItem]

    var id: Kind { kind }
}

struct WeeklyDigestItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case bill
        case member
    }

    enum BillState: String, Codable {
        case new
        case updated
        case passed
        case failed
        case finalized
    }

    enum Accent: String, Codable {
        case attention
        case movement
        case representative
        case discovery
        case neutral
    }

    let id: String
    let kind: Kind
    let title: String
    let eyebrow: String?
    let summary: String
    let detail: String?
    let reason: String?
    let accent: Accent
    let billState: BillState?
    let billGuid: String?
    let primaryMemberBioguideID: String?

    var billID: UUID? {
        guard let billGuid else { return nil }
        return UUID.deterministic(from: billGuid)
    }
}

extension WeeklyDigestItem.BillState {
    /// The bill status the item's stamp shows: Became law for `finalized`.
    nonisolated var billStatus: BillStatus {
        switch self {
        case .new: return .new
        case .updated: return .updated
        case .passed: return .passed
        case .failed: return .failed
        case .finalized: return .finalized
        }
    }
}

extension WeeklyDigestItem {
    /// The bill's number for the item's docket line ("H.R. 77"), from its GovInfo guid; nil for a
    /// member item or a guid that is not a bill's.
    nonisolated var billNumber: String? {
        guard kind == .bill else { return nil }
        return BillDisplayFormatting.officialBillNumber(billType: nil, billNumber: nil, guid: billGuid)
    }

    /// The eyebrow as the Weekly Brief detail shows it (Civic Record spec 4.52): the date alone ("Oct
    /// 14"), since the docket line's stamp already says the status. The server and the local builder
    /// write "Updated Oct 14" or "Became law Oct 14", so a bill item's leading status word is dropped;
    /// any other eyebrow is kept as written. Nil for a member item (its eyebrow is a count, "2 relevant
    /// bills this week", which its summary already says) and when nothing is left.
    nonisolated var dateEyebrow: String? {
        guard kind == .bill, let eyebrow = eyebrow?.trimmingCharacters(in: .whitespacesAndNewlines), !eyebrow.isEmpty else {
            return nil
        }
        let statusWords = ["Became law", "Finalized", "Updated", "Passed", "Failed", "New"]
        for word in statusWords {
            guard eyebrow.range(of: word, options: [.anchored, .caseInsensitive]) != nil else { continue }
            let rest = eyebrow.dropFirst(word.count)
            guard rest.isEmpty || rest.first?.isWhitespace == true || rest.first == "·" else { continue }
            let date = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "·")))
            return date.isEmpty ? nil : date
        }
        return eyebrow
    }

    /// What VoiceOver reads for `dateEyebrow` (Civic Record spec 1.7, 7.3): the date named for what it is,
    /// with its month in full, "Last updated October 14", while the page shows "OCT 14". Both builders date
    /// the eyebrow from the bill's `storedAt`, the date a bill slip reads as "Last updated". An eyebrow
    /// that is not a month and a day is read as written.
    nonisolated var spokenDateEyebrow: String? {
        guard let date = dateEyebrow else { return nil }
        guard let spoken = WeeklyDigestDateFormatter.spokenMonthDay(date) else { return date }
        return "Last updated \(spoken)"
    }
}

enum WeeklyDigestDateFormatter {
    /// A short month and day as the brief's builders write them ("Oct 14"; also "Sept 3" and "Dec 30,
    /// 2025") with the month in full: "October 14", "September 3", "December 30, 2025". Nil when the text
    /// is not a month and a day.
    nonisolated static func spokenMonthDay(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let month = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard month.count >= 3,
              let fullMonth = formatter.monthSymbols.first(where: { $0.lowercased().hasPrefix(month) }) else { return nil }
        let rest = String(parts[1])
        guard let match = rest.wholeMatch(of: #/(\d{1,2})(, \d{4})?/#),
              let day = Int(match.1), (1...31).contains(day) else { return nil }
        return "\(fullMonth) \(rest)"
    }


    nonisolated static func title(weekStart: Date, weekEnd: Date) -> String {
        "Your Week in Congress | \(rangeString(start: weekStart, end: weekEnd))"
    }

    nonisolated static func publishedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = WeeklyDigestSchedule.timeZone
        formatter.dateFormat = "EEEE, MMMM d 'at' h:mm a"
        return "Published \(formatter.string(from: date)) ET"
    }

    nonisolated static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = WeeklyDigestSchedule.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    /// The week in Eastern time, with an en dash (Civic Record spec 3.26): "Oct 11–17, 2026",
    /// "Sep 27–Oct 3, 2026", "Dec 27, 2026–Jan 2, 2027".
    nonisolated static func rangeString(start: Date, end: Date) -> String {
        range(start: start, end: end, month: .short, includesYear: true, separator: enDash)
    }

    /// The week as the Weekly Brief front page's docket line gives it, without the year: "Oct 11–17",
    /// "Sep 27–Oct 3", "Dec 27–Jan 2".
    nonisolated static func shortRangeString(start: Date, end: Date) -> String {
        range(start: start, end: end, month: .short, includesYear: false, separator: enDash)
    }

    /// The week with the months in full, the Weekly Brief detail's title: "October 11–17, 2026",
    /// "September 27–October 3, 2026", "December 27, 2026–January 2, 2027". Without the year for the
    /// read row in Updates: "October 11–17".
    nonisolated static func longRangeString(start: Date, end: Date, includesYear: Bool = true) -> String {
        range(start: start, end: end, month: .long, includesYear: includesYear, separator: enDash)
    }

    /// What VoiceOver reads for the week: "October 11 to 17, 2026".
    nonisolated static func spokenRangeString(start: Date, end: Date, includesYear: Bool = true) -> String {
        range(start: start, end: end, month: .long, includesYear: includesYear, separator: " to ")
    }

    nonisolated private static let enDash = "\u{2013}"

    nonisolated private enum MonthWidth {
        case short
        case long

        var format: String {
            switch self {
            case .short: return "MMM"
            case .long: return "MMMM"
            }
        }
    }

    /// One month: "Oct 11–17, 2026". Two months: "Sep 27–Oct 3, 2026". Two years, each date with its
    /// year: "Dec 27, 2026–Jan 2, 2027" (without years, "Dec 27–Jan 2").
    nonisolated private static func range(
        start: Date,
        end: Date,
        month width: MonthWidth,
        includesYear: Bool,
        separator: String
    ) -> String {
        let calendar = WeeklyDigestSchedule.calendar
        let startParts = calendar.dateComponents([.year, .month, .day], from: start)
        let endParts = calendar.dateComponents([.year, .month, .day], from: end)
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.timeZone = WeeklyDigestSchedule.timeZone
        monthFormatter.dateFormat = width.format

        let startMonth = monthFormatter.string(from: start)
        let endMonth = monthFormatter.string(from: end)
        let startDay = startParts.day ?? 0
        let endDay = endParts.day ?? 0
        let startYear = startParts.year ?? 0
        let endYear = endParts.year ?? 0

        guard startYear == endYear || !includesYear else {
            return "\(startMonth) \(startDay), \(startYear)\(separator)\(endMonth) \(endDay), \(endYear)"
        }
        let days: String
        if startYear == endYear, startParts.month == endParts.month {
            days = startDay == endDay ? "\(startMonth) \(startDay)" : "\(startMonth) \(startDay)\(separator)\(endDay)"
        } else {
            days = "\(startMonth) \(startDay)\(separator)\(endMonth) \(endDay)"
        }
        return includesYear ? "\(days), \(startYear)" : days
    }
}

struct WeeklyDigestSettings: Codable, Equatable {
    var isEnabled: Bool

    static let `default` = WeeklyDigestSettings(isEnabled: true)
}

enum WeeklyDigestContractError: LocalizedError, Equatable {
    case invalidDate(field: String, value: String)
    case invalidSectionKind(String)
    case invalidItemKind(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDate(field, value):
            return "Invalid weekly digest date for \(field): \(value)"
        case let .invalidSectionKind(value):
            return "Invalid weekly digest section kind: \(value)"
        case let .invalidItemKind(value):
            return "Invalid weekly digest item kind: \(value)"
        }
    }
}

extension WeeklyDigest {
    init(dto: UserAPIContractsV1.WeeklyDigest) throws {
        guard let weekStart = FlexibleISO8601.parse(dto.weekStart) else {
            throw WeeklyDigestContractError.invalidDate(field: "weekStart", value: dto.weekStart)
        }
        guard let weekEnd = FlexibleISO8601.parse(dto.weekEnd) else {
            throw WeeklyDigestContractError.invalidDate(field: "weekEnd", value: dto.weekEnd)
        }
        guard let publishedAt = FlexibleISO8601.parse(dto.publishedAt) else {
            throw WeeklyDigestContractError.invalidDate(field: "publishedAt", value: dto.publishedAt)
        }

        self.init(
            id: dto.id,
            title: dto.title,
            summary: dto.summary,
            weekStart: weekStart,
            weekEnd: weekEnd,
            publishedAt: publishedAt,
            source: .remote,
            isRead: dto.isRead,
            stats: dto.stats.map(WeeklyDigestStat.init(dto:)),
            sections: try dto.sections.map(WeeklyDigestSection.init(dto:))
        )
    }
}

extension WeeklyDigestStat {
    nonisolated init(dto: UserAPIContractsV1.WeeklyDigestStat) {
        self.init(
            id: dto.id,
            label: dto.label,
            value: dto.value,
            accent: Accent(rawValue: dto.accent) ?? .neutral
        )
    }
}

extension WeeklyDigestSection {
    nonisolated init(dto: UserAPIContractsV1.WeeklyDigestSection) throws {
        guard let kind = Kind(rawValue: dto.kind) else {
            throw WeeklyDigestContractError.invalidSectionKind(dto.kind)
        }

        self.init(
            kind: kind,
            title: dto.title,
            subtitle: dto.subtitle,
            items: try dto.items.map(WeeklyDigestItem.init(dto:))
        )
    }
}

extension WeeklyDigestItem {
    nonisolated init(dto: UserAPIContractsV1.WeeklyDigestItem) throws {
        guard let kind = Kind(rawValue: dto.kind) else {
            throw WeeklyDigestContractError.invalidItemKind(dto.kind)
        }

        self.init(
            id: dto.id,
            kind: kind,
            title: dto.title,
            eyebrow: dto.eyebrow,
            summary: dto.summary,
            detail: dto.detail,
            reason: dto.reason,
            accent: Accent(rawValue: dto.accent) ?? .neutral,
            billState: dto.billState.flatMap(BillState.init(rawValue:)),
            billGuid: dto.billGuid,
            primaryMemberBioguideID: dto.primaryMemberBioguideId?.uppercased()
        )
    }
}
