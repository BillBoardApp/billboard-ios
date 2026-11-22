import SwiftUI
import XCTest
@testable import Billboard

/// "About Billboard" (spec D 2.7): the version line and both website links come from the bundle's
/// Info.plist, and a missing or malformed website key hides the links instead of opening junk.
@MainActor
final class AboutViewTests: XCTestCase {
    func testBothLinksAreBuiltFromTheInfoPlistKey() throws {
        let info = AboutInfo.current

        let raw = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: AboutInfo.websiteBaseURLKey) as? String)
        XCTAssertEqual(raw, "https://billboard-project.com")
        XCTAssertEqual(info.roadmapURL?.absoluteString, "https://billboard-project.com/roadmap.html")
        XCTAssertEqual(info.privacyURL?.absoluteString, "https://billboard-project.com/privacy.html")
    }

    func testTheRunningAppShowsItsVersionAndBuild() throws {
        let short = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

        XCTAssertEqual(AboutInfo.current.versionLine, "Version \(short) (\(build))")
    }

    /// The version row's value (Civic Record spec 4.70): "1.2 (45)" in the docket face, from the bundle.
    func testVersionNumberFormatsAndComesFromTheBundle() throws {
        XCTAssertEqual(AboutInfo.versionNumber(shortVersion: "1.2", build: "45"), "1.2 (45)")
        XCTAssertEqual(AboutInfo.versionNumber(shortVersion: " 1.2 ", build: " "), "1.2")
        XCTAssertEqual(AboutInfo.versionNumber(shortVersion: nil, build: "45"), "Build 45")
        XCTAssertEqual(AboutInfo.versionNumber(shortVersion: nil, build: nil), "Not available")

        let short = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertEqual(AboutInfo.current.versionNumber, "\(short) (\(build))")
    }

    /// The approved legal copy stays word for word through the Civic Record restyle (project decision,
    /// 2026-10-17): the address privacy note, the About footer with its AI line, and the lines that say the
    /// summaries are written with AI. Each sentence is asserted whole. The About footer says "open-source" since
    /// 1.3 (approved D3, decision 17 of 2026-11-08).
    func testApprovedLegalCopyIsUnchanged() {
        XCTAssertEqual(
            LocationEditorView.privacyNote,
            "We send your address to the U.S. Census Bureau to find your district. We don't keep your street address on our servers; your iPhone remembers it so you can change it later. We keep only a scrambled code of it so one address can't verify unlimited accounts."
        )
        XCTAssertEqual(
            AboutInfo.disclaimer,
            "Billboard is an independent, open-source app and is not affiliated with Congress or any government agency. Bill information comes from Congress.gov and GovInfo, roll-call votes from Congress.gov and the U.S. Senate, and In the news picks are chosen with AI from public news headlines."
        )
        XCTAssertEqual(
            CreateAccountView.valueBullets,
            [
                "Plain-English summaries of bills in Congress, written with AI from the official text",
                "Vote Yea, Nay or Abstain on any bill",
                "See combined results after you vote, and how your representatives voted"
            ]
        )
        XCTAssertEqual(
            ProductTutorial.steps[0].summary,
            "Each card is a real bill, with a plain-English summary written with AI from the official text. Tap a card to read it."
        )
        XCTAssertEqual(
            LoginView.valueLine,
            "Plain-English summaries of real bills. Vote Yea, Nay or Abstain, then see combined results and how your representatives voted."
        )
    }

    func testVersionLineFormats() {
        XCTAssertEqual(AboutInfo.versionLine(shortVersion: "1.2", build: "45"), "Version 1.2 (45)")
        XCTAssertEqual(AboutInfo.versionLine(shortVersion: " 1.2 ", build: " "), "Version 1.2")
        XCTAssertEqual(AboutInfo.versionLine(shortVersion: nil, build: "45"), "Build 45")
        XCTAssertEqual(AboutInfo.versionLine(shortVersion: nil, build: nil), "Version not available")
    }

    func testLinksFollowTheConfiguredBaseURL() {
        let info = AboutInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "45",
            AboutInfo.websiteBaseURLKey: "https://example.org/"
        ])

        XCTAssertEqual(info.versionLine, "Version 1.2 (45)")
        XCTAssertEqual(info.roadmapURL?.absoluteString, "https://example.org/roadmap.html")
        XCTAssertEqual(info.privacyURL?.absoluteString, "https://example.org/privacy.html")
    }

    func testMissingOrUnsafeBaseURLHidesBothLinks() {
        let rejected: [Any?] = [
            nil,
            "",
            "   ",
            "$(WEBSITE_BASE_URL)",
            "http://billboard-project.com",
            "billboard-project.com",
            "https://",
            "https://billboard-project.com?ref=app",
            42
        ]

        for value in rejected {
            var dictionary: [String: Any] = ["CFBundleShortVersionString": "1.2"]
            if let value { dictionary[AboutInfo.websiteBaseURLKey] = value }
            let info = AboutInfo(infoDictionary: dictionary)
            XCTAssertNil(info.roadmapURL, "\(String(describing: value))")
            XCTAssertNil(info.privacyURL, "\(String(describing: value))")
        }
    }

    func testNoInfoDictionaryStillDescribesTheApp() {
        let info = AboutInfo(infoDictionary: nil)
        XCTAssertEqual(info.versionLine, "Version not available")
        XCTAssertNil(info.roadmapURL)
        XCTAssertNil(info.privacyURL)
    }

    func testDisclaimerNamesTheSourcesAndIndependence() {
        XCTAssertTrue(AboutInfo.disclaimer.hasPrefix("Billboard is an independent, open-source app"))
        XCTAssertTrue(AboutInfo.disclaimer.contains("not affiliated with Congress or any government agency"))
        XCTAssertEqual(
            AboutInfo.disclaimer,
            "Billboard is an independent, open-source app and is not affiliated with Congress or any government agency. Bill information comes from Congress.gov and GovInfo, roll-call votes from Congress.gov and the U.S. Senate, and In the news picks are chosen with AI from public news headlines."
        )
        XCTAssertFalse(AboutInfo.disclaimer.contains("BillBoard"))
    }

    // MARK: - Source code and Open-source licenses (APPF-32)

    /// The Source code row (approved D1) opens the app's public repository.
    func testSourceCodeOpensThePublicRepository() {
        XCTAssertEqual(AboutInfo.sourceCodeURL.absoluteString, "https://github.com/BillBoardApp/billboard-ios")
    }

    /// The Source code row and the licenses row are there even when the build has no website key, which hides
    /// Roadmap and Privacy policy: the repository is public whatever the website.
    func testSourceCodeAndLicensesShowWithoutTheWebsiteKey() {
        let host = AccessibilityTreeText.Host(NavigationStack { AboutView(info: AboutInfo(infoDictionary: nil)) }, size: CGSize(width: 390, height: 1400), settle: 0.3)
        defer { host.close() }
        let ids = host.identifiers()
        XCTAssertTrue(ids.contains("about.sourceCode"), "\(ids)")
        XCTAssertTrue(ids.contains("about.openSourceLicenses"), "\(ids)")
        XCTAssertFalse(ids.contains("about.roadmap"), "\(ids)")
        XCTAssertFalse(ids.contains("about.privacy"), "\(ids)")
        XCTAssertEqual(host.label(ofIdentifier: "about.sourceCode"), "Source code")
        XCTAssertEqual(host.hint(of: "Source code"), "Opens in Safari")
    }

    /// With the website key, Source code follows Privacy policy in the links section (D1), and Open-source licenses
    /// (D2) is its own row that opens a screen in the app, so it has no Safari hint.
    func testAboutListsTheLinksThenTheLicensesRow() throws {
        let info = AboutInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.3",
            "CFBundleVersion": "92",
            AboutInfo.websiteBaseURLKey: "https://billboard-project.com"
        ])
        let host = AccessibilityTreeText.Host(NavigationStack { AboutView(info: info) }, size: CGSize(width: 390, height: 1400), settle: 0.3)
        defer { host.close() }
        let labels = host.elements().map(\.label)
        let privacy = try XCTUnwrap(labels.firstIndex(of: "Privacy policy"), "\(labels)")
        let source = try XCTUnwrap(labels.firstIndex(of: "Source code"), "\(labels)")
        let licenses = try XCTUnwrap(labels.firstIndex(of: "Open-source licenses"), "\(labels)")
        XCTAssertLessThan(privacy, source)
        XCTAssertLessThan(source, licenses)
        XCTAssertEqual(host.identifier(of: "Open-source licenses"), "about.openSourceLicenses")
        XCTAssertNil(host.hint(of: "Open-source licenses"))
        XCTAssertTrue(host.text().contains(AboutInfo.disclaimer), host.text())
    }
}
