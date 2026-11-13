import Foundation

/// The segmented filter under "Find a member" on the Congress tab (spec D 2.5.8).
enum CongressMemberFilter: String, CaseIterable, Identifiable {
    case all
    case house
    case senate
    case myState

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .house: return "House"
        case .senate: return "Senate"
        case .myState: return "My state"
        }
    }
}

/// What the "Your representatives" section shows.
enum CongressRepresentativesState: Equatable {
    /// The profile has not loaded yet, so the location is not known.
    case loadingProfile
    /// The profile has no state: ask for an address.
    case needsLocation
    /// The location is known but the members manifest has not loaded yet.
    case loadingMembers
    /// The members manifest could not be loaded.
    case membersUnavailable
    /// The manifest has no member for the user's state and district (for example right after
    /// redistricting). `region` is the user's district ("VA-11") or state.
    case notFound(region: String)
    /// The senators (roster order), then the House member.
    case members([CongressMemberManifestItem])
}

/// The logic behind the Congress tab, kept out of the views so it can be tested: who represents
/// the user, which members they follow, member search and the "bills this week" counts. Nothing
/// here makes a request; it reads the members manifest, the profile and the loaded bills.
enum CongressTabModel {
    /// "Find a member" shows at most this many matches inline; "See all members" has the rest.
    static let inlineResultLimit = 20

    // MARK: - Your representatives

    /// The user's two senators (roster order) and House member, from the members manifest.
    ///
    /// The House member is the one whose district matches the user's district. For at-large
    /// seats (Census "00"), DC and the territories (Census "98" for non-voting delegates) the
    /// manifest may list the member with no district or "0", so any at-large-style district in
    /// the state matches. A state without a district gives the senators only.
    static func representatives(
        state rawState: String,
        district rawDistrict: String,
        in manifest: [CongressMemberManifestItem]
    ) -> [CongressMemberManifestItem] {
        let state = rawState.uppercasedTrimmed
        guard !state.isEmpty else { return [] }

        let inState = manifest.filter { ($0.state ?? "").uppercasedTrimmed == state }
        var results = inState.filter { $0.chamberNormalized == CongressChamber.senate.rawValue }
        let house = inState.filter { $0.chamberNormalized == CongressChamber.house.rawValue }
        if let member = houseMember(district: rawDistrict, state: state, among: house) {
            results.append(member)
        }
        return results
    }

    private static func houseMember(
        district rawDistrict: String,
        state: String,
        among house: [CongressMemberManifestItem]
    ) -> CongressMemberManifestItem? {
        guard let target = DistrictNormalization.normalize(rawDistrict, userState: state) else { return nil }

        if let exact = house.first(where: { normalizedDistrict(of: $0, state: state) == target }) {
            return exact
        }
        guard isAtLargeLike(target) else { return nil }
        return house.first { isAtLargeLike(normalizedDistrict(of: $0, state: state)) }
    }

    private static func normalizedDistrict(of member: CongressMemberManifestItem, state: String) -> String? {
        DistrictNormalization.normalize(member.district ?? "", userState: state)
    }

    /// At-large seats and non-voting delegates: no district number, "0"/"00" (normalized to
    /// "AT-LARGE") or the Census delegate code "98".
    private static func isAtLargeLike(_ normalizedDistrict: String?) -> Bool {
        guard let normalizedDistrict else { return true }
        return normalizedDistrict == "AT-LARGE" || normalizedDistrict == "98"
    }

    /// - Parameters:
    ///   - profileLoaded: the profile has refreshed once, so an empty state means "no address".
    ///   - manifestIsLoading, manifestHasLoaded, manifestFailed: `CongressMembersManifestStore`'s
    ///     `isLoading`, `hasLoadedOnce` and `errorMessage != nil`.
    static func representativesState(
        profileLoaded: Bool,
        state: String,
        district: String,
        manifest: [CongressMemberManifestItem],
        manifestIsLoading: Bool,
        manifestHasLoaded: Bool,
        manifestFailed: Bool
    ) -> CongressRepresentativesState {
        let cleanState = state.uppercasedTrimmed
        guard !cleanState.isEmpty else {
            return profileLoaded ? .needsLocation : .loadingProfile
        }

        let members = representatives(state: cleanState, district: district, in: manifest)
        if !members.isEmpty { return .members(members) }

        if manifest.isEmpty {
            if manifestIsLoading { return .loadingMembers }
            return (manifestFailed || manifestHasLoaded) ? .membersUnavailable : .loadingMembers
        }

        let region = CongressMember.districtLabel(state: cleanState, district: district) ?? cleanState
        return .notFound(region: region)
    }

