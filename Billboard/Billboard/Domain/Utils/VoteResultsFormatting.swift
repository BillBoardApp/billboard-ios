import Foundation

/// The Results section of bill detail (spec D 2.2): everyone and verified voters side by side,
/// unweighted, then the user's state and district (verified voters only), and the map's selection
/// text. Pure formatting over `BillStatsService.BillStats`; the views only lay it out.
///
/// Percent rule: Yea = round(yeaPct), Nay = 100 - Yea, no decimals, so the two always add up to 100.
/// No Yea or Nay votes gives "No Yea or Nay votes yet". "Votes" counts Yea + Nay; abstentions are
/// reported on their own line.
///
/// The floor (UX-34, pulled into 1.2 on 2026-10-28): below `minDecisionVotes` Yea + Nay votes on the bill (or
/// its companion group) Results show no split, no abstain count and no count of the votes so far, only "Results
/// open at 5 votes" (project decision of 2026-10-29). Above it no two numbers shown may give away a group under the floor: Verified voters are withheld when
/// Everyone minus them leaves 1 to 4 votes, and the state and district results when Everyone minus the states
/// shown does (the server already covers verified minus the states, and a state minus its districts). Regions
/// show no abstain count, which Everyone's abstained line minus theirs would give away.
enum VoteResultsFormatting {
    // MARK: - Percent rule

    struct Percentages: Equatable {
        let yea: Int
        let nay: Int
    }

    /// Whole-number Yea and Nay shares that add up to 100, or nil when there are no Yea or Nay
    /// votes. Uses `yeaPct` (0 to 100) when given, else the counts.
    static func percentages(yeaPct: Double?, yea: Int, nay: Int) -> Percentages? {
        let decisionVotes = max(0, yea) + max(0, nay)
        guard decisionVotes > 0 else { return nil }
        let raw = yeaPct ?? (Double(max(0, yea)) * 100 / Double(decisionVotes))
        guard raw.isFinite else { return nil }
        let yeaShare = Int(min(100, max(0, raw)).rounded())
        return Percentages(yea: yeaShare, nay: 100 - yeaShare)
    }

    static func percentages(_ split: BillStatsService.VoteSplit) -> Percentages? {
        guard split.decisionVotes > 0 else { return nil }
        return percentages(yeaPct: split.yeaPct, yea: split.yea, nay: split.nay)
    }

    static func percentages(_ totals: BillStatsService.VoteTotals) -> Percentages? {
        percentages(BillStatsService.VoteSplit(totals))
    }

    // MARK: - Copy

    static let sectionTitle = "Results"
    static let everyoneTitle = "Everyone"
    static let verifiedTitle = "Verified voters"
    static let noDecisionVotesText = "No Yea or Nay votes yet"
    static let loadingText = "Updating results…"
    static let unavailableText = "Results aren't available right now."

    // Locked Results (INT-11): other users' votes show only after the user votes or abstains on the bill.

    /// No vote held on the bill. Every bill page has the vote bar to vote from, a decided bill's too.
    static let lockText = "Vote to see results"
    /// The vote is shown on this device but the server does not hold it yet (`RESULTS_LOCKED`).
    static let awaitingSaveText = "Results show once your vote is saved."
    /// Reading the user's vote failed, so whether Results open is not known yet (Try again reads it again).
    static let checkFailedText = BillVoteStore.checkVoteFailedMessage
    static let tryAgainTitle = "Try again"

    // The sealed tally sheet (Civic Record spec 3.8): the locked Results drawn as a ruled sheet with blank
    // cells and a SEALED stamp, with the plain reason under it.

    /// The stamp's word, and the sealed sheet's VoiceOver label.
    static let sealedLabel = "Sealed"
    /// Under "Vote to see results": why Results are sealed.
    static let notVotedSealedText = "They open after you vote Yea, Nay or Abstain, so other people's votes don't sway yours."
    /// Beside the spinner between a vote made on the page and the stats for it.
    static let openingText = "Opening results…"
    /// Under the sealed Why people voted, when it is stamped (`SealedTallyState.reasonsText`).
    static let reasonsSealedText = "Reasons open after you vote."
    /// The sealed sheet's VoiceOver action before a vote: focus moves to the vote panel.
    static let goToVoteButtonsAction = "Go to vote buttons"

