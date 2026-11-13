import SwiftUI

/// A bill card on Bills, Search, the Watching, Voted, Passed and Skipped lists, topic and life-area
/// details and member bills, drawn as a docket slip (Civic Record spec 3.4). It reads the bill, the
/// profile's follows and the companion group the list passes down, and nothing else: it carries no
/// vote data at all, neither other users' votes (INT-11) nor the reader's own (project decision 5).
struct BillCard: View {
    let bill: Bill
    /// Shown as a second docket line under the bill number, e.g. "Identical to H.R. 900" on a member
    /// page (APPF-23).
    var numberSubtitle: String?
    @EnvironmentObject private var userStore: UserStore
    /// Set where the card stands for a companion group (APPF-23): Home, search and the quick lists.
    @Environment(\.billCardCompanions) private var companionsByBillID

    var body: some View {
        BillSlip(
            content: BillSlipContent(
                bill: bill,
                profile: userStore.profile,
                companion: companionsByBillID[bill.id],
                numberSubtitle: numberSubtitle,
                sponsor: bill.sponsorMemberID
                    .flatMap { CongressService.congressMember(for: $0) }
                    .map { BillSlipContent.Sponsor(member: $0) }
            )
        )
    }
}

// MARK: - What a slip shows

/// Everything a bill slip shows, worked out once from the bill (spec 3.4): the docket line, the title,
/// the index tags, the sponsor and the last-updated date, and the one sentence VoiceOver reads. A value,
/// so the slip can be drawn and tested without a store. No vote data: no counts, no count bucket, no
/// combined companion count and no vote mark (INT-11; project decision 5).
struct BillSlipContent: Equatable {
    /// The sponsor on the slip's stub.
    struct Sponsor: Equatable {
        let name: String
        let party: PoliticalParty
        /// The seat, for VoiceOver only: the slip shows name and party letter, the sentence the whole
        /// spoken form (project decision of 2026-10-21: one spoken form everywhere, slips included).
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

        /// "Sponsor: Representative Jordan Ellis, Republican, Texas's 7th district", the bill page's
        /// sponsor sentence (`CongressMemberLabel.spokenDescription`).
        var spokenSentence: String {
            "Sponsor: " + CongressMemberLabel.spokenDescription(
                name: name,
                party: party,
                state: stateCode,
                district: district,
                chamber: chamber
            )
        }
    }

    /// The generated plain-language title.
    var title: String
    /// The bill number, or a companion group's numbers, primary first; empty when unknown.
    var numbers: [String]
    /// The bill's status, or the group's (its status lead's).
    var status: BillStatus
    /// The number of the group member whose status the slip shows, when it is not the primary: the
    /// stamp then reads "S. 456 PASSED".
    var companionLead: String? = nil
    /// The reader watches the bill (or a member of its group). The binoculars mark shows only when
    /// the status is Updated (spec 3.1).
    var isWatched = false
    /// A second docket line naming the bill's companions: "Identical to H.R. 900".
    var subtitle: String? = nil
    /// Up to three interest tags, after the "Identical bills" tag of a group.
    var tags: [IndexTag.Kind] = []
    var sponsor: Sponsor? = nil
    /// When the bill's record was last stored (`Bill.storedAt`): the bill page's "Last updated" date.
    var lastUpdated: Date? = nil

    /// The most interest tags a slip shows (In the news, Member you follow, the topic, the life areas).
    static let maximumInterestTags = 3

    init(
        title: String,
        numbers: [String],
        status: BillStatus,
        companionLead: String? = nil,
        isWatched: Bool = false,
        subtitle: String? = nil,
        tags: [IndexTag.Kind] = [],
        sponsor: Sponsor? = nil,
        lastUpdated: Date? = nil
    ) {
        self.title = title
        self.numbers = numbers
        self.status = status
        self.companionLead = companionLead
        self.isWatched = isWatched
        self.subtitle = subtitle
        self.tags = tags
        self.sponsor = sponsor
        self.lastUpdated = lastUpdated
    }

    /// The slip of `bill` for a reader with `profile`. A companion group's slip (`companion`) shows
    /// every member's number, the group's status lead and the "Identical bills" tag.
    init(
        bill: Bill,
        profile: UserProfile,
        companion: BillCompanionDisplay? = nil,
        numberSubtitle: String? = nil,
        sponsor: Sponsor? = nil
    ) {
        var tags: [IndexTag.Kind] = []
        if let companion {
            tags.append(companion.isIdentical ? .identicalBills : .custom(title: companion.tag, systemImage: "doc.on.doc", spoken: nil))
        }
        tags += Array(Self.interestTags(for: bill, profile: profile).prefix(Self.maximumInterestTags))

        let lead = companion?.statusLead
        self.init(
            title: bill.title,
            numbers: companion?.numbers ?? bill.officialBillNumber.map { [$0] } ?? [],
            status: lead?.status ?? bill.billStatus,
            companionLead: lead.flatMap { $0.isPrimary ? nil : $0.billNumber },
            isWatched: bill.userWatched || companion?.isWatched == true,
            subtitle: numberSubtitle.flatMap { $0.isEmpty ? nil : $0 },
            tags: tags,
            sponsor: sponsor,
            lastUpdated: FlexibleISO8601.parse(bill.storedAt)
        )
    }

