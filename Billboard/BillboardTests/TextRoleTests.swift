import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Civic Record's type roles (spec 2.5), radii (2.6) and spacing (2.8): each role's face, size,
/// weight, scaling style, tracking, case and line spacing equal the spec table, and `.textRole`
/// scales from the environment's Dynamic Type size, so render tests can draw AX sizes for real.
@MainActor
final class TextRoleTests: XCTestCase {
    private struct SpecRole {
        let role: TextRole
        let face: TextRole.Face
        let size: CGFloat
        let weight: Font.Weight
        let textStyle: UIFont.TextStyle?
        let trackingEm: CGFloat
        let uppercase: Bool
        let lineSpacing: CGFloat
    }

    /// Spec 2.5, row by row ("fixed" roles have no text style).
    private static let specTable: [SpecRole] = [
        SpecRole(role: .display, face: .condensed, size: 40, weight: .heavy, textStyle: .largeTitle, trackingEm: -0.01, uppercase: false, lineSpacing: 0),
        SpecRole(role: .billTitle, face: .condensed, size: 34, weight: .bold, textStyle: .largeTitle, trackingEm: -0.01, uppercase: false, lineSpacing: 0),
        SpecRole(role: .title, face: .condensed, size: 30, weight: .bold, textStyle: .title1, trackingEm: -0.005, uppercase: false, lineSpacing: 0),
        SpecRole(role: .heading, face: .condensed, size: 22, weight: .bold, textStyle: .title2, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .name, face: .condensed, size: 20, weight: .bold, textStyle: .title3, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .lead, face: .serif, size: 20, weight: .regular, textStyle: .title3, trackingEm: -0.004, uppercase: false, lineSpacing: 6),
        SpecRole(role: .leadStrong, face: .serif, size: 21, weight: .semibold, textStyle: .title3, trackingEm: -0.005, uppercase: false, lineSpacing: 4),
        SpecRole(role: .prose, face: .serif, size: 17, weight: .regular, textStyle: .body, trackingEm: 0, uppercase: false, lineSpacing: 5),
        SpecRole(role: .officialTitle, face: .serif, size: 16, weight: .regular, textStyle: .callout, trackingEm: 0, uppercase: false, lineSpacing: 4),
        SpecRole(role: .body, face: .text, size: 16, weight: .regular, textStyle: .callout, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .subheadline, face: .text, size: 15, weight: .medium, textStyle: .subheadline, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .caption, face: .text, size: 13, weight: .regular, textStyle: .footnote, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .smallCaption, face: .text, size: 11, weight: .semibold, textStyle: .caption2, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .label, face: .text, size: 11.5, weight: .semibold, textStyle: .caption1, trackingEm: 0.08, uppercase: true, lineSpacing: 0),
        SpecRole(role: .tagLabel, face: .text, size: 11, weight: .semibold, textStyle: .caption2, trackingEm: 0.08, uppercase: true, lineSpacing: 0),
        SpecRole(role: .button, face: .text, size: 16, weight: .semibold, textStyle: .callout, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .docket, face: .mono, size: 11.5, weight: .medium, textStyle: .caption1, trackingEm: 0.06, uppercase: true, lineSpacing: 0),
        SpecRole(role: .dateline, face: .mono, size: 11, weight: .medium, textStyle: .caption2, trackingEm: 0.05, uppercase: true, lineSpacing: 0),
        SpecRole(role: .stamp, face: .mono, size: 11, weight: .semibold, textStyle: .caption2, trackingEm: 0.08, uppercase: true, lineSpacing: 0),
        SpecRole(role: .figure, face: .mono, size: 15.5, weight: .medium, textStyle: .callout, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .figureSmall, face: .mono, size: 12.5, weight: .medium, textStyle: .footnote, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .figureLarge, face: .mono, size: 24, weight: .medium, textStyle: .title2, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .navTitle, face: .condensed, size: 18, weight: .bold, textStyle: nil, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .tabLabel, face: .text, size: 11, weight: .semibold, textStyle: nil, trackingEm: 0.01, uppercase: false, lineSpacing: 0),
        SpecRole(role: .badge, face: .mono, size: 11, weight: .bold, textStyle: nil, trackingEm: 0, uppercase: false, lineSpacing: 0),
        SpecRole(role: .stampLarge, face: .text, size: 13, weight: .bold, textStyle: .footnote, trackingEm: 0.1, uppercase: true, lineSpacing: 0),
        SpecRole(role: .wordmark, face: .condensed, size: 30, weight: .black, textStyle: nil, trackingEm: 0.015, uppercase: true, lineSpacing: 0),
        SpecRole(role: .wordmarkCompact, face: .condensed, size: 26, weight: .black, textStyle: nil, trackingEm: 0.015, uppercase: true, lineSpacing: 0)
    ]

