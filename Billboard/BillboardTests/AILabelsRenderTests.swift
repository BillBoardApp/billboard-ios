import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// The AI labels (UX-37, feature review N3): "Written with AI from the official text · Report a problem" under Why it
/// matters, the Breakdown and the Summary on the bill page, Report a problem's email (with the address and Copy when
/// Mail isn't set up), and "Theme scores come from AI ratings of each bill." under both Civic Profile charts. Renders
/// each in light and dark at the default size and at accessibility sizes, and attaches the images for review.
@MainActor
final class AILabelsRenderTests: XCTestCase {
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

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility5)
    ]

    private static func bill(title: String = "Clean Energy Reporting Act", guid: String? = "BILLS-119hr1234ih") -> Bill {
        Bill(
            id: UUID.deterministic(from: "BILLS-119hr1234"),
            title: title,
            officialTitle: "To require a yearly public report on the Clean Energy Deployment Program.",
            category: "Energy",
            summary: "Requires the Department of Energy to publish a yearly report on the program's spending.",
            soWhat: "The program has grown fast, and it is hard to see where the money goes.",
            billBreakdown: BillBreakdown(
                who: "The Department of Energy would write the report.",
                what: "A yearly public report on every dollar the program spends.",
                how: nil,
                when: "It starts with the 2027 budget year.",
                where: nil,
                why: nil
            ),
            billStatus: .new,
            guid: guid,
            userVoted: false
        )
    }

    private static var reference: ReportProblem.BillReference {
        ReportProblem.BillReference(bill: bill())
    }

    // MARK: - Copy and the email

    func testTheCopyIsAsAgreed() {
        XCTAssertEqual(BillAINote.text, "Written with AI from the official text")
        XCTAssertEqual(ReportProblem.title, "Report a problem")
        XCTAssertEqual(BillAINote.accessibilityLabel, "Written with AI from the official text. Report a problem")
        XCTAssertEqual(
            (BillAINote.printedText + BillAINote.printedLink).replacingOccurrences(of: "\u{00A0}", with: " "),
            "Written with AI from the official text · Report a problem"
        )
        XCTAssertEqual(CivicProfileInfoCopy.aiNote, "Theme scores come from AI ratings of each bill.")
        XCTAssertEqual(ContactUs.address, "contact@billboard-project.com")
    }

    /// The subject names the bill's number and its title as the page shows it; the body names the text version.
    func testTheEmailNamesTheBill() throws {
        let reference = Self.reference
        XCTAssertEqual(reference.number, "H.R. 1234")
        XCTAssertEqual(ReportProblem.subject(for: reference), "Report a problem: H.R. 1234, Clean Energy Reporting Act")
        XCTAssertEqual(ReportProblem.body(for: reference), "Bill ID: BILLS-119hr1234ih\r\n\r\n")

        let url = ReportProblem.mailURL(for: reference)
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "contact@billboard-project.com")
        XCTAssertEqual(components.queryItems?.first { $0.name == "subject" }?.value, "Report a problem: H.R. 1234, Clean Energy Reporting Act")
        XCTAssertEqual(components.queryItems?.first { $0.name == "body" }?.value, "Bill ID: BILLS-119hr1234ih\r\n\r\n")

        // A title with "&", "=", "?", "#", "+" and accents stays one field, whole.
        let awkward = ReportProblem.BillReference(number: "S. 10", title: "Taxes & Fees = Fair? #1 + Café “Act”", guid: nil)
        let awkwardURL = ReportProblem.mailURL(for: awkward)
        let parsed = try XCTUnwrap(URLComponents(url: awkwardURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parsed.queryItems?.map(\.name), ["subject"], awkwardURL.absoluteString)
        XCTAssertEqual(parsed.queryItems?.first?.value, "Report a problem: S. 10, Taxes & Fees = Fair? #1 + Café “Act”")
        XCTAssertFalse(awkwardURL.absoluteString.contains("+"), "a plus is encoded, so no app reads it as a space")

        let untitled = ReportProblem.BillReference(number: nil, title: "  ", guid: nil)
        XCTAssertEqual(ReportProblem.subject(for: untitled), "Report a problem")
        XCTAssertEqual(ReportProblem.mailURL(for: untitled).absoluteString, "mailto:contact@billboard-project.com?subject=Report%20a%20problem")
        let headlineless = ReportProblem.BillReference(bill: Self.bill(title: " ", guid: nil))
        XCTAssertEqual(headlineless.title, "To require a yearly public report on the Clean Energy Deployment Program.", "the official title when there is no headline")
    }

    /// Without Mail set up the address is shown with Copy (and "Open email app", for another default email app);
    /// when no app opens the address, the address is shown with Copy. The fallback is the one mail helper's
    /// (`ContactUs`), its message ending on the bill.
    func testReportAProblemWorksWithoutMail() {
        XCTAssertEqual(ContactUs.firstFallback(canSendMail: false), .mailNotSetUp)
        XCTAssertNil(ContactUs.firstFallback(canSendMail: true))
        XCTAssertEqual(
            ContactUs.Fallback.mailNotSetUp.message(about: ReportProblem.aboutBill(Self.reference)),
            "Mail isn't set up on this iPhone. Write to contact@billboard-project.com from any email app about H.R. 1234."
        )
        XCTAssertEqual(
            ContactUs.Fallback.couldNotOpen.message(about: ReportProblem.aboutBill(Self.reference)),
            "Billboard couldn't open an email app. Write to contact@billboard-project.com about H.R. 1234."
        )
        let numberless = ReportProblem.BillReference(number: nil, title: "A bill", guid: nil)
        XCTAssertEqual(
            ContactUs.Fallback.couldNotOpen.message(about: ReportProblem.aboutBill(numberless)),
            "Billboard couldn't open an email app. Write to contact@billboard-project.com and name the bill."
        )
        XCTAssertTrue(ContactUs.Fallback.mailNotSetUp.offersEmailApp)
        XCTAssertFalse(ContactUs.Fallback.couldNotOpen.offersEmailApp)

        // Mail isn't set up: nothing is opened, the address shows.
        var opened: [URL] = []
        var shown: [ContactUs.Fallback] = []
        let handled = OpenURLAction { url in
            opened.append(url)
            return .handled
        }
        ReportProblem.open(bill: Self.reference, canSendMail: false, openURL: handled) { shown.append($0) }
        XCTAssertEqual(opened, [])
        XCTAssertEqual(shown, [.mailNotSetUp])

        // Mail is set up: the email opens.
        shown = []
        let opens = expectation(description: "the email opens")
        let handledThenDone = OpenURLAction { url in
            opened.append(url)
            opens.fulfill()
            return .handled
        }
        ReportProblem.open(bill: Self.reference, canSendMail: true, openURL: handledThenDone) { shown.append($0) }
        wait(for: [opens], timeout: 2)
        XCTAssertEqual(opened, [ReportProblem.mailURL(for: Self.reference)])
        XCTAssertEqual(shown, [])

        // No app takes it: the address shows.
        let refused = expectation(description: "the address shows")
        let discarded = OpenURLAction { _ in .discarded }
        ReportProblem.open(bill: Self.reference, canSendMail: true, openURL: discarded) {
            shown.append($0)
            refused.fulfill()
        }
        wait(for: [refused], timeout: 2)
        XCTAssertEqual(shown, [.couldNotOpen])
    }

    /// One mail helper (integration of 1.2's tracks): Report a problem and Contact us write to the one address, build
    /// their email links the same way and share one fallback. Contact us's email has no subject and its fallback
    /// message ends at the address; Report a problem's names the bill.
    func testReportAProblemAndContactUsShareOneMailHelper() throws {
        let report = try XCTUnwrap(URLComponents(url: ReportProblem.mailURL(for: Self.reference), resolvingAgainstBaseURL: false))
        let contact = try XCTUnwrap(URLComponents(url: ContactUs.mailURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(report.path, ContactUs.address)
        XCTAssertEqual(contact.path, ContactUs.address)
        XCTAssertNil(contact.queryItems, "Contact us opens a blank email")
        XCTAssertEqual(
            ReportProblem.mailURL(for: Self.reference),
            ContactUs.mailURL(subject: ReportProblem.subject(for: Self.reference), body: ReportProblem.body(for: Self.reference))
        )
        XCTAssertEqual(ContactUs.Fallback.mailNotSetUp.message, ContactUs.Fallback.mailNotSetUp.message(about: nil))
        XCTAssertEqual(
            ContactUs.Fallback.mailNotSetUp.message,
            "Mail isn't set up on this iPhone. Write to contact@billboard-project.com from any email app."
        )

        // Contact us opens its blank email through the same path.
        var opened: [URL] = []
        let opens = expectation(description: "the email opens")
        ContactUs.open(canSendMail: true, openURL: OpenURLAction { url in
            opened.append(url)
            opens.fulfill()
            return .handled
        }) { _ in XCTFail("no fallback when the email opens") }
        wait(for: [opens], timeout: 2)
        XCTAssertEqual(opened, [ContactUs.mailURL])
    }

    // MARK: - The bill page's note

    private func onDocument<Content: View>(_ view: Content) -> some View {
        view.background(BillboardColors.document)
    }

    private func sections() -> [(name: String, view: AnyView)] {
        let bill = Self.bill()
        return [
            ("why-it-matters", AnyView(BillSoWhatSection(bill: bill, showsRule: false))),
            ("breakdown", AnyView(BillBreakdownSection(breakdown: bill.billBreakdown!, aiNote: Self.reference))),
            ("summary", AnyView(BillSummarySection(summary: bill.summary, aiNote: Self.reference)))
        ]
    }

    /// Each AI-written section ends with the note, in light and dark, up to AX5.
    func testTheNoteRendersUnderEachAIWrittenSection() throws {
        for variant in Self.variants {
            for (name, view) in sections() {
                let image = try render(onDocument(view), variant: variant)
                attach(image, name: "ai-note-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 100, "\(name) \(variant.name)")
            }
        }
    }

    /// VoiceOver reads the note as one element, a button: the line, then "Report a problem", with a hint, after the
    /// section's text; Breakdown and Summary have no note when none is passed.
    func testVoiceOverReadsTheNoteAsOneButton() {
        for (name, view) in sections() {
            let host = AccessibilityTreeText.Host(onDocument(view).frame(width: 390), size: CGSize(width: 390, height: 1200))
            defer { host.close() }
            let strings = host.strings()
            XCTAssertEqual(Array(strings.suffix(2)), [BillAINote.accessibilityLabel, ReportProblem.accessibilityHint], "\(name): the note, then its hint, ends the section: \(strings)")
            XCTAssertEqual(strings.filter { $0.contains("Written with AI") }.count, 1, "\(name): one element: \(strings)")
            XCTAssertEqual(host.traits(of: BillAINote.accessibilityLabel)?.contains(.button), true, name)
            XCTAssertEqual(host.hint(of: BillAINote.accessibilityLabel), ReportProblem.accessibilityHint, name)
            XCTAssertEqual(host.identifier(of: BillAINote.accessibilityLabel), BillAINote.identifier, name)
        }
        let bill = Self.bill()
        for view in [AnyView(BillBreakdownSection(breakdown: bill.billBreakdown!)), AnyView(BillSummarySection(summary: bill.summary))] {
            XCTAssertFalse(AccessibilityTreeText.text(of: onDocument(view)).contains("Written with AI"))
        }
    }

    /// Voice Control takes "Tap Report a problem", the words drawn as the link, as well as the whole spoken name,
    /// as the app's other buttons with a short visible command do (Put back, Unfollow).
    func testVoiceControlCanSayReportAProblem() {
        for (name, view) in sections() {
            let host = AccessibilityTreeText.Host(onDocument(view).frame(width: 390), size: CGSize(width: 390, height: 1200))
            defer { host.close() }
            XCTAssertEqual(
                host.inputLabels(of: BillAINote.accessibilityLabel),
                ["Report a problem", "Written with AI from the official text. Report a problem"],
                name
            )
        }
    }

    /// The note is quiet: a `caption` line, far shorter than the `lead` text above it, and "Report a problem" is in
    /// ink (`interactive`), the rest in `ink2`.
    func testTheNoteIsAQuietCaptionLine() throws {
        for scheme in [ColorScheme.light, .dark] {
            let variant = Variant(scheme: scheme, size: .large)
            let note = try render(onDocument(BillAINote(bill: Self.reference)).frame(width: 390), variant: variant)
            XCTAssertLessThan(note.height / 2, 30, "\(variant.name): one caption line at 390 pt (rendered at 2x)")
            let ink = BillboardPalette.interactive.resolved(dark: scheme == .dark).rgb
            let secondary = BillboardPalette.secondaryText.resolved(dark: scheme == .dark).rgb
            let colours = try inkColours(note)
            XCTAssertTrue(colours.contains { distance($0, ink) < 0.08 }, "\(variant.name): the link in ink")
            XCTAssertTrue(colours.contains { distance($0, secondary) < 0.08 }, "\(variant.name): the line in ink 2")
        }
    }

    // MARK: - The Civic Profile charts

    private static func readyProfile(sponsored: Int? = nil) -> CivicProfileResponse {
        let keys = CivicProfileAxis.allCases.map(\.rawValue)
        return CivicProfileResponse(
            axes: Dictionary(uniqueKeysWithValues: zip(keys, [0.7, 0.4, 0.62, 0.56, 0.34, 0.82])),
            votesUsed: 33,
            // The server sends votesUsed = min(total, 100), so 33 of 50 never comes; 33 of 33 reads "Based on 33 votes".
            totalVotesWithProfile: 33,
            sponsoredBillsUsed: sponsored,
            cosponsoredBillsUsed: sponsored.map { $0 + 1 },
            minVotesRequired: 25,
            isReady: true
        )
    }

    private static let lockedProfile = CivicProfileResponse(axes: [:], votesUsed: 12, totalVotesWithProfile: 12, minVotesRequired: 25, isReady: false)

    /// Profile's chart and a member's chart both carry the AI line under the chart, in light and dark, up to AX5;
    /// a locked card, with no chart, does not.
    func testBothChartsSayTheThemeScoresComeFromAI() throws {
        // The renders show a profile the server can send, not a capped count of 33 ("Based on your last 33 votes").
        XCTAssertEqual(CivicProfileCopy.basedOn(Self.readyProfile()), "Based on 33 votes")
        let store = CivicProfileStore(service: FakeCivicService())
        let cards: [(name: String, view: AnyView)] = [
            ("profile", AnyView(CivicProfileCard(profile: Self.readyProfile(), isLoading: false).padding(16).background(BillboardColors.background))),
            ("member", AnyView(CongressMemberCivicProfileCard(mode: .profile(Self.readyProfile(sponsored: 3)), memberName: "Jordan Ellis")
                .background(BillboardColors.document).environmentObject(store)))
        ]
        for variant in Self.variants {
            for (name, view) in cards {
                let image = try render(view, variant: variant)
                attach(image, name: "ai-note-radar-\(name)-\(variant.name)")
            }
        }
        for (name, view) in cards {
            let host = AccessibilityTreeText.Host(view.frame(width: 390), size: CGSize(width: 390, height: 2400), settle: 0.3)
            defer { host.close() }
            let strings = host.strings()
            XCTAssertEqual(strings.filter { $0 == CivicProfileInfoCopy.aiNote }.count, 1, "\(name): one AI line: \(strings)")
            XCTAssertEqual(host.identifier(of: CivicProfileInfoCopy.aiNote), CivicProfileAINote.identifier, name)
            let note = try XCTUnwrap(strings.firstIndex(of: CivicProfileInfoCopy.aiNote))
            let lastTheme = try XCTUnwrap(strings.lastIndex { $0.contains("(1) to ") }, "\(name): \(strings)")
            XCTAssertGreaterThan(note, lastTheme, "\(name): under the chart: \(strings)")
        }
        let locked = AccessibilityTreeText.text(of: CivicProfileCard(profile: Self.lockedProfile, isLoading: false))
        XCTAssertFalse(locked.contains(CivicProfileInfoCopy.aiNote), locked)
    }

    // MARK: - Helpers

    private func render<Content: View>(_ view: Content, variant: Variant, width: CGFloat = 390) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = 2
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

    /// Every distinct colour in the image (opaque renders on the document ground).
    private func inkColours(_ image: CGImage) throws -> [BillboardColorMath.RGB] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colours: [BillboardColorMath.RGB] = []
        var seen = Set<Int>()
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let key = Int(bytes[index]) << 16 | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
            guard seen.insert(key).inserted else { continue }
            colours.append((red: Double(bytes[index]) / 255, green: Double(bytes[index + 1]) / 255, blue: Double(bytes[index + 2]) / 255))
        }
        return colours
    }
}
