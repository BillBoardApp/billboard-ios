import SwiftUI

// MARK: - How Congress voted (spec 4.45)
//
// The bill page's official roll calls: each chamber's tally, then how its members voted, with the user's own
// members tagged (UX-39a). Official Congress data, not other users' votes, so INT-11 does not seal them.
// `CongressSplitBar`, which Compare with Congress draws too, is in `BillDetailStatsSections.swift`.

/// How Congress voted (spec 4.45): each chamber's roll call as a tally in the TallySheet style, then how
/// its members voted, the user's representatives first, tagged "Your senator" or "Your representative"
/// (UX-39a), each only in their own chamber's roll call (`YourMembersOnRollCalls`). A member in the members
/// manifest opens their page; one who has left Congress stays a plain row. Official Congress data, so never
/// sealed (INT-11 gates only other Billboard users' votes).
struct BillOfficialVotesSection: View {
    let bill: Bill
    let userStateCode: String
    let userDistrictValue: String
    var showsRule = true
    /// When the page is drawn, which says whether the bill's Congress has ended; nil is now. Tests pin it.
    var now: Date?

    static let title = "How Congress voted"

    @EnvironmentObject private var congressManifestStore: CongressMembersManifestStore
    @State private var showAllHouseVotes = false
    @State private var showAllSenateVotes = false

    /// Whether the bill has any roll call to show.
    static func isShown(for bill: Bill) -> Bool {
        !CongressChamberTally.tallies(for: bill).isEmpty
    }

    /// The user's senators and House member on this bill's roll calls.
    private var yourMembers: YourMembersOnRollCalls {
        YourMembersOnRollCalls(
            state: userStateCode,
            district: userDistrictValue,
            manifest: congressManifestStore.items,
            billCongress: Self.congress(of: bill),
            now: now ?? Date()
        )
    }

    /// The bill's Congress, from its `congress` field, else its guid ("BILLS-119hr1234" is the 119th).
    static func congress(of bill: Bill) -> Int? {
        if let congress = bill.congress?.trimmedNonEmpty.flatMap({ Int($0) }) { return congress }
        return bill.guid.flatMap { BillsService.deriveLocator(from: $0) }.flatMap { Int($0.congress) }
    }

    /// The members manifest by upper-cased bioguide ID: who has a member page to open.
    private var manifestByID: [String: CongressMemberManifestItem] {
        Dictionary(congressManifestStore.items.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
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

    private func prioritizedMembers(for chamberVote: Bill.OfficialChamberVote?, roles: [String: YourMemberRole]) -> [Bill.OfficialVoteMember] {
        let members = chamberVote?.members ?? []
        return members.sorted { lhs, rhs in
            let lhsMine = roles[lhs.bioguideId.uppercased()] != nil
            let rhsMine = roles[rhs.bioguideId.uppercased()] != nil
            if lhsMine != rhsMine { return lhsMine && !rhsMine }

            let lhsPosition = votePositionSortOrder(lhs.votePosition)
            let rhsPosition = votePositionSortOrder(rhs.votePosition)
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func defaultVisibleMemberCount(for members: [Bill.OfficialVoteMember], roles: [String: YourMemberRole]) -> Int {
        let repCount = members.filter { roles[$0.bioguideId.uppercased()] != nil }.count
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
            let yours = yourMembers
            let pages = manifestByID
            RecordSection(Self.title, showsRule: showsRule) {
                VStack(alignment: .leading, spacing: BillboardStyle.Space.xxl) {
                    ForEach(tallies, id: \.chamber) { tally in
                        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
                            CongressChamberTallyView(tally: tally)
                            memberVotes(for: tally.chamber, yours: yours, pages: pages)
                        }
                    }
                }
            }
        }
    }

    /// How each member of the chamber voted, the user's representatives first, then Yea, Nay, Present
    /// and Not voting; eight (or all the representatives) until "Show all House votes (435)".
    @ViewBuilder
    private func memberVotes(
        for chamber: CongressChamber,
        yours: YourMembersOnRollCalls,
        pages: [String: CongressMemberManifestItem]
    ) -> some View {
        // The tags on this chamber's rows only: a senator is never tagged on the House roll call.
        let roles = yours.roles(of: chamberVote(chamber)?.members ?? [], in: chamber)
        let members = prioritizedMembers(for: chamberVote(chamber), roles: roles)
        if !members.isEmpty {
            let showAll = showAll(for: chamber)
            let defaultCount = defaultVisibleMemberCount(for: members, roles: roles)
            let visible = showAll.wrappedValue ? members : Array(members.prefix(defaultCount))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        HairlineRule()
                    }
                    memberRow(member, chamber: chamber, role: roles[member.bioguideId.uppercased()], page: pages[member.bioguideId.uppercased()])
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

    /// A member's row, which opens their page when the members manifest has them.
    @ViewBuilder
    private func memberRow(
        _ member: Bill.OfficialVoteMember,
        chamber: CongressChamber,
        role: YourMemberRole?,
        page: CongressMemberManifestItem?
    ) -> some View {
        if let page {
            let row = CongressMemberVoteRow(member: member, chamber: chamber, yourRole: role, opensPage: true)
            NavigationLink {
                CongressMemberProfileLoaderView(manifest: page)
            } label: {
                row
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel(row.accessibilityLabel)
        } else {
            CongressMemberVoteRow(member: member, chamber: chamber, yourRole: role)
                .padding(.vertical, 10)
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
/// voting as plain words. The user's own members carry an ink tag under the name, "Your senator" or "Your
/// representative" (UX-39a), and a row that opens the member's page ends in the chevron. At accessibility sizes
/// each part takes its own line. One VoiceOver element: "Senator Tim Kaine, Democrat, Virginia, your senator, Yea".
struct CongressMemberVoteRow: View {
    let member: Bill.OfficialVoteMember
    let chamber: CongressChamber
    /// The user's senator or House member, tagged as such.
    var yourRole: YourMemberRole?
    /// The row is a link to the member's page.
    var opensPage = false

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
        let parts = [who, yourRole?.spoken, Self.position(member.votePosition).word]
        return parts.compactMap { $0.trimmedNonEmpty }.joined(separator: ", ")
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
                    roleTag
                    // The chevron ends the last line, so the name keeps the line's width.
                    HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
                        positionLabel
                        if opensPage {
                            Spacer(minLength: BillboardStyle.Space.s)
                            RowChevron()
                        }
                    }
                }
            } else {
                HStack(alignment: .center, spacing: BillboardStyle.Space.s) {
                    disc
                    VStack(alignment: .leading, spacing: BillboardStyle.Space.xs) {
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
                        roleTag
                    }
                    Spacer(minLength: BillboardStyle.Space.s)
                    positionLabel
                        .fixedSize()
                    if opensPage {
                        RowChevron()
                    }
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

    /// "YOUR SENATOR" with the `person` glyph, in ink: no hue, as every index tag.
    @ViewBuilder
    private var roleTag: some View {
        if let yourRole {
            IndexTag(title: yourRole.tagTitle, systemImage: "person")
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
