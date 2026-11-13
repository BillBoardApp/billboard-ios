import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// The Civic Record palette (spec 2.1) and its proof (spec 2.2, 2.3 and 10.2): every token resolves
/// to the spec's value in light, dark and Increase Contrast; text meets WCAG AA on every ground;
/// the numbers equal the ones in the spec's computed contrast tables; and the vote, party
/// and status colours stay apart for normal vision and under protanopia, deuteranopia and
/// tritanopia (Machado 2009, severity 1, CIEDE2000). The maths is `BillboardColorMath`, checked
/// here against published reference values.
@MainActor
final class ThemePaletteTests: XCTestCase {
    private typealias Math = BillboardColorMath
    private typealias RGB = BillboardColorMath.RGB
    private typealias RGBA = BillboardColorToken.RGBA
    private typealias Deficiency = BillboardColorMath.VisionDeficiency

    private enum Appearance: String, CaseIterable {
        case light
        case dark

        var isDark: Bool { self == .dark }
    }

    /// Paper, sheet, document and well: every ground text sits on.
    private static let grounds = ["background", "cardBackground", "document", "secondaryBackground"]

    /// The spec prints ratios to two decimals and colour differences to one.
    private static let ratioAccuracy = 0.0051
    private static let deltaEAccuracy = 0.051

    // MARK: - Fixed colours

