import Foundation

/// A state, DC or a territory in the location editor's State picker.
nonisolated struct USState: Hashable, Identifiable, Sendable {
    /// Postal code, such as "VA".
    let code: String
    /// Full name, such as "Virginia".
    let name: String
    /// House seats in the 119th Congress (2020 apportionment). DC's and each territory's one seat is its
    /// non-voting delegate (Puerto Rico's, its Resident Commissioner).
    let houseSeats: Int
    /// DC or a territory: one non-voting delegate and no senators.
    var hasDelegateOnly = false

    var id: String { code }

    /// One seat: the state, DC or territory is a single at-large district.
    var isAtLarge: Bool { houseSeats == 1 }

    /// The place as a sentence names it: "the District of Columbia", "the U.S. Virgin Islands", "Puerto Rico".
    var nameInSentence: String {
        name.hasPrefix("District") || name.hasSuffix("Islands") ? "the \(name)" : name
    }
}

/// One entry in the District picker.
nonisolated struct DistrictChoice: Hashable, Identifiable, Sendable {
    /// The district as the profile stores it (`custom:district`): "11", or "At-Large".
    let value: String
    /// What the picker shows: "District 11", or "At-large".
    let label: String

    var id: String { value }
}

/// The data behind "Where do you vote?" (spec D 2.5.3): the 50 states, DC and the five territories with a
/// delegate (UX-39), the districts of a state, and the members who represent a district. Pure, so it is unit
/// tested. Main-actor isolated (the default) because the manifest and district helpers it uses are.
enum DistrictPickerModel {
    /// The stored value of a single at-large district (as onboarding stored it before R2).
    static let atLargeValue = "At-Large"
    /// The Census code of a delegate's district (DC and the territories): an address found there comes back
    /// as "PR-98", which is the at-large seat.
    static let censusDelegateDistrict = "98"

