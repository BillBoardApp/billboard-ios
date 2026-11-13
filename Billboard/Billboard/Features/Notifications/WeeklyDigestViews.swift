import SwiftUI

// MARK: - Updates: the front page, the read row, loading and error (Civic Record spec 3.26, 4.51)

/// The unread Weekly Brief on Updates: its front page (`WeeklyBriefFrontPage`), which opens the brief.
struct WeeklyDigestPreviewCard: View {
    let digest: WeeklyDigest

    var body: some View {
        NavigationLink {
            WeeklyDigestDetailView(digest: digest)
        } label: {
            WeeklyBriefFrontPage(digest: digest)
        }
        .buttonStyle(RowButtonStyle())
        // No system chevron in the Updates list: the slip and the row run to the gutter, and the read
        // row keeps only its own chevron (spec 3.26).
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityIdentifier("updates.weeklyBrief.open")
    }
}

/// The unread Weekly Brief as a front page (spec 3.26), replacing R2's navy card with its KPI tiles: a
/// slip with the docket line "WEEKLY BRIEF · OCT 11–17" (the week from the digest's `weekStart` and
/// `weekEnd`) and the UNREAD stamp, the digest's summary as the headline in New York (`leadStrong`), the
/// server's figures as one plain mono line ("2 NEED ATTENTION · 1 MEMBER ACTIVE · 3 WORTH A LOOK"), then
/// under a rule the dateline and the "Open Weekly Brief" capsule. No navy, no gradient, no teal, no
/// tiles, no shadow. Nothing in it is a vote count (INT-11): the figures count the brief's own items.
///
/// One VoiceOver element; the link around it opens the brief.
struct WeeklyBriefFrontPage: View {
    let digest: WeeklyDigest

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// "Weekly Brief · Oct 11–17" (the `docket` role sets it in capitals); the dot never starts a line.
    var docketText: String {
        "Weekly Brief\u{00A0}· \(WeeklyDigestDateFormatter.shortRangeString(start: digest.weekStart, end: digest.weekEnd))"
    }

    /// "Weekly Brief, October 11 to 17. Unread. Two bills need your attention… 2 need attention, 1
    /// member active, 3 worth a look. Published Saturday, October 17 at 1:12 PM ET."
    var accessibilityText: String {
        let week = WeeklyDigestDateFormatter.spokenRangeString(start: digest.weekStart, end: digest.weekEnd, includesYear: false)
        return SpokenSentences.join([
            "Weekly Brief, \(week)",
            StatusStamp.Kind.unread.spokenWord,
            digest.summary,
            WeeklyBriefFigures.spokenText(digest.stats),
            digest.publishedLabel
        ])
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            docketLine

            Text(digest.summary)
                .textRole(.leadStrong)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BillboardStyle.Space.m)

            if let figures = WeeklyBriefFigures.text(digest.stats) {
                // Plain text, never tappable; it wraps and never scales down.
                Text(figures)
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            HairlineRule()
                .padding(.horizontal, -BillboardStyle.Space.l)
                .padding(.top, BillboardStyle.Space.m)

            VStack(alignment: .leading, spacing: 10) {
                Text(WeeklyBriefText.unbrokenTime(digest.publishedLabel))
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                WeeklyBriefOpenCapsule()
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, BillboardStyle.Space.l)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BillboardColors.cardBackground)
        .clipShape(shape)
        // Inside the edge, so nothing is drawn outside the slip's frame; no shadow (spec 1.1).
        .overlay(shape.strokeBorder(BillboardColors.separator, lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityInputLabels(["Open Weekly Brief", "Weekly Brief"])
    }

    @ViewBuilder
    private var docketLine: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                docketWords
                StatusStamp(.unread)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                    docketWords
                        .fixedSize()
                    Spacer(minLength: BillboardStyle.Space.s)
                    StatusStamp(.unread)
                }
                VStack(alignment: .leading, spacing: 6) {
                    docketWords
                    StatusStamp(.unread)
                }
            }
        }
    }

    private var docketWords: some View {
        WeeklyBriefDocketWords(text: docketText)
    }
}

