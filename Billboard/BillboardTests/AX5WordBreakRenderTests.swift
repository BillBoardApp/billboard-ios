import CryptoKit
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// No word breaks mid-word at AX5 on a 375 pt phone, an iPhone SE's width (project decision of 2026-10-29): the vote
/// reason tags in Your vote broke "Constitutiona / l Rights", and the Where you vote success panel's Follow your
/// representatives button broke "representative / s". At AX5 the tags' glyphs sit 4 pt from the start and from the
/// word, and from AX4 the Follow button is the ink text button; smaller sizes keep the tag's 12 pt and 6 pt and the
/// capsule, which already keep every word whole there. With Bold Text at AX5 both words are also set at 93%. Every
/// accessibility size is checked, with and without Bold Text. Every reason tag and both panels a territory and an
/// at-large district show (the Profile panel, with representatives to follow) are rendered at AX3 and AX5 on 375 pt,
/// light and dark, and at AX5 with Bold Text.
///
/// Default sizes look the same: the default-size renders here are logged with a digest of their pixels
/// ("RENDER-DIGEST"), which matched byte for byte before and after the fix.
@MainActor
final class AX5WordBreakRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize
        var weight: LegibilityWeight = .regular

        var name: String {
            let sizeName: String
            switch size {
            case .large: sizeName = "default"
            case .xxxLarge: sizeName = "xxxLarge"
            case .accessibility3: sizeName = "AX3"
            case .accessibility5: sizeName = "AX5"
            default: sizeName = "\(size)"
            }
            return "\(scheme == .dark ? "dark" : "light")-\(sizeName)\(weight == .bold ? "-bold" : "")"
        }

        var style: UIUserInterfaceStyle { scheme == .dark ? .dark : .light }
    }

    /// The phone: 375 pt, an iPhone SE's width.
    private static let screenWidth: CGFloat = 375
    /// The bill page's and the location editor's gutter (spec 3.5, 4.10).
    private static let gutter = BillboardStyle.Space.xl
    /// The column both draw in on that phone.
    private static var column: CGFloat { screenWidth - 2 * gutter }

    private static let accessibility: [Variant] = [
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility3),
        Variant(scheme: .light, size: .accessibility5),
        Variant(scheme: .dark, size: .accessibility5),
        Variant(scheme: .light, size: .accessibility5, weight: .bold),
        Variant(scheme: .dark, size: .accessibility5, weight: .bold)
    ]
    /// Sizes the fix must not change.
    private static let unchanged: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .xxxLarge)
    ]

    /// Every accessibility size, with and without Bold Text (legibilityWeight .bold), at which no word may break.
    private static let wordCases: [(size: DynamicTypeSize, weight: LegibilityWeight)] = {
        let sizes: [DynamicTypeSize] = [.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        return sizes.flatMap { size in [(size, LegibilityWeight.regular), (size, .bold)] }
    }()

    private static func caseName(_ size: DynamicTypeSize, _ weight: LegibilityWeight) -> String {
        "\(size)\(weight == .bold ? " with Bold Text" : "")"
    }

    // MARK: - Reason tags

    /// Each word of every reason, alone in a tag in the bill page's column at each accessibility size, with and
    /// without Bold Text, takes one line, as "A" does, so a reason's tag breaks its lines only between words.
    /// Selected and not.
    func testEveryReasonTagKeepsItsWordsWholeAtAccessibilitySizes() throws {
        // Up to AX4 the tag keeps its 12 pt start and 6 pt after the glyph; at AX5 both are 4 pt. The word's end keeps
        // its 12 pt at every size.
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4] {
            XCTAssertEqual(SelectableTag.leadingPadding(at: size), 12, "\(size)")
            XCTAssertEqual(SelectableTag.glyphSpacing(at: size), 6, "\(size)")
        }
        XCTAssertEqual(SelectableTag.leadingPadding(at: .accessibility5), BillboardStyle.Space.xs)
        XCTAssertEqual(SelectableTag.glyphSpacing(at: .accessibility5), BillboardStyle.Space.xs)
        XCTAssertEqual(SelectableTag.trailingPadding, 12)
        // The word is set at 93% only at AX5 with Bold Text.
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility4, .accessibility5] {
            XCTAssertEqual(TextRole.boldTextAX5Scale(at: size, legibilityWeight: .regular), 1, "\(size)")
            XCTAssertEqual(TextRole.boldTextAX5Scale(at: size, legibilityWeight: nil), 1, "\(size)")
            let bold = TextRole.boldTextAX5Scale(at: size, legibilityWeight: .bold)
            XCTAssertEqual(bold, size == .accessibility5 ? 0.93 : 1, "\(size)")
        }

        for (textSize, weight) in Self.wordCases {
            let name = Self.caseName(textSize, weight)
            let oneLine = tagSize("A", selected: false, size: textSize, weight: weight).height
            for reason in VoteReason.allCases {
                for word in reason.title.split(separator: " ").map(String.init) {
                    for selected in [false, true] {
                        let size = tagSize(word, selected: selected, size: textSize, weight: weight)
                        XCTAssertEqual(size.height, oneLine, accuracy: 0.5, "\(name), \(reason.title): \"\(word)\" breaks (selected \(selected), \(size))")
                        XCTAssertLessThanOrEqual(size.width, Self.column, "\(name), \(reason.title): \"\(word)\"")
                    }
                }
            }
        }
    }

    /// A picked reason's tag in the bill page's column keeps its word inside its shape at every accessibility size,
    /// with and without Bold Text: every pixel of the word (in `onFill`) is at least 1 pt inside the tag's rounded
    /// shape. At AX5 a wrapped tag's corner was about 50 pt and cut through the end of its last line: "Taxes /
    /// Spending"'s "g" touched the fill's edge, and with Bold Text crossed it. At accessibility sizes a tag's corner is
    /// now no rounder than a one-line tag's ends, and a one-line tag is still a capsule. Below them the corner is the
    /// scaled 17 pt, as before.
    func testEveryPickedReasonTagKeepsItsWordInsideItsShape() throws {
        XCTAssertEqual(SelectableTag.shapeRadius(scaled: 17, at: .large), 17)
        XCTAssertEqual(SelectableTag.shapeRadius(scaled: 23.8, at: .xxxLarge), 23.8)
        for (size, weight) in Self.wordCases {
            let name = Self.caseName(size, weight)
            let wordScale = TextRole.boldTextAX5Scale(at: size, legibilityWeight: weight)
            let oneLine = tagSize("A", selected: true, size: size, weight: weight).height
            let capped = SelectableTag.shapeRadius(scaled: .greatestFiniteMagnitude, at: size, wordScale: wordScale)
            XCTAssertGreaterThanOrEqual(capped, oneLine / 2, "\(name): a one-line tag stays a capsule")
            XCTAssertLessThan(capped, oneLine / 2 + 1, name)
            for reason in VoteReason.allCases {
                let (outside, word) = try wordPixelsOutsidePickedTag(reason.title, size: size, weight: weight)
                XCTAssertGreaterThan(word, 0, "\(name): \(reason.title)'s word is drawn")
                XCTAssertEqual(outside, 0, "\(name): \(reason.title) runs into its tag's edge")
            }
        }
    }

    /// The real Your vote section at AX5 on 375 pt, light and dark, showing every reason across four renders: the
    /// picker shows the first three of the order and any picked, so each render shows three reasons and three picked
    /// ones (the picked look too), and the last shows Evidence / Data and, after an Abstain, Need More Information.
    /// The default and xxxLarge renders are the before-and-after proof that only accessibility sizes changed.
    func testEveryReasonTagRendersOnA375ptPhone() throws {
        let reasons = VoteReason.yeaNayReasons
        XCTAssertEqual(reasons.count, 13)
        let pages: [(String, VoteType, [VoteReason], Set<VoteReason>)] = [
            ("yea-1-to-6", .yea, Array(reasons[0..<6]), Set(reasons[3..<6])),
            ("nay-7-to-12", .nay, Array(reasons[6..<12]), Set(reasons[9..<12])),
            ("yea-13", .yea, [reasons[12]], []),
            ("abstain", .abstain, VoteReason.abstainReasons, [])
        ]
        for variant in Self.accessibility + Self.unchanged {
            for (name, voteType, order, picked) in pages {
                let section = BillYourVoteSection(
                    standing: .voted,
                    isWatching: false,
                    showsReasonPicker: true,
                    selectedReasons: picked,
                    reasonVoteType: voteType,
                    reasonOrder: order,
                    onToggleReason: { _ in },
                    onSetWatch: { _ in },
                    companionCaption: nil,
                    companionConflictNote: nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(BillboardColors.document)
                .environment(\.dynamicTypeSize, variant.size)
                .environment(\.legibilityWeight, variant.weight)
                // Under 2,700 pt: a taller window is past the simulator's largest texture at 3x and draws blank.
                let height: CGFloat = variant.size == .accessibility5 ? 2000 : variant.size == .accessibility3 ? 1400 : 760
                let image = try drawn(section, variant: variant, height: height) { host in
                    for reason in order {
                        let frame = try XCTUnwrap(host.frame(of: reason.title), "\(reason.title) shows: \(host.text())")
                        XCTAssertLessThanOrEqual(frame.maxY, height, "\(reason.title) is drawn")
                        XCTAssertLessThanOrEqual(frame.maxX, Self.screenWidth - Self.gutter + 0.5, "\(reason.title) stays in the column")
                    }
                }
                record(image, name: "reasons-\(name)-375-\(variant.name)", digest: Self.unchanged.contains { $0.name == variant.name })
            }
        }
    }

    // MARK: - The Follow button on the success panel

    /// "Follow your representatives" on 375 pt keeps its words whole on the territory and at-large panels at every
    /// accessibility size, with and without Bold Text: at most two lines, "Follow your" and "representatives", never
    /// a third line for "s"; at AX5 exactly two. At AX5 "representatives" is about 318 pt in the button face, wider
    /// than a capsule leaves it in the 335 pt column (303 pt inside its 16 pt padding, full width or not), and at AX4
    /// with Bold Text 303.3 pt, so from AX4 the button is the ink text button setup's "Continue without following" is;
    /// up to AX3 it stays the secondary capsule. At AX5 with Bold Text the word is 348 pt, wider than the column, so
    /// the label is set at 93% there.
    func testTheFollowButtonKeepsItsWordsWholeAtAccessibilitySizes() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility2, .accessibility3] {
            XCTAssertEqual(LocationSavedPanel.followButtonKind(at: size), .secondary, "\(size)")
        }
        XCTAssertEqual(LocationSavedPanel.followButtonKind(at: .accessibility4), .textButton)
        XCTAssertEqual(LocationSavedPanel.followButtonKind(at: .accessibility5), .textButton)
        for (size, weight) in Self.wordCases {
            for (panelName, result) in Self.panels {
                let name = "\(panelName), \(Self.caseName(size, weight))"
                let host = AccessibilityTreeText.Host(
                    panel(result)
                        .environment(\.dynamicTypeSize, size)
                        .environment(\.legibilityWeight, weight),
                    size: CGSize(width: Self.screenWidth, height: 3000),
                    settle: 0.2
                )
                let frame = try XCTUnwrap(host.frame(of: "Follow your representatives"), "\(name): \(host.text())")
                host.close()
                let oneLine = textHeight("A", size: size, weight: weight)
                let twoLines = textHeight("A\nA", size: size, weight: weight)
                let kind = LocationSavedPanel.followButtonKind(at: size)
                let padding = kind.isCapsule ? 2 * kind.verticalPadding : 0
                let lines = ((frame.height - padding - oneLine) / (twoLines - oneLine)).rounded() + 1
                if size == .accessibility5 {
                    XCTAssertEqual(lines, 2, "\(name): \(frame), one line \(oneLine), two \(twoLines)")
                } else {
                    XCTAssertLessThanOrEqual(lines, 2, "\(name): \(frame), one line \(oneLine), two \(twoLines)")
                }
                XCTAssertLessThanOrEqual(frame.maxX, Self.screenWidth - Self.gutter + 0.5, name)
                XCTAssertGreaterThanOrEqual(frame.minX, Self.gutter - 0.5, name)
            }
        }
    }

    /// Both panels at AX3 and AX5 on 375 pt, light and dark; at the default and xxxLarge sizes for the before-and-after
    /// proof.
    func testBothPanelsRenderOnA375ptPhone() throws {
        for (name, result) in Self.panels {
            for variant in Self.accessibility + Self.unchanged {
                let image = try render(panel(result), variant: variant)
                record(image, name: "location-success-\(name)-375-\(variant.name)", digest: Self.unchanged.contains { $0.name == variant.name })
            }
        }
    }

    // MARK: - Fixtures

    /// The territory (U.S. Virgin Islands) and at-large (Wyoming) panels in Profile, with a representative to follow.
    private static var panels: [(String, LocationEditorResult)] {
        [("territory-VI", result(state: "VI")), ("at-large-WY", result(state: "WY"))]
    }

    private static func result(state: String) -> LocationEditorResult {
        let district = DistrictPickerModel.normalizedDistrict("At-Large", state: state) ?? "At-Large"
        return LocationEditorResult(
            state: state,
            district: district,
            method: .chosenDistrict,
            verification: DistrictVerificationStatus(
                verified: false,
                status: "self_attested",
                method: DistrictVerificationStatus.methodManualStateDistrict,
                verifiedAt: nil,
                resolved: DistrictVerificationResolved(state: state, districtId: "\(state)-\(district)"),
                signals: nil,
                repsSignalEligible: nil,
                nextStep: nil,
                limitReason: nil
            ),
            representatives: [
                CongressMemberManifestItem(dto: UserAPIContractsV1.CongressMemberManifestItem(
                    bioguideId: "\(state)0",
                    name: "Alex Rivera",
                    chamber: "House of Representatives",
                    state: state,
                    party: "Democratic",
                    district: nil,
                    depictionImageUrl: nil,
                    updatedAt: nil,
                    currentCongressBillsSupportedCount: nil,
                    trackedSponsoredCount: nil,
                    trackedSupportedCount: nil
                ))
            ],
            followedRepresentatives: false
        )
    }

    /// The success panel as the location editor draws it: in its 20 pt gutter on paper.
    private func panel(_ result: LocationEditorResult) -> some View {
        LocationSavedPanel(
            result: result,
            context: .profile,
            followState: .idle,
            unfollowedRepresentativeCount: result.representatives.count,
            onContinue: { _ in },
            onFollow: {},
            onDone: {}
        )
        .padding(.horizontal, Self.gutter)
        .padding(.vertical, Self.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BillboardColors.background)
    }

    // MARK: - Helpers

    /// A tag with `title` in the bill page's column at `size`, with or without Bold Text: its size as laid out there.
    private func tagSize(_ title: String, selected: Bool, size: DynamicTypeSize, weight: LegibilityWeight) -> CGSize {
        let controller = UIHostingController(
            rootView: SelectableTag(title: title, isSelected: selected) {}
                .environment(\.dynamicTypeSize, size)
                .environment(\.legibilityWeight, weight)
        )
        return controller.sizeThatFits(in: CGSize(width: Self.column, height: 2000))
    }

    /// A picked tag with `title` in the bill page's column at `size`, with or without Bold Text, drawn light at 3x on
    /// a pure red page (a colour no tag pixel has) 4 pt from its top left: how many of its word's pixels (`onFill`,
    /// and its glyph's) have their centre outside the tag's shape (the RoundedRectangle it fills) or less than 1 pt in
    /// from its edge, and how many there are.
    private func wordPixelsOutsidePickedTag(
        _ title: String,
        size: DynamicTypeSize,
        weight: LegibilityWeight
    ) throws -> (outside: Int, word: Int) {
        let scale: CGFloat = 3
        let inset: CGFloat = 4
        let renderer = ImageRenderer(
            content: SelectableTag(title: title, isSelected: true) {}
                .frame(width: Self.column, alignment: .topLeading)
                .padding(inset)
                .background(Color(red: 1, green: 0, blue: 0))
                .environment(\.colorScheme, .light)
                .environment(\.dynamicTypeSize, size)
                .environment(\.legibilityWeight, weight)
        )
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "render failed for \(title)")

        // The tag's shape as SelectableTag draws it: its size in the column, and its corner from the scaled 17 pt.
        let tag = tagSize(title, selected: true, size: size, weight: weight)
        let traits = UITraitCollection(preferredContentSizeCategory: TextRole.contentSizeCategory(for: size))
        let scaled = UIFontMetrics(forTextStyle: .subheadline)
            .scaledValue(for: SelectableTag.height / 2, compatibleWith: traits)
        let radius = SelectableTag.shapeRadius(
            scaled: scaled,
            at: size,
            wordScale: TextRole.boldTextAX5Scale(at: size, legibilityWeight: weight)
        )
        // The shape 1 pt in from its edge: a letter that only touches the edge reads as cut too.
        let clear: CGFloat = 1
        let shape = RoundedRectangle(cornerRadius: max(0, radius - clear), style: .continuous)
            .path(in: CGRect(x: inset, y: inset, width: tag.width, height: tag.height).insetBy(dx: clear, dy: clear))

        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "could not read the render of \(title)")
        var outside = 0
        var word = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // The word: white over the ink fill or, past its edge, over the red page, at least 40% covered.
                // Neither the fill (green and blue under 50), its edge nor the page has green or blue over 100.
                guard bytes[i + 1] > 100, bytes[i + 2] > 100 else { continue }
                word += 1
                let centre = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                if !shape.contains(centre) { outside += 1 }
            }
        }
        return (outside, word)
    }

    /// The height of `text` in the button role at `size`, with or without Bold Text, at the Follow label's scale.
    private func textHeight(_ text: String, size: DynamicTypeSize, weight: LegibilityWeight) -> CGFloat {
        let controller = UIHostingController(
            rootView: Text(text)
                .textRole(.button, scale: TextRole.boldTextAX5Scale(at: size, legibilityWeight: weight))
                .fixedSize()
                .environment(\.dynamicTypeSize, size)
                .environment(\.legibilityWeight, weight)
        )
        return controller.sizeThatFits(in: CGSize(width: 2000, height: 2000)).height
    }

    private func render<Content: View>(_ view: Content, variant: Variant) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.screenWidth)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
                .environment(\.legibilityWeight, variant.weight)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: Self.screenWidth, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    /// `view` in a window on the test host's screen at 375 pt, after `prepare` (taps, checks), drawn as shown.
    private func drawn<Content: View>(
        _ view: Content,
        variant: Variant,
        height: CGFloat,
        prepare: (AccessibilityTreeText.Host) throws -> Void
    ) throws -> CGImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = AccessibilityTreeText.Host(view, size: CGSize(width: Self.screenWidth, height: height), settle: 0.3, scene: scene)
        defer { host.close() }
        host.window.overrideUserInterfaceStyle = variant.style
        host.run(0.2)
        try prepare(host)
        host.run(0.3)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
            host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.cgImage)
    }

    /// Attaches the image and, for a size the fix must not change, logs a digest of its pixels.
    private func record(_ image: CGImage, name: String, digest: Bool) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard digest, let data = image.dataProvider?.data as Data? else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print("RENDER-DIGEST \(name) \(image.width)x\(image.height) \(hash)")
    }
}
