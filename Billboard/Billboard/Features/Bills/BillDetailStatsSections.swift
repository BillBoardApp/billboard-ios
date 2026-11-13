import SwiftUI

// MARK: - Vote results sections of `BillDetail`
//
// Results (everyone beside verified voters, the user's state and district, the map) is
// `BillResultsSection` in `BillResultsComparison.swift`; Why people voted, the sealed tally sheet and the
// Results area that chooses between them are here. How Congress voted and Compare with Congress show
// the official roll calls, which are not other users' votes, so INT-11 does not seal them.

/// How Congress voted (spec 4.45): each chamber's roll call as a tally in the TallySheet style, then how
/// its members voted, the user's representatives first. Official Congress data, so never sealed (INT-11
/// gates only other Billboard users' votes).
struct BillOfficialVotesSection: View {
    let bill: Bill
    let userStateCode: String
    let userDistrictValue: String
    var showsRule = true

    static let title = "How Congress voted"

    @EnvironmentObject private var congressManifestStore: CongressMembersManifestStore
    @State private var showAllHouseVotes = false
    @State private var showAllSenateVotes = false

    /// Whether the bill has any roll call to show.
    static func isShown(for bill: Bill) -> Bool {
        !CongressChamberTally.tallies(for: bill).isEmpty
    }

    private var userRepresentativeBioguideIDs: Set<String> {
        let state = userStateCode
        guard !state.isEmpty else { return [] }

        let manifest = congressManifestStore.items
        let normalizedDistrict = DistrictNormalization.normalize(userDistrictValue, userState: state)?.uppercased()

        var ids = Set<String>()
        for member in manifest {
            let memberState = (member.state ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard memberState == state else { continue }

            if member.chamberNormalized == "Senate" {
                ids.insert(member.id.uppercased())
                continue
            }

            guard member.chamberNormalized == "House",
                  let normalizedDistrict,
                  let memberDistrict = DistrictNormalization.normalize(member.district ?? "", userState: state)?.uppercased(),
                  memberDistrict == normalizedDistrict else {
                continue
            }
            ids.insert(member.id.uppercased())
        }
        return ids
    }

    private func votePositionSortOrder(_ value: String) -> Int {
        switch CongressMemberVoteRow.position(value).choice {
        case .yea: return 0
        case .nay: return 1
        default: break
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "present" { return 2 }
        if normalized == "not voting" { return 3 }
        return 4
    }

    private func prioritizedMembers(for chamberVote: Bill.OfficialChamberVote?) -> [Bill.OfficialVoteMember] {
        let myIDs = userRepresentativeBioguideIDs
        let members = chamberVote?.members ?? []
        return members.sorted { lhs, rhs in
            let lhsMine = myIDs.contains(lhs.bioguideId.uppercased())
            let rhsMine = myIDs.contains(rhs.bioguideId.uppercased())
            if lhsMine != rhsMine { return lhsMine && !rhsMine }

            let lhsPosition = votePositionSortOrder(lhs.votePosition)
            let rhsPosition = votePositionSortOrder(rhs.votePosition)
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func defaultVisibleMemberCount(for members: [Bill.OfficialVoteMember]) -> Int {
        let myIDs = userRepresentativeBioguideIDs
        let repCount = members.filter { myIDs.contains($0.bioguideId.uppercased()) }.count
        return max(8, repCount)
    }

    private func showAll(for chamber: CongressChamber) -> Binding<Bool> {
        chamber == .house ? $showAllHouseVotes : $showAllSenateVotes
    }

    private func chamberVote(_ chamber: CongressChamber) -> Bill.OfficialChamberVote? {
        chamber == .house ? bill.officialVotes?.house : bill.officialVotes?.senate
    }

    var body: some View {
        let tallies = CongressChamberTally.tallies(for: bill)
        if !tallies.isEmpty {
            RecordSection(Self.title, showsRule: showsRule) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xxl) {
                    ForEach(tallies, id: \.chamber) { tally in
                        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                            CongressChamberTallyView(tally: tally)
                            memberVotes(for: tally.chamber)
                        }
                    }
                }
            }
        }
    }

    /// How each member of the chamber voted, the user's representatives first, then Yea, Nay, Present
    /// and Not voting; eight (or all the representatives) until "Show all House votes (435)".
    @ViewBuilder
    private func memberVotes(for chamber: CongressChamber) -> some View {
        let members = prioritizedMembers(for: chamberVote(chamber))
        if !members.isEmpty {
            let showAll = showAll(for: chamber)
            let defaultCount = defaultVisibleMemberCount(for: members)
            let visible = showAll.wrappedValue ? members : Array(members.prefix(defaultCount))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        HairlineRule()
                    }
                    CongressMemberVoteRow(member: member, chamber: chamber)
                        .padding(.vertical, 10)
                }

                if members.count > visible.count {
                    Button(Self.showAllTitle(for: chamber, count: members.count)) {
                        withAnimation(.easeOut(duration: 0.2)) { showAll.wrappedValue = true }
                    }
                    .buttonStyle(BillboardButtonStyle(kind: .textButton))
                    .padding(.top, BillboardStyle.Space.xs)
                } else if members.count > defaultCount {
                    Button(Self.showFewerTitle) {
                        withAnimation(.easeOut(duration: 0.2)) { showAll.wrappedValue = false }
                    }
                    .buttonStyle(BillboardButtonStyle(kind: .textButton))
                    .padding(.top, BillboardStyle.Space.xs)
                }
            }
        }
    }

    /// "Show all House votes (435)", "Show all Senate votes (100)".
    static func showAllTitle(for chamber: CongressChamber, count: Int) -> String {
        "Show all \(CongressMemberLabel.chamberWord(chamber)) votes (\(count))"
    }

    static let showFewerTitle = "Show fewer"
}