    // MARK: - Bills this week

    /// For each member, how many loaded bills they sponsor that changed inside the Bills tab's
    /// window (the same rule R1's representatives card used: manifest `updatedAt` within the
    /// window, member listed in `sponsors`). Members with no such bill get 0.
    static func recentSponsoredBillCounts(
        memberIDs: [String],
        manifestItems: [BillsManifestItem],
        window: BillboardHistoryWindow,
        now: Date = Date()
    ) -> [String: Int] {
        let ids = Set(memberIDs)
        var counts = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        guard !ids.isEmpty else { return counts }

        let cutoff = now.addingTimeInterval(-window.timeInterval)
        for item in manifestItems {
            // Check the sponsors first: most bills have none of the members, and that skips the
            // date parse.
            let sponsors = Set(item.sponsors).intersection(ids)
            guard !sponsors.isEmpty,
                  let updatedAt = FlexibleISO8601.parse(item.updatedAt),
                  updatedAt >= cutoff
            else { continue }
            for sponsor in sponsors {
                counts[sponsor, default: 0] += 1
            }
        }
        return counts
    }

    /// "2 bills this week" (one-week window), "1 bill in the last 2 weeks", or "Updating…"
    /// while the bills have not loaded.
    static func billCountText(_ count: Int?, window: BillboardHistoryWindow) -> String {
        guard let count else { return "Updating…" }
        return "\(count) \(count == 1 ? "bill" : "bills") \(windowPhrase(window))"
    }

    static func windowPhrase(_ window: BillboardHistoryWindow) -> String {
        let days = window.rawValue
        if days == 7 { return "this week" }
        if days.isMultiple(of: 7) { return "in the last \(days / 7) weeks" }
        return "in the last \(days) days"
    }

    // MARK: - Members you follow

    /// The members the profile follows that are in the manifest, in roster order. Follows of
    /// members who are not in the manifest (for example after they left Congress) are left out.
    static func followedMembers(
        followedIDs: [UUID],
        in manifest: [CongressMemberManifestItem]
    ) -> [CongressMemberManifestItem] {
        let ids = Set(followedIDs)
        guard !ids.isEmpty else { return [] }
        return manifest.filter { ids.contains(UUID.deterministic(from: $0.id)) }
    }

    /// How many followed members are not in the manifest.
    static func unmatchedFollowCount(followedIDs: [UUID], in manifest: [CongressMemberManifestItem]) -> Int {
        let ids = Set(followedIDs)
        guard !ids.isEmpty else { return 0 }
        let known = Set(manifest.map { UUID.deterministic(from: $0.id) })
        return ids.subtracting(known).count
    }

    static func isFollowed(_ member: CongressMemberManifestItem, followedIDs: [UUID]) -> Bool {
        followedIDs.contains(UUID.deterministic(from: member.id))
    }

    // MARK: - Find a member

    /// The matches "Find a member" lists inline, or nil when it should list nothing: an empty
    /// search with the All filter would just be the first 20 names of the roster, so the
    /// section then offers "See all members" only.
    struct InlineResults: Equatable {
        let members: [CongressMemberManifestItem]
        let totalCount: Int

        var isTruncated: Bool { totalCount > members.count }
    }

    static func shouldShowInlineResults(query: String, filter: CongressMemberFilter) -> Bool {
        !searchTokens(query).isEmpty || filter != .all
    }

    static func inlineResults(
        in manifest: [CongressMemberManifestItem],
        query: String,
        filter: CongressMemberFilter,
        userState: String,
        limit: Int = inlineResultLimit
    ) -> InlineResults? {
        guard shouldShowInlineResults(query: query, filter: filter) else { return nil }
        let all = searchResults(in: manifest, query: query, filter: filter, userState: userState)
        return InlineResults(members: Array(all.prefix(max(0, limit))), totalCount: all.count)
    }

    /// Every member in `filter` that matches `query`.
    ///
    /// The query is split into words; a member matches when every word matches its name (any part,
    /// ignoring case and accents), its state (postal code such as "va", or the start of a word of
    /// the state's name such as "virg") or its House district ("11", "VA-11", "va11"). Members
    /// matched by state or district come first, so "va" lists Virginia's members before names
    /// that contain "va"; otherwise the filter's order is kept.
    static func searchResults(
        in manifest: [CongressMemberManifestItem],
        query: String,
        filter: CongressMemberFilter,
        userState: String
    ) -> [CongressMemberManifestItem] {
        let pool = members(in: manifest, filter: filter, userState: userState)
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return pool }

