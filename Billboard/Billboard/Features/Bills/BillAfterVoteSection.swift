import SwiftUI

// MARK: - What happens next (UX-41 concept 1)
//
// Right after a vote made on the bill page, in place of Compare with Congress (the rebuild UX-34 N1 offered): the
// bill's latest action, the person's own members of Congress and how each voted on this bill under their own vote,
// and whether they'll be told when Congress acts. A project decision of 2026-11-23 (D83 (a)) approved the block and
// its words (`AfterVoteCopy`). It shows official Congress data and the person's own vote, never another user's, so
// INT-11 does not seal it.

/// What the What happens next block says after a vote made on the page (UX-41 concept 1), worked out from the bill,
/// the vote, the person's members and their notification settings, so it is tested without a page.
///
/// It never says a chamber has no recorded vote unless it knows. A companion group's other member is read too, since
/// a chamber's roll call may sit on it, and a chamber whose other member is not loaded gets no line. So does a chamber
/// whose actions mention a recorded vote that its roll call does not hold yet. A representative missing from their
/// chamber's roll call (sworn in later) gets no row, never "Not voting", and the person's members are not listed while
/// the members manifest has not loaded.
///
/// Neutral by construction: only the "You" row depends on the vote, the members come in roster order, and nothing
/// compares the vote with theirs.
struct AfterVoteSummary: Equatable {
    /// What the page knows of the person's members of Congress.
    enum Representatives {
        /// The profile has loaded and has no state.
        case noAddress
        /// The profile, or the members manifest, has not loaded: Your representatives is left out until it has.
        case notLoaded
        /// The person's state and district, and the members manifest (`CongressMembersManifestStore.items`).
        case known(state: String, district: String, manifest: [CongressMemberManifestItem])
    }

    /// The bill's last action as Congress words it, and its date.
    struct LatestAction: Equatable {
        let text: String
        /// "Oct 27", with the year when it is not this year; nil when the action has no date.
        let date: String?
        /// "October 27".
        let spokenDate: String?

        /// "Latest action: Referred to the Committee on Energy and Commerce. October 27."
        var accessibilityLabel: String {
            "\(AfterVoteCopy.latestActionLabel): \(SpokenSentences.join([text, spokenDate]))"
        }
    }

    /// One of the person's members, as their chamber's roll call on this bill records them.
    struct MemberRow: Equatable, Identifiable {
        let member: Bill.OfficialVoteMember
        let chamber: CongressChamber

        var id: String { member.bioguideId.uppercased() }

        /// How Congress voted's row for the member, with no "your senator" tag: the subhead says whose they are.
        private var row: CongressMemberVoteRow {
            CongressMemberVoteRow(member: member, chamber: chamber)
        }

        /// "✓ Yea", "✕ Nay", "Present" or "Not voting", worded as How Congress voted words them.
        var position: (choice: VoteChoice?, word: String) {
            CongressMemberVoteRow.position(member.votePosition)
        }

        /// "D · Senate · VA": the party as a letter.
        var affiliation: String? { row.affiliation }

        /// "Senator Tim Kaine, Democrat, Virginia, Nay".
        var accessibilityLabel: String { row.accessibilityLabel }
    }

    /// Your representatives: the person's vote, then their members.
    struct RepresentativesPart: Equatable {
        /// The "You" row.
        let you: VoteChoice
        /// Their senators in roster order, then their House member (`CongressTabModel.representatives`), each on
        /// their own chamber's roll call by How Congress voted's rule (`YourMembersOnRollCalls`).
        let members: [MemberRow]
        /// "Add your address in Profile to see how your representatives voted." under the "You" row.
        let asksForAddress: Bool
    }