/// One chamber's roll call: the official Yea and Nay totals, and Present and Not voting when the roll call
/// has them (official Congress data, not other users' votes).
struct CongressChamberTally: Equatable {
    let chamber: CongressChamber
    let yea: Int
    let nay: Int
    var present: Int? = nil
    var notVoting: Int? = nil
    /// The roll call's result, as Congress words it ("Passed").
    var result: String? = nil

    /// The House's, then the Senate's: from the roll call when there is one, else from the bill's counts.
    static func tallies(for bill: Bill) -> [CongressChamberTally] {
        let chambers: [(CongressChamber, Bill.OfficialChamberVote?, Int?, Int?)] = [
            (.house, bill.officialVotes?.house, bill.congressHouseYeaCount, bill.congressHouseNayCount),
            (.senate, bill.officialVotes?.senate, bill.congressSenateYeaCount, bill.congressSenateNayCount)
        ]
        return chambers.compactMap { chamber, vote, fallbackYea, fallbackNay in
            if let vote {
                return CongressChamberTally(
                    chamber: chamber,
                    yea: vote.yea,
                    nay: vote.nay,
                    present: vote.present,
                    notVoting: vote.notVoting,
                    result: vote.resultText?.trimmedNonEmpty
                )
            }
            guard let fallbackYea, let fallbackNay else { return nil }
            return CongressChamberTally(chamber: chamber, yea: fallbackYea, nay: fallbackNay)
        }
    }

    var chamberWord: String {
        CongressMemberLabel.chamberWord(chamber)
    }

    /// Present and Not voting are known.
    var hasOtherColumns: Bool {
        present != nil && notVoting != nil
    }

    /// "2 present · 6 not voting" under the bar (the docket face sets it in capitals); nil without them.
    var otherCaption: String? {
        guard let present, let notVoting else { return nil }
        return "\(present) present · \(notVoting) not voting"
    }

    /// "Yea 231", "Nay 196", "Present 2", "Not voting 6": the stacked form's figures (after the vote
    /// symbols), each kept on one line with no-break spaces.
    var stackedFigures: [String] {
        var parts = ["Yea \(yea)", "Nay \(nay)"]
        if let present { parts.append("Present \(present)") }
        if let notVoting { parts.append("Not voting \(notVoting)") }
        return parts.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
    }

    /// "House: 231 Yea, 196 Nay, 2 present, 6 not voting." with the result after it.
    var accessibilityLabel: String {
        var parts = ["\(yea) Yea", "\(nay) Nay"]
        if let present { parts.append("\(present) present") }
        if let notVoting { parts.append("\(notVoting) not voting") }
        var label = "\(chamberWord): \(parts.joined(separator: ", "))."
        if let result {
            label += " \(SpokenSentences.sentence(result))"
        }
        return label
    }
}

/// A chamber's roll call set like a tally sheet (spec 4.45), in the first of three forms that fits:
///
/// 1. Four figure columns, YEA, NAY, PRESENT and NOT VOTING, only where they fit (a wide screen; never a
///    phone at the default text size).
/// 2. The phone form: two columns, "✓ YEA" and "✕ NAY" in the vote colours, a heavy header rule, the
///    chamber row with its figures, the split bar with its 50% tick, and "2 PRESENT · 6 NOT VOTING" under it.
/// 3. Stacked, at accessibility sizes and wherever two columns do not fit: the chamber, then "✓ Yea 231 ·
///    ✕ Nay 196 · Present 2 · Not voting 6" on its own line, then the bar.
///
/// One VoiceOver element: "House: 231 Yea, 196 Nay, 2 present, 6 not voting."
struct CongressChamberTallyView: View {
    enum Form: CaseIterable {
        case automatic
        case columns
        case split
        case stacked
    }

