import XCTest
@testable import Billboard

/// The spoken forms of the codes the docket face prints (Civic Record spec 1.7): district codes, bill
/// numbers and ordinals.
@MainActor
final class SpokenFormTests: XCTestCase {
    /// Every VoiceOver label built from parts ends each part once, whatever mark the part ends with
    /// (`SpokenSentences`): a slip whose title ends in "?" reads "Should Congress act? House bill 1.", as an
    /// Updates row does, not "Should Congress act?." (the slip's copy checked only ".").
    func testSpokenSentencesEndEachPartOnce() {
        XCTAssertEqual(
            SpokenSentences.join(["Is it fair?", "Yes!", "Opening results…", "Done.", "  Plain  ", nil, " "]),
            "Is it fair? Yes! Opening results… Done. Plain."
        )
        XCTAssertEqual(SpokenSentences.sentence("Passed"), "Passed.")
        XCTAssertEqual(SpokenSentences.join([]), "")

        let title = "Should Congress act?"
        let slip = BillSlipContent(title: title, numbers: ["H.R. 1"], status: .new, tags: [], sponsor: nil, lastUpdated: nil)
        XCTAssertTrue(slip.accessibilityLabel().hasPrefix("Should Congress act? House bill 1."), slip.accessibilityLabel())
        XCTAssertEqual(
            RecordNotice(.nothingYet, title: "Nothing to vote on?", message: "Check back soon!").accessibilityText,
            "\(StatusStamp.Kind.nothingYet.spokenWord). Nothing to vote on? Check back soon!"
        )
    }

