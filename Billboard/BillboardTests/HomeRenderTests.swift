import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the Bills tab's pieces and the Updates cards that changed in R2 (spec D 2.1, 2.3, 2.4, 2.5.4)
/// in light and dark, at the default text size and at AX3, and attaches each image for review (spec D
/// 5.3). No network, no credentials, no baselines; a few sizes and pixels are checked.
@MainActor
final class HomeRenderTests: XCTestCase {
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

    private func render<Content: View>(_ view: Content, variant: Variant, width: CGFloat = 390) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .background(BillboardColors.background)
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
                in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height))
            )
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    private func luminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * rgb.red + 0.7152 * rgb.green + 0.0722 * rgb.blue
    }

    // MARK: - Fixtures

    private func bill(_ guid: String, number: String, status: BillStatus = .new, title: String) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: "Economic Policy",
            subCategory: "Energy",
            summary: "Requires a yearly report on how the program spends its money.",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 60 * 60)),
            billStatus: status,
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: number,
            userVoted: false,
            isPriority: status == .new
        )
    }

    private var items: [BillBoardItem] {
        [
            bill("BILLS-119hr1234", number: "1234", title: "Clean Energy Reporting Act"),
            bill("BILLS-119hr77", number: "77", status: .updated, title: "Rural Broadband Access Act of 2026, a long title that wraps")
        ].map { BillBoardItem(id: $0.id, bill: $0, date: Date(), type: $0.billStatus == .updated ? .updated : .bill) }
    }

    private var userStore: UserStore {
        UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService())
    }

    // MARK: - Bills tab

    /// The Bills tab as it stacks up for a no-topic profile (Civic Record spec 4.18): the masthead band
    /// under the navy bar (3.21), then the search capsule, the starter banner, the mono line, the slips
    /// and the "Show one more week" row, at the 16 pt list gutter. (`SwipeableTile` hosts a UIKit pan
    /// recognizer, which ImageRenderer cannot draw, so the slips are drawn without it here.) Teal means
    /// only Yea: no brand teal anywhere on the paper screen.
    func testTheBillsTabRendersInEveryVariant() throws {
        let items = items
        let store = userStore
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let specDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))
        for variant in Self.variants {
            let tab = VStack(spacing: 0) {
                MastheadBand(date: specDate)
                VStack(alignment: .leading, spacing: BillBoardQueueList.slipSpacing) {
                    BillsSearchEntryCard()
                    StarterFeedBanner(onChooseTopics: {}, onClose: {})
                    BillBoardListLine(windowTitle: "1 week")
                    ForEach(items) { item in
                        BillCard(bill: item.bill)
                    }
                    BillBoardExpandHistoryCard(isExpanding: false, action: {})
                }
                .padding(.horizontal, BillboardStyle.Space.l)
                .padding(.vertical, 14)
            }
            .environmentObject(store)
            let image = try render(tab, variant: variant)
            attach(image, name: "bills-tab-\(variant.name)")
            XCTAssertGreaterThan(image.height, 40 + 2 * 120 + 44 * 2, "\(variant.name): band, entry, banner, two slips and the row")
            // The band is navy, edge to edge, in both appearances; paper starts under it.
            let navy = BillboardPalette.navy.light
            let band = try pixel(of: image, x: 2, y: 4)
            XCTAssertEqual(band.red, navy.red, accuracy: 0.02, variant.name)
            XCTAssertEqual(band.green, navy.green, accuracy: 0.02, variant.name)
            XCTAssertEqual(band.blue, navy.blue, accuracy: 0.02, variant.name)
            try assertNoBrandTeal(in: image, variant.name)
        }
    }

    /// Every bill card is a slip (Civic Record spec 3.4, 4.19): no status stripe, no topic wash and no
    /// shadow, in light and dark.
    func testBillCardsAreSlipsWithoutStripeWashOrShadow() throws {
        let store = userStore
        for scheme in [ColorScheme.light, .dark] {
            for item in items {
                let card = BillCard(bill: item.bill)
                    .padding(20)
                    .environmentObject(store)
                let image = try render(card, variant: Variant(scheme: scheme, size: .large))
                attach(image, name: "bill-card-slip-\(item.bill.billStatus)-\(scheme == .dark ? "dark" : "light")")
                try SlipPixels.assertPlainSlip(in: image, inset: 20, dark: scheme == .dark, "\(item.bill.billStatus) \(scheme)")
            }
        }
    }

    /// Mid-swipe, the slip uncovers "Skip" on a neutral `well` sheet of the slip's own shape: never a vote
    /// colour (spec D 2.1.1; Civic Record spec 3.28). At rest nothing shows behind the slip.
    func testASwipedCardRevealsSkipInNeutralColours() throws {
        let item = items[0]
        let store = userStore
        for variant in Self.variants {
            let swiped = ZStack(alignment: .trailing) {
                SwipeActionReveal(title: BillBoardQueueList.swipeActionName, progress: 1)
                BillCard(bill: item.bill)
                    .offset(x: -110)
            }
            .padding(.horizontal, 20)
            .environmentObject(store)
            let image = try render(swiped, variant: variant)
            attach(image, name: "skip-reveal-\(variant.name)")

            // Inside the reveal's 22 pt trailing padding, mid-height: the well.
            let sample = try pixel(of: image, x: image.width - 20 - 8, y: image.height / 2)
            let spread = max(sample.red, sample.green, sample.blue) - min(sample.red, sample.green, sample.blue)
            XCTAssertLessThan(spread, 0.12, "\(variant.name): a grey surface, not teal Yea or orange Nay")
            let well = BillboardPalette.secondaryBackground.resolved(dark: variant.scheme == .dark).rgb
            XCTAssertEqual(sample.red, well.red, accuracy: 0.02, "\(variant.name): the well")
            XCTAssertEqual(sample.green, well.green, accuracy: 0.02, "\(variant.name): the well")
            XCTAssertEqual(sample.blue, well.blue, accuracy: 0.02, "\(variant.name): the well")
            // The reveal has the slip's 16 pt corners: its top trailing pixel is the ground.
            let corner = try pixel(of: image, x: image.width - 20 - 2, y: 1)
            let ground = BillboardPalette.background.resolved(dark: variant.scheme == .dark).rgb
            XCTAssertEqual(corner.red, ground.red, accuracy: 0.03, "\(variant.name): a rounded corner")
            XCTAssertEqual(corner.blue, ground.blue, accuracy: 0.03, "\(variant.name): a rounded corner")
        }

        let atRest = try render(
            SwipeActionReveal(title: BillBoardQueueList.swipeActionName, progress: 0).frame(height: 120).padding(20),
            variant: Variant(scheme: .light, size: .large)
        )
        let ground = BillboardPalette.background.light.rgb
        let middle = try pixel(of: atRest, x: atRest.width / 2, y: atRest.height / 2)
        XCTAssertEqual(middle.red, ground.red, accuracy: 0.02, "nothing shows before the slip moves")
        XCTAssertEqual(middle.green, ground.green, accuracy: 0.02, "nothing shows before the slip moves")
    }

    // MARK: - Bill slip variants (Civic Record spec 3.4, frame 3)

    private struct SlipVariant {
        let name: String
        let content: BillSlipContent
    }

    private static let jordan = BillSlipContent.Sponsor(name: "Jordan Ellis", party: .republican, chamber: .house, stateCode: "TX", district: "7")
    private static let priya = BillSlipContent.Sponsor(name: "Priya Natarajan", party: .democratic, chamber: .senate, stateCode: "CA")
    private static let longSponsor = BillSlipContent.Sponsor(name: "Rep. Alexandria Montgomery-Fitzgerald Jr.", party: .independent)

    /// `days` before now: the slips print it as a date this year ("Oct 14") or with its year.
    private static func daysAgo(_ days: Int) -> Date {
        Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    /// Every slip variant of frame 3: New, Updated and watched, Passed, Failed, Became law, a companion
    /// group with its lead stamp, a member-page slip with its companions line, no sponsor, no stub, and a
    /// long sponsor name.
    private static var slipVariants: [SlipVariant] {
        [
            SlipVariant(name: "new", content: BillSlipContent(
                title: "Clean Energy Reporting Act", numbers: ["H.R. 1234"], status: .new,
                tags: [.inTheNews, .topic("Energy")], sponsor: jordan, lastUpdated: daysAgo(3)
            )),
            SlipVariant(name: "updated-watched", content: BillSlipContent(
                title: "Medicare Prescription Drug Price Negotiation Improvement and Transparency Act", numbers: ["S. 88"],
                status: .updated, isWatched: true, tags: [.topic("Healthcare")], sponsor: priya, lastUpdated: daysAgo(2)
            )),
            SlipVariant(name: "passed", content: BillSlipContent(
                title: "Veterans Housing Assistance Expansion", numbers: ["H.R. 3021"], status: .passed,
                tags: [.topic("Housing"), .lifeArea("Housing")], sponsor: jordan, lastUpdated: daysAgo(5)
            )),
            SlipVariant(name: "failed", content: BillSlipContent(
                title: "Clean Energy Access Act", numbers: ["H.R. 6512"], status: .failed,
                tags: [.topic("Energy")], sponsor: jordan, lastUpdated: daysAgo(11)
            )),
            SlipVariant(name: "became-law", content: BillSlipContent(
                title: "Heritage Month Act", numbers: ["H.R. 498"], status: .finalized, lastUpdated: daysAgo(15)
            )),
            SlipVariant(name: "companion", content: BillSlipContent(
                title: "Protecting Veterans Act", numbers: ["H.R. 10", "S. 10"], status: .passed, companionLead: "S. 10",
                tags: [.identicalBills, .memberYouFollow], sponsor: priya, lastUpdated: daysAgo(8)
            )),
            SlipVariant(name: "number-subtitle", content: BillSlipContent(
                title: "Protecting Veterans Act", numbers: ["S. 10"], status: .new, subtitle: "Identical to H.R. 10",
                sponsor: priya, lastUpdated: daysAgo(8)
            )),
            SlipVariant(name: "no-stub", content: BillSlipContent(
                title: "A resolution with no sponsor or date on record", numbers: ["H.Res. 12"], status: .new
            )),
            SlipVariant(name: "long-sponsor", content: BillSlipContent(
                title: "Rural Broadband Access Act of 2026", numbers: ["H.R. 77"], status: .updated,
                tags: [.memberYouFollow], sponsor: longSponsor, lastUpdated: daysAgo(4)
            ))
        ]
    }

    private func slips(_ variants: [SlipVariant]) -> some View {
        VStack(spacing: BillboardStyle.Space.m) {
            ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                BillSlip(content: variant.content)
            }
        }
        .padding(BillboardStyle.Space.l)
    }

    /// Renders `view` at `scale` (the render tests' `render` draws at 1x).
    private func renderSlips<Content: View>(_ view: Content, variant: Variant, width: CGFloat = 390, scale: CGFloat = 1) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .background(BillboardColors.background)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    /// Frame 3 in every look (light, dark, default and AX3), at AX5, and at 375 pt for the long name.
    func testEverySlipVariantRendersInEveryLook() throws {
        let variants = Self.slipVariants
        for look in Self.variants + [Variant(scheme: .light, size: .accessibility5)] {
            let name = look.size == .accessibility5 ? "light-AX5" : look.name
            let image = try renderSlips(slips(variants), variant: look)
            attach(image, name: "bill-slips-\(name)")
            XCTAssertGreaterThan(image.height, variants.count * 90, name)
            try assertNoBrandTeal(in: image, name)
        }
        for look in [Variant(scheme: .light, size: .large), Variant(scheme: .dark, size: .large), Variant(scheme: .light, size: .accessibility3)] {
            let image = try renderSlips(slips(variants.filter { $0.name == "long-sponsor" || $0.name == "new" }), variant: look, width: 375)
            attach(image, name: "bill-slips-375-\(look.name)")
        }
    }

    /// Each variant is a plain slip: a 1 pt rule, the sheet inside it, the ground outside (no shadow,
    /// stripe or wash), in light and dark.
    func testEverySlipVariantIsAPlainSlip() throws {
        for scheme in [ColorScheme.light, .dark] {
            for variant in Self.slipVariants {
                let image = try renderSlips(BillSlip(content: variant.content).padding(20), variant: Variant(scheme: scheme, size: .large))
                try SlipPixels.assertPlainSlip(in: image, inset: 20, dark: scheme == .dark, "\(variant.name) \(scheme)")
            }
        }
    }

    /// The docket line comes first (spec 3.1, 10.1): the number's glyphs, 14 pt under the slip's top and
    /// 16 pt in, are `ink2` (semibold), not the title's `ink`. Drawn at 3x so the stems are solid.
    func testTheDocketLineLeadsEachSlipInInk2() throws {
        let scale: CGFloat = 3
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
            let ink2 = BillboardPalette.secondaryText.resolved(dark: dark).rgb
            for variant in Self.slipVariants {
                let image = try renderSlips(BillSlip(content: variant.content).padding(20), variant: Variant(scheme: scheme, size: .large), scale: scale)
                // The docket band: 14 pt down to 28 pt, the first 40 pt of the line ("H.R. 1234").
                var strongest: (red: Double, green: Double, blue: Double)?
                var strongestDistance = 0.0
                for y in stride(from: Int((20 + 14) * scale), to: Int((20 + 28) * scale), by: 1) {
                    for x in stride(from: Int((20 + 16) * scale), to: Int((20 + 56) * scale), by: 1) {
                        let sample = try pixel(of: image, x: x, y: y)
                        let distance = abs(sample.red - sheet.red) + abs(sample.green - sheet.green) + abs(sample.blue - sheet.blue)
                        if distance > strongestDistance {
                            strongestDistance = distance
                            strongest = sample
                        }
                    }
                }
                let glyph = try XCTUnwrap(strongest, "\(variant.name) \(scheme): glyphs in the docket band")
                XCTAssertEqual(glyph.red, ink2.red, accuracy: 0.05, "\(variant.name) \(scheme): the number is ink2")
                XCTAssertEqual(glyph.green, ink2.green, accuracy: 0.05, "\(variant.name) \(scheme): the number is ink2")
                XCTAssertEqual(glyph.blue, ink2.blue, accuracy: 0.05, "\(variant.name) \(scheme): the number is ink2")
            }
        }
    }

    /// The stub (spec 3.4): a long sponsor name at 375 pt puts the date under the sponsor, as every
    /// accessibility size does; without a sponsor the stub is the date alone, and without both there is
    /// no stub.
    func testTheStubStacksAndShortens() throws {
        let look = Variant(scheme: .light, size: .large)
        func height(_ content: BillSlipContent, width: CGFloat = 375) throws -> Int {
            try renderSlips(BillSlip(content: content), variant: look, width: width).height
        }
        let base = BillSlipContent(title: "Rural Broadband Access Act", numbers: ["H.R. 77"], status: .new, sponsor: Self.jordan, lastUpdated: Self.daysAgo(4))
        var long = base
        long.sponsor = Self.longSponsor
        var dateOnly = base
        dateOnly.sponsor = nil
        var noStub = dateOnly
        noStub.lastUpdated = nil

        let oneLine = try height(base)
        XCTAssertGreaterThan(try height(long), oneLine + 10, "the date goes under a long name at 375 pt")
        XCTAssertEqual(try height(base, width: 390), oneLine, "a short name keeps one line")
        XCTAssertLessThan(try height(dateOnly), oneLine, "no sponsor: the date alone")
        XCTAssertLessThan(try height(noStub), try height(dateOnly), "no sponsor and no date: no stub")
        XCTAssertFalse(noStub.hasStub)
        XCTAssertTrue(dateOnly.hasStub)
    }

    /// One VoiceOver element per slip, reading the slip's sentence, and no vote text in the tree (INT-11,
    /// as `BillCardVoteCountTests` checks for the cards).
    func testEachSlipIsOneSentenceWithNoVoteText() throws {
        let variants = Self.slipVariants
        let strings = AccessibilityTreeText.strings(of: slips(variants), size: CGSize(width: 390, height: 2400))
        for variant in variants {
            XCTAssertTrue(strings.contains(variant.content.accessibilityLabel()), "\(variant.name) in \(strings)")
        }
        let text = strings.joined(separator: " | ")
        XCTAssertNil(text.range(of: #"\bvot(e|es|ed|ing)\b"#, options: [.regularExpression, .caseInsensitive]), text)
        for word in ["Yea", "Nay", "Abstain", "Results", "10+", "50+", "150+"] {
            XCTAssertFalse(text.contains(word), "\(word) in: \(text)")
        }
        XCTAssertNil(text.range(of: #"\bH\.R\.|\bS\. \d"#, options: .regularExpression), "numbers are spoken: \(text)")
    }

    /// The slip's sentence (spec 3.4): title, spoken number, stamp, watched, companions line, tags,
    /// sponsor with the party in words, and the date; a date in another year carries the year.
    func testTheSlipSentenceReadsLikeTheSpec() throws {
        let locale = Locale(identifier: "en_US")
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func day(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        }
        let now = try day(2026, 10, 17)
        func sentence(_ content: BillSlipContent) -> String {
            content.accessibilityLabel(now: now, locale: locale, timeZone: timeZone)
        }

        var new = BillSlipContent(
            title: "Clean Energy Reporting Act", numbers: ["H.R. 1234"], status: .new,
            tags: [.inTheNews, .topic("Energy")], sponsor: Self.jordan, lastUpdated: try day(2026, 10, 14)
        )
        XCTAssertEqual(
            sentence(new),
            "Clean Energy Reporting Act. House bill 1234. New. In the news. Topic: Energy. Sponsor: Representative Jordan Ellis, Republican, Texas's 7th district. Last updated October 14."
        )
        XCTAssertEqual(new.lastUpdatedText(now: now, locale: locale, timeZone: timeZone)?.printed, "Oct 14", "the docket role sets OCT 14")
        new.lastUpdated = try day(2025, 12, 30)
        XCTAssertEqual(new.lastUpdatedText(now: now, locale: locale, timeZone: timeZone)?.printed, "Dec 30, 2025")
        XCTAssertTrue(sentence(new).hasSuffix("Last updated December 30, 2025."), sentence(new))

        let companion = BillSlipContent(
            title: "Protecting Veterans Act", numbers: ["H.R. 10", "S. 10"], status: .passed, companionLead: "S. 10",
            tags: [.identicalBills, .memberYouFollow], sponsor: Self.priya, lastUpdated: try day(2026, 10, 9)
        )
        XCTAssertEqual(
            sentence(companion),
            "Protecting Veterans Act. House bill 10 and Senate bill 10. Senate bill 10 passed. Identical bills. Member you follow. Sponsor: Senator Priya Natarajan, Democrat, California. Last updated October 9."
        )

        // One spoken form everywhere (project decision, 2026-10-21): the slip says its sponsor as the bill page does.
        XCTAssertEqual(
            Self.jordan.spokenSentence,
            BillSponsorRow.Content(
                name: "Jordan Ellis", party: .republican, chamber: .house, stateCode: "TX", district: "7"
            ).accessibilityLabel
        )
        XCTAssertEqual(
            BillSlipContent.Sponsor(name: "Ann Lee", party: .independent).spokenSentence,
            "Sponsor: Ann Lee, Independent",
            "no chamber or seat known: name and party only"
        )

        let watched = BillSlipContent(title: "Grid Repair Act", numbers: ["S. 88"], status: .updated, isWatched: true)
        XCTAssertEqual(sentence(watched), "Grid Repair Act. Senate bill 88. Updated. Watching.")
        XCTAssertTrue(watched.showsWatchedMark)
        var watchedNew = watched
        watchedNew.status = .new
        XCTAssertFalse(watchedNew.showsWatchedMark, "the binoculars mark only on an Updated bill")
        XCTAssertEqual(sentence(watchedNew), "Grid Repair Act. Senate bill 88. New.")

        let law = BillSlipContent(title: "Heritage Month Act", numbers: ["H.R. 498"], status: .finalized, subtitle: "Identical to H.R. 900 and S.J.Res. 4")
        XCTAssertEqual(sentence(law), "Heritage Month Act. House bill 498. Became law. Identical to House bill 900 and Senate joint resolution 4.")
        XCTAssertEqual(law.stamp, .becameLaw, "a green double-ruled stamp")

        let unnumbered = BillSlipContent(title: "A bill", numbers: [], status: .failed)
        XCTAssertEqual(sentence(unnumbered), "A bill. Failed.")
    }

    /// What a slip shows of a bill (spec 3.4): the tags in R2's order (In the news, Member you follow, the
    /// topic, two life areas) and at most three, after "Identical bills" for a group; the group's numbers
    /// and status lead; the watch; the stored date; never a vote.
    func testSlipContentFromABill() throws {
        let followed = UUID.deterministic(from: "member-1")
        let profile = UserProfile(
            id: "user-1", email: "reader@example.com", district: "",
            state: "", avatarName: nil,
            subscribedSubCategories: ["Energy"], subscribedLifeAreas: ["Housing", "Work", "Health"],
            subscribedMemberIDs: [followed], watchedBillGUIDs: [], selectedBillContentTypes: []
        )
        let storedAt = "2026-10-14T15:00:00Z"
        var bill = Bill(
            id: UUID.deterministic(from: "BILLS-119hr900"), title: "Grid Repair Act", category: "Economic Policy",
            subCategory: "Energy", soWhat: "", storedAt: storedAt, lifeAreas: ["Housing", "Work", "Health"],
            billStatus: .updated, guid: "BILLS-119hr900", congress: "119", billType: "hr", billID: "900",
            sponsorMemberID: followed, relatedMemberIDs: [followed], userVoted: true, userWatched: false,
            userVote: .yea, isPriority: true
        )
        let content = BillSlipContent(bill: bill, profile: profile, sponsor: Self.jordan)
        XCTAssertEqual(content.numbers, ["H.R. 900"])
        XCTAssertEqual(content.tags, [.inTheNews, .memberYouFollow, .topic("Energy")], "R2's order, at most three")
        XCTAssertEqual(content.stamp, .updated)
        XCTAssertFalse(content.showsWatchedMark)
        XCTAssertEqual(content.lastUpdated, FlexibleISO8601.parse(storedAt))
        XCTAssertNil(content.accessibilityLabel().range(of: "Yea"), "the reader's own vote is not on the slip (project decision 5)")

        bill.userWatched = true
        XCTAssertTrue(BillSlipContent(bill: bill, profile: profile).showsWatchedMark)

        let group = BillCompanionGroup(primaryGuid: "BILLS-119hr900", memberGuids: ["BILLS-119hr900", "BILLS-119s456"], relationship: "identical")
        let lead = CompanionStatusLead(guid: "BILLS-119s456", status: .passed, isPrimary: false, billNumber: "S. 456")
        bill.userWatched = false
        let grouped = BillSlipContent(bill: bill, profile: profile, companion: BillCompanionDisplay(group: group, statusLead: lead, isWatched: true))
        XCTAssertEqual(grouped.numbers, ["H.R. 900", "S. 456"])
        XCTAssertEqual(grouped.companionLead, "S. 456")
        XCTAssertEqual(grouped.stamp, .companionLead(number: "S. 456", status: .passed))
        XCTAssertEqual(grouped.tags.first, .identicalBills)
        XCTAssertEqual(grouped.tags.count, 1 + BillSlipContent.maximumInterestTags)
        XCTAssertTrue(grouped.isWatched, "a watched member watches the group")

        let primaryLead = CompanionStatusLead(guid: "BILLS-119hr900", status: .new, isPrimary: true, billNumber: "H.R. 900")
        let primaryLed = BillSlipContent(bill: bill, profile: profile, companion: BillCompanionDisplay(group: group, statusLead: primaryLead))
        XCTAssertNil(primaryLed.companionLead, "the primary leads: a plain stamp")
        XCTAssertEqual(primaryLed.stamp, .new)

        let member = BillSlipContent(bill: bill, profile: profile, numberSubtitle: "Identical to S. 456")
        XCTAssertEqual(member.subtitle, "Identical to S. 456")
        XCTAssertNil(BillSlipContent(bill: bill, profile: profile, numberSubtitle: "").subtitle)
    }

    /// Teal means only Yea (spec 1.2): no brand teal (#00BFA6, within 2 per channel) in a capture of a
    /// paper screen.
    private func assertNoBrandTeal(in image: CGImage, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "bitmap context", file: file, line: line)
        var tealPixels = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[index]), green = Int(bytes[index + 1]), blue = Int(bytes[index + 2])
            if abs(red - 0x00) <= 2, abs(green - 0xBF) <= 2, abs(blue - 0xA6) <= 2 {
                tealPixels += 1
            }
        }
        XCTAssertEqual(tealPixels, 0, "\(message): brand teal on a paper screen", file: file, line: line)
    }


    // MARK: - States and banner

    /// The queue states (spec 4.22): the syncing placeholder, ALL CAUGHT UP (with and without the pull
    /// hint), the Show one more week row, COULDN'T LOAD with Retry, and the sync capsule and Jump to top.
    func testQueueStatesRenderInEveryVariant() throws {
        for variant in Self.variants {
            let states = VStack(spacing: 16) {
                BillBoardQueueSyncPlaceholder()
                BillBoardCaughtUpState(windowTitle: "1 week", canExpand: true)
                BillBoardCaughtUpState(windowTitle: "52 weeks", canExpand: false)
                BillBoardExpandHistoryCard(isExpanding: false, action: {})
                BillBoardLoadErrorState(message: "Can't reach Billboard right now. Check your connection and try again.", isRetrying: false, onRetry: {})
                BillBoardLoadErrorState(message: "Can't reach Billboard right now.", isRetrying: true, onRetry: {})
                BillBoardSyncCapsule(isShowingStaleQueue: false)
                BillBoardSyncCapsule(isShowingStaleQueue: true)
                JumpToTopButton(action: {})
            }
            .padding(.horizontal, BillboardStyle.Space.l)
            let image = try render(states, variant: variant)
            attach(image, name: "bills-states-\(variant.name)")
            XCTAssertGreaterThan(image.height, 600, variant.name)
            try assertNoBrandTeal(in: image, variant.name)
        }
    }

    /// The states read as record notices (spec 3.20): the stamp word, title and message as one element,
    /// the action apart with its id; R2's copy.
    func testQueueStatesSpeakAsRecordNotices() throws {
        XCTAssertEqual(
            BillBoardCaughtUpState(windowTitle: "1 week").message,
            "No bills left to vote on from the last 1 week. Pull down to add one more week, up to a year."
        )
        XCTAssertEqual(BillBoardCaughtUpState(windowTitle: "52 weeks", canExpand: false).message, "No bills left to vote on from the last 52 weeks.")

        let caughtUp = AccessibilityTreeText.strings(of: BillBoardCaughtUpState(windowTitle: "1 week"))
        XCTAssertEqual(caughtUp, ["All caught up. You're all caught up. No bills left to vote on from the last 1 week. Pull down to add one more week, up to a year."])

        let host = AccessibilityTreeText.Host(
            VStack {
                BillBoardLoadErrorState(message: "Can't reach Billboard right now. Check your connection and try again.", isRetrying: false, onRetry: {})
                BillBoardExpandHistoryCard(isExpanding: false, action: {})
            }
        )
        defer { host.close() }
        let strings = host.strings()
        XCTAssertTrue(strings.contains("Couldn't load. Couldn't load your bills. Can't reach Billboard right now. Check your connection and try again."), "\(strings)")
        XCTAssertEqual(host.identifier(of: "Retry"), "home.queue.retry", "the notice's id leaves Retry's alone")
        XCTAssertEqual(host.identifier(of: "Show one more week"), "home.queue.expandHistory")
        XCTAssertTrue(strings.contains("Older bills you haven't voted on"), "\(strings)")
    }

    /// The signed-in UI tests (`waitForHomeQueueCard`) find the queue states by id: as record notices
    /// their words are one element with the stamp's ("All caught up. You're all caught up. …"), so no element
    /// is labelled with the title alone any more, and the placeholder reads its two lines as one.
    func testTheQueueStatesCarryTheIdsTheSmokeTestsFind() throws {
        let host = AccessibilityTreeText.Host(
            VStack {
                BillBoardCaughtUpState(windowTitle: "1 week")
                BillBoardQueueSyncPlaceholder()
                BillBoardSyncCapsule(isShowingStaleQueue: true)
            }
        )
        defer { host.close() }
        XCTAssertEqual(
            host.label(ofIdentifier: "home.queue.caughtUp"),
            "All caught up. You're all caught up. No bills left to vote on from the last 1 week. Pull down to add one more week, up to a year."
        )
        let syncing = try XCTUnwrap(host.label(ofIdentifier: "home.queue.syncing"), host.text())
        XCTAssertTrue(syncing.hasPrefix("Updating your bills…"), syncing)
        XCTAssertTrue(syncing.contains("Getting the latest bills."), syncing)
        XCTAssertEqual(host.label(ofIdentifier: "home.queue.syncCapsule"), "Refreshing your bills…")

        let updating = AccessibilityTreeText.Host(BillBoardSyncCapsule(isShowingStaleQueue: false))
        defer { updating.close() }
        XCTAssertEqual(updating.label(ofIdentifier: "home.queue.syncCapsule"), "Updating your bills…")
    }

    @MainActor
    private final class MeasuredFrames {
        var monoLine: CGRect?
        var firstSlip: CGRect?
    }

    /// Frame 1 (spec 4.18): 12 pt from the mono line to the first slip, and from the sync capsule to it,
    /// measured through `BillBoardQueueList` stacked as `BillBoardTab` stacks it. The list's scroll
    /// anchors take no room: in the spaced stack, two zero-height anchors pushed the first slip 24 pt down.
    func testTheFirstSlipSitsOneGapUnderTheMonoLineAndTheSyncCapsule() throws {
        let items = items
        let store = userStore
        for isSyncing in [false, true] {
            let frames = MeasuredFrames()
            let column = VStack(alignment: .leading, spacing: BillBoardQueueList.slipSpacing) {
                BillBoardListLine(windowTitle: "1 week")
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(ProductTutorialStorage.coordinateSpaceName))
                    } action: { frames.monoLine = $0 }
                BillBoardQueueList(
                    items: items,
                    isSyncing: isSyncing,
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
            }
            .padding(.horizontal, BillboardStyle.Space.l)
            .frame(maxHeight: .infinity, alignment: .top)
            .environmentObject(store)
            .coordinateSpace(name: ProductTutorialStorage.coordinateSpaceName)
            .environment(\.tutorialFrameCaptureEnabled, true)
            .onPreferenceChange(TutorialAnchorFramePreferenceKey.self) { anchors in
                frames.firstSlip = anchors[.billsFirstCard]
            }
            let host = AccessibilityTreeText.Host(column, size: CGSize(width: 402, height: 1200), settle: 0.5)
            let line = try XCTUnwrap(frames.monoLine, "the mono line")
            let slip = try XCTUnwrap(frames.firstSlip, "the first slip")
            host.close()
            // The sync capsule is 44 pt at the default size, one gap under the mono line.
            let expected = isSyncing ? BillBoardQueueList.slipSpacing + 44 + BillBoardQueueList.slipSpacing : BillBoardQueueList.slipSpacing
            XCTAssertEqual(slip.minY - line.maxY, expected, accuracy: 0.5, isSyncing ? "under the sync capsule" : "under the mono line")
        }
    }

    func testTheStarterBannerRendersAndFollowsTheAppearance() throws {
        for variant in Self.variants {
            let banner = StarterFeedBanner(onChooseTopics: {}, onClose: {})
                .padding(20)
            let image = try render(banner, variant: variant)
            attach(image, name: "starter-banner-\(variant.name)")
            // Close and Choose topics are 44 pt targets, plus two lines of text and padding.
            XCTAssertGreaterThanOrEqual(image.height, 44 + 44 + 40, variant.name)

            // No card (spec 4.21): under Choose topics, above the hairline, the banner is the paper.
            let ground = BillboardPalette.background.resolved(dark: variant.scheme == .dark).rgb
            let surface = try pixel(of: image, x: 30, y: image.height - 20 - 1 - 7)
            XCTAssertEqual(surface.red, ground.red, accuracy: 0.02, "\(variant.name): paper, not a card")
            XCTAssertEqual(surface.blue, ground.blue, accuracy: 0.02, "\(variant.name): paper, not a card")
            try assertNoBrandTeal(in: image, variant.name)
        }

        let host = AccessibilityTreeText.Host(StarterFeedBanner(onChooseTopics: {}, onClose: {}))
        defer { host.close() }
        XCTAssertEqual(host.identifier(of: "Hide for a week"), "home.starterBanner.close")
        XCTAssertEqual(host.identifier(of: "Choose topics"), "home.starterBanner.chooseTopics")
        XCTAssertTrue(host.traits(of: "New this week.")?.contains(.header) == true, "the banner's line labels the list")
    }

    /// The search entry is a 48 pt capsule (spec 3.17): a sheet with a 1 pt controlRule, its words in ink3.
    func testTheSearchEntryRendersInEveryVariant() throws {
        for variant in Self.variants {
            // A NavigationLink renders its label outside a navigation stack.
            let entry = BillsSearchEntryCard().padding(20)
            let image = try render(entry, variant: variant)
            attach(image, name: "search-entry-\(variant.name)")
            XCTAssertGreaterThanOrEqual(image.height, 48 + 40, variant.name)
            if variant.size == .large {
                XCTAssertEqual(image.height, 48 + 40, "\(variant.name): 48 pt")
                let dark = variant.scheme == .dark
                let rule = try pixel(of: image, x: image.width / 2, y: 20)
                let controlRule = BillboardColorMath.composite(
                    BillboardPalette.controlRule.resolved(dark: dark).rgb,
                    alpha: BillboardPalette.controlRule.resolved(dark: dark).alpha,
                    over: BillboardPalette.cardBackground.resolved(dark: dark).rgb
                )
                XCTAssertEqual(rule.red, controlRule.red, accuracy: 0.03, "\(variant.name): the controlRule edge")
                XCTAssertEqual(rule.green, controlRule.green, accuracy: 0.03, "\(variant.name): the controlRule edge")
                let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
                let inside = try pixel(of: image, x: image.width - 40, y: image.height / 2)
                XCTAssertEqual(inside.red, sheet.red, accuracy: 0.02, "\(variant.name): the sheet")
            }
            try assertNoBrandTeal(in: image, variant.name)
        }
    }

    /// The Bills list's glass capsules (spec 3.19): the sync capsule and Jump to top carry their words on
    /// the opaque sheet inside the rim, over paper and over a white title alike, and drop the rim under
    /// Reduce Transparency. 44 pt tall at the default size.
    func testTheSyncCapsuleAndJumpToTopCarryTheirWordsOnAnOpaqueSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let sheet = BillboardPalette.cardBackground.resolved(dark: dark).rgb
            let capsules: [(String, AnyView)] = [
                ("sync", AnyView(BillBoardSyncCapsule(isShowingStaleQueue: false))),
                ("jump", AnyView(JumpToTopButton(action: {}))),
                ("swipe-hint", AnyView(TutorialSwipeHint(reduceMotion: true)))
            ]
            let grounds: [(String, Color, (red: Double, green: Double, blue: Double))] = [
                ("paper", BillboardColors.background, BillboardPalette.background.resolved(dark: dark).rgb),
                ("white", BillboardColors.textOnNavy, (red: 1, green: 1, blue: 1))
            ]
            for (name, capsule) in capsules {
                // Where the capsule starts, found over paper; over white it is drawn in the same place.
                var capsuleLeft: Int?
                for (groundName, ground, groundRGB) in grounds {
                    let image = try renderSlips(
                        capsule.fixedSize().padding(10).background(ground),
                        variant: Variant(scheme: scheme, size: .large),
                        width: 260,
                        scale: 2
                    )
                    attach(image, name: "glass-\(name)-\(groundName)-\(dark ? "dark" : "light")")
                    XCTAssertEqual(image.height, (44 + 20) * 2, "\(name): 44 pt")
                    // From the capsule's left edge on the middle row: past the 4 pt rim and 4 pt into the
                    // sheet, still left of the text (14 pt in).
                    let row = image.height / 2
                    if capsuleLeft == nil {
                        capsuleLeft = try firstPixel(in: image, row: row, unlike: groundRGB)
                    }
                    let left = try XCTUnwrap(capsuleLeft, "\(name): the capsule")
                    let sample = try pixel(of: image, x: left + 8 * 2 + 2, y: row)
                    XCTAssertEqual(sample.red, sheet.red, accuracy: 0.01, "\(name) over \(groundName), \(scheme): the opaque sheet")
                    XCTAssertEqual(sample.green, sheet.green, accuracy: 0.01, "\(name) over \(groundName), \(scheme): the opaque sheet")
                    XCTAssertEqual(sample.blue, sheet.blue, accuracy: 0.01, "\(name) over \(groundName), \(scheme): the opaque sheet")
                }
            }
        }
        XCTAssertEqual(BillBoardSyncCapsule(isShowingStaleQueue: true).title, "Refreshing your bills…")
        XCTAssertEqual(BillBoardSyncCapsule(isShowingStaleQueue: false).title, "Updating your bills…")
        XCTAssertEqual(AccessibilityTreeText.strings(of: JumpToTopButton(action: {})), ["Jump to top"])
    }

    /// The first x on `row` whose pixel is not `ground`: where the capsule starts.
    private func firstPixel(in image: CGImage, row: Int, unlike ground: (red: Double, green: Double, blue: Double)) throws -> Int? {
        for x in 0..<image.width {
            let sample = try pixel(of: image, x: x, y: row)
            if abs(sample.red - ground.red) + abs(sample.green - ground.green) + abs(sample.blue - ground.blue) > 0.03 {
                return x
            }
        }
        return nil
    }

    // MARK: - Updates: the Weekly Brief front page (Civic Record spec 3.26, 4.51)

    private var digest: WeeklyDigest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WeeklyDigestSchedule.timeZone
        func eastern(_ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        return WeeklyDigest(
            id: "2026-10-17",
            title: "Your Week in Congress | Oct 11-17, 2026",
            summary: "Two bills need your attention, and one member you follow took action.",
            weekStart: eastern(11),
            weekEnd: eastern(17),
            publishedAt: eastern(17, hour: 13, minute: 12),
            source: .remote,
            isRead: false,
            stats: [
                WeeklyDigestStat(id: "attention", label: "Need attention", value: "2", accent: .attention),
                WeeklyDigestStat(id: "representatives", label: "Members active", value: "1", accent: .representative),
                WeeklyDigestStat(id: "quicklook", label: "Worth a look", value: "3", accent: .discovery)
            ],
            sections: []
        )
    }

    /// The Weekly Brief's front page is a slip, ink on sheet in both appearances (it replaces R2's "white
    /// text on navy" card): the plain slip with its 1 pt rule and no shadow, the darkest (light) or lightest
    /// (dark) text in ink, and no colour anywhere in it: no navy fill, no gradient, no teal, no gold.
    func testWeeklyBriefFrontPageDrawsInkOnSheet() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dark = scheme == .dark
            let image = try render(WeeklyBriefFrontPage(digest: digest).padding(20), variant: Variant(scheme: scheme, size: .large))
            attach(image, name: "weekly-brief-front-page-\(dark ? "dark" : "light")")
            try SlipPixels.assertPlainSlip(in: image, inset: 20, dark: dark, "front page \(scheme)")

            let pixels = try UpdatesRenderPixels.bytes(of: image)
            var extreme: (red: Double, green: Double, blue: Double)?
            var largestSpread = 0.0
            var inkCount = 0
            for y in 21..<(image.height - 21) {
                for x in 21..<(image.width - 21) {
                    let i = (y * image.width + x) * 4
                    let sample = (red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255, blue: Double(pixels[i + 2]) / 255)
                    let spread = max(sample.red, sample.green, sample.blue) - min(sample.red, sample.green, sample.blue)
                    largestSpread = max(largestSpread, spread)
                    let level = luminance(sample)
                    if dark ? level > 0.6 : level < 0.4 { inkCount += 1 }
                    if let current = extreme {
                        if dark ? level > luminance(current) : level < luminance(current) { extreme = sample }
                    } else {
                        extreme = sample
                    }
                }
            }
            XCTAssertLessThan(largestSpread, 0.2, "\(scheme): no teal, navy fill, gold or other colour in the front page")
            let ink = BillboardPalette.primaryText.resolved(dark: dark).rgb
            let found = try XCTUnwrap(extreme)
            XCTAssertEqual(found.red, ink.red, accuracy: 0.06, "\(scheme): the strongest text is ink")
            XCTAssertEqual(found.green, ink.green, accuracy: 0.06, "\(scheme): the strongest text is ink")
            XCTAssertEqual(found.blue, ink.blue, accuracy: 0.06, "\(scheme): the strongest text is ink")
            let area = (image.width - 42) * (image.height - 42)
            XCTAssertLessThan(Double(inkCount) / Double(area), 0.25, "\(scheme): ink is text on the sheet, not a filled card")
        }
    }

    /// The front page, the read row, the loading slip and both error states render in every variant.
    func testWeeklyBriefStatesRenderInEveryVariant() throws {
        var read = digest
        read.isRead = true
        for variant in Self.variants {
            let states = VStack(alignment: .leading, spacing: 16) {
                WeeklyDigestPreviewCard(digest: digest)
                WeeklyDigestCompactCard(digest: read)
                WeeklyDigestLoadingCard()
                WeeklyDigestErrorCard(message: "Can't reach Billboard right now.", isShowingPreviousBrief: true, retry: {})
                WeeklyDigestErrorCard(message: "Can't reach Billboard right now.", isShowingPreviousBrief: false, retry: {})
            }
            .padding(16)
            let image = try render(states, variant: variant)
            attach(image, name: "weekly-brief-states-\(variant.name)")
            XCTAssertGreaterThan(image.height, 300, variant.name)
        }
    }
}
