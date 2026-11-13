import SwiftUI

// MARK: - Bill content sections of `BillDetail`
//
// The bill page is set as a document (Civic Record spec 4.28 to 4.34): front matter like a printed bill
// over a thin-thick double rule, then ruled sections (`RecordSection`) with no boxes. Every section takes
// `showsRule`, which the page turns off for the first section under the double rule (spec 3.5).

// MARK: - Front matter

/// The top of the bill page (spec 4.29), like a printed bill: the docket line (number, chamber and the
/// status stamp, a decided bill's included), the plain-language title, the official "To…" title in upright
/// New York, "In the news" with its reason, the last-updated time, and the double rule. For a companion
/// group (APPF-23) the docket line has every member's number and the group's status lead ("S. 456 PASSED").
struct BillFrontMatter: View {
    /// What the front matter shows, worked out from the bill so it can be drawn and tested without a store.
    struct Content: Equatable {
        /// The bill number, or a companion group's numbers, primary first; empty when unknown.
        var numbers: [String]
        var status: BillStatus
        /// The member whose status the group shows, when it is not the primary.
        var companionLead: String? = nil
        var title: String
        var officialTitle: String? = nil
        var isInTheNews = false
        /// Why the bill is in the news ("Featured in the news this week"), when the bill says.
        var newsReason: String? = nil
        /// When the bill's record was last stored (`Bill.storedAt`).
        var lastUpdated: Date? = nil

        init(
            numbers: [String],
            status: BillStatus,
            companionLead: String? = nil,
            title: String,
            officialTitle: String? = nil,
            isInTheNews: Bool = false,
            newsReason: String? = nil,
            lastUpdated: Date? = nil
        ) {
            self.numbers = numbers
            self.status = status
            self.companionLead = companionLead
            self.title = title
            self.officialTitle = officialTitle
            self.isInTheNews = isInTheNews
            self.newsReason = newsReason
            self.lastUpdated = lastUpdated
        }

        init(bill: Bill, companion: BillCompanionDisplay? = nil) {
            let lead = companion?.statusLead
            let reason = bill.priorityReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(
                numbers: companion?.numbers ?? bill.officialBillNumber.map { [$0] } ?? [],
                status: lead?.status ?? bill.billStatus,
                companionLead: lead.flatMap { $0.isPrimary ? nil : $0.billNumber },
                title: bill.title,
                officialTitle: bill.displayOfficialTitle,
                isInTheNews: bill.hasActivePriority,
                newsReason: bill.hasActivePriority && reason?.isEmpty == false ? reason : nil,
                lastUpdated: FlexibleISO8601.parse(bill.storedAt)
            )
        }

        /// The docket line's chamber: from the bill type for one bill, none for a group (its numbers say it).
        var chamber: CongressChamber? {
            numbers.count == 1 ? DocketLine.chamber(forBillNumber: numbers[0]) : nil
        }
    }

    let content: Content
    /// Called with where the title ends in the page's content (`pageSpace`), so the page can show its
    /// inline title once the bill's own title has scrolled under the bar.
    var onTitleBottom: ((CGFloat) -> Void)? = nil

    init(_ content: Content, onTitleBottom: ((CGFloat) -> Void)? = nil) {
        self.content = content
        self.onTitleBottom = onTitleBottom
    }

    init(bill: Bill, companion: BillCompanionDisplay? = nil, onTitleBottom: ((CGFloat) -> Void)? = nil) {
        self.content = Content(bill: bill, companion: companion)
        self.onTitleBottom = onTitleBottom
    }

    /// The coordinate space of the bill page's scrolling content.
    static let pageSpace = "bill.page"
    static let numberIdentifier = "bill.detail.number"
    static let officialTitleIdentifier = "bill.detail.officialTitle"

    /// "Last updated Oct 14, 2026 · 11:30 AM" (the docket role sets it in capitals).
    static func lastUpdatedText(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        day.dateStyle = .medium
        day.timeStyle = .none
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        // A no-break space keeps the "·" at the end of a line, never the start of the next.
        return "Last updated \(day.string(from: date))\u{00A0}· \(time.string(from: date))"
    }

