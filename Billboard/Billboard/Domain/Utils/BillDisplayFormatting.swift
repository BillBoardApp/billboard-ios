import Foundation

/// User-facing formatting for bill metadata: official bill numbers and titles, timeline
/// dates and congress.gov action types. Keeps raw backend values (guids, ISO timestamps,
/// internal action codes) off the screen.
enum BillDisplayFormatting {
    // MARK: - Official bill number

    /// Citation prefix for each congress.gov bill type code.
    nonisolated private static let billTypePrefixes: [String: String] = [
        "hr": "H.R.",
        "s": "S.",
        "hjres": "H.J.Res.",
        "sjres": "S.J.Res.",
        "hconres": "H.Con.Res.",
        "sconres": "S.Con.Res.",
        "hres": "H.Res.",
        "sres": "S.Res."
    ]

    /// Official bill number such as "H.R. 1" or "S.J.Res. 213".
    ///
    /// Uses the bill type and number when both are known, otherwise parses a GovInfo
    /// package guid (e.g. "BILLS-119sjres213is"). Returns nil when neither is usable.
    nonisolated static func officialBillNumber(billType: String?, billNumber: String?, guid: String?) -> String? {
        guard let parts = billNumberParts(billType: billType, billNumber: billNumber, guid: guid),
              let prefix = billTypePrefixes[parts.typeCode] else { return nil }
        return "\(prefix) \(parts.number)"
    }

    /// The bill's type code and number, e.g. ("hr", 900): from the bill type and number when both
    /// are usable, otherwise from the GovInfo guid.
    nonisolated private static func billNumberParts(
        billType: String?,
        billNumber: String?,
        guid: String?
    ) -> (typeCode: String, number: Int)? {
        if let parts = typedBillNumberParts(billType: billType, billNumber: billNumber) {
            return parts
        }
        guard let parsed = parseGuid(guid) else { return nil }
        return typedBillNumberParts(billType: parsed.billType, billNumber: parsed.billNumber)
    }

