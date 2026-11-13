import XCTest
@testable import Billboard

/// The text and the "Show more" amount of Bills search when it caps the results it lays out.
@MainActor
final class BillsSearchResultsTests: XCTestCase {
    func testTheCountNamesEveryResultWhenAllAreShown() {
        XCTAssertEqual(BillsSearchView.resultCountText(total: 1, shown: 1), "1 result")
        XCTAssertEqual(BillsSearchView.resultCountText(total: 12, shown: 12), "12 results")
        XCTAssertEqual(BillsSearchView.resultCountText(total: 50, shown: 50), "50 results")
    }

    func testACappedListSaysHowManyOfTheMatchesAreShown() {
        XCTAssertEqual(BillsSearchView.resultCountText(total: 1002, shown: 50), "Showing 50 of 1002 results")
        XCTAssertEqual(BillsSearchView.resultCountText(total: 51, shown: 50), "Showing 50 of 51 results")
    }

    func testShowMoreAddsAPageOrWhatIsLeft() {
        XCTAssertEqual(BillsSearchView.moreResultsCount(total: 1002, shown: 50), 50)
        XCTAssertEqual(BillsSearchView.moreResultsCount(total: 60, shown: 50), 10)
        XCTAssertEqual(BillsSearchView.moreResultsCount(total: 51, shown: 50), 1)
        XCTAssertEqual(BillsSearchView.moreResultsCount(total: 50, shown: 50), 0)
        XCTAssertEqual(BillsSearchView.moreResultsCount(total: 10, shown: 10), 0)
    }
}
