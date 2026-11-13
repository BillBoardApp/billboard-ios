//
//  BillboardTheme.swift
//  Billboard
//
//  Colour tokens, type roles, radii and spacing, and the colour maths the palette tests use.
//

import SwiftUI
import UIKit

// MARK: - Colour token definition

/// One colour token: its sRGB value in light and dark appearance, and optionally a stronger value
/// for Increase Contrast. Tokens are defined in Swift (not an asset catalog) so the palette tests
/// resolve exactly the values the app draws, and the whole palette reads as one file.
nonisolated struct BillboardColorToken: Sendable, Equatable {
    /// An sRGB colour with alpha, components 0...1.
    nonisolated struct RGBA: Sendable, Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// `0xRRGGBB`, opaque unless `alpha` is given.
        static func hex(_ value: UInt32, alpha: Double = 1) -> RGBA {
            RGBA(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: alpha
            )
        }

        func withAlpha(_ alpha: Double) -> RGBA {
            RGBA(red: red, green: green, blue: blue, alpha: alpha)
        }

        static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
    }

    let light: RGBA
    let dark: RGBA
    let highContrastLight: RGBA?
    let highContrastDark: RGBA?

    init(light: RGBA, dark: RGBA, highContrastLight: RGBA? = nil, highContrastDark: RGBA? = nil) {
        self.light = light
        self.dark = dark
        self.highContrastLight = highContrastLight
        self.highContrastDark = highContrastDark
    }

    /// The same value in both appearances.
    init(_ both: RGBA) {
        self.init(light: both, dark: both)
    }

    /// The value drawn for an appearance. Increase Contrast falls back to the normal value where
    /// the token defines no high-contrast value.
    func resolved(dark isDark: Bool, highContrast: Bool = false) -> RGBA {
        if isDark {
            return highContrast ? (highContrastDark ?? dark) : dark
        }
        return highContrast ? (highContrastLight ?? light) : light
    }

    /// The value for one appearance as a `Color` that keeps it wherever it is drawn, rather than
    /// following the appearance of the view or bar it ends up in.
    func fixedColor(dark isDark: Bool, highContrast: Bool = false) -> Color {
        let rgba = resolved(dark: isDark, highContrast: highContrast)
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }

    /// A dynamic `UIColor` that follows the trait collection's appearance and contrast.
    var uiColor: UIColor {
        let token = self
        return UIColor { traits in
            let rgba = token.resolved(
                dark: traits.userInterfaceStyle == .dark,
                highContrast: traits.accessibilityContrast == .high
            )
            return UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
    }
}

// MARK: - Palette (Civic Record spec 2.1)