    /// The sealed sheet's one VoiceOver element's label: "Sealed", or the words beside the spinner that
    /// takes the stamp's place ("Checking your vote…", "Opening results…").
    static func sealedAccessibilityLabel(_ state: SealedTallyState) -> String {
        state.spinnerText ?? sealedLabel
    }

    /// The sealed sheet's VoiceOver value: the line and the text under the sheet, as sentences ("Vote to
    /// see results. They open after you vote Yea, Nay or Abstain, so other people's votes don't sway
    /// yours."); nil when there is none. Why people voted says "Reasons open after you vote." under the
    /// stamp and nothing beside a spinner.
    static func sealedAccessibilityValue(_ state: SealedTallyState, reasons: Bool = false) -> String? {
        let parts = reasons ? [state.reasonsText].compactMap { $0 } : [state.line, state.text].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return SpokenSentences.join(parts)
    }

    // The open tally sheet (Civic Record spec 3.7).

    /// Under the rows: what the tick on each bar is.
    static let majorityCaption = "The line marks 50%."
    /// Under the abstained line, after the user abstained (the first stats may not count it yet, so never
    /// "including you").
    static let youAbstainedText = "You abstained."
    /// The user's state or district line without an address.
    static let seeStateAndDistrictText = "See your state and district"
    static let seeDistrictText = "See your district"
    static let addAddressTitle = "Add your address"

    static let mapTitle = "Map: verified voters"
    static let infoTitle = "About these results"
    // The info sheet's lines (spec D 2.2, 4.44): each row's name is set in bold before its line.
    static let infoEveryoneText = "counts every Billboard user who voted."
    /// Verified voters entered an address that matched a district; nothing confirms it is their home
    /// (feature review N1).
    static let infoVerifiedText = "entered an address that matched a district."
    static let infoOnceText = "Each person's vote counts once."
    static let infoLocalText = "State, district and map results include verified voters only, because only their location is checked."
    /// The floor (UX-34): "Results open at 5 Yea or Nay votes. …". It says only what the floor does: it never
    /// promises that no one can work out a vote, because a floor cannot keep that promise (a unanimous 5 shows how
    /// each of the 5 voted).
    static func infoFloorText(_ floor: Int) -> String {
        let floor = max(1, floor)
        return "Results open at \(floor) Yea or Nay \(floor == 1 ? "vote" : "votes"). Any state, district or group with "
            + "fewer than \(floor) stays hidden, and so does any number that would give one away."
    }
    /// The info sheet's line for the 50% tick (spec 4.44).
    static let infoTickText = "The line on each bar marks 50%."
    /// The info sheet as plain sentences.
    static var infoText: String {
        [
            "\(everyoneTitle) \(infoEveryoneText)", "\(verifiedTitle) \(infoVerifiedText)", infoOnceText, infoLocalText,
            infoFloorText(BillStatsService.Comparison.defaultMinDecisionVotes), infoTickText
        ].joined(separator: " ")
    }
    static let addressForStateText = "Add your address in Profile to see your state"
    static let addressForDistrictText = "Add your address in Profile to see your district"

    /// The prompt for a local line without an address (`LocalLine.needsAddress`): "See your state and
    /// district" without a state, "See your district" with a state and no district.
    static func needsAddressPrompt(_ text: String) -> String {
        text == addressForDistrictText ? seeDistrictText : seeStateAndDistrictText
    }

    /// The map's help line: "Tap a state to see its result. Your state has a dashed outline."
    static func mapHelpText(national: Bool, outlinesYours: Bool) -> String {
        let region = national ? "state" : "district"
        let tap = "Tap a \(region) to see its result."
        return outlinesYours ? "\(tap) Your \(region) has a dashed outline." : tap
    }

