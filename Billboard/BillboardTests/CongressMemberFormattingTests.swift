import XCTest
@testable import Billboard

/// District labels include the state, the House roster sorts by last name (APPF-12), and members
/// are labelled with party letters (spec D 2.3.4).
final class CongressMemberFormattingTests: XCTestCase {
    @MainActor
    func testDistrictLabel() {
        XCTAssertEqual(CongressMember.districtLabel(state: "VA", district: "11"), "VA-11")
        XCTAssertEqual(CongressMember.districtLabel(state: "VA", district: "1"), "VA-1", "no leading zero, as the frames write it")
        XCTAssertEqual(CongressMember.districtLabel(state: "VA", district: "01"), "VA-1")
        XCTAssertEqual(CongressMember.districtLabel(state: "AK", district: "0"), "AK At-Large")
        XCTAssertEqual(CongressMember.districtLabel(state: "AK", district: "At-Large"), "AK At-Large")
        XCTAssertEqual(CongressMember.districtLabel(state: "Virginia", district: "11"), "11")
        XCTAssertNil(CongressMember.districtLabel(state: "VA", district: nil))
        // Trailing zeros are part of the number.
        XCTAssertEqual(CongressMember.districtLabel(state: "CA", district: "10"), "CA-10")
        XCTAssertEqual(CongressMember.districtLabel(state: "TX", district: "20"), "TX-20")
        XCTAssertEqual(CongressMember.districtLabel(state: "CA", district: "CA-10"), "CA-10")
        XCTAssertEqual(CongressMember.districtLabel(state: "CA", district: "050"), "CA-50")
    }

    @MainActor
    func testDistrictNormalizationKeepsTrailingZeros() {
        XCTAssertEqual(DistrictNormalization.normalize("10", userState: "CA"), "10")
        XCTAssertEqual(DistrictNormalization.normalize("CA-10", userState: "CA"), "10")
        XCTAssertEqual(DistrictNormalization.normalize("20th", userState: "TX"), "20")
        XCTAssertEqual(DistrictNormalization.normalize("012", userState: "NY"), "12")
        XCTAssertEqual(DistrictNormalization.normalize("00", userState: "AK"), "AT-LARGE")
        XCTAssertNotEqual(
            DistrictNormalization.normalize("10", userState: "CA"),
            DistrictNormalization.normalize("1", userState: "CA")
        )
    }

    @MainActor
    func testRosterSortByLastName() {
        let names = [
            "Tim Kaine",
            "Aaron Bean",
            "Chris Van Hollen",
            "Donald S. Beyer, Jr.",
            "Adam Gray",
            "Monica De La Cruz"
        ]

        let sorted = names.sorted { CongressMemberNameSortKey(name: $0) < CongressMemberNameSortKey(name: $1) }

        XCTAssertEqual(sorted, [
            "Aaron Bean",
            "Donald S. Beyer, Jr.",
            "Monica De La Cruz",
            "Adam Gray",
            "Tim Kaine",
            "Chris Van Hollen"
        ])
        XCTAssertEqual(CongressMemberNameSortKey(name: "Kaine, Tim").lastName, "Kaine")
    }

    // MARK: - Party letters and member labels (spec D 2.3.4)

    @MainActor
    func testLabelsNeverUseThePartyNicknames() {
        for party in PoliticalParty.allCases {
            let labels = [
                CongressMemberLabel.affiliation(party: party, state: "VA", district: "11", chamber: .house) ?? "",
                CongressMemberLabel.pageAffiliation(party: party, state: "VA", district: nil, chamber: .senate) ?? "",
                CongressMemberLabel.spokenDescription(name: "A Member", party: party, state: "VA", district: nil, chamber: .senate)
            ]
            for label in labels {
                for nickname in ["Dem", "GOP", "Ind"] {
                    XCTAssertNil(label.range(of: "\\b\(nickname)\\b", options: .regularExpression), "\(label) contains \(nickname)")
                }
            }
        }
    }

