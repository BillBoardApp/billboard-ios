import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Draws the first-run screens through UIKit (a `UIHostingController` in a window, then
/// `drawHierarchy`), in light and dark, and attaches each image for review (spec D 5.3).
///
/// `FirstRunRenderTests` uses `ImageRenderer`, which draws scroll views, text fields and toggles as
/// blanks or placeholders, so most of these screens came out empty there. Drawn through UIKit they
/// show what a device shows. Text sizes follow the simulator's setting (the window's content size
/// category), so these images are at the default size; the largest size is the
/// signed-out simulator pass and a TestFlight pass. No network: the auth manager is signed
/// out and the services are fakes.
@MainActor
final class FirstRunSnapshotTests: XCTestCase {
    private static let size = CGSize(width: 390, height: 844)
    private static let styles: [(name: String, style: UIUserInterfaceStyle)] = [("light", .light), ("dark", .dark)]

    private func signedOutAuth() -> AuthManager {
        let auth = AuthManager()
        auth.cancelSignIn()
        return auth
    }

    private func store() -> UserStore {
        UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
    }

    // MARK: - Signed out

    func testSignedOutScreens() throws {
        let auth = signedOutAuth()
        let userStore = store()
        let screens: [(String, AnyView)] = [
            ("login", AnyView(NavigationStack { LoginView() }.environmentObject(auth).environmentObject(userStore))),
            ("create-account", AnyView(NavigationStack { CreateAccountView() }.environmentObject(auth).environmentObject(userStore))),
            ("forgot-password", AnyView(NavigationStack { ForgotPasswordView() }.environmentObject(auth).environmentObject(userStore))),
            ("new-password", AnyView(NavigationStack { NewPasswordRequiredView() }.environmentObject(auth).environmentObject(userStore)))
        ]
        try snapshotAll(screens)
    }

    /// The screens before the tabs (Civic Record spec 4.10 to 4.16): under the navy bar they are ink on paper.
    /// Brand teal appears only in the wordmark on the bar (links and buttons are ink, spec 1.2), and the fields
    /// are boxes edged in `controlRule`, so a field's edge is visible.
    func testScreensBeforeTheTabsAreInkOnPaperUnderTheBar() throws {
        let auth = signedOutAuth()
        let userStore = store()
        let screens: [(String, AnyView, Bool)] = [
            ("sign-in", AnyView(NavigationStack { LoginView() }.environmentObject(auth).environmentObject(userStore)), true),
            ("create-account", AnyView(NavigationStack { CreateAccountView() }.environmentObject(auth).environmentObject(userStore)), true),
            ("forgot-password", AnyView(NavigationStack { ForgotPasswordView() }.environmentObject(auth).environmentObject(userStore)), true),
            ("new-password", AnyView(NavigationStack { NewPasswordRequiredView() }.environmentObject(auth).environmentObject(userStore)), true),
            ("age-gate", AnyView(NavigationStack { AdultAttestationGateView() }.environmentObject(auth).environmentObject(userStore)), false),
            ("ineligible", AnyView(NavigationStack { AccountIneligibleView() }.environmentObject(auth).environmentObject(userStore)), false),
            ("location-setup", AnyView(NavigationStack {
                LocationEditorView(context: .setup, congressService: FakeCongressService(), onSignOut: {}) { _ in }
                    .preTabBar()
            }.environmentObject(userStore)), true)
        ]
        let navy = BillboardPalette.navy.light
        let teal = BillboardPalette.brandTeal.light
        for (styleName, style) in Self.styles {
            let fieldEdge = style == .dark ? BillboardPalette.controlRule.dark : BillboardPalette.controlRule.light
            for (name, view, hasFields) in screens {
                let image = try snapshot(view, style: style)
                let attachment = XCTAttachment(image: image)
                attachment.name = "pretab-\(name)-\(styleName)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let column = try SnapshotPixels.column(of: image, x: 6)
                let barBottom = try XCTUnwrap(column.firstIndex { !SnapshotPixels.matches($0, navy, tolerance: 0.02) }, "\(name) \(styleName)")
                XCTAssertFalse(
                    try SnapshotPixels.contains(image, teal, tolerance: 0.06, fromY: barBottom + 2),
                    "\(name) \(styleName): teal under the bar"
                )
                if hasFields {
                    XCTAssertTrue(
                        try SnapshotPixels.contains(image, fieldEdge, tolerance: 0.03, fromY: barBottom + 2),
                        "\(name) \(styleName): field edges in controlRule"
                    )
                }
            }
        }
    }

    // MARK: - Signed in, before the tabs

    func testAgeGateAndSetupScreens() throws {
        let auth = signedOutAuth()
        let userStore = store()
        let screens: [(String, AnyView)] = [
            ("age-gate", AnyView(NavigationStack { AdultAttestationGateView() }.environmentObject(auth).environmentObject(userStore))),
            ("account-ineligible", AnyView(NavigationStack { AccountIneligibleView() }.environmentObject(auth).environmentObject(userStore))),
            ("location-setup", AnyView(NavigationStack {
                LocationEditorView(context: .setup, congressService: FakeCongressService()) { _ in }
            }.environmentObject(userStore))),
            ("location-profile", AnyView(NavigationStack {
                LocationEditorView(context: .profile, congressService: FakeCongressService()) { _ in }
            }.environmentObject(userStore)))
        ]
        try snapshotAll(screens)
    }

    func testTopicPickers() throws {
        let userStore = store()
        let seed = Bill(
            title: "A bill",
            category: SubscriptionsConfig.categorySocialPolicy,
            subCategory: SubscriptionsConfig.subHousing,
            soWhat: "",
            lifeAreas: [SubscriptionsConfig.lifeTaxes],
            billStatus: .new,
            userVoted: true
        )
        let screens: [(String, AnyView)] = [
            ("first-vote-topics", AnyView(NavigationStack { TopicPickerView(context: .firstVote(seedBill: seed)) {} }.environmentObject(userStore))),
            ("topic-picker-profile", AnyView(NavigationStack { TopicPickerView(context: .profile) {} }.environmentObject(userStore)))
        ]
        try snapshotAll(screens)
    }

    // MARK: - Tour

    func testTourSteps() throws {
        let card = CGRect(x: 20, y: 160, width: 350, height: 170)
        var screens: [(String, AnyView)] = []
        for (index, step) in ProductTutorial.steps.enumerated() {
            let overlay = ProductTutorialOverlay(
                step: step,
                stepIndex: index,
                totalSteps: ProductTutorial.steps.count,
                highlightRects: [card],
                hasFirstCard: true,
                onBack: {},
                onPrimary: {},
                onSkip: {}
            )
            .background(BillboardColors.background)
            screens.append(("tour-step\(index + 1)", AnyView(overlay)))
        }
        try snapshotAll(screens)
    }

    // MARK: - Navigation bars (Civic Record spec 3.21)

    /// The navy bars are drawn by the screen itself (`navyNavigationBar()`): navy from the top of the
    /// window down to the bottom of the bar, then the page's paper with no band or soft edge between, in
    /// both appearances. On Bills the masthead band continues the navy with no seam. A glass screen pushed
    /// from a navy root carries no navy at all.
    func testNavyBarsCoverTheBarAndNothingElse() throws {
        let auth = signedOutAuth()
        let userStore = store()
        let civicScore = CivicScoreStore(scope: "navy-bar-tests", service: FakeCivicService())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let specDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))

        let screens: [(name: String, view: AnyView)] = [
            ("sign-in", AnyView(NavigationStack { LoginView() }.environmentObject(auth).environmentObject(userStore))),
            ("age-gate", AnyView(NavigationStack { AdultAttestationGateView() }.environmentObject(auth).environmentObject(userStore))),
            ("tab-root", AnyView(NavigationStack {
                ScrollView { PageTitle(title: "Updates").padding(.horizontal, 20) }
                    .billboardBackground()
                    .tabRootBar(wordmark: .compact) {}
            }.environmentObject(civicScore))),
            ("bills-root", AnyView(NavigationStack {
                ScrollView {
                    VStack(spacing: 0) {
                        MastheadBand(date: specDate)
                        PageTitle(title: "Bills").padding(.horizontal, 20)
                    }
                }
                .billboardBackground()
                .tabRootBar(wordmark: .masthead) {}
            }.environmentObject(civicScore)))
        ]
        let navy = BillboardPalette.navy.light
        for (styleName, style) in Self.styles {
            let paper = style == .dark ? BillboardPalette.background.dark : BillboardPalette.background.light
            var barBottom: [String: Int] = [:]
            for screen in screens {
                let image = try snapshot(screen.view, style: style)
                let attachment = XCTAttachment(image: image)
                attachment.name = "navy-bar-\(screen.name)-\(styleName)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let name = "\(screen.name) \(styleName)"
                let column = try SnapshotPixels.column(of: image, x: 6)
                let firstNotNavy = try XCTUnwrap(column.firstIndex { !SnapshotPixels.matches($0, navy, tolerance: 0.02) }, name)
                barBottom[screen.name] = firstNotNavy
                XCTAssertGreaterThan(firstNotNavy, 40, "\(name): navy behind the status bar and the bar")
                // Paper starts right under the navy: no soft edge and no band. The drawing is scaled down
                // to 1x, which leaves a pixel or two of ringing at an edge that falls between pixels.
                let under = column[min(firstNotNavy + 4, column.count - 1)]
                XCTAssertTrue(SnapshotPixels.matches(under, paper, tolerance: 0.02), "\(name): paper under the bar, got \(under)")
            }
            let compact = try XCTUnwrap(barBottom["tab-root"])
            XCTAssertEqual(try XCTUnwrap(barBottom["sign-in"]), compact, accuracy: 1, "\(styleName): the same bar before and after the tabs")
            XCTAssertGreaterThan(try XCTUnwrap(barBottom["bills-root"]), compact + 30, "\(styleName): the masthead band continues the navy")

            // A glass screen pushed from a navy root: no navy anywhere down its left edge.
            let pushed = AnyView(NavigationStack(path: .constant([1])) {
                ScrollView { PageTitle(title: "Profile") }
                    .billboardBackground()
                    .tabRootBar(wordmark: .compact) {}
                    .navigationDestination(for: Int.self) { _ in
                        ScrollView { Text("About Billboard").padding(20) }
                            .billboardBackground()
                            .navigationTitle("About Billboard")
                            .glassNavigationBar()
                    }
            }.environmentObject(civicScore))
            let image = try snapshot(pushed, style: style)
            let column = try SnapshotPixels.column(of: image, x: 6)
            XCTAssertFalse(column.contains { SnapshotPixels.matches($0, navy, tolerance: 0.02) }, "\(styleName): a pushed glass screen has no navy band")
        }
    }

    // MARK: - Helpers

    private func snapshotAll(_ screens: [(String, AnyView)], file: StaticString = #filePath, line: UInt = #line) throws {
        for (name, view) in screens {
            for (styleName, style) in Self.styles {
                let image = try snapshot(view, style: style)
                let attachment = XCTAttachment(image: image)
                attachment.name = "snapshot-\(name)-\(styleName)"
                attachment.lifetime = .keepAlways
                add(attachment)
                // A blank screen (the failure ImageRenderer showed) is its background with nothing on it.
                let share = try SnapshotContent.share(of: image)
                XCTAssertGreaterThan(
                    share,
                    SnapshotContent.minimumShare,
                    "\(name) \(styleName) drew nothing (\(SnapshotContent.percent(share)) of it differs from the background)",
                    file: file,
                    line: line
                )
            }
        }
    }

    /// Hosts `view` in its own window with the given appearance and draws the window.
    private func snapshot(_ view: AnyView, style: UIUserInterfaceStyle) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.overrideUserInterfaceStyle = style
        // The tint `RootView` applies over every screen.
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // Let SwiftUI finish its first update (tasks, appear handlers, async layout).
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

