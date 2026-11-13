import Foundation

enum PoliticalParty: String, Codable, CaseIterable, Identifiable {
    case democratic = "Democratic"
    case republican = "Republican"
    case independent = "Independent"

    var id: String { rawValue }

    /// "D", "R", "I": shown in `PartyBadge` and member labels such as "(D-VA)".
    var letter: String {
        switch self {
        case .democratic: return "D"
        case .republican: return "R"
        case .independent: return "I"
        }
    }

    /// "Democrat", "Republican", "Independent": the word for a member of the party, and the
    /// `PartyBadge` accessibility label.
    var displayName: String {
        switch self {
        case .democratic: return "Democrat"
        case .republican: return "Republican"
        case .independent: return "Independent"
        }
    }
}

extension PoliticalParty {
    static func from(raw: String?) -> PoliticalParty? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("dem") || lower == "d" { return .democratic }
        if lower.hasPrefix("rep") || lower == "r" || lower == "gop" { return .republican }
        if lower.hasPrefix("ind") || lower == "i" { return .independent }
        return nil
    }
}