    /// One spoken form for members and districts everywhere (project decision of 2026-10-21): the chamber's
    /// title, the party in words, and the seat as `SpokenForm.district` says a district code.
    @MainActor
    func testSpokenDescriptionSpellsOutChamberPartyAndPlace() {
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Tim Kaine", party: .democratic, state: "VA", district: nil, chamber: .senate),
            "Senator Tim Kaine, Democrat, Virginia"
        )
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Jane Doe", party: .democratic, state: "VA", district: "11", chamber: .senate),
            "Senator Jane Doe, Democrat, Virginia",
            "a senator's seat is the state, whatever district comes with it"
        )
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Jane Doe", party: .republican, state: "VA", district: "011", chamber: .house),
            "Representative Jane Doe, Republican, Virginia's 11th district"
        )
        for district in ["0", "00", "AL", "At-Large"] {
            XCTAssertEqual(
                CongressMemberLabel.spokenDescription(name: "Nick Begich", party: .republican, state: "AK", district: district, chamber: .house),
                "Representative Nick Begich, Republican, Alaska's at-large district",
                district
            )
        }
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Eleanor Holmes Norton", party: .democratic, state: "DC", district: "0", chamber: .house),
            "Representative Eleanor Holmes Norton, Democrat, District of Columbia's at-large district",
            "a delegate's seat"
        )
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Jane Doe", party: .independent, state: "VA", district: nil, chamber: .house),
            "Representative Jane Doe, Independent, Virginia",
            "a House member whose district is not known"
        )
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Jane Doe", party: nil, state: nil, district: "TX-7", chamber: .house),
            "Representative Jane Doe, Texas's 7th district"
        )
        XCTAssertEqual(
            CongressMemberLabel.spokenDescription(name: "Jane Doe", party: .republican, state: "Virginia", district: "11", chamber: .house),
            "Representative Jane Doe, Republican, Virginia",
            "a state that is not a postal code, as it is"
        )
        XCTAssertEqual(CongressMemberLabel.spokenDescription(name: "Jane Doe", party: nil, state: nil, district: nil, chamber: nil), "Jane Doe")
    }

    /// The member rows, Your representatives, the member page and the bill page's sponsor and How Congress voted
    /// all read a member the same way, and the seat as Your representatives' counter and Profile read a district.
    @MainActor
    func testEveryScreenReadsAMemberInTheOneSpokenForm() {
        let expected = "Representative Jane Doe, Republican, Virginia's 11th district"
        XCTAssertEqual(BillSponsorRow.Content(name: "Jane Doe", party: .republican, chamber: .house, stateCode: "VA", district: "11").accessibilityLabel, "Sponsor: \(expected)")
        XCTAssertEqual(CongressMemberLabel.spokenSeat(state: "VA", district: "11", chamber: .house), SpokenForm.district("VA-11"))
        XCTAssertEqual(SectionHeader("Your representatives", trailing: .district("VA-11")).headerLabel, "Your representatives, Virginia's 11th district")
        XCTAssertEqual(CongressMemberLabel.spokenSeat(state: "WY", district: "At-Large", chamber: .house), SpokenForm.district("WY at-large"))
        XCTAssertEqual(
            WhereYouVoteSummary.make(state: "WY", district: "At-Large", status: nil, isLoading: false).accessibilityText.hasPrefix("Wyoming's at-large district"),
            true
        )
    }

    @MainActor
    func testChamberNamesFromEveryPayloadSpelling() {
        XCTAssertEqual(CongressMemberLabel.chamber(named: "House"), .house)
        XCTAssertEqual(CongressMemberLabel.chamber(named: "House of Representatives"), .house)
        XCTAssertEqual(CongressMemberLabel.chamber(named: " senate "), .senate)
        XCTAssertNil(CongressMemberLabel.chamber(named: "Member"))
    }

    @MainActor
    func testPartyRowSummary() {
        XCTAssertEqual(PoliticalPartyRow.summary(totalCount: 47, houseCount: 0, senateCount: 47), "47 members · 0 House · 47 Senate")
        XCTAssertEqual(PoliticalPartyRow.summary(totalCount: 1, houseCount: 0, senateCount: 1), "1 member · 0 House · 1 Senate")
    }

    @MainActor
    func testFollowButtonWords() {
        XCTAssertEqual(CongressFollowToolbarButton.title(isFollowing: false), "Follow")
        XCTAssertEqual(CongressFollowToolbarButton.title(isFollowing: true), "Following")
        XCTAssertEqual(CongressFollowToolbarButton.accessibilityLabel(isFollowing: false), "Follow")
        XCTAssertEqual(CongressFollowToolbarButton.accessibilityLabel(isFollowing: true), "Unfollow")
        // Civic Record spec 4.59: plus.circle + "Follow", checkmark.circle + "Following".
        XCTAssertEqual(CongressFollowToolbarButton.systemImage(isFollowing: false), "plus.circle")
        XCTAssertEqual(CongressFollowToolbarButton.systemImage(isFollowing: true), "checkmark.circle")
    }

    // MARK: - Affiliation lines (Civic Record spec 3.14, 3.15, 4.59)

    /// The affiliation line starts with the party letter, so the party is written as well as shown on the
    /// disc; unknown parts are left out. A House seat has no leading zero ("VA-1", as the frames set it).
    @MainActor
    func testAffiliationLineIsLedByThePartyLetter() {
        XCTAssertEqual(CongressMemberLabel.affiliation(party: .democratic, state: "VA", district: nil, chamber: .senate), "D · Senate · VA")
        XCTAssertEqual(CongressMemberLabel.affiliation(party: .democratic, state: "VA", district: "11", chamber: .house), "D · House · VA-11")
        XCTAssertEqual(CongressMemberLabel.affiliation(party: .republican, state: "VA", district: "1", chamber: .house), "R · House · VA-1")
        XCTAssertEqual(CongressMemberLabel.affiliation(party: .republican, state: "VA", district: "VA-01", chamber: .house), "R · House · VA-1")
        XCTAssertEqual(CongressMemberLabel.affiliation(party: .independent, state: "VT", district: nil, chamber: .senate), "I · Senate · VT")
        XCTAssertEqual(CongressMemberLabel.affiliation(party: .republican, state: "AK", district: "0", chamber: .house), "R · House · AK")
        XCTAssertEqual(CongressMemberLabel.affiliation(party: nil, state: "VA", district: "11", chamber: .house), "House · VA-11")
        XCTAssertEqual(CongressMemberLabel.affiliation(party: .democratic, state: nil, district: nil, chamber: nil), "D")
        XCTAssertNil(CongressMemberLabel.affiliation(party: nil, state: " ", district: nil, chamber: nil))
    }

    /// One affiliation line for a member wherever the member is listed: the bill page's sponsor and How
    /// Congress voted rows set the same line as the member rows, "R · House · TX-7", not "TX-7" on the bill
    /// page and "TX-07" in the directory.
    @MainActor
    func testTheBillPageAndTheMemberRowsShareTheAffiliationLine() {
        let sponsor = BillSponsorRow.Content(name: "Jordan Ellis", party: .republican, chamber: .house, stateCode: "TX", district: "07")
        XCTAssertEqual(sponsor.affiliation, "R · House · TX-7")
        XCTAssertEqual(sponsor.affiliation, CongressMemberLabel.affiliation(party: .republican, state: "TX", district: "07", chamber: .house))
        XCTAssertEqual(CongressMemberLabel.seat(state: nil, district: "TX-7", chamber: .house), "TX-7", "a seat from the district alone")
        XCTAssertEqual(CongressMemberLabel.seat(state: "Virginia", district: "11", chamber: .house), "Virginia", "a state name as given")
        XCTAssertEqual(CongressMemberLabel.seat(state: "VA", district: "11", chamber: .senate), "VA", "no district for a senator")
    }

    /// The user's own district is written as the member rows write a seat: on the Congress tab the Your
    /// representatives counter ("VA-1") sits over the House member's "R · House · VA-1", and Profile's Where
    /// you vote, the location panel's "You're in VA-1." and a district with no members ("We couldn't find the
    /// members for TX-7") follow it. R2 zero-padded the user's district ("VA-01") while the rows did not.
    @MainActor
    func testTheUsersDistrictMatchesTheHouseMembersSeat() throws {
        for (state, district) in [("VA", "1"), ("VA", "01"), ("TX", "7"), ("VA", "11"), ("CA", "050")] {
            let counter = try XCTUnwrap(YourRepresentativesContent.districtCode(state: state, district: district))
            let seat = try XCTUnwrap(CongressMemberLabel.seat(state: state, district: district, chamber: .house))
            XCTAssertEqual(counter, seat, "\(state) \(district)")
            let row = try XCTUnwrap(CongressMemberLabel.affiliation(party: .republican, state: state, district: district, chamber: .house))
            XCTAssertTrue(row.hasSuffix(" · \(counter)"), "\(row) ends with \(counter)")
            XCTAssertEqual(DistrictPickerModel.locationLabel(state: state, district: district), seat)
            XCTAssertEqual(DistrictPickerModel.successHeadline(state: state, district: district), "You're in \(seat).")
            let whereYouVote = WhereYouVoteSummary.make(state: state, district: district, status: nil, isLoading: true).line
            XCTAssertTrue(whereYouVote.hasPrefix("\(seat) · "), whereYouVote)
            XCTAssertEqual(VoteResultsFormatting.districtLabel(stateCode: state, district: district), seat, "Results' \"Verified voters in VA-1\"")
        }
    }

    /// The member page's docket line has the state and district in words.
    @MainActor
    func testPageAffiliationSpellsOutThePlace() {
        XCTAssertEqual(CongressMemberLabel.pageAffiliation(party: .democratic, state: "VA", district: nil, chamber: .senate), "D · Senate · Virginia")
        XCTAssertEqual(CongressMemberLabel.pageAffiliation(party: .republican, state: "TX", district: "7", chamber: .house), "R · House · Texas 7th district")
        XCTAssertEqual(CongressMemberLabel.pageAffiliation(party: .republican, state: "TX", district: "TX-22", chamber: .house), "R · House · Texas 22nd district")
        XCTAssertEqual(CongressMemberLabel.pageAffiliation(party: .republican, state: "AK", district: "0", chamber: .house), "R · House · Alaska at-large")
        XCTAssertEqual(CongressMemberLabel.pageAffiliation(party: .democratic, state: "Virginia", district: nil, chamber: .senate), "D · Senate · Virginia")
        XCTAssertNil(CongressMemberLabel.pageAffiliation(party: nil, state: nil, district: nil, chamber: nil))
    }

    /// A dot keeps to the end of its line when an affiliation wraps.
    @MainActor
    func testDocketTextKeepsEachDotWithTheWordBeforeIt() {
        XCTAssertEqual(CongressMemberLabel.docketText("D · Senate · VA"), "D\u{00A0}· Senate\u{00A0}· VA")
    }

    @MainActor
    func testDistrictWordsForTheMemberPage() {
        XCTAssertEqual(CongressMemberLabel.districtWords(state: "TX", district: "7", chamber: .house), "7th")
        XCTAssertEqual(CongressMemberLabel.districtWords(state: "VA", district: "VA-11", chamber: .house), "11th")
        XCTAssertEqual(CongressMemberLabel.districtWords(state: "AK", district: "0", chamber: .house), "At-large")
        XCTAssertNil(CongressMemberLabel.districtWords(state: "VA", district: "11", chamber: .senate))
        XCTAssertNil(CongressMemberLabel.districtWords(state: "VA", district: nil, chamber: .house))
    }

    @MainActor
    func testDirectoryOpensOnTheTabsFilter() {
        typealias Selection = CongressMembersDirectoryView.ExploreSelection
        XCTAssertEqual(Selection(.all), .all)
        XCTAssertEqual(Selection(.house), .house)
        XCTAssertEqual(Selection(.senate), .senate)
        XCTAssertEqual(Selection(.myState), .state)
        XCTAssertEqual(Selection.allCases.map(\.title), ["Mine", "All", "House", "Senate", "State"])
    }
}