    let tally: CongressChamberTally
    var form: Form = .automatic

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The chamber column's least width, and each figure column's (scaled with the figures).
    @ScaledMetric(relativeTo: .callout) private var chamberColumn: CGFloat = 88
    @ScaledMetric(relativeTo: .callout) private var wideFigureColumn: CGFloat = 84
    @ScaledMetric(relativeTo: .callout) private var figureColumn: CGFloat = 64

    static func identifier(for chamber: CongressChamber) -> String {
        "bill.congress.\(chamber.rawValue.lowercased())"
    }

    var body: some View {
        Group {
            switch form {
            case .columns: columns
            case .split: split
            case .stacked: stacked
            case .automatic:
                if dynamicTypeSize.isAccessibilitySize {
                    stacked
                } else if tally.hasOtherColumns {
                    ViewThatFits(in: .horizontal) {
                        columns
                        split
                        stacked
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        split
                        stacked
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tally.accessibilityLabel)
        .accessibilityIdentifier(Self.identifier(for: tally.chamber))
    }

    // MARK: Forms

    private var columns: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                Color.clear
                    .frame(minWidth: chamberColumn, maxWidth: .infinity, maxHeight: 0)
                voteHead(.yea).frame(width: wideFigureColumn, alignment: .trailing)
                voteHead(.nay).frame(width: wideFigureColumn, alignment: .trailing)
                plainHead("Present").frame(width: wideFigureColumn, alignment: .trailing)
                plainHead("Not voting").frame(width: wideFigureColumn, alignment: .trailing)
            }
            HeavyRule(width: 1.5)
                .padding(.top, 6)
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                chamberName
                    .frame(minWidth: chamberColumn, maxWidth: .infinity, alignment: .leading)
                figure(tally.yea).frame(width: wideFigureColumn, alignment: .trailing)
                figure(tally.nay).frame(width: wideFigureColumn, alignment: .trailing)
                figure(tally.present ?? 0).frame(width: wideFigureColumn, alignment: .trailing)
                figure(tally.notVoting ?? 0).frame(width: wideFigureColumn, alignment: .trailing)
            }
            .padding(.top, BillboardStyle.Space.s)
            CongressSplitBar(yea: tally.yea, nay: tally.nay)
                .padding(.top, BillboardStyle.Space.xs)
            resultLine
        }
    }

    private var split: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                Color.clear
                    .frame(minWidth: chamberColumn, maxWidth: .infinity, maxHeight: 0)
                voteHead(.yea).frame(width: figureColumn, alignment: .trailing)
                voteHead(.nay).frame(width: figureColumn, alignment: .trailing)
            }
            HeavyRule(width: 1.5)
                .padding(.top, 6)
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                chamberName
                    .frame(minWidth: chamberColumn, maxWidth: .infinity, alignment: .leading)
                figure(tally.yea).frame(width: figureColumn, alignment: .trailing)
                figure(tally.nay).frame(width: figureColumn, alignment: .trailing)
            }
            .padding(.top, BillboardStyle.Space.s)
            CongressSplitBar(yea: tally.yea, nay: tally.nay)
                .padding(.top, BillboardStyle.Space.xs)
            if let caption = tally.otherCaption {
                Text(caption)
                    .textRole(.docket)
                    .foregroundStyle(BillboardColors.dimText)
                    .fixedSize()
                    .padding(.top, 2)
            }
            resultLine
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 6) {
            chamberName
            stackedFigures
            CongressSplitBar(yea: tally.yea, nay: tally.nay)
            resultLine
        }
    }

    // MARK: Parts

    private var chamberName: some View {
        Text(tally.chamberWord)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "✓ YEA" or "✕ NAY" in the vote colour: a column head is a symbol and a word.
    private func voteHead(_ choice: VoteChoice) -> some View {
        HStack(spacing: 3) {
            Image(systemName: choice.symbolName)
            Text(choice.title)
        }
        .textRole(.label)
        .foregroundStyle(choice.color)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func plainHead(_ title: String) -> some View {
        Text(title)
            .textRole(.label)
            .foregroundStyle(BillboardColors.secondaryText)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func figure(_ value: Int) -> some View {
        Text(value.formatted())
            .textRole(.figure)
            .foregroundStyle(BillboardColors.primaryText)
            .monospacedDigit()
            .fixedSize()
    }

    /// "✓ Yea 231 · ✕ Nay 196 · Present 2 · Not voting 6", wrapping as one line of figures.
    private var stackedFigures: some View {
        let figures = tally.stackedFigures
        // No-break spaces keep each symbol with its word and each "·" at the end of a line.
        let yea = Text("\(Image(systemName: VoteChoice.yea.symbolName))\u{00A0}\(figures[0])")
        let nay = Text("\(Image(systemName: VoteChoice.nay.symbolName))\u{00A0}\(figures[1])")
        let rest = figures.dropFirst(2).map { "\u{00A0}· \($0)" }.joined()
        return Text("\(yea)\u{00A0}· \(nay)\(rest)")
            .textRole(.figure)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var resultLine: some View {
        if let result = tally.result {
            Text(result)
                .textRole(.caption)
                .foregroundStyle(BillboardColors.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, BillboardStyle.Space.xs)
        }
    }
}

/// How one member voted (spec 4.45): the party disc, the name, the docket affiliation led by the party
/// letter ("D · SENATE · VA"), and the position: "✓ Yea" or "✕ Nay" in the vote colour, Present and Not
/// voting as plain words. At accessibility sizes each part takes its own line. One VoiceOver element:
/// "Tim Kaine, Democrat, Virginia, Yea".
struct CongressMemberVoteRow: View {
    let member: Bill.OfficialVoteMember
    let chamber: CongressChamber

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The party disc stands beside the name with its letter in the affiliation, at 19 pt (spec 3.14).
    @ScaledMetric(relativeTo: .callout) private var discSize: CGFloat = 19

    /// A roll-call position as the page words it: Yea for "Yea", "Yes" and "Aye", Nay for "Nay" and "No"
    /// (one word per concept), "Not voting" in sentence case, anything else as Congress gave it.
    static func position(_ raw: String) -> (choice: VoteChoice?, word: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "yea", "yes", "aye": return (.yea, VoteChoice.yea.title)
        case "nay", "no": return (.nay, VoteChoice.nay.title)
        case "not voting": return (nil, "Not voting")
        case "present": return (nil, "Present")
        default: return (nil, trimmed)
        }
    }

    private var party: PoliticalParty? {
        PoliticalParty.from(raw: member.party)
    }

    var affiliation: String? {
        CongressMemberLabel.affiliation(party: party, state: member.state, district: member.district, chamber: chamber)
    }

    /// "Representative Jordan Ellis, Republican, Texas's 7th district, Yea", in the one spoken form
    /// (`CongressMemberLabel.spokenDescription`).
    var accessibilityLabel: String {
        let who = CongressMemberLabel.spokenDescription(
            name: member.displayName,
            party: party,
            state: member.state,
            district: member.district,
            chamber: chamber
        )
        let word = Self.position(member.votePosition).word
        return word.isEmpty ? who : "\(who), \(word)"
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
                    HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
                        disc
                        nameText
                    }
                    affiliationText
                    positionLabel
                }
            } else {
                HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
                    disc
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                            nameText.fixedSize()
                            affiliationText.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            nameText
                            affiliationText
                        }
                    }
                    Spacer(minLength: BillboardStyle.Space.s)
                    positionLabel
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var disc: some View {
        if let party {
            PartyDisc(party: party, diameter: discSize, ringColor: nil)
                .accessibilityHidden(true)
        }
    }

    private var nameText: some View {
        Text(member.displayName)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var affiliationText: some View {
        if let affiliation {
            Text(CongressMemberLabel.docketText(affiliation))
                .textRole(.docket)
                .foregroundStyle(BillboardColors.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "✓ Yea", "✕ Nay" in the vote colour; "Present", "Not voting" in ink 2.
    private var positionLabel: some View {
        let position = Self.position(member.votePosition)
        let choice = position.choice
        return HStack(spacing: 3) {
            if let choice {
                Image(systemName: choice.symbolName)
                    .accessibilityHidden(true)
            }
            Text(position.word)
        }
        .textRole(.subheadline)
        .foregroundStyle(choice?.color ?? BillboardColors.secondaryText)
    }
}

/// The Yea / Nay split of an official roll call (How Congress voted, Compare with Congress): the shared split
/// (`TallySplitBar`) under the 2 pt 50% tick, a `well` fill when the roll call has no Yea or Nay. A part:
/// the rows that draw it show the vote symbols and words. Hidden from VoiceOver.
struct CongressSplitBar: View {
    let yea: Int
    let nay: Int

    static let height = TallySplitBar.height
    static let gap = TallySplitBar.gap

    var body: some View {
        TallySplitBar(yea: Double(yea), nay: Double(nay), tick: .always, empty: .well)
    }
}

/// Why people voted, open (spec 4.46): anonymized reason counts for each side, never names. Two blocks
/// headed "✓ YEA (23)" and "✕ NAY (17)" in the vote colours over a heavy rule, each reason a ledger row
/// with "12 · 52%" in the figures face and a dotted rule under it, then the companion caption. Each reason
/// is one VoiceOver element: "Saves money: 12 people, 52 percent of Yea voters." Under the Results floor
/// (UX-34) it says "Not enough reasons shared yet." whatever the stats hold: the two heads would give the split.
struct BillVoteReasonsSection: View {
    let billStats: BillStatsService.BillStats?
    let isLoadingBillStats: Bool
    var showsRule = true

    static let title = "Why people voted"
    static let notEnoughText = "Not enough reasons shared yet."
    static let loadingText = "Updating reasons…"
    static let emptyText = "Reasons appear once enough people share why they voted. Names are never shown."

    var body: some View {
        RecordSection(Self.title, showsRule: showsRule) {
            VStack(alignment: .leading, spacing: 0) {
                if let billStats, VoteResultsFormatting.isBelowFloor(billStats) {
                    note(Self.notEnoughText)
                } else if let reasonBreakdown = billStats?.reasonBreakdown {
                    if reasonBreakdown.yea.reasons.isEmpty && reasonBreakdown.nay.reasons.isEmpty {
                        note(Self.notEnoughText)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            reasonBlock(choice: .yea, side: reasonBreakdown.yea)
                            reasonBlock(choice: .nay, side: reasonBreakdown.nay)
                        }
                    }
                } else if isLoadingBillStats {
                    note(Self.loadingText)
                } else {
                    note(Self.emptyText)
                }

                if let combinedVotesCaption = BillDisplayFormatting.combinedVotesCaption(
                    companionBillIds: billStats?.companionBillIds
                ) {
                    BillCombinedVotesCaption(text: combinedVotesCaption)
                        .padding(.top, BillboardStyle.Space.m)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .textRole(.body)
            .foregroundStyle(BillboardColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reasonBlock(
        choice: VoteChoice,
        side: BillStatsService.ReasonSide
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VoteCountHead(choice: choice, count: side.voteCount)
                .padding(.bottom, 6)
            HeavyRule(width: 1.5)

            if side.reasons.isEmpty {
                note(Self.notEnoughText)
                    .padding(.vertical, 9)
            } else {
                ForEach(side.reasons, id: \.reasonKey) { reason in
                    reasonRow(reason, choice: choice)
                    DottedRule()
                }
            }
        }
    }

    private func reasonRow(_ reason: BillStatsService.ReasonBucket, choice: VoteChoice) -> some View {
        let name = reasonDisplayName(reason.reasonKey)
        let figures = "\(reason.count) · \(formattedPercent(reason.pct))"
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                Text(name)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize()
                Spacer(minLength: BillboardStyle.Space.s)
                Text(figures)
                    .textRole(.figure)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(figures)
                    .textRole(.figure)
                    .foregroundStyle(BillboardColors.primaryText)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            VoteResultsFormatting.reasonAccessibilityLabel(reason: name, count: reason.count, pct: reason.pct, choice: choice)
        )
    }

    private func reasonDisplayName(_ key: String) -> String {
        if let voteReason = VoteReason(rawValue: key) {
            return voteReason.title
        }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Compare with Congress (spec 4.47): shown only right after a vote made on the page, and only when Congress
/// has voted. Per chamber, "HOUSE" and "220–210" in the figures face, the split bar with its 50% tick, and
/// "✓ Yea 220" and "✕ Nay 210" in the vote colours. It fades in (nothing moves); with Reduce Motion it
/// appears at once.
struct BillCongressVotedSection: View {
    let bill: Bill
    var showsRule = true

    static let title = "Compare with Congress"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The chambers that voted, House first.
    static func tallies(for bill: Bill) -> [CongressChamberTally] {
        let chambers: [(CongressChamber, Int?, Int?)] = [
            (.house, bill.congressHouseYeaCount, bill.congressHouseNayCount),
            (.senate, bill.congressSenateYeaCount, bill.congressSenateNayCount)
        ]
        return chambers.compactMap { chamber, yea, nay in
            guard let yea, let nay, yea + nay > 0 else { return nil }
            return CongressChamberTally(chamber: chamber, yea: yea, nay: nay)
        }
    }

    var body: some View {
        let tallies = Self.tallies(for: bill)
        if !tallies.isEmpty {
            RecordSection(Self.title, showsRule: showsRule) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                    ForEach(tallies, id: \.chamber) { tally in
                        chamberRow(tally)
                    }
                }
            }
            .transition(reduceMotion ? .identity : .opacity)
        }
    }

    private func chamberRow(_ tally: CongressChamberTally) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                Text(tally.chamberWord)
                    .textRole(.label)
                    .foregroundStyle(BillboardColors.secondaryText)
                Spacer(minLength: BillboardStyle.Space.s)
                Text("\(tally.yea)–\(tally.nay)")
                    .textRole(.figure)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize()
            }
            CongressSplitBar(yea: tally.yea, nay: tally.nay)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                    side(.yea, tally.yea).fixedSize()
                    Spacer(minLength: BillboardStyle.Space.s)
                    side(.nay, tally.nay).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    side(.yea, tally.yea)
                    side(.nay, tally.nay)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tally.chamberWord): \(tally.yea) Yea, \(tally.nay) Nay")
    }

    /// "✓ Yea 220" in the vote colour.
    private func side(_ choice: VoteChoice, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: choice.symbolName)
            Text("\(choice.title) \(count)")
        }
        .textRole(.subheadline)
        .foregroundStyle(choice.color)
    }
}