    /// The map's hatch key: "Fewer than 5 votes".
    static func hatchKeyText(floor: Int) -> String {
        "Fewer than \(max(1, floor)) votes"
    }

    /// One reason's VoiceOver label: "Saves money: 12 people, 52 percent of Yea voters." The server's share is
    /// of the side's voters (each picks up to 3 reasons), not of its reasons (feature review N1).
    static func reasonAccessibilityLabel(reason: String, count: Int, pct: Double?, choice: VoteChoice) -> String {
        let people = count == 1 ? "1 person" : "\(count) people"
        guard let pct, pct.isFinite else { return "\(reason): \(people)." }
        let rounded = (pct * 10).rounded() / 10
        let percent = abs(rounded.rounded() - rounded) < 0.05 ? "\(Int(rounded.rounded()))" : String(format: "%.1f", rounded)
        return "\(reason): \(people), \(percent) percent of \(choice.title) voters."
    }

    /// "Fewer than 5 votes so far".
    static func fewerThanFloorText(_ floor: Int) -> String {
        "Fewer than \(max(1, floor)) votes so far"
    }

    /// A row or line that would clear the floor but is withheld because, beside another number shown, it
    /// would give away a group under the floor.
    static let withheldText = "Shown once more people vote"

    /// "1 vote", "40 votes", "1,157 votes" (grouped, as the tally's figures are).
    static func voteCountText(_ count: Int) -> String {
        count == 1 ? "1 vote" : "\(count.formatted()) votes"
    }

