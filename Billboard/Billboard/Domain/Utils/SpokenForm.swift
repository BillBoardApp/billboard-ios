import Foundation

/// What VoiceOver reads for the codes Civic Record prints in the docket face (spec 1.7): a district
/// code that stands alone ("VA-11") is "Virginia's 11th district", a bill number ("H.R. 1234") is
/// "House bill 1234". Sighted readers get the code; the spoken form says what it stands for.
nonisolated enum SpokenForm {
    // MARK: - Ordinals

    /// "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "119th".
    static func ordinal(_ number: Int) -> String {
        let lastTwo = abs(number) % 100
        let suffix: String
        if (11...13).contains(lastTwo) {
            suffix = "th"
        } else {
            switch abs(number) % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(number)\(suffix)"
    }

    // MARK: - District codes

    /// The spoken form of a district code: "VA-11" or "VA-011" → "Virginia's 11th district";
    /// "AK-AL", "AK-At-Large", "AK-00" or "AK-0" → "Alaska's at-large district"; a state code alone
    /// ("VA") → "Virginia". A space works in place of the hyphen and case does not matter. Nil when
    /// the state is not a postal code Billboard knows or the district is not a number or at-large.
    /// The place takes its possessive as `possessive(_:)` writes it ("U.S. Virgin Islands' at-large district").
    static func district(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let stateCode = String(trimmed.prefix(2)).uppercased()
        guard let state = USStateNames.name(forPostalCode: stateCode) else { return nil }

        let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return state }
        guard rest.first == "-" || trimmed.dropFirst(2).first == " " else { return nil }
        let district = rest.drop(while: { $0 == "-" || $0 == " " }).uppercased()

        if district == "AL" || district == "AT-LARGE" || district == "AT LARGE" {
            return "\(possessive(state)) at-large district"
        }
        guard !district.isEmpty, district.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(district) else {
            return nil
        }
        if number == 0 { return "\(possessive(state)) at-large district" }
        return "\(possessive(state)) \(ordinal(number)) district"
    }

    /// A place name's possessive: "Virginia's", and "Texas's" and "Illinois's" for a singular name ending in
    /// "s", but "U.S. Virgin Islands'" and "Northern Mariana Islands'": a plural name takes the apostrophe alone.
    static func possessive(_ place: String) -> String {
        place.hasSuffix("Islands") ? "\(place)'" : "\(place)'s"
    }

    /// `district(_:)`, or the code itself when it has no spoken form.
    static func districtOrCode(_ code: String) -> String {
        district(code) ?? code
    }

    // MARK: - Bill numbers

    /// The words for each congress.gov bill type code.
    private static let billTypeWords: [String: String] = [
        "hr": "House bill",
        "s": "Senate bill",
        "hres": "House resolution",
        "sres": "Senate resolution",
        "hjres": "House joint resolution",
        "sjres": "Senate joint resolution",
        "hconres": "House concurrent resolution",
        "sconres": "Senate concurrent resolution"
    ]

    /// The spoken form of an official bill number: "H.R. 1234" → "House bill 1234", "S. 456" →
    /// "Senate bill 456", "S.J.Res. 21" → "Senate joint resolution 21". Anything that is not a bill
    /// number is returned unchanged.
    static func billNumber(_ number: String) -> String {
        guard let key = BillDisplayFormatting.billNumberQueryKey(number) else { return number }
        let typeCode = String(key.prefix { $0.isLetter })
        let digits = key.dropFirst(typeCode.count)
        guard let words = billTypeWords[typeCode] else { return number }
        return "\(words) \(digits)"
    }
}

/// The full names of the postal codes Billboard shows: the 50 states, DC and the five territories
/// with a delegate in the House.
nonisolated enum USStateNames {
    /// "VA" → "Virginia"; nil for a code that is not one of them.
    static func name(forPostalCode code: String) -> String? {
        names[code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }

    private static let names: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri",
        "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey",
        "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
        "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
        "DC": "District of Columbia", "PR": "Puerto Rico", "GU": "Guam", "VI": "U.S. Virgin Islands",
        "AS": "American Samoa", "MP": "Northern Mariana Islands"
    ]
}

/// VoiceOver labels read as sentences: "Clean Energy Reporting Act. House bill 1234. New." One rule for every
/// label built from parts (slips, docket lines, Updates rows, the Weekly Brief, notices, the bill page's
/// ledgers and sealed sheets): each part trimmed, empty parts left out, and a full stop added unless the part
/// already ends a sentence with ".", "?", "!" or "…". The copies this replaced checked only "." in some
/// places, so a title ending in "?" read "Is it fair?." on a slip and not in Updates.
nonisolated enum SpokenSentences {
    static func join(_ parts: [String?]) -> String {
        parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(sentence)
            .joined(separator: " ")
    }

    /// `part` ending a sentence: as it is when it ends with ".", "?", "!" or "…", else with a full stop.
    static func sentence(_ part: String) -> String {
        guard let last = part.last, !".?!…".contains(last) else { return part }
        return "\(part)."
    }
}