    /// What VoiceOver reads for the date line: "Last updated October 14, 2026, 11:30 AM" (spec 1.7: a bare
    /// docket date says what it is).
    static func lastUpdatedSpoken(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        day.dateStyle = .long
        day.timeStyle = .none
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        return "Last updated \(day.string(from: date)), \(time.string(from: date))"
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !content.numbers.isEmpty {
                DocketLine(
                    numbers: content.numbers,
                    chamber: content.chamber,
                    status: content.status,
                    companionLead: content.companionLead
                )
                .accessibilityIdentifier(Self.numberIdentifier)
                .padding(.bottom, 10)
            } else {
                // No number to file it under: the stamp alone keeps the decided status on the page.
                StatusStamp(status: content.status)
                    .padding(.bottom, 10)
            }

            Text(content.title)
                .textRole(.billTitle)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.pageSpace)).maxY
                } action: { bottom in
                    onTitleBottom?(bottom)
                }

            // `title` is a generated plain-language headline; the official title sits under it, upright
            // (these run 4 to 8 lines, and italics read worse at that length).
            if let officialTitle = content.officialTitle {
                Text(officialTitle)
                    .textRole(.officialTitle)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Official title: \(officialTitle)")
                    .accessibilityIdentifier(Self.officialTitleIdentifier)
                    .padding(.top, 10)
            }

            if content.isInTheNews {
                newsLine
                    .padding(.top, 14)
            }

            if let lastUpdated = content.lastUpdated {
                Text(Self.lastUpdatedText(lastUpdated))
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                    // Its own element, so the words are not set in the docket face's capitals.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.lastUpdatedSpoken(lastUpdated))
                    .padding(.top, 12)
            }

            DoubleRule()
                .padding(.top, BillboardStyle.Space.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BillboardStyle.Space.xl)
        .padding(.top, BillboardStyle.Space.m)
    }

    /// The "In the news" tag and its reason on one baseline; the reason goes under the tag at accessibility
    /// sizes. One VoiceOver element: "In the news. Featured in the news this week".
    @ViewBuilder
    private var newsLine: some View {
        let reason = content.newsReason.map { reason in
            Text(reason)
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    IndexTag(.inTheNews)
                    reason
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                    IndexTag(.inTheNews)
                        .fixedSize()
                    reason
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([IndexTag.Kind.inTheNews.accessibilityLabel, content.newsReason].compactMap { $0 }.joined(separator: ". "))
    }
}

// MARK: - Sponsor

/// The sponsor (spec 4.30): a row with the member's monogram (or photo) and party disc, the name, the
/// letter-led affiliation and a chevron, linking to the member's page. Shown only when the sponsor is in
/// the members manifest.
struct BillSponsorSection: View {
    let bill: Bill
    var showsRule = true

    static let title = "Sponsor"

    /// The sponsor and the manifest row the member page opens with, when both are known.
    private static func sponsor(for bill: Bill) -> (member: CongressMember, manifest: CongressMemberManifestItem)? {
        guard let sponsorID = bill.sponsorMemberID,
              let member = CongressService.congressMember(for: sponsorID),
              let manifest = CongressService.cachedMemberManifestItem(for: sponsorID) else { return nil }
        return (member, manifest)
    }

    /// Whether the page shows the section (so it knows which section comes first under the double rule).
    static func isShown(for bill: Bill) -> Bool {
        sponsor(for: bill) != nil
    }

    var body: some View {
        if let sponsor = Self.sponsor(for: bill) {
            let row = BillSponsorRow.Content(member: sponsor.member)
            RecordSection(Self.title, showsRule: showsRule) {
                NavigationLink {
                    CongressMemberProfileLoaderView(manifest: sponsor.manifest)
                } label: {
                    BillSponsorRow(content: row)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel(row.accessibilityLabel)
            }
        }
    }
}

/// The sponsor's row is the member roll row every member list uses (`MemberRollRow`; project decision of
/// 2026-10-21, one member row everywhere): the 44 pt monogram (the photo when there is one) with the party
/// disc on a ring of the document, the name in the `name` role, "R · HOUSE · TX-7" in the docket face, and
/// a chevron, with no roll-sheet insets since it sits in a ruled section. At accessibility sizes it stacks
/// as every member row does: the monogram and the chevron on the first line, then the name and the
/// affiliation across the whole width.
struct BillSponsorRow: View {
    struct Content: Equatable {
        let name: String
        let party: PoliticalParty
        var chamber: CongressChamber? = nil
        var stateCode: String? = nil
        var district: String? = nil
        var photoURL: URL? = nil

