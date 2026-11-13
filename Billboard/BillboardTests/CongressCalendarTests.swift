import Foundation
import XCTest
@testable import Billboard

/// The Congress and session a date falls in (Civic Record spec 3.21): computed in Washington's time
/// zone, rolling over on January 3 of each year (a new Congress in odd years).
final class CongressCalendarTests: XCTestCase {
    /// A wall-clock time in America/New_York.
    private func newYork(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    func testTheSpecDates() throws {
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2026, 10, 17)), .init(congress: 119, session: 2))
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2027, 1, 3)), .init(congress: 120, session: 1))
    }

    /// Either side of January 3, 2027, when the 120th Congress meets.
    func testTheNewCongressStartsOnJanuaryThird2027() throws {
        let before: [Date] = [
            try newYork(2026, 12, 31, 23, 59),
            try newYork(2027, 1, 1, 0, 0),
            try newYork(2027, 1, 2, 12, 0),
            try newYork(2027, 1, 2, 23, 59)
        ]
        for date in before {
            XCTAssertEqual(CongressCalendar.session(on: date), .init(congress: 119, session: 2), "\(date)")
        }
        let after: [Date] = [
            try newYork(2027, 1, 3, 0, 0),
            try newYork(2027, 1, 3, 12, 0),
            try newYork(2027, 1, 4, 9, 0),
            try newYork(2027, 6, 30),
            try newYork(2027, 12, 31, 23, 59),
            try newYork(2028, 1, 2, 23, 59)
        ]
        for date in after {
            XCTAssertEqual(CongressCalendar.session(on: date), .init(congress: 120, session: 1), "\(date)")
        }
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2028, 1, 3)), .init(congress: 120, session: 2))
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2029, 1, 3)), .init(congress: 121, session: 1))
    }

    /// The calendar is Washington's, whatever the device's time zone: 03:00 UTC on January 3 is still
    /// the evening of January 2 in New York, and 05:00 UTC is midnight there.
    func testTheDateIsTakenInNewYork() throws {
        XCTAssertEqual(CongressCalendar.session(on: try utc(2027, 1, 3, 3)), .init(congress: 119, session: 2))
        XCTAssertEqual(CongressCalendar.session(on: try utc(2027, 1, 3, 5)), .init(congress: 120, session: 1))
    }

    func testEarlierCongresses() throws {
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2025, 1, 2)), .init(congress: 118, session: 2))
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2025, 1, 3)), .init(congress: 119, session: 1))
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2026, 1, 2)), .init(congress: 119, session: 1))
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2026, 1, 3)), .init(congress: 119, session: 2))
        XCTAssertEqual(CongressCalendar.session(on: try newYork(2021, 3, 1)), .init(congress: 117, session: 1))
        XCTAssertEqual(CongressCalendar.session(on: try newYork(1790, 6, 1)), .init(congress: 1, session: 2))
    }

    func testTitles() {
        let session = CongressCalendar.Session(congress: 119, session: 2)
        XCTAssertEqual(session.congressTitle, "119th Congress")
        XCTAssertEqual(session.sessionTitle, "2nd session")
        XCTAssertEqual(session.title, "119th Congress · 2nd session")
        XCTAssertEqual(session.spokenTitle, "119th Congress, 2nd session")
        XCTAssertEqual(CongressCalendar.Session(congress: 120, session: 1).title, "120th Congress · 1st session")
        XCTAssertEqual(CongressCalendar.Session(congress: 121, session: 1).congressTitle, "121st Congress")
    }

    /// The Bills masthead's dateline (spec 3.21): the reader's own date, and the Congress and session.
    func testTheMastheadDatelineForTheSpecDate() throws {
        let newYorkZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let dateline = MastheadDateline(date: try newYork(2026, 10, 17), locale: Locale(identifier: "en_US"), timeZone: newYorkZone)
        XCTAssertEqual(dateline.date, "Sat, Oct 17, 2026")
        XCTAssertEqual(dateline.spokenDate, "Saturday, October 17, 2026")
        XCTAssertEqual(dateline.session, "119th Congress\u{00A0}· 2nd session", "a dot never starts a wrapped line")
        XCTAssertEqual(dateline.spokenText, "Saturday, October 17, 2026. 119th Congress, 2nd session.")
    }

    /// The date is the reader's calendar day, the session Washington's: late on January 2, 2027 in
    /// California is already January 3 in Washington, so the 120th Congress has met.
    func testTheMastheadDatelineUsesTheReadersDayAndWashingtonsSession() throws {
        let california = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let dateline = MastheadDateline(date: try utc(2027, 1, 3, 6), locale: Locale(identifier: "en_US"), timeZone: california)
        XCTAssertEqual(dateline.date, "Sat, Jan 2, 2027")
        XCTAssertEqual(dateline.session, "120th Congress\u{00A0}· 1st session")
    }
}