/// The caption under stats that combine a companion group's votes (APPF-23): `caption`, ink 3, no glyph
/// (spec 3.7).
struct BillCombinedVotesCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.dimText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("bill.stats.combinedCaption")
    }
}

// MARK: - Results gate (INT-11)

/// Results and Why people voted as the bill page stacks them (spec 4.28): open, the tally sheet and the
/// reasons; otherwise both drawn sealed (`SealedTally`), which take no stats. Nothing built from other
/// users' votes is created while sealed: no blur, no placeholder figures, no map. After a vote on the page
/// Results are open but the stats for it have not arrived, so the sheet shows Opening (the seal lifted, a
/// spinner) and cross-fades to the tally sheet when they do. How Congress voted (the official roll calls)
/// is not gated: the page shows it further down either way.
struct BillResultsArea: View {
    let access: BillResultsAccess
    let billStats: BillStatsService.BillStats?
    let isLoadingBillStats: Bool
    let billStatsError: String?
    let userStateCode: String
    let userDistrictValue: String
    /// A vote was made on this screen: Results show Opening until its stats arrive, and the bars grow once.
    var didVoteHere = false
    /// The user's vote, for the "You" marker and "You abstained." on the open sheet.
    var yourVote: VoteChoice? = nil
    /// Try again on the sealed sheet: reads the vote again, or sends the unsaved vote again.
    var onTryAgain: () -> Void = {}
    /// Try again when the open sheet's stats failed to load.
    var onRetryStats: (() -> Void)? = nil
    /// The sealed sheet's VoiceOver action "Go to vote buttons".
    var onGoToVoteButtons: (() -> Void)? = nil
    /// The bill page's VoiceOver focus: the Results title is `.resultsHeader`, where the ballot stamp's
    /// "Go to Results" moves it (spec 3.10.3). Nil attaches none (render tests).
    var titleFocus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil

    /// The sealed sheet's state, or nil for the open sheet.
    var sealedState: SealedTallyState? {
        SealedTallyState(access: access, opening: didVoteHere && billStats == nil && billStatsError == nil)
    }

    var body: some View {
        let sealed = sealedState
        VStack(alignment: .leading, spacing: 0) {
            if let sealed {
                SealedTally(kind: .results, state: sealed, onTryAgain: onTryAgain, onGoToVoteButtons: onGoToVoteButtons, titleFocus: titleFocus)
                    .transition(.opacity)
                SealedTally(kind: .reasons, state: sealed, onGoToVoteButtons: onGoToVoteButtons)
                    .transition(.opacity)
            } else {
                BillResultsSection(
                    billStats: billStats,
                    isLoadingBillStats: isLoadingBillStats,
                    billStatsError: billStatsError,
                    userStateCode: userStateCode,
                    userDistrictValue: userDistrictValue,
                    yourVote: yourVote,
                    growsOnFirstStats: didVoteHere,
                    onRetry: onRetryStats,
                    titleFocus: titleFocus
                )
                .transition(.opacity)
                BillVoteReasonsSection(
                    billStats: billStats,
                    isLoadingBillStats: isLoadingBillStats
                )
                .transition(.opacity)
            }
        }
        // Opening cross-fades to the tally sheet when the stats arrive (spec 5.1), with Reduce Motion too.
        .animation(.easeInOut(duration: 0.2), value: sealed == nil)
    }
}