        init(
            name: String,
            party: PoliticalParty,
            chamber: CongressChamber? = nil,
            stateCode: String? = nil,
            district: String? = nil,
            photoURL: URL? = nil
        ) {
            self.name = name
            self.party = party
            self.chamber = chamber
            self.stateCode = stateCode
            self.district = district
            self.photoURL = photoURL
        }

        init(member: CongressMember) {
            self.init(
                name: member.name,
                party: member.party,
                chamber: CongressMemberLabel.chamber(named: member.chamber),
                stateCode: member.stateCode ?? member.state,
                district: member.district,
                photoURL: member.imageUrl
            )
        }

        /// "R · House · TX-7".
        var affiliation: String? {
            CongressMemberLabel.affiliation(party: party, state: stateCode, district: district, chamber: chamber)
        }

        /// "Sponsor: Representative Jordan Ellis, Republican, Texas's 7th district", in the one spoken form
        /// (`CongressMemberLabel.spokenDescription`).
        var accessibilityLabel: String {
            "\(BillSponsorSection.title): " + CongressMemberLabel.spokenDescription(
                name: name,
                party: party,
                state: stateCode,
                district: district,
                chamber: chamber
            )
        }
    }

    let content: Content

    var body: some View {
        MemberRollRow(
            name: content.name,
            party: content.party,
            affiliation: content.affiliation,
            photoURL: content.photoURL,
            monogramSize: .roll,
            trailing: .chevron,
            insets: EdgeInsets(),
            groundColor: BillboardColors.document,
            accessibilityLabel: content.accessibilityLabel
        )
    }
}

// MARK: - Why it matters, Breakdown, Summary

/// Why it matters (spec 4.31): why the bill matters, in plain language, in the `lead` role (New York 20), then the
/// AI note (UX-37: "Written with AI from the official text · Report a problem").
struct BillSoWhatSection: View {
    let bill: Bill
    var showsRule = true

    static let title = "Why it matters"

    static func isShown(for bill: Bill) -> Bool {
        !bill.soWhat.isEmpty
    }

    var body: some View {
        if Self.isShown(for: bill) {
            RecordSection(Self.title, showsRule: showsRule) {
                Text(bill.soWhat)
                    .textRole(.lead)
                    .foregroundStyle(BillboardColors.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                BillAINote(bill: ReportProblem.BillReference(bill: bill))
            }
        }
    }
}

/// The Bill Breakdown (spec 4.32) as a ledger: WHO, WHAT, HOW, WHEN, WHERE, WHY in the docket face, the
/// answers in New York, dotted rules between; only the fields with text. No symbols. Then the AI note for `aiNote`'s
/// bill (UX-37); the bill page always passes it.
struct BillBreakdownSection: View {
    let breakdown: BillBreakdown
    var showsRule = true
    var aiNote: ReportProblem.BillReference? = nil

    static let title = "Bill Breakdown"

    /// Only the fields with text (`BillDisplayFormatting.breakdownRows`): no row for a missing `why`.
    var rows: [Ledger.Row] {
        BillDisplayFormatting.breakdownRows(breakdown).map { Ledger.Row($0.label, $0.text) }
    }

    var body: some View {
        RecordSection(Self.title, showsRule: showsRule) {
            Ledger(rows: rows, column: .breakdown, answerRole: .prose)
            if let aiNote {
                BillAINote(bill: aiNote)
            }
        }
    }
}

/// The legacy summary, for bills without a breakdown (spec 4.32): one `prose` paragraph, written by the same AI
/// summarizer, then the AI note for `aiNote`'s bill (UX-37); the bill page always passes it.
struct BillSummarySection: View {
    let summary: String
    var showsRule = true
    var aiNote: ReportProblem.BillReference? = nil

    static let title = "Summary"

    var body: some View {
        RecordSection(Self.title, showsRule: showsRule) {
            Text(summary)
                .textRole(.prose)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let aiNote {
                BillAINote(bill: aiNote)
            }
        }
    }
}

// MARK: - Source, Committees, Actions

/// Source (spec 4.34): the text link "View on GovInfo.gov", in ink and underlined, at the end of the page.
struct BillLinkSection: View {
    let bill: Bill
    var showsRule = true