/// Every colour value in the app. `BillboardUIColors` and `BillboardColors` expose these as
/// dynamic `UIColor` and `Color`. Change a value here and `ThemePaletteTests` re-checks contrast
/// and colour-blind separation against the spec's computed contrast tables.
///
/// Civic Record keeps R2's Swift names where a role only changed its value: `background` is paper,
/// `cardBackground` is sheet, `secondaryBackground` is well, `separator` is rule, `primaryText` is
/// ink, `secondaryText` is ink 2 and `dimText` is ink 3. Teal means only Yea; links and buttons
/// are navy ink (`interactive`); brand teal is only the wordmark and the selected tab on navy.
nonisolated enum BillboardPalette {
    typealias Token = BillboardColorToken
    typealias RGBA = BillboardColorToken.RGBA

    private static let navyRGBA = RGBA.hex(0x0B1D3A)
    private static let white = RGBA.hex(0xFFFFFF)
    private static let inkLight = RGBA.hex(0x0E1A2E)
    private static let inkDark = RGBA.hex(0xEEF0F4)

    // Surfaces
    /// Paper: the ground of every tab root, list, sheet and form. Warm grey, never cream.
    static let background = Token(light: .hex(0xF3F2EE), dark: .hex(0x0B1220))
    /// Well: monogram fill, segmented track, disabled button fill, swipe reveal.
    static let secondaryBackground = Token(light: .hex(0xECEBE6), dark: .hex(0x1C2536))
    /// Sheet: bill slips, roll sheets, form groups, vote-button and stamp fills, fields.
    static let cardBackground = Token(light: .hex(0xFFFFFF), dark: .hex(0x151D2C))
    /// Document: the full-bleed ground of the bill page, member page and Weekly Brief detail.
    static let document = Token(light: .hex(0xFFFFFF), dark: .hex(0x0B1220))
    /// Plate: the ground of the vote map.
    static let plate = Token(light: .hex(0xF3F2EE), dark: .hex(0x131B2A))
    /// Masthead, tab glass tint, launch and startup failure: the same navy in both appearances.
    static let navy = Token(navyRGBA)

    // Rules (lines)
    /// Rule: hairlines, sheet edges, list separators (decorative).
    static let separator = Token(
        light: navyRGBA.withAlpha(0.13),
        dark: white.withAlpha(0.12),
        highContrastLight: navyRGBA.withAlpha(0.30),
        highContrastDark: white.withAlpha(0.30)
    )
    /// Dotted ledger rules, the perforation, tag borders, the monogram ring, sealed-sheet blanks.
    static let rule2 = Token(
        light: navyRGBA.withAlpha(0.30),
        dark: white.withAlpha(0.28),
        highContrastLight: navyRGBA.withAlpha(0.50),
        highContrastDark: white.withAlpha(0.45)
    )
    /// The one line that identifies a control (field and selectable-tag borders): at least 3:1.
    static let controlRule = Token(
        light: navyRGBA.withAlpha(0.50),
        dark: white.withAlpha(0.45),
        highContrastLight: inkLight,
        highContrastDark: inkDark
    )

    // Ink and text
    /// Ink: body text, titles, heavy rules, interactive text.
    static let primaryText = Token(light: inkLight, dark: inkDark)
    /// Ink 2: secondary text, column heads, tags.
    static let secondaryText = Token(light: .hex(0x3D4250), dark: .hex(0xC5CAD3))
    /// Ink 3: docket text, captions, placeholders, chevrons.
    static let dimText = Token(
        light: .hex(0x5C6270),
        dark: .hex(0x9AA2AF),
        highContrastLight: .hex(0x3D4250),
        highContrastDark: .hex(0xC5CAD3)
    )
    /// Links, text buttons, outlined buttons, spinners and the system tint: navy ink, never teal.
    static let interactive = Token(light: inkLight, dark: inkDark)
    /// 2 pt section rules, double rules and the tally header rule (= ink).
    static let ruleHeavy = Token(light: inkLight, dark: inkDark)
    static let textOnNavy = Token(white)
    /// Unselected tab labels, the dateline and secondary text on navy.
    static let textOnNavyDim = Token(
        light: white.withAlpha(0.74),
        dark: white.withAlpha(0.74),
        highContrastLight: white.withAlpha(0.85),
        highContrastDark: white.withAlpha(0.85)
    )
    static let onFill = Token(light: .hex(0xFFFFFF), dark: .hex(0x0B0F17))
    /// Toggle "on" track and progress fills: ink in light, slate in dark (a white knob on ink
    /// would vanish in dark mode).
    static let controlOn = Token(light: inkLight, dark: .hex(0x7C8AA3))

    // Brand
    /// The wordmark's "BOARD" and the selected tab, only ever on navy (and the app icon's check).
    static let brandTeal = Token(.hex(0x00BFA6))

    // Votes: always with the symbol and the word (VoteChoice)
    static let voteYea = Token(light: .hex(0x036C7E), dark: .hex(0x3CC3D6), highContrastLight: .hex(0x025564))
    static let voteNay = Token(light: .hex(0xA84A0A), dark: .hex(0xF2994A), highContrastLight: .hex(0x803908))
    static let voteAbstain = Token(
        light: .hex(0x646464),
        dark: .hex(0x8F8F8F),
        highContrastLight: .hex(0x444444),
        highContrastDark: .hex(0xB0B0B0)
    )

    // Parties: always with the letter (PartyBadge)
    static let partyDemocratic = Token(light: .hex(0x2456A6), dark: .hex(0x6E9EEB))
    static let partyRepublican = Token(light: .hex(0xB3261E), dark: .hex(0xF07167))
    static let partyIndependent = Token(light: .hex(0x646464), dark: .hex(0xA3A3A3))

    /// FAILED, errors and destructive actions, always with the word.
    static let danger = Token(
        light: .hex(0xB42318),
        dark: .hex(0xF97066),
        highContrastLight: .hex(0x971D14),
        highContrastDark: .hex(0xFB9A92)
    )

    // Bill status: each only its stamped word
    static let statusUpdated = Token(light: .hex(0x7D6200), dark: .hex(0xE8C547), highContrastLight: .hex(0x604B00))
    static let statusPassed = Token(light: .hex(0x18794E), dark: .hex(0x3DD68C), highContrastLight: .hex(0x125839))
    static let statusFailed = danger

    // Map
    /// The vote map's 50/50 colour, the middle of its ramp from `voteNay` to `voteYea`. It sits on the
    /// `plate` at 1.55:1 (light) and 2.32:1 (dark), so the full-strength state outlines carry the edges
    /// (`VoterMapStyling.outlineToken`, 3:1 or more against the plate and this neutral).
    static let mapNeutral = Token(light: .hex(0xBFC5CF), dark: .hex(0x4A5570))

    /// Every named token, in the order of spec 2.1's tables (surfaces, ink and text, brand, votes and
    /// parties, status, rules, map), for the palette tests. R2's retired names (`accentText`,
    /// `accentPrimary`, `statusNew`, `statusFinalized`, `warning`, the `subscription*`, `category*` and
    /// `chartAxis*` hues, `navyGradientEnd`, `shadow`) are gone.
    static let allTokens: [(name: String, token: Token)] = [
        // Surfaces
        ("background", background),
        ("cardBackground", cardBackground),
        ("document", document),
        ("secondaryBackground", secondaryBackground),
        ("plate", plate),
        ("navy", navy),
        // Ink and text
        ("primaryText", primaryText),
        ("secondaryText", secondaryText),
        ("dimText", dimText),
        ("interactive", interactive),
        ("textOnNavy", textOnNavy),
        ("textOnNavyDim", textOnNavyDim),
        ("onFill", onFill),
        ("controlOn", controlOn),
        // Brand
        ("brandTeal", brandTeal),
        // Votes and parties
        ("voteYea", voteYea),
        ("voteNay", voteNay),
        ("voteAbstain", voteAbstain),
        ("partyDemocratic", partyDemocratic),
        ("partyRepublican", partyRepublican),
        ("partyIndependent", partyIndependent),
        // Status and feedback
        ("statusUpdated", statusUpdated),
        ("statusPassed", statusPassed),
        ("statusFailed", statusFailed),
        ("danger", danger),
        // Rules
        ("separator", separator),
        ("rule2", rule2),
        ("controlRule", controlRule),
        ("ruleHeavy", ruleHeavy),
        // Map
        ("mapNeutral", mapNeutral)
    ]

    /// Tokens used for text on paper, sheet, document and well (each must reach 4.5:1 on all four).
    /// `brandTeal` is not one: it only ever sits on navy.
    static let textTokenNames: [String] = [
        "primaryText", "secondaryText", "dimText", "interactive",
        "voteYea", "voteNay", "voteAbstain",
        "partyDemocratic", "partyRepublican", "partyIndependent",
        "danger", "statusUpdated", "statusPassed", "statusFailed"
    ]

    /// The text tokens nearest 4.5:1, which Increase Contrast lifts to at least 7:1 (spec 2.1).
    static let highContrastTextTokenNames: [String] = [
        "voteYea", "voteNay", "voteAbstain", "statusUpdated", "statusPassed", "danger"
    ]

    /// Tokens drawn as solid fills behind `onFill` text (each must reach 4.5:1 with it).
    static let solidFillTokenNames: [String] = [
        "voteYea", "voteNay", "voteAbstain",
        "partyDemocratic", "partyRepublican", "partyIndependent",
        "danger", "primaryText"
    ]

    /// Text tokens allowed directly on clear (custom) glass: none. Every text-carrying custom glass
    /// view puts its text on an opaque `cardBackground` fill inside the glass (spec 1.1, 2.9).
    static let textTokensAllowedOnClearGlass: [String] = []

    /// The opaque fill under the text in a custom glass capsule or the vote panel.
    static let glassInnerFillTokenName = "cardBackground"

    /// The tab capsule's navy glass tint (spec 2.9, 3.22).
    static let tabGlassTintOpacity = 0.85

    static func token(named name: String) -> Token? {
        allTokens.first(where: { $0.name == name })?.token
    }
}