    /// What the bill, and a companion group's other members, say of one chamber.
    enum ChamberRecord: Equatable {
        /// A recorded vote, with its roll call when the bill carries one (only the counts otherwise).
        case recorded(Bill.OfficialChamberVote?)
        /// Passed with no recorded vote: a voice vote or unanimous consent.
        case passedWithoutRecordedVote
        case noRecordedVote
        /// Not known: a companion group's other member is not loaded, or an action mentions a recorded vote that no
        /// roll call holds yet. The chamber gets no line.
        case unknown
    }

    let latestAction: LatestAction?
    /// Nil while the person's profile or the members manifest has not loaded.
    let representatives: RepresentativesPart?
    /// "The Senate hasn't held a recorded vote on this bill.", House first; or "Congress hasn't held a recorded vote on
    /// this bill yet." for both.
    let chamberLines: [String]
    /// "You'll get notified when Congress acts on it.", or why this device won't be; nil when the bill is watched (the
    /// Watch row says it), while the vote is not saved yet (APPF-30), and on a bill of a Congress that has ended.
    let promise: String?

    /// - Parameters:
    ///   - companions: a companion group's other members, each its loaded bill with details, or nil while it is not
    ///     loaded; empty for a bill in no group.
    ///   - block: why notifications can't reach this device for a bill the person follows
    ///     (`BillWatchNotificationBlock.make(…, isWatching: true, …)`: nothing asks for iOS's permission after a vote).
    ///   - isWatching: the bill, or a member of its group, is watched.
    ///   - isVoteSaved: the vote is not marked "Not saved yet" (APPF-30).
    ///   - now: when the page is drawn, which says the Congress in office.
    init(
        bill: Bill,
        vote: VoteChoice,
        representatives: Representatives,
        companions: [Bill?] = [],
        block: BillWatchNotificationBlock?,
        isWatching: Bool,
        isVoteSaved: Bool,
        now: Date = CongressCalendar.now(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        // One rule for an ended Congress, How Congress voted's (`YourMembersOnRollCalls`): it picks the seats, and it
        // drops the promise and the "yet" line.
        let seats = Self.seats(representatives, billCongress: BillOfficialVotesSection.congress(of: bill), now: now)
        let isFromEndedCongress = seats.isFromEndedCongress
        var records: [CongressChamber: ChamberRecord] = [:]
        let chambers = Self.chambers(of: [bill] + companions.compactMap { $0 })
        for chamber in chambers {
            records[chamber] = Self.record(of: chamber, bill: bill, companions: companions)
        }

        latestAction = Self.latestAction(for: bill, now: now, locale: locale, timeZone: timeZone)
        self.representatives = Self.representativesPart(representatives, vote: vote, seats: seats, records: records)
        chamberLines = Self.chamberLines(chambers.map { ($0, records[$0] ?? .unknown) }, isFromEndedCongress: isFromEndedCongress)
        promise = isWatching || !isVoteSaved || isFromEndedCongress ? nil : AfterVoteCopy.promise(blockedBy: block)
    }

    // MARK: Latest action

    /// The page's LATEST ACTION (`BillCompanionMemberRow.latestAction(for:)`'s choice: the last action of the
    /// timeline, in Congress's words), with the short date; nil when no action has text.
    static func latestAction(for bill: Bill, now: Date, locale: Locale, timeZone: TimeZone) -> LatestAction? {
        guard let action = BillDisplayFormatting.timelineActions(bill.actions).last,
              let text = BillDisplayFormatting.timelineText(for: action) else { return nil }
        let raw = action.actionDate?.trimmedNonEmpty
        guard let raw, let date = FlexibleISO8601.parse(raw) else {
            return LatestAction(text: text, date: nil, spokenDate: nil)
        }
        // A calendar day ("2026-10-27") is read in UTC, so it never moves to the day before.
        let isCalendarDay = raw.count == 10 && !raw.contains("T")
        let zone = isCalendarDay ? TimeZone(secondsFromGMT: 0) ?? timeZone : timeZone
        let (printed, spoken) = DocketDate.monthDay(date, now: now, locale: locale, timeZone: zone, nowTimeZone: timeZone)
        return LatestAction(text: text, date: printed, spokenDate: spoken)
    }

    // MARK: Your representatives

    /// How Congress voted's tags for the person's members (`YourMembersOnRollCalls`), which also say whether the bill's
    /// Congress has ended (an unknown Congress counts as ended). With no members known, none are tagged.
    private static func seats(_ representatives: Representatives, billCongress: Int?, now: Date) -> YourMembersOnRollCalls {
        guard case let .known(state, district, manifest) = representatives else {
            return YourMembersOnRollCalls(state: "", district: "", manifest: [], billCongress: billCongress, now: now)
        }
        return YourMembersOnRollCalls(state: state, district: district, manifest: manifest, billCongress: billCongress, now: now)
    }

    private static func representativesPart(
        _ representatives: Representatives,
        vote: VoteChoice,
        seats: YourMembersOnRollCalls,
        records: [CongressChamber: ChamberRecord]
    ) -> RepresentativesPart? {
        switch representatives {
        case .notLoaded:
            return nil
        case .noAddress:
            return RepresentativesPart(you: vote, members: [], asksForAddress: true)
        case let .known(state, district, manifest):
            guard !state.uppercasedTrimmed.isEmpty else {
                return RepresentativesPart(you: vote, members: [], asksForAddress: true)
            }
            guard !manifest.isEmpty else { return nil }
            let members = Self.members(
                CongressTabModel.representatives(state: state, district: district, in: manifest),
                seats: seats,
                records: records
            )
            return RepresentativesPart(you: vote, members: members, asksForAddress: false)
        }
    }

    /// The person's members on this bill's roll calls, in the order of `representatives`
    /// (`CongressTabModel.representatives`): each on their own chamber's roll call, in the person's seat once the
    /// bill's Congress has ended (`seats`, the rule that tags them in How Congress voted). One missing from the roll
    /// call is left out.
    static func members(
        _ representatives: [CongressMemberManifestItem],
        seats: YourMembersOnRollCalls,
        records: [CongressChamber: ChamberRecord]
    ) -> [MemberRow] {
        representatives.compactMap { representative in
            let chamber: CongressChamber = representative.chamberNormalized == CongressChamber.senate.rawValue ? .senate : .house
            guard case .recorded(let rollCall)? = records[chamber], let rollCall else { return nil }
            let id = representative.id.uppercased()
            guard let row = rollCall.members.first(where: { $0.bioguideId.uppercased() == id }),
                  seats.role(of: row, in: chamber) != nil else { return nil }
            return MemberRow(member: row, chamber: chamber)
        }
    }

    // MARK: Chambers

    /// The chambers a bill goes through: a simple resolution only its own, every other bill both. House first.
    static func chambers(of bills: [Bill]) -> [CongressChamber] {
        var chambers = Set<CongressChamber>()
        for bill in bills {
            switch bill.billTypeCode {
            case "hres": chambers.insert(.house)
            case "sres": chambers.insert(.senate)
            default: chambers.formUnion([.house, .senate])
            }
        }
        return [CongressChamber.house, .senate].filter(chambers.contains)
    }

    /// What `chamber` has done with the bill, from the bill and its group's other members.
    static func record(of chamber: CongressChamber, bill: Bill, companions: [Bill?]) -> ChamberRecord {
        let loaded = [bill] + companions.compactMap { $0 }
        if let source = loaded.first(where: { hasRecordedVote(in: chamber, $0) }) {
            return .recorded(chamber == .house ? source.officialVotes?.house : source.officialVotes?.senate)
        }
        // The roll call may sit on a member that is not loaded.
        if companions.contains(where: { $0 == nil }) { return .unknown }
        if loaded.contains(where: { mentionsRecordedVote(in: chamber, $0.actions) }) { return .unknown }
        if loaded.contains(where: { actionsShowPassage(in: chamber, $0.actions) }) { return .passedWithoutRecordedVote }
        return .noRecordedVote
    }

    /// The bill carries a roll call for `chamber`, or its counts (How Congress voted's `CongressChamberTally`).
    static func hasRecordedVote(in chamber: CongressChamber, _ bill: Bill) -> Bool {
        CongressChamberTally.tallies(for: bill).contains { $0.chamber == chamber }
    }

    /// The actions show `chamber` passed the bill, read as `EndedCongress.actionsShowPassage` reads them: the chamber's
    /// passage code, or the bill reaching the President, which both chambers passed.
    static func actionsShowPassage(in chamber: CongressChamber, _ actions: [Bill.BillAction]) -> Bool {
        let code = passageCode(of: chamber)
        return actions.contains { action in
            let type = trimmed(action.type).lowercased()
            return trimmed(action.actionCode) == code || type == "president" || type == "veto"
        }
    }

    /// An action mentions a recorded vote in `chamber`, as the server's roll-call search reads action text. A House
    /// roll call ("(Roll no. 150)") and a Senate one ("Yea-Nay Vote. 51 - 43. Record Vote Number: 623.") name their
    /// chamber by their form, whatever else the text says: a House floor action often does not name the House.
    /// Other words for a recorded vote (yeas and nays, a recorded vote, a roll call) count for the chamber whose
    /// passage code the action has, or else each chamber it names.
    static func mentionsRecordedVote(in chamber: CongressChamber, _ actions: [Bill.BillAction]) -> Bool {
        actions.contains { recordedVoteChambers(of: $0).contains(chamber) }
    }

    /// The chambers whose recorded vote `action` may mention: none when it mentions no recorded vote.
    static func recordedVoteChambers(of action: Bill.BillAction) -> Set<CongressChamber> {
        let text = trimmed(action.text)
        func matches(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if matches(houseRollCallPattern) { return [.house] }
        if matches(senateRecordVotePattern) { return [.senate] }
        guard matches(recordedVotePattern) else { return [] }
        let code = trimmed(action.actionCode)
        if code == passageCode(of: .house) { return [.house] }
        if code == passageCode(of: .senate) { return [.senate] }
        return Set([CongressChamber.house, .senate].filter { text.contains(CongressMemberLabel.chamberWord($0)) })
    }

    /// The House Clerk's roll call: "(Roll no. 150)".
    private static let houseRollCallPattern = #"\broll\s+no\.?\s*\d"#
    /// The Senate's: "by Yea-Nay Vote. 51 - 43. Record Vote Number: 623."
    private static let senateRecordVotePattern = #"\brecord\s+vote\s+(number|no\.?)\s*:?\s*\d|\byea[-\s]?nay\s+vote\b"#
    private static let recordedVotePattern = #"\byeas?\s+and\s+nays?\b|\broll\s*call\b|\brecord(ed)?\s+vote\b"#

    private static func passageCode(of chamber: CongressChamber) -> String {
        chamber == .house ? EndedCongress.housePassageCode : EndedCongress.senatePassageCode
    }

    /// One line per chamber with no recorded vote or a passage without one, House first; "Congress hasn't held a
    /// recorded vote on this bill yet." when both chambers have none, except on a bill of a Congress that has ended,
    /// which keeps the two lines (the page's ENDED stamp and note say the rest).
    static func chamberLines(_ records: [(CongressChamber, ChamberRecord)], isFromEndedCongress: Bool) -> [String] {
        if records.count == 2, records.allSatisfy({ $0.1 == .noRecordedVote }), !isFromEndedCongress {
            return [AfterVoteCopy.noRecordedVoteYet]
        }
        return records.compactMap { chamber, record in
            switch record {
            case .noRecordedVote: return AfterVoteCopy.noRecordedVote(in: chamber)
            case .passedWithoutRecordedVote: return AfterVoteCopy.passedWithoutRecordedVote(in: chamber)
            case .recorded, .unknown: return nil
            }
        }
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What happens next (UX-41 concept 1): right after a vote made on the page, between Results and Done. LATEST ACTION
/// as the page's ledgers set it; Your representatives, a subhead over the "You" row and the person's members, each a
/// name, the docket affiliation led by the party letter and the position; the chamber lines; the promise. Ink only,
/// but for the vote symbols and words in their colours: no party colour, no agree or disagree words. It fades in with
/// the post-vote block (nothing moves) and the promise with the not-saved strip's 0.2 s cross-fade; with Reduce Motion
/// both appear at once. No haptic.
///
/// VoiceOver reads the title (a header), the latest action, the subhead (a header), "You, Yea.", each member
/// ("Senator Tim Kaine, Democrat, Virginia, Nay"), then the lines.
struct BillAfterVoteSection: View {
    let summary: AfterVoteSummary
    var showsRule = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let youIdentifier = "bill.afterVote.you"

    var body: some View {
        RecordSection(AfterVoteCopy.title, showsRule: showsRule) {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                if let latest = summary.latestAction {
                    latestActionRow(latest)
                }
                if let part = summary.representatives {
                    representatives(part)
                }
                if !summary.chamberLines.isEmpty {
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                        ForEach(summary.chamberLines, id: \.self) { line in
                            note(line)
                        }
                    }
                }
                if let promise = summary.promise {
                    note(promise)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
        .transition(reduceMotion ? .identity : .opacity)
    }

    private func latestActionRow(_ latest: AfterVoteSummary.LatestAction) -> some View {
        LedgerRow(label: AfterVoteCopy.latestActionLabel, column: .inCongress, accessibilityLabel: latest.accessibilityLabel) {
            Text(latest.text)
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let date = latest.date {
                Text(date)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func representatives(_ part: AfterVoteSummary.RepresentativesPart) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AfterVoteCopy.representativesTitle)
                .textRole(.name)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, BillboardStyle.Space.xs)
            AfterVotePositionRow(
                name: AfterVoteCopy.you,
                affiliation: nil,
                choice: part.you,
                word: part.you.title,
                accessibilityLabel: AfterVoteCopy.youAccessibilityLabel(part.you)
            )
            .accessibilityIdentifier(Self.youIdentifier)
            ForEach(part.members) { row in
                HairlineRule()
                let position = row.position
                AfterVotePositionRow(
                    name: row.member.displayName,
                    affiliation: row.affiliation,
                    choice: position.choice,
                    word: position.word,
                    accessibilityLabel: row.accessibilityLabel
                )
            }
            if part.asksForAddress {
                note(AfterVoteCopy.addAddress)
                    .padding(.top, BillboardStyle.Space.s)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .textRole(.body)
            .foregroundStyle(BillboardColors.secondaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row of Your representatives: a name, with a member's docket affiliation under it ("D · SENATE · VA", the party
/// as a letter), and the position at the trailing edge: "✓ Yea" or "✕ Nay" in the vote colour, the Abstain mark and
/// word, "Present" and "Not voting" as plain words in ink 2. At the accessibility sizes the position takes a line of
/// its own. One VoiceOver element.
private struct AfterVotePositionRow: View {
    let name: String
    let affiliation: String?
    let choice: VoteChoice?
    let word: String
    let accessibilityLabel: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                    identity
                    position
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                    identity
                    Spacer(minLength: BillboardStyle.Space.s)
                    position
                        .fixedSize()
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let affiliation {
                Text(CongressMemberLabel.docketText(affiliation))
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var position: some View {
        HStack(spacing: 3) {
            if let choice {
                Image(systemName: choice.symbolName)
                    .accessibilityHidden(true)
            }
            Text(word)
        }
        .textRole(.subheadline)
        .foregroundStyle(choice?.color ?? BillboardColors.secondaryText)
    }
}
