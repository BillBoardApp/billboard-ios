import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the screens UX-39's broken-flows slice adds or changes (feature review N7, N9, N12), in light and dark,
/// at the default size and AX3, and attaches each image for review: the code step a sign-in opens, About with
/// Contact us, the startup failure screen's address, Search's loading line, load error and no-results notices,
/// and the success panel for a territory. No network, no credentials, no baselines. Screens with platform
/// controls (text fields, lists, scroll views, spinners) are drawn in a window, as `ProfileRenderTests` does, with
/// the text size set on the host (`traitOverrides`); the rest with `ImageRenderer`. A window image must show ink
/// under the bar, so a blank page fails.
@MainActor
final class BrokenFlowsRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String { "\(scheme == .dark ? "dark" : "light")-\(size == .large ? "default" : "AX3")" }
        var style: UIUserInterfaceStyle { scheme == .dark ? .dark : .light }
    }

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility3)
    ]

    private static let width: CGFloat = 390

    // MARK: - Sign-in recovery (N7)

    /// Drawn in a window at every size: the screen scrolls and has a text field, which `ImageRenderer` leaves
    /// out (an AX3 render was blank paper).
    func testTheCodeStepFromSignInRenders() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        for variant in Self.variants {
            let screen = CreateAccountView(confirming: PendingSignUpConfirmation(email: "voter@example.com", password: "Secret-123"))
                .environmentObject(auth)
                .environmentObject(userStore)
            let image = try snapshot(AnyView(NavigationStack { screen }), variant: variant)
            attach(image, name: "signin-code-step-\(variant.name)")
            try assertPaper(image, variant: variant)
            try assertInk(image, variant: variant)
        }
    }

    func testAboutWithContactUsRenders() throws {
        let info = AboutInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "45",
            AboutInfo.websiteBaseURLKey: "https://billboard-project.com"
        ])
        for variant in Self.variants {
            let image = try snapshot(AnyView(NavigationStack { AboutView(info: info) }), variant: variant)
            attach(image, name: "about-contact-us-\(variant.name)")
            try assertPaper(image, variant: variant)
            try assertInk(image, variant: variant)
        }
    }

    func testTheStartupFailureAddressRenders() throws {
        for variant in Self.variants {
            let image = try render(StartupFailureView().frame(height: 844), variant: variant)
            attach(image, name: "startup-failure-contact-\(variant.name)")
            XCTAssertEqual(image.width, Int(Self.width))
        }
        let text = AccessibilityTreeText.text(of: StartupFailureView())
        XCTAssertTrue(text.contains(ContactUs.address), text)
    }

    // MARK: - Search (N9)

    /// The loading line, the load error with Try again, and the no-results notices for words and for a number,
    /// over every bill and over the bills loaded so far. Drawn in a window, so the loading line's spinner is drawn.
    func testSearchCoverageAndNoResultsRender() throws {
        let words = try XCTUnwrap(BillsSearch.Query("medicare dental"))
        let number = try XCTUnwrap(BillsSearch.Query("H.R. 99999"))
        let failed = BillsSearch.Coverage.failed(message: "Can't reach Billboard right now. Check your connection and try again.")
        for variant in Self.variants {
            let view = VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: BillsSearchLayout.headToContent) {
                    SectionHeader("Search results")
                    BillsSearchCoverageNotice(coverage: .loading) {}
                }
                VStack(alignment: .leading, spacing: BillsSearchLayout.headToContent) {
                    SectionHeader("Search results")
                    BillsSearchCoverageNotice(coverage: failed) {}
                    BillsSearchNoResults(query: words, coverage: failed)
                }
                VStack(alignment: .leading, spacing: BillsSearchLayout.headToContent) {
                    SectionHeader("Search results")
                    BillsSearchCoverageNotice(coverage: .everyBill) {}
                    BillsSearchNoResults(query: number, coverage: .everyBill)
                }
            }
            .padding(.horizontal, BillsSearchLayout.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BillboardColors.background)
            let image = try snapshot(AnyView(view), variant: variant, height: variant.size == .large ? 900 : 1700)
            attach(image, name: "search-coverage-\(variant.name)")
            try assertPaper(image, variant: variant)
            try assertInk(image, variant: variant)
        }
    }

    /// What VoiceOver reads: the loading line, the error notice with its own Try again, and the no-results notice
    /// saying what was searched. Nothing counts anyone's votes (INT-11).
    func testSearchNoticesReadInFull() throws {
        let words = try XCTUnwrap(BillsSearch.Query("medicare dental"))
        let failed = BillsSearch.Coverage.failed(message: "Can't reach Billboard right now. Check your connection and try again.")
        let host = AccessibilityTreeText.Host(
            VStack {
                BillsSearchCoverageNotice(coverage: .loading) {}
                BillsSearchCoverageNotice(coverage: failed) {}
                BillsSearchNoResults(query: words, coverage: .everyBill)
            },
            size: CGSize(width: 390, height: 1200),
            settle: 0.2
        )
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(BillsSearch.loadingText), text)
        XCTAssertTrue(text.contains("Couldn't load every bill"), text)
        XCTAssertTrue(text.contains("Try again"), text)
        XCTAssertTrue(text.contains("No results for \"medicare dental\""), text)
        XCTAssertTrue(text.contains("We looked in the number, title, topic and life areas of every bill."), text)
        XCTAssertEqual(host.identifier(of: "Try again"), "search.loadEveryBill.retry")
        XCTAssertNil(text.range(of: #"\b\d+\s+votes?\b"#, options: .regularExpression), text)
    }

    // MARK: - Territories (N12)

    func testTerritorySuccessPanelsRender() throws {
        let fixtures: [(String, LocationEditorResult)] = [
            ("puerto-rico-verified", territoryResult(state: "PR", district: "98", verified: true)),
            ("virgin-islands-chosen", territoryResult(state: "VI", district: "At-Large", verified: false))
        ]
        for (name, fixture) in fixtures {
            for variant in Self.variants {
                let panel = LocationSavedPanel(
                    result: fixture,
                    context: .setup,
                    followState: .idle,
                    unfollowedRepresentativeCount: 0,
                    onContinue: { _ in },
                    onFollow: {},
                    onDone: {}
                )
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BillboardColors.background)
                let image = try render(panel, variant: variant)
                attach(image, name: "location-success-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 200, "\(name) \(variant.name)")
            }
        }
        let text = AccessibilityTreeText.text(of: LocationSavedPanel(
            result: fixtures[0].1,
            context: .setup,
            followState: .idle,
            unfollowedRepresentativeCount: 0,
            onContinue: { _ in },
            onFollow: {},
            onDone: {}
        ))
        XCTAssertTrue(text.contains("You're in Puerto Rico."), text)
        XCTAssertFalse(text.contains("98"), "the Census code never shows: \(text)")
    }

    // MARK: - Helpers

    private func territoryResult(state: String, district: String, verified: Bool) -> LocationEditorResult {
        LocationEditorResult(
            state: state,
            district: DistrictPickerModel.normalizedDistrict(district, state: state) ?? district,
            method: verified ? .address : .chosenDistrict,
            verification: DistrictVerificationStatus(
                verified: verified,
                status: verified ? "verified" : "self_attested",
                method: verified ? DistrictVerificationStatus.methodAddressGeocode : DistrictVerificationStatus.methodManualStateDistrict,
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

    private func render<Content: View>(_ view: Content, variant: Variant) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.width)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    /// The view in a window on the test host's screen, drawn after it settles (lists, scroll views, text fields and
    /// spinners draw only in a window). The text size is the host's trait, as Settings sets it: an environment
    /// override on a text field in a window hung the test host.
    private func snapshot(_ view: AnyView, variant: Variant, height: CGFloat = 844) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: Self.width, height: height))
        window.overrideUserInterfaceStyle = variant.style
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        host.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(variant.size)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The screen's left margin, below the bar, is paper in the variant's appearance (it follows dark mode).
    private func assertPaper(_ image: UIImage, variant: Variant, file: StaticString = #filePath, line: UInt = #line) throws {
        let paper = variant.scheme == .dark ? BillboardPalette.background.dark : BillboardPalette.background.light
        let margin = try SnapshotPixels.column(of: image, x: 4)
        XCTAssertTrue(
            margin.dropFirst(200).prefix(200).contains { SnapshotPixels.matches($0, paper, tolerance: 0.02) },
            "\(variant.name): paper in the margin",
            file: file,
            line: line
        )
    }

    /// The screen shows text, in the variant's ink, below the bar: not a blank page.
    private func assertInk(_ image: UIImage, variant: Variant, file: StaticString = #filePath, line: UInt = #line) throws {
        let ink = variant.scheme == .dark ? BillboardPalette.primaryText.dark : BillboardPalette.primaryText.light
        XCTAssertTrue(
            try SnapshotPixels.contains(image, ink, tolerance: 0.04, fromY: 140),
            "\(variant.name): ink below the bar",
            file: file,
            line: line
        )
    }

    private func attach(_ image: CGImage, name: String) {
        attach(UIImage(cgImage: image), name: name)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