    /// "1 person abstained.", "6 people abstained."; nil for none.
    static func abstainedText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 person abstained." : "\(count) people abstained."
    }

    // MARK: - Rows

    /// What one results row shows.
    enum RowValue: Equatable {
        case split(Percentages, decisionVotes: Int)
        case noDecisionVotes
        /// Withheld under the floor, or missing because of it.
        case fewerThanFloor(Int)
        /// Over the floor, but withheld so that it cannot give away a group under it (UX-34).
        case withheld

        /// "55% Yea · 45% Nay · 9 votes", "No Yea or Nay votes yet", "Fewer than 5 votes so far", "Shown once
        /// more people vote".
        var text: String {
            switch self {
            case .split(let percentages, let decisionVotes):
                return "\(percentages.yea)% Yea · \(percentages.nay)% Nay · \(VoteResultsFormatting.voteCountText(decisionVotes))"
            case .noDecisionVotes:
                return VoteResultsFormatting.noDecisionVotesText
            case .fewerThanFloor(let floor):
                return VoteResultsFormatting.fewerThanFloorText(floor)
            case .withheld:
                return VoteResultsFormatting.withheldText
            }
        }

        /// VoiceOver text: "55 percent Yea, 45 percent Nay, 9 Yea or Nay votes".
        var accessibilityText: String {
            switch self {
            case .split(let percentages, let decisionVotes):
                let votes = decisionVotes == 1 ? "1 Yea or Nay vote" : "\(decisionVotes) Yea or Nay votes"
                return "\(percentages.yea) percent Yea, \(percentages.nay) percent Nay, \(votes)"
            case .noDecisionVotes, .fewerThanFloor, .withheld:
                return text
            }
        }

        var percentages: Percentages? {
            if case .split(let percentages, _) = self { return percentages }
            return nil
        }
    }

    /// A national row: "Everyone" or "Verified voters".
    struct NationalRow: Equatable, Identifiable {
        enum Group: String, Equatable {
            case everyone
            case verified
        }

        let group: Group
        let value: RowValue

        var id: Group { group }

        var title: String {
            switch group {
            case .everyone: return VoteResultsFormatting.everyoneTitle
            case .verified: return VoteResultsFormatting.verifiedTitle
            }
        }

        var accessibilityLabel: String {
            "\(title): \(value.accessibilityText)"
        }
    }

    /// The user's state or district line: verified voters' result, or the prompt to add an address.
    /// `title` prints the place as a code ("Verified voters in VA-11"); `spokenTitle` is what VoiceOver
    /// reads, the place in the one spoken form ("Verified voters in Virginia's 11th district"; project
    /// decision of 2026-10-21).
    enum LocalLine: Equatable {
        case result(title: String, spokenTitle: String, value: RowValue)
        case needsAddress(String)
    }

    /// The one line Results show under the floor (UX-34), in place of the tally, the abstained line, the
    /// state and district and the map: "Results open at 5 votes". It shows no count of the votes so far (project
    /// decision of 2026-10-29): watching that count before and after a friend votes would show whether they voted
    /// Yea or Nay or abstained. So nothing in Results shows a number under the floor, and the line is the same
    /// for the first voter and the fourth.
    struct FloorLine: Equatable {
        let floor: Int

        /// "Results open at 5 votes".
        var text: String {
            "Results open at \(VoteResultsFormatting.voteCountText(max(1, floor)))"
        }

        /// `text` as drawn: a no-break space keeps the figure with its word ("5 votes"), so a narrow line breaks
        /// only between the sentence's other words, never between "5" and "votes" (as the tally's figures).
        var displayText: String {
            "Results open at \(VoteResultsFormatting.voteCountText(max(1, floor)).replacingOccurrences(of: " ", with: "\u{00A0}"))"
        }

        /// "Results open at 5 Yea or Nay votes."
        var accessibilityText: String {
            let floor = max(1, floor)
            return SpokenSentences.sentence("Results open at \(floor) Yea or Nay \(floor == 1 ? "vote" : "votes")")
        }
    }

    struct Summary: Equatable {
        /// Everyone first, then verified voters, with equal weight; none under the floor.
        let national: [NationalRow]
        /// "6 people abstained." (everyone), or nil; nil under the floor.
        let abstainedText: String?
        let minDecisionVotes: Int
        let state: LocalLine
        /// Nil when the state line already asks for an address.
        let district: LocalLine?
        /// Under the floor: the one line Results show. Results then draw none of the other parts.
        let belowFloor: FloorLine?
        /// Whether the map shows: over the floor, with a state that clears it and no region withheld, so the map
        /// is never all hatched.
        let showsMap: Bool
    }

    /// Whether everyone's Yea + Nay votes are under the floor: Results then show only `FloorLine`, and Why
    /// people voted no counts.
    static func isBelowFloor(_ stats: BillStatsService.BillStats) -> Bool {
        let comparison = stats.resolvedComparison
        return comparison.allUsers.decisionVotes < comparison.minDecisionVotes
    }

    /// The one line Results show for `stats` under the floor, or nil over it.
    static func floorLine(for stats: BillStatsService.BillStats) -> FloorLine? {
        guard isBelowFloor(stats) else { return nil }
        let comparison = stats.resolvedComparison
        return FloorLine(floor: comparison.minDecisionVotes)
    }

    /// The Results section's content for `stats` and the user's location (both may be empty).
    static func summary(
        for stats: BillStatsService.BillStats,
        userStateCode: String,
        userDistrictValue: String
    ) -> Summary {
        let comparison = stats.resolvedComparison
        let floor = comparison.minDecisionVotes
        let state = normalizedStateCode(userStateCode)
        let belowFloor = floorLine(for: stats)
        let regionsWithheld = belowFloor == nil && withholdsRegions(stats)

        func value(_ totals: BillStatsService.VoteTotals?) -> RowValue {
            regionsWithheld ? .withheld : localValue(totals, floor: floor)
        }

        let stateLine: LocalLine
        var districtLine: LocalLine?
        if let state {
            stateLine = .result(
                title: "\(verifiedTitle) in \(state)",
                spokenTitle: "\(verifiedTitle) in \(stateName(state) ?? state)",
                value: value(stateRollup(in: stats, stateCode: state)?.totals)
            )
            let district = userDistrictValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if district.isEmpty {
                districtLine = .needsAddress(addressForDistrictText)
            } else {
                districtLine = .result(
                    title: "\(verifiedTitle) in \(districtLabel(stateCode: state, district: district))",
                    spokenTitle: "\(verifiedTitle) in \(SpokenForm.districtOrCode(districtLabel(stateCode: state, district: district)))",
                    value: value(districtRollup(in: stats, stateCode: state, district: district)?.totals)
                )
            }
        } else {
            stateLine = .needsAddress(addressForStateText)
        }

        return Summary(
            national: belowFloor == nil ? nationalRows(comparison) : [],
            abstainedText: belowFloor == nil ? abstainedText(comparison.allUsers.abstain) : nil,
            minDecisionVotes: floor,
            state: stateLine,
            district: districtLine,
            belowFloor: belowFloor,
            showsMap: belowFloor == nil && !regionsWithheld && !shownStateRollups(in: stats, floor: floor).isEmpty
        )
    }

    /// Everyone, then verified voters: withheld under the floor (by the server), and when Everyone minus them
    /// would leave 1 to 4 Yea or Nay votes, since the two rows would then give away the unverified voters'
    /// split (UX-34). Everyone's own floor is the summary's (`FloorLine`).
    static func nationalRows(_ comparison: BillStatsService.Comparison) -> [NationalRow] {
        let everyone = NationalRow(group: .everyone, value: splitValue(comparison.allUsers))
        let verifiedValue: RowValue
        if !comparison.verifiedWithheld, let verified = comparison.verified {
            let unverified = comparison.allUsers.decisionVotes - verified.decisionVotes
            verifiedValue = isUnderFloor(unverified, floor: comparison.minDecisionVotes) ? .withheld : splitValue(verified)
        } else {
            verifiedValue = .fewerThanFloor(comparison.minDecisionVotes)
        }
        return [everyone, NationalRow(group: .verified, value: verifiedValue)]
    }

    /// The state rollups whose results show: those with at least `floor` Yea or Nay votes.
    static func shownStateRollups(in stats: BillStatsService.BillStats, floor: Int) -> [BillStatsService.StateRollup] {
        stats.rollups.byState.values.filter { clearsFloor($0.totals, floor: floor) }
    }

    /// Whether the state and district results are withheld (UX-34): Everyone minus the states shown leaves 1
    /// to 4 Yea or Nay votes, whose split the two would give away. (Only verified voters with a state are in a
    /// state; the server withholds verified voters when they minus the states shown would, and a district when
    /// its state minus the districts shown would.) Under the floor nothing regional shows anyway.
    static func withholdsRegions(_ stats: BillStatsService.BillStats) -> Bool {
        let comparison = stats.resolvedComparison
        let floor = comparison.minDecisionVotes
        let shown = shownStateRollups(in: stats, floor: floor).reduce(0) { $0 + $1.totals.decisionVotes }
        return isUnderFloor(comparison.allUsers.decisionVotes - shown, floor: floor)
    }

    /// 1 to `floor` - 1: a group with votes, too few to show.
    private static func isUnderFloor(_ decisionVotes: Int, floor: Int) -> Bool {
        decisionVotes > 0 && decisionVotes < max(1, floor)
    }

    private static func clearsFloor(_ totals: BillStatsService.VoteTotals, floor: Int) -> Bool {
        totals.decisionVotes >= max(1, floor) && percentages(totals) != nil
    }

    static func splitValue(_ split: BillStatsService.VoteSplit) -> RowValue {
        guard let percentages = percentages(split) else { return .noDecisionVotes }
        return .split(percentages, decisionVotes: split.decisionVotes)
    }

    /// A state or district rollup: missing (the server leaves out rollups under the floor) or under
    /// the floor shows "Fewer than 5 votes so far".
    static func localValue(_ totals: BillStatsService.VoteTotals?, floor: Int) -> RowValue {
        guard let totals, clearsFloor(totals, floor: floor), let percentages = percentages(totals) else {
            return .fewerThanFloor(floor)
        }
        return .split(percentages, decisionVotes: totals.decisionVotes)
    }

    // MARK: - Location lookups

    /// "VA" for a two-letter code (any case, trimmed), else nil.
    static func normalizedStateCode(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 2, cleaned.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return cleaned
    }

    static func stateRollup(in stats: BillStatsService.BillStats, stateCode: String) -> BillStatsService.StateRollup? {
        guard let state = normalizedStateCode(stateCode) else { return nil }
        if let exact = stats.rollups.byState[state] { return exact }
        return stats.rollups.byState.values.first { normalizedStateCode($0.state) == state }
    }

    /// The user's district rollup: by key ("VA-11", or the legacy "VA|11"), else the first rollup in
    /// the state whose district normalizes to the user's.
    static func districtRollup(
        in stats: BillStatsService.BillStats,
        stateCode: String,
        district: String
    ) -> BillStatsService.DistrictRollup? {
        guard let state = normalizedStateCode(stateCode) else { return nil }
        let trimmed = district.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        if let exact = stats.rollups.byDistrict["\(state)|\(trimmed)"] ?? stats.rollups.byDistrict[trimmed] {
            return exact
        }
        guard let normalized = DistrictNormalization.normalize(trimmed, userState: state)?.uppercased() else { return nil }
        return stats.rollups.byDistrict.values.first { rollup in
            guard normalizedStateCode(rollup.state) == state else { return false }
            return DistrictNormalization.normalize(rollup.district, userState: state)?.uppercased() == normalized
        }
    }

    /// "VA-11" (no leading zero), "AK at-large", or the state and the raw district.
    static func districtLabel(stateCode: String, district: String) -> String {
        let state = normalizedStateCode(stateCode) ?? stateCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let normalized = DistrictNormalization.normalize(district, userState: state)?.uppercased() else {
            return state
        }
        if normalized == "AT-LARGE" { return "\(state) at-large" }
        return "\(state)-\(normalized)"
    }

    // MARK: - Map

    /// What VoiceOver reads for the selected region: a state's full name, a district in the one spoken form
    /// ("Virginia's 11th district", "Alaska's at-large district"; project decision of 2026-10-21), or the
    /// printed name when it has no spoken form.
    static func regionSpokenName(id: String, label: String) -> String {
        let name = regionDisplayName(id: id, label: label)
        if normalizedStateCode(label.trimmingCharacters(in: .whitespacesAndNewlines)) != nil { return name }
        return SpokenForm.districtOrCode(name)
    }

    /// The selected region's name: a state's full name on the national map ("Virginia"), a district
    /// as "VA-11" or "AK at-large".
    static func regionDisplayName(id: String, label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let state = normalizedStateCode(trimmed) {
            return stateName(state) ?? state
        }
        let parts = id.uppercased().split(separator: "-", maxSplits: 1).map(String.init)
        if parts.count == 2, let state = normalizedStateCode(parts[0]) {
            return districtLabel(stateCode: state, district: parts[1] == "AL" ? "At-Large" : parts[1])
        }
        return trimmed.isEmpty ? id : trimmed
    }

    /// "Virginia · 55% Yea · 45% Nay · 9 verified votes", or "Virginia · Fewer than 5 votes so far". No
    /// abstain count: Everyone's abstained line minus a region's would count the abstentions outside it, in a
    /// group that may have under 5 Yea or Nay votes (UX-34).
    static func mapSelectionText(
        name: String,
        yeaPct: Double?,
        yea: Int,
        nay: Int,
        decisionVotes: Int,
        floor: Int
    ) -> String {
        guard decisionVotes >= max(1, floor),
              let percentages = percentages(yeaPct: yeaPct, yea: yea, nay: nay) else {
            return "\(name) · \(fewerThanFloorText(floor))"
        }
        let votes = decisionVotes == 1 ? "1 verified vote" : "\(decisionVotes) verified votes"
        return [name, "\(percentages.yea)% Yea", "\(percentages.nay)% Nay", votes].joined(separator: " · ")
    }

    /// At the map's state level, when no district in the user's state has `floor` Yea or Nay votes, this line
    /// takes the map's place, which would be all hatched.
    static func districtsUnderFloorText(_ floor: Int) -> String {
        "Every district has fewer than \(max(1, floor)) votes so far."
    }

    /// The map legend's VoiceOver value.
    static func mapLegendAccessibilityValue(floor: Int) -> String {
        "Colour scale from 100 percent Nay in orange to 100 percent Yea in teal; "
            + "hatched areas have fewer than \(max(1, floor)) votes."
    }

    // MARK: - State names

    /// The full name of a state, DC or territory by its postal code (`USStateNames`).
    static func stateName(_ code: String) -> String? {
        USStateNames.name(forPostalCode: code)
    }
}