    /// `fixedColor` keeps one appearance's value wherever it is drawn: the bill page's Watch and Share
    /// glyphs stay the page's ink while the bar around them is drawn in a navy root's dark appearance
    /// (a held swipe back).
    func testAFixedColourKeepsItsAppearanceInAnyEnvironment() {
        let ink = BillboardPalette.interactive
        for (isDark, highContrast) in [(false, false), (true, false), (false, true), (true, true)] {
            let expected = ink.resolved(dark: isDark, highContrast: highContrast)
            let fixed = ink.fixedColor(dark: isDark, highContrast: highContrast)
            for scheme in [ColorScheme.light, .dark] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                let drawn = fixed.resolve(in: environment)
                let name = "dark \(isDark), high contrast \(highContrast), drawn in \(scheme)"
                XCTAssertEqual(Double(drawn.red), expected.red, accuracy: 0.002, name)
                XCTAssertEqual(Double(drawn.green), expected.green, accuracy: 0.002, name)
                XCTAssertEqual(Double(drawn.blue), expected.blue, accuracy: 0.002, name)
            }
        }
    }

    /// The document pages' toolbar glyphs (the bill page's Watch and Share, the member page's Follow): ink
    /// fixed to the page's appearance, except with Reduce Transparency or Increase Contrast, where the group
    /// behind them turns dark during a held swipe back and the system's own colour (white there) is the
    /// readable one. `CongressRenderTests.testTheFollowButtonKeepsTheBarsSizeAndThePagesInk` checks that
    /// Follow draws it.
    func testTheDocumentPageToolbarGlyphsAreFixedInkUnlessTheGlassFallsBack() throws {
        let ink = BillboardPalette.interactive
        for isDark in [false, true] {
            let color = try XCTUnwrap(DocumentToolbarGlyph.color(dark: isDark, increaseContrast: false, reduceTransparency: false))
            var environment = EnvironmentValues()
            environment.colorScheme = isDark ? .light : .dark
            let drawn = color.resolve(in: environment)
            let expected = ink.resolved(dark: isDark)
            XCTAssertEqual(Double(drawn.red), expected.red, accuracy: 0.002)
            XCTAssertEqual(Double(drawn.green), expected.green, accuracy: 0.002)
            XCTAssertEqual(Double(drawn.blue), expected.blue, accuracy: 0.002)
            XCTAssertNil(DocumentToolbarGlyph.color(dark: isDark, increaseContrast: true, reduceTransparency: false))
            XCTAssertNil(DocumentToolbarGlyph.color(dark: isDark, increaseContrast: false, reduceTransparency: true))
        }
    }

    // MARK: - Helpers

    private func token(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> BillboardColorToken {
        guard let token = BillboardPalette.token(named: name) else {
            XCTFail("No palette token named \(name)", file: file, line: line)
            return BillboardColorToken(.clear)
        }
        return token
    }

    private func rgba(_ name: String, _ appearance: Appearance, highContrast: Bool = false) -> RGBA {
        token(name).resolved(dark: appearance.isDark, highContrast: highContrast)
    }

    private func rgb(_ name: String, _ appearance: Appearance, highContrast: Bool = false) -> RGB {
        rgba(name, appearance, highContrast: highContrast).rgb
    }

    /// `top` as the compositor draws it over the opaque `ground` (translucent rules and white 74%).
    private func drawn(_ top: RGBA, over ground: RGB) -> RGB {
        Math.composite(top.rgb, alpha: top.alpha, over: ground)
    }

    /// Contrast of token `first` drawn over token `second` (which must be opaque).
    private func contrast(_ first: String, _ second: String, _ appearance: Appearance, highContrast: Bool = false) -> Double {
        let ground = rgb(second, appearance, highContrast: highContrast)
        return Math.contrastRatio(drawn(rgba(first, appearance, highContrast: highContrast), over: ground), ground)
    }

    private func deltaE(
        _ first: String,
        _ second: String,
        _ appearance: Appearance,
        _ deficiency: Deficiency,
        highContrast: Bool = false
    ) -> Double {
        Math.deltaE2000(rgb(first, appearance, highContrast: highContrast), rgb(second, appearance, highContrast: highContrast), as: deficiency)
    }

    /// The smallest CIEDE2000 distance over every kind of vision.
    private func minDeltaE(_ first: String, _ second: String, _ appearance: Appearance, highContrast: Bool = false) -> Double {
        Deficiency.allCases.map { deltaE(first, second, appearance, $0, highContrast: highContrast) }.min() ?? 0
    }

    private func components(of color: UIColor, with traits: UITraitCollection) -> RGBA {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return RGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    private func traits(dark: Bool, highContrast: Bool) -> UITraitCollection {
        UITraitCollection(mutations: { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.accessibilityContrast = highContrast ? .high : .normal
        })
    }

    private func assertRGBAEqual(
        _ actual: RGBA,
        _ expected: RGBA,
        accuracy: Double = 1e-6,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.red, expected.red, accuracy: accuracy, "\(message) red", file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: accuracy, "\(message) green", file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: accuracy, "\(message) blue", file: file, line: line)
        XCTAssertEqual(actual.alpha, expected.alpha, accuracy: accuracy, "\(message) alpha", file: file, line: line)
    }

    // MARK: - Maths against reference values

    func testContrastRatioMatchesWCAGReferenceValues() {
        let white: RGB = (red: 1, green: 1, blue: 1)
        let black: RGB = (red: 0, green: 0, blue: 0)
        XCTAssertEqual(Math.contrastRatio(white, black), 21, accuracy: 1e-9)
        XCTAssertEqual(Math.contrastRatio(black, white), 21, accuracy: 1e-9)
        XCTAssertEqual(Math.contrastRatio(white, white), 1, accuracy: 1e-9)
        // #767676 on white is the well-known 4.54:1, the lightest grey that passes AA.
        XCTAssertEqual(Math.contrastRatio(RGBA.hex(0x767676).rgb, white), 4.54, accuracy: 0.005)
    }

    func testLabMatchesD65ReferenceValues() {
        let red = Math.lab((red: 1, green: 0, blue: 0))
        XCTAssertEqual(red.l, 53.24, accuracy: 0.01)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.01)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.01)

        let white = Math.lab((red: 1, green: 1, blue: 1))
        XCTAssertEqual(white.l, 100, accuracy: 0.001)
        XCTAssertEqual(white.a, 0, accuracy: 0.001)
        XCTAssertEqual(white.b, 0, accuracy: 0.001)
    }

    func testLabRoundTripsToSRGB() {
        for (name, token) in BillboardPalette.allTokens {
            for appearance in Appearance.allCases {
                let original = token.resolved(dark: appearance.isDark).rgb
                let back = Math.rgb(fromLab: Math.lab(original))
                XCTAssertEqual(back.red, original.red, accuracy: 1e-5, "\(name) \(appearance)")
                XCTAssertEqual(back.green, original.green, accuracy: 1e-5, "\(name) \(appearance)")
                XCTAssertEqual(back.blue, original.blue, accuracy: 1e-5, "\(name) \(appearance)")
            }
        }
    }

    /// Sharma, Wu and Dalal (2005), "The CIEDE2000 color-difference formula", test data pairs.
    func testDeltaE2000MatchesSharmaTestData() {
        let pairs: [(Math.Lab, Math.Lab, Double)] = [
            ((l: 50, a: 2.6772, b: -79.7751), (l: 50, a: 0, b: -82.7485), 2.0425),
            ((l: 50, a: 0, b: 0), (l: 50, a: -1, b: 2), 2.3669),
            ((l: 50, a: 2.49, b: -0.001), (l: 50, a: -2.49, b: 0.0009), 7.1792),
            ((l: 50, a: 2.5, b: 0), (l: 73, a: 25, b: -18), 27.1492),
            ((l: 60.2574, a: -34.0099, b: 36.2677), (l: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
            ((l: 90.8027, a: -2.0831, b: 1.441), (l: 91.1528, a: -1.6435, b: 0.0447), 1.4441)
        ]
        for (first, second, expected) in pairs {
            XCTAssertEqual(Math.deltaE2000(first, second), expected, accuracy: 0.0001)
            XCTAssertEqual(Math.deltaE2000(second, first), expected, accuracy: 0.0001, "symmetric")
        }
    }

    func testVisionSimulationKeepsNeutralGreyAndIdentityForNormalVision() {
        let grey: RGB = (red: 0.5, green: 0.5, blue: 0.5)
        for deficiency in Deficiency.allCases {
            let simulated = Math.simulate(grey, deficiency)
            XCTAssertEqual(simulated.red, 0.5, accuracy: 0.001, deficiency.rawValue)
            XCTAssertEqual(simulated.green, 0.5, accuracy: 0.001, deficiency.rawValue)
            XCTAssertEqual(simulated.blue, 0.5, accuracy: 0.001, deficiency.rawValue)
        }
        let teal = BillboardPalette.voteYea.light.rgb
        let normal = Math.simulate(teal, .normal)
        XCTAssertEqual(normal.red, teal.red)
        XCTAssertEqual(normal.green, teal.green)
        XCTAssertEqual(normal.blue, teal.blue)
    }

    func testLabInterpolationHitsBothEnds() {
        let nay = BillboardPalette.voteNay.light.rgb
        let yea = BillboardPalette.voteYea.light.rgb
        let start = Math.interpolateLab(from: nay, to: yea, fraction: 0)
        let end = Math.interpolateLab(from: nay, to: yea, fraction: 1)
        XCTAssertEqual(start.red, nay.red, accuracy: 1e-6)
        XCTAssertEqual(start.blue, nay.blue, accuracy: 1e-6)
        XCTAssertEqual(end.green, yea.green, accuracy: 1e-6)
        XCTAssertEqual(end.blue, yea.blue, accuracy: 1e-6)
        let clamped = Math.interpolateLab(from: nay, to: yea, fraction: 2)
        XCTAssertEqual(clamped.green, yea.green, accuracy: 1e-6)
    }

    // MARK: - Tokens equal the spec table (2.1)

    private struct SpecToken {
        let name: String
        let light: RGBA
        let dark: RGBA
        var highContrastLight: RGBA?
        var highContrastDark: RGBA?
    }

    private static let navy = RGBA.hex(0x0B1D3A)
    private static let white = RGBA.hex(0xFFFFFF)

    /// Spec 2.1, every token in the order of its tables: name, light, dark and the Increase Contrast
    /// values ("–" is nil). `statusFailed` is `danger` (2.1 "Status and feedback").
    private static let specTable: [SpecToken] = [
        // Surfaces
        SpecToken(name: "background", light: .hex(0xF3F2EE), dark: .hex(0x0B1220)),
        SpecToken(name: "cardBackground", light: .hex(0xFFFFFF), dark: .hex(0x151D2C)),
        SpecToken(name: "document", light: .hex(0xFFFFFF), dark: .hex(0x0B1220)),
        SpecToken(name: "secondaryBackground", light: .hex(0xECEBE6), dark: .hex(0x1C2536)),
        SpecToken(name: "plate", light: .hex(0xF3F2EE), dark: .hex(0x131B2A)),
        SpecToken(name: "navy", light: .hex(0x0B1D3A), dark: .hex(0x0B1D3A)),
        // Ink and text
        SpecToken(name: "primaryText", light: .hex(0x0E1A2E), dark: .hex(0xEEF0F4)),
        SpecToken(name: "secondaryText", light: .hex(0x3D4250), dark: .hex(0xC5CAD3)),
        SpecToken(name: "dimText", light: .hex(0x5C6270), dark: .hex(0x9AA2AF), highContrastLight: .hex(0x3D4250), highContrastDark: .hex(0xC5CAD3)),
        SpecToken(name: "interactive", light: .hex(0x0E1A2E), dark: .hex(0xEEF0F4)),
        SpecToken(name: "textOnNavy", light: .hex(0xFFFFFF), dark: .hex(0xFFFFFF)),
        SpecToken(
            name: "textOnNavyDim",
            light: white.withAlpha(0.74),
            dark: white.withAlpha(0.74),
            highContrastLight: white.withAlpha(0.85),
            highContrastDark: white.withAlpha(0.85)
        ),
        SpecToken(name: "onFill", light: .hex(0xFFFFFF), dark: .hex(0x0B0F17)),
        SpecToken(name: "controlOn", light: .hex(0x0E1A2E), dark: .hex(0x7C8AA3)),
        // Brand
        SpecToken(name: "brandTeal", light: .hex(0x00BFA6), dark: .hex(0x00BFA6)),
        // Votes and parties
        SpecToken(name: "voteYea", light: .hex(0x036C7E), dark: .hex(0x3CC3D6), highContrastLight: .hex(0x025564)),
        SpecToken(name: "voteNay", light: .hex(0xA84A0A), dark: .hex(0xF2994A), highContrastLight: .hex(0x803908)),
        SpecToken(name: "voteAbstain", light: .hex(0x646464), dark: .hex(0x8F8F8F), highContrastLight: .hex(0x444444), highContrastDark: .hex(0xB0B0B0)),
        SpecToken(name: "partyDemocratic", light: .hex(0x2456A6), dark: .hex(0x6E9EEB)),
        SpecToken(name: "partyRepublican", light: .hex(0xB3261E), dark: .hex(0xF07167)),
        SpecToken(name: "partyIndependent", light: .hex(0x646464), dark: .hex(0xA3A3A3)),
        // Status and feedback
        SpecToken(name: "statusUpdated", light: .hex(0x7D6200), dark: .hex(0xE8C547), highContrastLight: .hex(0x604B00)),
        SpecToken(name: "statusPassed", light: .hex(0x18794E), dark: .hex(0x3DD68C), highContrastLight: .hex(0x125839)),
        SpecToken(name: "statusFailed", light: .hex(0xB42318), dark: .hex(0xF97066), highContrastLight: .hex(0x971D14), highContrastDark: .hex(0xFB9A92)),
        SpecToken(name: "danger", light: .hex(0xB42318), dark: .hex(0xF97066), highContrastLight: .hex(0x971D14), highContrastDark: .hex(0xFB9A92)),
        // Rules
        SpecToken(
            name: "separator",
            light: navy.withAlpha(0.13),
            dark: white.withAlpha(0.12),
            highContrastLight: navy.withAlpha(0.30),
            highContrastDark: white.withAlpha(0.30)
        ),
        SpecToken(
            name: "rule2",
            light: navy.withAlpha(0.30),
            dark: white.withAlpha(0.28),
            highContrastLight: navy.withAlpha(0.50),
            highContrastDark: white.withAlpha(0.45)
        ),
        SpecToken(
            name: "controlRule",
            light: navy.withAlpha(0.50),
            dark: white.withAlpha(0.45),
            highContrastLight: .hex(0x0E1A2E),
            highContrastDark: .hex(0xEEF0F4)
        ),
        SpecToken(name: "ruleHeavy", light: .hex(0x0E1A2E), dark: .hex(0xEEF0F4)),
        // Map
        SpecToken(name: "mapNeutral", light: .hex(0xBFC5CF), dark: .hex(0x4A5570))
    ]

    /// The palette is spec 2.1's table exactly: the same names in the same order, and nothing else.
    func testTheTokensAreExactlyTheSpecTable() {
        XCTAssertEqual(BillboardPalette.allTokens.map(\.name), Self.specTable.map(\.name))
    }

    func testTokensMatchSpecTable() {
        for spec in Self.specTable {
            let actual = token(spec.name)
            assertRGBAEqual(actual.light, spec.light, "\(spec.name) light")
            assertRGBAEqual(actual.dark, spec.dark, "\(spec.name) dark")
            assertRGBAEqual(actual.resolved(dark: false, highContrast: true), spec.highContrastLight ?? spec.light, "\(spec.name) HC light")
            assertRGBAEqual(actual.resolved(dark: true, highContrast: true), spec.highContrastDark ?? spec.dark, "\(spec.name) HC dark")
            XCTAssertEqual(actual.highContrastLight == nil, spec.highContrastLight == nil, "\(spec.name) HC light is defined only where 2.1 gives one")
            XCTAssertEqual(actual.highContrastDark == nil, spec.highContrastDark == nil, "\(spec.name) HC dark is defined only where 2.1 gives one")
        }
    }

    /// Spec 2.1 "Retired tokens" and 10.2: R2's names are deleted (slice 14), not kept as aliases.
    private static let retiredNames = [
        "accentText", "accentPrimary", "statusNew", "statusFinalized", "warning",
        "subscriptionCategory", "subscriptionMember", "subscriptionLifeArea",
        "categoryEconomicPolicy", "categorySocialPolicy", "categoryEnvironmentalAndEnergyPolicy",
        "categoryForeignPolicyAndDefense", "categoryGovernanceAndInstitutionalPolicy",
        "categoryScienceTechnologyAndInfrastructure", "categoryCulturalAndEthicalIssues",
        "chartAxis1", "chartAxis2", "chartAxis3", "chartAxis4", "chartAxis5", "chartAxis6",
        "navyGradientEnd", "shadow"
    ]

    func testTheRetiredTokensAreGone() {
        let names = Set(BillboardPalette.allTokens.map(\.name))
        for retired in Self.retiredNames {
            XCTAssertFalse(names.contains(retired), retired)
            XCTAssertNil(BillboardPalette.token(named: retired), retired)
        }
        // Teal means only Yea: no token but brand teal draws R2's teal accent text.
        for (name, token) in BillboardPalette.allTokens where name != "brandTeal" {
            for appearance in Appearance.allCases {
                let value = token.resolved(dark: appearance.isDark)
                XCTAssertNotEqual(value, RGBA.hex(0x00796A), "\(name) \(appearance) is R2's accentText teal")
                XCTAssertNotEqual(value, RGBA.hex(0x2FD3BC), "\(name) \(appearance) is R2's accentText teal")
            }
        }
    }

    func testTokenNamesAreUniqueAndListsReferToRealTokens() {
        let names = BillboardPalette.allTokens.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        let lists = BillboardPalette.textTokenNames + BillboardPalette.highContrastTextTokenNames
            + BillboardPalette.solidFillTokenNames + [BillboardPalette.glassInnerFillTokenName]
        for name in lists {
            XCTAssertNotNil(BillboardPalette.token(named: name), name)
        }
        XCTAssertFalse(BillboardPalette.textTokenNames.contains("brandTeal"), "brand teal is never text on paper")
    }

    // MARK: - Dynamic colours resolve to the tokens

    func testDynamicUIColorsResolveToTokenValuesForEveryAppearanceAndContrast() {
        for (name, token) in BillboardPalette.allTokens {
            for dark in [false, true] {
                for highContrast in [false, true] {
                    let resolved = components(of: token.uiColor, with: traits(dark: dark, highContrast: highContrast))
                    assertRGBAEqual(
                        resolved,
                        token.resolved(dark: dark, highContrast: highContrast),
                        "\(name) dark=\(dark) highContrast=\(highContrast)"
                    )
                }
            }
        }
    }

    func testUIColorTokensAreThePaletteTokens() {
        let pairs: [(String, UIColor)] = [
            ("background", BillboardUIColors.background),
            ("secondaryBackground", BillboardUIColors.secondaryBackground),
            ("cardBackground", BillboardUIColors.cardBackground),
            ("document", BillboardUIColors.document),
            ("plate", BillboardUIColors.plate),
            ("navy", BillboardUIColors.navy),
            ("separator", BillboardUIColors.separator),
            ("rule2", BillboardUIColors.rule2),
            ("controlRule", BillboardUIColors.controlRule),
            ("ruleHeavy", BillboardUIColors.ruleHeavy),
            ("primaryText", BillboardUIColors.primaryText),
            ("secondaryText", BillboardUIColors.secondaryText),
            ("dimText", BillboardUIColors.dimText),
            ("interactive", BillboardUIColors.interactive),
            ("textOnNavy", BillboardUIColors.textOnNavy),
            ("textOnNavyDim", BillboardUIColors.textOnNavyDim),
            ("onFill", BillboardUIColors.onFill),
            ("controlOn", BillboardUIColors.controlOn),
            ("brandTeal", BillboardUIColors.brandTeal),
            ("voteYea", BillboardUIColors.voteYea),
            ("voteNay", BillboardUIColors.voteNay),
            ("voteAbstain", BillboardUIColors.voteAbstain),
            ("partyDemocratic", BillboardUIColors.partyDemocratic),
            ("partyRepublican", BillboardUIColors.partyRepublican),
            ("partyIndependent", BillboardUIColors.partyIndependent),
            ("danger", BillboardUIColors.danger),
            ("statusUpdated", BillboardUIColors.statusUpdated),
            ("statusPassed", BillboardUIColors.statusPassed),
            ("statusFailed", BillboardUIColors.statusFailed),
            ("mapNeutral", BillboardUIColors.mapNeutral)
        ]
        for (name, color) in pairs {
            for dark in [false, true] {
                for highContrast in [false, true] {
                    assertRGBAEqual(
                        components(of: color, with: traits(dark: dark, highContrast: highContrast)),
                        token(name).resolved(dark: dark, highContrast: highContrast),
                        "\(name) dark=\(dark) highContrast=\(highContrast)"
                    )
                }
            }
        }
    }

    /// SwiftUI resolves the token colours from the environment's colour scheme, so a view in dark
    /// mode draws the dark values without any forced appearance.
    func testSwiftUIColorsFollowTheEnvironmentColorScheme() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cases: [(String, Color)] = [
            ("background", BillboardColors.background),
            ("cardBackground", BillboardColors.cardBackground),
            ("document", BillboardColors.document),
            ("voteYea", BillboardColors.voteYea),
            ("voteNay", BillboardColors.voteNay),
            ("primaryText", BillboardColors.primaryText),
            ("interactive", BillboardColors.interactive),
            ("controlOn", BillboardColors.controlOn)
        ]
        for (name, color) in cases {
            for scheme in [ColorScheme.light, .dark] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                let cgColor = color.resolve(in: environment).cgColor
                let converted = try XCTUnwrap(cgColor.converted(to: srgb, intent: .defaultIntent, options: nil))
                let parts = try XCTUnwrap(converted.components)
                let expected = token(name).resolved(dark: scheme == .dark)
                XCTAssertEqual(Double(parts[0]), expected.red, accuracy: 0.01, "\(name) \(scheme)")
                XCTAssertEqual(Double(parts[1]), expected.green, accuracy: 0.01, "\(name) \(scheme)")
                XCTAssertEqual(Double(parts[2]), expected.blue, accuracy: 0.01, "\(name) \(scheme)")
            }
        }
    }

    // MARK: - T1: text on every ground

    func testT1EveryTextTokenMeetsAAOnEveryGround() {
        for appearance in Appearance.allCases {
            for text in BillboardPalette.textTokenNames {
                for ground in Self.grounds {
                    let ratio = contrast(text, ground, appearance)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text) on \(ground), \(appearance): \(ratio)")
                }
            }
        }
    }

    /// Under Increase Contrast every text token keeps AA and never loses contrast, and the six
    /// nearest 4.5:1 reach 7:1 on paper, sheet, document and well. The one exception is the spec's:
    /// dark Nay keeps its value, 6.90:1 on the dark well (2.1).
    func testT1HighContrastReachesSevenToOneForTheSmallestMarks() {
        for appearance in Appearance.allCases {
            for text in BillboardPalette.textTokenNames {
                for ground in Self.grounds {
                    let normal = contrast(text, ground, appearance)
                    let high = contrast(text, ground, appearance, highContrast: true)
                    XCTAssertGreaterThanOrEqual(high, 4.5, "\(text) on \(ground), \(appearance), high contrast")
                    XCTAssertGreaterThanOrEqual(high + 1e-9, normal, "\(text) on \(ground), \(appearance)")
                }
            }
            for text in BillboardPalette.highContrastTextTokenNames {
                for ground in Self.grounds {
                    let high = contrast(text, ground, appearance, highContrast: true)
                    if appearance == .dark, text == "voteNay", ground == "secondaryBackground" {
                        XCTAssertEqual(high, 6.90, accuracy: Self.ratioAccuracy, "the recorded exception")
                        continue
                    }
                    XCTAssertGreaterThanOrEqual(high, 7, "\(text) on \(ground), \(appearance), high contrast: \(high)")
                }
            }
        }
        // dimText is the token Increase Contrast strengthens most.
        XCTAssertEqual(contrast("dimText", "background", .light, highContrast: true), 8.95, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(contrast("dimText", "background", .dark, highContrast: true), 11.38, accuracy: Self.ratioAccuracy)
    }

    /// The contrast columns of spec 2.1: light against paper / sheet / well, dark against night
    /// paper / sheet / well, and `onFill` on the colour as a solid fill (light / dark).
    func testContrastColumnsMatchSpecTable() {
        let grounds = ["background", "cardBackground", "secondaryBackground"]
        let table: [(String, light: [Double], dark: [Double])] = [
            ("primaryText", [15.55, 17.41, 14.59], [16.41, 14.80, 13.46]),
            ("interactive", [15.55, 17.41, 14.59], [16.41, 14.80, 13.46]),
            ("secondaryText", [8.95, 10.03, 8.40], [11.38, 10.26, 9.33]),
            ("dimText", [5.46, 6.11, 5.12], [7.28, 6.56, 5.97]),
            ("voteYea", [5.43, 6.09, 5.10], [8.89, 8.01, 7.29]),
            ("voteNay", [5.14, 5.76, 4.82], [8.41, 7.58, 6.90]),
            ("voteAbstain", [5.28, 5.92, 4.96], [5.79, 5.22, 4.75]),
            ("partyDemocratic", [6.34, 7.10, 5.95], [6.91, 6.23, 5.67]),
            ("partyRepublican", [5.84, 6.54, 5.48], [6.48, 5.84, 5.31]),
            ("partyIndependent", [5.28, 5.92, 4.96], [7.42, 6.69, 6.09]),
            ("statusUpdated", [5.18, 5.80, 4.86], [11.15, 10.06, 9.15]),
            ("statusPassed", [4.83, 5.41, 4.53], [9.98, 9.00, 8.19]),
            ("danger", [5.87, 6.57, 5.51], [6.72, 6.06, 5.51])
        ]
        for (name, light, dark) in table {
            for (index, ground) in grounds.enumerated() {
                XCTAssertEqual(contrast(name, ground, .light), light[index], accuracy: Self.ratioAccuracy, "\(name) on \(ground), light")
                XCTAssertEqual(contrast(name, ground, .dark), dark[index], accuracy: Self.ratioAccuracy, "\(name) on \(ground), dark")
            }
        }
        let onFill: [(String, light: Double, dark: Double)] = [
            ("voteYea", 6.09, 9.10), ("voteNay", 5.76, 8.61), ("voteAbstain", 5.92, 5.93),
            ("partyDemocratic", 7.10, 7.08), ("partyRepublican", 6.54, 6.63), ("partyIndependent", 5.92, 7.60),
            // 2.2: the primary button is `onFill` on an ink capsule.
            ("primaryText", 17.41, 16.81)
        ]
        for (fill, light, dark) in onFill {
            XCTAssertEqual(contrast("onFill", fill, .light), light, accuracy: Self.ratioAccuracy, "onFill on \(fill), light")
            XCTAssertEqual(contrast("onFill", fill, .dark), dark, accuracy: Self.ratioAccuracy, "onFill on \(fill), dark")
        }
        // Do not put statusPassed text on the light well: 4.53:1 is too close to the limit (2.1).
        XCTAssertLessThan(contrast("statusPassed", "secondaryBackground", .light), 4.6)
        // Sheet on paper has no visible edge without its 1 pt rule (decorative).
        XCTAssertEqual(contrast("cardBackground", "background", .light), 1.12, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(contrast("cardBackground", "background", .dark), 1.11, accuracy: Self.ratioAccuracy)
    }

    /// Spec 2.1, "Increase Contrast values": on paper / sheet / well / document, and `onFill` on it.
    func testHighContrastValuesMatchSpecTable() {
        let grounds = ["background", "cardBackground", "secondaryBackground", "document"]
        let table: [(String, Appearance, [Double], onFill: Double)] = [
            ("voteYea", .light, [7.54, 8.45, 7.08, 8.45], 8.45),
            ("voteNay", .light, [7.48, 8.38, 7.02, 8.38], 8.38),
            ("voteAbstain", .light, [8.69, 9.74, 8.16, 9.74], 9.74),
            ("statusUpdated", .light, [7.49, 8.39, 7.03, 8.39], 8.39),
            ("statusPassed", .light, [7.56, 8.47, 7.09, 8.47], 8.47),
            ("danger", .light, [7.49, 8.39, 7.03, 8.39], 8.39),
            ("voteAbstain", .dark, [8.63, 7.78, 7.08, 8.63], 8.84),
            ("danger", .dark, [9.04, 8.15, 7.42, 9.04], 9.26)
        ]
        for (name, appearance, values, onFill) in table {
            for (index, ground) in grounds.enumerated() {
                XCTAssertEqual(
                    contrast(name, ground, appearance, highContrast: true),
                    values[index],
                    accuracy: Self.ratioAccuracy,
                    "\(name) HC on \(ground), \(appearance)"
                )
            }
            XCTAssertEqual(contrast("onFill", name, appearance, highContrast: true), onFill, accuracy: Self.ratioAccuracy, "onFill on \(name) HC, \(appearance)")
        }
    }

    // MARK: - Rules (2.1)

    func testRulesMatchSpecTableAndControlRuleReachesThreeToOne() {
        let onPaper: [(String, light: Double, dark: Double, hcLight: Double, hcDark: Double)] = [
            ("separator", 1.30, 1.38, 1.90, 2.67),
            ("rule2", 1.90, 2.48, 3.22, 4.51),
            ("controlRule", 3.22, 4.51, 15.55, 16.41),
            ("ruleHeavy", 15.55, 16.41, 15.55, 16.41)
        ]
        for (name, light, dark, hcLight, hcDark) in onPaper {
            XCTAssertEqual(contrast(name, "background", .light), light, accuracy: Self.ratioAccuracy, "\(name) light")
            XCTAssertEqual(contrast(name, "background", .dark), dark, accuracy: Self.ratioAccuracy, "\(name) dark")
            XCTAssertEqual(contrast(name, "background", .light, highContrast: true), hcLight, accuracy: Self.ratioAccuracy, "\(name) HC light")
            XCTAssertEqual(contrast(name, "background", .dark, highContrast: true), hcDark, accuracy: Self.ratioAccuracy, "\(name) HC dark")
        }
        // T6: controlRule identifies a control, so it reaches 3:1 on every ground a control sits on.
        let controlRuleOn: [(String, light: Double, dark: Double)] = [
            ("background", 3.22, 4.51), ("cardBackground", 3.31, 4.42), ("document", 3.31, 4.51)
        ]
        for (ground, light, dark) in controlRuleOn {
            for highContrast in [false, true] {
                for appearance in Appearance.allCases {
                    XCTAssertGreaterThanOrEqual(contrast("controlRule", ground, appearance, highContrast: highContrast), 3, "controlRule on \(ground), \(appearance)")
                }
            }
            XCTAssertEqual(contrast("controlRule", ground, .light), light, accuracy: Self.ratioAccuracy, "controlRule on \(ground), light")
            XCTAssertEqual(contrast("controlRule", ground, .dark), dark, accuracy: Self.ratioAccuracy, "controlRule on \(ground), dark")
        }
    }

    // MARK: - T5: onFill on solid fills

    func testT5OnFillMeetsAAOnEverySolidFill() {
        for appearance in Appearance.allCases {
            for highContrast in [false, true] {
                for fill in BillboardPalette.solidFillTokenNames {
                    let ratio = contrast("onFill", fill, appearance, highContrast: highContrast)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "onFill on \(fill), \(appearance), HC \(highContrast): \(ratio)")
                }
            }
        }
    }

    // MARK: - T6: controlOn

    /// The toggle's "on" track: ink in light, slate in dark, against the white knob and the grounds
    /// it sits on (2.1, 2.2).
    func testT6ControlOnReachesThreeToOneAgainstTheKnobAndItsGrounds() {
        let knob = RGBA.hex(0xFFFFFF).rgb
        for appearance in Appearance.allCases {
            XCTAssertGreaterThanOrEqual(Math.contrastRatio(rgb("controlOn", appearance), knob), 3, "\(appearance) knob")
            XCTAssertGreaterThanOrEqual(contrast("controlOn", "cardBackground", appearance), 3, "\(appearance) sheet")
            XCTAssertGreaterThanOrEqual(contrast("controlOn", "background", appearance), 3, "\(appearance) paper")
        }
        XCTAssertEqual(Math.contrastRatio(rgb("controlOn", .light), knob), 17.41, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(contrast("controlOn", "cardBackground", .light), 17.41, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(Math.contrastRatio(rgb("controlOn", .dark), knob), 3.49, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(contrast("controlOn", "cardBackground", .dark), 4.84, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(contrast("controlOn", "background", .dark), 5.37, accuracy: Self.ratioAccuracy)
    }

    // MARK: - T2-T4: colour-blind separation (CIEDE2000, 2.3)

    /// Test floors (2.3, 10.2): the vote trio at least 10 for every kind of vision, normal and HC;
    /// the party trio at least 15; Updated / Passed at least 10, normal and HC; Passed / Failed at
    /// least 8 with the normal values.
    func testT2ToT4FloorsHoldForEveryKindOfVision() {
        for appearance in Appearance.allCases {
            for highContrast in [false, true] {
                for (first, second) in [("voteYea", "voteNay"), ("voteYea", "voteAbstain"), ("voteNay", "voteAbstain")] {
                    let distance = minDeltaE(first, second, appearance, highContrast: highContrast)
                    XCTAssertGreaterThanOrEqual(distance, 10, "\(first) / \(second), \(appearance), HC \(highContrast)")
                }
                let updatedPassed = minDeltaE("statusUpdated", "statusPassed", appearance, highContrast: highContrast)
                XCTAssertGreaterThanOrEqual(updatedPassed, 10, "Updated / Passed, \(appearance), HC \(highContrast)")
            }
            for (first, second) in [("partyDemocratic", "partyRepublican"), ("partyDemocratic", "partyIndependent"), ("partyRepublican", "partyIndependent")] {
                XCTAssertGreaterThanOrEqual(minDeltaE(first, second, appearance), 15, "\(first) / \(second), \(appearance)")
            }
            XCTAssertGreaterThanOrEqual(minDeltaE("statusPassed", "statusFailed", appearance), 8, "Passed / Failed, \(appearance)")
        }
        XCTAssertGreaterThanOrEqual(minDeltaE("statusPassed", "statusFailed", .light, highContrast: true), 8, "Passed / Failed, light HC")
        // The one recorded exception (2.3): under Increase Contrast in dark mode the lighter danger
        // red and Passed are 1.5 apart for deuteranopes. They only ever appear as the words PASSED
        // and FAILED.
        XCTAssertEqual(deltaE("statusPassed", "statusFailed", .dark, .deuteranopia, highContrast: true), 1.5, accuracy: Self.deltaEAccuracy)
    }

    /// The colour-difference tables of 2.3 (normal, protanopia, deuteranopia, tritanopia), with the
    /// normal and the Increase Contrast values. Nay / Updated and Failed / R have no floor: they are
    /// always told apart by a word or letter.
    func testColourDifferencesMatchSpecTables() {
        typealias Row = (String, String, light: [Double], dark: [Double])
        let normal: [Row] = [
            ("voteYea", "voteNay", [43.6, 36.0, 41.6, 52.6], [45.8, 38.5, 44.2, 58.0]),
            ("voteYea", "voteAbstain", [18.8, 10.9, 14.2, 20.9], [24.8, 17.5, 18.0, 27.0]),
            ("voteNay", "voteAbstain", [26.0, 22.8, 24.2, 26.0], [27.4, 24.5, 27.3, 26.2]),
            ("partyDemocratic", "partyRepublican", [42.8, 45.0, 52.9, 60.7], [41.6, 39.6, 47.0, 69.8]),
            ("partyDemocratic", "partyIndependent", [23.9, 22.8, 24.6, 19.1], [22.2, 21.7, 23.0, 22.3]),
            ("partyRepublican", "partyIndependent", [27.2, 19.8, 22.4, 28.3], [25.7, 16.4, 19.4, 27.4]),
            ("statusUpdated", "statusPassed", [29.6, 11.8, 14.8, 41.8], [32.6, 10.9, 15.5, 48.5]),
            ("statusPassed", "statusFailed", [59.9, 14.6, 14.5, 58.2], [68.7, 18.7, 8.4, 69.7]),
            ("voteNay", "statusUpdated", [21.1, 3.2, 2.3, 13.2], [20.2, 10.1, 6.1, 11.9]),
            ("statusFailed", "partyRepublican", [1.2, 1.3, 0.9, 1.0], [1.5, 0.9, 1.5, 0.7])
        ]
        let highContrast: [Row] = [
            ("voteYea", "voteNay", [39.4, 32.3, 37.0, 46.8], [45.8, 38.5, 44.2, 58.0]),
            ("voteYea", "voteAbstain", [17.4, 10.7, 12.7, 19.7], [22.3, 11.8, 15.6, 24.2]),
            ("voteNay", "voteAbstain", [24.2, 20.4, 22.2, 24.7], [25.7, 24.2, 24.8, 24.9]),
            ("statusUpdated", "statusPassed", [26.2, 10.9, 14.4, 38.9], [32.6, 10.9, 15.5, 48.5]),
            ("statusPassed", "statusFailed", [52.7, 8.8, 15.2, 52.4], [60.5, 12.6, 1.5, 61.5])
        ]
        let order: [Deficiency] = [.normal, .protanopia, .deuteranopia, .tritanopia]
        for (rows, isHighContrast) in [(normal, false), (highContrast, true)] {
            for (first, second, light, dark) in rows {
                for (index, deficiency) in order.enumerated() {
                    XCTAssertEqual(
                        deltaE(first, second, .light, deficiency, highContrast: isHighContrast),
                        light[index],
                        accuracy: Self.deltaEAccuracy,
                        "\(first) / \(second), light, \(deficiency), HC \(isHighContrast)"
                    )
                    XCTAssertEqual(
                        deltaE(first, second, .dark, deficiency, highContrast: isHighContrast),
                        dark[index],
                        accuracy: Self.deltaEAccuracy,
                        "\(first) / \(second), dark, \(deficiency), HC \(isHighContrast)"
                    )
                }
            }
        }
    }

    func testNayIsNotTheRepublicanColour() {
        for appearance in Appearance.allCases {
            XCTAssertGreaterThanOrEqual(deltaE("voteNay", "partyRepublican", appearance, .normal), 10, "\(appearance)")
        }
    }

    // MARK: - T7: the vote map

    /// T7 (spec 2.1 "Map", 10.2): the 50/50 neutral against the plate (1.55:1 light, 2.32:1 dark: at least
    /// 1.5 and 2.3) and the document; the state outline (`ink3` light, `ink2` dark, at full strength) at 3:1 or
    /// more against both the plate and the neutral, which is what carries the edges; the ramp's ends on the
    /// plate; and the ramp's lightness monotonic from each end to the neutral.
    func testT7MapNeutralPlateAndOutlines() {
        XCTAssertGreaterThanOrEqual(contrast("mapNeutral", "plate", .light), 1.5)
        XCTAssertGreaterThanOrEqual(contrast("mapNeutral", "plate", .dark), 2.3)
        let table: [(String, String, Appearance, Double)] = [
            ("mapNeutral", "plate", .light, 1.55), ("mapNeutral", "plate", .dark, 2.32),
            ("mapNeutral", "document", .light, 1.74), ("mapNeutral", "document", .dark, 2.52),
            ("dimText", "plate", .light, 5.46), ("dimText", "mapNeutral", .light, 3.52),
            ("secondaryText", "plate", .dark, 10.48), ("secondaryText", "mapNeutral", .dark, 4.52),
            ("voteYea", "plate", .light, 5.43), ("voteNay", "plate", .light, 5.14),
            ("voteYea", "plate", .dark, 8.19), ("voteNay", "plate", .dark, 7.74)
        ]
        for (first, second, appearance, ratio) in table {
            XCTAssertEqual(contrast(first, second, appearance), ratio, accuracy: Self.ratioAccuracy, "\(first) on \(second), \(appearance)")
        }
        for appearance in Appearance.allCases {
            let outline = appearance.isDark ? "secondaryText" : "dimText"
            for highContrast in [false, true] {
                for ground in ["plate", "mapNeutral"] {
                    XCTAssertGreaterThanOrEqual(contrast(outline, ground, appearance, highContrast: highContrast), 3, "outline on \(ground), \(appearance), HC \(highContrast)")
                }
            }
            // The ends stay apart from the neutral for every kind of vision.
            for end in ["voteYea", "voteNay"] {
                XCTAssertGreaterThanOrEqual(minDeltaE(end, "mapNeutral", appearance), 30, "\(end) \(appearance)")
            }
            // Lightness runs one way from each end to the neutral.
            let neutral = Math.lab(rgb("mapNeutral", appearance)).l
            for end in ["voteYea", "voteNay"] {
                let endL = Math.lab(rgb(end, appearance)).l
                var previous = endL
                for step in 1...10 {
                    let stop = Math.interpolateLab(from: rgb(end, appearance), to: rgb("mapNeutral", appearance), fraction: Double(step) / 10)
                    let l = Math.lab(stop).l
                    XCTAssertEqual(l > previous, neutral > endL, "\(end) step \(step), \(appearance)")
                    previous = l
                }
            }
        }
        let expected: [(String, Appearance, Double)] = [
            ("voteYea", .light, 31.1), ("voteNay", .light, 40.8), ("voteYea", .dark, 34.0), ("voteNay", .dark, 48.3)
        ]
        for (end, appearance, value) in expected {
            XCTAssertEqual(minDeltaE(end, "mapNeutral", appearance), value, accuracy: 0.1, "\(end) \(appearance)")
        }
    }

    // MARK: - T8: vote labels on their tinted button fill

    func testT8VoteButtonLabelsMeetAAOnTheirTintedFill() {
        for appearance in Appearance.allCases {
            let sheet = rgb("cardBackground", appearance)
            for highContrast in [false, true] {
                for choice in VoteChoice.allCases {
                    let vote = choice.paletteToken.resolved(dark: appearance.isDark, highContrast: highContrast).rgb
                    // The ballot buttons' 7% / 6% tint.
                    for tint in [BallotButtonStyle.tintOpacity(dark: appearance.isDark)] {
                        let fill = Math.composite(vote, alpha: tint, over: sheet)
                        let ratio = Math.contrastRatio(vote, fill)
                        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(choice) on its \(tint) tint, \(appearance), HC \(highContrast): \(ratio)")
                    }
                    // Selected: onFill on the solid vote colour.
                    let selected = Math.contrastRatio(rgb("onFill", appearance, highContrast: highContrast), vote)
                    XCTAssertGreaterThanOrEqual(selected, 4.5, "\(choice) selected, \(appearance), HC \(highContrast)")
                }
            }
        }
        // The spec's numbers for the ballot buttons (2.1 and "Increase Contrast values").
        let expected: [(VoteChoice, Appearance, normal: Double, high: Double)] = [
            (.yea, .light, 5.50, 7.54), (.nay, .light, 5.21, 7.48), (.abstain, .light, 5.39, 8.69),
            (.yea, .dark, 7.22, 7.22), (.nay, .dark, 6.91, 6.91), (.abstain, .dark, 4.82, 7.01)
        ]
        for (choice, appearance, normal, high) in expected {
            let tint = appearance.isDark ? 0.06 : 0.07
            for (isHighContrast, value) in [(false, normal), (true, high)] {
                let vote = choice.paletteToken.resolved(dark: appearance.isDark, highContrast: isHighContrast).rgb
                let fill = Math.composite(vote, alpha: tint, over: rgb("cardBackground", appearance))
                XCTAssertEqual(Math.contrastRatio(vote, fill), value, accuracy: Self.ratioAccuracy, "\(choice) \(appearance) HC \(isHighContrast)")
            }
        }
    }

    // MARK: - T9: no text on clear glass

    /// No text token may sit on clear glass: every text-carrying custom glass view puts its text on
    /// an opaque sheet inside the glass. The reason is the flat composites of 2.2: ink on raw glass
    /// over ink text is 6.17:1 in light mode, but over a white title in dark mode only 2.87:1.
    func testT9TextOnCustomGlassSitsOnAnOpaqueFill() {
        XCTAssertTrue(BillboardPalette.textTokensAllowedOnClearGlass.isEmpty)
        let fill = BillboardPalette.glassInnerFillTokenName
        XCTAssertEqual(token(fill).light.alpha, 1, "the inner fill is opaque")
        XCTAssertEqual(token(fill).dark.alpha, 1, "the inner fill is opaque")
        XCTAssertEqual(contrast("primaryText", fill, .light), 17.41, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(contrast("primaryText", fill, .dark), 14.80, accuracy: Self.ratioAccuracy)

        let lightGlass = Math.composite(RGBA.hex(0xFFFFFF).rgb, alpha: 0.56, over: rgb("primaryText", .light))
        XCTAssertEqual(Math.contrastRatio(rgb("primaryText", .light), lightGlass), 6.17, accuracy: Self.ratioAccuracy)
        let darkGlass = Math.composite(RGBA.hex(0x1E2638).rgb, alpha: 0.52, over: RGBA.hex(0xFFFFFF).rgb)
        let darkRatio = Math.contrastRatio(rgb("primaryText", .dark), darkGlass)
        XCTAssertEqual(darkRatio, 2.87, accuracy: Self.ratioAccuracy)
        XCTAssertLessThan(darkRatio, 4.5, "why the text needs the opaque sheet")
    }

    // MARK: - T10, T11: the tab capsule and text on navy

    /// The navy glass tab capsule (2.2, 3.22), as flat composites of navy at 0.85 over what scrolls
    /// beneath (a white sheet in light mode, night paper in dark mode).
    func testT10TabCapsuleLabelsAndSelectionStroke() {
        let navy = rgb("navy", .light)
        let teal = rgb("brandTeal", .light)
        let tint = BillboardPalette.tabGlassTintOpacity
        XCTAssertEqual(tint, 0.85)
        let overSheet = Math.composite(navy, alpha: tint, over: RGBA.hex(0xFFFFFF).rgb)
        let overNightPaper = Math.composite(navy, alpha: tint, over: rgb("background", .dark))

        // Selected label: brand teal on the opaque navy selection capsule.
        XCTAssertGreaterThanOrEqual(Math.contrastRatio(teal, navy), 4.5)
        XCTAssertEqual(Math.contrastRatio(teal, navy), 7.20, accuracy: Self.ratioAccuracy)
        // Selection stroke at 100% against the glass and against the navy capsule (1.4.11).
        XCTAssertGreaterThanOrEqual(Math.contrastRatio(teal, overSheet), 3)
        XCTAssertEqual(Math.contrastRatio(teal, overSheet), 4.57, accuracy: Self.ratioAccuracy)
        XCTAssertEqual(Math.contrastRatio(teal, overNightPaper), 7.33, accuracy: Self.ratioAccuracy)
        // Unselected labels: textOnNavyDim (white 74%; 85% under Increase Contrast).
        for (glass, normal, high) in [(overSheet, 6.68, 8.22), (overNightPaper, 9.75, 12.55)] {
            let dim = drawn(rgba("textOnNavyDim", .light), over: glass)
            let dimHigh = drawn(rgba("textOnNavyDim", .light, highContrast: true), over: glass)
            XCTAssertGreaterThanOrEqual(Math.contrastRatio(dim, glass), 4.5)
            XCTAssertGreaterThanOrEqual(Math.contrastRatio(dimHigh, glass), 7)
            XCTAssertEqual(Math.contrastRatio(dim, glass), normal, accuracy: Self.ratioAccuracy)
            XCTAssertEqual(Math.contrastRatio(dimHigh, glass), high, accuracy: Self.ratioAccuracy)
        }
        // The tab badge: navy numerals on a white capsule.
        XCTAssertEqual(Math.contrastRatio(navy, RGBA.hex(0xFFFFFF).rgb), 16.79, accuracy: Self.ratioAccuracy)
    }

    func testT11TextOnNavyMeetsAA() {
        for appearance in Appearance.allCases {
            XCTAssertEqual(contrast("textOnNavy", "navy", appearance), 16.79, accuracy: Self.ratioAccuracy)
            XCTAssertEqual(contrast("textOnNavyDim", "navy", appearance), 9.61, accuracy: Self.ratioAccuracy)
            XCTAssertGreaterThanOrEqual(contrast("textOnNavyDim", "navy", appearance, highContrast: true), 7)
        }
    }

    // MARK: - T12: no type role under 11 pt

    /// The smallest roles (stamp, tag label, dateline, small caption, tab label, badge) are 11 pt
    /// at the default text size; nothing is smaller (spec 2.5).
    func testT12NoTextRoleIsUnderElevenPoints() {
        for role in TextRole.allCases {
            XCTAssertGreaterThanOrEqual(role.size, 11, "\(role)")
        }
        let elevens = Set(TextRole.allCases.filter { $0.size == 11 })
        XCTAssertEqual(elevens, [.stamp, .tagLabel, .dateline, .smallCaption, .tabLabel, .badge])
    }

    // MARK: - Appearance setting

    func testAppearancePreferenceMapsToSchemesAndDefaultsToSystem() {
        XCTAssertEqual(AppearancePreference.storageKey, "BillBoard.appearance.v1")
        XCTAssertNil(AppearancePreference.system.colorScheme)
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
        XCTAssertEqual(AppearancePreference.system.userInterfaceStyle, .unspecified)
        XCTAssertEqual(AppearancePreference.light.userInterfaceStyle, .light)
        XCTAssertEqual(AppearancePreference.dark.userInterfaceStyle, .dark)
        XCTAssertEqual(AppearancePreference.allCases.map(\.title), ["System", "Light", "Dark"])
        XCTAssertEqual(AppearancePreference(rawValue: "system"), .system)
        XCTAssertNil(AppearancePreference(rawValue: "sepia"))
    }

    func testThePartyHelperReturnsItsTokens() {
        var environment = EnvironmentValues()
        environment.colorScheme = .dark
        XCTAssertEqual(BillboardColors.party(.democratic).resolve(in: environment), BillboardColors.partyDemocratic.resolve(in: environment))
        XCTAssertEqual(BillboardColors.party(.republican).resolve(in: environment), BillboardColors.partyRepublican.resolve(in: environment))
        XCTAssertEqual(BillboardColors.party(.independent).resolve(in: environment), BillboardColors.partyIndependent.resolve(in: environment))
    }
}