/// The "Open Weekly Brief" capsule on the front page: the secondary capsule's look (spec 3.16) with a
/// `chevron.right`, drawn inside the link that is the whole slip.
private struct WeeklyBriefOpenCapsule: View {
    var body: some View {
        BillboardButtonBody(
            label: HStack(spacing: 7) {
                Text("Open Weekly Brief")
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
            },
            kind: .secondary,
            fullWidth: false,
            // Decoration inside the link: drawn as enabled wherever the link is.
            drawsAsEnabled: true
        )
    }
}

/// A Weekly Brief docket line's words: `docket`, semibold, `ink2`, as a bill number is.
private struct WeeklyBriefDocketWords: View {
    let text: String

    var body: some View {
        Text("\(Text(text).fontWeight(.semibold))")
            .textRole(.docket)
            .foregroundStyle(BillboardColors.secondaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The figures line under the front page's headline: the server's stats (counts of the brief's own
/// items, never votes), at most three as R2 showed. The three figures the app knows are set in its own
/// words, singular or plural by their count, as frame 9 shows them: the server labels the members' figure
/// "Reps active" and the local brief "Members active", and neither reads right ("1 reps active", "1 members
/// active"; the glossary never says "reps"). A figure the app does not know keeps the server's label.
enum WeeklyBriefFigures {
    /// "2 need attention · 1 member active · 3 worth a look" (the `docket` role sets it in capitals), a
    /// no-break space before each dot so a dot ends its line rather than starting the next. Nil without stats.
    static func text(_ stats: [WeeklyDigestStat]) -> String? {
        let parts = figures(stats)
        return parts.isEmpty ? nil : parts.joined(separator: "\u{00A0}· ")
    }

    /// "2 need attention, 1 member active, 3 worth a look", for VoiceOver.
    static func spokenText(_ stats: [WeeklyDigestStat]) -> String? {
        let parts = figures(stats)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// One figure: its count and words, "1 member active", "2 members active", "1 needs attention".
    static func words(for stat: WeeklyDigestStat) -> String? {
        let value = stat.value.trimmed
        let isOne = Int(value) == 1
        let label: String
        switch stat.id.trimmed.lowercased() {
        case "attention": label = isOne ? "needs attention" : "need attention"
        case "representatives": label = isOne ? "member active" : "members active"
        case "quicklook": label = "worth a look"
        default: label = stat.label.trimmed
        }
        let words = [value, label].filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func figures(_ stats: [WeeklyDigestStat]) -> [String] {
        stats.prefix(3).compactMap { words(for: $0) }
    }
}

enum WeeklyBriefText {
    /// The published line with its time kept on one line when it wraps: "…at 1:12\u{00A0}PM\u{00A0}ET".
    static func unbrokenTime(_ text: String) -> String {
        text
            .replacingOccurrences(of: " AM", with: "\u{00A0}AM")
            .replacingOccurrences(of: " PM", with: "\u{00A0}PM")
            .replacingOccurrences(of: " ET", with: "\u{00A0}ET")
    }
}

/// The Weekly Brief once read: one ruled row in the Updates list (spec 3.26), which opens the brief.
struct WeeklyDigestCompactCard: View {
    let digest: WeeklyDigest

    var body: some View {
        NavigationLink {
            WeeklyDigestDetailView(digest: digest)
        } label: {
            WeeklyBriefReadRow(digest: digest)
        }
        .buttonStyle(RowButtonStyle())
        // No system chevron in the Updates list: the slip and the row run to the gutter, and the read
        // row keeps only its own chevron (spec 3.26).
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityIdentifier("updates.weeklyBrief.open")
    }
}

/// The read Weekly Brief's row (spec 3.26): between hairlines, the docket "WEEKLY BRIEF", the week as
/// the title ("October 11–17", `name`), the published line (`caption`, `ink3`) and the chevron. One
/// VoiceOver element.
struct WeeklyBriefReadRow: View {
    let digest: WeeklyDigest

    var title: String {
        WeeklyDigestDateFormatter.longRangeString(start: digest.weekStart, end: digest.weekEnd, includesYear: false)
    }

    var accessibilityText: String {
        let week = WeeklyDigestDateFormatter.spokenRangeString(start: digest.weekStart, end: digest.weekEnd, includesYear: false)
        return SpokenSentences.join(["Weekly Brief, \(week)", digest.publishedLabel])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HairlineRule()
            HStack(alignment: .center, spacing: RollRowInsets.gap) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                    WeeklyBriefDocketWords(text: "Weekly Brief")
                    Text(title)
                        .textRole(.name)
                        .foregroundStyle(BillboardColors.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(digest.publishedLabel)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.dimText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RowChevron()
            }
            .padding(.vertical, BillboardStyle.Space.m)
            HairlineRule()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityInputLabels(["Weekly Brief", "Open Weekly Brief"])
    }
}

/// The front page while the brief is built (spec 3.26): the same slip, a spinner in ink and R2's words.
struct WeeklyDigestLoadingCard: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            WeeklyBriefDocketWords(text: "Weekly Brief")
            HStack(alignment: .center, spacing: BillboardStyle.Space.m) {
                ProgressView()
                    .tint(BillboardColors.interactive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Building your Weekly Brief")
                        .textRole(.name)
                        .foregroundStyle(BillboardColors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Summarizing last week for you.")
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(BillboardStyle.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BillboardColors.cardBackground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(BillboardColors.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Shown in Updates when the Weekly Brief could not be refreshed (spec 3.26). With no brief to show, a
/// `RecordNotice` with COULDN'T LOAD and Retry. When an earlier brief is still on screen, a caption line
/// above its slip says so, with Retry, rather than letting it pass as this week's.
struct WeeklyDigestErrorCard: View {
    let message: String
    let isShowingPreviousBrief: Bool
    let retry: () -> Void

    static let staleTitle = "Showing your last Weekly Brief"
    static let failedTitle = "Couldn't load your Weekly Brief"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var noticeIconSize: CGFloat = 13

    var body: some View {
        if isShowingPreviousBrief {
            staleLine
        } else {
            RecordNotice(
                .couldNotLoad,
                title: Self.failedTitle,
                message: message,
                action: .init(title: "Retry", accessibilityIdentifier: "updates.weeklyBrief.retry", perform: retry)
            )
        }
    }

    /// "Showing your last Weekly Brief. Can't reach Billboard right now." in `caption` `ink2`, with
    /// `info.circle` (a notice, spec 2.10), and the Retry text button beside it (under it at accessibility
    /// sizes).
    private var staleLine: some View {
        let note = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(TextRole.Face.text.font(size: noticeIconSize, weight: .semibold))
                .foregroundStyle(BillboardColors.secondaryText)
                .accessibilityHidden(true)
            Text(SpokenSentences.join([Self.staleTitle, message]))
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)

        let retryButton = Button("Retry", action: retry)
            .buttonStyle(BillboardButtonStyle(kind: .textButton))
            .accessibilityLabel("Retry the Weekly Brief")
            .accessibilityInputLabels(["Retry", "Retry the Weekly Brief"])
            .accessibilityIdentifier("updates.weeklyBrief.retry")

        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                    note
                    retryButton
                }
            } else {
                HStack(alignment: .center, spacing: BillboardStyle.Space.m) {
                    note
                        .frame(maxWidth: .infinity, alignment: .leading)
                    retryButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - The Weekly Brief detail (spec 4.52)

/// The Weekly Brief, set as a document (spec 4.52): the `document` ground, the 20 pt gutter, the
/// inline title "Weekly Brief", then `WeeklyBriefDocument`. Opening it marks the brief read.
struct WeeklyDigestDetailView: View {
    let digest: WeeklyDigest

    @EnvironmentObject private var weeklyDigestStore: WeeklyDigestStore
    @EnvironmentObject private var congressManifestStore: CongressMembersManifestStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                WeeklyBriefDocument(
                    digest: digest,
                    members: WeeklyBriefDocument.members(for: digest, in: congressManifestStore.items),
                    scrollToSection: { kind in
                        if reduceMotion {
                            proxy.scrollTo(kind, anchor: .top)
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(kind, anchor: .top)
                            }
                        }
                    }
                )
            }
        }
        .background(BillboardColors.document.ignoresSafeArea())
        .navigationTitle("Weekly Brief")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .accessibilityIdentifier("weeklyBrief.detail")
        .onAppear {
            weeklyDigestStore.markCurrentDigestRead()
        }
    }
}

/// The Weekly Brief's page (spec 4.52, frame 10). Front matter: the docket "WEEKLY BRIEF", the week as the
/// title ("October 11–17, 2026", `title`), the summary in `leadStrong`, the contents ("In this brief": one
/// 44 pt row per section that has items, in page order, each going to its section and moving VoiceOver
/// focus to its title), the dateline and the double rule. Then each section with a sentence-case title
/// and its items, separated by hairlines. No icons, no section colours, no line limits.
///
/// Item text is the server's (or the local builder's) copy; nothing here adds a vote count or another
/// user's vote (INT-11).
struct WeeklyBriefDocument: View {
    let digest: WeeklyDigest
    /// The members of the brief's member items, by bioguide id, for their party disc and affiliation.
    var members: [String: CongressMemberManifestItem] = [:]
    /// Scrolls the page to a section (the detail's `ScrollViewReader`).
    var scrollToSection: (WeeklyDigestSection.Kind) -> Void = { _ in }

    @AccessibilityFocusState private var focusedSection: WeeklyDigestSection.Kind?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The sections that have items, in page order.
    var sections: [WeeklyDigestSection] {
        digest.sections.filter { !$0.items.isEmpty }
    }

    /// The members the brief's member items name, looked up by bioguide id (case-insensitive).
    static func members(for digest: WeeklyDigest, in manifest: [CongressMemberManifestItem]) -> [String: CongressMemberManifestItem] {
        let wanted = Set(digest.sections.flatMap(\.items).compactMap { $0.primaryMemberBioguideID?.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        var found: [String: CongressMemberManifestItem] = [:]
        for member in manifest where wanted.contains(member.id.uppercased()) {
            found[member.id.uppercased()] = member
        }
        return found
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            frontMatter
            DoubleRule()
                .padding(.horizontal, BillboardStyle.Space.xl)

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                sectionView(section, isFirst: index == 0)
                    .id(section.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, BillboardStyle.Space.xxl)
    }

    // MARK: Front matter

    private var frontMatter: some View {
        VStack(alignment: .leading, spacing: 0) {
            WeeklyBriefDocketWords(text: "Weekly Brief")

            Text(WeeklyDigestDateFormatter.longRangeString(start: digest.weekStart, end: digest.weekEnd))
                .textRole(.title)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BillboardStyle.Space.s)
                .accessibilityLabel(WeeklyDigestDateFormatter.spokenRangeString(start: digest.weekStart, end: digest.weekEnd))
                .accessibilityAddTraits(.isHeader)

            Text(digest.summary)
                .textRole(.leadStrong)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BillboardStyle.Space.m)

            if !sections.isEmpty {
                contents
                    .padding(.top, 14)
            }

            Text(WeeklyBriefText.unbrokenTime(digest.publishedLabel))
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BillboardStyle.Space.m)
                .accessibilityLabel(digest.publishedLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BillboardStyle.Space.xl)
        .padding(.top, BillboardStyle.Space.l)
        .padding(.bottom, BillboardStyle.Space.l)
    }

    /// "In this brief" and a row per section, a dotted rule above each row.
    private var contents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("In this brief")
                .textRole(.label)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, BillboardStyle.Space.xs)
                .accessibilityAddTraits(.isHeader)
            ForEach(sections) { section in
                DottedRule()
                WeeklyBriefContentsRow(title: section.displayTitle, count: section.items.count) {
                    jump(to: section.kind)
                }
            }
        }
    }

    /// Scrolls to the section, then puts VoiceOver focus on its title once the scroll has settled.
    private func jump(to kind: WeeklyDigestSection.Kind) {
        scrollToSection(kind)
        let delay: Double = reduceMotion ? 0.05 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            focusedSection = kind
        }
    }

    // MARK: Sections

    /// A section as a document section (spec 3.5's RecordSection): a hairline on top (none for the first,
    /// under the double rule), 16 pt, the title in `heading`, then the items, each 12 pt below the one
    /// before, separated by hairlines; 20 pt gutter.
    private func sectionView(_ section: WeeklyDigestSection, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                HairlineRule()
            }
            Text(section.displayTitle)
                .textRole(.heading)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
                .background {
                    // The title's VoiceOver element, which a contents row moves focus to. It sits behind the
                    // title rather than on it: ImageRenderer draws nothing for a view that carries
                    // `accessibilityFocused`, so on the title itself the render tests would lose the title.
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel(section.displayTitle)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($focusedSection, equals: section.kind)
                }
                .padding(.top, BillboardStyle.Space.l)

            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    HairlineRule()
                }
                WeeklyBriefItemView(item: item, member: item.primaryMemberBioguideID.flatMap { members[$0.uppercased()] })
            }
        }
        .padding(.bottom, BillboardStyle.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BillboardStyle.Space.xl)
    }
}