    func testRolesMatchSpecTable() {
        XCTAssertEqual(Self.specTable.count, TextRole.allCases.count, "every role is in the table once")
        for spec in Self.specTable {
            let role = spec.role
            XCTAssertEqual(role.face, spec.face, "\(role) face")
            XCTAssertEqual(role.size, spec.size, "\(role) size")
            XCTAssertEqual(role.weight, spec.weight, "\(role) weight")
            XCTAssertEqual(role.textStyle, spec.textStyle, "\(role) text style")
            XCTAssertEqual(role.trackingEm, spec.trackingEm, accuracy: 1e-9, "\(role) tracking")
            XCTAssertEqual(role.isUppercase, spec.uppercase, "\(role) case")
            XCTAssertEqual(role.lineSpacing, spec.lineSpacing, "\(role) line spacing")
        }
    }

    /// New York is for reading text only (spec 1.3): the four reading roles and nothing else.
    func testSerifOnlyInTheFourReadingRoles() {
        let serif = TextRole.allCases.filter { $0.face == .serif }
        XCTAssertEqual(Set(serif), [.lead, .leadStrong, .prose, .officialTitle])
    }

    func testDynamicTypeSizesMapToContentSizeCategories() {
        let expected: [(DynamicTypeSize, UIContentSizeCategory)] = [
            (.xSmall, .extraSmall), (.small, .small), (.medium, .medium), (.large, .large),
            (.xLarge, .extraLarge), (.xxLarge, .extraExtraLarge), (.xxxLarge, .extraExtraExtraLarge),
            (.accessibility1, .accessibilityMedium), (.accessibility2, .accessibilityLarge),
            (.accessibility3, .accessibilityExtraLarge), (.accessibility4, .accessibilityExtraExtraLarge),
            (.accessibility5, .accessibilityExtraExtraExtraLarge)
        ]
        XCTAssertEqual(expected.count, DynamicTypeSize.allCases.count)
        for (size, category) in expected {
            XCTAssertEqual(TextRole.contentSizeCategory(for: size), category, "\(size)")
        }
    }

    /// Scaled roles follow their system text style's curve; fixed roles keep their size.
    func testScaledSizesFollowUIFontMetricsAndFixedRolesStayPut() {
        for role in TextRole.allCases {
            XCTAssertEqual(role.scaledSize(for: .large), role.size, "\(role) at the default size")
            let ax5 = role.scaledSize(for: .accessibility5)
            guard let textStyle = role.textStyle else {
                XCTAssertEqual(ax5, role.size, "\(role) is fixed")
                continue
            }
            let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)
            let expected = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: role.size, compatibleWith: traits)
            XCTAssertEqual(role.scaledSize(for: .accessibility3), expected, accuracy: 1e-9, "\(role) at AX3")
            XCTAssertGreaterThan(ax5, role.size, "\(role) grows at AX5")
            XCTAssertLessThan(role.scaledSize(for: .xSmall), role.size + 1e-9, "\(role) shrinks or holds at xSmall")
        }
    }

    /// The point of reading the environment: a render test that sets the Dynamic Type size gets
    /// bigger text (R2's fonts read the app's category and did not grow there).
    func testTextRoleScalesInsideImageRenderer() throws {
        func height(_ view: some View, _ size: DynamicTypeSize) throws -> CGFloat {
            let renderer = ImageRenderer(content: view.fixedSize().environment(\.dynamicTypeSize, size))
            renderer.scale = 1
            return CGFloat(try XCTUnwrap(renderer.cgImage).height)
        }
        let prose = Text("Ag Why it matters").textRole(.prose)
        XCTAssertGreaterThan(try height(prose, .accessibility5) / height(prose, .large), 2.5, "prose scales at AX5")
        let docket = Text("H.R. 1234").textRole(.docket)
        XCTAssertGreaterThan(try height(docket, .accessibility3), try height(docket, .large), "docket scales at AX3")
        let tab = Text("Bills").textRole(.tabLabel)
        XCTAssertEqual(try height(tab, .accessibility5), try height(tab, .large), "tab labels are fixed")
    }

    // MARK: - Radii and spacing

    func testRadiiAndSpacingMatchTheSpec() {
        XCTAssertEqual(BillboardStyle.Radius.mark, 4)
        XCTAssertEqual(BillboardStyle.Radius.slip, 16)
        XCTAssertEqual(BillboardStyle.Radius.panel, 30)

        let space = [
            BillboardStyle.Space.xxs, BillboardStyle.Space.xs, BillboardStyle.Space.s, BillboardStyle.Space.m,
            BillboardStyle.Space.l, BillboardStyle.Space.xl, BillboardStyle.Space.xxl, BillboardStyle.Space.xxxl
        ]
        XCTAssertEqual(space, [2, 4, 8, 12, 16, 20, 28, 40])
        for value in space.dropFirst() {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0, "\(value) is on the 4 pt grid")
        }
    }
}