/// The sealed tally sheet (spec 3.8, as the project changed it): Results, or Why people voted, before the
/// user votes or abstains, drawn as the ruled sheet with blank cells under a SEALED stamp, so the page
/// shows what is inside without showing any of it. It takes no stats. Under the sheet: the line and the
/// plain reason, and Try again where there is something to try again.
///
/// - Results: the column heads and their heavy rule; "Everyone" and "Verified voters" with a 30 pt dotted
///   blank in each figure cell and an empty 8 pt bar; the stamp centred over the rows on the document's
///   colour. Where the columns do not fit, or the centred stamp would cover a row's name (the accessibility
///   sizes; from xLarge on a 375 pt phone), the rows stack, each blank becomes one 80 pt dotted line under the
///   name, and the stamp moves above the rows, on the leading gutter (frame 26).
/// - Why people voted: "✓ YEA" and "✕ NAY" over heavy rules, two dotted blank lines each, the stamp, and
///   "Reasons open after you vote." (nothing beside the spinner).
///
/// While the vote is checked, and in Opening, a spinner takes the stamp's place. The title is its own
/// header element; the sheet and its words are one element labelled "Sealed" (or the spinner's words)
/// with the line and the text as its value. Before a vote it has the action "Go to vote buttons".
struct SealedTally: View {
    enum Kind {
        case results
        case reasons
    }