// MARK: - Sealed tally sheet

/// What the sealed tally sheet shows in place of Results and Why people voted (Civic Record spec 3.8, as the
/// project changed it: voting stays open on decided bills, so there is no "Voting closed" and no read-only
/// open state). Every state but Opening is a locked `BillResultsAccess`; Opening is Results that a vote on
/// this screen opened, before the stats for that vote arrive. None of them carries anything built from
/// other users' votes.
enum SealedTallyState: Equatable {
    /// No Yea, Nay or Abstain held: the SEALED stamp, "Vote to see results" and why.
    case notVoted
    /// The vote state is not known yet: a spinner and "Checking your vote…", no stamp, so a returning voter
    /// is never told to vote while the app checks.
    case checking
    /// Reading the vote failed: the stamp, "Couldn't check your vote on this bill." and Try again.
    case checkFailed
    /// The vote shows but the server does not hold it: the stamp, "Results show once your vote is saved."
    /// and Try again when there is a vote to send again.
    case awaitingSave(canRetry: Bool)
    /// After a vote on this screen, until its stats arrive: the seal lifted, a spinner and "Opening results…".
    case opening

    /// The sealed state for `access`. An open access is Opening while `opening` (a vote made on the screen,
    /// no stats yet, no error) and otherwise nil: the open tally sheet.
    init?(access: BillResultsAccess, opening: Bool) {
        switch access {
        case .open:
            guard opening else { return nil }
            self = .opening
        case .locked(.notVoted): self = .notVoted
        case .locked(.checking): self = .checking
        case .locked(.checkFailed): self = .checkFailed
        case .awaitingSave(let canRetry): self = .awaitingSave(canRetry: canRetry)
        }
    }