    /// Why the bill is on the reader's list, in R2's order: In the news, Member you follow, the topic,
    /// then up to two followed life areas.
    static func interestTags(for bill: Bill, profile: UserProfile) -> [IndexTag.Kind] {
        var tags: [IndexTag.Kind] = []
        if bill.hasActivePriority {
            tags.append(.inTheNews)
        }
        if bill.matchesSubscribedMembers(profile) {
            tags.append(.memberYouFollow)
        }
        if let topic = bill.subCategory, profile.subscribedSubCategories.contains(topic) {
            tags.append(.topic(topic))
        }
        let lifeAreas = bill.lifeAreas.filter { area in profile.subscribedLifeAreas.contains(where: { $0 == area }) }
        tags += lifeAreas.prefix(2).map(IndexTag.Kind.lifeArea)
        return tags
    }

    /// The stamp in the docket line.
    var stamp: StatusStamp.Kind {
        companionLead.map { .companionLead(number: $0, status: status) } ?? StatusStamp.Kind(status: status)
    }

    /// The binoculars mark shows: a watched bill whose status is Updated.
    var showsWatchedMark: Bool {
        isWatched && status == .updated
    }

    /// Whether the slip has a stub (the perforation, the sponsor and the date).
    var hasStub: Bool {
        sponsor != nil || lastUpdated != nil
    }

    /// The stub's date as printed ("Oct 14"; the `docket` role sets it in capitals) and as VoiceOver reads
    /// it ("October 14"). A date in another year than `now`'s carries the year.
    func lastUpdatedText(now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> (printed: String, spoken: String)? {
        guard let lastUpdated else { return nil }
        return DocketDate.monthDay(lastUpdated, now: now, locale: locale, timeZone: timeZone)
    }

    /// The one sentence VoiceOver reads for the slip (spec 3.4): "Clean Energy Reporting Act. House bill
    /// 1234. New. In the news. Topic: Energy. Sponsor: Representative Jordan Ellis, Republican, Texas's 7th
    /// district. Last updated October 14."
    /// Bill numbers are spoken ("House bill 1234", spec 1.7). Never a vote.
    func accessibilityLabel(now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var sentences = [title]
        if !numbers.isEmpty {
            sentences.append(BillDisplayFormatting.naturalList(numbers.map(SpokenForm.billNumber)))
        }
        sentences.append(stamp.spokenWord)
        if showsWatchedMark {
            sentences.append("Watching")
        }
        if let subtitle {
            sentences.append(Self.spokenBillNumbers(in: subtitle))
        }
        sentences += tags.map(\.accessibilityLabel)
        if let sponsor {
            sentences.append(sponsor.spokenSentence)
        }
        if let date = lastUpdatedText(now: now, locale: locale, timeZone: timeZone) {
            sentences.append("Last updated \(date.spoken)")
        }
        return SpokenSentences.join(sentences)
    }

    /// Every bill number in `text` in its spoken form: "Identical to H.R. 900 and S. 456" → "Identical to
    /// House bill 900 and Senate bill 456".
    static func spokenBillNumbers(in text: String) -> String {
        let pattern = #"\b(?:H\.\s?R\.|H\.\s?(?:J\.\s?|Con\.\s?)?Res\.|S\.\s?(?:J\.\s?|Con\.\s?)?Res\.|S\.)\s?\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var spoken = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: spoken) else { continue }
            spoken.replaceSubrange(range, with: SpokenForm.billNumber(String(spoken[range])))
        }
        return spoken
    }
}

// MARK: - The slip

private nonisolated struct BillSlipPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The slip below is being pressed: its sheet turns `well` (spec 3.4). No scale, no haptic.
    var billSlipIsPressed: Bool {
        get { self[BillSlipPressedKey.self] }
        set { self[BillSlipPressedKey.self] = newValue }
    }
}