// MARK: - UIKit colours

/// Dynamic `UIColor` tokens, for UIKit appearance proxies and anything that needs a `UIColor`.
nonisolated enum BillboardUIColors {
    static let background = BillboardPalette.background.uiColor
    static let secondaryBackground = BillboardPalette.secondaryBackground.uiColor
    static let cardBackground = BillboardPalette.cardBackground.uiColor
    static let document = BillboardPalette.document.uiColor
    static let plate = BillboardPalette.plate.uiColor
    static let navy = BillboardPalette.navy.uiColor
    static let separator = BillboardPalette.separator.uiColor
    static let rule2 = BillboardPalette.rule2.uiColor
    static let controlRule = BillboardPalette.controlRule.uiColor
    static let ruleHeavy = BillboardPalette.ruleHeavy.uiColor

    static let primaryText = BillboardPalette.primaryText.uiColor
    static let secondaryText = BillboardPalette.secondaryText.uiColor
    static let dimText = BillboardPalette.dimText.uiColor
    static let interactive = BillboardPalette.interactive.uiColor
    static let textOnNavy = BillboardPalette.textOnNavy.uiColor
    static let textOnNavyDim = BillboardPalette.textOnNavyDim.uiColor
    static let onFill = BillboardPalette.onFill.uiColor
    static let controlOn = BillboardPalette.controlOn.uiColor
    static let brandTeal = BillboardPalette.brandTeal.uiColor

    static let voteYea = BillboardPalette.voteYea.uiColor
    static let voteNay = BillboardPalette.voteNay.uiColor
    static let voteAbstain = BillboardPalette.voteAbstain.uiColor

    static let partyDemocratic = BillboardPalette.partyDemocratic.uiColor
    static let partyRepublican = BillboardPalette.partyRepublican.uiColor
    static let partyIndependent = BillboardPalette.partyIndependent.uiColor

    static let danger = BillboardPalette.danger.uiColor

    static let statusUpdated = BillboardPalette.statusUpdated.uiColor
    static let statusPassed = BillboardPalette.statusPassed.uiColor
    static let statusFailed = BillboardPalette.statusFailed.uiColor

    static let mapNeutral = BillboardPalette.mapNeutral.uiColor
}

