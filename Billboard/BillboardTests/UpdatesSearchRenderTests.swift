import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the Updates rows, the push primer, the Weekly Brief detail and Search's lists, results and
/// list screens (Civic Record spec 4.24 to 4.26, 4.49 to 4.53, 10.1) with fixture data, in light and dark,
/// at the default text size and AX3, an Updates row and a Weekly Brief item also at AX5 on a 375 pt phone,
/// and attaches each image for review. No network, no credentials, no baselines. Checked: rows wrap in
/// full at accessibility sizes, VoiceOver reads each row's full text, the contents rows go to their
/// sections, the ids stay, and nothing here shows other people's votes or a vote count (INT-11).
///
/// `ImageRenderer` draws SwiftUI only: a `NavigationLink` renders its label outside a navigation stack, so
/// screens are rendered as their content views, without the search field or the scroll view.
@MainActor
final class UpdatesSearchRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String {
            let sizeName: String
            switch size {
            case .large: sizeName = "default"
            case .accessibility3: sizeName = "AX3"
            case .accessibility5: sizeName = "AX5"
            default: sizeName = "\(size)"
            }
            return "\(scheme == .dark ? "dark" : "light")-\(sizeName)"
        }
    }

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility3)
    ]

    private static let ax5 = Variant(scheme: .light, size: .accessibility5)

    /// The narrowest phone Billboard supports.
    private static let narrowWidth: CGFloat = 375

    // MARK: - Fixtures

    private func eastern(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        WeeklyDigestSchedule.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Sunday, October 18, 2026, noon in New York: "today" for the rows' dates.
    private var today: Date { eastern(2026, 10, 18, hour: 12) }

    private func alert(
        title: String = "Rural Broadband Access Act of 2026",
        text: String = "Reported by the Committee on Energy and Commerce.",
        actionDate: String? = "2026-10-14",
        topic: String? = "Technology",
        billID: UUID? = UUID.deterministic(from: "BILLS-119hr77ih")
    ) -> BillAlert {
        BillAlert(
            id: UUID.deterministic(from: "alert|\(title)"),
            sponsorMemberID: nil,
            billID: billID,
            title: title,
            category: "Science, Technology, Communications",
            summary: text,
            soWhat: text,
            lifeAreas: [],
            subCategory: topic,
            alertText: text,
            actionDate: actionDate,
            actionCode: nil,
            actionType: nil,
            date: eastern(2026, 10, 14, hour: 9)
        )
    }

    private func bill(
        _ guid: String,
        number: String,
        type: String = "hr",
        status: BillStatus,
        title: String,
        summary: String? = nil,
        priority: Bool = false
    ) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: "Energy",
            subCategory: "Energy",
            summary: summary ?? "Passed the House by voice vote.",
            soWhat: "",
            storedAt: "2026-10-14T15:00:00Z",
            billStatus: status,
            guid: guid,
            congress: "119",
            billType: type,
            billID: number,
            userVoted: false,
            isPriority: priority
        )
    }

    private var longTitle: String {
        "Medicare Prescription Drug Price Negotiation Improvement and Transparency Act, with the Rural Pharmacy Access and Community Health Center Modernization Amendments of 2026"
    }

    private var longText: String {
        "Read twice and referred to the Committee on Finance, then reported with an amendment in the nature of a substitute, placed on the Senate Legislative Calendar under General Orders, and scheduled for consideration after the motion to proceed was agreed to by unanimous consent."
    }

    private func member(_ id: String, _ name: String, chamber: String, state: String, district: Int? = nil, party: String) throws -> CongressMemberManifestItem {
        var fields = [#""bioguideId":"\#(id)""#, #""name":"\#(name)""#, #""chamber":"\#(chamber)""#, #""state":"\#(state)""#, #""party":"\#(party)""#]
        if let district { fields.append(#""district":\#(district)"#) }
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func briefItem(
        _ id: String,
        guid: String,
        title: String,
        eyebrow: String,
        summary: String,
        reason: String?,
        state: WeeklyDigestItem.BillState
    ) -> WeeklyDigestItem {
        WeeklyDigestItem(
            id: id,
            kind: .bill,
            title: title,
            eyebrow: eyebrow,
            summary: summary,
            detail: "A detail line.",
            reason: reason,
            accent: .attention,
            billState: state,
            billGuid: guid,
            primaryMemberBioguideID: nil
        )
    }

    private var digest: WeeklyDigest {
        let kaine = WeeklyDigestItem(
            id: "member|K000384",
            kind: .member,
            title: "Tim Kaine",
            eyebrow: "2 relevant bills this week",
            summary: "Backed 2 bills on topics you follow.",
            detail: "Top bill: Rural Broadband Access Act of 2026",
            reason: "Member you follow",
            accent: .representative,
            billState: nil,
            billGuid: "BILLS-119hr77ih",
            primaryMemberBioguideID: "K000384"
        )
        return WeeklyDigest(
            id: "2026-10-17",
            title: "Your Week in Congress | Oct 11-17, 2026",
            summary: "Two bills need your attention, and one member you follow took action.",
            weekStart: eastern(2026, 10, 11),
            weekEnd: eastern(2026, 10, 17),
            publishedAt: eastern(2026, 10, 17, hour: 13, minute: 12),
            source: .remote,
            isRead: false,
            stats: [
                WeeklyDigestStat(id: "attention", label: "Need attention", value: "2", accent: .attention),
                WeeklyDigestStat(id: "representatives", label: "Reps active", value: "1", accent: .representative),
                WeeklyDigestStat(id: "quicklook", label: "Worth a look", value: "0", accent: .discovery)
            ],
            sections: [
                WeeklyDigestSection(kind: .needsAttention, title: "Needs Your Attention", subtitle: "The highest-signal changes from the week.", items: [
                    briefItem("bill|77", guid: "BILLS-119hr77ih", title: "Rural Broadband Access Act of 2026", eyebrow: "Updated Oct 14",
                              summary: "The Energy and Commerce Committee reported the bill to the full House.", reason: "You voted on this before", state: .updated),
                    briefItem("bill|88", guid: "BILLS-119s88is", title: longTitle, eyebrow: "Updated Oct 15",
                              summary: longText, reason: "You're watching this", state: .updated)
                ]),
                WeeklyDigestSection(kind: .movedThisWeek, title: "What Moved This Week", subtitle: nil, items: [
                    briefItem("bill|405", guid: "BILLS-119hr405eh", title: "Grid Modernization Act", eyebrow: "Finalized Oct 9",
                              summary: "Signed into law.", reason: "Became law this week", state: .finalized)
                ]),
                WeeklyDigestSection(kind: .representatives, title: "Your Representatives This Week", subtitle: nil, items: [kaine]),
                WeeklyDigestSection(kind: .worthQuickLook, title: "Worth A Quick Look", subtitle: nil, items: [])
            ]
        )
    }

    private var userStore: UserStore {
        UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService())
    }

    // MARK: - Updates rows (spec 4.49, 4.53)

    /// The Updates sections as they stack, in every variant and at AX5 on a 375 pt phone: the heads, the
    /// hint, action rows with and without a loaded bill, the Passed, Became law and Failed rows and the
    /// empty notices.
    func testUpdatesRowsRenderInEveryVariant() throws {
        let passed = bill("BILLS-119hr405eh", number: "405", status: .passed, title: "Grid Modernization Act")
        let law = bill("BILLS-119hr406enr", number: "406", status: .finalized, title: "Water Infrastructure Act")
        let failed = bill("BILLS-119s12is", number: "12", type: "s", status: .failed, title: "Senate Rules Reform Act", summary: "Failed in the Senate, 48 to 52.")
        for variant in Self.variants + [Self.ax5] {
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let view = VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Recent actions", trailing: .button("Clear") {})
                UpdatesSectionHint(text: NotificationsView.recentActionsHint)
                    .padding(.top, BillboardStyle.Space.s)
                UpdatesActionRow(alert: alert(), billNumber: "H.R. 77", now: today)
                UpdatesActionRow(alert: alert(title: longTitle, text: longText, actionDate: nil, topic: nil), billNumber: nil, now: today)
                SectionHeader("Passed bills", trailing: .button("Clear all") {})
                    .padding(.top, UpdatesLayout.sectionSpacing)
                UpdatesOutcomeRow(bill: passed)
                UpdatesOutcomeRow(bill: law)
                SectionHeader("Failed bills", trailing: .button("Clear all") {})
                    .padding(.top, UpdatesLayout.sectionSpacing)
                UpdatesOutcomeRow(bill: failed)
                RecordNotice(.nothingYet, title: "No failed bills")
                    .padding(.top, UpdatesLayout.headToContent)
            }
            let image = try render(listPage(view), variant: variant, width: width)
            attach(image, name: "updates-rows-\(variant.name)")
            XCTAssertGreaterThan(image.height, 400, variant.name)
        }
    }

    /// At accessibility sizes an Updates row has no line limit (spec 2.5, 4.53): at AX5 the row is at least
    /// as tall as its title and text set in full at the row's width, while at the default size the 2-line
    /// title and 3-line text limits cut the same long words short.
    func testAnUpdatesRowWrapsInFullAtAX5() throws {
        let width = Self.narrowWidth - 2 * UpdatesLayout.gutter
        let long = alert(title: longTitle, text: longText, actionDate: "2026-10-14")
        let outcome = bill("BILLS-119s88is", number: "88", type: "s", status: .passed, title: longTitle, summary: longText)
        for size in [DynamicTypeSize.large, .accessibility5] {
            let full = try height(of: Text(longTitle).textRole(.name), width: width, size: size)
                + height(of: Text(longText).textRole(.body), width: width, size: size)
            let rows: [(String, AnyView)] = [
                ("action", AnyView(UpdatesActionRow(alert: long, billNumber: "S. 88", now: today))),
                ("outcome", AnyView(UpdatesOutcomeRow(bill: outcome)))
            ]
            for (name, row) in rows {
                let rowHeight = try height(of: row, width: width, size: size)
                if size == .accessibility5 {
                    XCTAssertGreaterThanOrEqual(rowHeight, full, "\(name) at AX5: the title and text wrap in full")
                    attach(try render(listPage(row), variant: Self.ax5, width: Self.narrowWidth), name: "updates-\(name)-row-long-AX5")
                } else {
                    XCTAssertLessThan(rowHeight, full, "\(name) at the default size: the line limits apply")
                }
            }
        }
    }

    /// VoiceOver reads each row's full text at every size, the bill number in its spoken form and the date
    /// with what it is, even where the row cuts the text short on screen.
    func testUpdatesRowsReadTheirFullText() {
        let row = UpdatesActionRow(alert: alert(title: longTitle, text: longText), billNumber: "S. 88", now: today)
        XCTAssertEqual(row.accessibilityText, "\(longTitle). Senate bill 88. Action on October 14. \(longText) Technology.")
        let text = AccessibilityTreeText.text(of: row.environment(\.dynamicTypeSize, .large))
        XCTAssertTrue(text.contains(longText), text)

        let outcome = UpdatesOutcomeRow(bill: bill("BILLS-119hr406enr", number: "406", status: .finalized, title: "Water Infrastructure Act"))
        XCTAssertEqual(outcome.accessibilityText, "Water Infrastructure Act. House bill 406. Became law. Passed the House by voice vote. Energy.")
    }

    /// The action date: a calendar day the push carried stays that day in any time zone; without one, the
    /// day the alert arrived in the phone's zone; the year only when it is not this year.
    func testTheActionDate() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let english = Locale(identifier: "en_US")
        let sameDay = try XCTUnwrap(UpdatesActionDate(alert: alert(actionDate: "2026-10-14"), now: today, locale: english, timeZone: losAngeles))
        XCTAssertEqual(sameDay.printed, "Oct 14")
        XCTAssertEqual(sameDay.spoken, "October 14")
        let arrived = try XCTUnwrap(UpdatesActionDate(alert: alert(actionDate: nil), now: today, locale: english, timeZone: losAngeles))
        XCTAssertEqual(arrived.printed, "Oct 14", "9 AM in New York is 6 AM in Los Angeles, the same day")
        let lastYear = try XCTUnwrap(UpdatesActionDate(alert: alert(actionDate: "2025-12-30"), now: today, locale: english, timeZone: losAngeles))
        XCTAssertEqual(lastYear.printed, "Dec 30, 2025")
        XCTAssertEqual(lastYear.spoken, "December 30, 2025")
    }

    /// Docket dates follow the reader's region everywhere (`DocketDate`): with English (UK) a Recent actions
    /// row prints "14 Oct", as the slips, the bill page's Actions ledger and the masthead above the rows do.
    /// The rows were fixed to US order ("OCT 14" under a "SAT 17 OCT 2026" deck).
    func testDocketDatesFollowTheRegionOnEveryScreen() throws {
        let british = Locale(identifier: "en_GB")
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let row = try XCTUnwrap(UpdatesActionDate(alert: alert(actionDate: "2026-10-14"), now: today, locale: british, timeZone: utc))
        XCTAssertEqual(row.printed, "14 Oct")
        XCTAssertEqual(row.spoken, "14 October")
        let lastYear = try XCTUnwrap(UpdatesActionDate(alert: alert(actionDate: "2025-12-30"), now: today, locale: british, timeZone: utc))
        XCTAssertEqual(lastYear.printed, "30 Dec 2025")

        let actionDay = try XCTUnwrap(FlexibleISO8601.parse("2026-10-14"))
        let slip = BillSlipContent(title: "A bill", numbers: ["H.R. 1"], status: .new, tags: [], sponsor: nil, lastUpdated: actionDay)
        XCTAssertEqual(slip.lastUpdatedText(now: today, locale: british, timeZone: utc)?.printed, row.printed, "the slip's stub")
        XCTAssertEqual(BillDocketDate.short("2026-10-14", now: today, locale: british, timeZone: utc), row.printed, "the Actions ledger")
        XCTAssertEqual(MastheadDateline(date: actionDay, locale: british, timeZone: utc).date, DocketDate.string(actionDay, template: "EEEMMMdyyyy", locale: british, timeZone: utc))
        XCTAssertTrue(MastheadDateline(date: actionDay, locale: british, timeZone: utc).date.contains("14 Oct"), "the masthead's day first too")
    }

    /// In the Updates list no link draws the system's disclosure chevron (spec 3.26, 4.53, frame 9). In a
    /// plain List the chevron takes a trailing column, so a link row stopped about 22 pt short of the 16 pt
    /// gutter and the read Weekly Brief showed two chevrons. Every row here, the front-page slip and the
    /// read row run to the gutter as the row that is a button does: each one's widest band of ink (the
    /// slip's sheet, a row's hairline) spans the page between the gutters. Hosted in a window on the screen
    /// with the real `NotificationsView`, since `ImageRenderer` draws a link's label without the List.
    func testUpdatesLinksRunToTheGutterWithoutTheSystemChevron() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = CGSize(width: scene.screen.bounds.width, height: 2400)
        let scale: CGFloat = 3
        let measure = size.width - 2 * UpdatesLayout.gutter
        for isRead in [false, true] {
            let host = try updatesHost(briefIsRead: isRead, size: size, scene: scene)
            defer { host.close() }
            let image = try XCTUnwrap(drawnWindow(host.window, scale: scale))
            let bytes = try UpdatesRenderPixels.bytes(of: image)
            attach(image, name: "updates-hosted-\(isRead ? "read" : "unread")-brief")
            let elements = host.elements()
            let rows = [
                ("Weekly Brief, October 11 to 17. \(isRead ? "Published" : "Unread")", "the \(isRead ? "read row" : "front page")"),
                ("Rural Broadband Access Act of 2026. House bill 77.", "a Recent actions link"),
                ("Grid Modernization Act. House bill 405. Passed.", "a Passed link"),
                ("Senate Rules Reform Act. Senate bill 12. Failed.", "a Failed link"),
                ("Coast Guard Authorization Act.", "the Recent actions row that is a button")
            ]
            for (prefix, name) in rows {
                let element = try XCTUnwrap(elements.first { $0.label.hasPrefix(prefix) }, "\(name) is listed: \(elements.map(\.label))")
                let widest = widestInkRun(in: bytes, width: image.width, rows: element.frame, scale: scale) / scale
                XCTAssertGreaterThanOrEqual(widest, measure - 1, "\(name) runs to the gutter, with no system chevron beside it")
                XCTAssertLessThanOrEqual(widest, measure + 1, "\(name) stays inside the gutter")
            }
            let brief = try XCTUnwrap(elements.first { $0.label.hasPrefix("Weekly Brief, October 11 to 17") })
            XCTAssertEqual(brief.identifier, "updates.weeklyBrief.open", "the brief keeps the id the UI test taps")
        }
    }

    /// The primer is a ruled block with its two buttons, which keep their ids inside the primer's.
    func testThePushPrimerRendersAndKeepsItsIds() throws {
        for variant in Self.variants + [Self.ax5] {
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let image = try render(listPage(UpdatesPushPrimer(onEnable: {}, onNotNow: {})), variant: variant, width: width)
            attach(image, name: "updates-push-primer-\(variant.name)")
        }
        let host = AccessibilityTreeText.Host(UpdatesPushPrimer(onEnable: {}, onNotNow: {}))
        defer { host.close() }
        XCTAssertEqual(host.identifier(of: "Turn on notifications"), "updates.pushPrimer.enable")
        XCTAssertEqual(host.identifier(of: "Not now"), "updates.pushPrimer.notNow")
        for benefit in UpdatesPushPrimer.benefits {
            XCTAssertTrue(host.text().contains(benefit), benefit)
        }
    }

    // MARK: - Weekly Brief front page (spec 3.26)

    /// The figures line is in the app's words, singular or plural by count, as frame 9 sets it: "2 need
    /// attention · 1 member active · 3 worth a look". The server's "Reps active" never shows (the glossary
    /// never says "reps"), nor the local brief's "1 Members active"; an unknown figure keeps its label.
    func testTheFiguresLineIsInTheAppsWords() {
        func stat(_ id: String, _ label: String, _ value: String) -> WeeklyDigestStat {
            WeeklyDigestStat(id: id, label: label, value: value, accent: .neutral)
        }
        let server = [stat("attention", "Need attention", "2"), stat("representatives", "Reps active", "1"), stat("quicklook", "Worth a look", "3")]
        XCTAssertEqual(WeeklyBriefFigures.text(server), "2 need attention\u{00A0}· 1 member active\u{00A0}· 3 worth a look")
        XCTAssertEqual(WeeklyBriefFigures.spokenText(server), "2 need attention, 1 member active, 3 worth a look")
        let local = [stat("attention", "Need attention", "1"), stat("representatives", "Members active", "2"), stat("quicklook", "Worth a look", "1")]
        XCTAssertEqual(WeeklyBriefFigures.spokenText(local), "1 needs attention, 2 members active, 1 worth a look")
        XCTAssertEqual(WeeklyBriefFigures.words(for: stat("representatives", "Reps active", "0")), "0 members active")
        XCTAssertEqual(WeeklyBriefFigures.words(for: stat("moved", "Moved this week", "4")), "4 Moved this week", "an unknown figure keeps the server's label")

        let frontPage = WeeklyBriefFrontPage(digest: digest)
        XCTAssertTrue(frontPage.accessibilityText.contains("2 need attention, 1 member active, 0 worth a look."), frontPage.accessibilityText)
        for text in [frontPage.accessibilityText, WeeklyBriefFigures.text(digest.stats) ?? "", AccessibilityTreeText.text(of: frontPage)] {
            XCTAssertNil(text.range(of: "\\breps?\\b", options: [.regularExpression, .caseInsensitive]), "the members' figure never says reps: \(text)")
        }
    }

    // MARK: - Weekly Brief detail (spec 4.52)

    /// The brief as a document in every variant: on the `document` ground, front matter, contents,
    /// sections and items.
    func testTheWeeklyBriefDocumentRendersInEveryVariant() throws {
        let members = ["K000384": try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D")]
        for variant in Self.variants {
            let view = WeeklyBriefDocument(digest: digest, members: members)
                .environmentObject(userStore)
                .background(BillboardColors.document)
            let image = try render(view, variant: variant)
            attach(image, name: "weekly-brief-detail-\(variant.name)")
            let ground = try pixel(of: image, x: 4, y: 4)
            let document = BillboardPalette.document.resolved(dark: variant.scheme == .dark).rgb
            XCTAssertEqual(ground.red, document.red, accuracy: 0.02, "\(variant.name): the document ground")
            XCTAssertEqual(ground.green, document.green, accuracy: 0.02, "\(variant.name): the document ground")
            XCTAssertEqual(ground.blue, document.blue, accuracy: 0.02, "\(variant.name): the document ground")
        }
    }

    /// A Weekly Brief item at AX5 on a 375 pt phone wraps in full: the item is at least as tall as its
    /// title and summary set in full at the document's width. The member item stacks its monogram above
    /// the name.
    func testAWeeklyBriefItemWrapsInFullAtAX5() throws {
        let width = Self.narrowWidth - 2 * BillboardStyle.Space.xl
        let item = digest.sections[0].items[1]
        let full = try height(of: Text(longTitle).textRole(.name), width: width, size: .accessibility5)
            + height(of: Text(longText).textRole(.prose), width: width, size: .accessibility5)
        let itemHeight = try height(of: WeeklyBriefItemView(item: item), width: width, size: .accessibility5)
        XCTAssertGreaterThanOrEqual(itemHeight, full, "the title and summary wrap in full at AX5")

        let members = ["K000384": try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D")]
        let items = VStack(alignment: .leading, spacing: 0) {
            WeeklyBriefItemView(item: item)
            HairlineRule()
            WeeklyBriefItemView(item: digest.sections[2].items[0], member: members["K000384"])
        }
        .padding(.horizontal, BillboardStyle.Space.xl)
        .background(BillboardColors.document)
        attach(try render(items, variant: Self.ax5, width: Self.narrowWidth), name: "weekly-brief-items-AX5")
    }

    /// The contents list only the sections that have items, in page order, each read as "Needs attention,
    /// 2 items" with the hint "Goes to the section"; the sections have sentence-case titles.
    func testTheContentsListTheSectionsWithItems() {
        let document = WeeklyBriefDocument(digest: digest)
        XCTAssertEqual(document.sections.map(\.kind), [.needsAttention, .movedThisWeek, .representatives])
        XCTAssertEqual(document.sections.map(\.displayTitle), ["Needs attention", "Moved this week", "Your representatives"])
        let text = AccessibilityTreeText.text(of: NavigationStack { document })
        XCTAssertTrue(text.contains("Needs attention, 2 items"), text)
        XCTAssertTrue(text.contains("Moved this week, 1 item"), text)
        XCTAssertTrue(text.contains("Your representatives, 1 item"), text)
        XCTAssertTrue(text.contains(WeeklyBriefContentsRow.accessibilityHint), text)
        XCTAssertFalse(text.contains("Worth a quick look"), "a section without items is not listed")
        XCTAssertFalse(text.contains("Needs Your Attention"), "the server's title case is not shown")
    }

    /// Each section's title is drawn under the double rule (the first) and is a header VoiceOver can be
    /// moved to: its focus target sits behind the title, since a view that carries `accessibilityFocused`
    /// is not drawn by ImageRenderer.
    func testTheSectionTitlesAreDrawnAndAreHeaders() throws {
        let image = try render(WeeklyBriefDocument(digest: digest).background(BillboardColors.document), variant: Self.variants[0])
        let bytes = try UpdatesRenderPixels.bytes(of: image)
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let i = (y * image.width + x) * 4
            return Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 3 * 110
        }
        // The double rule: the first rows inked from 20 pt to 370 pt; its thin rule is the last of them.
        let ruled = (0..<image.height).filter { y in (20..<370).allSatisfy { isInk($0, y) } }
        let ruleBottom = try XCTUnwrap(ruled.first.map { first in ruled.prefix { $0 <= first + 4 }.last! })
        // The title's capitals stand 16 pt under the rule, before the first item's docket line.
        let titleBand = (ruleBottom + 18)...(ruleBottom + 34)
        let inked = titleBand.reduce(0) { count, y in count + (20..<200).filter { isInk($0, y) }.count }
        XCTAssertGreaterThan(inked, 60, "the first section's title is drawn under the double rule")

        let host = AccessibilityTreeText.Host(NavigationStack { WeeklyBriefDocument(digest: digest) }, size: CGSize(width: 390, height: 3000))
        defer { host.close() }
        for title in ["Needs attention", "Moved this week", "Your representatives"] {
            XCTAssertEqual(host.traits(of: title)?.contains(.header), true, title)
        }
    }

    /// Tapping a contents row goes to its section.
    func testAContentsRowGoesToItsSection() {
        var target: WeeklyDigestSection.Kind?
        let host = AccessibilityTreeText.Host(NavigationStack {
            WeeklyBriefDocument(digest: digest, scrollToSection: { target = $0 })
        })
        defer { host.close() }
        XCTAssertTrue(host.activate("Moved this week, 1 item"))
        XCTAssertEqual(target, .movedThisWeek)
    }

    /// Items read their docket line, the date named for what it is with its month in full (the page shows
    /// "OCT 14"; spec 1.7) and their text, with their own "Open bill" or "View member" link; the week
    /// reads in words.
    func testItemsReadTheDateAloneAndHaveTheirLinks() throws {
        let members = ["K000384": try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D")]
        let text = AccessibilityTreeText.text(of: NavigationStack { WeeklyBriefDocument(digest: digest, members: members) }, size: CGSize(width: 390, height: 3000))
        XCTAssertTrue(text.contains("Rural Broadband Access Act of 2026. House bill 77. Updated. Last updated October 14. The Energy and Commerce Committee reported the bill to the full House. You voted on this before."), text)
        XCTAssertTrue(text.contains("Grid Modernization Act. House bill 405. Became law. Last updated October 9."), text)
        XCTAssertFalse(text.contains("Oct 14."), "the bare abbreviated date is not read on its own")
        XCTAssertTrue(text.contains("Open bill: Rural Broadband Access Act of 2026"), text)
        XCTAssertTrue(text.contains("Senator Tim Kaine, Democrat, Virginia. Backed 2 bills on topics you follow. Member you follow."), text)
        XCTAssertTrue(text.contains("View member: Tim Kaine"), text)
        XCTAssertTrue(text.contains("October 11 to 17, 2026"), text)
        XCTAssertFalse(text.contains("Updated Oct 14"), "the eyebrow's status word is dropped")
    }

    // MARK: - Search (spec 4.24 to 4.26)

    private var searchCounts: [BillsSearchList: Int] {
        [.watching: 4, .voted: 12, .passed: 7, .skipped: 3]
    }

    /// Search's lists as one roll sheet, in every variant and at AX5, with no tile colours: every pixel is
    /// a grey (ink, paper, sheet or rule).
    func testSearchListsRenderInEveryVariant() throws {
        for variant in Self.variants + [Self.ax5] {
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let view = VStack(alignment: .leading, spacing: BillsSearchLayout.headToContent) {
                SectionHeader("Your lists")
                BillsSearchListsSheet(counts: searchCounts) { _ in EmptyView() }
            }
            let image = try render(listPage(view), variant: variant, width: width)
            attach(image, name: "search-lists-\(variant.name)")
            XCTAssertLessThan(try largestColourSpread(in: image), 0.2, "\(variant.name): no tile colours")
        }
    }

    /// Each row reads its title, sub-line and count, and keeps R2's tile id.
    func testSearchListRowsReadTheirCountsAndKeepTheirIds() {
        let host = AccessibilityTreeText.Host(NavigationStack {
            BillsSearchListsSheet(counts: searchCounts, window: .twoWeeks) { _ in EmptyView() }
        })
        defer { host.close() }
        XCTAssertEqual(host.identifier(of: "Watching, Bills you watch, 4 bills"), "search.tile.watching")
        XCTAssertEqual(host.identifier(of: "Voted, Last 30 days, 12 bills"), "search.tile.voted")
        XCTAssertEqual(host.identifier(of: "Passed, Passed or became law, on your topics, 7 bills"), "search.tile.passed")
        XCTAssertEqual(host.identifier(of: "Skipped, From the last 2 weeks, 3 bills"), "search.tile.skipped")
        XCTAssertEqual(host.identifier(of: "Topics, Bills by topic group"), "search.tile.topics")
        XCTAssertEqual(host.identifier(of: "Life areas, Bills by part of life"), "search.tile.lifeAreas")
    }

    /// The results' head, results, no results, the Skipped list (with slips and empty) and an empty list,
    /// in every variant.
    func testSearchResultsAndListsRenderInEveryVariant() throws {
        let store = userStore
        let bills = [
            bill("BILLS-119hr3021ih", number: "3021", status: .new, title: "Veterans Housing Assistance Expansion"),
            bill("BILLS-119s10es", number: "10", type: "s", status: .passed, title: "Protecting Veterans Act")
        ]
        let skipped = bills.map { BillBoardItem(id: $0.id, bill: $0, date: today, type: .bill) }
        for variant in Self.variants {
            let view = VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: BillsSearchLayout.slipSpacing) {
                    BillsSearchResultsHeader(total: 2, shown: 2)
                    ForEach(bills) { BillCard(bill: $0) }
                }
                VStack(alignment: .leading, spacing: BillsSearchLayout.headToContent) {
                    SectionHeader("Search results")
                    BillsSearchNoResults(query: BillsSearch.Query("medicare dental")!)
                }
                SkippedBillsList(items: skipped) { _ in }
                SkippedBillsList(items: []) { _ in }
                BillCollectionList(list: .watching, bills: [])
                BillCollectionList(list: .passed, bills: [bills[1]])
            }
            .environmentObject(store)
            let image = try render(listPage(view), variant: variant)
            attach(image, name: "search-results-and-lists-\(variant.name)")
            XCTAssertGreaterThan(image.height, 800, variant.name)
        }
    }

    /// The results' counter: "2 of 2", "50 of 1,002" (capitals by style), read as R2's sentence.
    func testTheResultsCounter() {
        XCTAssertEqual(BillsSearchView.resultCounterText(total: 2, shown: 2), "2 of 2")
        XCTAssertEqual(BillsSearchView.resultCounterText(total: 1002, shown: 50), "50 of 1,002")
        let header = SectionHeader("Search results", trailing: .counter("50 of 1,002", spoken: BillsSearchView.resultCountText(total: 1002, shown: 50)))
        XCTAssertEqual(header.headerLabel, "Search results, Showing 50 of 1002 results")
        let text = AccessibilityTreeText.text(of: BillsSearchResultsHeader(total: 1002, shown: 50))
        XCTAssertTrue(text.contains("Search results, Showing 50 of 1002 results"), text)
    }

    /// The Skipped words follow the Bills tab's window: "From the last week", "From the last 2 weeks".
    func testTheSkippedWordsFollowTheWindow() {
        XCTAssertEqual(BillsSearchList.skipped.subtitle(window: .oneWeek), "From the last week")
        XCTAssertEqual(BillsSearchList.skipped.subtitle(window: .twoWeeks), "From the last 2 weeks")
        XCTAssertEqual(SkippedBillsList.emptyTitle(window: .oneWeek), "You haven't skipped any bills from the last week.")
        XCTAssertEqual(BillsSearchList.windowPhrase(BillboardHistoryWindow(rawValue: 10)), "10 days")
    }

    // MARK: - INT-11

    /// Nothing on these screens is another person's vote or a vote count (INT-11): the Brief's and
    /// Search's words count bills and items only.
    func testTheBriefAndSearchShowNoVoteCounts() throws {
        let members = ["K000384": try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D")]
        let texts = [
            AccessibilityTreeText.text(of: NavigationStack { WeeklyBriefDocument(digest: digest, members: members) }, size: CGSize(width: 390, height: 3000)),
            AccessibilityTreeText.text(of: WeeklyBriefFrontPage(digest: digest)),
            AccessibilityTreeText.text(of: NavigationStack { BillsSearchListsSheet(counts: searchCounts) { _ in EmptyView() } }),
            AccessibilityTreeText.text(of: VStack { UpdatesActionRow(alert: alert(), billNumber: "H.R. 77", now: today) })
        ]
        let voteCount = try NSRegularExpression(pattern: #"\b\d[\d,]*\s+(votes?|yeas?|nays?|abstain\w*)\b|\d+\s*%"#, options: [.caseInsensitive])
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(voteCount.firstMatch(in: text, range: range), "no vote count in: \(text)")
        }
    }

    // MARK: - Helpers

    /// The real Updates tab in a navigation stack, hosted in a window on the screen with fake stores: the
    /// Weekly Brief (unread or read), Recent actions with a link and a button row, and a Passed and a
    /// Failed bill. `isActive` is false, so nothing loads or asks for push permission.
    private func updatesHost(briefIsRead: Bool, size: CGSize, scene: UIWindowScene) throws -> AccessibilityTreeText.Host {
        let scope = "updates-hosted-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: scope))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: scope) }
        var brief = digest
        brief.isRead = briefIsRead
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(brief), forKey: "BillBoard.weeklyDigest.v1.digest.\(scope)")
        let digestStore = WeeklyDigestStore(
            scope: scope,
            defaults: defaults,
            digestService: EmptyWeeklyDigestService(),
            billsService: FakeBillsService(),
            votesService: FakeBillVotesService(),
            congressService: FakeCongressService()
        )
        XCTAssertNotNil(digestStore.digest, "the brief is on Updates")

        let bills = [
            bill("BILLS-119hr77ih", number: "77", status: .updated, title: "Rural Broadband Access Act of 2026", priority: true),
            bill("BILLS-119hr405eh", number: "405", status: .passed, title: "Grid Modernization Act", priority: true),
            bill("BILLS-119s12is", number: "12", type: "s", status: .failed, title: "Senate Rules Reform Act", priority: true)
        ]
        let buttonRow = alert(title: "Coast Guard Authorization Act", text: "Placed on the Union Calendar.", actionDate: nil, topic: nil, billID: nil)
        let billsStore = BillsStore(bills: bills, cacheScope: scope, service: FakeBillsService(), preferencesService: FakePreferencesService())
        let voteStore = BillVoteStore(cache: BillVoteCache(config: BillVoteCache.Config(persistenceKey: nil)), service: FakeBillVotesService())
        billsStore.connect(voteStore: voteStore)
        let view = NavigationStack { NotificationsView(isActive: false) }
            .environmentObject(BillAlertsStore(alerts: [alert(), buttonRow]))
            .environmentObject(billsStore)
            .environmentObject(AppReadState(scope: .user(scope), store: InMemoryReadStateStore()))
            .environmentObject(AppState())
            .environmentObject(userStore)
            .environmentObject(CivicScoreStore(scope: scope, userDefaults: defaults, service: FakeCivicService()))
            .environmentObject(voteStore)
            .environmentObject(digestStore)
        return AccessibilityTreeText.Host(view, size: size, settle: 1.0, scene: scene)
    }

    /// The window as drawn on the screen, at `scale` pixels per point.
    private func drawnWindow(_ window: UIWindow, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.cgImage
    }

    /// The widest run of pixels that differ from the ground, on any one pixel row inside `rows` (a frame in
    /// points), in pixels. The ground is the row's colour at its leading edge.
    private func widestInkRun(in bytes: [UInt8], width: Int, rows frame: CGRect, scale: CGFloat) -> CGFloat {
        let top = Int((frame.minY * scale).rounded(.up))
        let bottom = min(Int((frame.maxY * scale).rounded(.down)), bytes.count / (width * 4))
        var widest = 0
        for y in top..<bottom {
            let ground = (y * width + 2) * 4
            var run = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                let difference = (0..<3).reduce(0) { $0 + abs(Int(bytes[i + $1]) - Int(bytes[ground + $1])) }
                run = difference > 12 ? run + 1 : 0
                widest = max(widest, run)
            }
        }
        return CGFloat(widest)
    }

    /// The view on paper in the 16 pt list gutter.
    private func listPage<Content: View>(_ content: Content) -> some View {
        content
            .padding(.horizontal, UpdatesLayout.gutter)
            .padding(.vertical, 16)
            .background(BillboardColors.background)
    }

    /// The height a view takes at `width` and a Dynamic Type size, in points.
    private func height<Content: View>(of view: Content, width: CGFloat, size: DynamicTypeSize) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environmentObject(userStore)
                .environment(\.dynamicTypeSize, size)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        return CGFloat(image.height)
    }

    private func render<Content: View>(_ view: Content, variant: Variant, width: CGFloat = 390) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
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

    /// The largest difference between a pixel's strongest and weakest channel: near 0 for greys, large
    /// for a colour (teal, gold, a tile tint).
    private func largestColourSpread(in image: CGImage) throws -> Double {
        let bytes = try UpdatesRenderPixels.bytes(of: image)
        var largest = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let channels = [bytes[i], bytes[i + 1], bytes[i + 2]]
            largest = max(largest, Int(channels.max()!) - Int(channels.min()!))
        }
        return Double(largest) / 255
    }

    /// The sRGB colour of one pixel, `x` and `y` from the top left.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> BillboardColorMath.RGB {
        let bytes = try UpdatesRenderPixels.bytes(of: image)
        let i = (y * image.width + x) * 4
        return (red: Double(bytes[i]) / 255, green: Double(bytes[i + 1]) / 255, blue: Double(bytes[i + 2]) / 255)
    }
}

/// An image's pixels as sRGB bytes (RGBA, row by row from the top), read once, for the Updates, Weekly
/// Brief and Search render tests.
@MainActor
enum UpdatesRenderPixels {
    static func bytes(of image: CGImage) throws -> [UInt8] {
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
        return bytes
    }
}