extension WeeklyDigestSection {
    /// The section's title on the page and in the contents, in sentence case (spec 4.52), whatever the
    /// server's title case says ("Needs Your Attention").
    var displayTitle: String {
        switch kind {
        case .needsAttention: return "Needs attention"
        case .movedThisWeek: return "Moved this week"
        case .representatives: return "Your representatives"
        case .worthQuickLook: return "Worth a quick look"
        }
    }
}

/// A row of the brief's contents (spec 4.52): a full-width button at least 44 pt tall with the section's
/// title (`body`, `ink`), its item count (`figure`, `ink`) and `chevron.down` (`ink3`). At accessibility
/// sizes the count and the chevron go under the title, so the title keeps the row's width.
struct WeeklyBriefContentsRow: View {
    let title: String
    let count: Int
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var chevronSize: CGFloat = 14

    /// "Needs attention, 2 items".
    var accessibilityText: String {
        "\(title), \(count) \(count == 1 ? "item" : "items")"
    }

    static let accessibilityHint = "Goes to the section"

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                        titleText
                        HStack(alignment: .center, spacing: 10) {
                            countText
                            chevron
                        }
                    }
                    .padding(.vertical, BillboardStyle.Space.s)
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        titleText
                            .frame(maxWidth: .infinity, alignment: .leading)
                        countText
                        chevron
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(Self.accessibilityHint)
        .accessibilityInputLabels([title])
    }

    private var titleText: some View {
        Text(title)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var countText: some View {
        Text("\(count)")
            .textRole(.figure)
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize()
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(TextRole.Face.text.font(size: chevronSize, weight: .semibold))
            .foregroundStyle(BillboardColors.dimText)
            .accessibilityHidden(true)
    }
}

