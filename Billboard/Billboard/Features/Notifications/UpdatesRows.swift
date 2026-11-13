import SwiftUI

// The rows of the Updates tab (Civic Record spec 4.53): ruled rows on paper, not cards. Each is one
// VoiceOver element whose label carries the full text at every size; at accessibility sizes the line
// limits go, so titles, summaries and action text wrap in full (spec 2.5, 7.2). No vote data in any of
// them (INT-11).

/// The Updates list's measures (spec 2.8, 3.5): the 16 pt list gutter, 28 pt above each section head,
/// 12 pt from a head to what follows, 12 pt above and below a row's text.
enum UpdatesLayout {
    static let gutter = BillboardStyle.Space.l
    static let sectionSpacing = BillboardStyle.Space.xxl
    static let headToContent = BillboardStyle.Space.m
    static let rowVertical = BillboardStyle.Space.m
    /// Line limits at the default sizes (none at accessibility sizes).
    static let titleLines = 2
    static let textLines = 3
}

/// The date at the trailing edge of a Recent actions row: the action's date when the push carried one
/// ("2026-10-14", a calendar day, read in UTC so it never moves to the day before), else when the alert
/// arrived (the phone's time zone). "Oct 14"; "Dec 30, 2025" when it is not this year; in the reader's
/// region, as the slips and the masthead above the rows write dates (`DocketDate`: "14 Oct" in the UK).
struct UpdatesActionDate: Equatable {
    /// "Oct 14" (the `docket` role sets it in capitals).
    let printed: String
    /// "October 14".
    let spoken: String

    init?(alert: BillAlert, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) {
        let raw = alert.actionDate?.trimmedNonEmpty
        let parsed = raw.flatMap(FlexibleISO8601.parse)
        let isCalendarDay = raw.map { $0.count == 10 && !$0.contains("T") } ?? false
        let date = parsed ?? alert.date
        let zone = parsed != nil && isCalendarDay ? TimeZone(secondsFromGMT: 0)! : timeZone
        self.init(date: date, timeZone: zone, now: now, nowTimeZone: timeZone, locale: locale)
    }

    init(date: Date, timeZone: TimeZone, now: Date = Date(), nowTimeZone: TimeZone = .current, locale: Locale = .current) {
        (printed, spoken) = DocketDate.monthDay(date, now: now, locale: locale, timeZone: timeZone, nowTimeZone: nowTimeZone)
    }
}

/// A Recent actions row (spec 4.53, frame 9): the docket line (the bill's number and chamber, the action's
/// date at the trailing edge), the title (`name`), the action text (`body`, `ink2`) and the topic
/// (`caption`, `ink3`), over a hairline. No building-columns icon. It opens the bill as before, with the
/// vote panel.
struct UpdatesActionRow: View {
    let alert: BillAlert
    /// "H.R. 77" when the bill is loaded; the docket line then shows only the date.
    let billNumber: String?
    var now: Date = Date()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var date: UpdatesActionDate? {
        UpdatesActionDate(alert: alert, now: now)
    }

    private var actionText: String? {
        alert.summary.trimmedNonEmpty
    }

    private var topic: String? {
        alert.subCategory?.trimmedNonEmpty ?? alert.category.trimmedNonEmpty
    }

    /// "Rural Broadband Access Act of 2026. House bill 77. Action on October 14. Reported by the Committee
    /// on Energy and Commerce. Technology."
    var accessibilityText: String {
        SpokenSentences.join([
            alert.title,
            billNumber.map { SpokenForm.billNumber($0) },
            date.map { "Action on \($0.spoken)" },
            actionText,
            topic
        ])
    }

    var body: some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                docketLine(isAX: isAX)

                UpdatesRowTitle(text: alert.title, lineLimit: isAX ? nil : UpdatesLayout.titleLines)
                    .padding(.top, BillboardStyle.Space.s)

                if let actionText {
                    UpdatesRowText(text: actionText, lineLimit: isAX ? nil : UpdatesLayout.textLines)
                        .padding(.top, 5)
                }
                if let topic {
                    UpdatesRowTopic(text: topic)
                        .padding(.top, 6)
                }
            }
            .padding(.vertical, UpdatesLayout.rowVertical)
            HairlineRule()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func docketLine(isAX: Bool) -> some View {
        let dateText = date.map {
            Text($0.printed)
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if isAX {
            VStack(alignment: .leading, spacing: 6) {
                if let billNumber {
                    DocketLine(number: billNumber, status: nil)
                }
                dateText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                if let billNumber {
                    DocketLine(number: billNumber, status: nil)
                } else {
                    Spacer(minLength: 0)
                }
                dateText
            }
        }
    }
}