    static let title = "Source"
    static let linkTitle = "View on GovInfo.gov"

    private var billLinkURL: URL? {
        if let link = bill.link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
            return URL(string: link)
        }
        // Fallback (placeholder / older cached bills): derive from guid.
        let guid = bill.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guid, !guid.isEmpty else { return nil }
        return URL(string: "https://www.govinfo.gov/app/details/\(guid)")
    }

    var body: some View {
        if let billLinkURL {
            RecordSection(Self.title, showsRule: showsRule) {
                Link(destination: billLinkURL) {
                    HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.xs) {
                        Text(Self.linkTitle)
                        Image(systemName: "arrow.up.right")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(BillboardButtonStyle(kind: .textLink))
                .accessibilityLabel(Self.linkTitle)
            }
        }
    }
}

/// The dates the docket prints for actions and committee activities.
enum BillDocketDate {
    /// A `yyyy-mm-dd` or ISO-8601 time, or nil.
    private static func parse(_ raw: String?) -> (date: Date, isDateOnly: Bool)? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let date = FlexibleISO8601.parse(trimmed) else { return nil }
        return (date, trimmed.count == 10 && !trimmed.contains("T"))
    }

    /// `date` from `template` (`DocketDate`). A calendar date without a time is parsed as UTC midnight: it is
    /// written in UTC so it does not move to the day before west of Greenwich (as
    /// `BillDisplayFormatting.displayDate`).
    private static func format(_ date: Date, template: String, isDateOnly: Bool, locale: Locale, timeZone: TimeZone) -> String {
        DocketDate.string(date, template: template, locale: locale, timeZone: isDateOnly ? TimeZone(secondsFromGMT: 0) ?? timeZone : timeZone)
    }

    private static func isThisYear(_ parsed: (date: Date, isDateOnly: Bool), now: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.isDateOnly ? TimeZone(secondsFromGMT: 0) ?? timeZone : timeZone
        return calendar.component(.year, from: parsed.date) == calendar.component(.year, from: now)
    }

    /// An action's date in the ledger's 56 pt label column (spec 3.6): "Feb 10" this year. In another year
    /// the year goes on a line of its own, "Feb 10" over "2025": "FEB 10, 2025" is too wide for the column
    /// and broke after its comma. The docket face sets it in capitals. Nil when there is no date.
    static func short(_ raw: String?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let parsed = parse(raw) else { return raw?.trimmedNonEmpty }
        let day = format(parsed.date, template: "MMMd", isDateOnly: parsed.isDateOnly, locale: locale, timeZone: timeZone)
        guard !isThisYear(parsed, now: now, timeZone: timeZone) else { return day }
        let year = format(parsed.date, template: "y", isDateOnly: parsed.isDateOnly, locale: locale, timeZone: timeZone)
        return "\(day)\n\(year)"
    }

    /// What VoiceOver reads for `short`: "Feb 10" this year, "Feb 10, 2025" in another. Nil when there is no
    /// date.
    static func shortSpoken(_ raw: String?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let parsed = parse(raw) else { return raw?.trimmedNonEmpty }
        let template = isThisYear(parsed, now: now, timeZone: timeZone) ? "MMMd" : "MMMdyyyy"
        return format(parsed.date, template: template, isDateOnly: parsed.isDateOnly, locale: locale, timeZone: timeZone)
    }

    /// A committee activity's date: "Oct 9, 2026". Nil when there is no date.
    static func full(_ raw: String?, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        BillDisplayFormatting.displayDate(raw, locale: locale, timeZone: timeZone)
    }
}

/// The committees the bill went through (spec 4.34), as a ledger: HOUSE or SENATE in the label column,
/// the committee's name, and under it each thing it did with the date ("Referred to · OCT 9, 2026").
struct BillCommitteesSection: View {
    let bill: Bill
    var showsRule = true

    static let title = "Committees"

    /// One committee row: the label, the name and its activities, without repeats.
    struct Row: Equatable {
        let label: String
        let name: String
        let activities: [(name: String, date: String?)]

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.label == rhs.label && lhs.name == rhs.name
                && lhs.activities.map(\.name) == rhs.activities.map(\.name)
                && lhs.activities.map(\.date) == rhs.activities.map(\.date)
        }

