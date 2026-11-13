import SwiftUI

/// The Bills masthead band (Civic Record spec 3.21): the first thing in the Bills scroll, navy and flush
/// with the navy bar above it, so the bar and the band read as one masthead. The `MastheadRule` (thin over
/// thick), then the dateline in the `dateline` role (11 pt SF Mono, capitals) in `textOnNavyDim`: the
/// date on the left, the Congress and session on the right, both computed (`MastheadDateline`). It
/// scrolls away with the content. At accessibility sizes the right half wraps under the left. VoiceOver
/// reads one element: "Saturday, October 17, 2026. 119th Congress, 2nd session."
struct MastheadBand: View {
    /// A fixed date (render tests); nil follows the clock, so the dateline turns over at midnight.
    var date: Date? = nil

    var body: some View {
        if let date {
            band(MastheadDateline(date: date))
        } else {
            TimelineView(.everyMinute) { context in
                band(MastheadDateline(date: context.date))
            }
        }
    }

    private func band(_ dateline: MastheadDateline) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            MastheadRule()
            ViewThatFits(in: .horizontal) {
                // One line at the default size: at least 8 pt between the halves, as in the mockup, on a
                // 390 pt phone and wider; at least 4 pt on a 375 pt phone, where 8 pt is 2 pt too many.
                // Spec 3.21 wraps the line only at the accessibility sizes; the larger standard sizes
                // wrap too, as the line is wider than any phone there.
                datelineRow(dateline, minimumGap: 8)
                datelineRow(dateline, minimumGap: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(dateline.date)
                    Text(dateline.session)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .textRole(.dateline)
            .foregroundStyle(BillboardColors.textOnNavyDim)
        }
        // The navigation bar already leaves about 21 pt of navy under the wordmark's capitals, which is
        // the mockup's whole space from the capitals to the rule (frames 1 and 2: its 10 px margin is
        // measured from a tools row with no such inset). 1 pt keeps the rule clear of the bar's edge.
        .padding(.top, 1)
        .padding(.bottom, 12)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BillboardColors.navy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dateline.spokenText)
    }

    /// The dateline on one line: the date on the left, the Congress and session on the right.
    private func datelineRow(_ dateline: MastheadDateline, minimumGap: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(dateline.date)
            Spacer(minLength: minimumGap)
            Text(dateline.session)
        }
        .lineLimit(1)
    }
}

/// The masthead's dateline (spec 3.21), computed from a date: "Sat, Oct 17, 2026" on the left and
/// "119th Congress · 2nd session" on the right (the `dateline` role sets both in capitals). The date is
/// the reader's own calendar day; the Congress and session follow Washington's calendar
/// (`CongressCalendar`). Also the Updates page title's deck line.
struct MastheadDateline: Equatable {
    /// "Sat, Oct 17, 2026".
    let date: String
    /// "Saturday, October 17, 2026": what VoiceOver reads for `date`.
    let spokenDate: String
    /// "119th Congress · 2nd session", with a no-break space before the "·", so where the line wraps (AX4 on a
    /// 375 or 402 pt phone, AX5 on a 440 pt one) the dot ends "119TH CONGRESS ·" instead of starting
    /// "· 2ND SESSION" (as the Congress deck and the affiliation lines set it).
    let session: String
    /// "119th Congress, 2nd session".
    let spokenSession: String

    init(date: Date, locale: Locale = .current, timeZone: TimeZone = .current) {
        let full = DateFormatter()
        full.locale = locale
        full.timeZone = timeZone
        full.dateStyle = .full
        full.timeStyle = .none
        let congress = CongressCalendar.session(on: date)
        self.date = DocketDate.string(date, template: "EEEMMMdyyyy", locale: locale, timeZone: timeZone)
        self.spokenDate = full.string(from: date)
        self.session = CongressMemberLabel.docketText(congress.title)
        self.spokenSession = congress.spokenTitle
    }

    /// The band's one VoiceOver element: "Saturday, October 17, 2026. 119th Congress, 2nd session."
    var spokenText: String {
        "\(spokenDate). \(spokenSession)."
    }
}

#Preview("Masthead band") {
    ScrollView {
        MastheadBand()
        Text("Slips follow on paper.")
            .padding()
    }
    .background(BillboardColors.background)
}
