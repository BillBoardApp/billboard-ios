import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the bill page (spec D 5.3; Civic Record spec 4.28 to 4.48, 10.1): the vote panel in every state,
/// the document's front matter and sections (Sponsor, Why it matters, the Breakdown ledger, Summary, In
/// Congress, Your vote in every state, How Congress voted, Compare with Congress, Committees, Actions,
/// Source, loading, error and not found), Results with fixtures (no votes, withheld, both rows, state
/// missing), locked Results (INT-11) and the vote map, in light and dark at the default text size and at
/// accessibility sizes, and attaches each image for review. No network, no credentials, no baselines;
/// pixels are checked where the colour or the layout is the point, and the accessibility tree where the
/// words are (`AccessibilityTreeText`).
///
/// Text set with `.textRole(_:)` scales with the environment's Dynamic Type size, so the AX3 and AX5
/// renders of the document and the vote panel are real (the panel's control heights follow the `button` role's
/// line).
@MainActor
final class BillDetailRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String {
            let scheme = self.scheme == .dark ? "dark" : "light"
            switch size {
            case .large: return "\(scheme)-default"
            case .accessibility3: return "\(scheme)-AX3"
            case .accessibility5: return "\(scheme)-AX5"
            default: return "\(scheme)-\(size)"
            }
        }
    }

    private static func variants(_ large: DynamicTypeSize) -> [Variant] {
        [
            Variant(scheme: .light, size: .large),
            Variant(scheme: .dark, size: .large),
            Variant(scheme: .light, size: large),
            Variant(scheme: .dark, size: large)
        ]
    }

    /// The sealed Results' VoiceOver value before a vote (spec 3.8.3).
    private static let sealedNotVoted = "Vote to see results. They open after you vote Yea, Nay or Abstain, so other people's votes don't sway yours."

    // MARK: - Vote panel (Civic Record spec 3.10, 3.11, 5.1)

    /// Every state of the panel (spec 10.1): before, inked, the stamp for each vote, the no-date form,
    /// changing, `.updatedOnly`, checking, the coach mark, refused (a first vote and a change).
    private struct PanelState {
        let name: String
        let model: BillVoteBarModel
        var coachMark = false
        var refusal: String? = nil
        var votedAt: Date? = BillDetailRenderTests.october17
        var inked: VoteChoice? = nil
        /// A resting state (choose, coach mark, voted), held to a quarter of the screen at every size (7.2).
        var isResting: Bool
    }

    /// October 17, 2026 at noon in New York: the stamp reads "OCT 17".
    private nonisolated static let october17: Date = {
        var components = DateComponents(year: 2026, month: 10, day: 17, hour: 12)
        components.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    private static let refusalText = AuthErrorMessages.voteDailyLimit

    private static let panelStates: [PanelState] = [
        PanelState(name: "choose", model: BillVoteBarModel(mode: .full, choice: nil), isResting: true),
        PanelState(name: "coach-mark", model: BillVoteBarModel(mode: .full, choice: nil), coachMark: true, isResting: true),
        PanelState(name: "inked-yea", model: BillVoteBarModel(mode: .full, choice: .yea), inked: .yea, isResting: true),
        PanelState(name: "voted-yea", model: BillVoteBarModel(mode: .full, choice: .yea), isResting: true),
        PanelState(name: "voted-nay", model: BillVoteBarModel(mode: .full, choice: .nay), isResting: true),
        PanelState(name: "abstained", model: BillVoteBarModel(mode: .full, choice: .abstain), isResting: true),
        PanelState(name: "voted-no-date", model: BillVoteBarModel(mode: .full, choice: .yea), votedAt: nil, isResting: true),
        PanelState(name: "checking", model: BillVoteBarModel(mode: .full, choice: nil, isChecking: true), isResting: false),
        PanelState(name: "updated", model: BillVoteBarModel(mode: .updatedOnly, choice: nil), isResting: false),
        PanelState(name: "changing-from-nay", model: BillVoteBarModel(mode: .full, choice: .nay, isChanging: true), isResting: false),
        PanelState(name: "refused", model: BillVoteBarModel(mode: .full, choice: nil), refusal: refusalText, isResting: false),
        PanelState(name: "refused-change", model: BillVoteBarModel(mode: .full, choice: .yea), refusal: refusalText, isResting: false)
    ]

    private func panel(_ state: PanelState) -> some View {
        BillVoteBar(
            model: state.model,
            showsCoachMark: state.coachMark,
            refusal: state.refusal,
            votedAt: state.votedAt,
            inked: state.inked,
            onVote: { _ in },
            onChange: {},
            onCollapse: {}
        )
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.timeZone, TimeZone(identifier: "America/New_York")!)
    }

    private func panel(_ model: BillVoteBarModel, coachMark: Bool = false, refusal: String? = nil, votedAt: Date? = BillDetailRenderTests.october17, inked: VoteChoice? = nil) -> some View {
        panel(PanelState(name: "", model: model, coachMark: coachMark, refusal: refusal, votedAt: votedAt, inked: inked, isResting: true))
    }

    /// The panel's width on a phone `screen` points wide: 12 pt in from each side.
    private static func panelWidth(onScreen screen: CGFloat) -> CGFloat {
        screen - 2 * BillVoteBar.sideMargin
    }

    func testTheVotePanelRendersInEveryState() throws {
        let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility3, .accessibility5]
        for scheme in [ColorScheme.light, .dark] {
            for size in sizes {
                let variant = Variant(scheme: scheme, size: size)
                for state in Self.panelStates {
                    let image = try render(panel(state), variant: variant, width: Self.panelWidth(onScreen: 393))
                    attach(image, name: "vote-panel-\(state.name)-\(variant.name)")
                    XCTAssertGreaterThanOrEqual(CGFloat(image.height), 2 * BillVoteBar.panelPadding + 44, "\(state.name) \(variant.name): one 44 pt control at least")
                }
            }
        }
    }

    /// Reduce Transparency and Increase Contrast draw the panel solid: the sheet with a 1 pt rule (spec 2.9).
    func testThePanelFallsBackToASolidSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            for (name, reduceTransparency, increaseContrast) in [("reduce-transparency", true, false), ("increase-contrast", false, true)] {
                let view = panel(BillVoteBarModel(mode: .full, choice: .yea))
                    .environment(\._accessibilityReduceTransparency, reduceTransparency)
                    .environment(\._colorSchemeContrast, increaseContrast ? .increased : .standard)
                let image = try render(view, variant: Variant(scheme: scheme, size: .large), width: Self.panelWidth(onScreen: 393))
                attach(image, name: "vote-panel-\(name)-\(scheme == .dark ? "dark" : "light")")
                // The panel's padding, between its edge and the stamp: the opaque sheet, not glass.
                assertColor(try pixel(of: image, x: Int(image.width / 2), y: 5), BillboardPalette.cardBackground.resolved(dark: dark).rgb, accuracy: 0.02, "\(name) \(scheme)")
            }
        }
    }

    /// The refused vote's strip draws its `danger` rule 1.5 pt wide, and 2 pt with Increase Contrast, as the
    /// ballot buttons, the stamp and Change widen theirs (spec 2.9, 7.6). Measured at 4x down the middle of the
    /// strip from its top edge, in a refused panel at the default size.
    func testTheRefusalStripsRuleWidensWithIncreaseContrast() throws {
        let width = Self.panelWidth(onScreen: 393)
        let scale: CGFloat = 4
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
            for increaseContrast in [false, true] {
                let renderer = ImageRenderer(
                    content: panel(BillVoteBarModel(mode: .full, choice: nil), refusal: Self.refusalText)
                        .environment(\.colorScheme, scheme)
                        .environment(\._colorSchemeContrast, increaseContrast ? .increased : .standard)
                )
                renderer.scale = scale
                renderer.proposedSize = ProposedViewSize(width: width, height: nil)
                let image = try XCTUnwrap(renderer.cgImage)
                let name = "refused-\(scheme == .dark ? "dark" : "light")\(increaseContrast ? "-increase-contrast" : "")"
                attach(image, name: "vote-panel-\(name)")
                let pixels = try bitmap(image)
                let top = Int(BillVoteBar.panelPadding * scale)
                let rule = (top..<(top + Int(4 * scale))).filter { distance(pixels[$0][image.width / 2], sheet) > 0.15 }
                let expected = increaseContrast ? VoteStrip.refusalRuleWidthHighContrast : VoteStrip.refusalRuleWidth
                XCTAssertEqual(rule.count, Int(expected * scale), "\(name): the rule's pixel rows \(rule)")
                XCTAssertEqual(rule.first, top, "\(name): the rule starts at the strip's top edge")
            }
        }
    }

    /// The three buttons share the row equally and are the vote colour at 7% (6% in dark mode) over the
    /// opaque sheet, with the ballot box (spec 3.10).
    func testTheBallotButtonsAreEqualAndUseTheVotePalette() throws {
        let width = Self.panelWidth(onScreen: 393)
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(panel(BillVoteBarModel(mode: .full, choice: nil)), variant: Variant(scheme: scheme, size: .large), width: width)
            XCTAssertEqual(CGFloat(image.height), 2 * BillVoteBar.panelPadding + BillVoteBarModel.minimumControlHeight, accuracy: 1, "50 pt buttons in a 10 pt padding")
            let dark = scheme == .dark
            let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
            let tint = BallotButtonStyle.tintOpacity(dark: dark)
            let cell = (width - 2 * BillVoteBar.panelPadding - 2 * BillVoteBar.spacing) / 3
            for (index, choice) in VoteChoice.allCases.enumerated() {
                let x = Int(BillVoteBar.panelPadding + CGFloat(index) * (cell + BillVoteBar.spacing) + 8)
                let sample = try pixel(of: image, x: x, y: image.height / 2)
                let expected = BillboardColorMath.composite(choice.paletteToken.resolved(dark: dark).rgb, alpha: tint, over: sheet)
                assertColor(sample, expected, accuracy: 0.02, "\(choice) \(scheme)")
            }
        }
    }

    /// The opaque-fill pixel test (spec 7.1, 10.1): the buttons, the stamp, Change and the strips are opaque
    /// fills on the glass, so they draw the same over any ground: here white paper and the navy masthead.
    func testTheButtonsStampChangeAndStripsAreOpaqueOverAnyGround() throws {
        let width = Self.panelWidth(onScreen: 393)
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
            let tint = BallotButtonStyle.tintOpacity(dark: dark)
            func images<V: View>(_ content: V) throws -> [CGImage] {
                try [BillboardColors.textOnNavy, BillboardColors.navy].map { ground in
                    try render(content.background(ground), variant: Variant(scheme: scheme, size: .large), width: width)
                }
            }
            // The buttons: the tinted sheet, 8 pt in from the ring.
            for image in try images(panel(BillVoteBarModel(mode: .full, choice: nil))) {
                let yea = BillboardColorMath.composite(VoteChoice.yea.paletteToken.resolved(dark: dark).rgb, alpha: tint, over: sheet)
                assertColor(try pixel(of: image, x: Int(BillVoteBar.panelPadding + 8), y: image.height / 2), yea, accuracy: 0.02, "Yea button \(scheme)")
            }
            // The stamp (inside its inner rule) and Change (inside its capsule, by the word).
            for image in try images(panel(BillVoteBarModel(mode: .full, choice: .yea))) {
                assertColor(try pixel(of: image, x: Int(BillVoteBar.panelPadding + 7), y: image.height / 2), sheet, accuracy: 0.02, "stamp \(scheme)")
                assertColor(try pixel(of: image, x: Int(width - BillVoteBar.panelPadding - 12), y: image.height / 2), sheet, accuracy: 0.02, "Change \(scheme)")
            }
            // A strip: the refusal's, 6 pt under its top rule.
            for image in try images(panel(BillVoteBarModel(mode: .full, choice: nil), refusal: Self.refusalText)) {
                assertColor(try pixel(of: image, x: Int(width / 2), y: Int(BillVoteBar.panelPadding + 6)), sheet, accuracy: 0.02, "refusal strip \(scheme)")
            }
        }
    }

    /// The tapped button inks (spec 5.1): the solid vote colour with the stamp's inner rule; the other two fade
    /// to 45%.
    func testTheInkedButtonIsTheSolidVoteColour() throws {
        let width = Self.panelWidth(onScreen: 393)
        let cell = (width - 2 * BillVoteBar.panelPadding - 2 * BillVoteBar.spacing) / 3
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let image = try render(
                panel(BillVoteBarModel(mode: .full, choice: .nay), inked: .nay).background(BillboardColors.document),
                variant: Variant(scheme: scheme, size: .large),
                width: width
            )
            let nay = try pixel(of: image, x: Int(BillVoteBar.panelPadding + cell + BillVoteBar.spacing + 8), y: image.height / 2)
            assertColor(nay, BillboardPalette.voteNay.resolved(dark: dark).rgb, accuracy: 0.02, "the inked Nay (\(scheme))")
            let yea = try pixel(of: image, x: Int(BillVoteBar.panelPadding + 8), y: image.height / 2)
            let full = BillboardColorMath.composite(VoteChoice.yea.paletteToken.resolved(dark: dark).rgb, alpha: BallotButtonStyle.tintOpacity(dark: dark), over: BillboardPalette.cardBackground.resolved(dark: dark).rgb)
            XCTAssertGreaterThan(distance(yea, full), 0.01, "Yea faded (\(scheme))")
        }
    }

    /// While changing, the current vote is not filled: the tinted sheet, a heavier ring and "Your vote" under its
    /// word, read "Vote Nay, your current vote" with the selected trait; "Change your vote" and Cancel above.
    func testTheChangingStateMarksTheCurrentVote() throws {
        let width = Self.panelWidth(onScreen: 393)
        let image = try render(panel(BillVoteBarModel(mode: .full, choice: .nay, isChanging: true)), variant: Variant(scheme: .light, size: .large), width: width)
        let cell = (width - 2 * BillVoteBar.panelPadding - 2 * BillVoteBar.spacing) / 3
        let sheet = BillboardPalette.cardBackground.light.rgb
        let nayTint = BillboardColorMath.composite(BillboardPalette.voteNay.light.rgb, alpha: BallotButtonStyle.tintOpacity(dark: false), over: sheet)
        let sample = try pixel(of: image, x: Int(BillVoteBar.panelPadding + cell + BillVoteBar.spacing + 8), y: image.height - Int(BillVoteBar.panelPadding) - 20)
        assertColor(sample, nayTint, accuracy: 0.02, "the current vote is drawn unfilled")

        let host = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .full, choice: .nay, isChanging: true)), size: CGSize(width: width, height: 300))
        defer { host.close() }
        let text = host.text()
        for shown in [BillVoteBarModel.changingCaption, BillVoteBarModel.cancelTitle, "Vote Yea", "Vote Nay, your current vote", "Abstain"] {
            XCTAssertTrue(host.strings().contains(shown), "\(shown) in: \(text)")
        }
        XCTAssertEqual(host.traits(of: "Vote Nay, your current vote")?.contains(.selected), true)
        XCTAssertEqual(host.identifier(of: BillVoteBarModel.cancelTitle), BillVoteBarModel.cancelIdentifier)
    }

    func testANarrowPanelFallsBackToOneVoteButton() throws {
        // Too narrow for three equal buttons: one full-width Vote button instead, the primary ink capsule.
        let narrow = try render(panel(BillVoteBarModel(mode: .full, choice: nil)), variant: Variant(scheme: .light, size: .large), width: 200)
        attach(narrow, name: "vote-panel-compact-light")
        let sample = try pixel(of: narrow, x: 30, y: narrow.height / 2)
        assertColor(sample, BillboardPalette.interactive.light.rgb, accuracy: 0.03, "the compact Vote button")
    }

    /// The stamp's width forms (spec 3.10): the dated stamp beside Change where it fits (a 393 pt phone at the
    /// default size), the no-date form where it does not (375 pt; 393 pt one size up), the stamp and Change
    /// stacked at xxxLarge. The forms are told apart by drawing the same vote with and without a date.
    func testTheStampTakesTheDatedNoDateOrStackedForm() throws {
        func images(screen: CGFloat, size: DynamicTypeSize) throws -> (dated: CGImage, noDate: CGImage) {
            let variant = Variant(scheme: .light, size: size)
            let width = Self.panelWidth(onScreen: screen)
            return (
                try render(panel(BillVoteBarModel(mode: .full, choice: .yea)), variant: variant, width: width),
                try render(panel(BillVoteBarModel(mode: .full, choice: .yea), votedAt: nil), variant: variant, width: width)
            )
        }
        func same(_ a: CGImage, _ b: CGImage) -> Bool {
            guard a.width == b.width, a.height == b.height,
                  let da = a.dataProvider?.data as Data?, let db = b.dataProvider?.data as Data? else { return false }
            return da == db
        }
        let wide = try images(screen: 393, size: .large)
        XCTAssertFalse(same(wide.dated, wide.noDate), "393 pt, default size: the dated stamp")
        let narrow = try images(screen: 375, size: .large)
        XCTAssertTrue(same(narrow.dated, narrow.noDate), "375 pt, default size: the no-date form")
        let larger = try images(screen: 393, size: .xLarge)
        XCTAssertTrue(same(larger.dated, larger.noDate), "393 pt, xLarge: the no-date form")
        let stacked = try images(screen: 375, size: .xxxLarge)
        XCTAssertGreaterThan(CGFloat(stacked.dated.height), 2 * BillVoteBar.panelPadding + 2 * BillVoteBarModel.minimumControlHeight, "xxxLarge: the stamp over Change")
        // The stamp is one view that drops its date to fit (so it can be matched with the inked button), and only
        // ever a row: even the narrowest panel (a 320 pt screen, an SE with Display Zoom) holds its no-date row at
        // every size the panel shows it, so the panel needs no box-over-the-words form.
        let narrowest = Self.panelWidth(onScreen: 320)
        for size in [DynamicTypeSize.large, .xLarge, .xxLarge, .xxxLarge] {
            for choice in VoteChoice.allCases {
                let image = try render(panel(BillVoteBarModel(mode: .full, choice: choice), votedAt: nil), variant: Variant(scheme: .light, size: size), width: narrowest)
                XCTAssertEqual(CGFloat(image.width), narrowest, "\(choice) \(size): the stamp fits a 320 pt screen")
            }
        }
        attach(wide.dated, name: "vote-panel-stamp-dated-393")
        attach(narrow.dated, name: "vote-panel-stamp-no-date-375")
        attach(stacked.dated, name: "vote-panel-stamp-stacked-375-xxxLarge")
    }

    /// The stamp is one element, "You voted Yea on October 17" (the no-date form: "You voted Yea"), id
    /// `bill.vote.summary`, with "Go to Results"; Change reads "Change your vote" and answers to "Change".
    func testTheStampAndChangeReadAsTheSpecSays() {
        let width = Self.panelWidth(onScreen: 393)
        for (votedAt, label) in [(Self.october17 as Date?, "You voted Yea on October 17"), (nil, "You voted Yea")] {
            let host = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .full, choice: .yea), votedAt: votedAt), size: CGSize(width: width, height: 300))
            defer { host.close() }
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), label, host.text())
            XCTAssertEqual(host.actionNames(ofIdentifier: BillVoteBarModel.summaryIdentifier), [BillVoteBarModel.goToResultsAction])
            XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.changeIdentifier), "Change your vote")
            for gone in ["YOU VOTED YEA", "OCT 17", "Vote saved"] {
                XCTAssertFalse(host.text().contains(gone), "\(gone) in: \(host.text())")
            }
        }
        let abstained = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .full, choice: .abstain)), size: CGSize(width: width, height: 300))
        defer { abstained.close() }
        XCTAssertEqual(abstained.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "You abstained on October 17")
    }

    /// The strips read as one element each: the caption with its id, the coach mark with Not now, the refusal
    /// as "Error: …" with its id (spec 3.10.1, 3.10.2, 7.3).
    func testTheStripsReadAsTheSpecSays() {
        let width = Self.panelWidth(onScreen: 393)
        let refused = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .full, choice: nil), refusal: Self.refusalText), size: CGSize(width: width, height: 400))
        defer { refused.close() }
        XCTAssertEqual(refused.label(ofIdentifier: BillVoteBarModel.refusalIdentifier), "Error: \(Self.refusalText)")
        XCTAssertTrue(refused.strings().contains("Vote Yea"), "the buttons under it: \(refused.text())")

        let coach = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .full, choice: nil), coachMark: true), size: CGSize(width: width, height: 400))
        defer { coach.close() }
        XCTAssertTrue(coach.text().contains(BillVoteBarModel.coachMarkText), coach.text())
        XCTAssertEqual(coach.identifier(of: BillVoteBarModel.coachMarkDismissTitle), BillVoteBarModel.coachMarkDismissIdentifier)

        let updated = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .updatedOnly, choice: nil)), size: CGSize(width: width, height: 400))
        defer { updated.close() }
        XCTAssertEqual(updated.identifier(of: BillVoteBarModel.updatedCaption), BillVoteBarModel.captionIdentifier)

        // The caption comes before the coach mark (project decision of 2026-10-21): one strip, the caption.
        let updatedFromTour = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .updatedOnly, choice: nil), coachMark: true), size: CGSize(width: width, height: 400))
        defer { updatedFromTour.close() }
        XCTAssertEqual(updatedFromTour.identifier(of: BillVoteBarModel.updatedCaption), BillVoteBarModel.captionIdentifier)
        XCTAssertFalse(updatedFromTour.text().contains(BillVoteBarModel.coachMarkText), updatedFromTour.text())
        XCTAssertNil(updatedFromTour.identifier(of: BillVoteBarModel.coachMarkDismissTitle), updatedFromTour.text())

        let checking = AccessibilityTreeText.Host(panel(BillVoteBarModel(mode: .full, choice: nil, isChecking: true)), size: CGSize(width: width, height: 400))
        defer { checking.close() }
        XCTAssertTrue(checking.strings().contains(BillVoteBarModel.checkingCaption), checking.text())
        XCTAssertEqual(checking.traits(of: "Vote Yea")?.contains(.notEnabled), true, "the buttons wait for the check")
    }

    /// At the accessibility sizes the panel holds one full-width button: "Vote", "Checking…", or the voted
    /// capsule read "You voted Yea on October 17" with the hint "Change your vote", id `bill.vote.change`
    /// (spec 3.10, frames 23 and 24). No strip is in the panel.
    func testTheAccessibilitySizesHoldOneButton() {
        let width = Self.panelWidth(onScreen: 375)
        func host(_ model: BillVoteBarModel, size: DynamicTypeSize, coachMark: Bool = false, refusal: String? = nil) -> AccessibilityTreeText.Host {
            AccessibilityTreeText.Host(
                panel(model, coachMark: coachMark, refusal: refusal).environment(\.dynamicTypeSize, size),
                size: CGSize(width: width, height: 600)
            )
        }
        for size in [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5] {
            let vote = host(BillVoteBarModel(mode: .full, choice: nil), size: size, coachMark: true, refusal: Self.refusalText)
            XCTAssertEqual(vote.label(ofIdentifier: BillVoteBarModel.compactIdentifier), BillVoteBarModel.compactTitle, "\(size): \(vote.text())")
            for gone in ["Vote Yea", BillVoteBarModel.coachMarkText, "Error: \(Self.refusalText)"] {
                XCTAssertFalse(vote.strings().contains(gone), "\(size): \(gone) in: \(vote.text())")
            }
            vote.close()

            let checking = host(BillVoteBarModel(mode: .full, choice: nil, isChecking: true), size: size)
            XCTAssertEqual(checking.label(ofIdentifier: BillVoteBarModel.compactIdentifier), BillVoteBarModel.checkingTitle)
            XCTAssertEqual(checking.traits(of: BillVoteBarModel.checkingTitle)?.contains(.notEnabled), true)
            checking.close()

            let voted = host(BillVoteBarModel(mode: .full, choice: .yea), size: size)
            XCTAssertEqual(voted.label(ofIdentifier: BillVoteBarModel.changeIdentifier), "You voted Yea on October 17", "\(size)")
            XCTAssertNil(voted.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "the stamp is in Your vote at \(size)")
            voted.close()
        }
    }

    /// The voted button at the accessibility sizes says "Yea · Change" where that fits on one line, and
    /// "Change" alone where it does not (AX4 and AX5 on 375 to 393 pt screens).
    func testTheVotedButtonFallsBackToChangeAtTheLargestSizes() throws {
        let model = BillVoteBarModel(mode: .full, choice: .yea)
        let ax1 = try render(panel(model), variant: Variant(scheme: .light, size: .accessibility1), width: Self.panelWidth(onScreen: 393))
        let ax5 = try render(panel(model), variant: Variant(scheme: .light, size: .accessibility5), width: Self.panelWidth(onScreen: 393))
        attach(ax1, name: "vote-panel-voted-button-AX1")
        attach(ax5, name: "vote-panel-voted-button-AX5")
        // "Yea · Change" puts the filled box (the vote colour) at the leading side of the label; "Change" alone
        // is ink in the middle. Look for the vote colour across the button's middle row.
        func hasVoteColour(_ image: CGImage) throws -> Bool {
            let yea = BillboardPalette.voteYea.light.rgb
            for x in stride(from: 20, to: image.width - 20, by: 2) {
                if distance(try pixel(of: image, x: x, y: image.height / 2), yea) < 0.06 { return true }
            }
            return false
        }
        XCTAssertTrue(try hasVoteColour(ax1), "AX1: Yea · Change")
        XCTAssertFalse(try hasVoteColour(ax5), "AX5: Change alone")
    }

    // MARK: - The bottom stack (spec 7.2, 10.1)

    /// On a 375 × 667 phone (no home indicator, so a 12 pt margin) the vote panel and its margin take at most a
    /// quarter of the height (166.75 pt) in the resting states at Large, xxxLarge, AX3 and AX5; the passing
    /// states (checking, `.updatedOnly`, changing, refused) at most a quarter at Large and a third (222.3 pt)
    /// at the larger sizes. The tab capsule is not there (the bill page hides it).
    func testTheBottomStackStaysWithinItsBudgetOnA375By667Phone() throws {
        let screen = CGSize(width: 375, height: 667)
        let margin = BillDetail.panelBottomPadding(safeAreaBottom: 0)
        XCTAssertEqual(margin, 12)
        var report: [String] = []
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            for state in Self.panelStates {
                let image = try render(panel(state), variant: Variant(scheme: .light, size: size), width: Self.panelWidth(onScreen: screen.width))
                let stack = CGFloat(image.height) + margin
                let budget = state.isResting || size == .large ? screen.height / 4 : screen.height / 3
                report.append("\(state.name) \(size): \(Int(stack)) pt (\(Int((stack / screen.height * 100).rounded()))%)")
                XCTAssertLessThanOrEqual(stack, budget, "\(state.name) at \(size): \(stack) pt of \(budget)")
            }
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "bottom-stack-375x667"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Your vote (Civic Record spec 3.13)

    private func voteSection(
        _ standing: BillYourVoteSection.Standing,
        watching: Bool = false,
        reasonsFor voteType: VoteType? = nil,
        reasons: Set<VoteReason> = [],
        companion: Bool = false
    ) -> some View {
        BillYourVoteSection(
            standing: standing,
            isWatching: watching,
            showsReasonPicker: voteType != nil,
            selectedReasons: reasons,
            reasonVoteType: voteType,
            reasonOrder: voteType.map { VoteReasonOrder.order(for: $0, seed: Self.reasonSeed) } ?? [],
            onToggleReason: { _ in },
            onSetWatch: { _ in },
            companionCaption: companion ? "These bills have identical text. Your vote counts once for both." : nil,
            companionConflictNote: companion
                ? "Before these were combined you also voted Nay on S. 456. Your H.R. 900 vote is the one that counts."
                : nil
        )
        .background(BillboardColors.document)
    }

    /// A person's seed for the reasons' order (`VoteReasonOrder`): an account ID.
    private static let reasonSeed = "3f2a9c4e-0b1d-4e8f-9a7c-5d6e1f2a3b4c"

    /// Every row of 3.13 (no read-only page: project decision 1): not voted, checking, a failed check, voted
    /// earlier (with the companion notes), a Yea or Nay made here (the reasons picker, one and three chosen),
    /// an Abstain held, an Abstain made here (its small picker, N13), and watching.
    private func yourVoteStates() -> [(name: String, view: AnyView)] {
        [
            ("not-voted", AnyView(voteSection(.notVoted))),
            ("checking", AnyView(voteSection(.checking))),
            ("check-failed", AnyView(voteSection(.checkFailed))),
            ("voted-earlier-companion", AnyView(voteSection(.voted, companion: true))),
            ("yea-here-one-reason", AnyView(voteSection(.voted, reasonsFor: .yea, reasons: [.economicImpact]))),
            ("nay-here-three-reasons", AnyView(voteSection(.voted, watching: true, reasonsFor: .nay, reasons: Set(VoteReason.allCases.prefix(VoteReason.maxSelections))))),
            ("abstain-here", AnyView(voteSection(.voted))),
            ("abstain-here-reasons", AnyView(voteSection(.voted, reasonsFor: .abstain, reasons: [.needMoreInfo]))),
            ("not-voted-watching", AnyView(voteSection(.notVoted, watching: true)))
        ]
    }

    func testYourVoteRendersEveryState() throws {
        for variant in Self.variants(.accessibility3) {
            for (name, view) in yourVoteStates() {
                let image = try render(view, variant: variant, width: 390)
                attach(image, name: "your-vote-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 80, "\(name) \(variant.name)")
            }
        }
    }

    /// Your vote opens with where the vote stands until one is held, then says nothing about it (the vote
    /// bar shows it). R2's "Vote saved", the vote badge ("Not voted yet", "Yea") and the "Watch for changes"
    /// nudge are gone (project decision 9); the Watch row is always there.
    func testYourVoteOpensWithItsFirstLineAndDropsR2sExtras() {
        let expectedLine: [String: String?] = [
            "not-voted": "You haven't voted on this bill.",
            "checking": "Checking your vote…",
            "check-failed": "Couldn't check your vote on this bill.",
            "voted-earlier-companion": nil,
            "yea-here-one-reason": nil,
            "nay-here-three-reasons": nil,
            "abstain-here": nil,
            "abstain-here-reasons": nil,
            "not-voted-watching": "You haven't voted on this bill."
        ]
        let firstLines = ["You haven't voted on this bill.", "Checking your vote…", "Couldn't check your vote on this bill."]
        for (name, view) in yourVoteStates() {
            let text = AccessibilityTreeText.text(of: view)
            XCTAssertTrue(text.hasPrefix("Your vote"), "\(name): the section title first: \(text)")
            let expected = expectedLine[name] ?? nil
            for line in firstLines {
                XCTAssertEqual(text.contains(line), line == expected, "\(name): \(line) in: \(text)")
            }
            XCTAssertTrue(text.contains(BillWatchCopy.rowTitle), "\(name): the Watch row: \(text)")
            // The vote itself is not repeated; after an Abstain made here the picker's title names it, as
            // "Why Yea?" does a Yea.
            let gone = ["Vote saved", "Watch for changes", "Not voted yet", "You voted", "You abstained"]
                + (name == "abstain-here-reasons" ? [] : ["Abstain"])
            for gone in gone {
                XCTAssertFalse(text.contains(gone), "\(name): \(gone) in: \(text)")
            }
        }
        XCTAssertEqual(BillYourVoteSection.Standing.voted.text, nil)
        XCTAssertEqual(BillYourVoteSection.Standing.checkFailed.text, VoteResultsFormatting.checkFailedText)
    }

    /// The reasons picker (spec 3.13.1): "Why Yea? (optional)" as a heading, the counter read as "1 of 3
    /// chosen", the hint, and each reason a selectable tag with its id; once three are chosen the others
    /// cannot be chosen.
    func testTheReasonsPickerUsesSelectableTags() {
        let one = AccessibilityTreeText.Host(voteSection(.voted, reasonsFor: .yea, reasons: [.economicImpact]))
        defer { one.close() }
        XCTAssertTrue(one.activate(VoteReasonPicker.moreTitle), "More reasons shows the rest: \(one.text())")
        let text = one.text()
        for shown in ["Why Yea? (optional)", "1 of 3 chosen", VoteReasonPicker.hint] {
            XCTAssertTrue(text.contains(shown), "\(shown) in: \(text)")
        }
        XCTAssertEqual(VoteReasonPicker.hint, "Choose up to 3 reasons. They're shown only as anonymous counts of 5 or more. You can skip this.")
        XCTAssertEqual(VoteReasonPicker.title(for: .nay), "Why Nay? (optional)")
        XCTAssertEqual(one.traits(of: "Why Yea? (optional)")?.contains(.header), true, "the picker's title is a heading")
        for reason in VoteReason.yeaNayReasons {
            XCTAssertEqual(one.identifier(of: reason.title), "bill.feedback.\(reason.rawValue)", reason.title)
        }
        XCTAssertNil(one.identifier(of: VoteReason.needMoreInfo.title), "Need More Information contradicts a Yea (N13): \(one.text())")
        XCTAssertEqual(one.traits(of: VoteReason.economicImpact.title)?.contains(.selected), true, "the chosen reason")
        let unchosen = VoteReason.yeaNayReasons.first { $0 != .economicImpact }!
        XCTAssertEqual(one.traits(of: unchosen.title)?.contains(.selected), false)

        let chosen = Set(VoteReason.yeaNayReasons.prefix(VoteReason.maxSelections))
        let full = AccessibilityTreeText.Host(voteSection(.voted, reasonsFor: .nay, reasons: chosen))
        defer { full.close() }
        XCTAssertTrue(full.text().contains("3 of 3 chosen"), full.text())
        XCTAssertTrue(full.activate(VoteReasonPicker.moreTitle), full.text())
        for reason in VoteReason.yeaNayReasons where !chosen.contains(reason) {
            XCTAssertEqual(full.traits(of: reason.title)?.contains(.notEnabled), true, "\(reason.title) cannot be chosen")
        }
        XCTAssertNil(full.identifier(of: VoteReason.needMoreInfo.title), "not after a Nay either: \(full.text())")
    }

    /// After an Abstain the picker is small (N13): "Why Abstain? (optional)" as a heading, a line saying the
    /// reason is not shown to others, and Need More Information only, with no counter and no More reasons.
    func testAnAbstainOffersOnlyNeedMoreInformation() throws {
        XCTAssertEqual(VoteReason.offered(for: .abstain), [.needMoreInfo])
        XCTAssertEqual(VoteReason.offered(for: .yea), VoteReason.yeaNayReasons)
        XCTAssertEqual(VoteReason.offered(for: .nay), VoteReason.yeaNayReasons)
        XCTAssertEqual(VoteReasonPicker.title(for: .abstain), "Why Abstain? (optional)")
        XCTAssertEqual(VoteReasonPicker.hint(for: .abstain), "It isn't shown to other people. You can skip this.")
        XCTAssertEqual(VoteReasonPicker.hint(for: .yea), VoteReasonPicker.hint)

        for picked in [Set<VoteReason>(), [.needMoreInfo]] {
            let host = AccessibilityTreeText.Host(voteSection(.voted, reasonsFor: .abstain, reasons: picked))
            defer { host.close() }
            let text = host.text()
            XCTAssertEqual(host.traits(of: "Why Abstain? (optional)")?.contains(.header), true, text)
            XCTAssertTrue(text.contains(VoteReasonPicker.abstainHint), text)
            XCTAssertEqual(host.identifier(of: VoteReason.needMoreInfo.title), "bill.feedback.need_more_info", text)
            XCTAssertEqual(host.traits(of: VoteReason.needMoreInfo.title)?.contains(.selected), !picked.isEmpty, text)
            for reason in VoteReason.yeaNayReasons {
                XCTAssertNil(host.identifier(of: reason.title), "\(reason.title) after an Abstain: \(text)")
            }
            XCTAssertNil(host.identifier(of: VoteReasonPicker.moreTitle), "no More reasons: \(text)")
            XCTAssertFalse(text.contains("chosen"), "no counter: \(text)")
            XCTAssertFalse(text.contains(VoteReasonPicker.hint), "not the Yea or Nay hint: \(text)")
        }
    }

    /// After a Yea or Nay the picker is shorter (project decisions of 2026-10-21): the first three reasons in the
    /// person's order (project decision of 2026-10-28, `VoteReasonOrder`), any reason the user picked (in that order
    /// too), then "More reasons", which shows the rest and moves VoiceOver to the first reason it showed. The
    /// order never depends on how often others pick a reason (INT-11).
    func testTheReasonsPickerShowsTheFirstFewThenMoreReasons() {
        let order = VoteReasonOrder.order(for: .yea, seed: Self.reasonSeed)
        XCTAssertEqual(Set(order), Set(VoteReason.yeaNayReasons))
        XCTAssertEqual(VoteReasonPicker.leadingCount, 3)
        let leading = Array(order.prefix(VoteReasonPicker.leadingCount))
        let rest = Array(order.dropFirst(VoteReasonPicker.leadingCount))
        XCTAssertEqual(VoteReasonPicker.shownReasons(order: order, selected: [], expanded: false), leading)
        XCTAssertEqual(
            VoteReasonPicker.shownReasons(order: order, selected: [rest[5], rest[1]], expanded: false),
            leading + [rest[1], rest[5]],
            "picked reasons stay visible, in the person's order"
        )
        XCTAssertEqual(
            VoteReasonPicker.shownReasons(order: order, selected: [rest[9], rest[0], rest[4]], expanded: false),
            leading + [rest[0], rest[4], rest[9]],
            "all three picked reasons stay visible after the leading three"
        )
        XCTAssertEqual(VoteReasonPicker.shownReasons(order: order, selected: [leading[0]], expanded: false), leading)
        XCTAssertEqual(VoteReasonPicker.shownReasons(order: order, selected: [leading[2], rest[3]], expanded: false), leading + [rest[3]])
        XCTAssertEqual(VoteReasonPicker.shownReasons(order: order, selected: [], expanded: true), order)
        XCTAssertEqual(VoteReasonPicker.moreHint(hidden: 10), "Shows 10 more reasons.")
        XCTAssertEqual(VoteReasonPicker.moreHint(hidden: 1), "Shows 1 more reason.")

        let picked = rest[6]
        let host = AccessibilityTreeText.Host(voteSection(.voted, reasonsFor: .yea, reasons: [picked]))
        defer { host.close() }
        let shown = Set(leading + [picked])
        for reason in VoteReason.allCases {
            XCTAssertEqual(host.identifier(of: reason.title) != nil, shown.contains(reason), "\(reason.title) before More reasons: \(host.text())")
        }
        XCTAssertEqual(host.identifier(of: VoteReasonPicker.moreTitle), VoteReasonPicker.moreIdentifier)
        XCTAssertEqual(host.hint(of: VoteReasonPicker.moreTitle), "Shows 9 more reasons.")
        assertInOrder(leading.map(\.title) + [picked.title, VoteReasonPicker.moreTitle], in: host.strings(), "the leading reasons, the picked one, then More reasons")

        XCTAssertTrue(host.activate(VoteReasonPicker.moreTitle, settle: 0.5))
        assertInOrder(order.map(\.title), in: host.strings(), "every reason, in the person's order")
        XCTAssertNil(host.identifier(of: VoteReasonPicker.moreTitle), "More reasons is gone once they show")
        XCTAssertNil(host.identifier(of: VoteReason.needMoreInfo.title), "Need More Information is not offered after a Yea")
    }

    /// Your vote is a ruled section on the document, not a slip: no box, no shadow, no stripe. The pixels
    /// beside the title and at the section's edges are the document ground; the top edge is the hairline.
    func testYourVoteIsARuledSectionOnTheDocument() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let image = try render(voteSection(.notVoted), variant: Variant(scheme: scheme, size: .large), width: 390)
            let document = BillboardPalette.document.resolved(dark: dark).rgb
            let ruleToken = BillboardPalette.separator.resolved(dark: dark)
            let rule = BillboardColorMath.composite(ruleToken.rgb, alpha: ruleToken.alpha, over: document)
            // The hairline across the 20 pt gutter, at the top; the gutter itself is the ground.
            assertColor(try pixel(of: image, x: 195, y: 0), rule, accuracy: 0.02, "the hairline (\(scheme))")
            assertColor(try pixel(of: image, x: 10, y: 0), document, accuracy: 0.02, "no rule in the gutter (\(scheme))")
            for (x, y) in [(10, image.height / 2), (380, image.height / 2), (195, image.height - 3), (380, 20)] {
                assertColor(try pixel(of: image, x: x, y: y), document, accuracy: 0.02, "the ground at \(x),\(y) (\(scheme))")
            }
        }
    }

    // MARK: - Results, open (Civic Record spec 3.7, 4.41)

    /// No votes and 4 votes are under the floor (UX-34): the floor line alone. Withheld: Everyone over the floor
    /// beside verified voters under it. Regions withheld: Everyone minus Virginia's 5 leaves 2 (UX-34).
    private static func fixtures() throws -> [(String, BillStatsService.BillStats?)] {
        let noVotes = try VoteResultsFormattingTests.stats(comparison: nil)
        return [
            ("no-votes", noVotes), ("below-floor", try Self.belowFloorStats()), ("withheld", try Self.withheldStats()),
            ("regions-withheld", try Self.regionsWithheldStats()), ("both-rows", try Self.bothRowsStats()), ("loading", nil)
        ]
    }

    /// 2 Yea, 1 Nay and 1 Abstain: under the floor.
    private static func belowFloorStats(yea: Int = 2, nay: Int = 1) throws -> BillStatsService.BillStats {
        let decision = yea + nay
        let yeaPct: Double? = decision > 0 ? Double(yea) * 100 / Double(decision) : nil
        let pct = yeaPct.map { "\($0)" } ?? "null"
        return try VoteResultsFormattingTests.stats(
            totals: VoteResultsFormattingTests.totals(yea: yea, nay: nay, abstain: 1, yeaPct: yeaPct),
            comparison: #"{"allUsers":{"votes":\#(decision + 1),"yea":\#(yea),"nay":\#(nay),"abstain":1,"decisionVotes":\#(decision),"yeaPct":\#(pct)},"verifiedWithheld":true,"minDecisionVotes":5}"#
        )
    }

    /// 12 Yea or Nay votes from everyone, verified voters under the floor, no state over it (so no map).
    private static func withheldStats() throws -> BillStatsService.BillStats {
        try VoteResultsFormattingTests.stats(
            totals: VoteResultsFormattingTests.totals(yea: 7, nay: 5, abstain: 1, yeaPct: 58.3),
            comparison: #"{"allUsers":{"votes":13,"yea":7,"nay":5,"abstain":1,"decisionVotes":12,"yeaPct":58.3},"verifiedWithheld":true,"minDecisionVotes":5}"#
        )
    }

    /// 7 Yea or Nay votes from everyone, 5 of them verified in Virginia: Everyone minus Virginia would give away
    /// the other 2, so the state and district lines are withheld and the map hidden.
    private static func regionsWithheldStats() throws -> BillStatsService.BillStats {
        try VoteResultsFormattingTests.stats(
            totals: VoteResultsFormattingTests.totals(yea: 4, nay: 3, abstain: 0, yeaPct: 57.1),
            comparison: #"{"allUsers":{"votes":7,"yea":4,"nay":3,"abstain":0,"decisionVotes":7,"yeaPct":57.1},"verifiedWithheld":true,"minDecisionVotes":5}"#,
            byState: ["VA": VoteResultsFormattingTests.totals(yea: 3, nay: 2, abstain: 0, yeaPct: 60)],
            byDistrict: ["VA-11": ("VA", "VA-11", VoteResultsFormattingTests.totals(yea: 3, nay: 2, abstain: 0, yeaPct: 60))]
        )
    }

    /// Both rows, 1,157 votes from everyone (so the count is grouped), abstentions and the user's state.
    private static func bothRowsStats() throws -> BillStatsService.BillStats {
        try VoteResultsFormattingTests.stats(
            totals: VoteResultsFormattingTests.totals(yea: 706, nay: 451, abstain: 127, yeaPct: 61.0),
            comparison: #"{"allUsers":{"votes":1284,"yea":706,"nay":451,"abstain":127,"decisionVotes":1157,"yeaPct":61.0},"verified":{"votes":383,"yea":241,"nay":142,"abstain":0,"decisionVotes":383,"yeaPct":62.9},"verifiedWithheld":false,"minDecisionVotes":5}"#,
            byState: ["VA": VoteResultsFormattingTests.totals(yea: 38, nay: 29, abstain: 2, yeaPct: 56.7)]
        )
    }

    private func tallySheet(
        _ stats: BillStatsService.BillStats?,
        state: String = "VA",
        district: String = "11",
        yourVote: VoteChoice? = nil,
        error: String? = nil,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        BillResultsSection(
            billStats: stats,
            isLoadingBillStats: stats == nil && error == nil,
            billStatsError: error,
            userStateCode: state,
            userDistrictValue: district,
            yourVote: yourVote,
            onRetry: onRetry
        )
        .background(BillboardColors.document)
    }

    func testResultsRenderEveryFixture() throws {
        for variant in Self.variants(.accessibility3) {
            for (name, stats) in try Self.fixtures() {
                for (location, state, district) in [("with-location", "VA", "11"), ("state-missing", "", "")] {
                    let image = try render(tallySheet(stats, state: state, district: district), variant: variant, width: 390)
                    attach(image, name: "results-\(name)-\(location)-\(variant.name)")
                    XCTAssertGreaterThan(image.height, 80, "\(name) \(location)")
                }
            }
        }
    }

    /// The tally sheet after a Yea, a Nay and an Abstain made here, in light and dark at the default size and
    /// stacked at AX5 (spec 10.1): the "You" marker under Everyone's bar for Yea and Nay, "You abstained."
    /// under the abstained line for an Abstain, "The line marks 50%.", and each row one element.
    func testTheTallySheetMarksYourVote() throws {
        let stats = try Self.bothRowsStats()
        for (name, vote) in [("yea", VoteChoice.yea), ("nay", .nay), ("abstain", .abstain)] {
            for variant in Self.variants(.accessibility5) {
                let image = try render(tallySheet(stats, yourVote: vote), variant: variant, width: 390)
                attach(image, name: "tally-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 200, "\(name) \(variant.name)")
            }
            let text = AccessibilityTreeText.text(of: tallySheet(stats, yourVote: vote))
            for shown in [VoteResultsFormatting.majorityCaption, "127 people abstained.", "Verified voters in Virginia: 57 percent Yea, 43 percent Nay, 67 Yea or Nay votes", "Verified voters in Virginia's 11th district: "] {
                XCTAssertTrue(text.contains(shown), "\(shown) in: \(text)")
            }
            for code in ["Verified voters in VA", "VA-11"] {
                XCTAssertFalse(text.contains(code), "the place is read in words, not \(code): \(text)")
            }
            switch vote {
            case .yea, .nay:
                XCTAssertTrue(text.contains("Everyone: 61 percent Yea, 39 percent Nay, 1157 Yea or Nay votes. You voted \(vote.title)."), text)
                XCTAssertTrue(text.contains("Verified voters: 63 percent Yea, 37 percent Nay, 383 Yea or Nay votes"), text)
                XCTAssertFalse(text.contains("Verified voters: 63 percent Yea, 37 percent Nay, 383 Yea or Nay votes. You"), "the marker is Everyone's: \(text)")
                XCTAssertFalse(text.contains(VoteResultsFormatting.youAbstainedText), text)
            case .abstain:
                XCTAssertTrue(text.contains(VoteResultsFormatting.youAbstainedText), text)
                XCTAssertFalse(text.contains("You voted"), text)
            }
        }
    }

    /// The figures are grouped ("1,157"), every row and line keeps its id inside the section's own id, and the
    /// info button is there.
    func testTheTallySheetKeepsItsIds() throws {
        let host = AccessibilityTreeText.Host(tallySheet(try Self.bothRowsStats(), yourVote: .yea))
        defer { host.close() }
        XCTAssertEqual(host.label(ofIdentifier: "bill.results.everyone"), "Everyone: 61 percent Yea, 39 percent Nay, 1157 Yea or Nay votes. You voted Yea.")
        XCTAssertEqual(host.label(ofIdentifier: "bill.results.verified"), "Verified voters: 63 percent Yea, 37 percent Nay, 383 Yea or Nay votes")
        XCTAssertEqual(host.label(ofIdentifier: "bill.results.abstained"), "127 people abstained.")
        XCTAssertEqual(host.label(ofIdentifier: "bill.results.info"), VoteResultsFormatting.infoTitle)
        XCTAssertNotNil(host.label(ofIdentifier: "bill.results.local"))
        XCTAssertTrue(host.traits(of: VoteResultsFormatting.sectionTitle)?.contains(.header) == true)
    }

    /// Without an address: "See your state and district" and "Add your address"; with a state and no district:
    /// "See your district". No Yea or Nay votes: under the floor, "Results open at 5 votes" alone (UX-34 changed
    /// this test from 0% rows and "No Yea or Nay votes yet.").
    func testTheTallySheetAsksForAnAddressAndSaysWhenNobodyVoted() throws {
        let stats = try Self.bothRowsStats()
        let noState = AccessibilityTreeText.Host(tallySheet(stats, state: "", district: ""))
        XCTAssertEqual(noState.label(ofIdentifier: "bill.results.addAddress"), VoteResultsFormatting.addAddressTitle)
        XCTAssertTrue(noState.text().contains(VoteResultsFormatting.seeStateAndDistrictText), noState.text())
        noState.close()

        let noDistrict = AccessibilityTreeText.text(of: tallySheet(stats, state: "VA", district: ""))
        XCTAssertTrue(noDistrict.contains(VoteResultsFormatting.seeDistrictText), noDistrict)
        XCTAssertTrue(noDistrict.contains("Verified voters in Virginia: "), noDistrict)

        let none = AccessibilityTreeText.text(of: tallySheet(try VoteResultsFormattingTests.stats()))
        XCTAssertTrue(none.contains("Results open at 5 Yea or Nay votes."), none)
        for absent in [VoteResultsFormatting.noDecisionVotesText, VoteResultsFormatting.majorityCaption, "Everyone", VoteResultsFormatting.seeStateAndDistrictText] {
            XCTAssertFalse(none.contains(absent), "\(absent) in: \(none)")
        }
    }

    /// Under the floor (UX-34) Results are one line, "Results open at 5 votes", under the sheet's heavy rule, with
    /// "✓ You voted Yea" under it (or "You abstained."), and nothing else: no split, no abstain count, no count of
    /// the votes so far, no state or district and no map. The line and the marker are one VoiceOver element,
    /// "Results open at 5 Yea or Nay votes. You voted Yea." The project decision of 2026-10-29 changed this test: it
    /// pinned "· 3 votes so far" (and "3 so far." for VoiceOver); now the first voter and a later one see and hear
    /// the same line. Light, dark, AX3 and AX5 renders; the line wraps between words, never between "5" and its
    /// word (`FloorLine.displayText`).
    func testUnderTheFloorResultsAreOneLine() throws {
        let stats = try Self.belowFloorStats()
        let first = try Self.belowFloorStats(yea: 0, nay: 0)
        let largest = [Variant(scheme: .light, size: .accessibility5), Variant(scheme: .dark, size: .accessibility5)]
        for (name, vote) in [("yea", VoteChoice.yea), ("nay", .nay), ("abstain", .abstain)] {
            for (fixture, sample) in [("three", stats), ("first-voter", first)] {
                for variant in Self.variants(.accessibility3) + largest {
                    let image = try render(tallySheet(sample, yourVote: vote), variant: variant, width: 390)
                    attach(image, name: "results-below-floor-\(fixture)-\(name)-\(variant.name)")
                    XCTAssertGreaterThan(image.height, 60, "\(fixture) \(name) \(variant.name)")
                }

                let host = AccessibilityTreeText.Host(tallySheet(sample, yourVote: vote))
                let line = host.label(ofIdentifier: BillResultsBelowFloor.identifier)
                let text = host.text()
                host.close()
                switch vote {
                case .yea, .nay:
                    XCTAssertEqual(line, "Results open at 5 Yea or Nay votes. You voted \(vote.title).", fixture)
                case .abstain:
                    XCTAssertEqual(line, "Results open at 5 Yea or Nay votes.", fixture)
                    XCTAssertTrue(text.contains(VoteResultsFormatting.youAbstainedText), text)
                }
                XCTAssertTrue(text.contains("Results open at 5 votes") || text.contains("Results open at 5 Yea or Nay votes."), text)
                for leaked in ["%", "percent", "so far", "abstained.", "1 person", "3 votes", "Everyone", "Verified", "Map", "Fewer than", VoteResultsFormatting.seeStateAndDistrictText] where !(leaked == "abstained." && vote == .abstain) {
                    XCTAssertFalse(text.contains(leaked), "\(fixture) \(name): \(leaked) in: \(text)")
                }
                XCTAssertFalse(text.contains("1 person abstained."), text)
            }
        }
    }

    /// Over the floor, a row or line that would give away a smaller group says "Shown once more people vote"
    /// (UX-34): the state and district here, as Everyone minus Virginia would leave 2 votes. No map.
    func testWithheldRegionsSayTheyShowOnceMorePeopleVote() throws {
        let host = AccessibilityTreeText.Host(tallySheet(try Self.regionsWithheldStats(), yourVote: .yea))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Verified voters in Virginia: Shown once more people vote"), text)
        XCTAssertTrue(text.contains("Verified voters in Virginia's 11th district: Shown once more people vote"), text)
        XCTAssertTrue(text.contains("Everyone: 57 percent Yea, 43 percent Nay, 7 Yea or Nay votes. You voted Yea."), text)
        XCTAssertFalse(text.contains("Map"), text)
        XCTAssertFalse(text.contains("60 percent"), "Virginia's split: \(text)")
    }

    /// A failed load says so, with Try again that asks again.
    func testUnavailableResultsOfferTryAgain() {
        var retries = 0
        let host = AccessibilityTreeText.Host(tallySheet(nil, error: VoteResultsFormatting.unavailableText, onRetry: { retries += 1 }))
        defer { host.close() }
        XCTAssertTrue(host.text().contains(VoteResultsFormatting.unavailableText), host.text())
        XCTAssertEqual(host.label(ofIdentifier: BillResultsSection.retryIdentifier), VoteResultsFormatting.tryAgainTitle)
        XCTAssertTrue(host.activate(VoteResultsFormatting.tryAgainTitle))
        XCTAssertEqual(retries, 1)
    }

    /// The split bar (spec 3.7): square ends, Yea, a 2 pt gap, Nay, widths by Yea and Nay only, and the 2 pt
    /// ink tick at half the width standing 4 pt above and below the 8 pt bar.
    func testTheSplitBarIsSquareWithTheTickAtHalf() throws {
        let bar = VoteSplitBar(percentages: .init(yea: 61, nay: 39)).background(BillboardColors.document)
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let image = try render(bar, variant: Variant(scheme: scheme, size: .large), width: 200)
            attach(image, name: "split-bar-\(scheme)")
            XCTAssertEqual(image.height, 16, "8 pt bar and the tick's 4 pt above and below")
            let yea = BillboardPalette.voteYea.resolved(dark: dark).rgb
            let nay = BillboardPalette.voteNay.resolved(dark: dark).rgb
            let ink = BillboardPalette.ruleHeavy.resolved(dark: dark).rgb
            let ground = BillboardPalette.document.resolved(dark: dark).rgb
            // Square ends: the corner pixels are the vote colours.
            assertColor(try pixel(of: image, x: 0, y: 4), yea, accuracy: 0.03, "Yea's top corner (\(scheme))")
            assertColor(try pixel(of: image, x: 0, y: 11), yea, accuracy: 0.03, "Yea's bottom corner (\(scheme))")
            assertColor(try pixel(of: image, x: 199, y: 4), nay, accuracy: 0.03, "Nay's top corner (\(scheme))")
            assertColor(try pixel(of: image, x: 199, y: 11), nay, accuracy: 0.03, "Nay's bottom corner (\(scheme))")
            // The gap after 61% of the 198 pt the two segments share.
            assertColor(try pixel(of: image, x: 121, y: 8), ground, accuracy: 0.03, "the 2 pt gap (\(scheme))")
            // The tick at half the width, above and below the bar; nothing else stands out there.
            assertColor(try pixel(of: image, x: 99, y: 1), ink, accuracy: 0.05, "tick above (\(scheme))")
            assertColor(try pixel(of: image, x: 100, y: 14), ink, accuracy: 0.05, "tick below (\(scheme))")
            assertColor(try pixel(of: image, x: 50, y: 1), ground, accuracy: 0.03, "no overhang but the tick (\(scheme))")
        }
    }

    /// No Yea or Nay votes, and every sealed bar: an 8 pt outline in `rule2`, no fill and no tick.
    func testAnEmptyBarIsOutlinedWithNoTick() throws {
        for bar in [AnyView(TallyBlankBar()), AnyView(VoteSplitBar(percentages: nil))] {
            let view = bar.background(BillboardColors.document)
            for scheme in [ColorScheme.light, .dark] {
                let dark = scheme == .dark
                let image = try render(view, variant: Variant(scheme: scheme, size: .large), width: 200)
                XCTAssertEqual(image.height, 16)
                let ground = BillboardPalette.document.resolved(dark: dark).rgb
                let token = BillboardPalette.rule2.resolved(dark: dark)
                let rule = BillboardColorMath.composite(token.rgb, alpha: token.alpha, over: ground)
                assertColor(try pixel(of: image, x: 100, y: 4), rule, accuracy: 0.03, "the top edge (\(scheme))")
                assertColor(try pixel(of: image, x: 100, y: 8), ground, accuracy: 0.03, "no fill (\(scheme))")
                assertColor(try pixel(of: image, x: 100, y: 1), ground, accuracy: 0.03, "no tick (\(scheme))")
            }
        }
    }

    func testTheComparisonTableFallsBackToTextWhenNarrow() throws {
        let rows = VoteResultsFormatting.nationalRows(
            BillStatsService.Comparison(
                allUsers: .init(votes: 46, yea: 25, nay: 15, abstain: 6, decisionVotes: 40, yeaPct: 62.5),
                verified: nil,
                verifiedWithheld: true,
                minDecisionVotes: 5
            )
        )
        for width: CGFloat in [390, 180] {
            let image = try render(
                BillResultsComparison(rows: rows, yourVote: .nay).padding(8).background(BillboardColors.document),
                variant: Variant(scheme: .light, size: .large),
                width: width
            )
            attach(image, name: "results-table-\(Int(width))")
            XCTAssertGreaterThan(image.height, 0)
        }
    }

    /// After a vote made on the page the bars grow once, from nothing to their widths (spec 5.1), and end at
    /// the full split: the hosted sheet's Yea end is drawn a second after it appears.
    func testTheBarsGrowToTheirWidthsAfterAVoteHere() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let rows = VoteResultsFormatting.nationalRows(try Self.bothRowsStats().resolvedComparison)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
        window.overrideUserInterfaceStyle = .light
        let host = UIHostingController(rootView: BillResultsComparison(rows: rows, yourVote: .yea, grows: true)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(BillboardColors.document))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        attach(try XCTUnwrap(image.cgImage), name: "tally-grown")
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixels = try bitmap(cgImage)
        let yea = BillboardPalette.voteYea.light.rgb
        // Somewhere along the left gutter's edge, Everyone's bar starts with Yea at x = 20..22.
        let yeaRows = pixels.indices.filter { y in distance(pixels[y][21], yea) < 0.06 }
        XCTAssertFalse(yeaRows.isEmpty, "the Yea segment reached the leading edge")
    }

    // MARK: - Sealed Results (INT-11; Civic Record spec 3.8)

    /// Results with every kind of count: both rows, abstentions, the user's state and district, reasons. With
    /// fewer votes (under the floor), the same reasons at a minimum count of 1.
    private static func richStats(yea: Int = 25, nay: Int = 15) throws -> BillStatsService.BillStats {
        let pct = Double(yea) * 100 / Double(yea + nay)
        let totals = VoteResultsFormattingTests.totals(yea: yea, nay: nay, abstain: 6, yeaPct: pct)
        let split = #"{"votes":\#(yea + nay + 6),"yea":\#(yea),"nay":\#(nay),"abstain":6,"decisionVotes":\#(yea + nay),"yeaPct":\#(pct)}"#
        let body = #"{"billId":"BILLS-119hr900","totals":\#(totals),"#
            + #""segments":{"verified":\#(totals),"selfAttested":\#(totals)},"#
            + #""rollups":{"byState":{"VA":{"state":"VA","totals":\#(totals),"segments":{"verified":\#(totals),"selfAttested":\#(totals)}}},"#
            + #""byDistrict":{"VA-11":{"state":"VA","district":"11","totals":\#(totals),"segments":{"verified":\#(totals),"selfAttested":\#(totals)}}}},"#
            + #""reasonBreakdown":{"minCount":1,"yea":{"voteCount":\#(yea),"reasons":[{"reasonKey":"economic_impact","count":\#(min(7, yea)),"pct":28.0}]},"#
            + #""nay":{"voteCount":\#(nay),"reasons":[{"reasonKey":"economic_impact","count":\#(min(3, nay)),"pct":20.0}]}},"#
            + #""companionBillIds":["BILLS-119hr900","BILLS-119s456"],"#
            + #""comparison":{"allUsers":\#(split),"#
            + #""verified":\#(split),"verifiedWithheld":false,"minDecisionVotes":5}}"#
        return try JSONDecoder.convertingFromSnakeCase().decode(BillStatsService.BillStats.self, from: Data(body.utf8))
    }

    /// Bill detail's Results area as it stacks: Results and Why people voted, open or sealed. How Congress
    /// voted is further down the page, outside the area (spec 4.28), and never sealed.
    private func resultsArea(
        _ access: BillResultsAccess,
        stats: BillStatsService.BillStats?,
        isLoading: Bool = false,
        error: String? = nil,
        didVoteHere: Bool = false,
        onGoToVoteButtons: (() -> Void)? = {}
    ) -> some View {
        BillResultsArea(
            access: access,
            billStats: stats,
            isLoadingBillStats: isLoading,
            billStatsError: error,
            userStateCode: "VA",
            userDistrictValue: "11",
            didVoteHere: didVoteHere,
            yourVote: didVoteHere ? .yea : nil,
            onTryAgain: {},
            onRetryStats: {},
            onGoToVoteButtons: onGoToVoteButtons
        )
        .padding(.vertical, 16)
        .background(BillboardColors.document)
    }

    /// The locked states INT-11's access has (Civic Record project decision 1: no "Voting closed", no
    /// read-only open state).
    private static let lockedStates: [(name: String, access: BillResultsAccess)] = [
        ("sealed", .locked(.notVoted)),
        ("sealed-checking", .locked(.checking)),
        ("sealed-check-failed", .locked(.checkFailed)),
        ("awaiting-save", .awaitingSave(canRetry: true)),
        ("awaiting-save-no-retry", .awaitingSave(canRetry: false))
    ]

    /// Every string the sealed sheets may put in the accessibility tree: the two titles, "Sealed" or the
    /// spinner's words, the line and text under each sheet, and Try again. None is built from votes.
    private static let sealedCopy: Set<String> = {
        var copy: Set<String> = [
            VoteResultsFormatting.sectionTitle, BillVoteReasonsSection.title, VoteResultsFormatting.sealedLabel,
            VoteResultsFormatting.tryAgainTitle, VoteResultsFormatting.reasonsSealedText
        ]
        for state in [SealedTallyState.notVoted, .checking, .checkFailed, .awaitingSave(canRetry: true), .opening] {
            copy.insert(VoteResultsFormatting.sealedAccessibilityLabel(state))
            if let value = VoteResultsFormatting.sealedAccessibilityValue(state) { copy.insert(value) }
        }
        return copy
    }()

    /// Locked, nothing built from other users' votes is drawn or read out, even with stats at hand: no
    /// percentages, counts, abstentions, verified voters, map or reasons. Results and Why people voted keep
    /// their headings, and each sheet is one element, "Sealed" with the reason (spec 3.8.3), so the row
    /// names and column heads drawn in the sheet never reach the tree as text. How Congress voted stays.
    func testLockedResultsShowOnlyTheSealedSheet() throws {
        let stats = try Self.richStats()

        // The open area shows all of it, so the walk below would find a leak.
        let open = AccessibilityTreeText.text(of: resultsArea(.open, stats: stats))
        for shown in ["Everyone", "Verified voters", "people abstained", "votes", "Why people voted", "Map: verified voters", "Economic"] {
            XCTAssertTrue(open.contains(shown), "\(shown) in: \(open)")
        }

        for state in Self.lockedStates {
            let strings = AccessibilityTreeText.strings(of: resultsArea(state.access, stats: stats))
            let text = strings.joined(separator: " | ")
            let sealed = try XCTUnwrap(SealedTallyState(access: state.access, opening: false))
            XCTAssertTrue(strings.contains(VoteResultsFormatting.sealedAccessibilityLabel(sealed)), "\(state.name): \(text)")
            if let value = VoteResultsFormatting.sealedAccessibilityValue(sealed) {
                XCTAssertTrue(strings.contains(value), "\(state.name): \(text)")
            }
            // Why people voted says when reasons open under its stamp, and nothing beside the checking spinner.
            XCTAssertEqual(strings.contains(VoteResultsFormatting.reasonsSealedText), sealed.showsStamp, "\(state.name): \(text)")
            // What the sealed sheets may say is set out above; everything else is scanned for a leak.
            let scanned = strings.filter { !Self.sealedCopy.contains($0) }.joined(separator: " | ")
            for leaked in ["%", "percent", "Yea (", "Yea,", "abstained", "verified", "Verified", "Everyone", "Map", "map",
                           "Why people voted", "Combined votes", "Fewer than", "No Yea or Nay", "Updating", "Economic", "62", "25", "40"] {
                XCTAssertFalse(scanned.contains(leaked), "\(state.name): \(leaked) in: \(scanned)")
            }
            XCTAssertNil(scanned.range(of: #"\bvotes\b"#, options: [.regularExpression, .caseInsensitive]), "\(state.name): \(scanned)")
            // No figure at all anywhere in the sealed area. (The system spinner, which `ImageRenderer` cannot
            // draw either, carries a value of its own; the walk reaches its UIKit view.)
            if sealed.showsStamp {
                XCTAssertNil(text.range(of: #"\d"#, options: .regularExpression), "\(state.name): \(text)")
            }
            // Try again: a vote to send again, or a failed vote read to make again.
            XCTAssertEqual(strings.contains(VoteResultsFormatting.tryAgainTitle), state.access.offersTryAgain, state.name)
        }
    }

    /// Every sealed state and Opening in light, dark and AX3 (spec 10.1). The sealed sheet takes no stats, so
    /// it draws the same with stats at hand; and below its column heads no bar is filled with a vote colour.
    func testTheSealedSheetRendersEveryStateTheSameWithOrWithoutStats() throws {
        let stats = try Self.richStats()
        let states = Self.lockedStates.map { ($0.name, $0.access, false) } + [("opening", BillResultsAccess.open, true)]
        for variant in Self.variants(.accessibility3) {
            for (name, access, didVoteHere) in states {
                let image = try render(resultsArea(access, stats: nil, didVoteHere: didVoteHere), variant: variant, width: 390)
                attach(image, name: "results-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 200, "\(name) \(variant.name)")
                if !didVoteHere {
                    let withStats = try render(resultsArea(access, stats: stats, didVoteHere: didVoteHere), variant: variant, width: 390)
                    XCTAssertEqual(withStats.height, image.height, "\(name) \(variant.name)")
                    XCTAssertEqual(withStats.dataProvider?.data as Data?, image.dataProvider?.data as Data?, "\(name) \(variant.name): the sheet takes no stats")
                }
                if variant.size == .large, let sealed = SealedTallyState(access: access, opening: didVoteHere) {
                    let sheet = SealedTally(kind: .results, state: sealed).background(BillboardColors.document)
                    try assertNoVoteColourUnderTheHeads(try render(sheet, variant: variant, width: 390), dark: variant.scheme == .dark, "\(name) \(variant.name)")
                }
            }
        }
    }

    /// The sealed Results keep their table only while the centred SEALED stamp clears the row names: at the
    /// default size on 375 and 402 pt phones it does; at xLarge on 375 pt (and xxLarge on 402 pt) "Verified
    /// voters" would run under it, so the rows stack with the stamp above them, as at the accessibility sizes
    /// (spec 3.8.2, frame 26). Checking and Opening keep the same form as the sealed sheet. The table is the form
    /// with the column heads, whose YEA is in the Yea colour; the stacked form has no vote colour.
    func testTheSealedSheetStacksBeforeTheStampWouldCoverARowName() throws {
        let cases: [(width: CGFloat, size: DynamicTypeSize, table: Bool)] = [
            (375, .large, true), (375, .xLarge, false), (402, .large, true), (402, .xxLarge, false)
        ]
        let yea = BillboardPalette.voteYea.light.rgb
        for (width, size, table) in cases {
            for state in [SealedTallyState.notVoted, .checking, .opening] {
                let name = "sealed-\(state)-\(size)-\(Int(width))"
                let image = try render(
                    SealedTally(kind: .results, state: state).background(BillboardColors.document),
                    variant: Variant(scheme: .light, size: size),
                    width: width
                )
                attach(image, name: name)
                let yeaPixels = try bitmap(image).reduce(0) { count, row in count + row.filter { distance($0, yea) < 0.08 }.count }
                if table {
                    XCTAssertGreaterThan(yeaPixels, 0, "\(name): the table, with its column heads")
                } else {
                    XCTAssertEqual(yeaPixels, 0, "\(name): stacked, the stamp above the rows")
                }
            }
        }
    }

    /// No pixel close to Yea or Nay below the first heavy rule (the column heads' rule) of a sealed Results
    /// sheet: its blank cells and empty bars carry no vote colour.
    private func assertNoVoteColourUnderTheHeads(_ image: CGImage, dark: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let pixels = try bitmap(image)
        let ink = BillboardPalette.ruleHeavy.resolved(dark: dark).rgb
        let gutter = Int(BillboardStyle.Space.xl)
        let headRule = try XCTUnwrap(pixels.indices.first { y in
            pixels[y][gutter..<(image.width - gutter)].allSatisfy { distance($0, ink) < 0.1 }
        }, "the column heads' rule: \(message)", file: file, line: line)
        let yea = BillboardPalette.voteYea.resolved(dark: dark).rgb
        let nay = BillboardPalette.voteNay.resolved(dark: dark).rgb
        var found = 0
        for y in (headRule + 2)..<image.height {
            for pixel in pixels[y] where distance(pixel, yea) < 0.06 || distance(pixel, nay) < 0.06 {
                found += 1
            }
        }
        XCTAssertEqual(found, 0, "vote colour under the heads: \(message)", file: file, line: line)
    }

    /// Each sealed sheet is one VoiceOver element under its heading: "Sealed" with the reason, or the
    /// spinner's words. Before a vote it has the action "Go to vote buttons", which moves focus to the vote
    /// panel; no other state has it. Try again keeps INT-11's id.
    func testTheSealedSheetIsOneElementWithItsAction() {
        var goes = 0
        let host = AccessibilityTreeText.Host(resultsArea(.locked(.notVoted), stats: nil, onGoToVoteButtons: { goes += 1 }))
        XCTAssertEqual(host.label(ofIdentifier: SealedTally.resultsIdentifier), VoteResultsFormatting.sealedLabel)
        XCTAssertEqual(host.value(ofIdentifier: SealedTally.resultsIdentifier), VoteResultsFormatting.sealedAccessibilityValue(.notVoted))
        XCTAssertEqual(host.label(ofIdentifier: SealedTally.reasonsIdentifier), VoteResultsFormatting.sealedLabel)
        XCTAssertEqual(host.value(ofIdentifier: SealedTally.reasonsIdentifier), VoteResultsFormatting.reasonsSealedText)
        XCTAssertTrue(host.traits(of: VoteResultsFormatting.sectionTitle)?.contains(.header) == true)
        XCTAssertTrue(host.traits(of: BillVoteReasonsSection.title)?.contains(.header) == true)
        XCTAssertEqual(host.actionNames(ofIdentifier: SealedTally.resultsIdentifier), [VoteResultsFormatting.goToVoteButtonsAction])
        XCTAssertTrue(host.performAction(named: VoteResultsFormatting.goToVoteButtonsAction, ofIdentifier: SealedTally.resultsIdentifier))
        XCTAssertEqual(goes, 1)
        host.close()

        for access in [BillResultsAccess.locked(.checking), .locked(.checkFailed), .awaitingSave(canRetry: true)] {
            let host = AccessibilityTreeText.Host(resultsArea(access, stats: nil))
            XCTAssertEqual(host.actionNames(ofIdentifier: SealedTally.resultsIdentifier), [], "\(access)")
            XCTAssertEqual(host.label(ofIdentifier: SealedTally.tryAgainIdentifier) != nil, access.offersTryAgain, "\(access)")
            host.close()
        }
        let checking = AccessibilityTreeText.Host(resultsArea(.locked(.checking), stats: nil))
        XCTAssertEqual(checking.label(ofIdentifier: SealedTally.resultsIdentifier), "Checking your vote…")
        checking.close()
    }

    /// The first load: after a vote made here, Opening (the seal lifted, "Opening results…"); when Results
    /// were open as the page opened, "Updating results…" alone. Never a row that claims there are no votes
    /// yet, and no map.
    func testTheFirstLoadSaysOpeningOrUpdatingNotNoVotes() throws {
        for isLoading in [false, true] {
            let text = AccessibilityTreeText.text(of: resultsArea(.open, stats: nil, isLoading: isLoading))
            XCTAssertTrue(text.contains(VoteResultsFormatting.loadingText), text)
            for claim in [VoteResultsFormatting.noDecisionVotesText, "Fewer than", "Everyone", "Map", VoteResultsFormatting.openingText] {
                XCTAssertFalse(text.contains(claim), "\(claim) in: \(text)")
            }

            let host = AccessibilityTreeText.Host(resultsArea(.open, stats: nil, isLoading: isLoading, didVoteHere: true))
            XCTAssertEqual(host.label(ofIdentifier: SealedTally.openingIdentifier), VoteResultsFormatting.openingText)
            XCTAssertNil(host.label(ofIdentifier: SealedTally.resultsIdentifier), "Opening is not locked")
            let opening = host.text()
            host.close()
            for claim in [VoteResultsFormatting.noDecisionVotesText, "Fewer than", "Everyone", "Map", VoteResultsFormatting.loadingText, VoteResultsFormatting.sealedLabel] {
                XCTAssertFalse(opening.contains(claim), "\(claim) in: \(opening)")
            }
        }
        // A failed load says so, without the loading line or any row, also after a vote here.
        for didVoteHere in [false, true] {
            let failed = AccessibilityTreeText.text(of: resultsArea(.open, stats: nil, error: VoteResultsFormatting.unavailableText, didVoteHere: didVoteHere))
            XCTAssertTrue(failed.contains(VoteResultsFormatting.unavailableText), failed)
            XCTAssertFalse(failed.contains(VoteResultsFormatting.loadingText), failed)
            XCTAssertFalse(failed.contains(VoteResultsFormatting.openingText), failed)
            XCTAssertFalse(failed.contains(VoteResultsFormatting.noDecisionVotesText), failed)
        }

        // Stats with no Yea or Nay votes say when Results open (UX-34 changed this from "No Yea or Nay votes yet").
        let none = AccessibilityTreeText.text(of: resultsArea(.open, stats: try VoteResultsFormattingTests.stats()))
        XCTAssertTrue(none.contains("Results open at 5 Yea or Nay votes."), none)
        XCTAssertFalse(none.contains(VoteResultsFormatting.noDecisionVotesText), none)

        for variant in Self.variants(.accessibility3) {
            let image = try render(resultsArea(.open, stats: nil), variant: variant, width: 390)
            attach(image, name: "results-first-load-\(variant.name)")
            XCTAssertGreaterThan(image.height, 80, variant.name)
        }
    }

    /// Why people voted, open (spec 4.46): the two blocks with their counts, each reason one element, its share
    /// read as of the side's voters (feature review N1). Under the floor (UX-34) no block shows, whatever the
    /// stats hold: the two heads would give the split.
    func testWhyPeopleVotedReadsEachReason() throws {
        let stats = try Self.richStats()
        let text = AccessibilityTreeText.text(of: BillVoteReasonsSection(billStats: stats, isLoadingBillStats: false))
        XCTAssertTrue(text.contains("Yea, 25 votes"), text)
        XCTAssertTrue(text.contains("Economic Impact / Jobs: 7 people, 28 percent of Yea voters."), text)
        XCTAssertTrue(text.contains("Economic Impact / Jobs: 3 people, 20 percent of Nay voters."), text)

        let few = try Self.richStats(yea: 3, nay: 1)
        let under = AccessibilityTreeText.text(of: BillVoteReasonsSection(billStats: few, isLoadingBillStats: false))
        XCTAssertTrue(under.contains(BillVoteReasonsSection.notEnoughText), under)
        for leaked in ["Yea, 3", "Nay, 1", "people,", "percent", "Economic"] {
            XCTAssertFalse(under.contains(leaked), "\(leaked) in: \(under)")
        }
        for variant in Self.variants(.accessibility3) {
            let image = try render(BillVoteReasonsSection(billStats: stats, isLoadingBillStats: false).background(BillboardColors.document), variant: variant, width: 390)
            attach(image, name: "reasons-open-\(variant.name)")
            XCTAssertGreaterThan(image.height, 100, variant.name)
        }
    }

    /// The SEALED stamp over the sealed sheet is 12.5 pt (spec 3.8.2) on the stamp role's Dynamic Type curve:
    /// larger than an 11 pt stamp, at least 28 pt tall, and larger again at AX3.
    func testTheSealStampIsTwelveAndAHalfPoints() throws {
        XCTAssertEqual(StatusStamp.Size.seal.scale, 12.5 / 11, accuracy: 1e-9)
        XCTAssertEqual(StatusStamp.Size.regular.scale, 1)
        let large = Variant(scheme: .light, size: .large)
        let regular = try render(StatusStamp(.sealed).fixedSize(), variant: large, width: 300)
        let seal = try render(StatusStamp(.sealed, size: .seal).fixedSize(), variant: large, width: 300)
        attach(seal, name: "seal-stamp")
        XCTAssertGreaterThanOrEqual(seal.height, 28)
        XCTAssertGreaterThan(seal.width, regular.width)
        let ax3 = try render(StatusStamp(.sealed, size: .seal).fixedSize(), variant: Variant(scheme: .light, size: .accessibility3), width: 600)
        XCTAssertGreaterThan(ax3.height, seal.height)
        XCTAssertGreaterThan(ax3.width, seal.width)
    }

    // MARK: - Map

    /// Two squares: "YE" with 100% Yea and enough votes, "LO" under the floor.
    private static func mapFixture() throws -> VoterMapGeometry {
        let json = #"""
        {"version":1,"canvas":{"width":200,"height":100},"features":[
          {"id":"YE","label":"YE","polygons":[{"rings":[[[0,0],[100,0],[100,100],[0,100]]]}],"bbox":{"minX":0,"minY":0,"maxX":100,"maxY":100}},
          {"id":"LO","label":"LO","polygons":[{"rings":[[[100,0],[200,0],[200,100],[100,100]]]}],"bbox":{"minX":100,"minY":0,"maxX":200,"maxY":100}}
        ]}
        """#
        return try VoterMapGeometryLoader.decodeGeometry(from: Data(json.utf8))
    }

    func testTheMapRampsVotesAndHatchesTooFewVotes() throws {
        let geometry = try Self.mapFixture()
        let stats: [String: VoterMapRegionStat] = [
            "YE": VoterMapRegionStat(id: "YE", label: "YE", yeaPct: 100, yea: 9, nay: 0, decisionVotes: 9),
            "LO": VoterMapRegionStat(id: "LO", label: "LO", yeaPct: 50, yea: 2, nay: 2, decisionVotes: 4)
        ]
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let map = VoterChoroplethView(
                geometry: geometry,
                statsByRegion: stats,
                selectedRegionID: nil,
                highlightedRegionIDs: [],
                onSelectRegion: { _ in }
            )
            let image = try render(map, variant: Variant(scheme: scheme, size: .large), width: 400)
            attach(image, name: "map-\(dark ? "dark" : "light")")
            XCTAssertEqual(image.width, 400)

            // 100% Yea is the voteYea end of the ramp.
            assertColor(try pixel(of: image, x: 100, y: image.height / 2), BillboardPalette.voteYea.resolved(dark: dark).rgb, accuracy: 0.03, "Yea \(scheme)")

            // Under the floor (here 50% Yea from 4 votes): secondaryBackground with hatch lines, never a
            // flat fill that reads as 50/50.
            let background = BillboardPalette.secondaryBackground.resolved(dark: dark).rgb
            let neutral = BillboardPalette.mapNeutral.resolved(dark: dark).rgb
            var backgroundCount = 0
            var lineCount = 0
            var neutralCount = 0
            for x in stride(from: 240, to: 360, by: 1) {
                let sample = try pixel(of: image, x: x, y: image.height / 2)
                if distance(sample, background) < 0.02 { backgroundCount += 1 }
                if distance(sample, background) > 0.08 { lineCount += 1 }
                if distance(sample, neutral) < 0.01 { neutralCount += 1 }
            }
            XCTAssertGreaterThan(backgroundCount, 30, "secondaryBackground between the lines (\(scheme))")
            XCTAssertGreaterThan(lineCount, 5, "hatch lines (\(scheme))")
            XCTAssertLessThan(neutralCount, 60, "not a flat 50/50 fill, which would match on every sample (\(scheme))")
        }
    }

    func testTheLegendSwatchIsHatched() throws {
        let swatch = VoterMapHatchSwatch().frame(width: 40, height: 40)
        let image = try render(swatch, variant: Variant(scheme: .light, size: .large), width: 40)
        attach(image, name: "map-hatch-swatch")
        let background = BillboardPalette.secondaryBackground.light.rgb
        var colours = Set<Int>()
        for x in 4..<36 {
            let sample = try pixel(of: image, x: x, y: 20)
            colours.insert(distance(sample, background) < 0.02 ? 0 : 1)
        }
        XCTAssertEqual(colours, [0, 1], "background and hatch lines both show")
    }

    /// The user's region and the selection (spec 3.9): the user's state in a 2 pt dashed ink line, the
    /// selected one in a 2.5 pt solid ink line, drawn over every neighbour's outline.
    func testTheMapDashesYourRegionAndRulesTheSelection() throws {
        let geometry = try Self.mapFixture()
        let stats: [String: VoterMapRegionStat] = [
            "YE": VoterMapRegionStat(id: "YE", label: "YE", yeaPct: 100, yea: 9, nay: 0, decisionVotes: 9),
            "LO": VoterMapRegionStat(id: "LO", label: "LO", yeaPct: 50, yea: 2, nay: 2, decisionVotes: 4)
        ]
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let map = VoterChoroplethView(
                geometry: geometry,
                statsByRegion: stats,
                selectedRegionID: "YE",
                highlightedRegionIDs: ["LO"],
                onSelectRegion: { _ in }
            )
            let image = try render3x(map, variant: Variant(scheme: scheme, size: .large), width: 400)
            attach(image, name: "map-strokes-\(scheme)")
            let pixels = try bitmap(image)
            let ink = BillboardPalette.primaryText.resolved(dark: dark).rgb
            // Along the top edge (the stroke's inner half shows): the selection is ink all the way, the
            // user's region alternates ink and gaps.
            let row = pixels[2]
            let selectedRun = row[30..<570].filter { distance($0, ink) < 0.12 }.count
            XCTAssertGreaterThan(selectedRun, 520, "solid selection (\(scheme))")
            var transitions = 0
            var wasInk = false
            for pixel in row[630..<1170] {
                let isInk = distance(pixel, ink) < 0.12
                if isInk != wasInk { transitions += 1 }
                wasInk = isInk
            }
            XCTAssertGreaterThan(transitions, 40, "dashed outline of your region (\(scheme))")
        }
    }

    /// The map on its plate (spec 3.9), hosted so the bundled map loads and the system segmented control
    /// draws: the plate's colour bleeds 10 pt past the 20 pt gutter on each side, against the document.
    func testTheMapSitsOnAPlateThatBleedsPastTheGutter() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let stats = try Self.bothRowsStats()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let dark = style == .dark
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 1100)
            window.overrideUserInterfaceStyle = style
            let host = UIHostingController(rootView: tallySheet(stats, yourVote: .nay).frame(maxHeight: .infinity, alignment: .top).background(BillboardColors.document))
            window.rootViewController = host
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            attach(cgImage, name: "results-open-hosted-\(dark ? "dark" : "light")")
            let pixels = try bitmap(cgImage)
            let plate = BillboardPalette.plate.resolved(dark: dark).rgb
            let document = BillboardPalette.document.resolved(dark: dark).rgb
            let plateRows = pixels.indices.filter { y in
                distance(pixels[y][12], plate) < 0.01 && distance(pixels[y][377], plate) < 0.01
                    && distance(pixels[y][6], document) < 0.01 && distance(pixels[y][384], document) < 0.01
            }
            XCTAssertGreaterThan(plateRows.count, 100, "the plate, 10 pt from each edge (\(style == .dark ? "dark" : "light"))")
        }
    }

    // MARK: - The document (Civic Record spec 4.28 to 4.34, 4.45, 4.47, 4.48)

    nonisolated private static let officialTitle = "To require the Secretary of Energy to submit an annual report to Congress on amounts spent under the Clean Energy Deployment Program, and for other purposes."
    /// 15:30 UTC: October 14 in every US time zone.
    private static let storedAt = "2026-10-14T15:30:00Z"

    private static func member(_ id: String, _ name: String, _ party: String, _ state: String, _ district: String?, _ position: String) -> Bill.OfficialVoteMember {
        Bill.OfficialVoteMember(bioguideId: id, displayName: name, party: party, state: state, district: district, votePosition: position)
    }

    private static func houseVote(members: Int = 2) -> Bill.OfficialChamberVote {
        let named = [
            member("E000001", "Jordan Ellis", "R", "TX", "7", "Yea"),
            member("D000002", "Jane Doe", "D", "CA", "12", "Aye"),
            member("S000003", "Sam Roe", "R", "OH", "4", "No"),
            member("P000004", "Pat Lee", "D", "NY", "10", "Not Voting")
        ]
        let extra = (0..<max(0, members - named.count)).map { index in
            member("X\(String(format: "%06d", index))", "Member \(index)", index.isMultiple(of: 2) ? "D" : "R", "VA", "\(index % 11 + 1)", "Yea")
        }
        return Bill.OfficialChamberVote(
            yea: 231, nay: 196, present: 2, notVoting: 6, totalCounted: 435,
            actionCode: nil, actionDate: "2026-10-12", resultText: "Passed", memberDataAvailable: true,
            members: Array(named.prefix(members)) + extra
        )
    }

    /// The bill of frames 4 to 8: in the news, with a breakdown, committees, actions and a House roll call.
    private static func documentBill(
        status: BillStatus = .new,
        houseMembers: Int = 2,
        official: String? = BillDetailRenderTests.officialTitle,
        extraActions: [Bill.BillAction] = []
    ) -> Bill {
        let officialVotes = Bill.OfficialVotesBreakdown(house: houseVote(members: houseMembers), senate: nil, lastSyncedAt: nil, source: nil, completeness: nil)
        return Bill(
            id: UUID.deterministic(from: "BILLS-119hr1234"),
            title: "Clean Energy Reporting Act",
            officialTitle: official,
            category: "Energy",
            soWhat: "The program has grown fast, and it is hard to see where the money goes. A yearly public report would let anyone check which projects are working before Congress votes to fund more.",
            billBreakdown: BillBreakdown(
                who: "The Department of Energy would write the report. Congress and the public would read it.",
                what: "A yearly public report on every dollar the Clean Energy Deployment Program spends, by project and by state.",
                how: "The Secretary of Energy sends it to the House and Senate energy committees by March 1 each year.",
                when: "It starts with the 2027 budget year.",
                where: "Projects in all 50 states and U.S. territories.",
                why: "Lawmakers say the program has grown fast and it is hard to see which projects deliver."
            ),
            storedAt: storedAt,
            link: "https://www.govinfo.gov/app/details/BILLS-119hr1234ih",
            actions: [
                Bill.BillAction(actionCode: nil, actionDate: "2026-10-09", text: "Introduced in House.", type: "IntroReferral", sourceSystem: nil, committees: nil),
                Bill.BillAction(actionCode: nil, actionDate: "2026-10-09", text: "Referred to the House Committee on Energy and Commerce.", type: "IntroReferral", sourceSystem: nil, committees: nil),
                Bill.BillAction(actionCode: nil, actionDate: "2026-10-14", text: "Subcommittee hearings held.", type: "Committee", sourceSystem: nil, committees: nil)
            ] + extraActions,
            committees: [
                Bill.BillCommittee(
                    chamber: "House", name: "Energy and Commerce Committee", systemCode: nil, type: nil, url: nil,
                    activities: [.init(date: "2026-10-09", name: "Referred to"), .init(date: "2026-10-09", name: "Referred To")]
                )
            ],
            billStatus: status,
            guid: "BILLS-119hr1234",
            userVoted: false,
            isPriority: true,
            priorityReason: "Featured in the news this week",
            congressHouseYeaCount: 231,
            congressHouseNayCount: 196,
            officialVotes: officialVotes,
            isProcessedDetailHydrated: true
        )
    }

    private func onDocument<Content: View>(_ view: Content) -> some View {
        view.background(BillboardColors.document)
    }

    // MARK: Front matter

    private static let frontMatters: [(name: String, content: BillFrontMatter.Content)] = [
        ("new", BillFrontMatter.Content(bill: documentBill())),
        ("companion-lead", BillFrontMatter.Content(
            numbers: ["H.R. 10", "S. 10"], status: .passed, companionLead: "S. 10",
            title: "Clean Energy Reporting Act", officialTitle: officialTitle, lastUpdated: FlexibleISO8601.parse(storedAt)
        )),
        ("became-law", BillFrontMatter.Content(bill: documentBill(status: .finalized))),
        ("no-number", BillFrontMatter.Content(numbers: [], status: .failed, title: "A bill with no number"))
    ]

    /// Front matter in light, dark, AX3 and AX5: the docket line (with the stamp on its own line at
    /// accessibility sizes), the condensed title, the upright official title, In the news, the date and
    /// the double rule. It grows with the text.
    func testTheFrontMatterRendersInEveryLook() throws {
        let looks = Self.variants(.accessibility3) + [Variant(scheme: .light, size: .accessibility5), Variant(scheme: .dark, size: .accessibility5)]
        for (name, content) in Self.frontMatters {
            var heights: [String: Int] = [:]
            for variant in looks {
                let image = try render(onDocument(BillFrontMatter(content)), variant: variant, width: 390)
                attach(image, name: "front-matter-\(name)-\(variant.name)")
                heights[variant.name] = image.height
            }
            let large = try XCTUnwrap(heights["light-default"])
            XCTAssertGreaterThan(try XCTUnwrap(heights["light-AX3"]), large, "\(name): AX3 really scales")
            XCTAssertGreaterThan(try XCTUnwrap(heights["light-AX5"]), try XCTUnwrap(heights["light-AX3"]), "\(name): AX5 more")
        }
        // At 375 pt and AX5 too (frame 23's iPhone SE).
        let se = try render(onDocument(BillFrontMatter(Self.frontMatters[0].content)), variant: Variant(scheme: .light, size: .accessibility5), width: 375)
        attach(se, name: "front-matter-new-light-AX5-375")
    }

    /// The front matter reads like the record: "House bill 1234. New." on the docket line (id kept), the
    /// title as the page's heading, "Official title: …", "In the news. Featured in the news this week" and
    /// the date said in words. A decided bill keeps its stamp; a companion pair names both bills.
    func testTheFrontMatterReadsLikeTheRecord() {
        let host = AccessibilityTreeText.Host(onDocument(BillFrontMatter(Self.frontMatters[0].content)))
        defer { host.close() }
        let text = host.text()
        XCTAssertEqual(host.label(ofIdentifier: BillFrontMatter.numberIdentifier), "House bill 1234. New.")
        XCTAssertEqual(host.label(ofIdentifier: BillFrontMatter.officialTitleIdentifier), "Official title: \(Self.officialTitle)")
        XCTAssertEqual(host.traits(of: "Clean Energy Reporting Act")?.contains(.header), true, "the title is the page's heading")
        for shown in ["In the news. Featured in the news this week", "Last updated October 14, 2026"] {
            XCTAssertTrue(text.contains(shown), "\(shown) in: \(text)")
        }

        let law = AccessibilityTreeText.text(of: onDocument(BillFrontMatter(Self.frontMatters[2].content)))
        XCTAssertTrue(law.contains("House bill 1234. Became law."), law)
        let pair = AccessibilityTreeText.text(of: onDocument(BillFrontMatter(Self.frontMatters[1].content)))
        XCTAssertTrue(pair.contains("House bill 10 and Senate bill 10. Senate bill 10 passed."), pair)
        let bare = AccessibilityTreeText.text(of: onDocument(BillFrontMatter(Self.frontMatters[3].content)))
        XCTAssertTrue(bare.contains("Failed"), "a bill with no number keeps its stamp: \(bare)")

        let utc = TimeZone(identifier: "UTC")!
        let date = FlexibleISO8601.parse(Self.storedAt)!
        let english = Locale(identifier: "en_US")
        // Foundation puts a narrow no-break space before PM; the page a no-break space before the "·".
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        XCTAssertTrue(BillFrontMatter.lastUpdatedText(date, locale: english, timeZone: utc).contains("2026\u{00A0}· "), "the dot stays at the end of a line")
        XCTAssertEqual(plain(BillFrontMatter.lastUpdatedText(date, locale: english, timeZone: utc)), "Last updated Oct 14, 2026 · 3:30 PM")
        XCTAssertEqual(plain(BillFrontMatter.lastUpdatedSpoken(date, locale: english, timeZone: utc)), "Last updated October 14, 2026, 3:30 PM")
    }

    /// The front matter sits on the document ground (no tint by status) and ends with the thin-thick double
    /// rule: from the bottom, 1 pt of ink, a 2 pt gap and 2 pt of ink, inside the 20 pt gutter.
    func testTheFrontMatterEndsWithTheDoubleRuleOnTheDocument() throws {
        for status in [BillStatus.new, .passed, .failed, .finalized] {
            for scheme in [ColorScheme.light, .dark] {
                let dark = scheme == .dark
                let image = try render(onDocument(BillFrontMatter(bill: Self.documentBill(status: status))), variant: Variant(scheme: scheme, size: .large), width: 390)
                let ink = BillboardPalette.ruleHeavy.resolved(dark: dark).rgb
                let document = BillboardPalette.document.resolved(dark: dark).rgb
                let x = image.width / 2
                let bottom = image.height - 1
                assertColor(try pixel(of: image, x: x, y: bottom), ink, accuracy: 0.03, "the thin rule (\(status) \(scheme))")
                assertColor(try pixel(of: image, x: x, y: bottom - 1), document, accuracy: 0.03, "the gap (\(status) \(scheme))")
                assertColor(try pixel(of: image, x: x, y: bottom - 2), document, accuracy: 0.03, "the gap (\(status) \(scheme))")
                assertColor(try pixel(of: image, x: x, y: bottom - 3), ink, accuracy: 0.03, "the thick rule (\(status) \(scheme))")
                assertColor(try pixel(of: image, x: x, y: bottom - 4), ink, accuracy: 0.03, "the thick rule (\(status) \(scheme))")
                assertColor(try pixel(of: image, x: 10, y: bottom), document, accuracy: 0.03, "the gutter (\(status) \(scheme))")
                assertColor(try pixel(of: image, x: image.width - 4, y: 4), document, accuracy: 0.03, "the ground, untinted (\(status) \(scheme))")
            }
        }
    }

    // MARK: Sponsor, Why it matters, Breakdown, Summary

    private static let sponsor = BillSponsorRow.Content(name: "Jordan Ellis", party: .republican, chamber: .house, stateCode: "TX", district: "07")

    func testTheSponsorRowLeadsItsAffiliationWithTheLetter() throws {
        XCTAssertEqual(Self.sponsor.affiliation, "R · House · TX-7")
        XCTAssertEqual(Self.sponsor.accessibilityLabel, "Sponsor: Representative Jordan Ellis, Republican, Texas's 7th district")
        let senator = BillSponsorRow.Content(name: "Tim Kaine", party: .democratic, chamber: .senate, stateCode: "VA", district: "11")
        XCTAssertEqual(senator.affiliation, "D · Senate · VA")
        XCTAssertEqual(senator.accessibilityLabel, "Sponsor: Senator Tim Kaine, Democrat, Virginia")
        let atLarge = BillSponsorRow.Content(name: "Nick Begich", party: .republican, chamber: .house, stateCode: "AK", district: "0")
        XCTAssertEqual(atLarge.accessibilityLabel, "Sponsor: Representative Nick Begich, Republican, Alaska's at-large district")
        XCTAssertEqual(AccessibilityTreeText.text(of: onDocument(BillSponsorRow(content: Self.sponsor))), Self.sponsor.accessibilityLabel)

        let section = RecordSection(BillSponsorSection.title, showsRule: false) { BillSponsorRow(content: Self.sponsor) }
        for variant in Self.variants(.accessibility3) + [Variant(scheme: .light, size: .accessibility5)] {
            let image = try render(onDocument(section), variant: variant, width: 390)
            attach(image, name: "sponsor-\(variant.name)")
            XCTAssertGreaterThanOrEqual(image.height, 44 + 16, variant.name)
        }
    }

    /// One member row everywhere (project decision of 2026-10-21): the sponsor row is the member roll row
    /// (`MemberRollRow`) with the 44 pt monogram on the document's ground, no roll-sheet insets and a chevron, so
    /// it draws as one at every size and stacks as one at the accessibility sizes (the monogram and the
    /// chevron, then the name and the affiliation across the width). It reads as one element, "Sponsor: …".
    func testTheSponsorRowIsTheMemberRollRow() throws {
        let roll = MemberRollRow(
            name: Self.sponsor.name,
            party: Self.sponsor.party,
            affiliation: Self.sponsor.affiliation,
            photoURL: nil,
            monogramSize: .roll,
            trailing: .chevron,
            insets: EdgeInsets(),
            groundColor: BillboardColors.document,
            accessibilityLabel: Self.sponsor.accessibilityLabel
        )
        func pixels(_ image: CGImage) throws -> [Double] {
            try bitmap(image).flatMap { $0.flatMap { [$0.red, $0.green, $0.blue] } }
        }
        for variant in Self.variants(.accessibility3) + [Variant(scheme: .light, size: .accessibility5)] {
            for width in [CGFloat(375), 402] {
                let sponsor = try render(onDocument(BillSponsorRow(content: Self.sponsor)), variant: variant, width: width)
                let member = try render(onDocument(roll), variant: variant, width: width)
                XCTAssertEqual(sponsor.height, member.height, "\(variant.name) at \(Int(width))")
                XCTAssertEqual(try pixels(sponsor), try pixels(member), "\(variant.name) at \(Int(width)): drawn as the member roll row")
            }
        }
        let host = AccessibilityTreeText.Host(onDocument(BillSponsorRow(content: Self.sponsor)).environment(\.dynamicTypeSize, .accessibility5), size: CGSize(width: 375, height: 800))
        defer { host.close() }
        XCTAssertEqual(host.strings(), [Self.sponsor.accessibilityLabel])
    }

    /// Why it matters in the `lead` role and the Breakdown ledger, at every size up to AX5: the ledger's
    /// labels go above their answers at accessibility sizes, so the AX5 ledger is far taller.
    func testWhyItMattersAndTheBreakdownLedgerRenderUpToAX5() throws {
        let bill = Self.documentBill()
        let breakdown = try XCTUnwrap(bill.billBreakdown)
        let looks = Self.variants(.accessibility3) + [Variant(scheme: .light, size: .accessibility5), Variant(scheme: .dark, size: .accessibility5)]
        var ledgerHeights: [String: Int] = [:]
        for variant in looks {
            let why = try render(onDocument(BillSoWhatSection(bill: bill, showsRule: false)), variant: variant, width: 390)
            attach(why, name: "why-it-matters-\(variant.name)")
            let ledger = try render(onDocument(BillBreakdownSection(breakdown: breakdown)), variant: variant, width: 390)
            attach(ledger, name: "breakdown-\(variant.name)")
            ledgerHeights[variant.name] = ledger.height
            let summary = try render(onDocument(BillSummarySection(summary: bill.soWhat)), variant: variant, width: 390)
            attach(summary, name: "summary-\(variant.name)")
        }
        XCTAssertGreaterThan(try XCTUnwrap(ledgerHeights["light-AX5"]), 2 * (try XCTUnwrap(ledgerHeights["light-default"])))

        let text = AccessibilityTreeText.text(of: onDocument(BillBreakdownSection(breakdown: breakdown)))
        XCTAssertTrue(text.hasPrefix("Bill Breakdown | Who: The Department of Energy would write the report."), text)
        for label in ["What:", "How:", "When:", "Where:", "Why:"] {
            XCTAssertTrue(text.contains(label), "\(label) in: \(text)")
        }
        let partial = BillBreakdown(who: "Someone.", what: nil, how: " ", when: nil, where: nil, why: nil)
        XCTAssertEqual(BillBreakdownSection(breakdown: partial).rows, [Ledger.Row("Who", "Someone.")], "only the fields with text")
    }

    // MARK: In Congress, Committees, Actions, Source

    func testInCongressBlocksRenderLoadedLoadingAndUnavailable() throws {
        let bill = Self.documentBill(status: .passed)
        let states: [(String, BillCompanionMemberRow)] = [
            ("loaded", BillCompanionMemberRow(memberGuid: "BILLS-119hr1234", bill: bill, isHydrated: true, isUnavailable: false)),
            ("loading", BillCompanionMemberRow(memberGuid: "BILLS-119s456", bill: nil, isHydrated: false, isUnavailable: false)),
            ("unavailable", BillCompanionMemberRow(memberGuid: "BILLS-119s456", bill: nil, isHydrated: false, isUnavailable: true))
        ]
        for variant in Self.variants(.accessibility3) {
            for (name, row) in states {
                let section = RecordSection(BillCompanionMembersSection.title) { row }
                let image = try render(onDocument(section), variant: variant, width: 390)
                attach(image, name: "in-congress-\(name)-\(variant.name)")
            }
        }
        let loaded = AccessibilityTreeText.text(of: onDocument(states[0].1))
        for shown in ["House bill 1234. Passed.", Self.officialTitle, "Latest action: Subcommittee hearings held.", "House vote · Yea 231 · Nay 196"] {
            XCTAssertTrue(loaded.contains(shown), "\(shown) in: \(loaded)")
        }
        XCTAssertTrue(AccessibilityTreeText.text(of: onDocument(states[1].1)).contains(BillCompanionMemberRow.loadingText))
        XCTAssertTrue(AccessibilityTreeText.text(of: onDocument(states[2].1)).contains(BillCompanionMemberRow.unavailableText))
    }

    /// Committees and Actions as ledgers (HOUSE, then the date in the label column; no numbering), and
    /// Source's link, in light, dark and AX3.
    func testCommitteesActionsAndSourceAreLedgersAndALink() throws {
        let bill = Self.documentBill()
        for variant in Self.variants(.accessibility3) {
            for (name, view) in [
                ("committees", AnyView(BillCommitteesSection(bill: bill))),
                ("actions", AnyView(BillActionsSection(bill: bill))),
                ("source", AnyView(BillLinkSection(bill: bill)))
            ] {
                let image = try render(onDocument(view), variant: variant, width: 390)
                attach(image, name: "\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 40, "\(name) \(variant.name)")
            }
        }
        let committees = BillCommitteesSection.rows(for: bill.committees)
        XCTAssertEqual(committees.count, 1)
        XCTAssertEqual(committees[0].label, "House")
        XCTAssertEqual(committees[0].activities.map(\.name), ["Referred to"], "repeats are dropped")
        XCTAssertTrue(AccessibilityTreeText.text(of: onDocument(BillCommitteesSection(bill: bill))).contains("House: Energy and Commerce Committee. Referred to"))

        let now = try XCTUnwrap(FlexibleISO8601.parse("2026-10-18T12:00:00Z"))
        let actions = BillActionsSection.rows(for: bill.actions, now: now)
        XCTAssertEqual(actions.map(\.answer), ["Introduced in House.", "Referred to the House Committee on Energy and Commerce.", "Subcommittee hearings held."], "oldest first")
        XCTAssertEqual(BillDocketDate.short("2026-10-09", now: now, locale: Locale(identifier: "en_US")), "Oct 9")
        XCTAssertEqual(BillDocketDate.short("2025-02-10", now: now, locale: Locale(identifier: "en_US")), "Feb 10\n2025")
        let actionsText = AccessibilityTreeText.text(of: onDocument(BillActionsSection(bill: bill)))
        XCTAssertFalse(actionsText.contains("1. "), "no numbering: \(actionsText)")

        let source = AccessibilityTreeText.text(of: onDocument(BillLinkSection(bill: bill)))
        XCTAssertEqual(source, "Source | View on GovInfo.gov")
    }

    // MARK: How Congress voted

    private func manifestStore() -> CongressMembersManifestStore {
        CongressMembersManifestStore(service: FakeCongressService())
    }

    private func officialVotes(_ bill: Bill) -> some View {
        onDocument(BillOfficialVotesSection(bill: bill, userStateCode: "TX", userDistrictValue: "7"))
            .environmentObject(manifestStore())
    }

    /// How Congress voted at 375 pt (an iPhone SE) at the default size and at AX3, light and dark: the two-
    /// column phone form at the default size and the stacked form at AX3, chosen by `ViewThatFits`; the four
    /// columns only on a wide screen.
    func testHowCongressVotedTakesThePhoneFormAt375AndStacksAtAX3() throws {
        let tally = try XCTUnwrap(CongressChamberTally.tallies(for: Self.documentBill()).first)
        // The section's content width is the screen less the 20 pt gutters.
        func tallyImage(_ form: CongressChamberTallyView.Form, width: CGFloat, size: DynamicTypeSize) throws -> CGImage {
            try render(onDocument(CongressChamberTallyView(tally: tally, form: form)), variant: Variant(scheme: .light, size: size), width: width)
        }
        let phone = try tallyImage(.automatic, width: 335, size: .large)
        XCTAssertEqual(phone.dataProvider?.data as Data?, try tallyImage(.split, width: 335, size: .large).dataProvider?.data as Data?, "two columns on a 375 pt phone")
        let phone393 = try tallyImage(.automatic, width: 353, size: .large)
        XCTAssertEqual(phone393.dataProvider?.data as Data?, try tallyImage(.split, width: 353, size: .large).dataProvider?.data as Data?, "not four columns on a 393 pt phone")
        let ax3 = try tallyImage(.automatic, width: 335, size: .accessibility3)
        XCTAssertEqual(ax3.dataProvider?.data as Data?, try tallyImage(.stacked, width: 335, size: .accessibility3).dataProvider?.data as Data?, "stacked at AX3")
        let wide = try tallyImage(.automatic, width: 700, size: .large)
        XCTAssertEqual(wide.dataProvider?.data as Data?, try tallyImage(.columns, width: 700, size: .large).dataProvider?.data as Data?, "four columns where they fit")
        for form in CongressChamberTallyView.Form.allCases {
            attach(try tallyImage(form, width: 335, size: .large), name: "how-congress-voted-tally-\(form)-375")
        }

        for variant in Self.variants(.accessibility3) {
            let image = try render(officialVotes(Self.documentBill()), variant: variant, width: 375)
            attach(image, name: "how-congress-voted-375-\(variant.name)")
            XCTAssertEqual(image.width, 375)
        }
    }

    /// The tally is one element per chamber, the split bar draws Yea and Nay in their colours with the 50%
    /// tick in ink, and each member row reads the member in the one spoken form (project decision of 2026-10-21)
    /// and the position: Yea, then Nay, then the rest, eight until "Show all House votes (12)"; Aye and No are
    /// Yea and Nay.
    func testHowCongressVotedReadsPerChamberAndPerMember() throws {
        let bill = Self.documentBill(houseMembers: 12)
        let host = AccessibilityTreeText.Host(officialVotes(bill), size: CGSize(width: 375, height: 2400))
        defer { host.close() }
        let strings = host.strings()
        XCTAssertEqual(strings.first, BillOfficialVotesSection.title)
        XCTAssertEqual(host.label(ofIdentifier: CongressChamberTallyView.identifier(for: .house)), "House: 231 Yea, 196 Nay, 2 present, 6 not voting. Passed.")
        XCTAssertEqual(Array(strings.dropFirst(2).prefix(2)), [
            "Representative Jane Doe, Democrat, California's 12th district, Yea",
            "Representative Jordan Ellis, Republican, Texas's 7th district, Yea"
        ], "\(strings)")
        XCTAssertTrue(strings.contains(BillOfficialVotesSection.showAllTitle(for: .house, count: 12)), "\(strings)")
        XCTAssertFalse(strings.contains { $0.contains("Sam Roe") }, "eight shown first: \(strings)")

        XCTAssertTrue(host.activate(BillOfficialVotesSection.showAllTitle(for: .house, count: 12)))
        let all = host.strings()
        for shown in ["Representative Sam Roe, Republican, Ohio's 4th district, Nay", "Representative Pat Lee, Democrat, New York's 10th district, Not voting", BillOfficialVotesSection.showFewerTitle] {
            XCTAssertTrue(all.contains(shown), "\(shown) in: \(all)")
        }
        let samRoe = try XCTUnwrap(all.firstIndex { $0.hasPrefix("Representative Sam Roe") })
        let patLee = try XCTUnwrap(all.firstIndex { $0.hasPrefix("Representative Pat Lee") })
        let lastYea = try XCTUnwrap(all.lastIndex { $0.hasSuffix(", Yea") })
        XCTAssertLessThan(lastYea, samRoe, "Yea before Nay")
        XCTAssertLessThan(samRoe, patLee, "Nay before Not voting")

        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let bar = CongressSplitBar(yea: 50, nay: 50).frame(width: 200).background(BillboardColors.document)
            let image = try render(bar, variant: Variant(scheme: scheme, size: .large), width: 200)
            let middle = image.height / 2
            assertColor(try pixel(of: image, x: 20, y: middle), BillboardPalette.voteYea.resolved(dark: dark).rgb, accuracy: 0.03, "Yea (\(scheme))")
            assertColor(try pixel(of: image, x: 180, y: middle), BillboardPalette.voteNay.resolved(dark: dark).rgb, accuracy: 0.03, "Nay (\(scheme))")
            assertColor(try pixel(of: image, x: 100, y: 1), BillboardPalette.ruleHeavy.resolved(dark: dark).rgb, accuracy: 0.03, "the 50% tick above the bar (\(scheme))")
            assertColor(try pixel(of: image, x: 60, y: 1), BillboardPalette.document.resolved(dark: dark).rgb, accuracy: 0.03, "no fill above the bar (\(scheme))")
        }
    }

    // MARK: Compare with Congress

    func testCompareWithCongressRendersWithSquareBars() throws {
        let bill = Self.documentBill()
        for variant in Self.variants(.accessibility3) {
            let image = try render(onDocument(BillCongressVotedSection(bill: bill)), variant: variant, width: 390)
            attach(image, name: "compare-with-congress-\(variant.name)")
        }
        let text = AccessibilityTreeText.text(of: onDocument(BillCongressVotedSection(bill: bill)))
        XCTAssertEqual(text, "Compare with Congress | House: 231 Yea, 196 Nay")
        var noVotes = bill
        noVotes.congressHouseYeaCount = nil
        noVotes.congressHouseNayCount = nil
        XCTAssertTrue(BillCongressVotedSection.tallies(for: noVotes).isEmpty, "only when Congress has voted")
    }

    // MARK: Loading, error, not found

    func testLoadingErrorAndNotFoundAreRecordNotices() throws {
        let error = BillDetailLoadErrorView(title: "Couldn't load this bill.", message: "Check your connection and try again.", retry: {})
        let states: [(String, AnyView)] = [
            ("loading", AnyView(BillDetailLoadingView())),
            ("error", AnyView(error)),
            ("not-found", AnyView(BillDetailMissingBillView(content: .notFound, retry: {})))
        ]
        let expected = [
            "loading": [BillDetailLoadingView.text],
            "error": ["Couldn't load. Couldn't load this bill. Check your connection and try again.", "Retry"],
            "not-found": ["Not found. Bill not found."]
        ]
        for (name, view) in states {
            let host = AccessibilityTreeText.Host(view, size: CGSize(width: 375, height: 667))
            let strings = host.strings()
            for part in expected[name] ?? [] {
                XCTAssertTrue(strings.contains { $0.contains(part) }, "\(name): \(part) in: \(strings)")
            }
            XCTAssertFalse(strings.contains { $0.contains("Retry") } && name != "error", "\(name): \(strings)")
            if name == "error" {
                XCTAssertEqual(host.label(ofIdentifier: BillDetailLoadErrorView.retryIdentifier), "Retry")
            }
            host.close()
        }
        for variant in Self.variants(.accessibility3) {
            let image = try render(BillDetailLoadingView().frame(height: 300), variant: variant, width: 375)
            attach(image, name: "bill-loading-\(variant.name)")
            assertColor(try pixel(of: image, x: 4, y: 4), BillboardPalette.document.resolved(dark: variant.scheme == .dark).rgb, accuracy: 0.02, "the document ground (\(variant.name))")
        }
    }

    // MARK: The page

    private func stores(_ bills: [Bill], votes: FakeBillVotesService? = nil) -> (billsStore: BillsStore, voteStore: BillVoteStore) {
        let votes = votes ?? FakeBillVotesService()
        let scope = "bill-document-tests-\(UUID().uuidString)"
        addTeardownBlock { BillsStore.clearCachedBills(scope: scope) }
        let service = FakeBillsService()
        service.cachedManifest = []
        let billsStore = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: votes)
        billsStore.connect(voteStore: voteStore)
        addTeardownBlock { withExtendedLifetime(voteStore) {} }
        return (billsStore, voteStore)
    }

    private func page(_ detail: BillDetail, billsStore: BillsStore, voteStore: BillVoteStore) -> some View {
        NavigationStack { detail }
            .environmentObject(billsStore)
            .environmentObject(voteStore)
            .environmentObject(AppReadState(scope: .user("bill-document-tests"), store: InMemoryReadStateStore()))
            .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
            .environmentObject(manifestStore())
    }

    /// The index of the first string that contains `part`, or nil.
    private func position(of part: String, in strings: [String]) -> Int? {
        strings.firstIndex { $0.contains(part) }
    }

    private func assertInOrder(_ parts: [String], in strings: [String], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        var last = -1
        for part in parts {
            guard let index = position(of: part, in: strings) else {
                return XCTFail("\(message): \(part) missing from \(strings)", file: file, line: line)
            }
            XCTAssertGreaterThan(index, last, "\(message): \(part) out of order in \(strings)", file: file, line: line)
            last = index
        }
    }

    /// The page in spec 4.28's order, before and after a vote made on it: the front matter, the bill's text,
    /// Your vote, Results (sealed until the vote, INT-11), then Compare with Congress and Done (only after
    /// the vote), How Congress voted (never sealed), Committees, Actions and Source. No "Vote saved", no
    /// "Watch for changes", no "Not voted yet"; Done has its id.
    func testThePageSetsItsSectionsInTheDocumentOrder() {
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let bill = Self.documentBill()
        let votes = FakeBillVotesService()
        let (billsStore, voteStore) = stores([bill], votes: votes)
        APIClient.$current.withValue(offline) {
            let host = AccessibilityTreeText.Host(page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), size: CGSize(width: 390, height: 7000), settle: 0.5)
            defer { host.close() }
            let before = host.strings()
            assertInOrder([
                "House bill 1234. New.", "Clean Energy Reporting Act", "Official title:", "In the news", "Last updated",
                BillSoWhatSection.title, BillBreakdownSection.title, "Who:",
                BillYourVoteSection.title, BillYourVoteSection.notVotedText, BillWatchCopy.rowTitle,
                Self.sealedNotVoted, BillVoteReasonsSection.title, VoteResultsFormatting.reasonsSealedText,
                BillOfficialVotesSection.title, "House: 231 Yea, 196 Nay",
                BillCommitteesSection.title, BillActionsSection.title, BillLinkSection.title, BillLinkSection.linkTitle
            ], in: before, "before the vote")
            for gone in [BillCongressVotedSection.title, BillDetail.doneTitle, "Vote saved", "Watch for changes", "Not voted yet"] {
                XCTAssertNil(position(of: gone, in: before), "\(gone) before the vote: \(before)")
            }

            XCTAssertTrue(host.activate("Vote Yea", settle: 1.0), "Vote Yea in: \(before)")
            XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback), [.yea])
            let after = host.strings()
            assertInOrder([
                BillYourVoteSection.title, BillWatchCopy.rowTitle, "Why Yea? (optional)",
                BillCongressVotedSection.title, "House: 231 Yea, 196 Nay",
                BillDetail.doneTitle,
                BillOfficialVotesSection.title, BillCommitteesSection.title
            ], in: after, "after the vote")
            XCTAssertEqual(host.label(ofIdentifier: BillDetail.doneIdentifier), BillDetail.doneTitle)
            for gone in [BillYourVoteSection.notVotedText, Self.sealedNotVoted, VoteResultsFormatting.sealedLabel, "Vote saved", "Watch for changes", "Not voted yet"] {
                XCTAssertNil(position(of: gone, in: after), "\(gone) after the vote: \(after)")
            }
        }
    }

    /// On the page, before a vote, the sealed Results and Why people voted carry the VoiceOver action "Go to
    /// vote buttons" (spec 3.8.3), wired to the vote panel's focus; after a vote it is gone with the seal.
    func testThePageSealedSheetOffersGoToVoteButtons() {
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let bill = Self.documentBill()
        let (billsStore, voteStore) = stores([bill])
        APIClient.$current.withValue(offline) {
            let host = AccessibilityTreeText.Host(page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), size: CGSize(width: 390, height: 7000), settle: 0.5)
            defer { host.close() }
            let action = VoteResultsFormatting.goToVoteButtonsAction
            XCTAssertEqual(host.actionNames(ofIdentifier: SealedTally.resultsIdentifier), [action], host.text())
            XCTAssertEqual(host.actionNames(ofIdentifier: SealedTally.reasonsIdentifier), [action], host.text())
            XCTAssertTrue(host.performAction(named: action, ofIdentifier: SealedTally.resultsIdentifier))
            XCTAssertTrue(host.text().contains("Vote Yea"), "the vote panel stays: \(host.text())")

            XCTAssertTrue(host.activate("Vote Yea", settle: 1.0))
            XCTAssertNil(host.label(ofIdentifier: SealedTally.resultsIdentifier), "Results opened: \(host.text())")
            XCTAssertEqual(host.actionNames(ofIdentifier: SealedTally.reasonsIdentifier), [], "no action after the vote")
        }
    }

    /// Your vote per mode: an updated bill opened where it is listed as updated (`.updatedOnly`) asks for a
    /// vote again in the bar and opens Your vote with "You haven't voted on this bill." when nothing is
    /// held; an Abstain held from before the update unlocks Results and drops the line (the bar asks again).
    /// A `.full` page with a held Yea has no line either.
    func testYourVoteFollowsTheModeAndTheHeldVote() {
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let updated = Self.documentBill(status: .updated)
        APIClient.$current.withValue(offline) {
            let (billsStore, voteStore) = stores([updated])
            let notVoted = AccessibilityTreeText.text(of: page(BillDetail(billID: updated.id, mode: .updatedOnly), billsStore: billsStore, voteStore: voteStore), size: CGSize(width: 390, height: 7000), settle: 0.5)
            for shown in [BillVoteBarModel.updatedCaption, BillYourVoteSection.notVotedText, Self.sealedNotVoted] {
                XCTAssertTrue(notVoted.contains(shown), "\(shown) in: \(notVoted)")
            }

            let held = FakeBillVotesService()
            held.singleResult = .success(.voted(.init(vote: .abstain, votedAt: Date(timeIntervalSince1970: 0))))
            let (heldBills, heldVotes) = stores([updated], votes: held)
            let abstained = AccessibilityTreeText.text(of: page(BillDetail(billID: updated.id, mode: .updatedOnly), billsStore: heldBills, voteStore: heldVotes), size: CGSize(width: 390, height: 7000), settle: 0.5)
            XCTAssertTrue(abstained.contains(BillVoteBarModel.updatedCaption), abstained)
            for gone in [BillYourVoteSection.notVotedText, Self.sealedNotVoted, VoteResultsFormatting.sealedLabel] {
                XCTAssertFalse(abstained.contains(gone), "\(gone) in: \(abstained)")
            }

            let yea = FakeBillVotesService()
            yea.singleResult = .success(.voted(.init(vote: .yea, votedAt: Date())))
            let fresh = Self.documentBill()
            let (yeaBills, yeaVotes) = stores([fresh], votes: yea)
            let voted = AccessibilityTreeText.text(of: page(BillDetail(billID: fresh.id), billsStore: yeaBills, voteStore: yeaVotes), size: CGSize(width: 390, height: 7000), settle: 0.5)
            XCTAssertTrue(voted.contains("You voted Yea"), voted)
            for gone in [BillYourVoteSection.notVotedText, Self.sealedNotVoted, VoteResultsFormatting.sealedLabel, "Why Yea? (optional)", BillDetail.doneTitle] {
                XCTAssertFalse(voted.contains(gone), "\(gone) in: \(voted)")
            }
        }
    }

    /// The tour's "Open this bill" can land on an updated bill, and the project's decision of 2026-10-21 puts "This
    /// bill's summary changed. Vote again:" before the coach mark. At the default size the panel shows one strip,
    /// so the caption shows and the coach mark does not; at AX3 Your vote stacks its rows, so the caption shows
    /// and then the coach mark with Not now. The flag stays pending until a vote is stored or Not now is tapped.
    func testAnUpdatedBillOpenedFromTheTourShowsTheCaptionBeforeTheCoachMark() {
        let defaults = UserDefaults.standard
        let key = FirstRunStorage.voteCoachMarkPendingKey
        let saved = defaults.object(forKey: key)
        addTeardownBlock {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        FirstRunStorage.setVoteCoachMarkPending(true)

        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let updated = Self.documentBill(status: .updated)
        APIClient.$current.withValue(offline) {
            @MainActor func strings(at size: DynamicTypeSize) -> [String] {
                let (billsStore, voteStore) = stores([updated])
                return AccessibilityTreeText.strings(
                    of: page(BillDetail(billID: updated.id, mode: .updatedOnly), billsStore: billsStore, voteStore: voteStore).environment(\.dynamicTypeSize, size),
                    size: CGSize(width: 390, height: 9000),
                    settle: 0.5
                )
            }

            let panel = strings(at: .large)
            let panelText = panel.joined(separator: " | ")
            XCTAssertTrue(panelText.contains(BillVoteBarModel.updatedCaption), "the panel's one strip: \(panelText)")
            for gone in [BillVoteBarModel.coachMarkText, BillVoteBarModel.coachMarkDismissTitle] {
                XCTAssertFalse(panelText.contains(gone), "\(gone) after the caption, in a panel of one strip: \(panelText)")
            }

            let stacked = strings(at: .accessibility3)
            assertInOrder([
                BillYourVoteSection.title,
                BillVoteBarModel.updatedCaption,
                BillVoteBarModel.accessibilityCoachMarkText,
                BillVoteBarModel.coachMarkDismissTitle,
                BillWatchCopy.rowTitle
            ], in: stacked, "AX3: the caption, then the coach mark")
            XCTAssertTrue(FirstRunStorage.voteCoachMarkPending, "showing it ends nothing")
        }
    }

    /// The inline title "Bill" stays off the bar at rest (frames 4 to 8) and shows once the bill's own title
    /// has scrolled under the bar (spec 4.28).
    func testTheInlineTitleShowsOnceTheBillTitleHasScrolledAway() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let bill = Self.documentBill()
        let (billsStore, voteStore) = stores([bill])
        try APIClient.$current.withValue(offline) {
            let host = AccessibilityTreeText.Host(
                page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore),
                size: CGSize(width: 390, height: 844),
                settle: 0.6,
                scene: scene
            )
            defer { host.close() }
            XCTAssertFalse(host.strings().contains(BillDetail.inlineTitle), "no inline title at rest: \(host.text())")
            let scroll = try XCTUnwrap(pageScrollView(in: host.window), "the page scrolls")
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 500), animated: false)
            host.run(until: { host.strings().contains(BillDetail.inlineTitle) })
            XCTAssertTrue(host.strings().contains(BillDetail.inlineTitle), "the inline title once scrolled: \(host.text())")
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            host.run(until: { !host.strings().contains(BillDetail.inlineTitle) })
            XCTAssertFalse(host.strings().contains(BillDetail.inlineTitle), "gone again at the top")
        }
    }

    /// A vote made on the page scrolls Your vote to the top of the visible area (spec 3.13, 5.1), in place of
    /// R2's scroll to the reasons picker or Done.
    func testAVoteScrollsYourVoteToTheTop() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let bill = Self.documentBill()
        let (billsStore, voteStore) = stores([bill])
        try APIClient.$current.withValue(offline) {
            let host = AccessibilityTreeText.Host(
                page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore),
                size: CGSize(width: 390, height: 844),
                settle: 0.6,
                scene: scene
            )
            defer { host.close() }
            let before = try XCTUnwrap(host.frame(of: BillYourVoteSection.title))
            XCTAssertGreaterThan(before.minY, 844, "Your vote starts below the screen")
            XCTAssertTrue(host.activate("Vote Yea", settle: BillDetail.yourVoteScrollDelay + 1.2))
            let after = try XCTUnwrap(host.frame(of: BillYourVoteSection.title))
            XCTAssertGreaterThan(after.minY, 0, "below the top of the screen")
            XCTAssertLessThan(after.minY, 220, "at the top of the visible area, under the bar: \(after)")
        }
    }

    // MARK: The vote panel on the page (spec 3.10, 4.9)

    /// Whether `view` is inside a scroll view (a tap there would reach the page under the panel).
    private func isInScrollView(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is UIScrollView { return true }
            current = candidate.superview
        }
        return false
    }

    /// The panel is the page's only bottom bar, attached with `safeAreaBar`: its bottom edge sits 24 pt above the
    /// screen's bottom edge where there is a home indicator (34 pt safe area) and 12 pt where there is none, 12 pt
    /// in from the sides; the page's text, scrolled to its end, stops at the panel's top (the safe area clears it:
    /// no spacer); and a tap anywhere on the panel, its rim in the home-indicator area included, never reaches the
    /// page under the glass (`PanelRimTapGuard`).
    func testThePanelSitsWhereTheTabCapsuleWouldAndTakesItsOwnTaps() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let bill = Self.documentBill()
        for size in [CGSize(width: 402, height: 874), CGSize(width: 375, height: 667)] {
            let (billsStore, voteStore) = stores([bill])
            try APIClient.$current.withValue(offline) {
                let host = AccessibilityTreeText.Host(page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore), size: size, settle: 0.8, scene: scene)
                defer { host.close() }
                let safeBottom = host.window.safeAreaInsets.bottom
                let yea = try XCTUnwrap(host.frame(ofIdentifier: BillVoteBarModel.identifier(for: .yea)))
                let panel = yea.insetBy(dx: -BillVoteBar.panelPadding, dy: -BillVoteBar.panelPadding)
                let margin: CGFloat = safeBottom > 0 ? 24 : 12
                XCTAssertEqual(panel.maxY, size.height - margin, accuracy: 0.5, "\(size): \(margin) pt above the bottom edge")
                XCTAssertEqual(panel.minX, BillVoteBar.sideMargin, accuracy: 0.5, "\(size): 12 pt from the side")
                for y in stride(from: panel.minY + 2, through: panel.maxY - 2, by: 4) {
                    XCTAssertFalse(isInScrollView(host.window.hitTest(CGPoint(x: panel.midX, y: y), with: nil)), "\(size): a tap at y \(y) on the panel reached the page")
                }
                XCTAssertTrue(isInScrollView(host.window.hitTest(CGPoint(x: panel.midX, y: panel.minY - 12), with: nil)), "\(size): the page above the panel takes its taps")

                let scroll = try XCTUnwrap(pageScrollView(in: host.window))
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
                host.run(0.4)
                let link = try XCTUnwrap(host.frame(of: BillLinkSection.linkTitle))
                let panelAtEnd = try XCTUnwrap(host.frame(ofIdentifier: BillVoteBarModel.identifier(for: .yea))).minY - BillVoteBar.panelPadding
                XCTAssertLessThanOrEqual(link.maxY, panelAtEnd, "\(size): the last line ends above the panel")
                XCTAssertGreaterThan(link.maxY, panelAtEnd - 40, "\(size): and not far above it (no spacer)")
            }
        }

        // At the accessibility sizes, not voted, on a 375 x 667 window: the one Vote button (opaque ink) ends 10 pt
        // above the panel's edge, which ends 12 pt above the window's. At AX4 the bottom safe area measured here
        // came back 5.7e-14, not 0, and the panel took the home indicator's 24 pt (slice 9 review).
        let size = CGSize(width: 375, height: 667)
        for textSize in [DynamicTypeSize.accessibility3, .accessibility4, .accessibility5] {
            let (billsStore, voteStore) = stores([bill])
            try APIClient.$current.withValue(offline) {
                let host = AccessibilityTreeText.Host(
                    page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore).environment(\.dynamicTypeSize, textSize),
                    size: size,
                    settle: 0.8,
                    scene: scene
                )
                defer { host.close() }
                host.window.overrideUserInterfaceStyle = .light
                host.run(0.2)
                XCTAssertEqual(host.window.safeAreaInsets.bottom, 0)
                XCTAssertEqual(host.label(ofIdentifier: BillVoteBarModel.compactIdentifier), BillVoteBarModel.compactTitle, "\(textSize): \(host.text())")
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let capture = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
                    host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
                }
                let image = try XCTUnwrap(capture.cgImage)
                attach(image, name: "panel-bottom-\(textSize)-375x667")
                let pixels = try bitmap(image)
                let x = image.width / 2
                let ink = BillboardPalette.interactive.light.rgb
                let buttonBottom = try XCTUnwrap(pixels.indices.last { distance(pixels[$0][x], ink) < 0.08 }, "\(textSize): the Vote button's ink")
                let panelBottom = CGFloat(buttonBottom + 1) + BillVoteBar.panelPadding
                XCTAssertEqual(panelBottom, size.height - 12, accuracy: 1, "\(textSize): 12 pt above the bottom edge")
            }
        }
    }

    /// From xxxLarge up the panel's strips are the first rows of Your vote, in the panel's order (the refusal, the
    /// `.updatedOnly` caption, the coach mark; project decision of 2026-10-21), and at the accessibility sizes the
    /// full stamp follows once voted (spec 3.13, frames 23 and 24).
    func testYourVoteTakesThePanelsRowsAtTheLargerSizes() throws {
        func section(_ standing: BillYourVoteSection.Standing, rows: BillVoteBarModel.YourVoteRows) -> some View {
            BillYourVoteSection(
                standing: standing,
                isWatching: false,
                showsReasonPicker: false,
                selectedReasons: [],
                reasonVoteType: nil,
                reasonOrder: [],
                onToggleReason: { _ in },
                onSetWatch: { _ in },
                movedRows: rows,
                votedAt: Self.october17
            )
            .background(BillboardColors.document)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(identifier: "America/New_York")!)
        }
        let strips = BillVoteBarModel.YourVoteRows(
            refusal: Self.refusalText,
            caption: BillVoteBarModel.updatedCaption,
            coachMark: BillVoteBarModel.accessibilityCoachMarkText
        )
        for size in [DynamicTypeSize.xxxLarge, .accessibility3, .accessibility5] {
            for scheme in [ColorScheme.light, .dark] {
                let variant = Variant(scheme: scheme, size: size)
                attach(try render(section(.notVoted, rows: strips), variant: variant, width: 375), name: "your-vote-moved-strips-\(variant.name)")
                attach(try render(section(.voted, rows: BillVoteBarModel.YourVoteRows(stamp: .yea)), variant: variant, width: 375), name: "your-vote-moved-stamp-\(variant.name)")
            }
        }
        let host = AccessibilityTreeText.Host(section(.notVoted, rows: strips).environment(\.dynamicTypeSize, .accessibility3), size: CGSize(width: 375, height: 3000))
        defer { host.close() }
        assertInOrder([
            BillYourVoteSection.title,
            "Error: \(Self.refusalText)",
            BillVoteBarModel.updatedCaption,
            BillVoteBarModel.accessibilityCoachMarkText,
            BillVoteBarModel.coachMarkDismissTitle,
            BillYourVoteSection.notVotedText,
            BillWatchCopy.rowTitle
        ], in: host.strings(), "the moved rows come first")
        XCTAssertEqual(host.identifier(of: BillVoteBarModel.updatedCaption), BillVoteBarModel.captionIdentifier)

        let stamp = AccessibilityTreeText.Host(section(.voted, rows: BillVoteBarModel.YourVoteRows(stamp: .yea)).environment(\.dynamicTypeSize, .accessibility5), size: CGSize(width: 375, height: 3000))
        defer { stamp.close() }
        XCTAssertEqual(stamp.label(ofIdentifier: BillVoteBarModel.summaryIdentifier), "You voted Yea on October 17")
        XCTAssertEqual(stamp.actionNames(ofIdentifier: BillVoteBarModel.summaryIdentifier), [BillVoteBarModel.goToResultsAction])
        assertInOrder([BillYourVoteSection.title, "You voted Yea on October 17", BillWatchCopy.rowTitle], in: stamp.strings(), "the stamp, then Watch")
    }

    /// After a vote made here the page scrolls Your vote to the top (0.4 s), and the first row of Results (the
    /// Opening sheet) still shows above the vote panel at the default size (spec 3.13, 5.1): after an Abstain,
    /// which opens no reasons picker, and after a Yea, whose picker is the shorter one, three reasons then More
    /// reasons (project decisions of 2026-10-21; its 14 reasons had put the row about 350 pt under the panel on
    /// 375 x 667). On two phones: a real iPhone SE's screen (375 x 667, the 20 pt status bar and no home
    /// indicator, so the panel sits 12 pt above the bottom edge), not a 375 x 667 window under the iPhone 17
    /// Pro's 62 pt top inset as before, and the iPhone 17 Pro's own (402 x 874, 62 pt at the top and the 34 pt
    /// home indicator). The measured gaps are attached.
    func testAfterAVoteResultsFirstRowShowsAboveThePanelOnAnSEAndA402By874Phone() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // The stats never arrive while the test looks, so Results stay in Opening.
        let waiting = APIClient(transport: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLError(.timedOut)
        })
        let phones: [(name: String, size: CGSize, insets: UIEdgeInsets)] = [
            ("iphone-se-375x667", CGSize(width: 375, height: 667), UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
            ("402x874", CGSize(width: 402, height: 874), UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0))
        ]
        let bill = Self.documentBill()
        for phone in phones {
            for label in ["Abstain", "Vote Yea"] {
                let (billsStore, voteStore) = stores([bill])
                try APIClient.$current.withValue(waiting) {
                    let host = AccessibilityTreeText.Host(
                        page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore),
                        size: phone.size,
                        settle: 0.8,
                        scene: scene,
                        safeAreaInsets: phone.insets
                    )
                    defer { host.close() }
                    XCTAssertEqual(host.safeAreaInsets, phone.insets, "\(phone.name): the phone's screen insets")
                    XCTAssertTrue(host.activate(label, settle: BillDetail.yourVoteScrollDelay + 1.4), "\(phone.name): \(label)")
                    // Until the scroll has landed: under 200 pt and not moving between two looks.
                    var last: CGRect?
                    host.run(until: {
                        let frame = host.frame(of: BillYourVoteSection.title)
                        defer { last = frame }
                        return (frame?.minY ?? .infinity) < 200 && frame == last
                    }, timeout: 8)
                    let title = try XCTUnwrap(host.frame(of: BillYourVoteSection.title))
                    XCTAssertLessThan(title.minY, 200, "\(phone.name), \(label): Your vote at the top: \(title)")
                    let opening = try XCTUnwrap(host.frame(ofIdentifier: SealedTally.openingIdentifier), host.text())
                    let changeFrame = try XCTUnwrap(host.frame(ofIdentifier: BillVoteBarModel.changeIdentifier))
                    let panelTop = changeFrame.minY - BillVoteBar.panelPadding
                    XCTAssertEqual(
                        changeFrame.maxY + BillVoteBar.panelPadding,
                        phone.size.height - BillDetail.panelBottomPadding(safeAreaBottom: phone.insets.bottom) - phone.insets.bottom,
                        accuracy: 1,
                        "\(phone.name): the panel's bottom edge"
                    )
                    // The sheet's column heads and its first row ("Everyone") take its top 60 pt.
                    let rowEnd = opening.minY + 60
                    let message = "\(phone.name), \(label): Results' first row above the panel: sheet \(opening), panel top \(panelTop), row ends \(panelTop - rowEnd) pt above it"
                    let measured = XCTAttachment(string: message)
                    measured.name = "after-\(label == "Abstain" ? "an-abstain" : "a-yea")-results-first-row-\(phone.name)"
                    measured.lifetime = .keepAlways
                    add(measured)
                    XCTAssertLessThan(rowEnd, panelTop, message)
                    // The page's order is the person's (`VoteReasonOrder`); this store's profile has no account ID
                    // yet, so it is the device's.
                    let seed = VoteReasonOrder.seed(accountID: "")
                    if label != "Abstain" {
                        XCTAssertNotNil(host.frame(ofIdentifier: VoteReasonPicker.moreIdentifier), "the shorter picker: \(host.text())")
                        for reason in VoteReasonOrder.order(for: .yea, seed: seed).prefix(VoteReasonPicker.leadingCount) {
                            XCTAssertNotNil(host.frame(of: reason.title), "\(phone.name): \(reason.title) shows")
                        }
                    } else {
                        XCTAssertNotNil(host.frame(of: VoteReason.needMoreInfo.title), "\(phone.name): the Abstain picker: \(host.text())")
                        XCTAssertNil(host.frame(ofIdentifier: VoteReasonPicker.moreIdentifier), "\(phone.name): no More reasons after an Abstain")
                    }
                }
            }
        }
    }

    // MARK: - Slice 7 review fixes

    /// The width `text` takes in the docket face at a text size, in points, on one line.
    private func docketWidth(_ text: String, size: DynamicTypeSize) -> CGFloat {
        let controller = UIHostingController(rootView: Text(text).textRole(.docket).fixedSize().environment(\.dynamicTypeSize, size))
        return controller.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
    }

    /// A ledger column's width at a text size (`LedgerRow` scales it with `.caption`).
    private func columnWidth(_ column: Ledger.Column, size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFontMetrics(forTextStyle: .caption1).scaledValue(for: column.rawValue, compatibleWith: traits)
    }

    /// In Congress names a member bill's sponsor as the Sponsor section does (spec 3.14, 4.30): the name over
    /// the letter-led "R · HOUSE · TX-7", not R2's "Jordan Ellis (R-TX-7)", and read in words. "LATEST
    /// ACTION" fits its label column on one line at every non-accessibility size; under about 347 pt (an
    /// iPhone SE) the labels go above the answers instead of breaking.
    func testInCongressNamesTheSponsorAsTheSponsorSectionDoes() throws {
        let bill = Self.documentBill(status: .passed)
        let row = BillCompanionMemberRow(memberGuid: "BILLS-119hr1234", bill: bill, isHydrated: true, isUnavailable: false, sponsor: Self.sponsor)
        let text = AccessibilityTreeText.text(of: onDocument(row))
        for shown in ["Sponsor: Representative Jordan Ellis, Republican, Texas's 7th district", "Latest action: Subcommittee hearings held."] {
            XCTAssertTrue(text.contains(shown), "\(shown) in: \(text)")
        }
        for gone in ["R-TX", "(R", "TX-7"] {
            XCTAssertFalse(text.contains(gone), "\(gone) is not read: \(text)")
        }
        XCTAssertEqual(Self.sponsor.affiliation, "R · House · TX-7", "the line the row sets under the name")
        XCTAssertNil(BillCompanionMemberRow.sponsor(for: bill), "a sponsor the members manifest does not have is left out")

        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge] {
            for label in [BillCompanionMemberRow.sponsorLabel, BillCompanionMemberRow.latestActionLabel] {
                XCTAssertLessThanOrEqual(docketWidth(label, size: size), columnWidth(.inCongress, size: size), "\(label) on one line at \(size)")
            }
        }
        XCTAssertFalse(LedgerRowLayout(labelWidth: Ledger.Column.inCongress.rawValue).stacks(in: 390 - 2 * BillboardStyle.Space.xl))
        XCTAssertTrue(LedgerRowLayout(labelWidth: Ledger.Column.inCongress.rawValue).stacks(in: 375 - 2 * BillboardStyle.Space.xl))

        for variant in Self.variants(.accessibility3) {
            for width in [CGFloat(375), 390] {
                let image = try render(onDocument(RecordSection(BillCompanionMembersSection.title) { row }), variant: variant, width: width)
                attach(image, name: "in-congress-sponsor-\(variant.name)-\(Int(width))")
            }
        }
    }

    /// A member bill without an official title shows its plain title as a headline (`name`), not in New
    /// York, which is for reading text only (spec 1.3, project decisions); the official title stays upright
    /// in `officialTitle`.
    func testInCongressSetsAMissingOfficialTitleAsAHeadline() throws {
        let titled = BillCompanionMemberRow.titleLine(for: Self.documentBill())
        XCTAssertEqual(titled.text, Self.officialTitle)
        XCTAssertEqual(titled.role, .officialTitle)

        for official in [nil, "", "  "] as [String?] {
            let untitled = Self.documentBill(official: official)
            let line = BillCompanionMemberRow.titleLine(for: untitled)
            XCTAssertEqual(line.text, "Clean Energy Reporting Act")
            XCTAssertEqual(line.role, .name)
            XCTAssertNotEqual(line.role.face, .serif, "not New York")
        }
        let untitledRow = BillCompanionMemberRow(memberGuid: "BILLS-119hr1234", bill: Self.documentBill(official: nil), isHydrated: true, isUnavailable: false)
        let image = try render(onDocument(RecordSection(BillCompanionMembersSection.title) { untitledRow }), variant: Variant(scheme: .light, size: .large), width: 390)
        attach(image, name: "in-congress-no-official-title-light-default")
    }

    /// An action from another year (a bill introduced in 2025, read in 2026) keeps its date in the 56 pt
    /// column: "FEB 10" over "2025", with no comma to break after, each line fitting the column. VoiceOver
    /// reads it "Feb 10, 2025".
    func testAnActionFromAnotherYearSetsItsYearUnderItsDate() throws {
        let english = Locale(identifier: "en_US")
        let now = try XCTUnwrap(FlexibleISO8601.parse("2026-10-18T12:00:00Z"))
        XCTAssertEqual(BillDocketDate.short("2025-02-10", now: now, locale: english), "Feb 10\n2025")
        XCTAssertEqual(BillDocketDate.shortSpoken("2025-02-10", now: now, locale: english), "Feb 10, 2025")
        XCTAssertEqual(BillDocketDate.short("2026-10-09", now: now, locale: english), "Oct 9")
        XCTAssertEqual(BillDocketDate.shortSpoken("2026-10-09", now: now, locale: english), "Oct 9")
        XCTAssertNil(BillDocketDate.shortSpoken(nil, now: now))
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge] {
            // The docket face is monospaced: "Sep 30" is as wide as any month and day.
            for line in ["Sep 30", "2025", BillActionsSection.undatedLabel] {
                XCTAssertLessThanOrEqual(docketWidth(line, size: size), columnWidth(.dates, size: size), "\(line) at \(size)")
            }
        }

        let older = Bill.BillAction(actionCode: nil, actionDate: "2025-02-10", text: "Introduced in House.", type: "IntroReferral", sourceSystem: nil, committees: nil)
        let rows = BillActionsSection.rows(for: [older], now: now)
        XCTAssertEqual(rows.first?.accessibilityLabel.hasPrefix("Feb 10, 2025: Introduced in House."), true, "\(rows)")
        let bill = Self.documentBill(extraActions: [older])
        let spoken = AccessibilityTreeText.text(of: onDocument(BillActionsSection(bill: bill)))
        XCTAssertFalse(spoken.contains("\n"), spoken)
        for variant in Self.variants(.accessibility3) {
            let image = try render(onDocument(BillActionsSection(bill: bill)), variant: variant, width: 375)
            attach(image, name: "actions-another-year-\(variant.name)")
        }
    }

    /// A committee activity's date goes after a "·" beside its words, and alone under them, without the dot,
    /// when they do not fit on one line (a line never opens with "·").
    func testACommitteeDateUnderItsWordsHasNoLeadingDot() throws {
        XCTAssertEqual(BillCommitteeActivityLine.dateText("Oct 9, 2026", besideName: true), "· Oct 9, 2026")
        XCTAssertEqual(BillCommitteeActivityLine.dateText("Oct 9, 2026", besideName: false), "Oct 9, 2026")

        let line = BillCommitteeActivityLine(name: "Referred to", date: "Oct 9, 2026")
        let beside = AccessibilityTreeText.strings(of: onDocument(line), size: CGSize(width: 350, height: 200))
        XCTAssertTrue(beside.contains("· Oct 9, 2026"), "beside the words: \(beside)")
        let stacked = AccessibilityTreeText.strings(
            of: onDocument(line).environment(\.dynamicTypeSize, .accessibility5),
            size: CGSize(width: 200, height: 600)
        )
        XCTAssertTrue(stacked.contains("Oct 9, 2026"), "under the words: \(stacked)")
        XCTAssertFalse(stacked.contains { $0.hasPrefix("·") }, "no line opens with the dot: \(stacked)")

        let bill = Self.documentBill()
        for (variant, width) in [(Variant(scheme: .light, size: .accessibility3), CGFloat(402)), (Variant(scheme: .light, size: .accessibility5), 375)] {
            let image = try render(onDocument(BillCommitteesSection(bill: bill)), variant: variant, width: width)
            attach(image, name: "committees-\(variant.name)-\(Int(width))")
        }
    }

    /// Every pixel of `image`, row by row, in sRGB.
    private func bitmap(_ image: CGImage) throws -> [[BillboardColorMath.RGB]] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        return (0..<image.height).map { y in
            (0..<image.width).map { x in
                let i = (y * image.width + x) * 4
                return (red: Double(bytes[i]) / 255, green: Double(bytes[i + 1]) / 255, blue: Double(bytes[i + 2]) / 255)
            }
        }
    }

    /// `view` drawn at 3x, so text strokes are solid.
    private func render3x<Content: View>(_ view: Content, variant: Variant, width: CGFloat) throws -> CGImage {
        // Lay out on a 3x pixel grid on every simulator: by default SwiftUI rounds to the host screen's, so an
        // iPhone SE (2x) moved text by a point (Xcode Cloud, 2026-11-02).
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
                .environment(\.displayScale, 3)
        )
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    /// The pixel rows (at 3x) that hold a dotted rule across the column: many short marks, none darker than
    /// the rule itself (a line of text has ink; a tag's edge is one long mark).
    private func dottedRuleRows(in image: CGImage, ground: BillboardColorMath.RGB, rule: BillboardColorMath.RGB) throws -> [Int] {
        let pixels = try bitmap(image)
        let ruleDistance = distance(rule, ground)
        let gutter = Int(BillboardStyle.Space.xl * 3)
        return pixels.indices.filter { y in
            let row = pixels[y][gutter..<(image.width - gutter)]
            var transitions = 0
            var wasMark = false
            var darkest = 0.0
            for pixel in row {
                let away = distance(pixel, ground)
                darkest = max(darkest, away)
                let isMark = away > ruleDistance / 2
                if isMark != wasMark { transitions += 1 }
                wasMark = isMark
            }
            return transitions >= 60 && darkest <= ruleDistance + 0.08
        }
    }

    /// After a Yea or Nay made on the page, a dotted rule sets the reasons picker off from the Watch row
    /// (frames 5 and 22): 18 pt under the row, in light and dark. Without the picker there is none.
    func testADottedRuleSetsTheReasonsPickerOffTheWatchRow() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let variant = Variant(scheme: scheme, size: .large)
            let ground = BillboardPalette.document.resolved(dark: dark).rgb
            let token = BillboardPalette.rule2.resolved(dark: dark)
            let rule = BillboardColorMath.composite(token.rgb, alpha: token.alpha, over: ground)

            let without = try render3x(voteSection(.voted), variant: variant, width: 390)
            XCTAssertEqual(try dottedRuleRows(in: without, ground: ground, rule: rule), [], "no picker, no rule (\(scheme))")

            let with = try render3x(voteSection(.voted, reasonsFor: .yea, reasons: [.economicImpact]), variant: variant, width: 390)
            attach(with, name: "your-vote-reasons-rule-\(scheme)")
            let rows = try dottedRuleRows(in: with, ground: ground, rule: rule)
            XCTAssertFalse(rows.isEmpty, "the dotted rule (\(scheme))")
            XCTAssertLessThanOrEqual((rows.last ?? 0) - (rows.first ?? 0), 3, "one rule, 1 pt: \(rows) (\(scheme))")
            // The section without the picker ends 24 pt under the Watch row; the rule is 18 pt under it.
            let watchRowBottom = CGFloat(without.height) / 3 - 24
            let ruleTop = CGFloat(rows.first ?? 0) / 3
            XCTAssertEqual(ruleTop, watchRowBottom + BillYourVoteSection.reasonsRuleSpacing.above, accuracy: 1.5, "(\(scheme))")
        }
    }

    /// The loading caption is `caption` ink 2 (spec 3.20, 4.48), not ink 3: the darkest pixel under the
    /// spinner is the ink 2 of the text.
    func testTheLoadingCaptionIsInk2() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let image = try render3x(BillDetailLoadingView().frame(height: 300), variant: Variant(scheme: scheme, size: .large), width: 375)
            let pixels = try bitmap(image)
            let ground = BillboardPalette.document.resolved(dark: dark).rgb
            // The caption sits under the middle of the view (the spinner is above it).
            let middle = image.height / 2
            var darkest = ground
            for y in (middle + 3 * 4)..<min(image.height, middle + 3 * 40) {
                for pixel in pixels[y] where distance(pixel, ground) > distance(darkest, ground) {
                    darkest = pixel
                }
            }
            let ink2 = BillboardPalette.secondaryText.resolved(dark: dark).rgb
            let ink3 = BillboardPalette.dimText.resolved(dark: dark).rgb
            XCTAssertLessThan(distance(darkest, ink2), 0.06, "ink 2 (\(scheme)): \(darkest)")
            XCTAssertLessThan(distance(darkest, ink2), distance(darkest, ink3), "closer to ink 2 than ink 3 (\(scheme))")
        }
    }

    /// A navigation path a test can push onto.
    private final class PushPath: ObservableObject {
        @Published var pages: [String] = []
    }

    /// `detail` at the root of a stack whose path the test holds.
    private struct PushStack: View {
        @ObservedObject var path: PushPath
        let detail: BillDetail

        var body: some View {
            NavigationStack(path: $path.pages) {
                detail.navigationDestination(for: String.self) { page in
                    Text(page)
                }
            }
        }
    }

    /// The bar shows "Bill" only once the bill's title has scrolled away, but the screen's title is "Bill"
    /// all along: a page pushed from the bill page at rest (the sponsor's member page) goes back to "Bill",
    /// not to "Back", as one pushed after scrolling does.
    func testAPagePushedFromTheBillPageAtRestGoesBackToBill() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let bill = Self.documentBill()
        let (billsStore, voteStore) = stores([bill])
        let path = PushPath()
        try APIClient.$current.withValue(offline) {
            let host = AccessibilityTreeText.Host(
                PushStack(path: path, detail: BillDetail(billID: bill.id))
                    .environmentObject(billsStore)
                    .environmentObject(voteStore)
                    .environmentObject(AppReadState(scope: .user("bill-document-tests"), store: InMemoryReadStateStore()))
                    .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
                    .environmentObject(manifestStore()),
                size: CGSize(width: 390, height: 844),
                settle: 0.6,
                scene: scene
            )
            defer { host.close() }
            let navigation = try XCTUnwrap(host.navigationController, "the stack's navigation controller")
            XCTAssertEqual(navigation.topViewController?.navigationItem.title, BillDetail.inlineTitle, "the screen's title at rest")
            XCTAssertFalse(host.strings().contains(BillDetail.inlineTitle), "not shown in the bar at rest: \(host.text())")

            path.pages.append("Member page")
            host.run(untilSettled: {
                navigation.viewControllers.count == 2
                    && navigation.navigationBar.backItem?.title == BillDetail.inlineTitle
                    && host.traits(of: BillDetail.inlineTitle)?.contains(.button) == true
            })
            XCTAssertEqual(navigation.viewControllers.count, 2, "pushed")
            XCTAssertEqual(navigation.navigationBar.backItem?.title, BillDetail.inlineTitle, "the back item")
            // VoiceOver's back button is labelled with the bill page's title (it said "Back" when that was
            // empty); only the chevron image inside it keeps the word "Back".
            XCTAssertEqual(host.traits(of: BillDetail.inlineTitle)?.contains(.button), true, "the back button reads Bill: \(host.text())")
        }
    }

    /// A stack whose path the test holds, with the bill page pushed on a root, as a tab pushes it.
    private struct PushedBillStack: View {
        @ObservedObject var path: PushPath
        let detail: BillDetail

        var body: some View {
            NavigationStack(path: $path.pages) {
                Text("Bills").navigationDestination(for: String.self) { _ in
                    detail
                }
            }
        }
    }

    /// The first-vote topic prompt is asked on an event, not a timer (spec 4.39): a vote saved on the page asks
    /// nothing while the page is up (the reasons and the Results that just opened stay in view), and asks once
    /// the page is taken off its stack, with the guid the vote went to.
    func testAVoteSavedHereAsksForTheTopicPromptOnceThePageIsLeft() throws {
        @MainActor final class Received {
            var requests: [FirstVoteTopicPromptTrigger.Request] = []
        }
        let received = Received()
        let observer = NotificationCenter.default.addObserver(forName: .billboardFirstVoteTopicPromptTrigger, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                if let request = FirstVoteTopicPromptTrigger.Request(userInfo: note.userInfo) {
                    received.requests.append(request)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let offline = APIClient(transport: { _ in throw URLError(.notConnectedToInternet) })
        let bill = Self.documentBill()
        let (billsStore, voteStore) = stores([bill])
        let path = PushPath()
        path.pages = ["bill"]
        APIClient.$current.withValue(offline) {
            let host = AccessibilityTreeText.Host(
                PushedBillStack(path: path, detail: BillDetail(billID: bill.id))
                    .environmentObject(billsStore)
                    .environmentObject(voteStore)
                    .environmentObject(AppReadState(scope: .user("bill-document-tests"), store: InMemoryReadStateStore()))
                    .environmentObject(UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService()))
                    .environmentObject(manifestStore()),
                size: CGSize(width: 390, height: 844),
                settle: 0.8,
                scene: scene
            )
            defer { host.close() }
            XCTAssertTrue(host.activate("Vote Yea", settle: 1.2), host.text())
            XCTAssertEqual(received.requests, [], "nothing while the page is up")
            path.pages.append("member")
            host.run(1.0)
            host.run(untilSettled: { path.pages.count == 1 })
            XCTAssertEqual(received.requests, [], "nothing for a page pushed over it")
            path.pages.removeLast()
            host.run(1.0)
            host.run(untilSettled: { path.pages.isEmpty })
            XCTAssertEqual(received.requests, [], "back on the page")
            path.pages.removeAll()
            host.run(untilSettled: { !received.requests.isEmpty })
            host.run(0.5) // and no second request
            XCTAssertEqual(received.requests.map(\.votedGUID), ["BILLS-119hr1234"], "asked once the page was left")
        }
    }

    /// Only the first vote made on the page scrolls Your vote to the top (spec 3.13, as R2's scroll was). Try
    /// again on "Results show once your vote is saved." sends the vote again and leaves the page where it
    /// is, where its answer shows; so does a Change.
    func testTryAgainAndAChangeLeaveThePageWhereItIs() throws {
        XCTAssertTrue(BillDetail.scrollsToYourVote(afterAVoteHere: false, isRetry: false), "the first vote here")
        XCTAssertFalse(BillDetail.scrollsToYourVote(afterAVoteHere: true, isRetry: false), "a Change")
        XCTAssertFalse(BillDetail.scrollsToYourVote(afterAVoteHere: false, isRetry: true), "Try again")
        XCTAssertFalse(BillDetail.scrollsToYourVote(afterAVoteHere: true, isRetry: true), "Try again")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // The vote is kept on the device (offline) and the server holds none: RESULTS_LOCKED, so Results say
        // "Results show once your vote is saved." with Try again.
        let lockedStats = APIClient(transport: { request in
            if await request.path == "bill-stats" { throw backendError(await BillStatsService.resultsLockedCode) }
            throw URLError(.notConnectedToInternet)
        })
        let votes = FakeBillVotesService()
        votes.setFeedbackError = URLError(.notConnectedToInternet)
        let bill = Self.documentBill()
        let (billsStore, voteStore) = stores([bill], votes: votes)
        try APIClient.$current.withValue(lockedStats) {
            let host = AccessibilityTreeText.Host(
                page(BillDetail(billID: bill.id), billsStore: billsStore, voteStore: voteStore),
                size: CGSize(width: 390, height: 844),
                settle: 0.6,
                scene: scene
            )
            defer { host.close() }
            let settle = BillDetail.yourVoteScrollDelay + 1.2
            XCTAssertTrue(host.activate("Vote Yea", settle: settle))
            XCTAssertTrue(host.text().contains(VoteResultsFormatting.awaitingSaveText), host.text())
            let atTop = try XCTUnwrap(host.frame(of: BillYourVoteSection.title))
            XCTAssertLessThan(atTop.minY, 220, "the first vote scrolled Your vote to the top: \(atTop)")

            // Read on down to Results, then tap Try again there.
            let scroll = try XCTUnwrap(pageScrollView(in: host.window), "the page scrolls")
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 300), animated: false)
            host.run(0.3)
            let readingResults = try XCTUnwrap(host.frame(of: BillYourVoteSection.title))
            XCTAssertTrue(host.activate(VoteResultsFormatting.tryAgainTitle, settle: settle), host.text())
            XCTAssertEqual(votes.setFeedbackCalls.count, 2, "Try again sent the vote again")
            let afterTryAgain = try XCTUnwrap(host.frame(of: BillYourVoteSection.title))
            XCTAssertEqual(afterTryAgain.minY, readingResults.minY, accuracy: 2, "Try again leaves the page where it is")

            XCTAssertTrue(host.activate("Change your vote", settle: 0.6))
            XCTAssertTrue(host.activate("Vote Nay", settle: settle))
            XCTAssertEqual(votes.setFeedbackCalls.map(\.feedback).last, .nay)
            let afterChange = try XCTUnwrap(host.frame(of: BillYourVoteSection.title))
            XCTAssertEqual(afterChange.minY, readingResults.minY, accuracy: 2, "a Change leaves the page where it is")
        }
    }

    // MARK: - Slice 8 review fixes

    /// `view` in a light window on the test host's screen, drawn at 1x with `drawHierarchy`.
    @MainActor
    private final class HostedWindow<Content: View> {
        let window: UIWindow
        let host: UIHostingController<Content>

        init(_ view: Content, size: CGSize, scene: UIWindowScene) {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = .light
            host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
        }

        func run(_ interval: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            host.view.layoutIfNeeded()
        }

        func capture() throws -> CGImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            return try XCTUnwrap(image.cgImage)
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// Whether Everyone's Yea segment reaches the bar's leading end at x = 21 (a 20 pt gutter, 1x, light).
    private func yeaReachesTheLeadingEnd(_ image: CGImage) throws -> Bool {
        let pixels = try bitmap(image)
        let yea = BillboardPalette.voteYea.light.rgb
        return pixels.indices.contains { y in distance(pixels[y][21], yea) < 0.06 }
    }

    /// The number of pixels that differ visibly between two captures of the same size.
    private func differingPixels(_ a: CGImage, _ b: CGImage) throws -> Int {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let first = try bitmap(a)
        let second = try bitmap(b)
        var count = 0
        for y in 0..<min(first.count, second.count) {
            for x in 0..<min(first[y].count, second[y].count) where distance(first[y][x], second[y][x]) > 0.1 {
                count += 1
            }
        }
        return count
    }

    /// Clears the panel's inked vote, as `BillDetail` does 180 ms after the tap (`BallotMoment.inkHold`).
    private final class InkSwitch: ObservableObject {
        @Published var inked: VoteChoice?

        init(inked: VoteChoice?) {
            self.inked = inked
        }
    }

    /// A voted Nay panel, 12 pt in from the sides of a 402 pt window, inked until `ink` clears it.
    private struct InkSwitchedPanel: View {
        @ObservedObject var ink: InkSwitch
        let reduceMotion: Bool

        var body: some View {
            BillVoteBar(
                model: BillVoteBarModel(mode: .full, choice: .nay),
                votedAt: BillDetailRenderTests.october17,
                inked: ink.inked,
                onVote: { _ in },
                onChange: {},
                onCollapse: {}
            )
            .padding(.horizontal, BillVoteBar.sideMargin)
            .frame(maxHeight: .infinity)
            .background(BillboardColors.document)
            .environment(\._accessibilityReduceMotion, reduceMotion)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, TimeZone(identifier: "America/New_York")!)
        }
    }

    /// The inked button becomes the stamp in place (spec 3.10 step 2, 5.1): when the button row gives way, the
    /// stamp starts from the inked Nay's frame and moves and grows into its own while the two cross-fade (they
    /// share `BillVoteBar.morphID`). With Reduce Motion nothing is matched: the stamp is in its own place at once
    /// and only fades. The morph runs here as a 10 s linear animation, so the frame read half a second in is
    /// early in it on any machine.
    func testTheInkedButtonBecomesTheStampInPlace() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = CGSize(width: 402, height: 200)
        for reduceMotion in [false, true] {
            let settled = AccessibilityTreeText.Host(InkSwitchedPanel(ink: InkSwitch(inked: nil), reduceMotion: reduceMotion), size: size, settle: 0.3, scene: scene)
            let stamp = try XCTUnwrap(settled.frame(ofIdentifier: BillVoteBarModel.summaryIdentifier), "the settled stamp")
            settled.close()

            let ink = InkSwitch(inked: .nay)
            let host = AccessibilityTreeText.Host(InkSwitchedPanel(ink: ink, reduceMotion: reduceMotion), size: size, settle: 0.3, scene: scene)
            defer { host.close() }
            let nay = try XCTUnwrap(host.frame(ofIdentifier: BillVoteBarModel.identifier(for: .nay)), "the inked Nay")
            XCTAssertNil(host.frame(ofIdentifier: BillVoteBarModel.summaryIdentifier), "no stamp while inked")
            withAnimation(.linear(duration: 10)) {
                ink.inked = nil
            }
            host.run(0.5)
            let early = try XCTUnwrap(host.frame(ofIdentifier: BillVoteBarModel.summaryIdentifier), host.text())
            if reduceMotion {
                XCTAssertEqual(early.minX, stamp.minX, accuracy: 0.5, "Reduce Motion: in its own place (\(early), settled \(stamp))")
                XCTAssertEqual(early.width, stamp.width, accuracy: 0.5, "Reduce Motion: its own width")
            } else {
                // A twentieth of the way from the Nay's frame to the stamp's: still over the inked Nay, well short of
                // its own place (it is never narrower than its no-date row, so it overhangs the Nay's frame early on).
                XCTAssertLessThan(early.minX, nay.midX, "over the inked Nay (\(early), Nay \(nay), settled \(stamp))")
                XCTAssertGreaterThan(early.maxX, nay.midX, "over the inked Nay (\(early), Nay \(nay), settled \(stamp))")
                XCTAssertGreaterThan(early.minX - stamp.minX, 20, "not yet in its own place (\(early), settled \(stamp))")
                XCTAssertEqual(early.midY, nay.midY, accuracy: 1, "in the Nay's row")
            }
        }
    }

    /// Turns a tally's `grows` on while it is shown, as `didJustVote` does when the user votes again on a page
    /// whose Results were already open.
    private final class GrowSwitch: ObservableObject {
        @Published var grows = false
    }

    private struct SwitchedTally: View {
        @ObservedObject var growSwitch: GrowSwitch
        let rows: [VoteResultsFormatting.NationalRow]

        var body: some View {
            BillResultsComparison(rows: rows, yourVote: .yea, grows: growSwitch.grows)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(BillboardColors.document)
        }
    }

    /// Results were open when the page opened (a vote held), then the user votes again here (Change, or a new
    /// vote over a held Abstain): the open sheet keeps its figures, bars and "You" marker. It grows only when
    /// it first appears after a vote here (spec 3.7, 5.1); a later vote's refresh tweens. Before, `grows`
    /// turning on under a sheet that had appeared without growing drew "0%", "0%", "0" and empty bars until
    /// the page was left.
    func testAVoteHereUnderOpenResultsKeepsTheirFiguresAndBars() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let rows = VoteResultsFormatting.nationalRows(try Self.bothRowsStats().resolvedComparison)
        let growSwitch = GrowSwitch()
        let hosted = HostedWindow(SwitchedTally(growSwitch: growSwitch, rows: rows), size: CGSize(width: 390, height: 300), scene: scene)
        defer { hosted.close() }
        hosted.run(0.6)
        let before = try hosted.capture()
        XCTAssertTrue(try yeaReachesTheLeadingEnd(before), "open at full width")

        growSwitch.grows = true
        hosted.run(1.2)
        let after = try hosted.capture()
        attach(before, name: "tally-before-a-vote-here")
        attach(after, name: "tally-after-a-vote-here")
        XCTAssertTrue(try yeaReachesTheLeadingEnd(after), "the bars keep their widths")
        XCTAssertEqual(try differingPixels(before, after), 0, "figures, bars and the You marker unchanged")
    }

    /// The bars grow the first time the open sheet is on screen (spec 5.1, 4.40), not when it is inserted
    /// below the fold: a sheet that waits off screen longer than the grow still starts from the centre gap
    /// when it is scrolled into view, then ends at full width.
    func testTheBarsGrowTheFirstTimeTheyAreOnScreen() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let rows = VoteResultsFormatting.nationalRows(try Self.bothRowsStats().resolvedComparison)
        let page = ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 1200)
                BillResultsComparison(rows: rows, yourVote: .yea, grows: true)
                    .padding(20)
                Color.clear.frame(height: 600)
            }
        }
        .background(BillboardColors.document)
        let hosted = HostedWindow(page, size: CGSize(width: 390, height: 400), scene: scene)
        defer { hosted.close() }
        hosted.run(1.0)
        let scroll = try XCTUnwrap(pageScrollView(in: hosted.host.view), "the page scrolls")
        scroll.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        hosted.run(0.05)
        let arriving = try hosted.capture()
        attach(arriving, name: "tally-scrolled-into-view")
        XCTAssertFalse(try yeaReachesTheLeadingEnd(arriving), "still growing from the centre gap as it comes on screen")
        hosted.run(1.2)
        let grown = try hosted.capture()
        attach(grown, name: "tally-grown-on-screen")
        XCTAssertTrue(try yeaReachesTheLeadingEnd(grown), "grown to full width")
    }

    /// While the sheet waits to grow, with its first row in view but less than half its rows (just above the
    /// vote panel, say), the row's figures are blank: scaled by the grow's progress of 0 they read "0%  0%  0",
    /// the words of a bill with no Yea or Nay votes, while VoiceOver read the real figures. Once the rows are
    /// on screen the figures roll up and show.
    func testTheFiguresAreBlankWhileTheSheetWaitsToGrow() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let rows = VoteResultsFormatting.nationalRows(try Self.bothRowsStats().resolvedComparison)
        let page = ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 1200)
                BillResultsComparison(rows: rows, yourVote: .yea, grows: true)
                    .padding(20)
                Color.clear.frame(height: 600)
            }
        }
        .background(BillboardColors.document)
        let height: CGFloat = 400
        let host = AccessibilityTreeText.Host(page, size: CGSize(width: 390, height: height), settle: 1.0, scene: scene)
        defer { host.close() }
        host.window.overrideUserInterfaceStyle = .light
        let scroll = try XCTUnwrap(pageScrollView(in: host.window), "the page scrolls")
        let row = try XCTUnwrap(host.frame(ofIdentifier: "bill.results.everyone"), host.text())
        // Everyone's figures (the line under the 10 pt row top) just inside the window's bottom edge.
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + row.minY + 32 - height), animated: false)
        host.run(0.6)
        let sheet = try XCTUnwrap(host.frame(ofIdentifier: "bill.results.national"))
        XCTAssertLessThan(height - sheet.minY, sheet.height / 2, "less than half the sheet in view: \(sheet)")

        func inkInFigures() throws -> Int {
            let everyone = try XCTUnwrap(host.frame(ofIdentifier: "bill.results.everyone"))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = try XCTUnwrap(UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
                host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
            }.cgImage)
            attach(image, name: "tally-figures-\(Int(everyone.minY))")
            let pixels = try bitmap(image)
            let ink = BillboardPalette.primaryText.light.rgb
            // The Nay and Votes columns: the Yea column also holds the 50% tick over the bar.
            let columns = TallySheetMetrics.nayColumn + TallySheetMetrics.votesColumn
            var count = 0
            for y in Int(everyone.minY + TallySheetMetrics.rowTop)..<Int(everyone.minY + 31) where pixels.indices.contains(y) {
                for x in Int(everyone.maxX - columns)..<Int(everyone.maxX) where distance(pixels[y][x], ink) < 0.25 {
                    count += 1
                }
            }
            return count
        }
        XCTAssertEqual(try inkInFigures(), 0, "no \"0%  0%  0\" while the sheet waits to grow")

        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 200), animated: false)
        host.run(1.2)
        host.run(until: { ((try? inkInFigures()) ?? 0) > 20 })
        XCTAssertGreaterThan(try inkInFigures(), 20, "the figures once grown")
    }

    /// While the vote is checked (a spinner, no stamp) and in Opening, the sealed Why people voted says
    /// nothing under its spinner: "Reasons open after you vote." would tell a returning voter to vote while
    /// the app checks, and someone who just voted that they have not. It stays under the stamped sheets.
    func testTheSealedReasonsSayNothingBesideASpinner() {
        let states: [(access: BillResultsAccess, didVoteHere: Bool, says: Bool)] = [
            (.locked(.notVoted), false, true),
            (.locked(.checking), false, false),
            (.locked(.checkFailed), false, true),
            (.awaitingSave(canRetry: true), false, true),
            (.open, true, false)
        ]
        for state in states {
            let host = AccessibilityTreeText.Host(resultsArea(state.access, stats: nil, didVoteHere: state.didVoteHere))
            let text = host.text()
            XCTAssertEqual(text.contains(VoteResultsFormatting.reasonsSealedText), state.says, "\(state.access): \(text)")
            XCTAssertEqual(host.value(ofIdentifier: SealedTally.reasonsIdentifier) == VoteResultsFormatting.reasonsSealedText, state.says, "\(state.access)")
            host.close()
        }
    }

    /// At AX5 the spinner's words wrap under the sheet's width instead of widening it, so the bill page keeps
    /// its gutters (spec 7.2): every sealed state and Opening is exactly as wide as offered on a 375 pt and a
    /// 402 pt phone, also at AX3.
    func testTheSealedSheetIsAsWideAsOfferedAtAccessibilitySizes() throws {
        let states = Self.lockedStates.map { ($0.name, $0.access, false) } + [("opening", BillResultsAccess.open, true)]
        for size in [DynamicTypeSize.accessibility3, .accessibility5] {
            for width: CGFloat in [375, 402] {
                for (name, access, didVoteHere) in states {
                    let variant = Variant(scheme: .light, size: size)
                    let image = try render(resultsArea(access, stats: nil, didVoteHere: didVoteHere), variant: variant, width: width)
                    if name == "sealed-checking" || name == "opening" {
                        attach(image, name: "results-\(name)-\(Int(width))-\(variant.name)")
                    }
                    XCTAssertEqual(CGFloat(image.width), width, "\(name) at \(Int(width)) pt, \(variant.name)")
                }
            }
        }
    }

    /// The SEALED stamp's box in a 3x render, in points: the rows of its long ink rules (more than 30 pt and
    /// less than most of the column, so neither text nor the heavy rule), and its side rules, found in the
    /// box's middle row just outside the ends of those long rules (their corners are rounded).
    private func sealBox(in image: CGImage, dark: Bool = false) throws -> CGRect? {
        let pixels = try bitmap(image)
        let ink = BillboardPalette.primaryText.resolved(dark: dark).rgb
        let column = image.width - 6 * Int(BillboardStyle.Space.xl)
        var rules: [(y: Int, start: Int, end: Int)] = []
        for y in pixels.indices {
            var run = 0
            var longest = (length: 0, end: 0)
            for x in pixels[y].indices {
                run = distance(pixels[y][x], ink) < 0.1 ? run + 1 : 0
                if run > longest.length { longest = (run, x) }
            }
            if longest.length > 90, longest.length < column * 8 / 10 {
                rules.append((y, longest.end - longest.length + 1, longest.end))
            }
        }
        guard let top = rules.first?.y, let bottom = rules.last?.y,
              let start = rules.map(\.start).min(), let end = rules.map(\.end).max() else { return nil }
        let middle = pixels[(top + bottom) / 2]
        let corner = 15
        let leading = (max(0, start - corner)...start).first { distance(middle[$0], ink) < 0.1 } ?? start
        let trailing = (end...min(middle.count - 1, end + corner)).last { distance(middle[$0], ink) < 0.1 } ?? end
        return CGRect(x: CGFloat(leading) / 3, y: CGFloat(top) / 3, width: CGFloat(trailing - leading + 1) / 3, height: CGFloat(bottom - top + 1) / 3)
    }

    /// Frame 26: at accessibility sizes the SEALED stamp sits above the rows on the leading gutter, in a box
    /// that fits its word (the word's line and 2 pt above and below), on Results and Why people voted. At the
    /// default size it stays the 28 pt stamp centred over the rows.
    func testTheSealStampSitsSnugOnTheGutterAtAccessibilitySizes() throws {
        let width: CGFloat = 375
        for size in [DynamicTypeSize.accessibility3, .accessibility5] {
            let wordSize = TextRole.stamp.scaledSize(for: size) * StatusStamp.Size.seal.scale
            let snug = UIFont.monospacedSystemFont(ofSize: wordSize, weight: .semibold).lineHeight + 4
            for kind in [SealedTally.Kind.results, .reasons] {
                let image = try render3x(SealedTally(kind: kind, state: .notVoted).background(BillboardColors.document), variant: Variant(scheme: .light, size: size), width: width)
                attach(image, name: "sealed-\(kind)-\(size)")
                let box = try XCTUnwrap(try sealBox(in: image), "\(kind) \(size)")
                XCTAssertEqual(box.minX, BillboardStyle.Space.xl, accuracy: 0.7, "on the leading gutter: \(kind) \(size) \(box)")
                XCTAssertEqual(box.height, snug, accuracy: 2, "fits its word: \(kind) \(size) \(box)")
            }
        }
        let image = try render3x(SealedTally(kind: .results, state: .notVoted).background(BillboardColors.document), variant: Variant(scheme: .light, size: .large), width: width)
        let box = try XCTUnwrap(try sealBox(in: image))
        XCTAssertEqual(box.height, 28, accuracy: 1, "\(box)")
        XCTAssertEqual(box.midX, width / 2, accuracy: 1, "centred over the rows: \(box)")
    }

    /// The Results info button's glyph stays inside the 20 pt gutter at every text size, in line with the
    /// column heads and figures below it; its 44 pt target only overhangs where the glyph is smaller.
    func testTheInfoButtonStaysInsideTheGutterAtEverySize() throws {
        let width: CGFloat = 402
        let stats = try Self.bothRowsStats()
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5] {
            let variant = Variant(scheme: .light, size: size)
            let image = try render3x(tallySheet(stats), variant: variant, width: width)
            let pixels = try bitmap(image)
            let ink = BillboardPalette.ruleHeavy.light.rgb
            let gutter = 3 * Int(BillboardStyle.Space.xl)
            let headRule = try XCTUnwrap(pixels.indices.first { y in
                pixels[y][gutter..<(image.width - gutter)].allSatisfy { distance($0, ink) < 0.1 }
            }, "the column heads' rule at \(variant.name)")
            var trailingInk = 0
            for y in 0..<headRule {
                for x in pixels[y].indices.reversed() where distance(pixels[y][x], ink) < 0.3 {
                    trailingInk = max(trailingInk, x)
                    break
                }
            }
            if size == .accessibility3 { attach(image, name: "results-title-\(variant.name)") }
            XCTAssertLessThanOrEqual(CGFloat(trailingInk) / 3, width - BillboardStyle.Space.xl, "inside the gutter at \(variant.name)")
            // Its frame ends on the gutter; the symbol draws inside it by a margin that grows with the size
            // (about 1.3 pt at the default size, 6 pt at AX5).
            XCTAssertGreaterThan(CGFloat(trailingInk) / 3, width - BillboardStyle.Space.xl - 7, "on the gutter at \(variant.name)")

            let host = AccessibilityTreeText.Host(tallySheet(stats).environment(\.dynamicTypeSize, size), size: CGSize(width: width, height: 1600))
            let target = try XCTUnwrap(host.frame(of: VoteResultsFormatting.infoTitle), variant.name)
            host.close()
            XCTAssertGreaterThanOrEqual(target.width, 44, variant.name)
            XCTAssertGreaterThanOrEqual(target.height, 44, variant.name)
        }
    }

    /// The runs of inked columns in a 3x render's lines of text, in pixels: a line is a band of rows with
    /// ink, and a run ends at a gap wider than `gap` pixels.
    private func inkRuns(in image: CGImage, ink: BillboardColorMath.RGB, gap: Int) throws -> [ClosedRange<Int>] {
        let pixels = try bitmap(image)
        let inked = pixels.map { row in row.map { distance($0, ink) < 0.35 } }
        var bands: [ClosedRange<Int>] = []
        for y in inked.indices where inked[y].contains(true) {
            if let last = bands.last, last.upperBound == y - 1 {
                bands[bands.count - 1] = last.lowerBound...y
            } else {
                bands.append(y...y)
            }
        }
        var runs: [ClosedRange<Int>] = []
        for band in bands {
            let columns = (0..<image.width).filter { x in band.contains { inked[$0][x] } }
            var run: ClosedRange<Int>?
            for x in columns {
                if let current = run, x - current.upperBound <= gap {
                    run = current.lowerBound...x
                } else {
                    if let current = run { runs.append(current) }
                    run = x...x
                }
            }
            if let run { runs.append(run) }
        }
        return runs
    }

    /// The map ramp's labels (spec 3.9): "50/50" centred on the ramp's midpoint and never broken, with
    /// "100% NAY" and "100% YEA" at the ends. They share one row where it fits with "50/50" centred (to
    /// xxxLarge) and take a line each at the accessibility sizes, where one row put "100% NAY" on two
    /// lines and moved "50/50" off the midpoint (AX3) or broke it (AX5).
    func testTheMapRampLabelsKeepFiftyFiftyOnTheMidpoint() throws {
        let width: CGFloat = 362
        let ink = BillboardPalette.secondaryText.light.rgb
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            let variant = Variant(scheme: .light, size: size)
            let image = try render3x(VoterMapRampLabels().background(BillboardColors.document), variant: variant, width: width)
            attach(image, name: "map-ramp-labels-\(variant.name)")
            XCTAssertEqual(CGFloat(image.width) / 3, width, variant.name)

            let midAlone = Text(VoterMapRampLabels.midText).textRole(.docket).fixedSize().environment(\.dynamicTypeSize, size)
            let line = UIHostingController(rootView: midAlone).sizeThatFits(in: CGSize(width: 1000, height: 1000)).height
            let lines = (CGFloat(image.height) / 3 / line).rounded(.down)
            XCTAssertEqual(lines, size.isAccessibilitySize ? 3 : 1, "\(variant.name): \(image.height / 3) pt for \(line) pt lines")

            // The run nearest the middle is "50/50", whole, and centred on it.
            let gap = Int(TextRole.docket.scaledSize(for: size) * 3 / 2)
            let runs = try inkRuns(in: image, ink: ink, gap: gap)
            let centre = CGFloat(image.width) / 2
            let mid = try XCTUnwrap(runs.min { abs(CGFloat($0.lowerBound + $0.upperBound) / 2 - centre) < abs(CGFloat($1.lowerBound + $1.upperBound) / 2 - centre) })
            XCTAssertEqual(CGFloat(mid.lowerBound + mid.upperBound + 1) / 6, width / 2, accuracy: 1, "\(variant.name): 50/50 on the midpoint")
            let alone = try render3x(midAlone.background(BillboardColors.document), variant: variant, width: 1000)
            let aloneRun = try XCTUnwrap(try inkRuns(in: alone, ink: ink, gap: gap).first)
            XCTAssertEqual(mid.count, aloneRun.count, accuracy: 3, "\(variant.name): 50/50 whole")
        }
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

    private func distance(_ a: BillboardColorMath.RGB, _ b: BillboardColorMath.RGB) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }

    private func assertColor(
        _ sample: BillboardColorMath.RGB,
        _ expected: BillboardColorMath.RGB,
        accuracy: Double,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sample.red, expected.red, accuracy: accuracy, "red: \(message)", file: file, line: line)
        XCTAssertEqual(sample.green, expected.green, accuracy: accuracy, "green: \(message)", file: file, line: line)
        XCTAssertEqual(sample.blue, expected.blue, accuracy: accuracy, "blue: \(message)", file: file, line: line)
    }

    /// The sRGB colour of one pixel, `x` and `y` from the top left.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> BillboardColorMath.RGB {
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
        XCTAssertEqual(bytes[3], 255, "sampled an opaque pixel at \(x),\(y)")
        return (red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
    }
}