    let kind: Kind
    let state: SealedTallyState
    var showsRule = true
    var onTryAgain: () -> Void = {}
    var onGoToVoteButtons: (() -> Void)? = nil
    /// Focus for the title (`.resultsHeader`, Results only); nil attaches none.
    var titleFocus: AccessibilityFocusState<VoteFocusTarget?>.Binding? = nil

    /// INT-11's id for the sealed Results element (kept for the smoke UI tests).
    static let resultsIdentifier = "bill.results.locked"
    /// Opening is open Results waiting for their stats, not locked ones.
    static let openingIdentifier = "bill.results.opening"
    static let reasonsIdentifier = "bill.reasons.locked"
    static let tryAgainIdentifier = "bill.results.tryAgain"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var yeaColumn = TallySheetMetrics.yeaColumn
    @ScaledMetric(relativeTo: .callout) private var nayColumn = TallySheetMetrics.nayColumn
    @ScaledMetric(relativeTo: .callout) private var votesColumn = TallySheetMetrics.votesColumn
    @ScaledMetric(relativeTo: .callout) private var stackedBlank = TallySheetMetrics.stackedBlank

    private var title: String {
        kind == .results ? VoteResultsFormatting.sectionTitle : BillVoteReasonsSection.title
    }

    private var identifier: String {
        switch kind {
        case .results: return state == .opening ? Self.openingIdentifier : Self.resultsIdentifier
        case .reasons: return Self.reasonsIdentifier
        }
    }

    private var line: String? {
        kind == .results ? state.line : nil
    }

    private var text: String? {
        kind == .results ? state.text : state.reasonsText
    }