/// The docket slip (Civic Record spec 3.4): a `sheet` with a 1 pt `rule` and the slip radius, no
/// shadow, stripe or wash. Top to bottom: the `DocketLine` (number, chamber, the watched mark and the
/// status stamp), the title in the `heading` role, the ink index tags, and the stub under a perforation:
/// the sponsor's monogram with the party disc, the name and the party letter in text ("Jordan Ellis
/// · R"), and the last-updated date at the trailing edge. When the sponsor and the date do not fit on
/// one line, and at every accessibility size, the date goes under the sponsor. No sponsor: the stub is
/// the date alone; no sponsor and no date: no stub.
///
/// One VoiceOver element (`BillSlipContent.accessibilityLabel`).
struct BillSlip: View {
    let content: BillSlipContent

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.billSlipIsPressed) private var isPressed

    /// Padding inside the slip: 14 pt at the top, 16 pt at the sides, and at the bottom when there is
    /// no stub.
    static let topPadding: CGFloat = 14
    static let sidePadding = BillboardStyle.Space.l

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        let ground = isPressed ? BillboardColors.secondaryBackground : BillboardColors.cardBackground
        let date = content.lastUpdatedText()

        VStack(alignment: .leading, spacing: 0) {
            docket

            Text(content.title)
                .textRole(.heading)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BillboardStyle.Space.s)

            if !content.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(content.tags.enumerated()), id: \.offset) { _, tag in
                        IndexTag(tag)
                    }
                }
                .padding(.top, 10)
            }

            if content.hasStub {
                VStack(alignment: .leading, spacing: 0) {
                    PerforationRule()
                        .padding(.horizontal, -Self.sidePadding)
                    stub(date: date?.printed, ground: ground)
                        .padding(.top, 10)
                        .padding(.bottom, BillboardStyle.Space.m)
                }
                .padding(.top, 13)
            }
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.top, Self.topPadding)
        .padding(.bottom, content.hasStub ? 0 : BillboardStyle.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // As tall as its content whatever height a stack offers (its stamps and tags have minimum
        // heights, which a smaller offer would squeeze).
        .fixedSize(horizontal: false, vertical: true)
        .background(ground, in: shape)
        // Inside the edge, so nothing is drawn outside the slip's frame.
        .overlay(shape.strokeBorder(BillboardColors.separator, lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel())
    }

    @ViewBuilder
    private var docket: some View {
        if content.numbers.count == 1, let number = content.numbers.first {
            DocketLine(
                numbers: [number],
                chamber: DocketLine.chamber(forBillNumber: number),
                status: content.status,
                companionLead: content.companionLead,
                isWatched: content.isWatched
            )
        } else {
            DocketLine(
                numbers: content.numbers,
                chamber: nil,
                status: content.status,
                companionLead: content.companionLead,
                isWatched: content.isWatched
            )
        }
        if let subtitle = content.subtitle {
            Text(subtitle)
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    // MARK: Stub

    @ViewBuilder
    private func stub(date: String?, ground: Color) -> some View {
        if let sponsor = content.sponsor {
            if dynamicTypeSize.isAccessibilitySize {
                stackedStub(sponsor, date: date, ground: ground)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 9) {
                        sponsorLine(sponsor, ground: ground)
                            .fixedSize()
                        if let date {
                            Spacer(minLength: BillboardStyle.Space.s)
                            dateText(date)
                        }
                    }
                    stackedStub(sponsor, date: date, ground: ground)
                }
            }
        } else if let date {
            dateText(date)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func stackedStub(_ sponsor: BillSlipContent.Sponsor, date: String?, ground: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sponsorLine(sponsor, ground: ground)
            if let date {
                dateText(date)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The monogram with its party disc, the name, and the party letter in text: the disc's 7 pt letter is
    /// too small to be the only place the party is written (spec 3.14).
    private func sponsorLine(_ sponsor: BillSlipContent.Sponsor, ground: Color) -> some View {
        HStack(alignment: .center, spacing: 9) {
            monogram(sponsor, ground: ground)
            sponsorText(sponsor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Jordan Ellis · R": the name in `subheadline` ink, then the letter in `docket` ink3, as one run of
    /// text, so a long name wraps with the letter after its last word.
    private func sponsorText(_ sponsor: BillSlipContent.Sponsor) -> Text {
        let nameSize = TextRole.subheadline.scaledSize(for: dynamicTypeSize)
        let letterSize = TextRole.docket.scaledSize(for: dynamicTypeSize)
        let name = Text(sponsor.name)
            .font(TextRole.subheadline.font(size: nameSize))
            .foregroundStyle(BillboardColors.primaryText)
        let letter = Text("\u{00A0}·\u{00A0}\(sponsor.party.letter)")
            .font(TextRole.docket.font(size: letterSize))
            .tracking(TextRole.docket.trackingEm * letterSize)
            .foregroundStyle(BillboardColors.dimText)
        return Text("\(name)\(letter)")
    }

    private func monogram(_ sponsor: BillSlipContent.Sponsor, ground: Color) -> some View {
        CongressMemberAvatar(url: sponsor.photoURL, name: sponsor.name, size: .stub, party: sponsor.party, groundColor: ground)
    }

    private func dateText(_ date: String) -> some View {
        Text(date)
            .textRole(.docket)
            .foregroundStyle(BillboardColors.dimText)
            .fixedSize()
    }
}

// MARK: - Companion group display (APPF-23)

/// What a bill card (and the detail header) shows for a companion group: every member's number
/// ("H.R. 900 · S. 456"), its accessibility label, the "Identical bills" tag, the status lead and whether
/// the reader watches any member. No vote counts (INT-11).
nonisolated struct BillCompanionDisplay: Equatable, Sendable {
    /// Every member's number, primary first.
    let numbers: [String]
    let numbersLabel: String
    let accessibilityLabel: String
    let tag: String
    let isIdentical: Bool
    let statusLead: CompanionStatusLead?
    /// The reader watches a member of the group.
    let isWatched: Bool

    init(group: BillCompanionGroup, statusLead: CompanionStatusLead?, isWatched: Bool = false) {
        numbers = group.memberGuids.map(CompanionGroupIndex.billNumber(forGUID:))
        numbersLabel = CompanionGroupIndex.numbersLabel(for: group)
        accessibilityLabel = CompanionGroupIndex.accessibilityLabel(for: group)
        tag = BillDisplayFormatting.companionTag(isIdentical: group.isIdentical)
        isIdentical = group.isIdentical
        self.statusLead = statusLead
        self.isWatched = isWatched
    }

    /// A group's display from the store's loaded members: the status lead and the watch.
    @MainActor
    static func make(for group: BillCompanionGroup, in store: BillsStore) -> BillCompanionDisplay {
        BillCompanionDisplay(
            group: group,
            statusLead: store.companionStatusLead(for: group),
            isWatched: group.memberGuids.contains { member in store.loadedBills(ofMember: member).contains(where: \.userWatched) }
        )
    }

    /// The display of each grouped bill in `bills`, by bill id, for `View.environment(\.billCardCompanions, _)`.
    /// Empty when the store has no groups.
    @MainActor
    static func lookup(for bills: [Bill], in store: BillsStore) -> [UUID: BillCompanionDisplay] {
        let companions = store.companionGroupIndex
        guard !companions.isEmpty else { return [:] }
        var byGroup: [String: BillCompanionDisplay] = [:]
        var lookup: [UUID: BillCompanionDisplay] = [:]
        for bill in bills {
            guard let group = companions.group(for: bill) else { continue }
            if let display = byGroup[group.primaryGuid] {
                lookup[bill.id] = display
            } else {
                let display = make(for: group, in: store)
                byGroup[group.primaryGuid] = display
                lookup[bill.id] = display
            }
        }
        return lookup
    }
}

extension BillBoardItem {
    /// The card display of a Home item that stands for a companion group; nil for a single bill.
    var companionDisplay: BillCompanionDisplay? {
        guard let companionGroup else { return nil }
        return BillCompanionDisplay(
            group: companionGroup,
            statusLead: statusLead,
            isWatched: bill.userWatched || memberBills.contains(where: \.userWatched)
        )
    }
}

private nonisolated struct BillCardCompanionsKey: EnvironmentKey {
    static let defaultValue: [UUID: BillCompanionDisplay] = [:]
}

extension EnvironmentValues {
    /// The companion groups the `BillCard`s below stand for, by the card bill's id (APPF-23). Empty
    /// (the default) shows every card as its own bill, as member pages and insights do.
    var billCardCompanions: [UUID: BillCompanionDisplay] {
        get { self[BillCardCompanionsKey.self] }
        set { self[BillCardCompanionsKey.self] = newValue }
    }
}

#Preview("Bill slips") {
    ScrollView {
        VStack(spacing: 12) {
            BillSlip(content: BillSlipContent(
                title: "Clean Energy Reporting Act",
                numbers: ["H.R. 1234"],
                status: .new,
                tags: [.inTheNews, .topic("Energy")],
                sponsor: .init(name: "Jordan Ellis", party: .republican),
                lastUpdated: Date()
            ))
            BillSlip(content: BillSlipContent(
                title: "Protecting Veterans Act",
                numbers: ["H.R. 10", "S. 10"],
                status: .passed,
                companionLead: "S. 10",
                tags: [.identicalBills, .memberYouFollow],
                sponsor: .init(name: "Priya Natarajan", party: .democratic),
                lastUpdated: Date()
            ))
            BillSlip(content: BillSlipContent(title: "Heritage Month Act", numbers: ["H.R. 498"], status: .finalized, lastUpdated: Date()))
        }
        .padding(16)
    }
    .background(BillboardColors.background)
}
