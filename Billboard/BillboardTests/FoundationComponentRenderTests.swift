import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the shared components in light and dark, at the default text size and at AX3 (and, for
/// Civic Record's components, AX5, Button Shapes, Reduce Transparency and Increase Contrast), and
/// attaches each image to the result bundle for review (spec D 5.3; Civic Record spec 10.1). No
/// network, no credentials, no baselines; pixels are checked where the colour or the rule is the point.
@MainActor
final class FoundationComponentRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String { "\(scheme == .dark ? "dark" : "light")-\(size == .large ? "default" : "AX3")" }
    }

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility3)
    ]

    // MARK: - Ballot buttons (Civic Record spec 3.10)

    private func ballotButton(_ choice: VoteChoice, state: BallotButtonStyle.State) -> some View {
        Button {} label: {
            BallotButtonLabel(choice: choice, isCurrent: state == .current, isInked: state == .inked)
        }
        .buttonStyle(BallotButtonStyle(choice: choice, state: state))
    }

    private var ballotButtons: some View {
        VStack(spacing: 12) {
            ForEach([BallotButtonStyle.State.ready, .current, .inked], id: \.self) { state in
                HStack(spacing: 8) {
                    ForEach(VoteChoice.allCases) { self.ballotButton($0, state: state) }
                }
            }
        }
        .padding(16)
        .background(BillboardColors.cardBackground)
    }

    func testBallotButtonsRenderInEveryVariant() throws {
        for variant in Self.variants {
            let image = try render(ballotButtons, variant: variant, width: 390)
            attach(image, name: "ballot-buttons-\(variant.name)")
            // Three rows of at least 50 pt plus padding and spacing.
            XCTAssertGreaterThanOrEqual(image.height, 3 * 50 + 2 * 12 + 32, variant.name)
        }
    }

    func testBallotButtonFillsUseTheVotePalette() throws {
        // Inked Yea, dark: the solid vote colour.
        let inked = try render(ballotButton(.yea, state: .inked), variant: Variant(scheme: .dark, size: .large), width: 360)
        XCTAssertGreaterThanOrEqual(inked.height, 50, "50 pt at the default text size")
        let inkedPixel = try pixel(of: inked, x: 12, y: inked.height / 2)
        let yeaDark = BillboardPalette.voteYea.dark
        XCTAssertEqual(inkedPixel.red, yeaDark.red, accuracy: 0.02)
        XCTAssertEqual(inkedPixel.green, yeaDark.green, accuracy: 0.02)
        XCTAssertEqual(inkedPixel.blue, yeaDark.blue, accuracy: 0.02)

        // Unselected Nay, light: 7% of the vote colour over the opaque sheet.
        let ready = try render(ballotButton(.nay, state: .ready), variant: Variant(scheme: .light, size: .large), width: 360)
        let readyPixel = try pixel(of: ready, x: 12, y: ready.height / 2)
        let tint = BillboardColorMath.composite(
            BillboardPalette.voteNay.light.rgb,
            alpha: BallotButtonStyle.tintOpacity(dark: false),
            over: BillboardPalette.cardBackground.light.rgb
        )
        XCTAssertEqual(readyPixel.red, tint.red, accuracy: 0.02)
        XCTAssertEqual(readyPixel.green, tint.green, accuracy: 0.02)
        XCTAssertEqual(readyPixel.blue, tint.blue, accuracy: 0.02)
    }

    // MARK: - Undo toast

    func testUndoToastRendersInEveryVariant() throws {
        for variant in Self.variants {
            let toast = UndoToast(message: "Skipped H.R. 1234", onUndo: {})
                .padding(16)
                .background(BillboardColors.background)
            let image = try render(toast, variant: variant, width: 390)
            attach(image, name: "undo-toast-\(variant.name)")
            XCTAssertGreaterThanOrEqual(image.height, 44 + 32, "the Undo target is at least 44 pt")
        }
    }

    /// Civic Record spec 4.23 (replacing R2's "navy in both appearances"): the toast's text and "Undo" sit
    /// on the glass capsule's opaque inner sheet in light and dark, over paper, a white title and navy alike,
    /// and "Undo" is ink, not teal. Reduce Transparency draws the fallback: the sheet with a 1 pt rule and
    /// no rim. Drawn at 2x.
    func testUndoToastTextSitsOnAnOpaqueSheetAndUndoIsInk() throws {
        for scheme in [ColorScheme.light, .dark] {
            for ground in [BillboardColors.background, BillboardColors.textOnNavy, BillboardColors.navy] {
                let look = Look(scheme: scheme)
                let image = try draw(UndoToast(message: "Cleared 3 bills", onUndo: {}).padding(10).background(ground), look, width: 343, scale: 2)
                XCTAssertEqual(image.height, (50 + 20) * 2, "50 pt toast \(look.name)")
                let sheet = tokenColor(BillboardPalette.cardBackground, look)
                let mid = image.height / 2
                // 10 pt in, the 4 pt rim, then 4 pt into the sheet at both ends (the text is 16 pt in).
                assertColor(try pixel(of: image, x: 36, y: mid), sheet, accuracy: 0.01, "the sheet before the message \(look.name)")
                assertColor(try pixel(of: image, x: image.width - 37, y: mid), sheet, accuracy: 0.01, "the sheet after Undo \(look.name)")
                // "Undo" ends 16 pt inside the sheet: its strokes are ink.
                let undo = try inkiestPixel(in: image, x: (343 - 14 - 16 - 40) * 2..<(343 - 14 - 16) * 2, y: mid - 12..<mid + 12, towards: tokenColor(BillboardPalette.primaryText, look))
                assertColor(undo, tokenColor(BillboardPalette.primaryText, look), accuracy: 0.05, "Undo is ink \(look.name)")
            }

            let reduced = Look(scheme: scheme, reduceTransparency: true)
            let solid = try draw(UndoToast(message: "Cleared 3 bills", onUndo: {}).padding(10).background(BillboardColors.navy), reduced, width: 343, scale: 2)
            XCTAssertEqual(solid.height, (50 + 20) * 2, "the fallback keeps the size \(reduced.name)")
            assertColor(try pixel(of: solid, x: 20, y: solid.height / 2), tokenColor(BillboardPalette.separator, reduced), accuracy: 0.03, "1 pt rule over the sheet, no rim \(reduced.name)")
            assertColor(try pixel(of: solid, x: 23, y: solid.height / 2), tokenColor(BillboardPalette.cardBackground, reduced), accuracy: 0.01, "the sheet fills the capsule \(reduced.name)")
        }
        // Undo first: it has VoiceOver's focus priority (spec D 2.1.2).
        XCTAssertEqual(AccessibilityTreeText.strings(of: UndoToast(message: "Skipped H.R. 1234", onUndo: {})), ["Undo", "Skipped H.R. 1234"])
    }

    /// At the accessibility sizes the toast is two lines (the message over Undo) and takes the slip's
    /// 16 pt corners, not a pill's: 6 pt in from its top-left corner is inside the toast, which a radius
    /// of half its height would leave outside. At the default size it stays a capsule. Drawn with Reduce
    /// Transparency, on navy, so the sheet's white shows where the shape is.
    func testTheTwoLineUndoToastHasSlipCorners() throws {
        for size in [DynamicTypeSize.accessibility3, .accessibility5] {
            let look = Look(size: size, reduceTransparency: true)
            let image = try draw(UndoToast(message: "Skipped H.R. 1234", onUndo: {}).padding(10).background(BillboardColors.navy), look, width: 343, scale: 2)
            XCTAssertGreaterThan(height(of: image, scale: 2), 2 * 50, "\(look.name): two lines")
            assertColor(try pixel(of: image, x: 2 * 16, y: 2 * 16), tokenColor(BillboardPalette.cardBackground, look), accuracy: 0.02, "\(look.name): the corner is the slip's")
        }
        let capsule = Look(size: .large, reduceTransparency: true)
        let image = try draw(UndoToast(message: "Skipped H.R. 1234", onUndo: {}).padding(10).background(BillboardColors.navy), capsule, width: 343, scale: 2)
        assertColor(try pixel(of: image, x: 2 * 16, y: 2 * 16), BillboardPalette.navy.light.rgb, accuracy: 0.02, "the default size keeps a capsule's round end")
    }

    /// The pixel in `x` by `y` nearest to `target` (the darkest stroke of ink text on a light sheet, the
    /// lightest on a dark one).
    private func inkiestPixel(
        in image: CGImage,
        x: Range<Int>,
        y: Range<Int>,
        towards target: BillboardColorMath.RGB
    ) throws -> (red: Double, green: Double, blue: Double) {
        let pixels = try PixelGrid(image)
        var best = pixels.rgb(x.lowerBound, y.lowerBound)
        var bestDistance = Double.infinity
        for row in y {
            for column in x {
                let sample = pixels.rgb(column, row)
                let distance = abs(sample.red - target.red) + abs(sample.green - target.green) + abs(sample.blue - target.blue)
                if distance < bestDistance {
                    best = sample
                    bestDistance = distance
                }
            }
        }
        return best
    }

    // MARK: - Index tags, status stamps, party badges, section header

    func testSmallComponentsRenderInEveryVariant() throws {
        for variant in Self.variants {
            let sampler = VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IndexTag(.inTheNews)
                    IndexTag(.memberYouFollow)
                }
                HStack(spacing: 8) {
                    StatusStamp(status: .new)
                    StatusStamp(status: .passed)
                }
                HStack(spacing: 8) {
                    ForEach(PoliticalParty.allCases) { party in
                        PartyBadge(party: party, size: .small)
                        PartyBadge(party: party, size: .regular)
                    }
                }
                SectionHeader("Results")
            }
            .padding(16)
            .background(BillboardColors.cardBackground)

            let image = try render(sampler, variant: variant, width: 390)
            attach(image, name: "components-\(variant.name)")
            XCTAssertGreaterThan(image.height, 0)
        }
    }

    // MARK: - Rules (Civic Record spec 2.7)

    /// Each rule draws at its spec thickness in its token, and the double rule is thick over thin
    /// with a 2 pt gap.
    func testRulesDrawAtTheirThicknessInTheirTokens() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let variant = Variant(scheme: scheme, size: .large)
            let paper = BillboardPalette.background.resolved(dark: dark).rgb
            let ink = BillboardPalette.ruleHeavy.resolved(dark: dark).rgb
            func onPaper(_ rule: some View) -> some View { rule.background(BillboardColors.background) }

            let heights: [(String, AnyView, Int)] = [
                ("hairline", AnyView(onPaper(HairlineRule())), 1),
                ("heavy", AnyView(onPaper(HeavyRule())), 2),
                ("double", AnyView(onPaper(DoubleRule())), 5),
                ("dotted", AnyView(onPaper(DottedRule())), 1),
                ("perforation", AnyView(onPaper(PerforationRule())), 1),
                ("majority-tick", AnyView(onPaper(MajorityTick())), 16),
                ("masthead", AnyView(MastheadRule().background(BillboardColors.navy)), 5)
            ]
            for (name, view, height) in heights {
                let image = try render(view, variant: variant, width: 200)
                attach(image, name: "rule-\(name)-\(scheme == .dark ? "dark" : "light")")
                XCTAssertEqual(image.height, height, "\(name) \(scheme)")
                XCTAssertEqual(image.width, 200, "\(name) fills the width")
            }

            let hairline = try render(onPaper(HairlineRule()), variant: variant, width: 200)
            let rule = BillboardPalette.separator.resolved(dark: dark)
            assertColor(try pixel(of: hairline, x: 100, y: 0), BillboardColorMath.composite(rule.rgb, alpha: rule.alpha, over: paper), "hairline \(scheme)")

            let heavy = try render(onPaper(HeavyRule()), variant: variant, width: 200)
            assertColor(try pixel(of: heavy, x: 100, y: 1), ink, "heavy \(scheme)")

            let double = try render(onPaper(DoubleRule()), variant: variant, width: 200)
            assertColor(try pixel(of: double, x: 100, y: 0), ink, "double, thick rule \(scheme)")
            assertColor(try pixel(of: double, x: 100, y: 2), paper, "double, gap \(scheme)")
            assertColor(try pixel(of: double, x: 100, y: 4), ink, "double, thin rule \(scheme)")

            let tick = try render(onPaper(MajorityTick()), variant: variant, width: 200)
            assertColor(try pixel(of: tick, x: 100, y: 8), ink, "tick at 50% \(scheme)")
            assertColor(try pixel(of: tick, x: 90, y: 8), paper, "tick is 2 pt wide \(scheme)")
        }
    }

    // MARK: - Tally marks (Civic Record spec 3.23)

    /// At 24 pt the glyph's grid is one unit per point: four uprights at x 5.5, 9.5, 13.5 and 17.5
    /// from y 5 to 19, and the diagonal from (3, 16.6) to (20.5, 7.4). Drawn 2 pt wide here so whole
    /// pixels are covered.
    func testTallyMarksDrawFourUprightsAndOneDiagonal() throws {
        func glyph(struck: Bool) -> some View {
            TallyMarks(count: 4, struck: struck)
                .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(BillboardColors.primaryText)
                .frame(width: 24, height: 24)
                .background(BillboardColors.background)
        }
        let variant = Variant(scheme: .light, size: .large)
        let struck = try render(glyph(struck: true), variant: variant, width: 24)
        let unstruck = try render(glyph(struck: false), variant: variant, width: 24)
        attach(struck, name: "tally-marks")
        XCTAssertEqual(struck.width, 24)
        XCTAssertEqual(struck.height, 24)

        func isInk(_ image: CGImage, _ x: Int, _ y: Int) throws -> Bool {
            luminance(try pixel(of: image, x: x, y: y)) < 0.3
        }
        func isPaper(_ image: CGImage, _ x: Int, _ y: Int) throws -> Bool {
            luminance(try pixel(of: image, x: x, y: y)) > 0.85
        }
        for x in [5, 9, 13, 17] {
            XCTAssertTrue(try isInk(struck, x, 8), "an upright at x \(x)")
        }
        for x in [7, 11, 15, 21] {
            XCTAssertTrue(try isPaper(struck, x, 8), "a gap at x \(x)")
        }
        XCTAssertTrue(try isPaper(struck, 12, 2), "nothing above the uprights")
        XCTAssertTrue(try isPaper(struck, 12, 22), "nothing below the uprights")
        XCTAssertTrue(try isInk(struck, 11, 12), "the diagonal crosses the middle gap")
        XCTAssertTrue(try isPaper(unstruck, 11, 12), "no diagonal when not struck")
    }

    /// The masthead chips (spec 3.23): a white star and white tally marks on navy, never teal or the
    /// flame, and each reads as what it counts. Before the score has loaded they show a dash, not a false 0
    /// (UX-39 N11; this test pinned "Civic Score 0" for a store that had read nothing).
    func testTheMastheadChipsAreWhiteAndSayWhatTheyCount() async throws {
        let service = FakeCivicService()
        let store = CivicScoreStore(scope: "render-tests", userDefaults: try isolatedDefaults(), service: service)
        let chips = HStack(spacing: 24) {
            CivicScoreLeadingBadge {}
            StreakTrailingBadge {}
        }
        .padding(8)
        .background(BillboardColors.navy)
        .environmentObject(store)

        let notLoaded = AccessibilityTreeText.text(of: chips)
        XCTAssertTrue(notLoaded.contains("Civic Score, not loaded"), notLoaded)
        XCTAssertTrue(notLoaded.contains("Day streak, not loaded"), notLoaded)
        XCTAssertFalse(notLoaded.contains("Civic Score 0"), notLoaded)
        XCTAssertEqual(HeaderMetricCopy.value(nil), "–")
        for scheme in [ColorScheme.light, .dark] {
            attach(try render(chips, variant: Variant(scheme: scheme, size: .large), width: 200), name: "masthead-chips-not-loaded-\(scheme == .dark ? "dark" : "light")")
        }

        // A zero score that the server sent is a real 0.
        await store.refresh()
        let text = AccessibilityTreeText.text(of: chips)
        XCTAssertTrue(text.contains("Civic Score 0"), text)
        XCTAssertTrue(text.contains("0-day streak"), text)
        XCTAssertTrue(text.contains("Shows your civic rank details"), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("flame"), text)
        XCTAssertEqual(HeaderMetricCopy.scoreLabel(48), "Civic Score 48")
        XCTAssertEqual(HeaderMetricCopy.streakLabel(4), "4-day streak")
        XCTAssertEqual(HeaderMetricCopy.value(48), "48")

        for scheme in [ColorScheme.light, .dark] {
            let image = try render(chips, variant: Variant(scheme: scheme, size: .large), width: 200)
            attach(image, name: "masthead-chips-\(scheme == .dark ? "dark" : "light")")
            let pixels = try allPixels(of: image)
            let teal = BillboardPalette.brandTeal.light
            let tealPixels = pixels.filter {
                abs($0.red - teal.red) <= 2.0 / 255 && abs($0.green - teal.green) <= 2.0 / 255 && abs($0.blue - teal.blue) <= 2.0 / 255
            }
            XCTAssertTrue(tealPixels.isEmpty, "\(scheme): no brand teal in the chips")
            let white = pixels.filter { $0.red > 0.97 && $0.green > 0.97 && $0.blue > 0.97 }
            XCTAssertGreaterThan(white.count, 40, "\(scheme): the glyphs and figures are white")
        }
    }

    /// A vote side's head (`VoteCountHead`, spec 4.46): "✓ YEA (3)" in the `label` role and the vote colour,
    /// read "Yea, 3 votes" as Why people voted's "✓ YEA (23)" is; and the shared split (`TallySplitBar`) with
    /// no tick takes only its 8 pt. (Kept from Profile's Your votes by topic, removed in UX-39 N11.)
    func testTheVoteCountHeadIsALabelLineAndTheBareSplitHasNoTick() throws {
        XCTAssertEqual(VoteCountHead.spoken(.yea, count: 3), "Yea, 3 votes")
        XCTAssertEqual(VoteCountHead.spoken(.nay, count: 1), "Nay, 1 vote")
        let head = try XCTUnwrap(ImageRenderer(content: VoteCountHead(choice: .yea, count: 3).fixedSize()).cgImage)
        let labelLine = try XCTUnwrap(ImageRenderer(content: Text("Yea (3)").textRole(.label).fixedSize()).cgImage)
        XCTAssertEqual(head.height, labelLine.height, "the head is a `label` line")

        let bar = try XCTUnwrap(ImageRenderer(content: TallySplitBar(yea: 3, nay: 1).frame(width: 202)).cgImage)
        XCTAssertEqual(bar.height, Int(TallySplitBar.height), "no tick, no room for one")
    }

    /// The streak chip's Large Content Viewer shows the tally marks, not only "4-day streak" (spec 3.23:
    /// `HeaderMetricBadge`'s viewer stays). The viewer takes a picture only from an `Image`, so the chip
    /// hands it this template image: 68 pt like the star symbol the score chip gives it, with the four
    /// uprights inked and the gaps between them clear.
    func testTheStreakChipGivesTheLargeContentViewerItsTallyMarks() throws {
        let image = StreakTrailingBadge.largeContentImage
        XCTAssertEqual(image.renderingMode, .alwaysTemplate, "tinted by the viewer like a symbol")
        XCTAssertEqual(image.size, CGSize(width: 68, height: 68))
        let cgImage = try XCTUnwrap(image.cgImage)
        let unit = 68.0 / 24
        func alpha(atUnit x: Double, _ y: Double) throws -> Double {
            try alphaValue(of: cgImage, x: Int(x * unit * image.scale), y: Int(y * unit * image.scale))
        }
        for x in [5.5, 9.5, 13.5, 17.5] {
            XCTAssertGreaterThan(try alpha(atUnit: x, 8), 0.9, "an upright at \(x)")
        }
        for x in [7.5, 11.5, 15.5] {
            XCTAssertEqual(try alpha(atUnit: x, 8), 0, accuracy: 0.01, "a gap at \(x)")
        }
        XCTAssertGreaterThan(try alpha(atUnit: 11.5, 12), 0.9, "the diagonal")
    }

    /// The alpha of one pixel, 0 to 1.
    private func alphaValue(of image: CGImage, x: Int, y: Int) throws -> Double {
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        return Double(bytes[3]) / 255
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "FoundationComponentRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        return defaults
    }

    /// Every pixel of `image` in sRGB, row by row.
    private func allPixels(of image: CGImage) throws -> [(red: Double, green: Double, blue: Double)] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        return stride(from: 0, to: bytes.count, by: 4).map {
            (red: Double(bytes[$0]) / 255, green: Double(bytes[$0 + 1]) / 255, blue: Double(bytes[$0 + 2]) / 255)
        }
    }

    // MARK: - Button Shapes outline (Civic Record spec 3.16)

    /// With Button Shapes on, a text-only control gets a 1 pt `controlRule` capsule 5 pt outside the
    /// label on each side (10 pt wider) and an underline; off, it draws nothing extra.
    func testTheButtonShapeOutlineDrawsACapsuleAroundTheLabel() throws {
        func label(_ isOn: Bool) -> some View {
            Text("Clear all")
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .modifier(ButtonShapeOutline(isOn: isOn))
                .padding(12)
                .background(BillboardColors.background)
        }
        for scheme in [ColorScheme.light, .dark] {
            let variant = Variant(scheme: scheme, size: .large)
            let on = try render(label(true), variant: variant, width: 200)
            let off = try render(label(false), variant: variant, width: 200)
            attach(on, name: "button-shape-outline-\(scheme == .dark ? "dark" : "light")")
            XCTAssertEqual(on.height, off.height, "the outline does not change the layout")
            XCTAssertNotEqual(on.dataProvider?.data as Data?, off.dataProvider?.data as Data?, "Button Shapes draws something")

            // The label is centred in 200 pt; the capsule's middle-left is 5 pt left of the label.
            let paper = BillboardPalette.background.resolved(dark: scheme == .dark).rgb
            let rule = BillboardPalette.controlRule.resolved(dark: scheme == .dark)
            let edge = try leftmostNonGround(in: on, row: on.height / 2, ground: paper)
            let labelEdge = try leftmostNonGround(in: off, row: off.height / 2, ground: paper)
            XCTAssertLessThan(edge, labelEdge, "the capsule sits outside the label")
            XCTAssertEqual(labelEdge - edge, 5, accuracy: 3, "about 5 pt outside the label")
            assertColor(
                try pixel(of: on, x: edge, y: on.height / 2),
                BillboardColorMath.composite(rule.rgb, alpha: rule.alpha, over: paper),
                accuracy: 0.08,
                "the capsule is controlRule \(scheme)"
            )
        }
    }

    private func leftmostNonGround(in image: CGImage, row: Int, ground: BillboardColorMath.RGB) throws -> Int {
        for x in 0..<image.width {
            let sample = try pixel(of: image, x: x, y: row)
            if abs(sample.red - ground.red) + abs(sample.green - ground.green) + abs(sample.blue - ground.blue) > 0.05 {
                return x
            }
        }
        return image.width
    }

    private func luminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    private func assertColor(
        _ sample: (red: Double, green: Double, blue: Double),
        _ expected: BillboardColorMath.RGB,
        accuracy: Double = 0.02,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sample.red, expected.red, accuracy: accuracy, "red: \(message)", file: file, line: line)
        XCTAssertEqual(sample.green, expected.green, accuracy: accuracy, "green: \(message)", file: file, line: line)
        XCTAssertEqual(sample.blue, expected.blue, accuracy: accuracy, "blue: \(message)", file: file, line: line)
    }

    // MARK: - Civic Record components (spec 3, 9.2 slice 3)

    /// A render condition for the Civic Record components: appearance, text size, and the Button Shapes,
    /// Reduce Transparency and Increase Contrast settings (set through SwiftUI's underscored environment
    /// values, which the public ones read).
    private struct Look: Hashable {
        var scheme: ColorScheme = .light
        var size: DynamicTypeSize = .large
        var buttonShapes = false
        var reduceTransparency = false
        var increaseContrast = false

        var dark: Bool { scheme == .dark }

        var name: String {
            var parts = [dark ? "dark" : "light"]
            switch size {
            case .large: parts.append("default")
            case .accessibility3: parts.append("AX3")
            case .accessibility5: parts.append("AX5")
            default: parts.append("\(size)")
            }
            if buttonShapes { parts.append("shapes") }
            if reduceTransparency { parts.append("reduce-transparency") }
            if increaseContrast { parts.append("increase-contrast") }
            return parts.joined(separator: "-")
        }

        static let light = Look()
        static let dark = Look(scheme: .dark)
    }

    /// Light and dark at the default size, AX3 and AX5 (spec 10.1: AX5 for the components).
    private static let componentLooks: [Look] = [
        Look(scheme: .light, size: .large), Look(scheme: .dark, size: .large),
        Look(scheme: .light, size: .accessibility3), Look(scheme: .dark, size: .accessibility3),
        Look(scheme: .light, size: .accessibility5), Look(scheme: .dark, size: .accessibility5)
    ]

    /// The component looks with Button Shapes off and on.
    private static let buttonShapeLooks: [Look] = componentLooks + componentLooks.map {
        var look = $0
        look.buttonShapes = true
        return look
    }

    /// Draws `view` at its ideal height. Without `fixedSize`, `ImageRenderer` lays out anything taller than
    /// the screen (874 pt here) in the screen's height, squeezed and centred, and leaves the rest of the
    /// image transparent: AX5 samples are taller than that.
    private func draw<Content: View>(_ view: Content, _ look: Look, width: CGFloat?, scale: CGFloat = 1) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, look.scheme)
                .environment(\.dynamicTypeSize, look.size)
                .environment(\._accessibilityShowButtonShapes, look.buttonShapes)
                .environment(\._accessibilityReduceTransparency, look.reduceTransparency)
                .environment(\._colorSchemeContrast, look.increaseContrast ? .increased : .standard)
        )
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(look.name)")
    }

    /// Draws `view` in every look at 2x for review, attaches each image, and returns them by look.
    @discardableResult
    private func drawForReview<Content: View>(
        _ name: String,
        width: CGFloat?,
        looks: [Look]? = nil,
        ground: Color? = nil,
        @ViewBuilder _ view: () -> Content
    ) throws -> [Look: CGImage] {
        let looks = looks ?? Self.componentLooks
        let ground = ground ?? BillboardColors.background
        var images: [Look: CGImage] = [:]
        let content = view()
        for look in looks {
            let image = try draw(content.padding(16).background(ground), look, width: width, scale: 2)
            attach(image, name: "\(name)-\(look.name)")
            images[look] = image
        }
        return images
    }

    /// The colour a token draws in a look, composited over `ground` when it has alpha.
    private func tokenColor(
        _ token: BillboardColorToken,
        _ look: Look,
        over ground: BillboardColorToken = BillboardPalette.cardBackground
    ) -> BillboardColorMath.RGB {
        let value = token.resolved(dark: look.dark, highContrast: look.increaseContrast)
        let base = ground.resolved(dark: look.dark, highContrast: look.increaseContrast).rgb
        return BillboardColorMath.composite(value.rgb, alpha: value.alpha, over: base)
    }

    private func height(of image: CGImage, scale: CGFloat = 1) -> CGFloat {
        CGFloat(image.height) / scale
    }

    private func width(of image: CGImage, scale: CGFloat = 1) -> CGFloat {
        CGFloat(image.width) / scale
    }

    /// A solid-colour image, for a monogram's photo.
    private func solidImage(red: Double, green: Double, blue: Double) -> Image {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor(red: red, green: green, blue: blue, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return Image(uiImage: image)
    }

    // MARK: Stamps (spec 3.2)

    private static let allStamps: [StatusStamp.Kind] = [
        .new, .updated, .passed, .failed, .becameLaw, .verified, .notVerified, .sealed, .unread,
        .allCaughtUp, .nothingYet, .notFound, .couldNotLoad, .companionLead(number: "S. 456", status: .passed)
    ]

    func testStampsRenderEveryKindInEveryLook() throws {
        let images = try drawForReview("stamps", width: 390, ground: BillboardColors.cardBackground) {
            FlowLayout(spacing: 10) {
                ForEach(Array(Self.allStamps.enumerated()), id: \.offset) { _, kind in
                    StatusStamp(kind)
                }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(images[Look(size: .accessibility5)]).height, try XCTUnwrap(images[.light]).height)

        for look in [Look.light, Look(size: .accessibility5)] {
            let single = try draw(StatusStamp(.new), look, width: nil)
            let double = try draw(StatusStamp(.becameLaw), look, width: nil)
            if look.size == .large {
                XCTAssertEqual(single.height, 20, "a stamp is 20 pt at the default size")
                XCTAssertEqual(double.height, 22, "a double-ruled stamp is 22 pt")
            } else {
                XCTAssertGreaterThan(single.height, 40, "the stamp scales at AX5")
            }
        }
    }

    /// Every stamp's rule is its token, normal and under Increase Contrast, light and dark; the fill is
    /// the sheet beneath (no fill of its own). Drawn at 2x so the rules cover whole pixels.
    func testStampRulesAreTheirTokensAndTheFillIsClear() throws {
        let looks = [Look.light, Look.dark, Look(increaseContrast: true), Look(scheme: .dark, increaseContrast: true)]
        for look in looks {
            let sheet = tokenColor(BillboardPalette.cardBackground, look)
            for kind in Self.allStamps {
                let image = try draw(StatusStamp(kind).padding(4).background(BillboardColors.cardBackground), look, width: nil, scale: 2)
                let middle = image.height / 2
                let color = tokenColor(kind.paletteToken, look)
                let message = "\(kind.word) \(look.name)"
                assertColor(try pixel(of: image, x: 8, y: middle), color, accuracy: 0.03, "outer rule: \(message)")
                if kind.isDoubleRuled {
                    assertColor(try pixel(of: image, x: 11, y: middle), sheet, accuracy: 0.03, "the gap: \(message)")
                    assertColor(try pixel(of: image, x: 13, y: middle), color, accuracy: 0.03, "inner rule: \(message)")
                    assertColor(try pixel(of: image, x: 17, y: middle), sheet, accuracy: 0.03, "no fill: \(message)")
                } else {
                    assertColor(try pixel(of: image, x: 12, y: middle), sheet, accuracy: 0.03, "no fill: \(message)")
                }
            }
        }
        // Increase Contrast lifts the status colours (spec 2.1).
        XCTAssertNotEqual(BillboardPalette.statusPassed.resolved(dark: false, highContrast: true), BillboardPalette.statusPassed.light)
    }

    func testStampsReadTheirWordsInSentenceCase() {
        XCTAssertEqual(StatusStamp.Kind(status: .finalized), .becameLaw)
        XCTAssertEqual(StatusStamp.Kind(status: .new), .new)
        XCTAssertEqual(StatusStamp.Kind.becameLaw.word, "Became law")
        XCTAssertTrue(StatusStamp.Kind.becameLaw.isDoubleRuled)
        XCTAssertTrue(StatusStamp.Kind.sealed.isDoubleRuled)
        XCTAssertFalse(StatusStamp.Kind.passed.isDoubleRuled)
        XCTAssertTrue(StatusStamp.Kind.companionLead(number: "S. 456", status: .finalized).isDoubleRuled)
        XCTAssertEqual(StatusStamp.Kind.companionLead(number: "S. 456", status: .passed).word, "S. 456 Passed")

        let strings = AccessibilityTreeText.strings(of: VStack {
            ForEach(Array(Self.allStamps.enumerated()), id: \.offset) { _, kind in
                StatusStamp(kind)
            }
        })
        for expected in ["New", "Updated", "Passed", "Failed", "Became law", "Verified", "Not verified", "Sealed", "Unread",
                         "All caught up", "Nothing yet", "Not found", "Couldn't load", "Senate bill 456 passed"] {
            XCTAssertTrue(strings.contains(expected), "\(expected) in \(strings)")
        }
        XCTAssertFalse(strings.contains("BECAME LAW"), "VoiceOver hears words, not capitals")
    }

    // MARK: Docket line (spec 3.1)

    func testDocketLinesRenderInEveryLook() throws {
        try drawForReview("docket-lines", width: 375, ground: BillboardColors.cardBackground) {
            VStack(alignment: .leading, spacing: 14) {
                DocketLine(number: "H.R. 1234", status: .new)
                DocketLine(number: "S. 88", status: .updated, isWatched: true)
                DocketLine(numbers: ["H.R. 10", "S. 10"], chamber: nil, status: .passed, companionLead: "S. 10")
                DocketLine(number: "H.J.Res. 77", status: .finalized, companions: .init(["S.J.Res. 21"]))
                DocketLine(number: "S. 456", status: .failed)
            }
        }
    }

    /// One line at the default size; at AX5 the stamp goes onto its own line under the numbers.
    func testTheDocketStampStacksAtAccessibilitySizes() throws {
        for look in [Look.light, Look(size: .accessibility5)] {
            let withStamp = try draw(DocketLine(number: "H.R. 1234", status: .new), look, width: 343)
            let numbersOnly = try draw(DocketLine(number: "H.R. 1234", status: nil), look, width: 343)
            let stamp = try draw(StatusStamp(.new), look, width: nil)
            if look.size == .large {
                XCTAssertLessThan(withStamp.height, numbersOnly.height + stamp.height, "one line at the default size")
                XCTAssertEqual(withStamp.height, stamp.height, "the stamp sets the line's height")
            } else {
                XCTAssertGreaterThanOrEqual(withStamp.height, numbersOnly.height + stamp.height, "stacked at AX5")
            }
        }
        // A companion pair with a long lead stacks when it does not fit at 375 pt.
        let narrow = try draw(
            DocketLine(numbers: ["H.Con.Res. 1001", "S.Con.Res. 1002"], chamber: nil, status: .finalized, companionLead: "S.Con.Res. 1002"),
            .light,
            width: 260
        )
        XCTAssertGreaterThan(narrow.height, 30, "stacked when the line does not fit")
    }

    func testTheDocketLineIsOneSpokenElement() {
        XCTAssertEqual(DocketLine(number: "H.R. 1234", status: .new).accessibilityText, "House bill 1234. New.")
        XCTAssertEqual(DocketLine(number: "S. 88", status: .updated, isWatched: true).accessibilityText, "Senate bill 88. Updated. Watching.")
        XCTAssertEqual(DocketLine(number: "S. 88", status: .new, isWatched: true).accessibilityText, "Senate bill 88. New.", "the mark shows only on Updated")
        XCTAssertEqual(
            DocketLine(numbers: ["H.R. 10", "S. 10"], chamber: nil, status: .passed, companionLead: "S. 10").accessibilityText,
            "House bill 10 and Senate bill 10. Senate bill 10 passed."
        )
        // The companions' numbers are spoken too (spec 1.7); the printed line keeps the codes.
        let identical = DocketLine(number: "H.R. 77", status: .finalized, companions: .init(["H.R. 900"]))
        XCTAssertEqual(identical.accessibilityText, "House bill 77. Became law. Identical to House bill 900.")
        XCTAssertEqual(identical.companions?.printed, "Identical to H.R. 900")
        XCTAssertEqual(
            DocketLine(number: "S. 5", status: .new, companions: .init(["H.R. 900", "S.J.Res. 21"], isIdentical: false)).accessibilityText,
            "Senate bill 5. New. Companion to House bill 900 and Senate joint resolution 21."
        )
        XCTAssertEqual(DocketLine.chamber(forBillNumber: "H.R. 1"), .house)
        XCTAssertEqual(DocketLine.chamber(forBillNumber: "H.Con.Res. 3"), .house)
        XCTAssertEqual(DocketLine.chamber(forBillNumber: "S.J.Res. 21"), .senate)
        XCTAssertNil(DocketLine.chamber(forBillNumber: "Clean Energy Act"))

        let strings = AccessibilityTreeText.strings(of: DocketLine(number: "H.R. 1234", status: .new))
        XCTAssertEqual(strings, ["House bill 1234. New."], "the stamp is merged into the line")
    }

    // MARK: Index tags and selectable tags (spec 3.3)

    func testTagsRenderInEveryLook() throws {
        let images = try drawForReview("tags", width: 390, ground: BillboardColors.cardBackground) {
            VStack(alignment: .leading, spacing: 12) {
                FlowLayout(spacing: 6) {
                    IndexTag(.inTheNews)
                    IndexTag(.memberYouFollow)
                    IndexTag(.topic("Healthcare"))
                    IndexTag(.lifeArea("Housing"))
                    IndexTag(.identicalBills)
                }
                FlowLayout(spacing: 8) {
                    SelectableTag(title: "Energy", isSelected: false) {}
                    SelectableTag(title: "Housing", isSelected: true) {}
                }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(images[Look(size: .accessibility5)]).height, try XCTUnwrap(images[.light]).height)

        let tag = try draw(IndexTag(.topic("Energy")), .light, width: nil)
        XCTAssertEqual(tag.height, 22, "an index tag is 22 pt at the default size")
        let selectable = try draw(SelectableTag(title: "Energy", isSelected: false) {}, .light, width: nil)
        XCTAssertEqual(selectable.height, 34, "a selectable tag is 34 pt (its hit area is 44)")
    }

    /// At accessibility sizes a tag's word stays whole in a phone-wide column (343 pt): sentence case with
    /// no tracking, the glyph above the word when the two do not fit on one line. In capitals with the
    /// tracking, HEALTHCARE broke as HEALTHCAR/E at AX5 on Profile and on bill cards. The words are the
    /// longest single words among Billboard's topics and life areas; "Telecommunications" fits at AX3 and
    /// wraps only at AX5, where it is wider than the column itself (tags never shrink, spec 7.2).
    func testLongTagWordsStayWholeAtAccessibilitySizes() throws {
        let words = ["Healthcare", "Infrastructure", "Transportation", "Constitutional", "Accountability", "Globalization", "Institutional"]
        for size in [DynamicTypeSize.accessibility3, .accessibility5] {
            for word in words + (size == .accessibility3 ? ["Telecommunications"] : []) {
                for tag in [IndexTag(.topic(word)), IndexTag(title: word, systemImage: nil)] {
                    XCTAssertEqual(try lines(of: tag, Look(size: size), width: 343), 1, "\(word) at \(size), glyph \(tag.kind.systemImage ?? "none")")
                }
            }
        }
        XCTAssertEqual(
            try lines(of: IndexTag(.topic("Telecommunications")), Look(size: .accessibility5), width: 343), 2,
            "wider than the column at AX5: it wraps and never shrinks"
        )
        XCTAssertEqual(IndexTag.wordRole(at: .large), .tagLabel, "capitals and tracking at the default size")
        XCTAssertEqual(IndexTag.wordRole(at: .xxxLarge), .tagLabel)
        XCTAssertEqual(IndexTag.wordRole(at: .accessibility1), .smallCaption, "sentence case, no tracking")
        XCTAssertFalse(TextRole.smallCaption.isUppercase)
        XCTAssertEqual(TextRole.smallCaption.trackingEm, 0)
        XCTAssertEqual(TextRole.smallCaption.size, TextRole.tagLabel.size, "the same size and face as the tag label")
        XCTAssertEqual(TextRole.smallCaption.face, TextRole.tagLabel.face)
        XCTAssertEqual(TextRole.smallCaption.weight, TextRole.tagLabel.weight)
    }

    /// How many lines the one text in `view` is finally set in, read through a `TextRenderer` while the
    /// view is drawn. `ImageRenderer` draws the text more than once (a first pass sets it one character a
    /// line); the last drawing is the one in the image.
    private func lines(of view: some View, _ look: Look, width: CGFloat) throws -> Int? {
        let recorder = TextLineRecorder()
        _ = try draw(view.textRenderer(TextLineRecorder.Renderer(recorder: recorder)), look, width: width)
        return recorder.lines.last
    }

    private final class TextLineRecorder: @unchecked Sendable {
        var lines: [Int] = []

        struct Renderer: TextRenderer {
            let recorder: TextLineRecorder

            func draw(layout: Text.Layout, in context: inout GraphicsContext) {
                recorder.lines.append(layout.count)
                for line in layout {
                    context.draw(line)
                }
            }
        }
    }

    /// Index tags have a `rule2` border and no fill; a selected tag is filled with ink, an unselected one
    /// has a `controlRule` border and no fill. Drawn at 2x on the sheet.
    func testTagFillsAndBorders() throws {
        for look in [Look.light, Look.dark] {
            let sheet = tokenColor(BillboardPalette.cardBackground, look)
            func onSheet(_ view: some View) -> some View { view.padding(4).background(BillboardColors.cardBackground) }

            let tag = try draw(onSheet(IndexTag(.lifeArea("Housing"))), look, width: nil, scale: 2)
            assertColor(try pixel(of: tag, x: 8, y: tag.height / 2), tokenColor(BillboardPalette.rule2, look), accuracy: 0.03, "tag border \(look.name)")
            assertColor(try pixel(of: tag, x: 11, y: tag.height / 2), sheet, accuracy: 0.03, "tag has no fill \(look.name)")

            let selected = try draw(onSheet(SelectableTag(title: "Housing", isSelected: true) {}), look, width: nil, scale: 2)
            assertColor(try pixel(of: selected, x: 20, y: selected.height / 2), tokenColor(BillboardPalette.primaryText, look), accuracy: 0.03, "selected is ink \(look.name)")

            let unselected = try draw(onSheet(SelectableTag(title: "Energy", isSelected: false) {}), look, width: nil, scale: 2)
            assertColor(try pixel(of: unselected, x: 8, y: unselected.height / 2), tokenColor(BillboardPalette.controlRule, look), accuracy: 0.04, "unselected border \(look.name)")
            assertColor(try pixel(of: unselected, x: 20, y: unselected.height / 2), sheet, accuracy: 0.03, "unselected has no fill \(look.name)")
        }
    }

    /// The topic "Housing" and the life area "Housing" differ for VoiceOver by a spoken prefix; selection is
    /// a trait, not only a fill.
    func testTagsSayWhatKindTheyAre() {
        let strings = AccessibilityTreeText.strings(of: VStack {
            IndexTag(.inTheNews)
            IndexTag(.memberYouFollow)
            IndexTag(.topic("Housing"))
            IndexTag(.lifeArea("Housing"))
            IndexTag(.identicalBills)
        })
        XCTAssertEqual(strings, ["In the news", "Member you follow", "Topic: Housing", "Life area: Housing", "Identical bills"])
        XCTAssertEqual(IndexTag.outlineSymbol("newspaper.fill"), "newspaper")
        XCTAssertEqual(IndexTag.outlineSymbol("person.crop.circle.fill"), "person.crop.circle")

        let host = AccessibilityTreeText.Host(HStack {
            SelectableTag(title: "Energy", isSelected: false) {}
            SelectableTag(title: "Housing", isSelected: true) {}
        })
        defer { host.close() }
        XCTAssertEqual(host.traits(of: "Housing")?.contains(.selected), true)
        XCTAssertEqual(host.traits(of: "Energy")?.contains(.selected), false)
        XCTAssertEqual(host.traits(of: "Energy")?.contains(.button), true)
    }

    // MARK: Section headers and record sections (spec 3.5)

    func testSectionHeadersRenderInEveryLookWithAndWithoutButtonShapes() throws {
        try drawForReview("section-headers", width: 375, looks: Self.buttonShapeLooks) {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader("Your representatives", trailing: .district("VA-11"))
                SectionHeader("Recent actions", trailing: .button("Clear all") {})
                SectionHeader("Members you follow", trailing: .counter("3"))
                SectionHeader("How Congress works")
            }
        }
        for look in [Look.light, Look.dark] {
            let off = try draw(SectionHeader("Recent actions", trailing: .button("Clear all") {}).background(BillboardColors.background), look, width: 343)
            var shapesLook = look
            shapesLook.buttonShapes = true
            let on = try draw(SectionHeader("Recent actions", trailing: .button("Clear all") {}).background(BillboardColors.background), shapesLook, width: 343)
            XCTAssertEqual(on.height, off.height, "Button Shapes does not change the layout \(look.name)")
            XCTAssertNotEqual(on.dataProvider?.data as Data?, off.dataProvider?.data as Data?, "Button Shapes outlines Clear all \(look.name)")

            // The 2 pt ink rule on top.
            let header = try draw(SectionHeader("Results").background(BillboardColors.background), look, width: 343)
            let ink = tokenColor(BillboardPalette.ruleHeavy, look)
            assertColor(try pixel(of: header, x: 170, y: 0), ink, "rule row 1 \(look.name)")
            assertColor(try pixel(of: header, x: 170, y: 1), ink, "rule row 2 \(look.name)")
            assertColor(try pixel(of: header, x: 170, y: 3), tokenColor(BillboardPalette.background, look), "8 pt gap \(look.name)")
        }
    }

    /// At accessibility sizes the counter wraps under the title; at the default size it shares the line.
    func testSectionHeaderCountersWrapAtAccessibilitySizes() throws {
        for look in [Look.light, Look(size: .accessibility5)] {
            let titled = try draw(SectionHeader("Your representatives"), look, width: 343)
            let counted = try draw(SectionHeader("Your representatives", trailing: .district("VA-11")), look, width: 343)
            if look.size == .large {
                XCTAssertEqual(counted.height, titled.height, "one line at the default size")
            } else {
                XCTAssertGreaterThan(counted.height, titled.height + 30, "the counter wraps under the title at AX5")
            }
        }
    }

    func testSectionHeadersSpeakTheirCounters() {
        XCTAssertEqual(SectionHeader("Your representatives", trailing: .district("VA-11")).headerLabel, "Your representatives, Virginia's 11th district")
        XCTAssertEqual(SectionHeader("Members", trailing: .counter("3", spoken: "3 members")).headerLabel, "Members, 3 members")
        XCTAssertEqual(SectionHeader("Topics", trailing: .counter("3")).headerLabel, "Topics, 3")

        let host = AccessibilityTreeText.Host(VStack {
            SectionHeader("Your representatives", trailing: .district("VA-11"))
            SectionHeader("Recent actions", trailing: .button("Clear all", accessibilityIdentifier: "updates.clearAll") {})
        })
        defer { host.close() }
        XCTAssertEqual(host.traits(of: "Your representatives, Virginia's 11th district")?.contains(.header), true)
        XCTAssertEqual(host.traits(of: "Recent actions")?.contains(.header), true)
        XCTAssertEqual(host.traits(of: "Clear all")?.contains(.button), true, "the button is its own element")
    }

    /// Updates' Clear buttons are the header's trailing button (spec 3.5), not a button beside an R2
    /// header: the rule spans the whole width, the button sits on the title's line, and it says what it
    /// clears, keeping the word as a Voice Control input label and its identifier.
    func testAClearButtonInAHeaderKeepsTheRuleFullWidthAndSaysWhatItClears() throws {
        func header() -> SectionHeader {
            SectionHeader(
                "Passed bills",
                trailing: .button("Clear all", accessibilityLabel: "Clear all passed bills", accessibilityIdentifier: "updates.passed.clearAll") {}
            )
        }
        for look in [Look.light, Look.dark] {
            let image = try draw(header().background(BillboardColors.background), look, width: 343)
            let ink = tokenColor(BillboardPalette.ruleHeavy, look)
            for x in [1, 170, 341] {
                assertColor(try pixel(of: image, x: x, y: 1), ink, "the rule at x \(x) \(look.name)")
            }
            let titleOnly = try draw(SectionHeader("Passed bills").background(BillboardColors.background), look, width: 343)
            XCTAssertLessThanOrEqual(image.height, titleOnly.height + 14, "the button shares the title's line \(look.name)")
        }

        let host = AccessibilityTreeText.Host(header())
        defer { host.close() }
        XCTAssertEqual(host.traits(of: "Clear all passed bills")?.contains(.button), true, host.text())
        XCTAssertEqual(host.traits(of: "Passed bills")?.contains(.header), true, host.text())
        XCTAssertFalse(host.strings().contains("Clear all"), "read with what it clears: \(host.text())")
    }

    func testRecordSectionsRenderInEveryLook() throws {
        try drawForReview("record-sections", width: 375, ground: BillboardColors.document) {
            VStack(spacing: 0) {
                DoubleRule().padding(.horizontal, 20)
                RecordSection("Why it matters", showsRule: false) {
                    Text("A yearly public report on how the grant program spends its money.")
                        .textRole(.lead)
                        .foregroundStyle(BillboardColors.primaryText)
                }
                RecordSection("Sponsor") {
                    Text("Rep. Jordan Ellis").textRole(.name).foregroundStyle(BillboardColors.primaryText)
                }
            }
        }
        for look in [Look.light, Look.dark] {
            let document = tokenColor(BillboardPalette.document, look, over: BillboardPalette.document)
            let ruled = try draw(RecordSection("Sponsor") { Text("Jordan Ellis") }.background(BillboardColors.document), look, width: 375)
            assertColor(try pixel(of: ruled, x: 187, y: 0), tokenColor(BillboardPalette.separator, look, over: BillboardPalette.document), "hairline on top \(look.name)")
            assertColor(try pixel(of: ruled, x: 10, y: 0), document, "the hairline sits in the 20 pt gutter \(look.name)")
            let first = try draw(RecordSection("Sponsor", showsRule: false) { Text("Jordan Ellis") }.background(BillboardColors.document), look, width: 375)
            assertColor(try pixel(of: first, x: 187, y: 0), document, "no hairline after the double rule \(look.name)")
            XCTAssertEqual(ruled.height, first.height + 1)
        }
        let host = AccessibilityTreeText.Host(RecordSection("Sponsor") { Text("Jordan Ellis") })
        defer { host.close() }
        XCTAssertEqual(host.traits(of: "Sponsor")?.contains(.header), true)
    }

    // MARK: Ledger (spec 3.6)

    private static let breakdownRows: [Ledger.Row] = [
        .init("Who", "The Department of Energy would write the report. Congress and the public would read it."),
        .init("What", "A yearly public report on clean energy grants."),
        .init("When", "Starts in fiscal year 2027.")
    ]

    func testLedgersRenderInEveryLook() throws {
        let images = try drawForReview("ledger", width: 375, ground: BillboardColors.document) {
            VStack(alignment: .leading, spacing: 24) {
                Ledger(rows: Self.breakdownRows, column: .breakdown, answerRole: .prose)
                Ledger(
                    rows: [
                        .init("Feb 10", "Passed House", detail: "Floor action"),
                        .init("Jan 16", "Referred to the Committee on Energy and Commerce", detail: "Referral")
                    ],
                    column: .dates
                )
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(images[Look(size: .accessibility5)]).height, try XCTUnwrap(images[.light]).height)
    }

    /// Label beside the answer when the column fits in 30% of the row; above it in a narrow row and at
    /// every accessibility size.
    func testLedgerRowsStackWhenTheLabelColumnIsTooWide() throws {
        let layout = LedgerRowLayout(labelWidth: 62)
        XCTAssertFalse(layout.stacks(in: 335))
        XCTAssertFalse(layout.stacks(in: 207))
        XCTAssertTrue(layout.stacks(in: 200))
        XCTAssertTrue(LedgerRowLayout(labelWidth: 62, alwaysStacks: true).stacks(in: 1000))

        let row = Ledger(rows: [.init("Who", "The Department of Energy.")], column: .breakdown, answerRole: .prose)
        let wide = try draw(row, .light, width: 335)
        let narrow = try draw(row, .light, width: 180)
        XCTAssertGreaterThan(narrow.height, wide.height + 10, "the label goes above the answer in a narrow row")

        let large = try draw(row, Look(size: .accessibility5), width: 335)
        let answerOnly = try draw(Text("The Department of Energy.").textRole(.prose).frame(width: 335, alignment: .leading), Look(size: .accessibility5), width: 335)
        XCTAssertGreaterThan(large.height, answerOnly.height + 30, "the label goes above the answer at AX5")
    }

    func testEachLedgerRowIsOneSpokenElement() {
        XCTAssertEqual(Self.breakdownRows[2].accessibilityLabel, "When: Starts in fiscal year 2027.")
        XCTAssertEqual(Ledger.Row("Feb 10", "Passed House", detail: "Floor action").accessibilityLabel, "Feb 10: Passed House Floor action")
        let strings = AccessibilityTreeText.strings(of: Ledger(rows: Self.breakdownRows, column: .breakdown, answerRole: .prose))
        XCTAssertEqual(strings, Self.breakdownRows.map(\.accessibilityLabel))
    }

    /// Labels repeat in the ledgers spec 3.6 reuses: two House committees, two actions on one day. Every
    /// row still shows, in order. Keyed by its label, the second House row was dropped.
    func testLedgerRowsThatShareALabelAllShow() {
        let committees: [Ledger.Row] = [
            .init("House", "Energy and Commerce"),
            .init("House", "Ways and Means"),
            .init("Senate", "Finance")
        ]
        XCTAssertEqual(AccessibilityTreeText.strings(of: Ledger(rows: committees)), committees.map(\.accessibilityLabel))

        let actions: [Ledger.Row] = [
            .init("Feb 10", "Introduced in House"),
            .init("Feb 10", "Referred to the Committee on Ways and Means"),
            .init("Feb 12", "Passed House")
        ]
        XCTAssertEqual(AccessibilityTreeText.strings(of: Ledger(rows: actions, column: .dates)), actions.map(\.accessibilityLabel))
    }

    // MARK: Monograms and the party disc (spec 3.14)

    func testMonogramsRenderInEveryLook() throws {
        try drawForReview("monograms", width: 420, ground: BillboardColors.cardBackground) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 18) {
                    MemberMonogram(name: "Jordan Ellis", size: .stub, party: .republican)
                    MemberMonogram(name: "Bernie Sanders", size: .row, party: .independent)
                    MemberMonogram(name: "Sen. Tim Kaine", size: .roll, party: .democratic)
                    MemberMonogram(name: "Angus King", size: .profile)
                    MemberMonogram(name: "Sen. Mark R. Warner", size: .page, party: .democratic)
                }
                HStack(alignment: .bottom, spacing: 18) {
                    MemberMonogram(name: "Jordan Ellis", size: .roll, party: .republican, photo: solidImage(red: 0.55, green: 0.45, blue: 0.35))
                    MemberMonogram(name: "reader42", size: .profile)
                    HStack(spacing: 8) {
                        ForEach(PoliticalParty.allCases) { party in
                            PartyBadge(party: party, size: .small)
                            PartyBadge(party: party, size: .regular)
                        }
                    }
                }
            }
        }
    }

    func testMonogramSizesScaleWithText() throws {
        for size in MemberMonogram.Size.allCases {
            let image = try draw(MemberMonogram(name: "Tim Kaine", size: size), .light, width: nil)
            XCTAssertEqual(CGFloat(image.width), size.diameter, "\(size)")
            XCTAssertEqual(image.width, image.height)
            let large = try draw(MemberMonogram(name: "Tim Kaine", size: size), Look(size: .accessibility3), width: nil)
            XCTAssertGreaterThan(large.width, image.width, "\(size) grows at AX3")
        }
        XCTAssertEqual([12, 14, 14, 19, 20, 24], MemberMonogram.Size.allCases.map(\.discDiameter))
        XCTAssertEqual(MemberMonogram.Size.settings.diameter, 34, "the Settings header (spec 4.68)")
    }

    /// Monograms grow on the spec's `.title3` curve (spec 3.14), the member photo (`CongressMemberAvatar`)
    /// too. Every row that shows one stacks at accessibility sizes (the member rows, the Profile and Settings
    /// headers, the bill page's sponsor), so R2's gentler `.largeTitle` curve, once kept for rows that did not,
    /// is gone with the parameter that chose it.
    func testMonogramsGrowOnTheSpecsTitle3Curve() throws {
        let ax5 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        for size in MemberMonogram.Size.allCases {
            let spec = try draw(MemberMonogram(name: "Tim Kaine", size: size), Look(size: .accessibility5), width: nil)
            let specDiameter = UIFontMetrics(forTextStyle: .title3).scaledValue(for: size.diameter, compatibleWith: ax5)
            XCTAssertEqual(CGFloat(spec.width), specDiameter, accuracy: 1, "\(size) on the spec's curve")
        }
        let avatar = try draw(CongressMemberAvatar(url: nil, name: "Tim Kaine", size: .roll), Look(size: .accessibility5), width: nil)
        XCTAssertEqual(CGFloat(avatar.width), UIFontMetrics(forTextStyle: .title3).scaledValue(for: 44, compatibleWith: ax5), accuracy: 1)
    }

    /// The well with its ring, the party disc in the party colour on a ring of the ground, and a photo in
    /// place of the initials. 72 pt, drawn at 1x with 12 pt around it for the disc.
    func testMonogramFillRingsDiscAndPhoto() throws {
        for look in [Look.light, Look.dark] {
            func onSheet(_ view: some View) -> some View { view.padding(12).background(BillboardColors.cardBackground) }
            let image = try draw(onSheet(MemberMonogram(name: "Mark Warner", size: .page, party: .democratic)), look, width: nil)
            let well = tokenColor(BillboardPalette.secondaryBackground, look)
            assertColor(try pixel(of: image, x: 12 + 11, y: 12 + 36), well, accuracy: 0.03, "well between the rings and the initials \(look.name)")
            assertColor(try pixel(of: image, x: 12, y: 12 + 36), tokenColor(BillboardPalette.rule2, look, over: BillboardPalette.secondaryBackground), accuracy: 0.05, "outer ring \(look.name)")

            // The disc: 24 pt, its centre 12 pt in from the monogram's corner plus the 0.22 overhang.
            let centre = 12 + 72 - 12 + Int((24 * MemberMonogram.discOverhang).rounded())
            assertColor(try pixel(of: image, x: centre - 8, y: centre), tokenColor(BillboardPalette.partyDemocratic, look), accuracy: 0.03, "disc \(look.name)")
            assertColor(try pixel(of: image, x: centre - 13, y: centre), tokenColor(BillboardPalette.cardBackground, look), accuracy: 0.04, "ring of the ground \(look.name)")

            let photo = try draw(onSheet(MemberMonogram(name: "Mark Warner", size: .page, photo: solidImage(red: 0.6, green: 0.2, blue: 0.1))), look, width: nil)
            assertColor(try pixel(of: photo, x: 12 + 36, y: 12 + 36), (red: 0.6, green: 0.2, blue: 0.1), accuracy: 0.03, "the photo replaces the initials \(look.name)")
        }
    }

    func testMonogramInitials() {
        let cases: [(String, String)] = [
            ("Sen. Mark R. Warner", "MW"),
            ("Mark R. Warner", "MW"),
            ("Kaine, Tim", "TK"),
            ("Kaine, Tim, Jr.", "TK"),
            ("Jordan Ellis Jr.", "JE"),
            ("Jordan Ellis III", "JE"),
            ("Rep. Alexandria Ocasio-Cortez", "AO"),
            ("Res. Comm. Pablo José Hernández Rivera", "PR"),
            ("Del. Eleanor Holmes Norton", "EN"),
            ("Chris Van Hollen", "CH"),
            ("J. D. Vance", "JV"),
            ("jordan.ellis", "JE"),
            ("reader42", "R"),
            ("Profile", "P"),
            ("", ""),
            ("  ", ""),
            ("4242", "")
        ]
        for (name, expected) in cases {
            XCTAssertEqual(MemberMonogram.initials(for: name), expected, name)
        }
    }

    /// The monogram is decoration: the row's label says the name and the party.
    func testTheMonogramIsHiddenFromVoiceOver() {
        let strings = AccessibilityTreeText.strings(of: HStack {
            MemberMonogram(name: "Tim Kaine", size: .roll, party: .democratic)
            Text("Sen. Tim Kaine")
        })
        XCTAssertEqual(strings, ["Sen. Tim Kaine"])
        XCTAssertEqual(AccessibilityTreeText.strings(of: PartyBadge(party: .independent)), ["Independent"], "a standalone badge reads the party")
    }

    /// Smart Invert leaves member photos as they are (spec 7.8). The setting cannot be turned on in a test
    /// and SwiftUI marks nothing in the view tree until it is, so this reads the monogram's body type, which
    /// names the modifier because the photo branch carries it.
    func testMemberPhotosAreLeftOutOfSmartInvert() {
        // The body's type, not its value: calling `body` outside a view hierarchy reads the environment
        // uninstalled, which SwiftUI reports as a runtime warning.
        let bodyType = String(reflecting: MemberMonogram.Body.self)
        XCTAssertTrue(bodyType.contains("AccessibilityIgnoresInvertColors"), bodyType)
    }

    /// `CongressMemberAvatar` without a photo is the member's monogram.
    func testTheMemberAvatarIsTheMonogram() throws {
        let avatar = try draw(CongressMemberAvatar(url: nil, name: "Tim Kaine", size: .roll), .light, width: nil)
        let monogram = try draw(MemberMonogram(name: "Tim Kaine", size: .roll), .light, width: nil)
        XCTAssertEqual(avatar.dataProvider?.data as Data?, monogram.dataProvider?.data as Data?)
    }

    // MARK: Buttons (spec 3.16)

    private struct ButtonSample: View {
        var isEnabled = true

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        /// Side by side, or one under the other at accessibility sizes, as screens lay buttons out.
        @ViewBuilder
        private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) { content() }
            } else {
                HStack(spacing: 12) { content() }
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                // The loading state's spinner is UIKit, which ImageRenderer cannot draw; its title is
                // checked in the accessibility tree instead.
                BBActionButton(title: "Sign in", action: {}, isEnabled: isEnabled)
                BBActionButton(
                    title: "Find my district",
                    action: {},
                    isEnabled: false,
                    disabledHint: "Add your street address, city, state and ZIP to continue."
                )
                row {
                    BBActionButton(title: "Choose topics", action: {}, isEnabled: isEnabled, kind: .secondary)
                    BBActionButton(title: "Change", action: {}, isEnabled: isEnabled, kind: .panelSecondary)
                }
                row {
                    BBActionButton(title: "Forgot password?", action: {}, isEnabled: isEnabled, kind: .textLink)
                    BBActionButton(title: "Clear all", action: {}, isEnabled: isEnabled, kind: .textButton)
                    BBActionButton(title: "Sign out", action: {}, isEnabled: isEnabled, kind: .destructive)
                }
                BBActionButton(title: "Delete account and data", action: {}, isEnabled: isEnabled, kind: .destructiveFill)
                row {
                    BillboardButtonBody(label: Text("Pressed"), kind: .primary, fullWidth: false, isPressed: true)
                    BillboardButtonBody(label: Text("Pressed"), kind: .textButton, isPressed: true)
                }
            }
        }
    }

    func testButtonsRenderInEveryLookWithAndWithoutButtonShapes() throws {
        let images = try drawForReview("buttons", width: 390, looks: Self.buttonShapeLooks) { ButtonSample() }
        try drawForReview("buttons-disabled", width: 390, looks: [.light, .dark]) { ButtonSample(isEnabled: false) }
        try drawForReview("button-on-navy", width: 300, looks: [.light, .dark], ground: BillboardColors.navy) {
            BBActionButton(title: "Try again", action: {}, kind: .primaryOnNavy, expandToMaxWidth: false)
        }
        for look in Self.componentLooks {
            var shapes = look
            shapes.buttonShapes = true
            let off = try XCTUnwrap(images[look])
            let on = try XCTUnwrap(images[shapes])
            XCTAssertEqual(on.height, off.height, "Button Shapes does not change the layout \(look.name)")
            XCTAssertNotEqual(on.dataProvider?.data as Data?, off.dataProvider?.data as Data?, "Button Shapes outlines the text buttons \(look.name)")
        }
    }

    /// Heights: primary 50, secondary and panel 44 at the default size, scaled with the text; primary
    /// spans the width, the others hug their label.
    func testButtonSizes() throws {
        func button(_ kind: BillboardButtonKind) -> some View {
            Button("Continue") {}.buttonStyle(BillboardButtonStyle(kind: kind))
        }
        let primary = try draw(button(.primary), .light, width: 300)
        XCTAssertEqual(primary.height, 50)
        XCTAssertEqual(primary.width, 300, "full width by default")
        let secondary = try draw(button(.secondary), .light, width: 300)
        XCTAssertEqual(secondary.height, 44)
        XCTAssertLessThan(secondary.width, 200)
        XCTAssertEqual(try draw(button(.panelSecondary), .light, width: 300).height, 44)
        // The launch screen's Try again on navy (spec 4.2).
        XCTAssertEqual(try draw(button(.primaryOnNavy), .light, width: 300).height, 44)
        XCTAssertEqual(try draw(button(.destructiveFill), .light, width: 300).height, 50)
        XCTAssertLessThan(try draw(button(.textButton), .light, width: 300).height, 30, "a text button keeps its text's height (its hit area is 44)")
        XCTAssertGreaterThan(try draw(button(.primary), Look(size: .accessibility3), width: 300).height, 60)
        // The capsule grows with its label (about 85 pt at AX5, spec 7.2), not 50 pt scaled to 138.
        let largest = try draw(button(.primary), Look(size: .accessibility5), width: 300).height
        XCTAssertGreaterThan(largest, 70)
        XCTAssertLessThan(largest, 100)
        XCTAssertEqual(
            try draw(Button("Done") {}.buttonStyle(BillboardButtonStyle(kind: .primary, minHeight: 52)), .light, width: 300).height,
            52,
            "an R2 call site's taller floor is kept"
        )
    }

    /// Each kind's colours (spec 3.16): primary ink, disabled well, destructive danger, secondary an ink
    /// rule with no fill, panel secondary an opaque sheet with a controlRule (2 pt with Increase Contrast).
    func testButtonChromeColours() throws {
        func button(_ kind: BillboardButtonKind, enabled: Bool = true) -> some View {
            Button("Continue") {}
                .buttonStyle(BillboardButtonStyle(kind: kind, fullWidth: true))
                .disabled(!enabled)
                .background(BillboardColors.background)
        }
        for look in [Look.light, Look.dark, Look(increaseContrast: true), Look(scheme: .dark, increaseContrast: true)] {
            let paper = tokenColor(BillboardPalette.background, look)
            let sheet = tokenColor(BillboardPalette.cardBackground, look)
            func sample(_ kind: BillboardButtonKind, enabled: Bool = true, x: Int) throws -> (red: Double, green: Double, blue: Double) {
                let image = try draw(button(kind, enabled: enabled), look, width: 300)
                return try pixel(of: image, x: x, y: image.height / 2)
            }
            assertColor(try sample(.primary, x: 30), tokenColor(BillboardPalette.interactive, look), "primary fill \(look.name)")
            assertColor(try sample(.primary, enabled: false, x: 30), tokenColor(BillboardPalette.secondaryBackground, look), "disabled fill \(look.name)")
            assertColor(try sample(.destructiveFill, x: 30), tokenColor(BillboardPalette.danger, look), "destructive fill \(look.name)")
            assertColor(try sample(.secondary, x: 0), tokenColor(BillboardPalette.interactive, look), accuracy: 0.04, "secondary rule \(look.name)")
            assertColor(try sample(.secondary, x: 4), paper, "secondary has no fill \(look.name)")
            assertColor(try sample(.panelSecondary, x: 0), tokenColor(BillboardPalette.controlRule, look), accuracy: 0.05, "panel rule \(look.name)")
            assertColor(
                try sample(.panelSecondary, x: 1),
                look.increaseContrast ? tokenColor(BillboardPalette.controlRule, look) : sheet,
                accuracy: 0.05,
                "panel rule is 2 pt only with Increase Contrast \(look.name)"
            )
            assertColor(try sample(.panelSecondary, x: 6), sheet, "panel fill is the opaque sheet \(look.name)")
        }
    }

    /// Capsules scale to 0.98 when pressed; text buttons fade to 0.6.
    func testButtonPresses() throws {
        let still = try draw(BillboardButtonBody(label: Text("Continue"), kind: .primary).background(BillboardColors.background), .light, width: 300)
        let pressed = try draw(BillboardButtonBody(label: Text("Continue"), kind: .primary, isPressed: true).background(BillboardColors.background), .light, width: 300)
        XCTAssertEqual(still.width, pressed.width)
        assertColor(try pixel(of: still, x: 1, y: still.height / 2), tokenColor(BillboardPalette.interactive, .light), accuracy: 0.05, "the capsule reaches the edge")
        assertColor(try pixel(of: pressed, x: 1, y: pressed.height / 2), tokenColor(BillboardPalette.background, .light), accuracy: 0.05, "pressed, it shrinks in by 1%")

        let text = try draw(BillboardButtonBody(label: Text("Clear all"), kind: .textButton).background(BillboardColors.background), .light, width: nil)
        let textPressed = try draw(BillboardButtonBody(label: Text("Clear all"), kind: .textButton, isPressed: true).background(BillboardColors.background), .light, width: nil)
        XCTAssertNotEqual(text.dataProvider?.data as Data?, textPressed.dataProvider?.data as Data?)
    }

    /// Loading shows its title; a disabled button with a hint says what is missing, on screen and as the
    /// button's VoiceOver hint.
    func testButtonLoadingAndDisabledHint() throws {
        let hint = "Add your street address, city, state and ZIP to continue."
        let strings = AccessibilityTreeText.strings(of: VStack {
            BBActionButton(title: "Sign in", action: {}, loadingTitle: "Signing in…", isLoading: true)
            BBActionButton(title: "Find my district", action: {}, isEnabled: false, disabledHint: hint)
        })
        XCTAssertTrue(strings.contains("Signing in…"), "the loading title, without the spinner's words: \(strings)")
        XCTAssertTrue(strings.contains("Find my district"), "\(strings)")
        XCTAssertEqual(strings.filter { $0 == hint }.count, 1, "the hint is read once, as the button's hint: \(strings)")

        let withHint = try draw(BBActionButton(title: "Find my district", action: {}, isEnabled: false, disabledHint: hint), .light, width: 343)
        let enabled = try draw(BBActionButton(title: "Find my district", action: {}, isEnabled: true, disabledHint: hint), .light, width: 343)
        XCTAssertEqual(enabled.height, 50, "no hint while enabled")
        XCTAssertGreaterThan(withHint.height, 60, "the hint line shows under the disabled button")
    }

    /// Callers disable a button while it loads (Sign in, Find my district, Save). It keeps its `ink`
    /// capsule then (spec 3.16: the spinner in `onFill` on the capsule): the disabled `well` look would
    /// leave the `onFill` spinner at about 1.2:1. No "what is missing" hint shows while loading, and
    /// VoiceOver still hears the loading title.
    func testALoadingButtonKeepsItsInkCapsuleWhileDisabled() throws {
        let hint = "Add your street address, city, state and ZIP to continue."
        for look in [Look.light, Look.dark] {
            let loading = try draw(
                BBActionButton(title: "Sign in", action: {}, loadingTitle: "Signing in…", isEnabled: false, isLoading: true, disabledHint: hint),
                look,
                width: 343
            )
            XCTAssertEqual(loading.height, 50, "no hint line while loading \(look.name)")
            assertColor(try pixel(of: loading, x: 14, y: 25), tokenColor(BillboardPalette.interactive, look), accuracy: 0.03, "the ink fill \(look.name)")

            let disabled = try draw(BBActionButton(title: "Sign in", action: {}, isEnabled: false), look, width: 343)
            assertColor(try pixel(of: disabled, x: 14, y: 25), tokenColor(BillboardPalette.secondaryBackground, look), accuracy: 0.03, "disabled, not loading: the well \(look.name)")
        }
        let strings = AccessibilityTreeText.strings(of: BBActionButton(
            title: "Sign in", action: {}, loadingTitle: "Signing in…", isEnabled: false, isLoading: true, disabledHint: hint
        ))
        XCTAssertTrue(strings.contains("Signing in…"), "\(strings)")
        XCTAssertFalse(strings.contains(hint), "\(strings)")
    }

    // MARK: Error banner (spec 3.19)

    func testTheErrorBannerRendersInEveryLook() throws {
        try drawForReview("error-banner", width: 375) {
            BBErrorBanner(message: .constant("Can't reach Billboard right now. Check your connection and try again."))
        }
    }

    /// An opaque sheet with a 1.5 pt danger rule and no shadow. The banner sits 16 pt in from the sides
    /// and 8 pt down; drawn at 2x on paper.
    func testTheErrorBannerIsASheetWithADangerRuleAndNoShadow() throws {
        for look in [Look.light, Look.dark, Look(increaseContrast: true)] {
            let image = try draw(
                BBErrorBanner(message: .constant("Can't reach Billboard right now.")).background(BillboardColors.background),
                look,
                width: 375,
                scale: 2
            )
            let middle = (image.height + 16) / 2
            let paper = tokenColor(BillboardPalette.background, look)
            assertColor(try pixel(of: image, x: 32, y: middle), tokenColor(BillboardPalette.danger, look), accuracy: 0.03, "the rule \(look.name)")
            assertColor(try pixel(of: image, x: 34, y: middle), tokenColor(BillboardPalette.danger, look), accuracy: 0.03, "1.5 pt wide \(look.name)")
            assertColor(try pixel(of: image, x: 37, y: middle), tokenColor(BillboardPalette.cardBackground, look), accuracy: 0.03, "the sheet \(look.name)")
            for x in [31, 26, 20] {
                assertColor(try pixel(of: image, x: x, y: middle), paper, accuracy: 0.01, "no shadow \((32 - x) / 2) pt out \(look.name)")
            }
        }
        let strings = AccessibilityTreeText.strings(of: BBErrorBanner(message: .constant("Can't reach Billboard right now.")))
        XCTAssertEqual(strings, ["Error", "Can't reach Billboard right now.", "Close error"], "the xmark means Close (spec 2.10)")
    }

    // MARK: Record notices (spec 3.20)

    func testRecordNoticesRenderInEveryLook() throws {
        try drawForReview("record-notices", width: 375) {
            VStack(alignment: .leading, spacing: 20) {
                RecordNotice(.allCaughtUp, title: "You're all caught up", message: "No bills left to vote on from the last week. Pull down to add one more week, up to a year.")
                RecordNotice(
                    .couldNotLoad,
                    title: "Couldn't load your bills",
                    message: "Can't reach Billboard right now. Check your connection and try again.",
                    action: .init(title: "Try again") {}
                )
                RecordNotice(.nothingYet, title: "No recent actions", message: "Things Congress did on bills you watch show up here.")
                RecordNotice(
                    .notFound,
                    title: "No results for \u{201C}medicare dental\u{201D}",
                    message: "Try a bill number like H.R. 1234, or fewer words.",
                    action: .init(title: "Clear search", style: .textLink) {}
                )
            }
        }
    }

    func testRecordNoticesReadAsOneElementWithTheActionApart() {
        let notice = RecordNotice(
            .couldNotLoad,
            title: "Couldn't load your bills",
            message: "Can't reach Billboard right now. Check your connection and try again.",
            action: .init(title: "Try again", accessibilityIdentifier: "home.queue.retry") {}
        )
        XCTAssertEqual(notice.accessibilityText, "Couldn't load. Couldn't load your bills. Can't reach Billboard right now. Check your connection and try again.")
        let strings = AccessibilityTreeText.strings(of: notice)
        XCTAssertEqual(strings, [notice.accessibilityText, "Try again"])
        XCTAssertEqual(RecordNotice(.allCaughtUp, title: "You're all caught up").accessibilityText, "All caught up. You're all caught up.")
        XCTAssertEqual(RecordNotice.Kind.allCases.map(\.stamp), [.nothingYet, .notFound, .allCaughtUp, .couldNotLoad])
    }

    // MARK: Wordmark (spec 3.24)

    func testTheWordmarkIsWhiteAndBrandTealOnNavyAtAFixedSize() throws {
        try drawForReview("wordmark", width: 300, looks: [.light, .dark, Look(size: .accessibility5)], ground: BillboardColors.navy) {
            VStack(spacing: 16) {
                Wordmark(size: .masthead)
                Wordmark(size: .compact)
            }
        }
        let masthead = try draw(Wordmark(size: .masthead).background(BillboardColors.navy), .light, width: nil)
        let compact = try draw(Wordmark(size: .compact).background(BillboardColors.navy), .light, width: nil)
        XCTAssertGreaterThan(masthead.width, compact.width, "30 pt on Bills, 26 pt elsewhere")
        let large = try draw(Wordmark(size: .masthead).background(BillboardColors.navy), Look(size: .accessibility5), width: nil)
        XCTAssertEqual(large.width, masthead.width, "fixed size")
        XCTAssertEqual(large.height, masthead.height, "fixed size")

        for look in [Look.light, Look.dark] {
            let pixels = try allPixels(of: try draw(Wordmark(size: .masthead).background(BillboardColors.navy), look, width: nil, scale: 2))
            let teal = BillboardPalette.brandTeal.light
            let tealPixels = pixels.filter {
                abs($0.red - teal.red) <= 3.0 / 255 && abs($0.green - teal.green) <= 3.0 / 255 && abs($0.blue - teal.blue) <= 3.0 / 255
            }
            let white = pixels.filter { $0.red > 0.97 && $0.green > 0.97 && $0.blue > 0.97 }
            XCTAssertGreaterThan(tealPixels.count, 100, "BOARD is brand teal \(look.name)")
            XCTAssertGreaterThan(white.count, 100, "BILL is white \(look.name)")
        }

        let host = AccessibilityTreeText.Host(Wordmark())
        defer { host.close() }
        XCTAssertEqual(host.strings(), ["Billboard"])
        XCTAssertEqual(host.traits(of: "Billboard")?.contains(.header), true)
    }

    // MARK: Masthead band and page title (spec 3.21)

    /// Saturday, October 17, 2026 at noon in Washington: the spec's date.
    private static var specDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12))!
    }

    /// The Bills masthead band is navy in both appearances, with the masthead rule and the dateline in
    /// white at 74% (never teal), and the dateline wraps under itself at accessibility sizes.
    func testTheMastheadBandIsNavyWithTheRuleAndDatelineInWhite() throws {
        try drawForReview("masthead-band", width: 390, ground: BillboardColors.background) {
            VStack(spacing: 0) {
                MastheadBand(date: Self.specDate)
                Text("Slips follow on paper.")
                    .textRole(.body)
                    .foregroundStyle(BillboardColors.primaryText)
                    .padding(.top, 16)
            }
        }
        let navy = BillboardPalette.navy.light
        let teal = BillboardPalette.brandTeal.light
        var defaultHeight: CGFloat = 0
        for look in [Look.light, Look.dark] {
            let image = try draw(MastheadBand(date: Self.specDate), look, width: 390, scale: 2)
            defaultHeight = height(of: image, scale: 2)
            // Navy at the left edge, outside the gutter, in both appearances.
            let edge = try pixel(of: image, x: 4, y: image.height / 2)
            XCTAssertEqual(edge.red, navy.red, accuracy: 0.02, look.name)
            XCTAssertEqual(edge.green, navy.green, accuracy: 0.02, look.name)
            XCTAssertEqual(edge.blue, navy.blue, accuracy: 0.02, look.name)
            // The thick white line of the rule: 1 pt from the top, under a 1 pt line and a 2 pt gap.
            let rule = try pixel(of: image, x: 200, y: 2 * 5)
            XCTAssertGreaterThan(rule.red, 0.8, "\(look.name): the rule's 2 pt line is white at 88%")
            let pixels = try allPixels(of: image)
            XCTAssertFalse(
                pixels.contains { abs($0.red - teal.red) <= 3.0 / 255 && abs($0.green - teal.green) <= 3.0 / 255 && abs($0.blue - teal.blue) <= 3.0 / 255 },
                "\(look.name): no teal on the masthead band"
            )
        }
        // Rule, gap, one dateline row and the padding: the dateline fits one line on a 390 pt phone.
        let chrome: CGFloat = 1 + 5 + 7 + 12
        let datelineSize: CGFloat = 11
        XCTAssertGreaterThanOrEqual(defaultHeight, chrome + datelineSize)
        XCTAssertLessThan(defaultHeight, chrome + 2 * datelineSize, "one dateline row at 390 pt")
        let wrapped = try draw(MastheadBand(date: Self.specDate), Look(size: .accessibility5), width: 390)
        XCTAssertGreaterThan(height(of: wrapped), 2.5 * defaultHeight, "the dateline wraps and grows at AX5")
        // A 375 pt phone (iPhone SE) at the default size keeps one row too (spec 3.21 wraps it only at
        // the accessibility sizes), with every date's width: the dateline is mono, so its widest day has
        // the same number of characters as any other ("Wed, Sep 30, 2026").
        let narrow = try draw(MastheadBand(date: Self.specDate), .light, width: 375, scale: 2)
        XCTAssertEqual(height(of: narrow, scale: 2), defaultHeight, accuracy: 0.5, "one dateline row at 375 pt")
        let wrapsAtAX1 = try draw(MastheadBand(date: Self.specDate), Look(size: .accessibility1), width: 375)
        XCTAssertGreaterThan(height(of: wrapsAtAX1), defaultHeight + 11, "the right half wraps under the left at AX1")

        let host = AccessibilityTreeText.Host(MastheadBand(date: Self.specDate))
        defer { host.close() }
        XCTAssertEqual(host.strings().count, 1, host.text())
        XCTAssertTrue(host.text().hasSuffix(", 2026. 119th Congress, 2nd session."), host.text())
    }

    /// The page title is a 40 pt condensed ink header with its deck in ink3, on paper in both appearances.
    func testThePageTitleIsAnInkHeaderWithAnInk3Deck() throws {
        let deck = CongressDeck.text(session: CongressCalendar.session(on: Self.specDate), houseCount: 435, senateCount: 100)
        XCTAssertEqual(deck, "119th Congress · House 435 · Senate 100")
        let images = try drawForReview("page-title", width: 390) {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: "Updates", deck: "Sat, Oct 17, 2026")
                PageTitle(title: "Congress", deck: deck)
                PageTitle(title: "Profile")
            }
        }
        for look in [Look.light, Look.dark] {
            let pixels = try allPixels(of: try XCTUnwrap(images[look]))
            let ink = tokenColor(BillboardPalette.primaryText, look, over: BillboardPalette.background)
            let ink3 = tokenColor(BillboardPalette.dimText, look, over: BillboardPalette.background)
            let near: (BillboardColorMath.RGB) -> Int = { color in
                pixels.filter { abs($0.red - color.red) <= 3.0 / 255 && abs($0.green - color.green) <= 3.0 / 255 && abs($0.blue - color.blue) <= 3.0 / 255 }.count
            }
            XCTAssertGreaterThan(near(ink), 500, "\(look.name): titles in ink")
            XCTAssertGreaterThan(near(ink3), 30, "\(look.name): deck lines in ink3")
        }
        let small = try draw(PageTitle(title: "Congress", deck: deck), .light, width: 390)
        let large = try draw(PageTitle(title: "Congress", deck: deck), Look(size: .accessibility5), width: 390)
        XCTAssertGreaterThan(height(of: small), 15 + 40 + 2.5 + 11 + 4, "15 pt above, the title, the deck and 4 pt below")
        XCTAssertGreaterThan(height(of: large), 2 * height(of: small), "the title and deck scale with the text size")

        let host = AccessibilityTreeText.Host(
            PageTitle(title: "Congress", deck: deck, deckAccessibilityLabel: "119th Congress. House, 435 members. Senate, 100 members.")
        )
        defer { host.close() }
        XCTAssertEqual(host.strings(), ["Congress", "119th Congress. House, 435 members. Senate, 100 members."])
        XCTAssertEqual(host.traits(of: "Congress")?.contains(.header), true)
    }

    /// The page title sits 4 pt inside the screen's gutter (the mockup's `.pagetitle{padding:18px 4px 4px}`
    /// in its 16 pt list gutter), so on every root the title starts at 20 pt, in line with the masthead
    /// rule and the dateline: Profile's 16 pt gutter put it at 16 pt.
    func testThePageTitleIsInset4PointsFromTheGutter() throws {
        let scale: CGFloat = 2
        let bare = try draw(Text("Congress").textRole(.display).background(BillboardColors.background), .light, width: nil, scale: scale)
        let titled = try draw(PageTitle(title: "Congress").background(BillboardColors.background), .light, width: 390, scale: scale)
        let bearing = try XCTUnwrap(try inkBounds(of: bare, scale: scale)).minX
        let left = try XCTUnwrap(try inkBounds(of: titled, scale: scale)).minX
        XCTAssertEqual(left - bearing, 4, accuracy: 0.5, "the title's glyphs start 4 pt in")
        // On Profile's 16 pt gutter the title starts where the dateline does, 20 pt from the edge.
        let profile = try draw(PageTitle(title: "Congress").padding(.horizontal, 16).background(BillboardColors.background), .light, width: 390, scale: scale)
        XCTAssertEqual(try XCTUnwrap(try inkBounds(of: profile, scale: scale)).minX - bearing, 20, accuracy: 0.5)
    }

    /// The page title matches frames 9, 12 and 15 optically: the title's capitals start about 24.3 pt under
    /// the view's top (the navy's bottom on a root), and the deck's capitals about 15 pt under the title's
    /// baseline. The mockup sets the 40 pt title at line-height 1; SwiftUI's line box adds the font's
    /// whole ascent and descent, so the CSS's 18 pt and 8 pt measured 27.5 and 20.3 pt in the app.
    func testThePageTitleSpacingMatchesTheFrames() throws {
        let scale: CGFloat = 3
        let deck = CongressDeck.text(session: CongressCalendar.session(on: Self.specDate), houseCount: 435, senateCount: 100)
        for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            let image = try draw(
                // "P" and the deck's "1" have flat tops and the "P" a flat foot, so the ink runs end at the
                // capitals' top and the baseline.
                PageTitle(title: "Profile", deck: deck).background(BillboardColors.background),
                Look(size: size),
                width: 390,
                scale: scale
            )
            let left = try XCTUnwrap(try inkBounds(of: image, scale: scale)).minX
            // Down the stem of the title's "P" and the deck's "1": two runs of ink.
            let runs = try inkRows(of: image, scale: scale, columns: left...(left + 3))
            XCTAssertGreaterThanOrEqual(runs.count, 2, "\(size): the title's P and the deck's 1")
            guard runs.count >= 2 else { continue }
            let capTop = runs[0].lowerBound
            let baseline = runs[0].upperBound
            let deckCapTop = runs[1].lowerBound
            if size == .large {
                XCTAssertEqual(capTop, 24.3, accuracy: 0.75, "the title's capitals under the top")
                XCTAssertEqual(deckCapTop - baseline, 15, accuracy: 0.75, "the deck's capitals under the title's baseline")
            } else {
                XCTAssertGreaterThan(deckCapTop - baseline, 15, "\(size): the deck stays clear of the larger title")
            }
        }
    }

    /// The bounds, in points, of the dark ink in a light-mode drawing on paper (pixels darker than mid grey);
    /// nil when there is none. `columns` limits the search to a range of x in points.
    private func inkBounds(of image: CGImage, scale: CGFloat, columns: ClosedRange<CGFloat>? = nil) throws -> CGRect? {
        let rows = try inkRows(of: image, scale: scale, columns: columns)
        guard let top = rows.first?.lowerBound, let bottom = rows.last?.upperBound else { return nil }
        let pixels = try pixelsOverWhite(of: image)
        var minX = Int.max
        var maxX = Int.min
        for row in 0..<image.height {
            for column in 0..<image.width {
                let pixel = pixels[row * image.width + column]
                if pixel.red + pixel.green + pixel.blue < 1.5 {
                    minX = min(minX, column)
                    maxX = max(maxX, column)
                }
            }
        }
        return CGRect(x: CGFloat(minX) / scale, y: top, width: CGFloat(maxX + 1 - minX) / scale, height: bottom - top)
    }

    /// Every pixel of `image` composited over white, row by row: a partly drawn edge row (a fractional
    /// height) reads as paper, not as black.
    private func pixelsOverWhite(of image: CGImage) throws -> [(red: Double, green: Double, blue: Double)] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(bounds)
            context.draw(image, in: bounds)
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        return stride(from: 0, to: bytes.count, by: 4).map {
            (red: Double(bytes[$0]) / 255, green: Double(bytes[$0 + 1]) / 255, blue: Double(bytes[$0 + 2]) / 255)
        }
    }

    /// The runs of rows, in points, that hold dark ink in a light-mode drawing on paper, top to bottom.
    /// `columns` limits the search to a range of x in points.
    private func inkRows(of image: CGImage, scale: CGFloat, columns: ClosedRange<CGFloat>? = nil) throws -> [ClosedRange<CGFloat>] {
        let pixels = try pixelsOverWhite(of: image)
        let first = columns.map { max(0, Int(($0.lowerBound * scale).rounded(.down))) } ?? 0
        let last = columns.map { min(image.width - 1, Int(($0.upperBound * scale).rounded(.up))) } ?? image.width - 1
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for row in 0...image.height {
            let inked = row < image.height && (first...last).contains { column in
                let pixel = pixels[row * image.width + column]
                return pixel.red + pixel.green + pixel.blue < 1.5
            }
            if inked, start == nil { start = row }
            if !inked, let begin = start {
                runs.append(CGFloat(begin) / scale...CGFloat(row) / scale)
                start = nil
            }
        }
        return runs
    }

    // MARK: Glass capsule (spec 2.9, 3.19)

    /// Increase Contrast wins; Reduce Transparency and the kill switch draw the solid capsule.
    func testGlassCapsuleTreatments() {
        XCTAssertEqual(GlassChrome.treatment(glassChrome: true, reduceTransparency: false, increaseContrast: false), .glass)
        XCTAssertEqual(GlassChrome.treatment(glassChrome: true, reduceTransparency: true, increaseContrast: false), .solid)
        XCTAssertEqual(GlassChrome.treatment(glassChrome: false, reduceTransparency: false, increaseContrast: false), .solid, "FeatureFlags.glassChrome off")
        XCTAssertEqual(GlassChrome.treatment(glassChrome: true, reduceTransparency: false, increaseContrast: true), .solidHighContrast)
        XCTAssertEqual(GlassChrome.treatment(glassChrome: true, reduceTransparency: true, increaseContrast: true), .solidHighContrast)
        XCTAssertEqual(GlassChrome.treatment(glassChrome: false, reduceTransparency: false, increaseContrast: true), .solidHighContrast)
        XCTAssertTrue(FeatureFlags.glassChrome, "custom glass ships on")
    }

    /// The Undo toast, the one text-and-button glass capsule (spec 3.19).
    private func toast(_ message: String = "Skipped H.R. 77") -> some View {
        UndoToast(message: message, onUndo: {})
    }

    /// The capsules over a busy ground (white titles on a dark slip, ink text on paper), in every look,
    /// with Button Shapes, and under Reduce Transparency and Increase Contrast.
    func testGlassCapsulesRenderOverTextInEveryLook() throws {
        let busy = VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<4) { _ in
                Text("Clean Energy Reporting Act Medicare Prescription Drug Price")
                    .textRole(.heading)
                    .foregroundStyle(BillboardColors.primaryText)
                    .lineLimit(1)
            }
        }
        let looks = Self.buttonShapeLooks + [
            Look(reduceTransparency: true), Look(scheme: .dark, reduceTransparency: true),
            Look(increaseContrast: true), Look(scheme: .dark, increaseContrast: true)
        ]
        try drawForReview("glass-capsules", width: 375, looks: looks) {
            VStack(alignment: .leading, spacing: 12) {
                toast()
                // The sync capsule's spinner is UIKit, which ImageRenderer cannot draw.
                GlassCapsule(size: .compact) {
                    Text("Updating your bills…").textRole(.caption)
                }
                GlassCapsule(size: .compact) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up")
                        Text("Jump to top").textRole(.caption).fontWeight(.semibold)
                    }
                }
                GlassCapsule(size: .compact) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.left")
                        Text("Swipe left to skip").textRole(.caption)
                    }
                }
            }
            .padding(12)
            .background(alignment: .topLeading) { busy }
        }
    }

    /// The text sits on an opaque sheet whatever is under the glass: just inside the rim the pixel is the
    /// sheet exactly, over paper and over a white title alike. Reduce Transparency and Increase Contrast
    /// drop the rim for a 1 pt rule or controlRule. Drawn at 2x.
    func testGlassCapsuleTextSitsOnAnOpaqueSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            for ground in [BillboardColors.background, BillboardColors.textOnNavy, BillboardColors.navy] {
                let look = Look(scheme: scheme)
                let image = try draw(toast().padding(10).background(ground), look, width: 343, scale: 2)
                XCTAssertEqual(image.height, (50 + 20) * 2, "50 pt toast \(look.name)")
                // 10 pt in, then the 4 pt rim, then 4 pt into the sheet (the text starts 16 pt in).
                assertColor(try pixel(of: image, x: 36, y: image.height / 2), tokenColor(BillboardPalette.cardBackground, look), accuracy: 0.01, "opaque sheet \(look.name)")
            }

            let reduced = Look(scheme: scheme, reduceTransparency: true)
            let solid = try draw(toast().padding(10).background(BillboardColors.background), reduced, width: 343, scale: 2)
            XCTAssertEqual(solid.height, (50 + 20) * 2)
            let sheet = tokenColor(BillboardPalette.cardBackground, reduced)
            assertColor(try pixel(of: solid, x: 20, y: solid.height / 2), tokenColor(BillboardPalette.separator, reduced), accuracy: 0.03, "1 pt rule, no rim \(reduced.name)")
            assertColor(try pixel(of: solid, x: 23, y: solid.height / 2), sheet, accuracy: 0.01, "the sheet fills the capsule \(reduced.name)")

            let contrast = Look(scheme: scheme, increaseContrast: true)
            let ruled = try draw(toast().padding(10).background(BillboardColors.background), contrast, width: 343, scale: 2)
            assertColor(try pixel(of: ruled, x: 20, y: ruled.height / 2), tokenColor(BillboardPalette.controlRule, contrast), accuracy: 0.03, "controlRule edge \(contrast.name)")
            assertColor(try pixel(of: ruled, x: 23, y: ruled.height / 2), tokenColor(BillboardPalette.cardBackground, contrast), accuracy: 0.01, "the sheet \(contrast.name)")
        }

        // 44 pt, or one line of text and its padding where that is taller (the capsule grows with its text).
        // Measured, not assumed: on Xcode Cloud's virtual Mac the capsule came out 44.33 pt (2026-11-02), on a
        // Mac 44 at every display scale.
        let text = UIHostingController(rootView: Text("Jump to top").environment(\.dynamicTypeSize, .large))
            .sizeThatFits(in: CGSize(width: 1000, height: 1000))
        let compact = UIHostingController(
            rootView: GlassCapsule(size: .compact) { Text("Jump to top") }.environment(\.dynamicTypeSize, .large)
        ).sizeThatFits(in: CGSize(width: 1000, height: 1000))
        // The sheet pads its text 6 pt above and below, inside the rim.
        let oneLine = text.height + 2 * 6 + 2 * GlassCapsule<Text>.rimWidth
        let expected = max(GlassCapsule<Text>.Size.compact.height, oneLine)
        XCTAssertEqual(compact.height, expected, accuracy: 0.01, "44 pt, or a \(text.height) pt line and its padding")
        let large = try draw(toast(), Look(size: .accessibility3), width: 343)
        XCTAssertGreaterThan(large.height, 50, "the capsule grows with the text")
        XCTAssertEqual(AccessibilityTreeText.strings(of: toast()), ["Undo", "Skipped H.R. 77"], "Undo first (spec D 2.1.2)")
    }

    // MARK: Tab capsule (spec 2.9, 3.22, 4.4)

    private func tabCapsule(_ selected: TabsBar.Tab = .home, badges: Bool = true) -> some View {
        BillboardTabBar(selectedTab: selected, homeBadgeCount: badges ? 3 : 0, updatesBadgeCount: badges ? 12 : 0, onSelect: { _ in })
    }

    /// The capsule drawn 16 pt in from each side of a 375 pt phone (343 pt wide), over `ground`, at 2x.
    /// Its tabs are 83.75 pt columns from x = 20; the selected tab's capsule spans y = 20 to 76 pt.
    private func drawTabCapsule(
        _ selected: TabsBar.Tab = .home,
        badges: Bool = true,
        over ground: Color? = nil,
        _ look: Look,
        differentiateWithoutColor: Bool = false
    ) throws -> CGImage {
        try draw(
            tabCapsule(selected, badges: badges)
                .padding(16)
                .background(ground ?? BillboardColors.cardBackground)
                .environment(\._accessibilityDifferentiateWithoutColor, differentiateWithoutColor),
            look,
            width: 375,
            scale: 2
        )
    }

    private static let tabColumn: CGFloat = (343 - 8) / 4

    /// The capsule in every look over a white slip (light) and night paper (dark), at a fixed size at
    /// AX5, and its fallbacks: Reduce Transparency (or `glassChrome` off) solid navy, Increase Contrast
    /// solid navy with a 1 pt white 30% edge. The selected tab's capsule is opaque navy with its brand-teal
    /// stroke in every look (2 pt with Increase Contrast).
    func testTabCapsuleRendersInEveryLookWithItsFallbacks() throws {
        let navy = BillboardPalette.navy.light.rgb
        let teal = BillboardPalette.brandTeal.light.rgb
        let looks: [Look] = [
            .light, .dark, Look(size: .accessibility5), Look(scheme: .dark, size: .accessibility5),
            Look(reduceTransparency: true), Look(scheme: .dark, reduceTransparency: true),
            Look(increaseContrast: true), Look(scheme: .dark, increaseContrast: true)
        ]
        for look in looks {
            let ground = look.dark ? BillboardColors.background : BillboardColors.cardBackground
            let image = try drawTabCapsule(over: ground, look)
            attach(image, name: "tab-capsule-\(look.name)")
            XCTAssertEqual(image.width, 750, look.name)
            XCTAssertEqual(image.height, (64 + 32) * 2, "64 pt at every text size: the Large Content Viewer shows it larger \(look.name)")

            // Inside the selected capsule, left of the symbol: opaque navy over the glass.
            assertColor(try pixel(of: image, x: 48, y: 96), navy, accuracy: 0.01, "opaque navy selection \(look.name)")
            // The selection's stroke at its leftmost point (x = 20 to 21.5 pt, or 22 pt with Increase Contrast).
            assertColor(try pixel(of: image, x: 41, y: 96), teal, accuracy: 0.03, "brand-teal stroke \(look.name)")
            if look.increaseContrast {
                assertColor(try pixel(of: image, x: 42, y: 96), teal, accuracy: 0.03, "2 pt stroke \(look.name)")
            } else {
                assertColor(try pixel(of: image, x: 44, y: 96), navy, accuracy: 0.03, "1.5 pt stroke \(look.name)")
            }

            // The capsule's own ground in the 4 pt band above the tabs, at its middle.
            let groundSample = try pixel(of: image, x: 375, y: 36)
            if look.reduceTransparency || look.increaseContrast {
                assertColor(groundSample, navy, accuracy: 0.01, "solid navy, no glass \(look.name)")
            } else {
                // Navy glass, lighter than solid navy where a white slip shows through (#2F3F57 over white).
                XCTAssertLessThan(luminance(groundSample), 0.3, "dark navy glass \(look.name): \(groundSample)")
                XCTAssertGreaterThan(groundSample.blue, groundSample.red, "navy, not grey \(look.name): \(groundSample)")
                XCTAssertNotEqual(groundSample.red, navy.red, accuracy: 0.002, "glass, not a solid fill \(look.name)")
                // Spec 3.22 and 7.1, measured on the glass as drawn: an unselected label (white 74%) at least
                // 6.68:1, and the selection's teal stroke at least 4.57:1 (3:1 is the floor for a control's edge).
                let glass = (red: groundSample.red, green: groundSample.green, blue: groundSample.blue)
                let label = BillboardColorMath.composite(BillboardPalette.textOnNavy.light.rgb, alpha: 0.74, over: glass)
                XCTAssertGreaterThanOrEqual(BillboardColorMath.contrastRatio(label, glass), 6.6, "unselected label on the glass \(look.name)")
                XCTAssertGreaterThanOrEqual(BillboardColorMath.contrastRatio(teal, glass), 4.5, "teal stroke against the glass \(look.name)")
            }
            if look.increaseContrast {
                // The 1 pt edge (y = 16 to 17 pt), white 30% over the navy.
                let edge = BillboardColorMath.composite(BillboardPalette.textOnNavy.light.rgb, alpha: 0.3, over: navy)
                assertColor(try pixel(of: image, x: 375, y: 33), edge, accuracy: 0.03, "white 30% edge \(look.name)")
            }
        }
    }

    /// Spec 3.22, 10.1: drawn under Reduce Transparency (the selection is navy on navy) and desaturated, the
    /// selected Bills tab still differs from the unselected Bills tab by its stroke, its weight and the filled
    /// symbol. Bills is compared with itself, selected and not (Updates selected), so only the selection differs.
    func testTheSelectedTabDiffersByStrokeWeightAndShapeWithoutColour() throws {
        let look = Look(reduceTransparency: true)
        let selectedImage = try drawTabCapsule(.home, badges: false, look)
        let unselectedImage = try drawTabCapsule(.updates, badges: false, look)
        attach(try desaturated(selectedImage), name: "tab-capsule-bills-selected-reduce-transparency-desaturated")
        attach(try desaturated(unselectedImage), name: "tab-capsule-bills-unselected-reduce-transparency-desaturated")
        let selected = try PixelGrid(selectedImage)
        let unselected = try PixelGrid(unselectedImage)

        let navy = BillboardPalette.navy.light.rgb
        let navyGray = PixelGrid.gray(navy)
        let tealGray = PixelGrid.gray(BillboardPalette.brandTeal.light.rgb)
        let dimGray = PixelGrid.gray(BillboardColorMath.composite(BillboardPalette.textOnNavy.light.rgb, alpha: 0.74, over: navy))

        // Stroke: grey teal at the selection's leftmost point; plain navy where Bills is not selected.
        XCTAssertEqual(selected.gray(41, 96), tealGray, accuracy: 0.04, "the stroke shows in grey")
        XCTAssertEqual(unselected.gray(41, 96), navyGray, accuracy: 0.02, "no stroke on an unselected tab")

        // The symbol and the label: the ink in the middle of the Bills column, clear of the selection's
        // rounded ends, as runs of rows (symbol, then label), in units of fully inked pixels.
        let columns = Int((20 + 20) * 2)..<Int((20 + Self.tabColumn - 20) * 2)
        // Between the selection's top and bottom strokes (y = 20 to 21.5 and 74.5 to 76 pt).
        let rows = 46..<146
        let on = selected.inkRuns(columns: columns, rows: rows, ground: navyGray, ink: tealGray)
        let off = unselected.inkRuns(columns: columns, rows: rows, ground: navyGray, ink: dimGray)
        XCTAssertEqual(on.count, 2, "a symbol and a label, selected: \(on)")
        XCTAssertEqual(off.count, 2, "a symbol and a label, unselected: \(off)")
        guard on.count == 2, off.count == 2 else { return }
        XCTAssertGreaterThan(on[0].coverage, off[0].coverage * 1.5, "the filled doc.text.fill against the outline doc.text: \(on[0]) \(off[0])")
        XCTAssertGreaterThan(on[1].coverage, off[1].coverage * 1.1, "the Bold label against the Medium one: \(on[1]) \(off[1])")
    }

    /// Differentiate Without Color adds a 2 pt brand-teal underline, 14 pt wide, under the selected label
    /// and nothing else.
    func testDifferentiateWithoutColorUnderlinesTheSelectedLabel() throws {
        for look in [Look.light, .dark, Look(reduceTransparency: true)] {
            let plain = try PixelGrid(drawTabCapsule(badges: false, look))
            let underlinedImage = try drawTabCapsule(badges: false, look, differentiateWithoutColor: true)
            attach(underlinedImage, name: "tab-capsule-differentiate-without-color-\(look.name)")
            let underlined = try PixelGrid(underlinedImage)
            var changed: [(x: Int, y: Int)] = []
            for y in 0..<plain.height {
                for x in 0..<plain.width where plain.distance(underlined, x, y) > 0.06 {
                    changed.append((x, y))
                }
            }
            XCTAssertFalse(changed.isEmpty, "an underline is drawn \(look.name)")
            let xs = changed.map(\.x)
            let ys = changed.map(\.y)
            let width = Double((xs.max() ?? 0) - (xs.min() ?? 0) + 1) / 2
            let height = Double((ys.max() ?? 0) - (ys.min() ?? 0) + 1) / 2
            XCTAssertEqual(width, 14, accuracy: 1.5, "14 pt wide \(look.name)")
            XCTAssertEqual(height, 2, accuracy: 1, "2 pt tall \(look.name)")
            XCTAssertEqual(Double(xs.min()! + xs.max()!) / 4, 20 + Self.tabColumn / 2, accuracy: 1.5, "centred under the Bills label \(look.name)")
            let middle = underlined.rgb((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
            assertColor(middle, BillboardPalette.brandTeal.light.rgb, accuracy: 0.03, "brand teal \(look.name)")
        }
    }

    /// The badges: white capsules with navy mono numerals, capped at 99+, hidden from VoiceOver; the tab's
    /// value says the count, and the ids stay on the four buttons.
    func testTabBadgesAndTheTabsVoiceOverReads() throws {
        XCTAssertEqual(TabBadgeAccessibility.badgeText(count: 3), "3")
        XCTAssertEqual(TabBadgeAccessibility.badgeText(count: 99), "99")
        XCTAssertEqual(TabBadgeAccessibility.badgeText(count: 100), "99+")
        let host = AccessibilityTreeText.Host(tabCapsule().padding(16), size: CGSize(width: 375, height: 120))
        defer { host.close() }
        XCTAssertEqual(host.strings(), ["Bills", "3 bills to vote on", "Updates", "12 updates", "Congress", "Profile"])
        XCTAssertEqual(host.traits(of: "Bills")?.contains(.selected), true)
        XCTAssertEqual(host.traits(of: "Updates")?.contains(.selected), false)
        XCTAssertEqual(
            ["Bills", "Updates", "Congress", "Profile"].map { host.identifier(of: $0) },
            ["tab.billboard", "tab.updates", "tab.congress", "tab.profile"],
            "the ids are on the buttons, not replaced by a container's"
        )
    }

    /// A greyscale copy of `image`, for review.
    private func desaturated(_ image: CGImage) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - Helpers

    private func render<Content: View>(_ view: Content, variant: Variant, width: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        XCTAssertEqual(bytes[3], 255, "sampled an opaque pixel")
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}

/// An image's pixels in sRGB, read once, for checks over many pixels.
private struct PixelGrid {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        bytes = buffer
    }

    /// The colour at `x`, `y` from the top left.
    func rgb(_ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double) {
        let index = (y * width + x) * 4
        return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255)
    }

    /// The pixel in grey (Rec. 709 weights on the sRGB values), as a desaturated copy shows it.
    func gray(_ x: Int, _ y: Int) -> Double {
        Self.gray(rgb(x, y))
    }

    static func gray(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    /// The largest channel difference from `other` at `x`, `y`.
    func distance(_ other: PixelGrid, _ x: Int, _ y: Int) -> Double {
        let a = rgb(x, y)
        let b = other.rgb(x, y)
        return max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }

    /// The ink of grey `ink` on grey `ground` in `columns`, in runs of inked rows separated by clean rows,
    /// top to bottom, each with its coverage in fully inked pixels.
    func inkRuns(columns: Range<Int>, rows: Range<Int>, ground: Double, ink: Double) -> [(rows: ClosedRange<Int>, coverage: Double)] {
        var runs: [(rows: ClosedRange<Int>, coverage: Double)] = []
        var start: Int?
        var coverage = 0.0
        for y in rows {
            var rowCoverage = 0.0
            for x in columns {
                rowCoverage += min(1, max(0, (gray(x, y) - ground) / (ink - ground)))
            }
            if rowCoverage > 0.5 {
                if start == nil { start = y }
                coverage += rowCoverage
            } else if let first = start {
                runs.append((first...(y - 1), coverage))
                start = nil
                coverage = 0
            }
        }
        if let first = start {
            runs.append((first...(rows.upperBound - 1), coverage))
        }
        return runs
    }
}