// MARK: - SwiftUI colours

/// SwiftUI colour tokens. Each follows light and dark appearance and Increase Contrast.
///
/// Rules (Civic Record spec 1.2): every hue has one meaning and always comes with a word, letter
/// or symbol. Vote colours come with their symbol and word (`VoteChoice`), party colours with
/// their letter (`PartyBadge`), status colours only as stamped words. Links, buttons, toggles and
/// spinners are ink (`interactive`, `controlOn`), never teal; `brandTeal` only sits on navy.
/// `textOnNavy` on navy; `onFill` on solid vote, party, danger and ink fills; `cardBackground`
/// instead of white surfaces; `primaryText` instead of black.
struct BillboardColors {
    // Surfaces
    /// Paper.
    static let background = Color(uiColor: BillboardUIColors.background)
    /// Well.
    static let secondaryBackground = Color(uiColor: BillboardUIColors.secondaryBackground)
    /// Sheet.
    static let cardBackground = Color(uiColor: BillboardUIColors.cardBackground)
    /// The bill page, member page and Weekly Brief detail ground.
    static let document = Color(uiColor: BillboardUIColors.document)
    /// The vote map's ground.
    static let plate = Color(uiColor: BillboardUIColors.plate)
    /// Masthead, tab glass tint and launch: the same navy in both appearances.
    static let navy = Color(uiColor: BillboardUIColors.navy)
    /// Rule: hairlines, sheet edges and list separators.
    static let separator = Color(uiColor: BillboardUIColors.separator)
    /// Dotted ledger rules, perforation, tag borders.
    static let rule2 = Color(uiColor: BillboardUIColors.rule2)
    /// Borders that identify a control (fields, selectable tags, Change): at least 3:1.
    static let controlRule = Color(uiColor: BillboardUIColors.controlRule)
    /// 2 pt section rules and double rules (ink).
    static let ruleHeavy = Color(uiColor: BillboardUIColors.ruleHeavy)

    // Text
    /// Ink.
    static let primaryText = Color(uiColor: BillboardUIColors.primaryText)
    /// Ink 2.
    static let secondaryText = Color(uiColor: BillboardUIColors.secondaryText)
    /// Ink 3.
    static let dimText = Color(uiColor: BillboardUIColors.dimText)
    /// Links, text buttons, outlined buttons, spinners and the system tint (navy ink).
    static let interactive = Color(uiColor: BillboardUIColors.interactive)
    /// Text and icons on navy surfaces.
    static let textOnNavy = Color(uiColor: BillboardUIColors.textOnNavy)
    /// Secondary text on navy: unselected tab labels, the dateline.
    static let textOnNavyDim = Color(uiColor: BillboardUIColors.textOnNavyDim)
    /// Text and icons on solid vote, party, danger and ink fills.
    static let onFill = Color(uiColor: BillboardUIColors.onFill)
    /// Toggle "on" track and progress fills.
    static let controlOn = Color(uiColor: BillboardUIColors.controlOn)
    /// The wordmark's "BOARD" and the selected tab. Only on navy.
    static let brandTeal = Color(uiColor: BillboardUIColors.brandTeal)

    // Votes
    static let voteYea = Color(uiColor: BillboardUIColors.voteYea)
    static let voteNay = Color(uiColor: BillboardUIColors.voteNay)
    static let voteAbstain = Color(uiColor: BillboardUIColors.voteAbstain)

    // Parties
    static let partyDemocratic = Color(uiColor: BillboardUIColors.partyDemocratic)
    static let partyRepublican = Color(uiColor: BillboardUIColors.partyRepublican)
    static let partyIndependent = Color(uiColor: BillboardUIColors.partyIndependent)

    /// Errors and destructive buttons.
    static let danger = Color(uiColor: BillboardUIColors.danger)

    // Status colours: each only with its stamped word (Became law is `statusPassed` with a double rule)
    static let statusUpdated = Color(uiColor: BillboardUIColors.statusUpdated)
    static let statusPassed = Color(uiColor: BillboardUIColors.statusPassed)
    static let statusFailed = Color(uiColor: BillboardUIColors.statusFailed)

    /// 50/50 in the vote map ramp.
    static let mapNeutral = Color(uiColor: BillboardUIColors.mapNeutral)
}

extension BillboardColors {
    /// The party colour. Always shown with the party letter (`PartyBadge`).
    static func party(_ party: PoliticalParty) -> Color {
        switch party {
        case .democratic: return partyDemocratic
        case .republican: return partyRepublican
        case .independent: return partyIndependent
        }
    }
}

// MARK: - Appearance setting (spec D 2.3.3)