/// Tells a drawn screen from a blank one by the share of the image that differs from its background.
///
/// Every pixel counts. A sample on a coarse grid misses thin text, so a sparse screen passed or failed depending on
/// where its content sat: the light Reset password screen passed on iPhone 17 and failed on iPhone 17e.
enum SnapshotContent {
    /// A drawn screen covers more than this share of the image (1 pixel in 500); a blank one covers none. The sparsest
    /// screen here, Reset password in light mode, covers about 6% on both devices, and its title alone about 0.7%.
    static let minimumShare = 0.002

    /// The share of pixels whose colour, at 16 levels per channel, differs from the image's most common colour (its
    /// background). A blank or fully transparent image gives 0.
    static func share(of image: UIImage) throws -> Double {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let pixelCount = width * height
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, pixelCount > 0 else {
            XCTFail("could not read the snapshot's pixels")
            return 0
        }
        var counts = [Int](repeating: 0, count: 4096)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            counts[Int(pixels[index] >> 4) << 8 | Int(pixels[index + 1] >> 4) << 4 | Int(pixels[index + 2] >> 4)] += 1
        }
        let background = counts.max() ?? pixelCount
        return Double(pixelCount - background) / Double(pixelCount)
    }

    static func percent(_ share: Double) -> String {
        String(format: "%.2f%%", share * 100)
    }
}

