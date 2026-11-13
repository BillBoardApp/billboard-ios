import SwiftUI

/// "Last 30 days" in the Civic Rank sheet (Civic Record spec 3.23, 4.65): one tally mark per day, grouped in
/// fives like a clerk's count (four uprights struck through by the fifth), `ink` for a day with a vote and
/// `rule2` for a day without. The first day's date and "Today" sit under the marks in the docket face. One
/// VoiceOver element: "Voted on 12 of the last 30 days, including today". No circles, no teal.
struct VotingStreakView: View {
    let recentVoteDays: [VoteDay]
    /// Today's date string, for "including today"; the device's calendar day when nil.
    var today: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The marks keep their size at every text size, so 30 days stay on one line (the line is read as one
    /// summary).
    static let groupSize: CGFloat = 30
    static let groupGap: CGFloat = 10
    static let daysPerGroup = 5

    /// Server day strings ("2026-10-08") parsed and printed the same way on every device.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Calendar day string for today.
    private var todayString: String {
        today ?? Self.dayFormatter.string(from: Date())
    }

    /// Days in the row with at least one vote.
    static func activeDayCount(_ days: [VoteDay]) -> Int {
        // `VoteDay.count` is the day's vote tally, not a collection size.
        // swiftlint:disable:next empty_count
        days.filter { $0.count > 0 }.count
    }

    /// "Voted on 12 of the last 30 days", with ", including today" when today has a vote.
    static func accessibilitySummary(_ days: [VoteDay], today: String? = nil) -> String {
        let active = activeDayCount(days)
        let base = "Voted on \(active) of the last \(days.count) day\(days.count == 1 ? "" : "s")"
        // swiftlint:disable:next empty_count
        guard let today, days.contains(where: { $0.date == today && $0.count > 0 }) else { return base }
        return "\(base), including today"
    }

    /// The days in groups of five, oldest first.
    static func groups(_ days: [VoteDay]) -> [[VoteDay]] {
        stride(from: 0, to: days.count, by: daysPerGroup).map { start in
            Array(days[start..<min(start + daysPerGroup, days.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            SectionHeader("Last 30 days")

            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                HStack(spacing: Self.groupGap) {
                    ForEach(Array(Self.groups(recentVoteDays).enumerated()), id: \.offset) { _, group in
                        TallyGroup(days: group)
                            .frame(width: Self.groupSize, height: Self.groupSize)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibilitySummary(recentVoteDays, today: todayString))
                .accessibilityIdentifier("civicRank.lastThirtyDays")

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        // The marks keep their size; the dates take the width rather than break a word.
                        Text(recentVoteDays.first.map { "\(shortDateLabel($0.date)) to today" } ?? "Today")
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack {
                            if let first = recentVoteDays.first {
                                Text(shortDateLabel(first.date))
                            }
                            Spacer()
                            Text("Today")
                        }
                        .frame(width: groupsWidth)
                    }
                }
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .accessibilityHidden(true)
            }
        }
    }

    /// The width of the marks, so the dates end under the last group.
    private var groupsWidth: CGFloat {
        let count = CGFloat(Self.groups(recentVoteDays).count)
        return max(0, count * Self.groupSize + max(0, count - 1) * Self.groupGap)
    }

    private func shortDateLabel(_ dateString: String) -> String {
        guard let date = Self.dayFormatter.date(from: dateString) else { return dateString }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Up to five days as one tally group: the first four as uprights and the fifth as the stroke across them,
/// each in `ink` for a day with a vote or `rule2` for a day without. Decoration; the row says it in words.
private struct TallyGroup: View {
    let days: [VoteDay]

    var body: some View {
        ZStack {
            ForEach(Array(days.prefix(VotingStreakView.daysPerGroup).enumerated()), id: \.offset) { index, day in
                TallyStroke(index: index)
                    .stroke(color(for: day), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }

    private func color(for day: VoteDay) -> Color {
        // `VoteDay.count` is the day's vote tally, not a collection size.
        // swiftlint:disable:next empty_count
        day.count > 0 ? BillboardColors.primaryText : BillboardColors.rule2
    }
}

/// One stroke of a tally group, on `TallyMarks`' 24-unit square: uprights 0 to 3, then (4) the diagonal.
private struct TallyStroke: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 12) * unit, y: rect.midY + (y - 12) * unit)
        }
        var path = Path()
        if index < TallyMarks.maximumCount {
            let x = 5.5 + CGFloat(index) * 4
            path.move(to: point(x, 5))
            path.addLine(to: point(x, 19))
        } else {
            path.move(to: point(3, 16.6))
            path.addLine(to: point(20.5, 7.4))
        }
        return path
    }
}