/// One item of the Weekly Brief (spec 4.52). A bill: its docket line (number, chamber, stamp), the date
/// alone ("OCT 14"; the stamp already says the status), the title (`name`), the summary (`prose`), the
/// reason (`caption`, `ink2`) and the "Open bill" link. A member: the monogram with the party disc, the
/// name and the letter-led affiliation ("D · SENATE · VA"), the summary, the reason and "View member".
/// The text is one VoiceOver element; the link is its own.
struct WeeklyBriefItemView: View {
    let item: WeeklyDigestItem
    /// The member a member item names, when the members list has them.
    var member: CongressMemberManifestItem? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var memberParty: PoliticalParty? {
        guard let member else { return nil }
        return CongressMemberLabel.party(of: member)
    }

    private var memberChamber: CongressChamber? {
        guard let member else { return nil }
        return CongressMemberLabel.chamber(of: member)
    }

    private var docketLine: DocketLine? {
        let status = item.billState?.billStatus
        guard item.kind == .bill else { return nil }
        if let number = item.billNumber {
            return DocketLine(number: number, status: status)
        }
        guard let status else { return nil }
        return DocketLine(numbers: [], chamber: nil, status: status)
    }

    private var memberAffiliation: String? {
        guard let member else { return nil }
        return CongressMemberLabel.affiliation(party: memberParty, state: member.state, district: member.district, chamber: memberChamber)
    }

