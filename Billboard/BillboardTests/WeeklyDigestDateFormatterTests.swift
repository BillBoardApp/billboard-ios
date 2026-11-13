import XCTest
@testable import Billboard

/// The Weekly Brief's dates (Civic Record spec 3.26, 4.52): every range comes from the digest's
/// `weekStart` and `weekEnd` in Eastern time, with an en dash, for a week inside one month, a week
/// across two months and a week across two years. And the detail's item eyebrows keep the date only, which
/// VoiceOver reads as "Last updated October 14".
final class WeeklyDigestDateFormatterTests: XCTestCase {
    /// Midnight Eastern, as the digest's `weekStart` and `weekEnd` are ("2026-10-11T00:00:00-04:00").
    private func eastern(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return WeeklyDigestSchedule.calendar.date(from: components)!
    }

    // MARK: - A week inside one month

    func testAWeekInsideOneMonth() {
        let start = eastern(2026, 10, 11)
        let end = eastern(2026, 10, 17)
        XCTAssertEqual(WeeklyDigestDateFormatter.rangeString(start: start, end: end), "Oct 11\u{2013}17, 2026")
        XCTAssertEqual(WeeklyDigestDateFormatter.shortRangeString(start: start, end: end), "Oct 11\u{2013}17")
        XCTAssertEqual(WeeklyDigestDateFormatter.longRangeString(start: start, end: end), "October 11\u{2013}17, 2026")
        XCTAssertEqual(WeeklyDigestDateFormatter.longRangeString(start: start, end: end, includesYear: false), "October 11\u{2013}17")
        XCTAssertEqual(WeeklyDigestDateFormatter.spokenRangeString(start: start, end: end), "October 11 to 17, 2026")
    }

    // MARK: - A week across two months

    func testAWeekAcrossTwoMonths() {
        let start = eastern(2026, 9, 27)
        let end = eastern(2026, 10, 3)
        XCTAssertEqual(WeeklyDigestDateFormatter.rangeString(start: start, end: end), "Sep 27\u{2013}Oct 3, 2026")
        XCTAssertEqual(WeeklyDigestDateFormatter.shortRangeString(start: start, end: end), "Sep 27\u{2013}Oct 3")
        XCTAssertEqual(WeeklyDigestDateFormatter.longRangeString(start: start, end: end), "September 27\u{2013}October 3, 2026")
        XCTAssertEqual(WeeklyDigestDateFormatter.longRangeString(start: start, end: end, includesYear: false), "September 27\u{2013}October 3")
        XCTAssertEqual(WeeklyDigestDateFormatter.spokenRangeString(start: start, end: end), "September 27 to October 3, 2026")
    }

    // MARK: - A week across two years

    func testAWeekAcrossTwoYears() {
        let start = eastern(2026, 12, 27)
        let end = eastern(2027, 1, 2)
        XCTAssertEqual(WeeklyDigestDateFormatter.rangeString(start: start, end: end), "Dec 27, 2026\u{2013}Jan 2, 2027")
        XCTAssertEqual(WeeklyDigestDateFormatter.shortRangeString(start: start, end: end), "Dec 27\u{2013}Jan 2")
        XCTAssertEqual(WeeklyDigestDateFormatter.longRangeString(start: start, end: end), "December 27, 2026\u{2013}January 2, 2027")
        XCTAssertEqual(WeeklyDigestDateFormatter.longRangeString(start: start, end: end, includesYear: false), "December 27\u{2013}January 2")
        XCTAssertEqual(WeeklyDigestDateFormatter.spokenRangeString(start: start, end: end), "December 27, 2026 to January 2, 2027")
    }

    // MARK: - Eastern time

    /// The days are Eastern days wherever the phone is: Saturday 00:00 in New York is still Friday on the
    /// west coast and already Saturday in London; the range says the 17th either way.
    func testTheRangeIsReadInEasternTime() throws {
        let start = try XCTUnwrap(FlexibleISO8601.parse("2026-10-11T00:00:00-04:00"))
        let end = try XCTUnwrap(FlexibleISO8601.parse("2026-10-17T00:00:00-04:00"))
        XCTAssertEqual(WeeklyDigestDateFormatter.shortRangeString(start: start, end: end), "Oct 11\u{2013}17")
        // A late-evening Eastern time is still that day, though it is the next day in UTC.
        XCTAssertEqual(
            WeeklyDigestDateFormatter.shortRangeString(start: eastern(2026, 10, 11, hour: 23), end: eastern(2026, 10, 17, hour: 23)),
            "Oct 11\u{2013}17"
        )
    }

    /// The local fallback's title and the push text use the same range, so they have the en dash too.
    func testTheFallbackTitleUsesTheSameRange() {
        XCTAssertEqual(
            WeeklyDigestDateFormatter.title(weekStart: eastern(2026, 3, 15), weekEnd: eastern(2026, 3, 21)),
            "Your Week in Congress | Mar 15\u{2013}21, 2026"
        )
    }