    /// The 50 states, DC and the territories, by name. DC and the territories (Puerto Rico, Guam, the U.S.
    /// Virgin Islands, American Samoa and the Northern Mariana Islands) each have one at-large seat held by a
    /// non-voting delegate, and no senators (UX-39: their residents could not finish setup).
    static let states: [USState] = [
        USState(code: "AL", name: "Alabama", houseSeats: 7),
        USState(code: "AK", name: "Alaska", houseSeats: 1),
        USState(code: "AS", name: "American Samoa", houseSeats: 1, hasDelegateOnly: true),
        USState(code: "AZ", name: "Arizona", houseSeats: 9),
        USState(code: "AR", name: "Arkansas", houseSeats: 4),
        USState(code: "CA", name: "California", houseSeats: 52),
        USState(code: "CO", name: "Colorado", houseSeats: 8),
        USState(code: "CT", name: "Connecticut", houseSeats: 5),
        USState(code: "DE", name: "Delaware", houseSeats: 1),
        USState(code: "DC", name: "District of Columbia", houseSeats: 1, hasDelegateOnly: true),
        USState(code: "FL", name: "Florida", houseSeats: 28),
        USState(code: "GA", name: "Georgia", houseSeats: 14),
        USState(code: "GU", name: "Guam", houseSeats: 1, hasDelegateOnly: true),
        USState(code: "HI", name: "Hawaii", houseSeats: 2),
        USState(code: "ID", name: "Idaho", houseSeats: 2),
        USState(code: "IL", name: "Illinois", houseSeats: 17),
        USState(code: "IN", name: "Indiana", houseSeats: 9),
        USState(code: "IA", name: "Iowa", houseSeats: 4),
        USState(code: "KS", name: "Kansas", houseSeats: 4),
        USState(code: "KY", name: "Kentucky", houseSeats: 6),
        USState(code: "LA", name: "Louisiana", houseSeats: 6),
        USState(code: "ME", name: "Maine", houseSeats: 2),
        USState(code: "MD", name: "Maryland", houseSeats: 8),
        USState(code: "MA", name: "Massachusetts", houseSeats: 9),
        USState(code: "MI", name: "Michigan", houseSeats: 13),
        USState(code: "MN", name: "Minnesota", houseSeats: 8),
        USState(code: "MS", name: "Mississippi", houseSeats: 4),
        USState(code: "MO", name: "Missouri", houseSeats: 8),
        USState(code: "MT", name: "Montana", houseSeats: 2),
        USState(code: "NE", name: "Nebraska", houseSeats: 3),
        USState(code: "NV", name: "Nevada", houseSeats: 4),
        USState(code: "NH", name: "New Hampshire", houseSeats: 2),
        USState(code: "NJ", name: "New Jersey", houseSeats: 12),
        USState(code: "NM", name: "New Mexico", houseSeats: 3),
        USState(code: "NY", name: "New York", houseSeats: 26),
        USState(code: "NC", name: "North Carolina", houseSeats: 14),
        USState(code: "ND", name: "North Dakota", houseSeats: 1),
        USState(code: "MP", name: "Northern Mariana Islands", houseSeats: 1, hasDelegateOnly: true),
        USState(code: "OH", name: "Ohio", houseSeats: 15),
        USState(code: "OK", name: "Oklahoma", houseSeats: 5),
        USState(code: "OR", name: "Oregon", houseSeats: 6),
        USState(code: "PA", name: "Pennsylvania", houseSeats: 17),
        USState(code: "PR", name: "Puerto Rico", houseSeats: 1, hasDelegateOnly: true),
        USState(code: "RI", name: "Rhode Island", houseSeats: 2),
        USState(code: "SC", name: "South Carolina", houseSeats: 7),
        USState(code: "SD", name: "South Dakota", houseSeats: 1),
        USState(code: "TN", name: "Tennessee", houseSeats: 9),
        USState(code: "TX", name: "Texas", houseSeats: 38),
        USState(code: "VI", name: "U.S. Virgin Islands", houseSeats: 1, hasDelegateOnly: true),
        USState(code: "UT", name: "Utah", houseSeats: 4),
        USState(code: "VT", name: "Vermont", houseSeats: 1),
        USState(code: "VA", name: "Virginia", houseSeats: 11),
        USState(code: "WA", name: "Washington", houseSeats: 10),
        USState(code: "WV", name: "West Virginia", houseSeats: 2),
        USState(code: "WI", name: "Wisconsin", houseSeats: 8),
        USState(code: "WY", name: "Wyoming", houseSeats: 1)
    ]

    private static let statesByCode: [String: USState] = Dictionary(
        uniqueKeysWithValues: states.map { ($0.code, $0) }
    )

    private static let codesByName: [String: String] = {
        var map = Dictionary(uniqueKeysWithValues: states.map { ($0.name.uppercased(), $0.code) })
        map["WASHINGTON DC"] = "DC"
        map["WASHINGTON D.C."] = "DC"
        map["VIRGIN ISLANDS"] = "VI"
        map["US VIRGIN ISLANDS"] = "VI"
        map["UNITED STATES VIRGIN ISLANDS"] = "VI"
        map["NORTHERN MARIANAS"] = "MP"
        return map
    }()

    static func state(forCode code: String) -> USState? {
        statesByCode[code.uppercasedTrimmed]
    }

    /// The postal code for a code or a full name ("va", "Virginia"), or nil when it is neither.
    static func stateCode(from raw: String) -> String? {
        let upper = raw.uppercasedTrimmed
        guard !upper.isEmpty else { return nil }
        if statesByCode[upper] != nil { return upper }
        return codesByName[upper]
    }