/// Checks `SnapshotContent` on images drawn here, so the result is the same on every simulator.
@MainActor
final class SnapshotContentTests: XCTestCase {
    private static let size = CGSize(width: 390, height: 844)
    private static let titleFont = UIFont.systemFont(ofSize: 28, weight: .bold)

    func testBlankImagesHaveNoContent() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = screen(style: style) { _, _ in }
            XCTAssertEqual(try SnapshotContent.share(of: image), 0, "style \(style.rawValue)")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let transparent = UIGraphicsImageRenderer(size: Self.size, format: format).image { _ in }
        XCTAssertEqual(try SnapshotContent.share(of: transparent), 0)
    }

    /// Reset password in light mode: a title, an empty Email field and a disabled Send code button. It is drawn at
    /// every offset across one 16 px block, so a check that depends on where content sits fails at some offset.
    func testSparseScreenCountsAsDrawnWhereverItSits() throws {
        for offset in 0...16 {
            let image = screen(style: .light) { context, color in
                let title = CGRect(x: 0, y: CGFloat(56 + offset), width: Self.size.width, height: 40)
                let field = CGRect(x: 16, y: title.maxY + 18, width: 358, height: 50)
                let button = CGRect(x: 16, y: field.maxY + 18, width: 358, height: 50)
                text("Reset password", font: Self.titleFont, color: color(BillboardUIColors.primaryText), centredIn: title)
                fill(context, field, color(BillboardUIColors.cardBackground))
                text("Email", font: .systemFont(ofSize: 17), color: color(.placeholderText), at: CGPoint(x: field.minX + 14, y: field.minY + 14))
                fill(context, button, color(BillboardUIColors.secondaryBackground))
                text("Send code", font: .systemFont(ofSize: 17, weight: .semibold), color: color(BillboardUIColors.dimText), centredIn: button)
            }
            let share = try SnapshotContent.share(of: image)
            XCTAssertGreaterThan(share, SnapshotContent.minimumShare, "offset \(offset): \(SnapshotContent.percent(share))")
        }
    }

    func testTitleAloneCountsAsDrawn() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = screen(style: style) { _, color in
                let title = CGRect(x: 0, y: 64, width: Self.size.width, height: 40)
                text("Reset password", font: Self.titleFont, color: color(BillboardUIColors.primaryText), centredIn: title)
            }
            let share = try SnapshotContent.share(of: image)
            XCTAssertGreaterThan(share, SnapshotContent.minimumShare, "style \(style.rawValue): \(SnapshotContent.percent(share))")
        }
    }

    // MARK: - Helpers

    /// A 390 x 844 screen on the app background at scale 1, like the snapshots. `content` gets the context and a
    /// function that resolves a dynamic colour for `style`.
    private func screen(style: UIUserInterfaceStyle, _ content: (CGContext, (UIColor) -> UIColor) -> Void) -> UIImage {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let resolve: (UIColor) -> UIColor = { $0.resolvedColor(with: traits) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: Self.size, format: format).image { renderer in
            renderer.cgContext.setFillColor(resolve(BillboardUIColors.background).cgColor)
            renderer.cgContext.fill(CGRect(origin: .zero, size: Self.size))
            content(renderer.cgContext, resolve)
        }
    }

    private func fill(_ context: CGContext, _ rect: CGRect, _ color: UIColor) {
        context.setFillColor(color.cgColor)
        context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 12).cgPath)
        context.fillPath()
    }

    private func text(_ string: String, font: UIFont, color: UIColor, at point: CGPoint) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
    }

    private func text(_ string: String, font: UIFont, color: UIColor, centredIn rect: CGRect) {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

/// Reads pixels from a drawn screen, for the navigation-bar checks.
enum SnapshotPixels {
    typealias RGB = (red: Double, green: Double, blue: Double)

    /// The colours down the column at `x`, top to bottom.
    static func column(of image: UIImage, x: Int) throws -> [RGB] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        return (0..<height).map { y in
            let index = (y * width + x) * 4
            return (Double(pixels[index]) / 255, Double(pixels[index + 1]) / 255, Double(pixels[index + 2]) / 255)
        }
    }

    /// Whether any pixel at or below row `fromY` is within `tolerance` of `token` on every channel.
    static func contains(_ image: UIImage, _ token: BillboardColorToken.RGBA, tolerance: Double, fromY: Int = 0) throws -> Bool {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        let limit = Int((tolerance * 255).rounded())
        let target = [token.red, token.green, token.blue].map { Int(($0 * 255).rounded()) }
        for y in max(0, fromY)..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                if abs(Int(pixels[index]) - target[0]) <= limit,
                   abs(Int(pixels[index + 1]) - target[1]) <= limit,
                   abs(Int(pixels[index + 2]) - target[2]) <= limit {
                    return true
                }
            }
        }
        return false
    }

    static func matches(_ color: RGB, _ token: BillboardColorToken.RGBA, tolerance: Double) -> Bool {
        abs(color.red - token.red) <= tolerance && abs(color.green - token.green) <= tolerance && abs(color.blue - token.blue) <= tolerance
    }
}
