import Amplify
import Foundation

struct UserProfileMapper {
    static func attribute(_ key: AuthUserAttributeKey, in attributes: [AuthUserAttribute]) -> String {
        return attributes.first(where: { $0.key == key })?.value ?? ""
    }

    static func baseProfile(userId: String, attributes: [AuthUserAttribute]) -> UserProfile {
        let customState = attribute(.custom("state"), in: attributes)
        let stateValue = customState

        let customDistrict = attribute(.custom("district"), in: attributes)
        let districtValue = customDistrict

        // Party, gender and birth date are left out (UX-36): the app no longer shows or keeps them.
        return UserProfile(
            id: userId,
            email: attribute(.email, in: attributes),
            district: districtValue,
            state: stateValue,
            avatarName: nil,
            subscribedSubCategories: [],
            subscribedLifeAreas: [],
            subscribedMemberIDs: [],
            watchedBillGUIDs: [],
            selectedBillContentTypes: []
        )
    }
}