/// The user's Appearance choice in App Settings, applied to the app's windows
/// (`userInterfaceStyle`; `BillBoardApp`). System is the default; Light is the rollback lever if a
/// dark screen ships broken.
nonisolated enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// `@AppStorage` key.
    static let storageKey = FirstRunStorage.appearanceKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The choice as a SwiftUI colour scheme; nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The same choice for UIKit windows; `.unspecified` follows the system.
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Type roles (Civic Record spec 2.5)

/// Every text style in Civic Record: its face, size and weight at the default text size (Large),
/// the system text style it scales with, its tracking, its case and its line spacing. Apply one
/// with `.textRole(_:)`, which scales from the SwiftUI environment's `dynamicTypeSize`, so a
/// render test that sets `.environment(\.dynamicTypeSize, .accessibility3)` scales the text for
/// real (R2's type tokens read the app's content size category, which a render test cannot set).
///
/// One face per job (spec 1.3): condensed SF Pro for headlines, New York for the four reading
/// roles only, SF Mono for the docket, SF Pro Text for everything else. No SF Pro Rounded.
enum TextRole: CaseIterable {
    /// Page titles on Updates, Congress, Profile.
    case display
    /// The bill page title and the member page name.
    case billTitle
    /// Screen titles before the tabs, Civic Rank and the Weekly Brief detail.
    case title
    /// Section titles everywhere and bill card titles.
    case heading
    /// Member names, sponsor, list-row titles, Weekly Brief item titles, tour step titles.
    case name
    /// "Why it matters".
    case lead
    /// The Weekly Brief summary sentence, nothing else.
    case leadStrong
    /// Breakdown answers, the Summary fallback, Weekly Brief item summaries, the member bio.
    case prose
    /// The official "To…" title (drawn in ink 2, upright at every size).
    case officialTitle
    /// UI text, captions that are sentences, list rows.
    case body
    /// Secondary row text, the sponsor name on cards.
    case subheadline
    /// Hints, footnotes.
    case caption
    /// Rare: under-icon labels outside the tab bar.
    case smallCaption
    /// Column heads (YEA, NAY, VOTES, MEMBER), the map sublabel.
    case label
    /// Index-tag text.
    case tagLabel
    /// All buttons and capsules.
    case button
    /// Bill numbers, chamber, dates, district codes, party letters in affiliation lines, ledger labels.
    case docket
    /// The Bills masthead dateline.
    case dateline
    /// Status stamps and every other stamp.
    case stamp
    /// Results percentages and counts, roll-call tallies.
    case figure
    /// Local results lines.
    case figureSmall
    /// Roll-sheet figures and Civic Rank figures.
    case figureLarge
    /// Inline titles on glass bars (fixed; the system Large Content Viewer shows it larger).
    case navTitle
    /// Tab labels (fixed; Large Content Viewer).
    case tabLabel
    /// Tab badges (fixed).
    case badge
    /// The ballot stamp's "YOU VOTED YEA".
    case stampLarge
    /// BILL/BOARD on the Bills masthead (fixed).
    case wordmark
    /// BILL/BOARD on the other tab roots and the screens before the tabs (fixed).
    case wordmarkCompact

    /// The face: condensed SF Pro, New York, SF Mono or SF Pro Text.
    enum Face {
        case condensed
        case serif
        case mono
        case text

        /// The face at a size and weight. Roles call it with their scaled size; components call it
        /// for text sized from a frame that already follows Dynamic Type (a monogram's initials, a
        /// party disc's letter, a tag's glyph), so no raw size is needed outside Theme/. `.serif` is
        /// for the four reading roles only (spec 1.3); components never ask for it. The UI rules check
        /// flags `Face.serif` and a literal size (`.font(size: 9, ...)`) outside Theme/.
        func font(size: CGFloat, weight: Font.Weight) -> Font {
            switch self {
            case .condensed:
                return Font.system(size: size, weight: weight, design: .default).width(.condensed)
            case .serif:
                return Font.system(size: size, weight: weight, design: .serif)
            case .mono:
                return Font.system(size: size, weight: weight, design: .monospaced)
            case .text:
                return Font.system(size: size, weight: weight, design: .default)
            }
        }
    }

    var face: Face {
        switch self {
        case .display, .billTitle, .title, .heading, .name, .navTitle, .wordmark, .wordmarkCompact:
            return .condensed
        case .lead, .leadStrong, .prose, .officialTitle:
            return .serif
        case .docket, .dateline, .stamp, .figure, .figureSmall, .figureLarge, .badge:
            return .mono
        case .body, .subheadline, .caption, .smallCaption, .label, .tagLabel, .button, .tabLabel, .stampLarge:
            return .text
        }
    }

