import Foundation

enum BillContentTypePreference: String, CaseIterable, Codable, Hashable, Sendable {
    case bills = "bills"
    case jointResolutions = "joint_resolutions"
    case otherResolutions = "other_resolutions"

    var title: String {
        switch self {
        case .bills:
            return "Bills"
        case .jointResolutions:
            return "Joint Resolutions"
        case .otherResolutions:
            return "Other Resolutions"
        }
    }

    var subtitle: String {
        switch self {
        case .bills:
            return "House and Senate bills"
        case .jointResolutions:
            return "House and Senate joint resolutions"
        case .otherResolutions:
            return "Concurrent and simple resolutions"
        }
    }

    var sortOrder: Int {
        switch self {
        case .bills:
            return 0
        case .jointResolutions:
            return 1
        case .otherResolutions:
            return 2
        }
    }

    nonisolated static func from(rawBillType: String?) -> BillContentTypePreference? {
        let normalized = rawBillType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "house-bill", "senate-bill", "hr", "s":
            return .bills
        case "house-joint-resolution", "senate-joint-resolution", "hjres", "sjres":
            return .jointResolutions
        case "house-concurrent-resolution", "senate-concurrent-resolution", "house-resolution", "senate-resolution",
            "hconres", "sconres", "hres", "sres":
            return .otherResolutions
        default:
            return nil
        }
    }

    nonisolated static func allows(rawBillType: String?, allowed: Set<BillContentTypePreference>) -> Bool {
        guard let preference = from(rawBillType: rawBillType) else {
            return true
        }
        return allowed.contains(preference)
    }
}

struct UserProfile: Codable, Equatable, Sendable {
    let id: String

    // Cognito attributes. Party, gender and birth year are not read any more (UX-36): the app stopped asking
    // for them, and a server job clears what earlier builds stored.
    let email: String
    let district: String

    // Derived / app fields
    let state: String
    let avatarName: String?

    // Preferences
    let subscribedSubCategories: [String]
    let subscribedLifeAreas: [String]
    let subscribedMemberIDs: [UUID]
    let watchedBillGUIDs: [String]
    let selectedBillContentTypes: [BillContentTypePreference]

    nonisolated var effectiveSelectedBillContentTypes: Set<BillContentTypePreference> {
        let explicit = Set(selectedBillContentTypes)
        return explicit.isEmpty ? Set(BillContentTypePreference.allCases) : explicit
    }

    var displayName: String {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return "Profile" }
        return trimmedEmail.split(separator: "@").first.map(String.init) ?? trimmedEmail
    }

    static func placeholder() -> UserProfile {
        UserProfile(
            id: "",
            email: "",
            district: "",
            state: "",
            avatarName: nil,
            subscribedSubCategories: [],
            subscribedLifeAreas: [],
            subscribedMemberIDs: [],
            watchedBillGUIDs: [],
            selectedBillContentTypes: []
        )
    }

    func updating(
        id: String? = nil,
        email: String? = nil,
        state: String? = nil,
        district: String? = nil,
        avatarName: String?? = nil,
        subscribedSubCategories: [String]? = nil,
        subscribedLifeAreas: [String]? = nil,
        subscribedMemberIDs: [UUID]? = nil,
        watchedBillGUIDs: [String]? = nil,
        selectedBillContentTypes: [BillContentTypePreference]? = nil
    ) -> UserProfile {
        UserProfile(
            id: id ?? self.id,
            email: email ?? self.email,
            district: district ?? self.district,
            state: state ?? self.state,
            avatarName: avatarName ?? self.avatarName,
            subscribedSubCategories: subscribedSubCategories ?? self.subscribedSubCategories,
            subscribedLifeAreas: subscribedLifeAreas ?? self.subscribedLifeAreas,
            subscribedMemberIDs: subscribedMemberIDs ?? self.subscribedMemberIDs,
            watchedBillGUIDs: watchedBillGUIDs ?? self.watchedBillGUIDs,
            selectedBillContentTypes: selectedBillContentTypes ?? self.selectedBillContentTypes
        )
    }
}
