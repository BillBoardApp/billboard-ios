import Foundation
import SwiftUI

/// Centralized subscription definitions used across the app.
///
/// Nonisolated (constants and pure functions only), so manifest normalization, the disk-cache restore and
/// other work off the main actor can map topic names.
nonisolated struct SubscriptionsConfig {
    // Named category constants
    // Legacy short category constants (kept for compatibility)
    static let categoryEnergy = "Energy"
    static let categoryHealthcare = "Healthcare"
    static let categoryTechnology = "Technology"
    static let categoryInfrastructure = "Infrastructure"
    static let categoryEducation = "Education"
    static let categoryEnvironment = "Environment"
    static let categoryDefense = "Defense"
    static let categoryEconomy = "Economy"

    // Official full category names (authorized categories)
    static let categoryEconomicPolicy = "Economic Policy"
    static let categorySocialPolicy = "Social Policy"
    static let categoryEnvironmentalAndEnergyPolicy = "Environmental and Energy Policy"
    static let categoryForeignPolicyAndDefense = "Foreign Policy and Defense"
    static let categoryGovernanceAndInstitutionalPolicy = "Governance and Institutional Policy"
    static let categoryScienceTechnologyAndInfrastructure = "Science, Technology, and Infrastructure"
    static let categoryCulturalAndEthicalIssues = "Cultural and Ethical Issues"

    // Named life-area constants
    static let lifeUtilityBills = "Utility Bills"
    static let lifeHomeEnergy = "Home Energy"
    static let lifeStudentLoans = "Student Loans"
    static let lifeHealthInsurance = "Health Insurance"
    static let lifeTaxes = "Taxes"
    static let lifeMedicalCosts = "Medical Costs"
    static let lifeTransportation = "Transportation"
    static let lifeLocalDevelopment = "Local Development"
    static let lifeOnlinePrivacy = "Online Privacy"
    static let lifeDigitalSecurity = "Digital Security"
    static let lifeSocialMedia = "Social Media"
    static let lifeDigitalServices = "Digital Services"
    static let lifePetOwnership = "Pet Ownership"

    // Official sub-category constants (grouped by high-level category)
    // Economic Policy
    static let subFiscalPolicy = "Fiscal Policy"
    static let subMonetaryPolicy = "Monetary Policy"
    static let subLaborAndEmployment = "Labor and Employment"
    static let subTradeAndGlobalization = "Trade and Globalization"
    static let subSocialWelfare = "Social Welfare"

    static let subcategoriesEconomic: [String] = [
        subFiscalPolicy,
        subMonetaryPolicy,
        subLaborAndEmployment,
        subTradeAndGlobalization,
        subSocialWelfare
    ]

    // Social Policy
    static let subHealthcare = "Healthcare"
    static let subEducation = "Education"
    static let subHousing = "Housing"
    /// Was "Social Justice" until LLM-10 (`legacyTopicAliases`).
    static let subCivilRightsAndLiberties = "Civil Rights and Liberties"
    static let subFamilyAndGenderPolicy = "Family and Gender Policy"

    static let subcategoriesSocial: [String] = [
        subHealthcare,
        subEducation,
        subHousing,
        subCivilRightsAndLiberties,
        subFamilyAndGenderPolicy
    ]

    // Environmental and Energy Policy
    static let subClimateChange = "Climate Change"
    static let subEnergy = "Energy"
    static let subConservationAndNaturalResources = "Conservation and Natural Resources"
    static let subPollutionControl = "Pollution Control"

    static let subcategoriesEnvironment: [String] = [
        subClimateChange,
        subEnergy,
        subConservationAndNaturalResources,
        subPollutionControl
    ]

    // Foreign Policy and Defense
    static let subDiplomacy = "Diplomacy"
    static let subMilitaryAndDefense = "Military and Defense"
    static let subTradeAndSanctions = "Trade and Sanctions"
    static let subImmigrationAndBorderControl = "Immigration and Border Control"
    static let subHumanitarianIntervention = "Humanitarian Intervention"

    static let subcategoriesForeign: [String] = [
        subDiplomacy,
        subMilitaryAndDefense,
        subTradeAndSanctions,
        subImmigrationAndBorderControl,
        subHumanitarianIntervention
    ]

    // Governance and Institutional Policy
    static let subConstitutionalAndLegalIssues = "Constitutional and Legal Issues"
    static let subElectionsAndVoting = "Elections and Voting"
    static let subTransparencyAndAccountability = "Transparency and Accountability"
    static let subLocalVsFederalPower = "Local vs. Federal Power"

    static let subcategoriesGovernance: [String] = [
        subConstitutionalAndLegalIssues,
        subElectionsAndVoting,
        subTransparencyAndAccountability,
        subLocalVsFederalPower
    ]

    // Science, Technology, and Infrastructure
    static let subTechnologyRegulation = "Technology Regulation"
    static let subTransportation = "Transportation"
    static let subResearchAndInnovation = "Research and Innovation"
    static let subTelecommunications = "Telecommunications"

    static let subcategoriesScienceTech: [String] = [
        subTechnologyRegulation,
        subTransportation,
        subResearchAndInnovation,
        subTelecommunications
    ]

    // Cultural and Ethical Issues
    static let subReligionAndState = "Religion and State"
    /// Was "Identity Politics" until LLM-10 (`legacyTopicAliases`).
    static let subHeritageAndIdentity = "Heritage and Identity"
    static let subFreedomOfSpeechAndPress = "Freedom of Speech and Press"
    static let subEthicsInPolicy = "Ethics in Policy"

    static let subcategoriesCultural: [String] = [
        subReligionAndState,
        subHeritageAndIdentity,
        subFreedomOfSpeechAndPress,
        subEthicsInPolicy
    ]

    // Flattened list of all official sub-categories
    static let allSubcategories: [String] = subcategoriesEconomic
        + subcategoriesSocial
        + subcategoriesEnvironment
        + subcategoriesForeign
        + subcategoriesGovernance
        + subcategoriesScienceTech
        + subcategoriesCultural

    // Default categories users can subscribe to (includes all categories used in mock data)
    // Use the official authorized category names as defaults shown in the UI.
    static let defaultCategories: [String] = [
        categoryEconomicPolicy,
        categorySocialPolicy,
        categoryEnvironmentalAndEnergyPolicy,
        categoryForeignPolicyAndDefense,
        categoryScienceTechnologyAndInfrastructure,
        categoryGovernanceAndInstitutionalPolicy,
        categoryCulturalAndEthicalIssues
    ]

    // Default life areas (includes all life areas used in mock data)
    static let defaultLifeAreas: [String] = [
        lifeUtilityBills,
        lifeHomeEnergy,
        lifeStudentLoans,
        lifeHealthInsurance,
        lifeTaxes,
        lifeMedicalCosts,
        lifeTransportation,
        lifeLocalDevelopment,
        lifeOnlinePrivacy,
        lifeDigitalSecurity,
        lifeSocialMedia,
        lifeDigitalServices,
        lifePetOwnership
    ]

    // All available subscription categories (can be expanded)
    static let allCategories: [String] = defaultCategories

    // Mapping from high-level category name -> sub-category list
    // Map the official category names to their sub-categories.
    static let subcategoryGroups: [String: [String]] = [
        categoryEconomicPolicy: subcategoriesEconomic,
        categorySocialPolicy: subcategoriesSocial,
        categoryEnvironmentalAndEnergyPolicy: subcategoriesEnvironment,
        categoryForeignPolicyAndDefense: subcategoriesForeign,
        categoryGovernanceAndInstitutionalPolicy: subcategoriesGovernance,
        categoryScienceTechnologyAndInfrastructure: subcategoriesScienceTech,
        categoryCulturalAndEthicalIssues: subcategoriesCultural
    ]

    // All available life areas
    static let allLifeAreas: [String] = defaultLifeAreas

    // MARK: - Renamed topics (LLM-10)

    /// The topic names before LLM-10, kept only to read data written under them.
    static let legacyTopicSocialJustice = "Social Justice"
    static let legacyTopicIdentityPolitics = "Identity Politics"

    /// Legacy topic name -> current name. Mirrors `LEGACY_SUB_CATEGORY_ALIASES` in billboard-backend
    /// `services/src/models/categories.ts`: a processed bill, the manifest, a push, a stored follow or a cache
    /// written by an older build may still carry the old name.
    /// The app maps every topic it reads through `canonicalTopic(_:)`, so only current names are shown,
    /// matched and written. Both renames keep their topic group.
    static let legacyTopicAliases: [String: String] = [
        legacyTopicSocialJustice: subCivilRightsAndLiberties,
        legacyTopicIdentityPolitics: subHeritageAndIdentity
    ]

    /// `legacyTopicAliases` keyed by `topicLookupKey`, so a legacy name with other spacing or case still maps.
    private static let legacyTopicAliasesByLookupKey: [String: String] = Dictionary(
        uniqueKeysWithValues: legacyTopicAliases.map { (topicLookupKey($0.key), $0.value) }
    )

    private static func topicLookupKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The current name of a topic: a legacy name (`legacyTopicAliases`, compared trimmed and ignoring
    /// case) becomes its new name; any other value, including a topic group or an unknown label, is
    /// returned unchanged.
    static func canonicalTopic(_ name: String) -> String {
        if let renamed = legacyTopicAliases[name] { return renamed }
        // Fast path for the common case (the manifest maps tens of thousands of labels): a current name.
        if currentTopics.contains(name) { return name }
        return legacyTopicAliasesByLookupKey[topicLookupKey(name)] ?? name
    }

    private static let currentTopics: Set<String> = Set(allSubcategories)

    /// True when `name` is a legacy topic name (see `canonicalTopic(_:)`).
    static func isLegacyTopic(_ name: String) -> Bool {
        canonicalTopic(name) != name
    }

    /// `names` mapped through `canonicalTopic(_:)`, in order, each name once (the first occurrence wins),
    /// so a bill or a profile carrying both the old and the new name keeps one.
    static func canonicalTopics(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map(canonicalTopic)
            .filter { seen.insert($0).inserted }
    }
}