        var ranked: [(rank: Int, index: Int, member: CongressMemberManifestItem)] = []
        for (index, member) in pool.enumerated() {
            var rank = 1
            var matchesEveryToken = true
            for token in tokens {
                switch match(member, token: token) {
                case .none:
                    matchesEveryToken = false
                case .location:
                    rank = 0
                case .name:
                    break
                }
                if !matchesEveryToken { break }
            }
            if matchesEveryToken {
                ranked.append((rank, index, member))
            }
        }

        return ranked
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.member)
    }

    /// The members a filter covers, before any search. "My state" lists the senators, then the
    /// House members by district; it is empty when the profile has no state.
    static func members(
        in manifest: [CongressMemberManifestItem],
        filter: CongressMemberFilter,
        userState: String
    ) -> [CongressMemberManifestItem] {
        switch filter {
        case .all:
            return manifest
        case .house:
            return manifest.filter { $0.chamberNormalized == CongressChamber.house.rawValue }
        case .senate:
            return manifest.filter { $0.chamberNormalized == CongressChamber.senate.rawValue }
        case .myState:
            let state = userState.uppercasedTrimmed
            guard !state.isEmpty else { return [] }
            return delegationSorted(
                manifest.filter { ($0.state ?? "").uppercasedTrimmed == state },
                state: state
            )
        }
    }

    /// Senators first (roster order), then House members by district number (at-large first),
    /// then anyone else.
    private static func delegationSorted(_ members: [CongressMemberManifestItem], state: String) -> [CongressMemberManifestItem] {
        func groupRank(_ member: CongressMemberManifestItem) -> Int {
            switch member.chamberNormalized {
            case CongressChamber.senate.rawValue: return 0
            case CongressChamber.house.rawValue: return 1
            default: return 2
            }
        }
        func districtNumber(_ member: CongressMemberManifestItem) -> Int {
            guard let normalized = normalizedDistrict(of: member, state: state) else { return 0 }
            return Int(normalized) ?? 0
        }
        return members.enumerated()
            .sorted { lhs, rhs in
                let left = (groupRank(lhs.element), districtNumber(lhs.element), lhs.offset)
                let right = (groupRank(rhs.element), districtNumber(rhs.element), rhs.offset)
                return left < right
            }
            .map(\.element)
    }

    /// The search words: lower case, accents removed, split on spaces and commas.
    static func searchTokens(_ query: String) -> [String] {
        fold(query)
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private enum TokenMatch {
        case none
        case name
        case location
    }

    private static func match(_ member: CongressMemberManifestItem, token: String) -> TokenMatch {
        let state = (member.state ?? "").uppercasedTrimmed

        if !state.isEmpty {
            if token == state.lowercased() { return .location }
            if let name = stateName(for: state).map({ fold($0) }) {
                let words = name.split(separator: " ")
                if name.hasPrefix(token) || words.contains(where: { $0.hasPrefix(token) }) {
                    return .location
                }
            }
        }

        if let wanted = districtQuery(token),
           member.chamberNormalized == CongressChamber.house.rawValue,
           wanted.state == nil || wanted.state == state,
           let district = normalizedDistrict(of: member, state: state),
           district == wanted.district {
            return .location
        }

        if fold(member.name).contains(token) { return .name }
        return .none
    }

    /// Reads "11", "11th", "va-11" or "va11" as a district (number without leading zeros) and an
    /// optional state code.
    private static func districtQuery(_ token: String) -> (state: String?, district: String)? {
        var rest = Substring(token)
        var state: String?

        let leadingLetters = rest.prefix(while: { $0.isLetter })
        if !leadingLetters.isEmpty {
            guard leadingLetters.count == 2 else { return nil }
            state = leadingLetters.uppercased()
            rest = rest.dropFirst(2)
            if rest.first == "-" { rest = rest.dropFirst() }
        }

        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let suffix = String(rest.dropFirst(digits.count))
        guard suffix.isEmpty || ["st", "nd", "rd", "th"].contains(suffix) else { return nil }

        let number = String(digits.drop(while: { $0 == "0" }))
        guard !number.isEmpty else { return nil }
        return (state, number)
    }

    private static func fold(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - States

    /// The full name for a postal code ("VA" → "Virginia"): the 50 states, DC and the five
    /// territories with a delegate in the House (`USStateNames`).
    static func stateName(for code: String) -> String? {
        USStateNames.name(forPostalCode: code)
    }

    // MARK: - Voting seats

    /// A House member for DC or a territory (`USState.hasDelegateOnly`): a non-voting delegate, or Puerto
    /// Rico's Resident Commissioner. The manifest has no flag for them, so the seat's state says it, as a
    /// postal code or a name ("PR", "Puerto Rico"), whatever district the row gives.
    static func isNonVotingDelegate(_ member: CongressMemberManifestItem) -> Bool {
        guard member.chamberNormalized == CongressChamber.house.rawValue,
              let code = DistrictPickerModel.stateCode(from: member.state ?? "") else { return false }
        return DistrictPickerModel.state(forCode: code)?.hasDelegateOnly == true
    }

    /// `members` without the non-voting delegates, in the same order. Every count and share counts these
    /// (project decision 2026-10-31: counts and shares use the voting seats): the Congress deck, How Congress
    /// works, the chamber and party pages' Composition, the Parties rows and the directory's counters. The
    /// delegates stay in every list, roll and search, in Your representatives and in Where you vote.
    static func votingMembers(_ members: [CongressMemberManifestItem]) -> [CongressMemberManifestItem] {
        members.filter { !isNonVotingDelegate($0) }
    }

    /// The voting members of each chamber, for the deck ("House 433 · Senate 100" with two seats vacant)
    /// and How Congress works.
    static func chamberCounts(in manifest: [CongressMemberManifestItem]) -> (house: Int, senate: Int) {
        let voting = votingMembers(manifest)
        return (
            house: voting.filter { $0.chamberNormalized == CongressChamber.house.rawValue }.count,
            senate: voting.filter { $0.chamberNormalized == CongressChamber.senate.rawValue }.count
        )
    }
}

/// How members are named across the Congress tab, member rows, the bill page and the member page
/// (spec D 2.3.4; Civic Record spec 3.14, 3.15): party letters, never "Dem"/"GOP"/"Ind"; titled names
/// ("Sen. Tim Kaine", "Rep. Jane Doe"); the affiliation line ("D · Senate · VA"); and one spoken form
/// ("Representative Jane Doe, Republican, Virginia's 11th district").
enum CongressMemberLabel {
    static func party(of member: CongressMemberManifestItem) -> PoliticalParty? {
        PoliticalParty.from(raw: member.party)
    }

    static func chamber(of member: CongressMemberManifestItem) -> CongressChamber? {
        member.chamberNormalized.flatMap(CongressChamber.init(rawValue:))
    }

    /// "House", "House of Representatives", "Representative" → House; "Senate", "Senator" → Senate.
    static func chamber(named value: String) -> CongressChamber? {
        let lower = value.trimmed.lowercased()
        if lower.contains("house") || lower.contains("representative") { return .house }
        if lower.contains("senat") { return .senate }
        return nil
    }

    /// "Sen. Tim Kaine", "Rep. Jane Doe", or the name alone for an unknown chamber.
    static func titledName(_ name: String, chamber: CongressChamber?) -> String {
        switch chamber {
        case .senate: return "Sen. \(name)"
        case .house: return "Rep. \(name)"
        case nil: return name
        }
    }

    /// The affiliation line of a member (Civic Record spec 3.14, 3.15, 4.30, 4.45), led by the party letter
    /// so the party is always written as well as shown on the disc: "D · Senate · VA", "R · House · TX-7"
    /// (the `docket` role sets it in capitals). Every affiliation line uses it: member rows, Your
    /// representatives, the bill page's sponsor and How Congress voted. Unknown parts are left out; nil
    /// when nothing is known.
    static func affiliation(party: PoliticalParty?, state: String?, district: String?, chamber: CongressChamber?) -> String? {
        let parts = affiliationParts(
            party: party,
            chamber: chamber,
            region: seat(state: state, district: district, chamber: chamber)
        )
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The seat on an affiliation line: "VA" for a senator or an at-large seat, "TX-7" for a House district,
    /// with no leading zero (spec 3.14 and the frames' "R · House · TX-7", "R · House · VA-1"), as the
    /// user's own district is written (`CongressMember.districtLabel`). A state that is not a postal code is given as it is, without a
    /// district; with no state, a district such as "TX-7" still gives its seat. Nil when nothing is known.
    static func seat(state rawState: String?, district: String?, chamber: CongressChamber?) -> String? {
        if let state = rawState?.trimmedNonEmpty, !(state.count == 2 && state.allSatisfy(\.isLetter)) {
            return state
        }
        return BillDisplayFormatting.memberAffiliation(
            partyLetter: nil,
            stateCode: rawState,
            district: chamber == .senate ? nil : district
        )?
        .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    }

    /// The member page's docket line (spec 4.59), with the state and district in words: "D · Senate ·
    /// Virginia", "R · House · Texas 7th district", "R · House · Alaska at-large".
    static func pageAffiliation(party: PoliticalParty?, state rawState: String?, district: String?, chamber: CongressChamber?) -> String? {
        var place: String?
        if let state = rawState?.trimmedNonEmpty {
            let stateWords = CongressTabModel.stateName(for: state) ?? state
            place = stateWords
            if chamber != .senate, let normalized = DistrictNormalization.normalize(district ?? "", userState: state.uppercased()) {
                if normalized == "AT-LARGE" {
                    place = "\(stateWords) at-large"
                } else if let number = Int(normalized) {
                    place = "\(stateWords) \(SpokenForm.ordinal(number)) district"
                }
            }
        }
        let parts = affiliationParts(party: party, chamber: chamber, region: place)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func affiliationParts(party: PoliticalParty?, chamber: CongressChamber?, region: String?) -> [String] {
        [party?.letter, chamber.map { chamberWord($0) }, region].compactMap { $0 }
    }

    /// An affiliation line set for the docket face: a no-break space before each "·", so a dot ends its
    /// line rather than starting the next when the line wraps at large text sizes.
    static func docketText(_ affiliation: String) -> String {
        affiliation.replacingOccurrences(of: " · ", with: "\u{00A0}· ")
    }

    /// The member page's DISTRICT row: "7th", "At-large", or nil for a senator or an unknown district.
    static func districtWords(state rawState: String?, district: String?, chamber: CongressChamber?) -> String? {
        guard chamber != .senate, let district = district?.trimmedNonEmpty else { return nil }
        let state = rawState?.trimmedNonEmpty?.uppercased() ?? ""
        guard let normalized = DistrictNormalization.normalize(district, userState: state) else { return nil }
        if normalized == "AT-LARGE" { return "At-large" }
        if let number = Int(normalized) { return SpokenForm.ordinal(number) }
        return nil
    }

    static func chamberWord(_ chamber: CongressChamber) -> String {
        switch chamber {
        case .senate: return "Senate"
        case .house: return "House"
        }
    }

    /// What VoiceOver reads for a member, the one spoken form on every screen that names one (project decision
    /// of 2026-10-21): the bill page's sponsor and How Congress voted, member rows, the member page, Your
    /// representatives, Profile, setup and the Weekly Brief. "Representative Jane Doe, Republican, Virginia's
    /// 11th district", "Senator Tim Kaine, Democrat, Virginia"; the seat as `spokenSeat` says it. Parts that
    /// are not known are left out.
    static func spokenDescription(name: String, party: PoliticalParty?, state rawState: String?, district: String?, chamber: CongressChamber?) -> String {
        let titled: String
        switch chamber {
        case .senate: titled = "Senator \(name)"
        case .house: titled = "Representative \(name)"
        case nil: titled = name
        }
        return [titled, party?.displayName, spokenSeat(state: rawState, district: district, chamber: chamber)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The seat of the affiliation line (`seat`) in words, as `SpokenForm.district` says a district code:
    /// "Virginia" for a senator, "Virginia's 11th district" for a House district, "Alaska's at-large
    /// district" for an at-large seat and "District of Columbia's at-large district" for a delegate's (district
    /// 0, 00, AL or At-Large), and the state alone for a House member whose district is not known. A state that
    /// is not a postal code is said as it is. Nil when nothing is known.
    static func spokenSeat(state rawState: String?, district: String?, chamber: CongressChamber?) -> String? {
        guard let seat = seat(state: rawState, district: district, chamber: chamber) else { return nil }
        guard seat.count == 2, chamber != .senate,
              DistrictNormalization.normalize(district ?? "", userState: seat) == "AT-LARGE" else {
            return SpokenForm.districtOrCode(seat)
        }
        return SpokenForm.district("\(seat)-AL") ?? SpokenForm.districtOrCode(seat)
    }
}