    var body: some View {
        // The title is drawn here rather than by `RecordSection`, at the same place, so it can take focus.
        RecordSection(nil, showsRule: showsRule) {
            Text(title)
                .textRole(.heading)
                .foregroundStyle(BillboardColors.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocusTarget(kind == .results ? titleFocus : nil, equals: .resultsHeader)
            VStack(alignment: .leading, spacing: 0) {
                sheetElement
                if kind == .results, state.offersTryAgain {
                    Button(VoteResultsFormatting.tryAgainTitle, action: onTryAgain)
                        .buttonStyle(BillboardButtonStyle(kind: .secondary, fullWidth: false))
                        .accessibilityIdentifier(Self.tryAgainIdentifier)
                        .padding(.top, BillboardStyle.Space.m)
                        .transition(.opacity)
                }
            }
            // The stamp and the spinner swap with a 0.2 s fade (spec 3.8.4); with Reduce Motion at once.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
        }
    }

    /// The sheet and the words under it: one VoiceOver element.
    private var sheetElement: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .results:
                // At the accessibility sizes the rows stack and the stamp moves above them (spec 3.8.2).
                if dynamicTypeSize.isAccessibilitySize {
                    resultsStacked
                } else {
                    ViewThatFits(in: .horizontal) {
                        resultsTable
                        resultsStacked
                    }
                }
            case .reasons:
                reasonsSheet
            }
            words
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VoteResultsFormatting.sealedAccessibilityLabel(state))
        .accessibilityValue(VoteResultsFormatting.sealedAccessibilityValue(state, reasons: kind == .reasons) ?? "")
        .accessibilityActions {
            if state.offersGoToVoteButtons, let onGoToVoteButtons {
                Button(VoteResultsFormatting.goToVoteButtonsAction, action: onGoToVoteButtons)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    /// The line ("Vote to see results", `name`) and the text (`body`, ink 2), 16 pt under the sheet.
    @ViewBuilder
    private var words: some View {
        if line != nil || text != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let line {
                    Text(line)
                        .textRole(.name)
                        .foregroundStyle(BillboardColors.primaryText)
                }
                if let text {
                    Text(text)
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, BillboardStyle.Space.l)
            .transition(.opacity)
        }
    }

    // MARK: Results

    private static let rowNames = [VoteResultsFormatting.everyoneTitle, VoteResultsFormatting.verifiedTitle]

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            TallyColumnHeads()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.rowNames, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            rowName(name)
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            blank.frame(width: yeaColumn, alignment: .trailing)
                            blank.frame(width: nayColumn, alignment: .trailing)
                            blank.frame(width: votesColumn, alignment: .trailing)
                        }
                        .padding(.top, TallySheetMetrics.rowTop)
                        TallyBlankBar()
                            .padding(.top, TallySheetMetrics.barTop)
                    }
                }
            }
            .overlay { overlaidMark }
            stampClearance
        }
    }

    /// Not drawn, no height: the widest row name on each side of the SEALED stamp and its backing. It makes the
    /// table's ideal width what the centred stamp needs to clear the names, so `ViewThatFits` takes the stacked
    /// form as soon as the stamp would cover one ("Verified voters" at xLarge on a 375 pt phone, xxLarge on
    /// 402 pt). Always the stamp, never the spinner: it sits between the rows, and the sheet keeps one form
    /// from checking to sealed.
    private var stampClearance: some View {
        HStack(spacing: 0) {
            widestRowName
            StatusStamp(.sealed, size: .seal)
                .padding(.horizontal, Self.markBackingPadding)
            widestRowName
        }
        .fixedSize()
        .frame(height: 0)
        .hidden()
        .accessibilityHidden(true)
    }

    private var widestRowName: some View {
        ZStack {
            ForEach(Self.rowNames, id: \.self) { rowName($0) }
        }
    }

    private var resultsStacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            stackedMark
            HeavyRule(width: 1.5)
            ForEach(Self.rowNames, id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    rowName(name)
                        .fixedSize(horizontal: false, vertical: true)
                    DottedRule()
                        .frame(width: stackedBlank)
                        .padding(.vertical, 8)
                    TallyBlankBar()
                }
                .padding(.top, TallySheetMetrics.rowTop)
            }
        }
    }

    private func rowName(_ name: String) -> some View {
        Text(name)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
    }

    /// A figure cell left blank: 30 pt of dotted rule, 3 pt above the row's baseline.
    private var blank: some View {
        DottedRule()
            .frame(width: 30)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
    }

    // MARK: Why people voted

    private var reasonsSheet: some View {
        let stampAbove = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 0) {
            if stampAbove {
                stackedMark
            }
            VStack(alignment: .leading, spacing: 14) {
                reasonsBlock(.yea)
                reasonsBlock(.nay)
            }
            .overlay {
                if !stampAbove { overlaidMark }
            }
        }
    }

    /// "✓ YEA" or "✕ NAY" over a heavy rule, then two blank dotted lines.
    private func reasonsBlock(_ choice: VoteChoice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: choice.symbolName)
                Text(choice.title)
            }
            .textRole(.label)
            .foregroundStyle(choice.color)
            .padding(.bottom, 6)
            HeavyRule(width: 1.5)
            blankLine(fraction: 1)
            blankLine(fraction: 0.62)
        }
    }

    private func blankLine(fraction: CGFloat) -> some View {
        GeometryReader { geometry in
            DottedRule()
                .frame(width: geometry.size.width * fraction)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 18)
    }

    // MARK: The mark

    /// The document-coloured backing's reach past the mark's sides.
    private static let markBackingPadding = BillboardStyle.Space.m

    /// Over the rows: the mark centred on the document's colour, so the blanks stop at its edge.
    private var overlaidMark: some View {
        mark
            .padding(.vertical, 6)
            .padding(.horizontal, Self.markBackingPadding)
            .background(BillboardColors.document)
    }

    /// Above the stacked rows (the accessibility sizes, frame 26): the mark on the leading gutter, under the
    /// title like the rows' names, with no backing (nothing runs behind it).
    private var stackedMark: some View {
        mark
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, BillboardStyle.Space.m)
    }

    /// The SEALED stamp, or a spinner where the vote is checked and in Opening.
    private var mark: some View {
        Group {
            if let spinnerText = state.spinnerText {
                HStack(spacing: BillboardStyle.Space.s) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BillboardColors.interactive)
                        .accessibilityHidden(true)
                    // Why people voted shows the spinner alone: Results above say what it waits for.
                    if kind == .results {
                        // Wraps at the largest sizes: one line wider than the column would widen the
                        // whole page past its gutters (spec 7.2).
                        Text(spinnerText)
                            .textRole(.caption)
                            .foregroundStyle(BillboardColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            } else {
                StatusStamp(.sealed, size: .seal)
                    .transition(.opacity)
            }
        }
    }
}

private func formattedPercent(_ value: Double?) -> String {
    guard let value else { return "—" }
    let rounded = round(value * 10) / 10
    if abs(rounded.rounded() - rounded) < 0.05 {
        return "\(Int(rounded.rounded()))%"
    }
    return String(format: "%.1f%%", rounded)
}