    /// The item's text as VoiceOver reads it: "Rural Broadband Access Act of 2026. House bill 77. Updated.
    /// Last updated October 14. The Energy and Commerce Committee reported the bill. You voted on this
    /// before." The date is named for what it is and its month is in full (spec 1.7), as a slip reads it.
    var accessibilityText: String {
        switch item.kind {
        case .bill:
            return SpokenSentences.join([item.title, docketLine?.accessibilityText, item.spokenDateEyebrow, item.summary, item.reason])
        case .member:
            let who = member.map {
                CongressMemberLabel.spokenDescription(name: item.title, party: memberParty, state: $0.state, district: $0.district, chamber: memberChamber)
            } ?? item.title
            return SpokenSentences.join([who, item.summary, item.reason])
        }
    }

    /// "Open bill" or "View member".
    var callToAction: String {
        item.kind == .bill ? "Open bill" : "View member"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                switch item.kind {
                case .bill:
                    billHead
                case .member:
                    memberHead
                }
                if let summary = item.summary.trimmedNonEmpty {
                    Text(summary)
                        .textRole(.prose)
                        .foregroundStyle(BillboardColors.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = item.reason?.trimmedNonEmpty {
                    Text(reason)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)

            NavigationLink {
                switch item.kind {
                case .bill:
                    WeeklyDigestBillDestinationView(item: item)
                case .member:
                    WeeklyDigestMemberDestinationView(item: item)
                }
            } label: {
                Text(callToAction)
            }
            .buttonStyle(BillboardButtonStyle(kind: .textLink))
            .accessibilityLabel("\(callToAction): \(item.title)")
            .accessibilityInputLabels([callToAction])
            .padding(.top, BillboardStyle.Space.xs)
        }
        .padding(.top, BillboardStyle.Space.m)
        .padding(.bottom, BillboardStyle.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var billHead: some View {
        VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
            if let docketLine {
                docketLine
            }
            if let date = item.dateEyebrow {
                Text(date)
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            titleText
        }
    }

    @ViewBuilder
    private var memberHead: some View {
        let avatar = CongressMemberAvatar(
            url: member?.depictionImageUrl,
            name: member?.name ?? item.title,
            size: .roll,
            party: memberParty,
            groundColor: BillboardColors.document
        )
        let names = VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
            titleText
            if let affiliation = memberAffiliation {
                Text(CongressMemberLabel.docketText(affiliation))
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                avatar
                names
            }
        } else {
            HStack(alignment: .center, spacing: 14) {
                avatar
                names
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var titleText: some View {
        Text(item.title)
            .textRole(.name)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Destinations (spec 4.52)

private struct WeeklyDigestBillDestinationView: View {
    let item: WeeklyDigestItem

    @EnvironmentObject private var billsStore: BillsStore

    @State private var resolvedBillID: UUID?
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let resolvedBillID {
                // With the guid, the screen fetches the bill again if a manifest load drops it (APPF-26).
                // A decided bill opens with the vote panel too (project decision 1).
                BillDetail(billID: resolvedBillID, mode: item.billDetailMode, linkGUID: item.billGuid)
            } else if isLoading {
                WeeklyDigestUnavailableView.loading(message: "Loading this bill.")
            } else {
                WeeklyDigestUnavailableView(
                    title: "Couldn't open this bill",
                    message: errorMessage ?? "Try again in a moment."
                ) {
                    Task { await resolveBillIfNeeded(forceRefresh: true) }
                }
            }
        }
        // The loading and unavailable states before the bill page exists get the pushed screen's glass
        // bar too (spec 3.21); the bill page sets its own.
        .glassNavigationBar()
        .task(id: item.id) {
            await resolveBillIfNeeded()
        }
    }

    @MainActor
    private func resolveBillIfNeeded(forceRefresh: Bool = false) async {
        if !forceRefresh, resolvedBillID != nil { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // A member of a companion group (APPF-23) opens on the group primary's bill when it is loaded;
        // the detail shows the group for either member.
        if let guid = item.billGuid, billsStore.companionGroup(forGUID: guid) != nil {
            let groupBillID = billsStore.deepLinkBillID(forGUID: guid)
            if billsStore.bill(for: groupBillID) != nil {
                resolvedBillID = groupBillID
                return
            }
        }

        if let billID = item.billID, billsStore.bill(for: billID) != nil {
            resolvedBillID = billID
            return
        }

        if let guid = item.billGuid, let existing = billsStore.bill(forGUID: guid) {
            resolvedBillID = existing.id
            return
        }

        guard let guid = item.billGuid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty else {
            errorMessage = "This item has no bill to open."
            return
        }

        // The on-demand load deep links use (APPF-26): the same request and merge as before, plus 404 vs failure.
        switch await billsStore.loadLinkedBill(BillLinkTarget(billID: UUID.deterministic(from: guid), guid: guid)) {
        case .loaded(let billID):
            resolvedBillID = billID
        case .cancelled:
            return
        case .notFound, .failed:
            errorMessage = "We couldn't load this bill right now."
        }
    }
}

private struct WeeklyDigestMemberDestinationView: View {
    let item: WeeklyDigestItem

    @EnvironmentObject private var congressManifestStore: CongressMembersManifestStore

    @State private var manifestItem: CongressMemberManifestItem?
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let manifestItem {
                CongressMemberProfileLoaderView(manifest: manifestItem)
            } else if isLoading {
                WeeklyDigestUnavailableView.loading(message: "Loading this member.")
            } else {
                WeeklyDigestUnavailableView(
                    title: "Couldn't open this member",
                    message: errorMessage ?? "Try again in a moment."
                ) {
                    Task { await resolveManifestIfNeeded(forceRefresh: true) }
                }
            }
        }
        // The loading and unavailable states get the pushed screen's glass bar too (spec 3.21); the
        // member page sets its own.
        .glassNavigationBar()
        .task(id: item.id) {
            await resolveManifestIfNeeded()
        }
    }

    @MainActor
    private func resolveManifestIfNeeded(forceRefresh: Bool = false) async {
        if !forceRefresh, manifestItem != nil { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let bioguideID = item.primaryMemberBioguideID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bioguideID.isEmpty else {
            errorMessage = "This item has no member to open."
            return
        }

        if let cached = lookupManifestItem(bioguideID: bioguideID, in: congressManifestStore.items) {
            manifestItem = cached
            return
        }

        if let cachedManifest = CongressService.cachedCongressMembersManifest(),
           let cached = lookupManifestItem(bioguideID: bioguideID, in: cachedManifest) {
            manifestItem = cached
            return
        }

        await congressManifestStore.load(forceRefresh: forceRefresh)
        if let loaded = lookupManifestItem(bioguideID: bioguideID, in: congressManifestStore.items) {
            manifestItem = loaded
            return
        }

        errorMessage = "We couldn't find this member right now."
    }

    private func lookupManifestItem(
        bioguideID: String,
        in manifest: [CongressMemberManifestItem]
    ) -> CongressMemberManifestItem? {
        manifest.first { $0.id.caseInsensitiveCompare(bioguideID) == .orderedSame }
    }
}

/// A Weekly Brief destination before its page exists (spec 4.52), on the `document` ground the bill and
/// member pages have: while loading, a spinner in ink with its caption; when it cannot open, a
/// `RecordNotice` with COULDN'T LOAD, the reason and a secondary "Try again".
struct WeeklyDigestUnavailableView: View {
    let title: String
    let message: String
    var retryAction: (() -> Void)?

    init(title: String, message: String, retryAction: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retryAction = retryAction
    }

    static func loading(message: String) -> WeeklyDigestUnavailableView {
        WeeklyDigestUnavailableView(title: "", message: message)
    }

    var body: some View {
        Group {
            if let retryAction {
                ScrollView {
                    RecordNotice(
                        .couldNotLoad,
                        title: title,
                        message: message,
                        action: .init(title: "Try again", perform: retryAction)
                    )
                    .padding(.horizontal, BillboardStyle.Space.xl)
                    .padding(.top, BillboardStyle.Space.l)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(BillboardColors.interactive)
                    Text(message)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(BillboardStyle.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BillboardColors.document.ignoresSafeArea())
    }
}

// MARK: - Item helpers

extension WeeklyDigestItem {
    /// The vote bar the item's bill opens with: a decided bill can be voted on too (project decision 1).
    var billDetailMode: BillDetail.Mode {
        BillDetail.Mode(opening: billState)
    }
}

extension WeeklyDigestItem.BillState {
    /// The status word: "Became law" for `finalized` (REL-44), as on the stamp.
    var title: String {
        StatusStamp.Kind(status: billStatus).word
    }
}