    /// A district as the profile stores it: "11" ("VA-11", "11th", "011" all give "11"), or
    /// "At-Large" ("AL", "0", "At-large", and the Census delegate code "98" in DC and the territories). Nil
    /// when nothing can be read from `raw`.
    static func normalizedDistrict(_ raw: String, state: String) -> String? {
        guard let normalized = DistrictNormalization.normalize(raw, userState: state) else { return nil }
        if normalized == "AT-LARGE" { return atLargeValue }
        if normalized == censusDelegateDistrict, Self.state(forCode: state)?.hasDelegateOnly == true { return atLargeValue }
        guard Int(normalized) != nil else { return nil }
        return normalized
    }

    /// The District picker's choices for `stateCode`, in order: "At-large" alone for a one-seat
    /// state, DC and a territory, else "District 1" ... "District N". The members manifest adds any district it
    /// lists that the seat table does not (so the picker follows the data), and the seat table keeps a
    /// district with a vacant seat, or with no manifest loaded, in the list.
    static func districtChoices(for stateCode: String, manifest: [CongressMemberManifestItem]) -> [DistrictChoice] {
        let code = stateCode.uppercasedTrimmed
        guard !code.isEmpty else { return [] }
        let seatTable = state(forCode: code)

        if seatTable?.isAtLarge == true {
            return [atLargeChoice]
        }

        var numbers = Set<Int>(seatTable.map { Array(1...$0.houseSeats) } ?? [])
        var hasAtLarge = false
        for member in houseMembers(in: manifest, state: code) {
            guard let district = normalizedDistrict(member.district ?? "", state: code) else { continue }
            if district == atLargeValue {
                hasAtLarge = true
            } else if let number = Int(district), (1...99).contains(number) {
                numbers.insert(number)
            }
        }

        // A state the seat table does not know (it never happens for the 50 and DC) shows what the
        // manifest has.
        if numbers.isEmpty {
            return hasAtLarge ? [atLargeChoice] : []
        }
        return numbers.sorted().map { DistrictChoice(value: String($0), label: "District \($0)") }
    }

    private static let atLargeChoice = DistrictChoice(value: atLargeValue, label: "At-large")

    /// The members who represent `district` of `state`: the two senators (by name), then the House
    /// member (DC and a territory: its delegate only). When no House member matches the district, a one-seat state's
    /// House member is used, as onboarding did before R2.
    static func representatives(
        in manifest: [CongressMemberManifestItem],
        state: String,
        district: String
    ) -> [CongressMemberManifestItem] {
        let code = state.uppercasedTrimmed
        guard !code.isEmpty else { return [] }

        let senators = manifest
            .filter { $0.chamberNormalized == "Senate" && $0.state?.uppercasedTrimmed == code }
        let sortedSenators = CongressMemberManifestItem.rosterSorted(senators)

        let house = houseMembers(in: manifest, state: code)
        let wanted = normalizedDistrict(district, state: code)
        var houseMember = house.first { member in
            guard let wanted else { return false }
            return normalizedDistrict(member.district ?? "", state: code) == wanted
        }
        if houseMember == nil, Self.state(forCode: code)?.isAtLarge == true || wanted == atLargeValue {
            houseMember = house.first { normalizedDistrict($0.district ?? "", state: code) == atLargeValue }
                ?? (house.count == 1 ? house.first : nil)
        }

        return sortedSenators + (houseMember.map { [$0] } ?? [])
    }

    private static func houseMembers(in manifest: [CongressMemberManifestItem], state code: String) -> [CongressMemberManifestItem] {
        manifest.filter { $0.chamberNormalized == "House" && $0.state?.uppercasedTrimmed == code }
    }

    /// "VA-11" or "VA-2" (no leading zero, as the member rows' affiliation lines write the seat), "AK
    /// at-large", "DC at-large" or "PR at-large".
    static func locationLabel(state: String, district: String) -> String {
        let code = state.uppercasedTrimmed
        guard let normalized = normalizedDistrict(district, state: code) else { return code }
        if normalized == atLargeValue {
            return "\(code) at-large"
        }
        return CongressMember.districtLabel(state: code, district: normalized) ?? "\(code)-\(normalized)"
    }

