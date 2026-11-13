import Amplify
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// The R2 tour (spec D 2.5.5): three steps on Bills that end in a vote, version 2, started only by
/// setup or "Replay the tour" once the tabs are usable. Also the tab shell's copy and symbols
/// (spec D 2.4.2: the Bills tab, the history window titles).
@MainActor
final class ProductTutorialTests: XCTestCase {
    // MARK: - Steps

    func testThreeStepsOnTheFirstBillsCard() {
        let steps = ProductTutorial.steps
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.map(\.id), [0, 1, 2])
        XCTAssertEqual(steps.map(\.anchor), [.billsFirstCard, .billsFirstCard, .billsFirstCard])
        XCTAssertEqual(TutorialAnchor.billsFirstCard.ownerTab, .home, "the tour stays on Bills")
        XCTAssertEqual(steps.map(\.primaryAction), [.next, .next, .openFirstBill])
        XCTAssertEqual(steps.map(\.showsSwipeHint), [false, true, false])
    }

    func testStepCopy() {
        let steps = ProductTutorial.steps
        XCTAssertEqual(steps[0].title, "Bills in Congress")
        XCTAssertEqual(steps[0].summary, "Each card is a real bill, with a plain-English summary written with AI from the official text. Tap a card to read it.")
        XCTAssertEqual(steps[1].title, "Skip what you don't care about")
        XCTAssertEqual(steps[1].summary, "Swipe left to skip a bill. Skipping is never a vote, and you can undo it.")
        XCTAssertEqual(steps[2].title, "Cast your first vote")
        XCTAssertEqual(steps[2].summary, "Open a bill and choose Yea (for), Nay (against) or Abstain. Results appear after you vote.")
        XCTAssertEqual(ProductTutorial.headerTitle, "Tour")
        XCTAssertEqual(ProductTutorial.skipTitle, "Skip tour")
    }

    func testButtonsPerStep() {
        let steps = ProductTutorial.steps
        let first = ProductTutorial.presentation(for: steps[0], index: 0, hasFirstCard: true)
        XCTAssertEqual(first.primaryTitle, "Next")
        XCTAssertNil(first.backTitle)
        XCTAssertEqual(first.progressLabel, "Step 1 of 3")
        XCTAssertEqual(first.progressFigure, "1 of 3")

        let second = ProductTutorial.presentation(for: steps[1], index: 1, hasFirstCard: true)
        XCTAssertEqual(second.primaryTitle, "Next")
        XCTAssertEqual(second.backTitle, "Back")

        let third = ProductTutorial.presentation(for: steps[2], index: 2, hasFirstCard: true)
        XCTAssertEqual(third.primaryTitle, "Open this bill")
        XCTAssertEqual(third.backTitle, "Back")
        XCTAssertEqual(third.title, "Cast your first vote")
    }

    func testEmptyListEndsWithGotIt() {
        let third = ProductTutorial.presentation(for: ProductTutorial.steps[2], index: 2, hasFirstCard: false)
        XCTAssertEqual(third.title, "Open any bill to vote")
        XCTAssertEqual(third.primaryTitle, "Got it")
        XCTAssertTrue(third.summary.contains("Yea (for), Nay (against) or Abstain"))
        // The other steps do not change with an empty list.
        XCTAssertEqual(ProductTutorial.presentation(for: ProductTutorial.steps[0], index: 0, hasFirstCard: false).title, "Bills in Congress")
    }

    func testCopyUsesTheGlossary() {
        let banned = ["Home", "queue", "Alert", "Dismiss", "Subscri", "Quick Tour", "BillBoard", "Abstain on"]
        for (index, step) in ProductTutorial.steps.enumerated() {
            for hasCard in [true, false] {
                let shown = ProductTutorial.presentation(for: step, index: index, hasFirstCard: hasCard)
                for text in [shown.title, shown.summary, shown.primaryTitle] {
                    for word in banned {
                        XCTAssertFalse(text.contains(word), "\(word) in \(text)")
                    }
                }
            }
        }
    }

    func testSpotlightIsTheAnchorWhenItIsOnScreen() {
        let step = ProductTutorial.steps[0]
        let frame = CGRect(x: 20, y: 200, width: 350, height: 180)
        XCTAssertEqual(ProductTutorial.highlightRects(for: step, anchorFrames: [.billsFirstCard: frame]), [frame])
        XCTAssertEqual(ProductTutorial.highlightRects(for: step, anchorFrames: [:]), [], "no card: no spotlight")
        XCTAssertEqual(ProductTutorial.highlightRects(for: step, anchorFrames: [.billsFirstCard: .zero]), [])
        XCTAssertEqual(ProductTutorial.highlightRects(for: step, anchorFrames: [.voteBar: frame]), [])
        XCTAssertEqual(ProductTutorial.highlightRects(for: step, anchorFrames: [.tabBar: frame]), [], "the capsule is never spotlit")
        for step in ProductTutorial.steps {
            XCTAssertEqual(
                ProductTutorial.highlightRects(for: step, anchorFrames: [.billsFirstCard: frame, .tabBar: CGRect(x: 16, y: 786, width: 370, height: 64)]),
                [frame],
                "step \(step.id) spotlights the card alone"
            )
        }
    }

    /// Civic Record spec 4.9: the card ends 10 pt above the tab capsule's measured top, or 98 pt above the
    /// bottom edge (64 + 24 + 10) before the capsule is measured.
    func testTheCardEndsAboveTheMeasuredTabCapsule() {
        // iPhone 17 Pro: the capsule 24 pt above the 874 pt screen's bottom edge.
        XCTAssertEqual(ProductTutorialOverlay.bottomInset(tabBarFrame: CGRect(x: 16, y: 786, width: 370, height: 64), screenHeight: 874), 98)
        // iPhone SE: 12 pt above the 667 pt screen's bottom edge.
        XCTAssertEqual(ProductTutorialOverlay.bottomInset(tabBarFrame: CGRect(x: 16, y: 591, width: 343, height: 64), screenHeight: 667), 86)
        // Not measured yet, or off screen.
        XCTAssertEqual(ProductTutorialOverlay.bottomInset(tabBarFrame: nil, screenHeight: 874), 98)
        XCTAssertEqual(ProductTutorialOverlay.bottomInset(tabBarFrame: .zero, screenHeight: 874), 98)
        XCTAssertEqual(ProductTutorialOverlay.bottomInset(tabBarFrame: CGRect(x: 16, y: 900, width: 370, height: 64), screenHeight: 874), 98)
        // The frame is in window coordinates: a window 50 pt down the screen moves it by as much.
        XCTAssertEqual(ProductTutorialOverlay.bottomInset(tabBarFrame: CGRect(x: 16, y: 836, width: 370, height: 64), overlayTop: 50, screenHeight: 874), 98)
        XCTAssertEqual(TabCapsuleLayout.fallbackTourBottomInset, 98)
    }

    // MARK: - Spotlight and swipe hint (Civic Record spec 4.17)

    @MainActor
    private final class AnchorFrames {
        var frames: [TutorialAnchor: CGRect] = [:]
    }

    private func slipBill(_ guid: String, number: String, title: String) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: "Economic Policy",
            subCategory: "Energy",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 60 * 60)),
            billStatus: .new,
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: number,
            userVoted: false,
            isPriority: true
        )
    }

    /// The first slip on Bills is the tour's anchor: its frame is the slip's own, 16 pt in from the
    /// screen's edges, so the spotlight frames the slip and nothing else.
    func testTheTourAnchorIsTheFirstSlip() throws {
        let bills = [
            slipBill("BILLS-119hr1234", number: "1234", title: "Clean Energy Reporting Act"),
            slipBill("BILLS-119hr77", number: "77", title: "Rural Broadband Access Act of 2026, a long title that wraps")
        ]
        let items = bills.map { BillBoardItem(id: $0.id, bill: $0, date: Date(), type: .bill) }
        let store = UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService())
        let box = AnchorFrames()
        let list = BillBoardQueueList(
            items: items,
            isSyncing: false,
            isShowingStaleQueue: false,
            canExpandHistoryWindow: false,
            isExpandingHistoryWindow: false,
            visibleCardIDs: .constant(Set(items.map(\.id))),
            hasAnimatedBoardCards: .constant(true),
            onOpen: { _ in },
            onSwipeLeft: { _ in },
            onExpandHistory: {},
            onJumpToTop: {}
        )
        let screen = VStack(spacing: 0) {
            list.padding(.horizontal, BillboardStyle.Space.l)
            Spacer(minLength: 0)
        }
        .environmentObject(store)
        .coordinateSpace(name: ProductTutorialStorage.coordinateSpaceName)
        .environment(\.tutorialFrameCaptureEnabled, true)
        .onPreferenceChange(TutorialAnchorFramePreferenceKey.self) { frames in
            box.frames = frames
        }
        let host = AccessibilityTreeText.Host(screen, size: CGSize(width: 390, height: 1200), settle: 0.5)
        defer { host.close() }

        let frame = try XCTUnwrap(box.frames[.billsFirstCard], "the first slip is measured while the tour can run")
        XCTAssertEqual(frame.minX, 16, accuracy: 0.5, "16 pt list gutter")
        XCTAssertEqual(frame.width, 390 - 32, accuracy: 0.5)
        let renderer = ImageRenderer(content: BillCard(bill: bills[0]).frame(width: 358).environmentObject(store))
        renderer.proposedSize = ProposedViewSize(width: 358, height: nil)
        let slipHeight = try XCTUnwrap(renderer.cgImage).height
        XCTAssertEqual(frame.height, CGFloat(slipHeight) / renderer.scale, accuracy: 1, "as tall as the first slip")
        for step in ProductTutorial.steps {
            XCTAssertEqual(ProductTutorial.highlightRects(for: step, anchorFrames: box.frames), [frame], "step \(step.id)")
        }
    }

    /// The spotlight (spec 4.17) around the first slip where the list really puts it, on the 16 pt gutter
    /// (`testTheTourAnchorIsTheFirstSlip`): the same padding on every side, so its corners are concentric
    /// with the slip's (16 + the padding), and a 2 pt white outline with no glow; the swipe hint nudges
    /// 12 pt every 1.2 s. Drawn at 2x over paper: on the outline the pixel is white, in the spotlight's
    /// rounded corner it is still the scrim, inside the cut-out it is the paper, and just outside the
    /// outline it is plain scrim.
    func testTheSpotlightIsConcentricWithTheSlipAndOutlinedInWhite() throws {
        let padding = ProductTutorialOverlay.spotlightPadding
        XCTAssertEqual(ProductTutorialOverlay.spotlightCornerRadius, BillboardStyle.Radius.slip + padding)
        XCTAssertEqual(ProductTutorialOverlay.spotlightOutlineWidth, 2)
        XCTAssertEqual(TutorialSwipeHint.nudge, 12)
        XCTAssertEqual(TutorialSwipeHint.period, 1.2)

        // The first slip on a 390 pt screen, 16 pt in, where the tour's scroll leaves it under the bar
        // (the tour card then sits low, clear of the spotlight).
        let slip = CGRect(x: 16, y: 128, width: 390 - 32, height: 180)
        let spotlight = slip.insetBy(dx: -padding, dy: -padding)
        for scheme in [ColorScheme.light, .dark] {
            let image = try renderOverlay(step: 1, slip: slip, scheme: scheme, size: CGSize(width: 390, height: 844), scale: 2)
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "tour-spotlight-\(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)

            let dark = scheme == .dark
            let paper = BillboardPalette.background.resolved(dark: dark).rgb
            let scrim = BillboardColorMath.composite((red: 0, green: 0, blue: 0), alpha: 0.62, over: paper)
            let white: BillboardColorMath.RGB = (red: 1, green: 1, blue: 1)
            func assertPixel(_ x: CGFloat, _ y: CGFloat, _ expected: BillboardColorMath.RGB, _ what: String) throws {
                let sample = try SlipPixels.pixel(of: image, x: Int(x * 2), y: Int(y * 2))
                XCTAssertEqual(sample.red, expected.red, accuracy: 0.03, "\(what), \(scheme)")
                XCTAssertEqual(sample.green, expected.green, accuracy: 0.03, "\(what), \(scheme)")
                XCTAssertEqual(sample.blue, expected.blue, accuracy: 0.03, "\(what), \(scheme)")
            }
            // The outline runs `padding` outside the slip on all four sides.
            try assertPixel(spotlight.minX, slip.midY, white, "the 2 pt white outline \(padding) pt left of the slip")
            try assertPixel(spotlight.maxX, slip.midY, white, "the outline \(padding) pt right of the slip")
            try assertPixel(slip.minX + 40, spotlight.minY, white, "the outline \(padding) pt above the slip")
            try assertPixel(slip.minX + 40, spotlight.maxY, white, "the outline \(padding) pt below the slip")
            try assertPixel(slip.minX + 24, slip.midY, paper, "the slip shows through the cut-out")
            try assertPixel(spotlight.minX + 3, spotlight.minY + 3, scrim, "3 pt in from the corner is still scrim: the corner is rounded")
            try assertPixel(4, spotlight.maxY + 24, scrim, "the scrim below the spotlight")
            // No glow: 3 pt outside the outline is plain scrim.
            try assertPixel(spotlight.minX - 3, slip.midY, scrim, "no glow outside the outline")
        }
    }

    /// The spotlight's geometry around the first slip as the list lays it out (16 pt in, the screen's width
    /// less 32), on a 402 and a 375 pt screen: the same padding on every side, nothing clamped, so a
    /// radius of 16 + the padding is concentric with the slip all the way round.
    func testTheSpotlightPadsTheRealFirstSlipEvenly() {
        let padding = ProductTutorialOverlay.spotlightPadding
        XCTAssertEqual(padding, 8)
        XCTAssertEqual(ProductTutorialOverlay.spotlightCornerRadius, 24)
        for width in [CGFloat(402), 375] {
            let safeArea = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
            let size = CGSize(width: width, height: 874 - 62 - 34)
            let slip = CGRect(x: 16, y: 128, width: width - 32, height: 162)
            let spotlight = ProductTutorialOverlay.spotlightRect(around: slip, size: size, safeAreaInsets: safeArea)
            XCTAssertEqual(slip.minX - spotlight.minX, padding, "\(width) pt: left")
            XCTAssertEqual(spotlight.maxX - slip.maxX, padding, "\(width) pt: right")
            XCTAssertEqual(slip.minY - spotlight.minY, padding, "\(width) pt: top")
            XCTAssertEqual(spotlight.maxY - slip.maxY, padding, "\(width) pt: bottom")
            XCTAssertGreaterThanOrEqual(spotlight.minX, ProductTutorialOverlay.spotlightScreenMargin, "\(width) pt: clear of the edge")
        }
    }

    /// The swipe hint (spec 4.17) sits under the spotlighted slip, so the slip the step points at stays
    /// readable: its docket line and title (the top half) show through the cut-out untouched, and the
    /// hint's opaque sheet is drawn lower down. At the default size the hint has room under the spotlight;
    /// at AX3 the slip is 412 pt tall and the tour card leaves none, so it rides over the slip's foot.
    func testTheSwipeHintLeavesTheSlipsTitleReadable() throws {
        let screen = CGSize(width: 402, height: 874)
        // The slip where the tour's scroll leaves it, under a 116 pt bar; the last value is where to stop
        // looking for the hint, above the tour card.
        let cases: [(DynamicTypeSize, CGFloat, CGFloat)] = [(.large, 162, 430), (.accessibility3, 412, 560)]
        for (size, height, searchEnd) in cases {
            let slip = CGRect(x: 16, y: 128, width: screen.width - 32, height: height)
            for scheme in [ColorScheme.light, .dark] {
                let name = "\(size == .large ? "default" : "AX3") \(scheme)"
                let image = try renderOverlay(step: 1, slip: slip, scheme: scheme, size: screen, scale: 2, dynamicTypeSize: size)
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "tour-swipe-hint-\(size == .large ? "default" : "AX3")-\(scheme == .dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)

                let dark = scheme == .dark
                let paper = BillboardPalette.background.resolved(dark: dark).rgb
                let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
                func matches(_ sample: BillboardColorMath.RGB, _ expected: BillboardColorMath.RGB) -> Bool {
                    abs(sample.red - expected.red) + abs(sample.green - expected.green) + abs(sample.blue - expected.blue) < 0.03
                }
                // The slip's top half is the paper under the cut-out, every few points across.
                var covered: [String] = []
                for y in stride(from: slip.minY + 4, to: slip.midY, by: 4) {
                    for x in stride(from: slip.minX + 2, to: slip.maxX - 2, by: 3) {
                        let sample = try SlipPixels.pixel(of: image, x: Int(x * 2), y: Int(y * 2))
                        if !matches(sample, paper) { covered.append("(\(Int(x)), \(Int(y)))") }
                    }
                }
                XCTAssertTrue(covered.isEmpty, "\(name): the hint covers the slip's title at \(covered.prefix(5))")

                // The hint is drawn below the middle: a run of 20 pt of its sheet on some row.
                var found = false
                for y in stride(from: slip.midY, to: searchEnd, by: 2) where !found {
                    var run = 0
                    for x in stride(from: 0, to: screen.width, by: 1) {
                        let sample = try SlipPixels.pixel(of: image, x: Int(x * 2), y: Int(y * 2))
                        run = matches(sample, sheet) ? run + 1 : 0
                        if run >= 20 { found = true; break }
                    }
                }
                XCTAssertTrue(found, "\(name): the hint's sheet under the title")
            }
        }
    }

    /// Where the swipe hint goes (`TutorialSwipeHintLayout`): 12 pt under the spotlight when it fits above
    /// the card; else 12 pt above the card, over the slip's foot; never above the spotlight's top.
    func testTheSwipeHintSitsUnderTheSpotlightOrJustAboveTheCard() {
        let spotlight = CGRect(x: 8, y: 120, width: 386, height: 178)
        XCTAssertEqual(TutorialSwipeHintLayout.gap, 12)
        XCTAssertEqual(TutorialSwipeHintLayout.hintTop(spotlight: spotlight, hintHeight: 44, floor: 439), 310, "room under the spotlight")
        XCTAssertEqual(TutorialSwipeHintLayout.hintTop(spotlight: spotlight, hintHeight: 44, floor: 360), 304, "the card is close: just above it")
        let tall = CGRect(x: 8, y: 120, width: 386, height: 428)
        XCTAssertEqual(TutorialSwipeHintLayout.hintTop(spotlight: tall, hintHeight: 55, floor: 566), 499, "AX3: over the slip's foot")
        XCTAssertEqual(TutorialSwipeHintLayout.hintTop(spotlight: tall, hintHeight: 55, floor: 100), 120, "never above the spotlight")
    }

    /// The tour's overlay over paper, with `slip` as the spotlighted frame (screen coordinates), drawn still
    /// (Reduce Motion), as `ImageRenderer` draws it: no safe area, so the spotlight is clamped only 8 pt in
    /// from the edges.
    private func renderOverlay(
        step: Int,
        slip: CGRect,
        scheme: ColorScheme,
        size: CGSize,
        scale: CGFloat,
        dynamicTypeSize: DynamicTypeSize = .large
    ) throws -> CGImage {
        let overlay = ProductTutorialOverlay(
            step: ProductTutorial.steps[step],
            stepIndex: step,
            totalSteps: ProductTutorial.steps.count,
            highlightRects: [slip],
            hasFirstCard: true,
            onBack: {},
            onPrimary: {},
            onSkip: {}
        )
        .frame(width: size.width, height: size.height)
        .background(BillboardColors.background)
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\._accessibilityReduceMotion, true)
        let renderer = ImageRenderer(content: overlay)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        return try XCTUnwrap(renderer.cgImage)
    }

    /// Scrolling to the tour's anchor (`BillBoardTab.scrollToTutorialAnchorIfNeeded`) shows the whole
    /// spotlight: the anchor sits the spotlight's padding above the first slip, outside the list's spaced
    /// stack, so the slip ends up that far under the top of the scroll view and the spotlight's top edge at it.
    func testScrollingToTheTourAnchorShowsTheWholeSpotlight() throws {
        let bills = [
            slipBill("BILLS-119hr1234", number: "1234", title: "Clean Energy Reporting Act"),
            slipBill("BILLS-119hr77", number: "77", title: "Rural Broadband Access Act of 2026, a long title that wraps")
        ]
        let items = bills.map { BillBoardItem(id: $0.id, bill: $0, date: Date(), type: .bill) }
        let store = UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService())
        let box = AnchorFrames()
        let list = BillBoardQueueList(
            items: items,
            isSyncing: false,
            isShowingStaleQueue: false,
            canExpandHistoryWindow: false,
            isExpandingHistoryWindow: false,
            visibleCardIDs: .constant(Set(items.map(\.id))),
            hasAnimatedBoardCards: .constant(true),
            onOpen: { _ in },
            onSwipeLeft: { _ in },
            onExpandHistory: {},
            onJumpToTop: {}
        )
        let screen = ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 600)
                        list.padding(.horizontal, BillboardStyle.Space.l)
                        Color.clear.frame(height: 1600)
                    }
                }
                .onAppear {
                    // As the tab does: on the next turn, once the list is laid out.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        proxy.scrollTo(TutorialAnchor.billsFirstCard.scrollID, anchor: .top)
                    }
                }
            }
        }
        .environmentObject(store)
        .coordinateSpace(name: ProductTutorialStorage.coordinateSpaceName)
        .environment(\.tutorialFrameCaptureEnabled, true)
        .onPreferenceChange(TutorialAnchorFramePreferenceKey.self) { frames in
            box.frames = frames
        }
        let host = AccessibilityTreeText.Host(
            screen,
            size: CGSize(width: 390, height: 844),
            settle: 0.8,
            scene: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        defer { host.close() }

        let frame = try XCTUnwrap(box.frames[.billsFirstCard], "the first slip is measured")
        XCTAssertEqual(frame.minY, ProductTutorialOverlay.spotlightPadding, accuracy: 0.5, "scrolled to the anchor: the spotlight starts at the top")
    }

    // MARK: - Accessibility sizes (integration review)

    /// A slip partly below the screen, or taller than it, is framed where it shows: the spotlight is cut to the
    /// safe area, not moved up onto the starter banner and list line above the slip (AX3 before the list had
    /// scrolled). No part on screen, no spotlight.
    func testTheSpotlightFramesOnlyThePartOfTheSlipOnScreen() {
        let safeArea = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        let size = CGSize(width: 402, height: 874 - 62 - 34)
        let below = CGRect(x: 16, y: 663, width: 370, height: 412)
        let spotlight = ProductTutorialOverlay.spotlightRect(around: below, size: size, safeAreaInsets: safeArea)
        XCTAssertEqual(spotlight.minY, below.minY - ProductTutorialOverlay.spotlightPadding, "not moved up")
        XCTAssertEqual(spotlight.maxY, 874 - 34 - ProductTutorialOverlay.spotlightScreenMargin, "cut at the safe area")
        XCTAssertEqual(spotlight.minX, below.minX - ProductTutorialOverlay.spotlightPadding)
        XCTAssertTrue(ProductTutorialOverlay.spotlightRect(around: CGRect(x: 16, y: 900, width: 370, height: 412), size: size, safeAreaInsets: safeArea).isNull)
        XCTAssertTrue(ProductTutorialOverlay.spotlightRect(around: CGRect(x: 16, y: 820, width: 370, height: 412), size: size, safeAreaInsets: safeArea).isNull, "less than a docket line shows")
    }

    /// The card is never shorter than its footer plus its text down to the step's title, so "Tour", Skip tour
    /// and the title stay in view at AX3 and AX5 and only the step's text scrolls. With a slip taller than the
    /// room (AX5), the card goes below and the spotlight keeps the slip's top, 18 pt above the card. At the
    /// default size nothing changes: the card is as tall as its content, under the spotlight.
    func testTheCardKeepsItsTitleAndTheSpotlightGivesWay() {
        // AX5 on a 402 x 874 phone: the slip scrolled under the bar, taller than the screen.
        let tall = ProductTutorialOverlay.layout(
            spotlights: [CGRect(x: 8, y: 120, width: 386, height: 712)],
            screenHeight: 874, visibleHeight: 778, topInset: 74, bottomInset: 98,
            textHeight: 800, footerHeight: 250, titleBottom: 190
        )
        XCTAssertFalse(tall.placeCardAtTop)
        XCTAssertEqual(tall.cardHeight, 440, "the footer and the text down to the title")
        XCTAssertEqual(tall.cardTop, 874 - 98 - 440)
        XCTAssertEqual(tall.spotlights, [CGRect(x: 8, y: 120, width: 386, height: tall.cardTop - 18 - 120)], "the slip's top, clear of the card")

        // The default size: a 162 pt slip under the bar; the card fits under it at its content's height.
        let slip = CGRect(x: 8, y: 120, width: 386, height: 178)
        let usual = ProductTutorialOverlay.layout(
            spotlights: [slip], screenHeight: 874, visibleHeight: 778, topInset: 74, bottomInset: 98,
            textHeight: 150, footerHeight: 120, titleBottom: 80
        )
        XCTAssertFalse(usual.placeCardAtTop)
        XCTAssertEqual(usual.cardHeight, 270)
        XCTAssertEqual(usual.spotlights, [slip], "unchanged")

        // A card that holds less than its floor beside the spotlight still gets it, and never more than the room.
        let short = ProductTutorialOverlay.layout(
            spotlights: [CGRect(x: 8, y: 44, width: 359, height: 500)], screenHeight: 667, visibleHeight: 647, topInset: 32, bottomInset: 86,
            textHeight: 900, footerHeight: 400, titleBottom: 300
        )
        XCTAssertEqual(short.cardHeight, 667 - 86 - 32, "the room between the insets")
        XCTAssertEqual(short.spotlights, [], "no room left to frame a docket line")
    }

    /// The tour card at AX3 and AX5 in a real window on the test host's screen, over a first slip as tall as it
    /// is at those sizes (412 and 597 pt), scrolled under the bar: on every step "Skip tour", the step's title,
    /// the progress and the primary button are inside the card, in that order, without overlapping. Before,
    /// the card was squeezed to 190 pt: at AX3 it showed only the title, and at AX5 the title and text were
    /// laid out under the footer and Skip tour was cut off at the card's top.
    func testTheTourCardKeepsSkipAndTheTitleInViewAtAccessibilitySizes() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let screen = scene.screen.bounds.size
        for (size, slipHeight) in [(DynamicTypeSize.accessibility3, CGFloat(412)), (.accessibility5, 597)] {
            for index in ProductTutorial.steps.indices {
                let step = ProductTutorial.steps[index]
                let presentation = ProductTutorial.presentation(for: step, index: index, totalSteps: ProductTutorial.steps.count, hasFirstCard: true)
                let host = AccessibilityTreeText.Host(
                    ProductTutorialOverlay(
                        step: step,
                        stepIndex: index,
                        totalSteps: ProductTutorial.steps.count,
                        highlightRects: [CGRect(x: 16, y: 128, width: screen.width - 32, height: slipHeight)],
                        hasFirstCard: true,
                        tabBarFrame: CGRect(x: 16, y: screen.height - 88, width: screen.width - 32, height: 64),
                        onBack: {},
                        onPrimary: {},
                        onSkip: {}
                    )
                    .environment(\.dynamicTypeSize, size),
                    size: screen,
                    settle: 0.8,
                    scene: scene
                )
                defer { host.close() }
                let name = "\(size) step \(index + 1)"
                let card = try XCTUnwrap(host.frame(ofIdentifier: "tour.card"), name)
                let skip = try XCTUnwrap(host.frame(ofIdentifier: "tour.skip"), name)
                let title = try XCTUnwrap(host.frame(of: presentation.title), "\(name): \(host.text())")
                let progress = try XCTUnwrap(host.frame(of: presentation.progressLabel), name)
                let primary = try XCTUnwrap(host.frame(ofIdentifier: "tour.primary"), name)
                let inCard = card.insetBy(dx: -0.5, dy: -0.5)
                for (part, frame) in [("Skip tour", skip), ("the title", title), ("the progress", progress), ("the primary button", primary)] {
                    XCTAssertTrue(inCard.contains(frame), "\(name): \(part) \(frame) inside the card \(card)")
                }
                XCTAssertLessThanOrEqual(skip.maxY, title.minY + 0.5, "\(name): Skip tour above the title")
                XCTAssertLessThanOrEqual(title.maxY, progress.minY + 0.5, "\(name): the title \(title) above the footer \(progress)")
                XCTAssertLessThanOrEqual(progress.maxY, primary.minY + 0.5, "\(name): the progress above the buttons")
                XCTAssertGreaterThanOrEqual(card.minY, scene.windows.first.map { $0.safeAreaInsets.top } ?? 0, "\(name): the card under the status bar")
                XCTAssertLessThanOrEqual(card.maxY, screen.height - 88 - 9.5, "\(name): the card above the capsule")

                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: host.window.bounds, format: format).image { _ in
                    host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "tour-card-\(size)-step-\(index + 1)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// The tour often begins before the Bills queue shows (it is still being derived or synced). The scroll
    /// to the first slip then found no anchor and the request was dropped, so at AX3 the slip stayed below
    /// the screen and the spotlight framed the starter banner and the list line above it. The request now
    /// waits for the queue: asked for while no slip shows (both bills skipped, the list caught up), it is
    /// kept, and once the slips come back the first one is scrolled to the top of the real Bills tab.
    func testTheTourScrollsToTheFirstSlipOnceTheQueueShows() throws {
        let scope = "tour-scroll-\(UUID().uuidString.prefix(8))"
        let bills = [
            slipBill("BILLS-119hr1234", number: "1234", title: "Clean Energy Reporting Act"),
            slipBill("BILLS-119hr77", number: "77", title: "Rural Broadband Access Act of 2026")
        ]
        let service = FakeBillsService()
        service.manifestResults = [.success(bills.map { bill in
            BillsManifestItem(
                guid: bill.guid!, congress: "119", billType: bill.billType, billID: bill.billID,
                updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600)),
                subCategories: ["Energy"], lifeAreas: [], sponsors: [], cosponsors: [],
                isPriority: bill.isPriority, title: bill.title, billStatus: bill.billStatus.rawValue
            )
        })]
        let stub = APIClient(transport: { request in
            guard await request.path == "me" else { throw URLError(.notConnectedToInternet) }
            return Data(#"{"adultStatus":"attested_adult","deletionStatus":"not_requested","canWrite":true}"#.utf8)
        })
        let billsStore = BillsStore(bills: bills, cacheScope: scope, service: service, preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        var loaded = false
        Task { @MainActor in
            await APIClient.$current.withValue(stub) {
                await userStore.refresh(userId: "tour-\(scope)", attributes: [
                    AuthUserAttribute(.custom("state"), value: "VA"),
                    AuthUserAttribute(.custom("district"), value: "11")
                ])
                await billsStore.load(forceRefresh: true, mode: .manifestOnly, historyWindow: .oneWeek)
            }
            loaded = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !loaded, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(loaded, "the stores loaded")

        let readState = AppReadState(scope: .user(scope), store: InMemoryReadStateStore())
        _ = readState.dismissAllBills(bills.map(\.id))
        let appState = AppState()
        appState.hasCompletedHomeQueueReconciliation = true
        appState.isReconcilingHomeQueue = false
        let box = AnchorFrames()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        try APIClient.$current.withValue(stub) {
            let host = AccessibilityTreeText.Host(
                NavigationStack { BillBoardTab() }
                    .environmentObject(readState)
                    .environmentObject(billsStore)
                    .environmentObject(appState)
                    .environmentObject(userStore)
                    .environmentObject(voteStore)
                    .environmentObject(BillAlertsStore(alerts: []))
                    .coordinateSpace(name: ProductTutorialStorage.coordinateSpaceName)
                    .environment(\.tutorialFrameCaptureEnabled, true)
                    .onPreferenceChange(TutorialAnchorFramePreferenceKey.self) { frames in box.frames = frames }
                    .environment(\.dynamicTypeSize, .accessibility3),
                size: scene.screen.bounds.size,
                settle: 1.5,
                scene: scene
            )
            defer { host.close() }
            XCTAssertNil(box.frames[.billsFirstCard], "no slip while both bills are skipped: \(host.text())")

            appState.pendingTutorialAnchor = .billsFirstCard
            host.run(1.0)
            XCTAssertEqual(appState.pendingTutorialAnchor, .billsFirstCard, "the request waits for the queue")

            readState.undismissBills(bills.map(\.id))
            host.run(2.0)
            // The queue refreshes before the slip shows ("Refreshing content" after 2 s on Xcode Cloud's virtual Mac).
            host.run(until: { appState.pendingTutorialAnchor == nil && box.frames[.billsFirstCard] != nil }, timeout: 15)
            XCTAssertNil(appState.pendingTutorialAnchor, "scrolled once the queue showed")
            host.run(until: { (box.frames[.billsFirstCard]?.minY ?? .infinity) < 200 })
            let slip = try XCTUnwrap(box.frames[.billsFirstCard], "the first slip is measured: \(host.text())")
            XCTAssertLessThan(slip.minY, 200, "the first slip at the top, under the bar: \(slip)")
        }
    }

    /// The tour draws one symbol: the swipe hint's `arrow.left`. The step symbols went with the card's
    /// redraw (spec 4.17) and the hint's `hand.point.left.fill` with its glass capsule (spec 3.19).
    func testTheSwipeHintsSymbolExists() {
        for symbol in ["arrow.left"] {
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
        }
    }

    // MARK: - When the tour runs

    func testVersionIsTwoAndCompletingStoresIt() {
        XCTAssertEqual(ProductTutorialStorage.currentVersion, 2)
        XCTAssertEqual(ProductTutorialPolicy.completedVersion(previous: 0), 2)
        XCTAssertEqual(ProductTutorialPolicy.completedVersion(previous: 1), 2, "an R1 account that finished v1")
        XCTAssertEqual(ProductTutorialPolicy.completedVersion(previous: 3), 3, "never goes back")
    }

    func testStartsOnlyWhenAskedAndTheTabsAreUsable() {
        XCTAssertTrue(ProductTutorialPolicy.shouldBegin(isShowing: false, pendingAutoShow: true, replayRequested: false, canPresent: true))
        XCTAssertTrue(ProductTutorialPolicy.shouldBegin(isShowing: false, pendingAutoShow: false, replayRequested: true, canPresent: true))
        XCTAssertFalse(
            ProductTutorialPolicy.shouldBegin(isShowing: false, pendingAutoShow: true, replayRequested: false, canPresent: false),
            "waits under setup, a gate or the loading screen"
        )
        XCTAssertFalse(
            ProductTutorialPolicy.shouldBegin(isShowing: false, pendingAutoShow: false, replayRequested: false, canPresent: true),
            "an existing account (even one that finished v1) is not shown v2 automatically"
        )
        XCTAssertFalse(ProductTutorialPolicy.shouldBegin(isShowing: true, pendingAutoShow: true, replayRequested: true, canPresent: true))
    }

    func testStorageKeysAreUnchanged() {
        XCTAssertEqual(ProductTutorialStorage.pendingAutoShowKey, "BillBoard.tutorial.pendingAutoShow.v1")
        XCTAssertEqual(ProductTutorialStorage.replayRequestedKey, "BillBoard.tutorial.replayRequested.v1")
        XCTAssertEqual(ProductTutorialStorage.completedVersionKey, "BillBoard.tutorial.completedVersion")
    }

    // MARK: - Tab shell copy

    func testBillsTabTitleAndSymbols() {
        XCTAssertEqual(TabsBar.Tab.home.title, "Bills")
        XCTAssertEqual([TabsBar.Tab.home, .updates, .congress, .profile].map(\.title), ["Bills", "Updates", "Congress", "Profile"])
        for tab in [TabsBar.Tab.home, .updates, .congress, .profile] {
            XCTAssertNotNil(UIImage(systemName: tab.systemImage), tab.systemImage)
            XCTAssertNotNil(UIImage(systemName: tab.selectedSystemImage), tab.selectedSystemImage)
        }
        // Civic Record spec 2.10: Bills is doc.text, and every selected tab shows the filled form.
        XCTAssertEqual(TabsBar.Tab.allCases.map(\.systemImage), ["doc.text", "bell", "building.columns", "person"])
        XCTAssertEqual(TabsBar.Tab.allCases.map(\.selectedSystemImage), ["doc.text.fill", "bell.fill", "building.columns.fill", "person.fill"])
        XCTAssertEqual(TabsBar.Tab.allCases.map(\.accessibilityIdentifier), ["tab.billboard", "tab.updates", "tab.congress", "tab.profile"])
    }

    func testTabBadgeValues() {
        XCTAssertEqual(TabBadgeAccessibility.billsValue(count: 0), "")
        XCTAssertEqual(TabBadgeAccessibility.billsValue(count: 1), "1 bill to vote on")
        XCTAssertEqual(TabBadgeAccessibility.billsValue(count: 15), "15 bills to vote on")
        XCTAssertEqual(TabBadgeAccessibility.updatesValue(count: 0), "")
        XCTAssertEqual(TabBadgeAccessibility.updatesValue(count: 1), "1 update")
        XCTAssertEqual(TabBadgeAccessibility.updatesValue(count: 4), "4 updates")
    }

    func testHistoryWindowCopy() {
        XCTAssertEqual(BillboardHistoryWindow.oneWeek.title, "1 week")
        XCTAssertEqual(BillboardHistoryWindow.fourWeeks.title, "4 weeks")
        XCTAssertEqual(BillboardHistoryWindow(rawValue: 10).title, "10 days")
        XCTAssertEqual(BillboardHistoryWindow.oneWeek.subtitle, "Recommended")
        for window in [BillboardHistoryWindow.twoWeeks, .threeWeeks, .fourWeeks, .maxExpanded] {
            XCTAssertNil(window.subtitle, window.title)
        }
    }

    func testActionInCongressFallbackTitle() {
        XCTAssertEqual(PushDeepLinkRouter.actionInCongressTitle, "Action in Congress")
    }
}