    /// Size in points at the default text size (Large).
    var size: CGFloat {
        switch self {
        case .display: return 40
        case .billTitle: return 34
        case .title: return 30
        case .heading: return 22
        case .name: return 20
        case .lead: return 20
        case .leadStrong: return 21
        case .prose: return 17
        case .officialTitle: return 16
        case .body: return 16
        case .subheadline: return 15
        case .caption: return 13
        case .smallCaption: return 11
        case .label: return 11.5
        case .tagLabel: return 11
        case .button: return 16
        case .docket: return 11.5
        case .dateline: return 11
        case .stamp: return 11
        case .figure: return 15.5
        case .figureSmall: return 12.5
        case .figureLarge: return 24
        case .navTitle: return 18
        case .tabLabel: return 11
        case .badge: return 11
        case .stampLarge: return 13
        case .wordmark: return 30
        case .wordmarkCompact: return 26
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display: return .heavy
        case .billTitle, .title, .heading, .name, .navTitle, .badge, .stampLarge: return .bold
        case .leadStrong, .smallCaption, .label, .tagLabel, .button, .stamp, .tabLabel: return .semibold
        case .subheadline, .docket, .dateline, .figure, .figureSmall, .figureLarge: return .medium
        case .lead, .prose, .officialTitle, .body, .caption: return .regular
        case .wordmark, .wordmarkCompact: return .black
        }
    }

    /// The system text style whose Dynamic Type curve the role follows; nil for the fixed roles
    /// (bar titles, tab labels, badges and the wordmark), which keep their size and rely on the
    /// Large Content Viewer.
    var textStyle: UIFont.TextStyle? {
        switch self {
        case .display, .billTitle: return .largeTitle
        case .title: return .title1
        case .heading, .figureLarge: return .title2
        case .name, .lead, .leadStrong: return .title3
        case .prose: return .body
        case .officialTitle, .body, .button, .figure: return .callout
        case .subheadline: return .subheadline
        case .caption, .figureSmall, .stampLarge: return .footnote
        case .label, .docket: return .caption1
        case .smallCaption, .tagLabel, .dateline, .stamp: return .caption2
        case .navTitle, .tabLabel, .badge, .wordmark, .wordmarkCompact: return nil
        }
    }

    /// Letter spacing in em, multiplied by the scaled size so it scales with the text.
    var trackingEm: CGFloat {
        switch self {
        case .display, .billTitle: return -0.01
        case .title, .leadStrong: return -0.005
        case .lead: return -0.004
        case .label, .tagLabel, .stamp: return 0.08
        case .docket: return 0.06
        case .dateline: return 0.05
        case .tabLabel: return 0.01
        case .stampLarge: return 0.1
        case .wordmark, .wordmarkCompact: return 0.015
        default: return 0
        }
    }

    /// Roles drawn in capitals. Uppercase is a style, never typed into strings, so VoiceOver
    /// reads normal words (spec 1.7).
    var isUppercase: Bool {
        switch self {
        case .label, .tagLabel, .docket, .dateline, .stamp, .stampLarge, .wordmark, .wordmarkCompact: return true
        default: return false
        }
    }

    /// Extra line spacing at the default size, scaled with the text.
    var lineSpacing: CGFloat {
        switch self {
        case .lead: return 6
        case .prose: return 5
        case .leadStrong, .officialTitle: return 4
        default: return 0
        }
    }