    // MARK: - Item eyebrows (spec 4.52)

    private func item(kind: WeeklyDigestItem.Kind = .bill, eyebrow: String?, state: WeeklyDigestItem.BillState? = .updated) -> WeeklyDigestItem {
        WeeklyDigestItem(
            id: "item",
            kind: kind,
            title: "Rural Broadband Access Act of 2026",
            eyebrow: eyebrow,
            summary: "Reported to the full House.",
            detail: nil,
            reason: nil,
            accent: .attention,
            billState: kind == .bill ? state : nil,
            billGuid: kind == .bill ? "BILLS-119hr77ih" : nil,
            primaryMemberBioguideID: kind == .member ? "K000384" : nil
        )
    }

    /// A bill item's eyebrow is the date alone: the stamp on its docket line already says the status.
    func testABillItemsEyebrowKeepsTheDateOnly() {
        XCTAssertEqual(item(eyebrow: "Updated Oct 14").dateEyebrow, "Oct 14")
        XCTAssertEqual(item(eyebrow: "Became law Oct 9", state: .finalized).dateEyebrow, "Oct 9")
        XCTAssertEqual(item(eyebrow: "Finalized Oct 9", state: .finalized).dateEyebrow, "Oct 9", "the server's word for Became law")
        XCTAssertEqual(item(eyebrow: "New Mar 20", state: .new).dateEyebrow, "Mar 20")
        XCTAssertEqual(item(eyebrow: "passed Oct 2", state: .passed).dateEyebrow, "Oct 2")
        XCTAssertEqual(item(eyebrow: "Failed · Oct 3", state: .failed).dateEyebrow, "Oct 3")
        XCTAssertEqual(item(eyebrow: "Oct 14").dateEyebrow, "Oct 14", "an eyebrow that is already a date stays")
        XCTAssertNil(item(eyebrow: "Updated").dateEyebrow, "a status word alone leaves nothing")
        XCTAssertNil(item(eyebrow: nil).dateEyebrow)
        XCTAssertNil(item(eyebrow: "  ").dateEyebrow)
        XCTAssertEqual(item(eyebrow: "Newly reported Oct 14").dateEyebrow, "Newly reported Oct 14", "only a whole status word is dropped")
    }

    /// VoiceOver reads a bill item's date named for what it is, with its month in full (spec 1.7, 7.3):
    /// "Last updated October 14", as a slip reads its date. An eyebrow that is not a date is read as written.
    func testABillItemsDateIsReadAsLastUpdatedWithTheMonthInFull() {
        XCTAssertEqual(item(eyebrow: "Updated Oct 14").spokenDateEyebrow, "Last updated October 14")
        XCTAssertEqual(item(eyebrow: "Finalized Oct 9", state: .finalized).spokenDateEyebrow, "Last updated October 9")
        XCTAssertEqual(item(eyebrow: "New May 1", state: .new).spokenDateEyebrow, "Last updated May 1")
        XCTAssertEqual(item(eyebrow: "Passed Sept 3", state: .passed).spokenDateEyebrow, "Last updated September 3")
        XCTAssertEqual(item(eyebrow: "Updated Dec 30, 2025").spokenDateEyebrow, "Last updated December 30, 2025")
        XCTAssertEqual(item(eyebrow: "Jun 2").spokenDateEyebrow, "Last updated June 2")
        XCTAssertEqual(item(eyebrow: "Newly reported Oct 14").spokenDateEyebrow, "Newly reported Oct 14", "not a date: read as written")
        XCTAssertEqual(item(eyebrow: "Updated Oct 40").spokenDateEyebrow, "Oct 40", "not a day: read as written")
        XCTAssertNil(item(eyebrow: "Updated").spokenDateEyebrow)
        XCTAssertNil(item(kind: .member, eyebrow: "2 relevant bills this week").spokenDateEyebrow)
        XCTAssertNil(WeeklyDigestDateFormatter.spokenMonthDay("Ma 4"), "too short to name a month")
    }

    /// A member item's eyebrow is a count its summary already says, so it has none.
    func testAMemberItemHasNoEyebrow() {
        XCTAssertNil(item(kind: .member, eyebrow: "2 relevant bills this week").dateEyebrow)
    }

    /// The docket line's number comes from the item's guid; a member item has none.
    func testABillItemsNumberAndStatusComeFromItsGuidAndState() {
        XCTAssertEqual(item(eyebrow: nil).billNumber, "H.R. 77")
        XCTAssertNil(item(kind: .member, eyebrow: nil).billNumber)
        XCTAssertEqual(WeeklyDigestItem.BillState.finalized.billStatus, .finalized)
        XCTAssertEqual(WeeklyDigestItem.BillState.updated.billStatus, .updated)
    }
}