    /// The SEALED stamp sits over the rows; otherwise a spinner does.
    var showsStamp: Bool {
        spinnerText == nil
    }

    /// The words beside the spinner in the stamp's place.
    var spinnerText: String? {
        switch self {
        case .checking: return BillVoteBarModel.checkingCaption
        case .opening: return VoteResultsFormatting.openingText
        case .notVoted, .checkFailed, .awaitingSave: return nil
        }
    }

    /// The line under the Results sheet (`name` role): "Vote to see results".
    var line: String? {
        self == .notVoted ? VoteResultsFormatting.lockText : nil
    }

    /// The text under the Results sheet (`body`, ink 2).
    var text: String? {
        switch self {
        case .notVoted: return VoteResultsFormatting.notVotedSealedText
        case .checkFailed: return VoteResultsFormatting.checkFailedText
        case .awaitingSave: return VoteResultsFormatting.awaitingSaveText
        case .checking, .opening: return nil
        }
    }

    /// The text under the sealed Why people voted: "Reasons open after you vote." under the stamp, nothing
    /// beside a spinner. While the vote is checked a returning voter is never told to vote (spec 3.8.1's
    /// rule for the checking sheet), and in Opening the user has just voted.
    var reasonsText: String? {
        showsStamp ? VoteResultsFormatting.reasonsSealedText : nil
    }

    /// Try again under the Results sheet: a vote read to make again, or a vote to send again.
    var offersTryAgain: Bool {
        self == .checkFailed || self == .awaitingSave(canRetry: true)
    }

    /// The VoiceOver action "Go to vote buttons": only before a vote, when the vote panel is one step away.
    var offersGoToVoteButtons: Bool {
        self == .notVoted
    }
}
