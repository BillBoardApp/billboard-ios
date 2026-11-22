/// The Home Screen icons a user can pick in App settings. White is the primary icon (`AppIcon.icon`, the masthead's
/// B in navy on paper); Navy is the alternate (`AppIcon-Navy.icon`, the same B in paper on navy), listed in the
/// target's `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. With dark Home Screen icons, both show the navy look.
nonisolated enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case white
    case navy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "White"
        case .navy: return "Navy"
        }
    }

    /// The name `UIApplication.setAlternateIconName(_:)` takes; nil is the primary icon.
    var alternateIconName: String? {
        switch self {
        case .white: return nil
        case .navy: return "AppIcon-Navy"
        }
    }

    /// The choice for the icon iOS shows now (`UIApplication.alternateIconName`). A name this build doesn't know
    /// reads as White, the primary icon.
    static func from(alternateIconName: String?) -> AppIconChoice {
        allCases.first { $0.alternateIconName == alternateIconName } ?? .white
    }
}