    func testOrdinals() {
        let cases: [(Int, String)] = [
            (1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (9, "9th"), (10, "10th"),
            (11, "11th"), (12, "12th"), (13, "13th"), (14, "14th"),
            (21, "21st"), (22, "22nd"), (23, "23rd"), (52, "52nd"),
            (101, "101st"), (111, "111th"), (112, "112th"), (113, "113th"), (119, "119th"), (120, "120th"), (121, "121st")
        ]
        for (number, expected) in cases {
            XCTAssertEqual(SpokenForm.ordinal(number), expected)
        }
    }

    func testDistrictCodes() {
        let cases: [(String, String)] = [
            ("VA-11", "Virginia's 11th district"),
            ("VA-01", "Virginia's 1st district"),
            ("va-1", "Virginia's 1st district"),
            ("CA-52", "California's 52nd district"),
            ("TX-7", "Texas's 7th district"),
            ("NY-13", "New York's 13th district"),
            ("NC-02", "North Carolina's 2nd district"),
            ("FL-23", "Florida's 23rd district"),
            ("VA 11", "Virginia's 11th district"),
            (" VA-11 ", "Virginia's 11th district")
        ]
        for (code, expected) in cases {
            XCTAssertEqual(SpokenForm.district(code), expected, code)
        }
    }

    /// The forms an at-large seat comes in across the app: "AK-AL", the label "AK-At-Large", and
    /// district 0 or 00.
    func testAtLargeDistricts() {
        for code in ["AK-AL", "AK-At-Large", "ak-at-large", "AK-00", "AK-0", "AK AL", "AK at-large"] {
            XCTAssertEqual(SpokenForm.district(code), "Alaska's at-large district", code)
        }
        XCTAssertEqual(SpokenForm.district("DC-AL"), "District of Columbia's at-large district")
        XCTAssertEqual(SpokenForm.district("PR-00"), "Puerto Rico's at-large district")
    }

    /// Every delegate's seat reads as a possessive that is said right: a plural place name ("U.S. Virgin
    /// Islands", "Northern Mariana Islands") takes the apostrophe alone, as "U.S. Virgin Islands's" is not
    /// English; a singular name ending in "s" keeps "'s" ("Texas's", "Illinois's", "Massachusetts's").
    func testAPluralPlaceTakesTheApostropheAlone() {
        let delegates: [(String, String)] = [
            ("VI-AL", "U.S. Virgin Islands' at-large district"),
            ("VI-00", "U.S. Virgin Islands' at-large district"),
            ("MP-AL", "Northern Mariana Islands' at-large district"),
            ("MP-0", "Northern Mariana Islands' at-large district"),
            ("GU-AL", "Guam's at-large district"),
            ("AS-AL", "American Samoa's at-large district"),
            ("PR-AL", "Puerto Rico's at-large district"),
            ("DC-AL", "District of Columbia's at-large district")
        ]
        for (code, expected) in delegates {
            XCTAssertEqual(SpokenForm.district(code), expected, code)
        }
        XCTAssertEqual(SpokenForm.district("TX-7"), "Texas's 7th district")
        XCTAssertEqual(SpokenForm.district("IL-13"), "Illinois's 13th district")
        XCTAssertEqual(SpokenForm.district("MA-4"), "Massachusetts's 4th district")
        XCTAssertEqual(SpokenForm.district("VI"), "U.S. Virgin Islands", "a place alone is not a possessive")
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Stacey Plaskett", party: .democratic, state: "VI", district: "0", chamber: .house),
            "Representative Stacey Plaskett, Democrat, U.S. Virgin Islands' at-large district"
        )
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Kimberlyn King-Hinds", party: .republican, state: "MP", district: "At-Large", chamber: .house),
            "Representative Kimberlyn King-Hinds, Republican, Northern Mariana Islands' at-large district"
        )
    }

    func testAStateAloneIsItsName() {
        XCTAssertEqual(SpokenForm.district("VA"), "Virginia")
        XCTAssertEqual(SpokenForm.district("dc"), "District of Columbia")
        XCTAssertEqual(SpokenForm.district("VI"), "U.S. Virgin Islands")
    }

    func testCodesWithoutASpokenForm() {
        for code in ["", "V", "ZZ-11", "VA-", "VA-X", "VA11", "Virginia", "VA-11-2"] {
            XCTAssertNil(SpokenForm.district(code), code)
        }
        XCTAssertEqual(SpokenForm.districtOrCode("ZZ-11"), "ZZ-11")
        XCTAssertEqual(SpokenForm.districtOrCode("VA-11"), "Virginia's 11th district")
    }

    /// One state table serves the Congress tab, the Results lines and the spoken forms.
    func testStateNamesComeFromOneTable() {
        XCTAssertEqual(USStateNames.name(forPostalCode: "va"), "Virginia")
        XCTAssertEqual(CongressTabModel.stateName(for: "VA"), "Virginia")
        XCTAssertEqual(VoteResultsFormatting.stateName("VA"), "Virginia")
        XCTAssertNil(USStateNames.name(forPostalCode: "ZZ"))
        for code in ["AL", "AK", "WY", "DC", "PR", "GU", "VI", "AS", "MP"] {
            XCTAssertEqual(CongressTabModel.stateName(for: code), USStateNames.name(forPostalCode: code), code)
            XCTAssertEqual(VoteResultsFormatting.stateName(code), USStateNames.name(forPostalCode: code), code)
        }
    }

    func testBillNumbers() {
        let cases: [(String, String)] = [
            ("H.R. 1234", "House bill 1234"),
            ("S. 456", "Senate bill 456"),
            ("H.Res. 5", "House resolution 5"),
            ("S.Res. 12", "Senate resolution 12"),
            ("H.J.Res. 7", "House joint resolution 7"),
            ("S.J.Res. 21", "Senate joint resolution 21"),
            ("H.Con.Res. 3", "House concurrent resolution 3"),
            ("S.Con.Res. 9", "Senate concurrent resolution 9"),
            ("hr900", "House bill 900")
        ]
        for (number, expected) in cases {
            XCTAssertEqual(SpokenForm.billNumber(number), expected, number)
        }
        XCTAssertEqual(SpokenForm.billNumber("Clean Energy Act"), "Clean Energy Act", "not a bill number")
    }
}