    /// The point size at a Dynamic Type size, the way UIKit scales `textStyle`. SwiftUI has no system-font
    /// initializer that takes `relativeTo:`, and `Font.custom` cannot name the condensed system face, so
    /// sizes are scaled with `UIFontMetrics`.
    func scaledSize(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        guard let textStyle else { return size }
        let category = Self.contentSizeCategory(for: dynamicTypeSize)
        guard category != .large else { return size }
        return UIFontMetrics(forTextStyle: textStyle).scaledValue(
            for: size,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
    }

    /// The role's font at a given point size.
    func font(size: CGFloat) -> Font {
        face.font(size: size, weight: weight)
    }

    /// SwiftUI's Dynamic Type size as UIKit's content size category, for `UIFontMetrics`.
    static func contentSizeCategory(for dynamicTypeSize: DynamicTypeSize) -> UIContentSizeCategory {
        switch dynamicTypeSize {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// Applies a `TextRole`: font, tracking, case and line spacing, scaled from the environment's
/// Dynamic Type size.
struct TextRoleModifier: ViewModifier {
    let role: TextRole
    /// A size off the role's, as a multiple of it, on the role's own Dynamic Type curve: only for a
    /// size the spec gives one component (the sealed sheet's 12.5 pt stamp is the stamp role × 12.5/11).
    var scale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let scaledSize = role.scaledSize(for: dynamicTypeSize) * scale
        content
            .font(role.font(size: scaledSize))
            .tracking(role.trackingEm * scaledSize)
            .lineSpacing(role.lineSpacing * scaledSize / role.size)
            .textCase(role.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Sets the text in this view in a Civic Record type role (spec 2.5).
    func textRole(_ role: TextRole) -> some View {
        modifier(TextRoleModifier(role: role))
    }

    /// Sets the text in a type role at `scale` times the role's size, on the role's Dynamic Type curve.
    /// For a component the spec sizes off the role (the sealed sheet's stamp), or a word kept whole at AX5 with Bold
    /// Text (`TextRole.boldTextAX5Scale`); everything else uses a role.
    func textRole(_ role: TextRole, scale: CGFloat) -> some View {
        modifier(TextRoleModifier(role: role, scale: scale))
    }
}

extension TextRole {
    /// The scale for a word that must stay whole in a 375 pt phone's 335 pt column at AX5 (project decision of
    /// 2026-10-29: no mid-word breaks at AX5): 93% at AX5 with Bold Text, which makes such a word about 6% wider, and
    /// 1 everywhere else. Used by the reason tags (at full size "Constitutional" breaks as "Constitutiona / l", and a
    /// picked "Sponsor/Party" tag is about 352 pt; at 93% it is 332 pt) and Follow your representatives
    /// ("representatives" is 348 pt at full size, 324 pt at 93%).
    static func boldTextAX5Scale(at size: DynamicTypeSize, legibilityWeight: LegibilityWeight?) -> CGFloat {
        size >= .accessibility5 && legibilityWeight == .bold ? 0.93 : 1
    }
}

// MARK: - Colour maths

/// WCAG 2.x contrast, CIELAB (D65), CIEDE2000 and colour-vision-deficiency simulation
/// (Machado, Oliveira and Fernandes 2009, severity 1.0, applied in linear RGB). Used by the palette
/// tests (spec D 2.3.6) and available for colour ramps that interpolate in CIELAB (the vote map).
nonisolated enum BillboardColorMath {
    typealias RGB = (red: Double, green: Double, blue: Double)
    typealias Lab = (l: Double, a: Double, b: Double)

    nonisolated enum VisionDeficiency: String, CaseIterable, Sendable {
        case normal
        case protanopia
        case deuteranopia
        case tritanopia

        fileprivate var matrix: [[Double]]? {
            switch self {
            case .normal:
                return nil
            case .protanopia:
                return [
                    [0.152286, 1.052583, -0.204868],
                    [0.114503, 0.786281, 0.099216],
                    [-0.003882, -0.048116, 1.051998]
                ]
            case .deuteranopia:
                return [
                    [0.367322, 0.860646, -0.227968],
                    [0.280085, 0.672501, 0.047413],
                    [-0.011820, 0.042940, 0.968881]
                ]
            case .tritanopia:
                return [
                    [1.255528, -0.076749, -0.178779],
                    [-0.078411, 0.930809, 0.147602],
                    [0.004733, 0.691367, 0.303900]
                ]
            }
        }
    }

    static func linearize(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func delinearize(_ channel: Double) -> Double {
        let clamped = min(max(channel, 0), 1)
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }

    /// Blends `top` at `alpha` over the opaque `bottom` (sRGB, as the compositor does).
    static func composite(_ top: RGB, alpha: Double, over bottom: RGB) -> RGB {
        (
            red: top.red * alpha + bottom.red * (1 - alpha),
            green: top.green * alpha + bottom.green * (1 - alpha),
            blue: top.blue * alpha + bottom.blue * (1 - alpha)
        )
    }

    static func relativeLuminance(_ rgb: RGB) -> Double {
        0.2126 * linearize(rgb.red) + 0.7152 * linearize(rgb.green) + 0.0722 * linearize(rgb.blue)
    }

    /// WCAG 2.x contrast ratio, 1...21.
    static func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func simulate(_ rgb: RGB, _ deficiency: VisionDeficiency) -> RGB {
        guard let m = deficiency.matrix else { return rgb }
        let r = linearize(rgb.red)
        let g = linearize(rgb.green)
        let b = linearize(rgb.blue)
        return (
            red: delinearize(m[0][0] * r + m[0][1] * g + m[0][2] * b),
            green: delinearize(m[1][0] * r + m[1][1] * g + m[1][2] * b),
            blue: delinearize(m[2][0] * r + m[2][1] * g + m[2][2] * b)
        )
    }

    private static let whiteX = 0.95047
    private static let whiteY = 1.0
    private static let whiteZ = 1.08883

    static func lab(_ rgb: RGB) -> Lab {
        let r = linearize(rgb.red)
        let g = linearize(rgb.green)
        let b = linearize(rgb.blue)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
        }
        let fx = f(x / whiteX)
        let fy = f(y / whiteY)
        let fz = f(z / whiteZ)
        return (l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// CIELAB to sRGB, clamped into gamut.
    static func rgb(fromLab lab: Lab) -> RGB {
        let fy = (lab.l + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200
        func finv(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta ? t * t * t : 3 * delta * delta * (t - 4.0 / 29.0)
        }
        let x = whiteX * finv(fx)
        let y = whiteY * finv(fy)
        let z = whiteZ * finv(fz)
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return (red: delinearize(r), green: delinearize(g), blue: delinearize(b))
    }

    /// Interpolates between two colours in CIELAB; `fraction` 0 gives `from`, 1 gives `to`.
    static func interpolateLab(from: RGB, to: RGB, fraction: Double) -> RGB {
        let t = min(max(fraction, 0), 1)
        let a = lab(from)
        let b = lab(to)
        return rgb(fromLab: (
            l: a.l + (b.l - a.l) * t,
            a: a.a + (b.a - a.a) * t,
            b: a.b + (b.b - a.b) * t
        ))
    }

    /// CIEDE2000 colour difference (kL = kC = kH = 1).
    static func deltaE2000(_ lab1: Lab, _ lab2: Lab) -> Double {
        let rad = Double.pi / 180
        let c1 = (lab1.a * lab1.a + lab1.b * lab1.b).squareRoot()
        let c2 = (lab2.a * lab2.a + lab2.b * lab2.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * lab1.a
        let a2p = (1 + g) * lab2.a
        let c1p = (a1p * a1p + lab1.b * lab1.b).squareRoot()
        let c2p = (a2p * a2p + lab2.b * lab2.b).squareRoot()

        func hue(_ b: Double, _ ap: Double) -> Double {
            if b == 0 && ap == 0 { return 0 }
            let h = atan2(b, ap) / rad
            return h >= 0 ? h : h + 360
        }
        let h1p = hue(lab1.b, a1p)
        let h2p = hue(lab2.b, a2p)

        let dLp = lab2.l - lab1.l
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * rad / 2)

        let lBarP = (lab1.l + lab2.l) / 2
        let cBarP = (c1p + c2p) / 2
        var hBarP = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 {
                hBarP = (h1p + h2p) / 2
            } else if h1p + h2p < 360 {
                hBarP = (h1p + h2p + 360) / 2
            } else {
                hBarP = (h1p + h2p - 360) / 2
            }
        }

        let t1: Double = 0.17 * cos((hBarP - 30) * rad)
        let t2: Double = 0.24 * cos(2 * hBarP * rad)
        let t3: Double = 0.32 * cos((3 * hBarP + 6) * rad)
        let t4: Double = 0.20 * cos((4 * hBarP - 63) * rad)
        let t: Double = 1 - t1 + t2 + t3 - t4
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rC = 2 * (cBarP7 / (cBarP7 + pow(25, 7))).squareRoot()
        let lMinus50Squared = (lBarP - 50) * (lBarP - 50)
        let sL = 1 + 0.015 * lMinus50Squared / (20 + lMinus50Squared).squareRoot()
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rT = -sin(2 * dTheta * rad) * rC

        let lTerm = dLp / sL
        let cTerm = dCp / sC
        let hTerm = dHp / sH
        return (lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rT * cTerm * hTerm).squareRoot()
    }

    /// CIEDE2000 between two sRGB colours as seen with `deficiency`.
    static func deltaE2000(_ first: RGB, _ second: RGB, as deficiency: VisionDeficiency) -> Double {
        deltaE2000(lab(simulate(first, deficiency)), lab(simulate(second, deficiency)))
    }
}

extension BillboardColorToken.RGBA {
    /// The colour without alpha, for the colour maths.
    nonisolated var rgb: BillboardColorMath.RGB {
        (red: red, green: green, blue: blue)
    }
}

// MARK: - Billboard Styling
struct BillboardStyle {
    /// Civic Record's three radii and the capsule (spec 2.6), all continuous corners. Inner shapes
    /// are concentric with their container.
    enum Radius {
        /// Stamps, index tags, the ballot box, the swipe-reveal label chip.
        static let mark: CGFloat = 4
        /// Bill slips, roll sheets, form groups, text fields, the map plate, the error banner,
        /// the swipe reveal and the sealed sheet.
        static let slip: CGFloat = 16
        /// Glass panels (the vote panel). With 10 pt padding the inner shapes are 20.
        static let panel: CGFloat = 30
    }

    /// The 4 pt spacing grid (spec 2.8).
    enum Space {
        /// Stamp inner padding, bar gap.
        static let xxs: CGFloat = 2
        /// Icon to text in tags.
        static let xs: CGFloat = 4
        /// Row element gap, rule to title.
        static let s: CGFloat = 8
        /// Inside rows, between stacked lines.
        static let m: CGFloat = 12
        /// Slip padding; the list-screen gutter.
        static let l: CGFloat = 16
        /// The document gutter (bill page, member page, Weekly Brief detail).
        static let xl: CGFloat = 20
        /// Between document sections and tab-root sections.
        static let xxl: CGFloat = 28
        /// Page top under a page title.
        static let xxxl: CGFloat = 40
    }
}

// MARK: - View Extensions
extension View {
    /// The app's switch (spec 3.17): the system toggle with its "on" track in `controlOn`, ink in
    /// light and slate in dark. Never teal: teal means only Yea.
    func billboardToggle() -> some View {
        tint(BillboardColors.controlOn)
    }

    /// Paper under the whole screen, safe areas included.
    func billboardBackground() -> some View {
        self.background(
            ZStack {
                BillboardColors.background
            }
            .ignoresSafeArea()
        )
    }
}
