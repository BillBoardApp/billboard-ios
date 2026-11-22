import SwiftUI
import XCTest
@testable import Billboard

/// REL-46: a bill of an earlier Congress than the one in office prints its Congress on its docket line, after the
/// chamber ("H.R. 1 · HOUSE · 119TH", the website's order), and VoiceOver reads it ("House bill 1, 119th Congress").
/// A bill of the Congress in office stays as it is. The Congress in office turns over at noon Eastern on January 3,
/// 2027 (17:00 UTC). Search lists the Congress in office's bills first.
@MainActor
final class OlderCongressTagTests: XCTestCase {
    private static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static let beforeNoon = at("2027-01-03T16:59:00Z")
    private static let noon = at("2027-01-03T17:00:00Z")

    private func bill(_ guid: String, _ status: BillStatus = .new, title: String = "A bill") -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            billStatus: status,
            guid: guid,
            userVoted: false
        )
    }

    // MARK: - Docket lines

    func testTheDocketLineReadsTheCongressAfterTheNumbers() {
        XCTAssertEqual(DocketLine(number: "H.R. 1", status: .new, congressTag: "119th").accessibilityText, "House bill 1, 119th Congress. New.")
        XCTAssertEqual(DocketLine(number: "H.R. 1", status: .new).accessibilityText, "House bill 1. New.", "a current bill is unchanged")
        XCTAssertEqual(
            DocketLine(numbers: ["H.R. 10", "S. 10"], chamber: nil, status: .updated, endedCongress: 119, congressTag: "119th").accessibilityText,
            "House bill 10 and Senate bill 10, 119th Congress. Ended with the 119th Congress."
        )
        XCTAssertEqual(DocketLine(numbers: [], chamber: nil, status: .failed, congressTag: "119th").accessibilityText, "Failed.", "no number, no Congress")
        let strings = AccessibilityTreeText.strings(of: DocketLine(number: "H.R. 1", status: .passed, congressTag: "119th"))
        XCTAssertEqual(strings, ["House bill 1, 119th Congress. Passed."], "one element")
    }

    /// The tag is printed in the docket role's capitals after the chamber, and the line still fits or stacks.
    func testTheTaggedDocketLineRendersAndStacksAtAX5() throws {
        let tagged = DocketLine(number: "H.R. 4521", status: .updated, endedCongress: 119, congressTag: "119th")
        let plain = DocketLine(number: "H.R. 4521", status: .updated)
        let largeTagged = try height(of: tagged, size: .large)
        let largePlain = try height(of: plain, size: .large)
        XCTAssertGreaterThan(largeTagged, largePlain, "the long stamp goes under the numbers at 375 pt")
        let ax5 = try height(of: tagged, size: .accessibility5)
        XCTAssertGreaterThan(ax5, largeTagged * 2, "it grows and wraps at AX5")
        let numbersOnly = DocketLine(number: "H.R. 4521", status: nil, congressTag: "119th")
        XCTAssertEqual(try height(of: numbersOnly, size: .large), try height(of: DocketLine(number: "H.R. 4521", status: nil), size: .large), "the tag fits on the line")
    }

    private func height<Content: View>(of view: Content, size: DynamicTypeSize, width: CGFloat = 375) throws -> Int {
        let renderer = ImageRenderer(content: view.background(BillboardColors.cardBackground).environment(\.dynamicTypeSize, size))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.cgImage).height
    }

    // MARK: - Surfaces

    func testSlipsAndTheBillPageCarryTheTagOnlyForOlderBills() {
        let profile = UserProfile.placeholder()
        let old = bill("BILLS-119hr1", .updated, title: "Clean Energy Reporting Act")
        let current = bill("BILLS-120hr1", .new)

        let before = BillSlipContent(bill: old, profile: profile, now: Self.beforeNoon)
        XCTAssertNil(before.congressTag)
        let after = BillSlipContent(bill: old, profile: profile, now: Self.noon)
        XCTAssertEqual(after.congressTag, "119th")
        XCTAssertTrue(
            after.accessibilityLabel().hasPrefix("Clean Energy Reporting Act. House bill 1, 119th Congress. Ended with the 119th Congress."),
            after.accessibilityLabel()
        )
        XCTAssertNil(BillSlipContent(bill: current, profile: profile, now: Self.noon).congressTag)

        XCTAssertEqual(BillFrontMatter.Content(bill: old, now: Self.noon).congressTag, "119th")
        XCTAssertNil(BillFrontMatter.Content(bill: current, now: Self.noon).congressTag)
        XCTAssertNil(BillFrontMatter.Content(bill: old).congressTag, "the tests' clock is in the 119th Congress")
    }

    func testUpdatesAndTheWeeklyBriefSayTheCongress() {
        let old = bill("BILLS-119hr77", .passed)
        XCTAssertTrue(UpdatesOutcomeRow(bill: old, now: Self.noon).accessibilityText.contains("House bill 77, 119th Congress. Passed."))
        XCTAssertTrue(UpdatesOutcomeRow(bill: old, now: Self.beforeNoon).accessibilityText.contains("House bill 77. Passed."))

        let alert = BillAlert(
            id: UUID(), sponsorMemberID: nil, billID: old.id, title: "Rural Broadband Access Act", category: "Bills",
            summary: "Reported by the Committee on Energy and Commerce.", soWhat: "", lifeAreas: [], subCategory: "Technology",
            alertText: nil, actionDate: "2027-01-05", actionCode: nil, actionType: nil, date: Self.noon
        )
        let row = UpdatesActionRow(alert: alert, billNumber: "H.R. 77", congressTag: old.olderCongressTag(at: Self.noon), now: Self.noon)
        XCTAssertTrue(row.accessibilityText.contains("House bill 77, 119th Congress."), row.accessibilityText)

        let item = WeeklyDigestItem(
            id: "bill|BILLS-119hr77", kind: .bill, title: "A bill", eyebrow: "Passed Jan 8", summary: "A summary.",
            detail: nil, reason: nil, accent: .attention, billState: .passed, billGuid: "BILLS-119hr77",
            primaryMemberBioguideID: nil
        )
        XCTAssertEqual(item.olderCongressTag(at: Self.noon), "119th")
        XCTAssertNil(item.olderCongressTag(at: Self.beforeNoon))
        XCTAssertTrue(WeeklyBriefItemView(item: item, now: Self.noon).accessibilityText.contains("House bill 77, 119th Congress. Passed."))
    }

    func testPutBackSaysTheCongress() {
        let old = bill("BILLS-119hr5")
        let item = BillBoardItem(id: old.id, bill: old, date: Date(), type: .bill)
        XCTAssertEqual(SkippedBillsList.putBackLabel(for: item, now: Self.noon), "Put back House bill 5, 119th Congress")
        XCTAssertEqual(SkippedBillsList.putBackLabel(for: item, now: Self.beforeNoon), "Put back House bill 5")
    }

    // MARK: - Search

    private func search(_ text: String, in bills: [Bill], currentCongress: Int) -> [String] {
        guard let query = BillsSearch.Query(text) else { return [] }
        return BillsSearch.results(in: bills, query: query, companions: .empty, currentCongress: currentCongress).compactMap(\.guid)
    }

    /// "H.R. 1" lists the Congress in office's H.R. 1 first, then the older one; the order is stable otherwise.
    func testSearchListsTheCongressInOfficesBillsFirst() {
        let bills = [
            bill("BILLS-119hr1", title: "Older bill one"),
            bill("BILLS-119s7", title: "Mentions H.R. 1 in passing"),
            bill("BILLS-120hr1", title: "Newer bill one"),
            bill("BILLS-120s8", title: "Also mentions H.R. 1")
        ]
        XCTAssertEqual(search("H.R. 1", in: bills, currentCongress: 120), ["BILLS-120hr1", "BILLS-119hr1", "BILLS-120s8", "BILLS-119s7"])
        XCTAssertEqual(search("H.R. 1", in: bills, currentCongress: 119), ["BILLS-119hr1", "BILLS-120hr1", "BILLS-119s7", "BILLS-120s8"], "before: as given")

        let words = [bill("BILLS-119hr2", title: "Rural broadband"), bill("BILLS-119hr3", title: "Broadband maps"), bill("BILLS-120hr4", title: "Broadband grants")]
        XCTAssertEqual(search("broadband", in: words, currentCongress: 120), ["BILLS-120hr4", "BILLS-119hr2", "BILLS-119hr3"], "stable within each Congress")
        XCTAssertEqual(search("broadband", in: words, currentCongress: 119), ["BILLS-119hr2", "BILLS-119hr3", "BILLS-120hr4"])
    }
}
