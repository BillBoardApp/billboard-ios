import Foundation

struct DistrictVerificationResolved: Codable, Equatable {
    let state: String
    let districtId: String
}

struct DistrictVerificationSignals: Codable, Equatable {
    let addressGeocoded: Bool
    let ipStateConsistency: String
    let ipStateObserved: String?
    let districtClaimMatch: Bool?
}

struct DistrictVerificationStatus: Codable, Equatable {
    let verified: Bool
    let status: String?
    /// `address_geocode`, `manual_state_district`, or `address_capped` (INT-03).
    let method: String?
    let verifiedAt: String?
    let resolved: DistrictVerificationResolved?
    let signals: DistrictVerificationSignals?
    let repsSignalEligible: Bool?
    let nextStep: String?
    /// `address_limit` while the account's address already has the most verified accounts
    /// allowed (method `address_capped`, `verified` false). Absent from older servers.
    var limitReason: String? = nil

    static let methodAddressGeocode = "address_geocode"
    static let methodManualStateDistrict = "manual_state_district"
    static let methodAddressCapped = "address_capped"
    static let limitReasonAddressLimit = "address_limit"

    /// The address geocoded, but its address and unit already have the most verified accounts
    /// allowed, so the district is saved as not verified (spec D 2.5.3).
    var isAddressCapped: Bool {
        method == Self.methodAddressCapped || limitReason == Self.limitReasonAddressLimit
    }

    static let empty = DistrictVerificationStatus(
        verified: false,
        status: nil,
        method: nil,
        verifiedAt: nil,
        resolved: nil,
        signals: nil,
        repsSignalEligible: nil,
        nextStep: nil,
        limitReason: nil
    )
}