        /// "House: Energy and Commerce Committee. Referred to, Oct 9, 2026."
        var accessibilityLabel: String {
            let lines = [name] + activities.map { activity in
                [activity.name, activity.date].compactMap { $0 }.joined(separator: ", ")
            }
            return "\(label): " + SpokenSentences.join(lines)
        }
    }

    static func rows(for committees: [Bill.BillCommittee]) -> [Row] {
        committees.map { committee in
            let chamber = (committee.chamber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (committee.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Deduplicate activities by name (Reported By, Markup By, ...).
            var seen = Set<String>()
            let activities = (committee.activities ?? []).compactMap { activity -> (name: String, date: String?)? in
                let activityName = (activity.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !activityName.isEmpty, seen.insert(activityName.lowercased()).inserted else { return nil }
                return (activityName, BillDocketDate.full(activity.date))
            }
            return Row(
                label: chamber.isEmpty ? "Committee" : chamber,
                name: name.isEmpty ? "Committee" : name,
                activities: activities
            )
        }
    }

    var body: some View {
        let rows = Self.rows(for: bill.committees)
        if !rows.isEmpty {
            RecordSection(Self.title, showsRule: showsRule) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            DottedRule()
                        }
                        LedgerRow(label: row.label, column: .breakdown, accessibilityLabel: row.accessibilityLabel) {
                            Text(row.name)
                                .textRole(.body)
                                .foregroundStyle(BillboardColors.primaryText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(row.activities.enumerated()), id: \.offset) { _, activity in
                                BillCommitteeActivityLine(name: activity.name, date: activity.date)
                            }
                        }
                        .padding(.top, index == 0 ? 2 : 10)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
    }
}

/// "Referred to · OCT 9, 2026": what the committee did in `caption`, the date in the docket face; the date
/// goes under the words when they do not fit on one line, without the "·", which never opens a line.
struct BillCommitteeActivityLine: View {
    let name: String
    let date: String?

    /// The date as it is set: after a "·" beside the words, alone on its line under them.
    static func dateText(_ date: String, besideName: Bool) -> String {
        besideName ? "· \(date)" : date
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                nameText.fixedSize()
                dateText(besideName: true).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                nameText.fixedSize(horizontal: false, vertical: true)
                dateText(besideName: false).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nameText: some View {
        Text(name)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.secondaryText)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func dateText(besideName: Bool) -> some View {
        if let date {
            Text(Self.dateText(date, besideName: besideName))
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
        }
    }
}

/// The bill's actions (spec 4.34), oldest first, as a ledger: the date in the label column ("FEB 10", with
/// the year under it in another year), the action's text, and its type under it in `caption`. No numbers:
/// the dates order it. Duplicates from several sources are left out; an action without text shows its type
/// instead, or is left out (`BillDisplayFormatting.timelineActions`).
struct BillActionsSection: View {
    let bill: Bill
    var showsRule = true

    static let title = "Actions"
    /// The label of an action with no date.
    static let undatedLabel = "No date"

    static func rows(for actions: [Bill.BillAction], now: Date = Date()) -> [Ledger.Row] {
        BillDisplayFormatting.timelineActions(actions).map { action in
            Ledger.Row(
                BillDocketDate.short(action.actionDate, now: now) ?? undatedLabel,
                BillDisplayFormatting.timelineText(for: action) ?? "",
                detail: BillDisplayFormatting.timelineTypeLabel(for: action),
                spokenLabel: BillDocketDate.shortSpoken(action.actionDate, now: now)
            )
        }
    }

    var body: some View {
        let rows = Self.rows(for: bill.actions)
        if !rows.isEmpty {
            RecordSection(Self.title, showsRule: showsRule) {
                Ledger(rows: rows, column: .dates)
            }
        }
    }
}

// MARK: - In Congress (APPF-23)

/// In Congress (spec 4.33): one block per member of a companion group, House bill first, each with its
/// docket line (number, chamber, status stamp), its official title, a ledger with its sponsor and latest
/// action, and the chamber tallies ("HOUSE VOTE · YEA 220 · NAY 210", official Congress data, not other
/// users' votes). Blocks are separated by hairlines. A member whose details are not loaded is fetched here
/// (its processed bill, as the weekly digest does); when that fails the block says "Details unavailable".
struct BillCompanionMembersSection: View {
    let group: BillCompanionGroup
    var showsRule = true

    static let title = "In Congress"

    @EnvironmentObject private var billsStore: BillsStore
    @State private var failedMembers: Set<String> = []

    var body: some View {
        RecordSection(Self.title, showsRule: showsRule) {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                ForEach(Array(group.memberGuids.enumerated()), id: \.element) { index, member in
                    if index > 0 {
                        HairlineRule()
                    }
                    BillCompanionMemberRow(
                        memberGuid: member,
                        bill: memberBill(member),
                        isHydrated: isHydrated(member),
                        isUnavailable: failedMembers.contains(member),
                        sponsor: memberBill(member).flatMap { BillCompanionMemberRow.sponsor(for: $0) }
                    )
                }
            }
        }
        .task(id: Self.loadTaskKey(for: group, in: billsStore)) {
            await loadMissingMembers()
        }
    }

    /// What restarts the members' load: the group, and which members' details are current. A member a
    /// newer manifest row marks stale while the screen is open (an "Updated" push for the Senate bill
    /// opens on the House primary) is fetched again; a fetch that succeeds changes the key once, and
    /// one that fails leaves it, so the load does not loop. (Storing a fetched member never drops
    /// another member from a full store, `upsertCompanionMemberBill`, so the key cannot flip back.)
    struct LoadTaskKey: Equatable {
        let memberGuids: [String]
        let isCurrent: [Bool]
    }

    static func loadTaskKey(for group: BillCompanionGroup, in billsStore: BillsStore) -> LoadTaskKey {
        LoadTaskKey(
            memberGuids: group.memberGuids,
            isCurrent: group.memberGuids.map { isCurrent($0, in: billsStore) }
        )
    }

    private static func isCurrent(_ member: String, in billsStore: BillsStore) -> Bool {
        billsStore.loadedBills(ofMember: member).first.map { billsStore.isBillDetailHydrated($0) } ?? false
    }

    /// The member's loaded bill: the one with its plain guid, else a legacy text-version bill of it.
    private func memberBill(_ member: String) -> Bill? {
        billsStore.loadedBills(ofMember: member).first
    }

    /// The member has details to show (stale ones included, while they are fetched again).
    private func isHydrated(_ member: String) -> Bool {
        memberBill(member).map { billsStore.hasBillDetails($0) } ?? false
    }

    private func isCurrent(_ member: String) -> Bool {
        Self.isCurrent(member, in: billsStore)
    }

    /// Loads each member whose details are missing or stale, one at a time; a member still without
    /// details afterwards shows "Details unavailable".
    @MainActor
    private func loadMissingMembers() async {
        for member in group.memberGuids where !isCurrent(member) {
            guard !Task.isCancelled else { return }
            await loadMember(member)
            guard !Task.isCancelled else { return }
            if !isHydrated(member) {
                failedMembers.insert(member)
            }
        }
    }

    /// Hydrates the member's loaded bill, or fetches and stores its processed bill.
    @MainActor
    private func loadMember(_ member: String) async {
        if let bill = memberBill(member) {
            _ = await billsStore.ensureHydrated(billID: bill.id, reportsError: false)
            return
        }
        do {
            let processed = try await BillsService.getProcessedBill(guid: member)
            billsStore.upsertCompanionMemberBill(processed, of: group)
        } catch {
            #if DEBUG
            print("[BillCompanionMembersSection] Failed to load guid=\(member): \(APIErrorDebug.debugString(for: error))")
            #endif
        }
    }
}

/// One member of a companion group in the In Congress section, read by VoiceOver as one element.
struct BillCompanionMemberRow: View {
    let memberGuid: String
    let bill: Bill?
    /// The member's processed details are loaded.
    let isHydrated: Bool
    /// Loading the member's details failed.
    let isUnavailable: Bool
    /// The member bill's sponsor, when the members manifest has them (`sponsor(for:)`).
    var sponsor: BillSponsorRow.Content? = nil

    static let loadingText = "Loading details…"
    static let unavailableText = "Details unavailable"
    static let sponsorLabel = "Sponsor"
    static let latestActionLabel = "Latest action"

    /// The member bill's sponsor from the members manifest, or nil.
    static func sponsor(for bill: Bill) -> BillSponsorRow.Content? {
        guard let sponsorID = bill.sponsorMemberID,
              let member = CongressService.congressMember(for: sponsorID) else { return nil }
        return BillSponsorRow.Content(member: member)
    }

    private var number: String {
        CompanionGroupIndex.billNumber(forGUID: memberGuid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            DocketLine(number: number, status: bill?.billStatus)

            if let bill, isHydrated {
                details(for: bill)
            } else if isUnavailable {
                Text(Self.unavailableText)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.dimText)
            } else {
                HStack(spacing: BillboardStyle.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BillboardColors.interactive)
                    Text(Self.loadingText)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.dimText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The line under the docket line: the official title in the reading face, or, for a bill without one,
    /// its plain-English title as a headline (`name`), since New York is for reading text only (spec 1.3).
    static func titleLine(for bill: Bill) -> (text: String, role: TextRole) {
        if let official = bill.officialTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !official.isEmpty {
            return (official, .officialTitle)
        }
        return (bill.title, .name)
    }

    /// LATEST ACTION: the bill's last action and its date, or nil when it has none with text.
    static func latestAction(for bill: Bill) -> Ledger.Row? {
        guard let action = BillDisplayFormatting.timelineActions(bill.actions).last,
              let text = BillDisplayFormatting.timelineText(for: action) else { return nil }
        return Ledger.Row(latestActionLabel, text, detail: BillDisplayFormatting.displayDate(action.actionDate))
    }

    @ViewBuilder
    private func details(for bill: Bill) -> some View {
        let title = Self.titleLine(for: bill)
        Text(title.text)
            .textRole(title.role)
            .foregroundStyle(title.role == .officialTitle ? BillboardColors.secondaryText : BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)

        let latest = Self.latestAction(for: bill)
        if sponsor != nil || latest != nil {
            // A ledger (spec 3.6, 4.33): the sponsor as the Sponsor section names them, the name over the
            // letter-led affiliation ("R · HOUSE · TX-7", spec 3.14, 4.30) and read as "Sponsor:
            // Representative Jordan Ellis, Republican, Texas's 7th district"; then the latest action and its
            // date.
            VStack(alignment: .leading, spacing: 0) {
                if let sponsor {
                    LedgerRow(label: Self.sponsorLabel, column: .inCongress, accessibilityLabel: sponsor.accessibilityLabel) {
                        answerText(sponsor.name)
                        if let affiliation = sponsor.affiliation {
                            Text(affiliation)
                                .textRole(.docket)
                                .foregroundStyle(BillboardColors.dimText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                }
                if let latest {
                    if sponsor != nil {
                        DottedRule()
                    }
                    LedgerRow(label: latest.label, column: .inCongress, accessibilityLabel: latest.accessibilityLabel) {
                        answerText(latest.answer)
                        if let date = latest.detail {
                            Text(date)
                                .textRole(.caption)
                                .foregroundStyle(BillboardColors.dimText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, sponsor == nil ? 2 : 10)
                    .padding(.bottom, 10)
                }
            }
        }

        ForEach(Self.officialVoteLines(for: bill), id: \.self) { line in
            Text(line)
                .textRole(.docket)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func answerText(_ text: String) -> some View {
        Text(text)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "House vote · Yea 220 · Nay 210", then the Senate's, for each chamber that voted (the docket face
    /// sets them in capitals).
    static func officialVoteLines(for bill: Bill) -> [String] {
        let chambers: [(String, Bill.OfficialChamberVote?, Int?, Int?)] = [
            ("House", bill.officialVotes?.house, bill.congressHouseYeaCount, bill.congressHouseNayCount),
            ("Senate", bill.officialVotes?.senate, bill.congressSenateYeaCount, bill.congressSenateNayCount)
        ]
        return chambers.compactMap { chamber, vote, fallbackYea, fallbackNay in
            if let vote {
                return "\(chamber) vote · Yea \(vote.yea) · Nay \(vote.nay)"
            }
            guard let fallbackYea, let fallbackNay else { return nil }
            return "\(chamber) vote · Yea \(fallbackYea) · Nay \(fallbackNay)"
        }
    }
}
