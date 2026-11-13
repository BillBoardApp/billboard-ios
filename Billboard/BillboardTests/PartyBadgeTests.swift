import CoreGraphics
import SwiftUI
import XCTest
@testable import Billboard

/// Party letters and names (spec D 2.3.4) and `PartyBadge`: a circle in the party colour with the
/// letter in `onFill`, read by VoiceOver as the party name, sized with Dynamic Type.
@MainActor
final class PartyBadgeTests: XCTestCase {
    // MARK: - PoliticalParty

    func testLettersAndDisplayNames() {
        XCTAssertEqual(PoliticalParty.democratic.letter, "D")
        XCTAssertEqual(PoliticalParty.republican.letter, "R")
        XCTAssertEqual(PoliticalParty.independent.letter, "I")

        XCTAssertEqual(PoliticalParty.democratic.displayName, "Democrat")
        XCTAssertEqual(PoliticalParty.republican.displayName, "Republican")
        XCTAssertEqual(PoliticalParty.independent.displayName, "Independent")
    }

    func testRawValuesAreUnchangedForStoredProfiles() {
        XCTAssertEqual(PoliticalParty.democratic.rawValue, "Democratic")
        XCTAssertEqual(PoliticalParty.republican.rawValue, "Republican")
        XCTAssertEqual(PoliticalParty.independent.rawValue, "Independent")
    }

    func testFromRawAcceptsNamesLettersAndOldAbbreviations() {
        let cases: [(String?, PoliticalParty?)] = [
            ("Democratic", .democratic), ("Democrat", .democratic), ("D", .democratic), ("dem", .democratic),
            ("Republican", .republican), ("R", .republican), ("GOP", .republican), (" rep ", .republican),
            ("Independent", .independent), ("I", .independent), ("Ind", .independent),
            ("Green", nil), ("", nil), ("   ", nil), (nil, nil)
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(PoliticalParty.from(raw: raw), expected, String(describing: raw))
        }
    }

    // MARK: - PartyBadge

    func testAccessibilityLabelIsThePartyName() {
        for party in PoliticalParty.allCases {
            XCTAssertEqual(PartyBadge.accessibilityLabel(for: party), party.displayName)
        }
    }

    func testLetterMeetsAAOnEveryPartyColourInBothAppearances() {
        let tokens: [PoliticalParty: BillboardColorToken] = [
            .democratic: BillboardPalette.partyDemocratic,
            .republican: BillboardPalette.partyRepublican,
            .independent: BillboardPalette.partyIndependent
        ]
        for party in PoliticalParty.allCases {
            for dark in [false, true] {
                let fill = tokens[party]!.resolved(dark: dark).rgb
                let letter = BillboardPalette.onFill.resolved(dark: dark).rgb
                XCTAssertGreaterThanOrEqual(BillboardColorMath.contrastRatio(letter, fill), 4.5, "\(party) dark=\(dark)")
            }
        }
    }

    func testRenderedFillIsThePartyColourInLightAndDark() throws {
        let tokens: [PoliticalParty: BillboardColorToken] = [
            .democratic: BillboardPalette.partyDemocratic,
            .republican: BillboardPalette.partyRepublican,
            .independent: BillboardPalette.partyIndependent
        ]
        for party in PoliticalParty.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let image = try render(PartyBadge(party: party, size: .regular), scheme: scheme)
                XCTAssertEqual(image.width, 24, "regular badge is 24 pt at the default text size")
                XCTAssertEqual(image.height, 24)

                // A point inside the circle, left of the letter.
                let sample = try pixel(of: image, x: image.width * 15 / 100, y: image.height / 2)
                let expected = tokens[party]!.resolved(dark: scheme == .dark)
                XCTAssertEqual(sample.red, expected.red, accuracy: 0.02, "\(party) \(scheme)")
                XCTAssertEqual(sample.green, expected.green, accuracy: 0.02, "\(party) \(scheme)")
                XCTAssertEqual(sample.blue, expected.blue, accuracy: 0.02, "\(party) \(scheme)")
            }
        }
    }

    func testSmallIsSmallerAndBothGrowWithDynamicType() throws {
        let small = try render(PartyBadge(party: .democratic, size: .small), scheme: .light)
        let regular = try render(PartyBadge(party: .democratic, size: .regular), scheme: .light)
        XCTAssertEqual(small.width, 18)
        XCTAssertLessThan(small.width, regular.width)

        let largeText = try render(PartyBadge(party: .democratic, size: .regular), scheme: .light, dynamicTypeSize: .accessibility3)
        XCTAssertGreaterThan(largeText.width, regular.width)
        XCTAssertEqual(largeText.width, largeText.height, "stays a circle")
    }

    // MARK: - Rendering helpers

    private func render<Content: View>(
        _ view: Content,
        scheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize = .large
    ) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        )
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "render failed")
    }

    /// The sRGB colour of one pixel, `x` and `y` from the top left.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> (red: Double, green: Double, blue: Double) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(
                    x: -CGFloat(x),
                    y: -CGFloat(image.height - 1 - y),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        XCTAssertEqual(bytes[3], 255, "sampled inside the opaque circle")
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