    /// The success panel's headline: "You're in VA-11.", "You're in Alaska's at-large district.",
    /// "You're in the District of Columbia.", or for a territory, as for DC, "You're in Puerto Rico." and
    /// "You're in the U.S. Virgin Islands."
    static func successHeadline(state: String, district: String) -> String {
        let code = state.uppercasedTrimmed
        if let place = Self.state(forCode: code), place.hasDelegateOnly {
            return "You're in \(place.nameInSentence)."
        }
        if normalizedDistrict(district, state: code) == atLargeValue, let name = Self.state(forCode: code)?.name {
            return "You're in \(name)'s at-large district."
        }
        return "You're in \(locationLabel(state: code, district: district))."
    }
}

/// The "Where do you vote?" form's fields and when its buttons are enabled. Pure, for tests.
struct LocationForm: Equatable {
    var line1 = ""
    var line2 = ""
    var city = ""
    /// Postal code ("VA"), or empty.
    var state = ""
    var zip = ""
    /// The District picker's value ("11", "At-Large"), or empty.
    var district = ""

    /// The state as a known postal code, or nil.
    var stateCode: String? {
        DistrictPickerModel.stateCode(from: state)
    }

    /// Five digits, or ZIP+4.
    var isZipValid: Bool {
        zip.trimmed.range(of: #"^\d{5}(-\d{4})?$"#, options: .regularExpression) != nil
    }

    /// "Find my district": street, city, a known state and a valid ZIP.
    var canFindDistrict: Bool {
        !line1.trimmed.isEmpty && !city.trimmed.isEmpty && stateCode != nil && isZipValid
    }

    /// What a disabled "Find my district" says is missing (Civic Record spec 4.16): every part when nothing is
    /// filled in, "Add your street address, city, state and ZIP to continue.", else only what is missing,
    /// "Add a ZIP to continue.". Nil when the form is complete.
    var findDistrictHint: String? {
        let missingStreet = line1.trimmed.isEmpty
        let missingCity = city.trimmed.isEmpty
        let missingState = stateCode == nil
        let missingZip = zip.trimmed.isEmpty
        if missingStreet, missingCity, missingState, missingZip {
            return "Add your street address, city, state and ZIP to continue."
        }
        var parts: [String] = []
        if missingStreet { parts.append("your street address") }
        if missingCity { parts.append("a city") }
        if missingState { parts.append("a state") }
        if missingZip {
            parts.append("a ZIP")
        } else if !isZipValid {
            parts.append("a 5-digit ZIP")
        }
        guard let last = parts.popLast() else { return nil }
        let list = parts.isEmpty ? last : "\(parts.joined(separator: ", ")) and \(last)"
        return "Add \(list) to continue."
    }

    /// What a disabled Continue in "Choose your district" says is missing. Nil when it can continue.
    func chooseDistrictHint(choices: [DistrictChoice]) -> String? {
        if stateCode == nil { return "Choose a state and a district to continue." }
        return canChooseDistrict(choices: choices) ? nil : "Choose a district to continue."
    }

    /// The chosen district as stored, or nil until a state and a district are picked.
    var chosenDistrict: String? {
        guard let stateCode else { return nil }
        return DistrictPickerModel.normalizedDistrict(district, state: stateCode)
    }

    /// "Continue" in "Choose your district": a known state and one of its districts.
    func canChooseDistrict(choices: [DistrictChoice]) -> Bool {
        guard let chosenDistrict else { return false }
        return choices.contains { $0.value == chosenDistrict }
    }

    /// Keeps the district when it is one of the new state's choices; clears it otherwise. A
    /// one-district state selects its only choice.
    mutating func reconcileDistrict(with choices: [DistrictChoice]) {
        if choices.count == 1 {
            district = choices[0].value
        } else if let chosenDistrict, choices.contains(where: { $0.value == chosenDistrict }) {
            district = chosenDistrict
        } else {
            district = ""
        }
    }
}