    nonisolated private static func typedBillNumberParts(billType: String?, billNumber: String?) -> (typeCode: String, number: Int)? {
        let normalizedType = (billType ?? "")
            .lowercased()
            .filter { $0.isLetter }
        guard billTypePrefixes[normalizedType] != nil else { return nil }

        // Accept "900", or a number with its type in front ("hr900", "H.R. 900"). Anything
        // else (e.g. a composite "119-hr-900") is rejected so the guid is used instead.
        let trimmed = (billNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let typePart = trimmed.prefix { !($0.isASCII && $0.isNumber) }
        let digits = trimmed.dropFirst(typePart.count)
        guard typePart.allSatisfy({ $0.isLetter || $0 == "." || $0 == " " }),
              !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number > 0 else { return nil }
        return (normalizedType, number)
    }

    // MARK: - Bill number search

    /// The bill's number as search text: its type code and number run together ("hr900",
    /// "sjres84"), from the bill type and number, else the guid. Nil when neither is usable.
    nonisolated static func billNumberSearchKey(billType: String?, billNumber: String?, guid: String?) -> String? {
        guard let parts = billNumberParts(billType: billType, billNumber: billNumber, guid: guid) else { return nil }
        return "\(parts.typeCode)\(parts.number)"
    }

    /// The spoken names of the bill types (`SpokenForm.billNumber` says them), run together as a query is
    /// compacted, so "House bill 1" and "Senate joint resolution 21" read as numbers too.
    nonisolated private static let spokenBillTypes: [(words: String, typeCode: String)] = [
        ("housebill", "hr"),
        ("senatebill", "s"),
        ("houseresolution", "hres"),
        ("senateresolution", "sres"),
        ("housejointresolution", "hjres"),
        ("senatejointresolution", "sjres"),
        ("houseconcurrentresolution", "hconres"),
        ("senateconcurrentresolution", "sconres")
    ]

    /// A search query read as a bill number, in the form `billNumberSearchKey` gives: "H.R. 900",
    /// "hr 900", "hr900", "HR-900", "H.R. #900", "House bill 900", "S. 456", "S 456" and "s456" give "hr900"
    /// or "s456". Nil when the query is not a bill number: a known type (dots, hyphens, "#" and spaces
    /// ignored) followed by the number.
    nonisolated static func billNumberQueryKey(_ query: String) -> String? {
        var compact = query.lowercased().filter { !($0 == "." || $0 == "-" || $0 == "#" || $0.isWhitespace) }
        if let spoken = spokenBillTypes.first(where: { compact.hasPrefix($0.words) }) {
            compact = spoken.typeCode + compact.dropFirst(spoken.words.count)
        }
        let typeCode = String(compact.prefix { $0.isASCII && $0.isLetter })
        let digits = compact.dropFirst(typeCode.count)
        guard billTypePrefixes[typeCode] != nil,
              !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number > 0 else { return nil }
        return "\(typeCode)\(number)"
    }

    /// Splits "BILLS-<congress><type><number><version>" into its type and number.
    nonisolated private static func parseGuid(_ guid: String?) -> (billType: String, billNumber: String)? {
        guard let trimmed = guid?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.uppercased().hasPrefix("BILLS-") else { return nil }
        let rest = Array(trimmed.dropFirst("BILLS-".count))

        var index = 0
        while index < rest.count, rest[index].isASCII, rest[index].isNumber { index += 1 }
        guard index > 0 else { return nil }

        let typeStart = index
        while index < rest.count, rest[index].isASCII, rest[index].isLetter { index += 1 }
        guard index > typeStart else { return nil }
        let billType = String(rest[typeStart..<index])

        let numberStart = index
        while index < rest.count, rest[index].isASCII, rest[index].isNumber { index += 1 }
        guard index > numberStart else { return nil }
        let billNumber = String(rest[numberStart..<index])

        // Whatever follows must be the text version suffix (letters only), e.g. "is", "eh".
        guard rest[index...].allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return (billType, billNumber)
    }

    // MARK: - Dates

    /// Formats an ISO-8601 timestamp or a plain "yyyy-MM-dd" date as a localized
    /// medium date ("Sep 17, 2026"). Unparseable values are returned trimmed so no
    /// information is lost; empty values return nil.
    nonisolated static func displayDate(_ raw: String?, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard let date = FlexibleISO8601.parse(trimmed) else { return trimmed }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // A calendar date without a time is parsed as UTC midnight; format it in UTC so
        // it does not shift to the previous day for users west of Greenwich.
        formatter.timeZone = isDateOnly(trimmed) ? TimeZone(secondsFromGMT: 0) : timeZone
        return formatter.string(from: date)
    }

    nonisolated private static func isDateOnly(_ value: String) -> Bool {
        value.count == 10 && !value.contains("T")
    }

    // MARK: - Action types

    /// Plain-language label for a congress.gov action type code, or nil when the code
    /// is empty or not one we can describe (internal codes are hidden rather than shown raw).
    nonisolated static func actionTypeLabel(_ rawType: String?) -> String? {
        let key = (rawType ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter }
        guard !key.isEmpty else { return nil }

        switch key {
        case "introreferral":
            return "Introduced and referred"
        case "committee":
            return "Committee action"
        case "calendars":
            return "Placed on calendar"
        case "floor":
            return "Floor action"
        case "discharge":
            return "Discharged from committee"
        case "president":
            return "Sent to the President"
        case "becamelaw":
            return "Became law"
        case "veto":
            return "Veto"
        case "resolvingdifferences":
            return "Resolving differences"
        default:
            return nil
        }
    }

    // MARK: - Breakdown and actions

    /// The breakdown rows to show, in order, as (label, text): trimmed, and without a field that is
    /// missing or blank. Older summaries have no `why`, so their breakdown has no Why row.
    nonisolated static func breakdownRows(_ breakdown: BillBreakdown) -> [(label: String, text: String)] {
        let fields: [(String, String?)] = [
            ("Who", breakdown.who),
            ("What", breakdown.what),
            ("How", breakdown.how),
            ("When", breakdown.when),
            ("Where", breakdown.where),
            ("Why", breakdown.why)
        ]
        return fields.compactMap { label, text in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return (label, text)
        }
    }

    /// The actions to list, oldest first, without a repeat of the same date and text (several sources
    /// produce them). An action without text is listed by its type label (`timelineText(for:)`) when no
    /// action with text shares its date, so a bill whose only introduction action has no text still
    /// shows it. It is left out when an action with text shares its date (Congress.gov gives an Intro-S
    /// IntroReferral action no text next to the Senate's own introduction text) or its type has no label.
    nonisolated static func timelineActions(_ actions: [Bill.BillAction]) -> [Bill.BillAction] {
        let datesWithText = Set(actions.compactMap { action -> String? in
            ownText(of: action).isEmpty ? nil : trimmedDate(of: action)
        })
        let newestFirst = actions.sorted { a, b in
            let da = a.actionDate ?? ""
            let db = b.actionDate ?? ""
            if da != db { return da > db }
            return (a.text ?? "") > (b.text ?? "")
        }

        var seen = Set<String>()
        var out: [Bill.BillAction] = []
        out.reserveCapacity(newestFirst.count)
        for action in newestFirst {
            let date = trimmedDate(of: action)
            if ownText(of: action).isEmpty, datesWithText.contains(date) { continue }
            guard let text = timelineText(for: action), seen.insert(date + "|" + text.lowercased()).inserted else { continue }
            out.append(action)
        }
        return out.reversed()
    }

    /// The line to show for a timeline action: its text, or its type label when it has no text; nil
    /// when it has neither.
    nonisolated static func timelineText(for action: Bill.BillAction) -> String? {
        let text = ownText(of: action)
        return text.isEmpty ? actionTypeLabel(action.type) : text
    }

    /// The type label to show under a timeline action's line; nil when its line already is the label.
    nonisolated static func timelineTypeLabel(for action: Bill.BillAction) -> String? {
        ownText(of: action).isEmpty ? nil : actionTypeLabel(action.type)
    }

    nonisolated private static func ownText(of action: Bill.BillAction) -> String {
        (action.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func trimmedDate(of action: Bill.BillAction) -> String {
        (action.actionDate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Official title

    /// The official title to show under the plain-language headline: trimmed, or nil when it
    /// is empty or only repeats the headline.
    nonisolated static func officialTitle(_ officialTitle: String?, headline: String) -> String? {
        guard let trimmed = officialTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let trimmedHeadline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.compare(trimmedHeadline, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame else {
            return nil
        }
        return trimmed
    }

    // MARK: - Companion bills (APPF-23)

    /// "H.R. 900 · S. 456" and the other group labels come from `CompanionGroupIndex.numbersLabel(for:)`
    /// and `accessibilityLabel(for:)`; the strings below are the ones only the screens use.

    /// The tag next to a group's numbers: "Identical bills".
    nonisolated static func companionTag(isIdentical: Bool) -> String {
        isIdentical ? "Identical bills" : "Companion bills"
    }

    /// The line under a group member's number on a member page, naming the other members:
    /// "Identical to H.R. 900". Nil when there are none.
    nonisolated static func companionSubtitle(otherGuids: [String], isIdentical: Bool) -> String? {
        companionSubtitle(numbers: otherGuids.map(CompanionGroupIndex.billNumber(forGUID:)), isIdentical: isIdentical)
    }

    /// The same line from bill numbers: "Identical to H.R. 900", "Companion to H.R. 900 and S. 456".
    /// Pass spoken numbers for VoiceOver ("Identical to House bill 900"). Nil without numbers.
    nonisolated static func companionSubtitle(numbers: [String], isIdentical: Bool) -> String? {
        guard !numbers.isEmpty else { return nil }
        return "\(isIdentical ? "Identical to" : "Companion to") \(naturalList(numbers))"
    }

    /// The caption in a group's Your Vote section:
    /// "These bills have identical text. Your vote counts once for both."
    nonisolated static func companionVoteCaption(memberCount: Int, isIdentical: Bool) -> String {
        let bills = isIdentical ? "These bills have identical text." : "These bills are companion bills."
        let once = memberCount > 2 ? "Your vote counts once for all of them." : "Your vote counts once for both."
        return "\(bills) \(once)"
    }

    /// The caption over stats that combine a group's votes: "Combined votes on H.R. 900 and S. 456".
    /// Nil unless the server listed at least two combined bills (`BillStats.companionBillIds`).
    nonisolated static func combinedVotesCaption(companionBillIds: [String]?) -> String? {
        let numbers = (companionBillIds ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(CompanionGroupIndex.billNumber(forGUID:))
        guard numbers.count >= 2 else { return nil }
        return "Combined votes on \(naturalList(numbers))"
    }

    /// The note shown when the user voted differently on two members before they were combined:
    /// "Before these were combined you also voted Nay on S. 456. Your H.R. 900 vote is the one that
    /// counts." An Abstain on either side is named as such ("you also abstained on S. 456").
    nonisolated static func companionConflictNote(
        countedGuid: String,
        countedVote: VoteType,
        otherGuid: String,
        otherVote: VoteType
    ) -> String {
        let countedNumber = CompanionGroupIndex.billNumber(forGUID: countedGuid)
        let otherNumber = CompanionGroupIndex.billNumber(forGUID: otherGuid)
        let other = otherVote == .abstain
            ? "you also abstained on \(otherNumber)"
            : "you also voted \(otherVote.feedbackValue) on \(otherNumber)"
        let counted = countedVote == .abstain
            ? "Your abstention on \(countedNumber) is the one that counts."
            : "Your \(countedNumber) vote is the one that counts."
        return "Before these were combined \(other). \(counted)"
    }

    // MARK: - Members (spec D 2.3.4)

    /// A member's party and seat as R2 shows them after the name: "(D-VA)" for a senator,
    /// "(R-VA-11)" for a House member, "(R-AK)" for an at-large seat, "(I)" with no state. Nil when
    /// there is neither a party letter nor a state. `stateCode` may be a postal code or a district
    /// that already carries it ("VA-11"); the district may be "11", "VA-11", "011" or "At-Large".
    nonisolated static func memberAffiliation(partyLetter: String?, stateCode: String?, district: String?) -> String? {
        let letter = partyLetter?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let party = (letter?.isEmpty == false) ? letter : nil
        let state = postalCode(stateCode) ?? districtStatePrefix(district)
        var seat = state
        if let state, let number = districtNumber(district, state: state) {
            seat = "\(state)-\(number)"
        }
        let parts = [party, seat].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "(\(parts.joined(separator: "-")))"
    }

    /// "VA" for a two-letter code, else nil.
    nonisolated private static func postalCode(_ raw: String?) -> String? {
        let cleaned = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count == 2, cleaned.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return cleaned
    }

    /// "VA" from a district such as "VA-11" or "VA11"; nil for "11", "AL" or "At-Large".
    nonisolated private static func districtStatePrefix(_ raw: String?) -> String? {
        let cleaned = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard cleaned.count > 2, !cleaned.contains("AT-LARGE") else { return nil }
        let third = cleaned[cleaned.index(cleaned.startIndex, offsetBy: 2)]
        guard third == "-" || third.isNumber else { return nil }
        return postalCode(String(cleaned.prefix(2)))
    }

    /// The district number without leading zeros ("011" and "VA-11" give "11"); nil for an
    /// at-large seat ("At-Large", "AL", "0") or no number.
    nonisolated private static func districtNumber(_ raw: String?, state: String) -> String? {
        var cleaned = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleaned.isEmpty, !cleaned.contains("AT-LARGE"), cleaned != "AL" else { return nil }
        if cleaned.hasPrefix(state) {
            cleaned = String(cleaned.dropFirst(state.count))
        }
        let digits = cleaned.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits), number > 0 else { return nil }
        return String(number)
    }

    /// "A", "A and B", "A, B and C".
    nonisolated static func naturalList(_ items: [String]) -> String {
        guard items.count > 2, let last = items.last else { return items.joined(separator: " and ") }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension Bill {
    /// Official bill number derived from the bill type/number or the GovInfo guid.
    nonisolated var officialBillNumber: String? {
        BillDisplayFormatting.officialBillNumber(billType: billType, billNumber: billID, guid: guid)
    }

    /// The bill number as search text ("hr900"); see `BillDisplayFormatting.billNumberSearchKey`.
    nonisolated var billNumberSearchKey: String? {
        BillDisplayFormatting.billNumberSearchKey(billType: billType, billNumber: billID, guid: guid)
    }

    /// The official title for display under `title`, the generated headline; see
    /// `BillDisplayFormatting.officialTitle(_:headline:)`.
    nonisolated var displayOfficialTitle: String? {
        BillDisplayFormatting.officialTitle(officialTitle, headline: title)
    }
}