/// A Passed or Failed bills row (spec 4.53): the docket line with the PASSED, FAILED or BECAME LAW stamp
/// (no seal icon; the stamp replaces R2's "Became law" caption), the title (2 lines), the summary (3
/// lines) and the topic, over a hairline. It opens the bill with the vote panel (project decision 1).
struct UpdatesOutcomeRow: View {
    let bill: Bill

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var docketLine: DocketLine {
        if let number = bill.officialBillNumber {
            return DocketLine(number: number, status: bill.billStatus)
        }
        return DocketLine(numbers: [], chamber: nil, status: bill.billStatus)
    }

    private var summary: String? {
        bill.summary.trimmedNonEmpty ?? bill.billBreakdown?.what?.trimmedNonEmpty
    }

    private var topic: String? {
        (bill.subCategory ?? bill.category).trimmedNonEmpty
    }

    /// "Grid Modernization Act. House bill 405. Passed. Passed the House by voice vote. Energy."
    var accessibilityText: String {
        SpokenSentences.join([bill.title, docketLine.accessibilityText, summary, topic])
    }

    var body: some View {
        let isAX = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                docketLine

                UpdatesRowTitle(text: bill.title, lineLimit: isAX ? nil : UpdatesLayout.titleLines)
                    .padding(.top, BillboardStyle.Space.s)

                if let summary {
                    UpdatesRowText(text: summary, lineLimit: isAX ? nil : UpdatesLayout.textLines)
                        .padding(.top, 5)
                }
                if let topic {
                    UpdatesRowTopic(text: topic)
                        .padding(.top, 6)
                }
            }
            .padding(.vertical, UpdatesLayout.rowVertical)
            HairlineRule()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

/// A row's title: `name`, `ink`.
private struct UpdatesRowTitle: View {
    let text: String
    let lineLimit: Int?

    var body: some View {
        Text(text)
            .textRole(.name)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's action text or summary: `body`, `ink2`.
private struct UpdatesRowText: View {
    let text: String
    let lineLimit: Int?

    var body: some View {
        Text(text)
            .textRole(.body)
            .foregroundStyle(BillboardColors.secondaryText)
            .multilineTextAlignment(.leading)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row's topic: `caption`, `ink3`.
private struct UpdatesRowTopic: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.dimText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The hint under Recent actions (spec 4.49): `caption`, `ink2`.
struct UpdatesSectionHint: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.secondaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The push-permission primer (spec 4.50): a ruled block, not a card. The title (`name`), what Billboard
/// can send as a plain list between dotted rules (no check glyphs), where to choose, then the primary
/// "Turn on notifications" and the text button "Not now" (stacked at accessibility sizes). It asks iOS
/// only when the person opts in.
struct UpdatesPushPrimer: View {
    let onEnable: () -> Void
    let onNotNow: () -> Void

    static let title = "Get notified about bills that matter to you"
    static let benefits = [
        "New bills on topics you follow",
        "Changes to bills you voted on",
        "Actions in Congress on bills you watch",
        "Bills that pass or fail",
        "Your Weekly Brief"
    ]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineRule()
            VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                Text(Self.title)
                    .textRole(.name)
                    .foregroundStyle(BillboardColors.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Billboard can send you notifications about:")
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, BillboardStyle.Space.s)
                    ForEach(Array(Self.benefits.enumerated()), id: \.offset) { index, benefit in
                        if index > 0 {
                            DottedRule()
                        }
                        Text(benefit)
                            .textRole(.body)
                            .foregroundStyle(BillboardColors.primaryText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, BillboardStyle.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("Choose which ones you get in Profile at any time.")
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                        enableButton(fullWidth: true)
                        notNowButton
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: BillboardStyle.Space.m) {
                            enableButton(fullWidth: false)
                            notNowButton
                        }
                        VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                            enableButton(fullWidth: true)
                            notNowButton
                        }
                    }
                }
            }
            .padding(.top, BillboardStyle.Space.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A container, so the buttons inside keep their own ids.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("updates.pushPrimer")
    }

    private func enableButton(fullWidth: Bool) -> some View {
        Button("Turn on notifications", action: onEnable)
            .buttonStyle(BillboardButtonStyle(kind: .primary, fullWidth: fullWidth))
            .accessibilityIdentifier("updates.pushPrimer.enable")
    }

    private var notNowButton: some View {
        Button("Not now", action: onNotNow)
            .buttonStyle(BillboardButtonStyle(kind: .textButton))
            .accessibilityIdentifier("updates.pushPrimer.notNow")
    }
}
