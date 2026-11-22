import os
import XCTest
@testable import Billboard

/// `BillDisplayFormatting` turns raw bill metadata into the official bill number, a
/// readable date and a plain label for the Congress.gov action type.
final class BillDisplayFormattingTests: XCTestCase {
    func testOfficialNumberFromTypeAndNumber() {
        XCTAssertEqual(BillDisplayFormatting.officialBillNumber(billType: "sjres", billNumber: "213", guid: nil), "S.J.Res. 213")
        XCTAssertEqual(BillDisplayFormatting.officialBillNumber(billType: "HR", billNumber: "0001", guid: nil), "H.R. 1")
    }

    func testOfficialNumberFallsBackToGuid() {
        XCTAssertEqual(BillDisplayFormatting.officialBillNumber(billType: nil, billNumber: nil, guid: "BILLS-119hconres12ih"), "H.Con.Res. 12")
        XCTAssertEqual(BillDisplayFormatting.officialBillNumber(billType: "hr", billNumber: "119-hr-900", guid: "BILLS-119hr900ih"), "H.R. 900")
        XCTAssertNil(BillDisplayFormatting.officialBillNumber(billType: nil, billNumber: nil, guid: "not-a-guid"))
    }

    func testDisplayDate() throws {
        let locale = Locale(identifier: "en_US")
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(BillDisplayFormatting.displayDate("2026-09-17T20:45:22Z", locale: locale, timeZone: timeZone), "Sep 17, 2026")
        XCTAssertEqual(BillDisplayFormatting.displayDate("2026-09-17", locale: locale, timeZone: timeZone), "Sep 17, 2026")
        XCTAssertNil(BillDisplayFormatting.displayDate("  ", locale: locale, timeZone: timeZone))
    }

    /// `FlexibleISO8601` shares its formatters across threads (the manifest is parsed off the main actor).
    func testFlexibleISO8601ParsesTheSameOnManyThreads() {
        let inputs = [
            "2026-09-17T20:45:22.123Z",
            "2026-09-17T20:45:22Z",
            "2026-09-17T20:45:22.123+0000",
            "2026-09-17T20:45:22+02:00",
            "2026-09-17T20:45:22",
            "2026-09-17"
        ]
        let expected = inputs.map { FlexibleISO8601.parse($0) }
        XCTAssertFalse(expected.contains(nil))
        XCTAssertNil(FlexibleISO8601.parse("next Tuesday"))

        let mismatches = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 3_000) { index in
            let position = index % inputs.count
            if FlexibleISO8601.parse(inputs[position]) != expected[position] {
                mismatches.withLock { $0 += 1 }
            }
        }
        XCTAssertEqual(mismatches.withLock { $0 }, 0)
    }

    func testActionTypeLabels() {
        XCTAssertEqual(BillDisplayFormatting.actionTypeLabel("IntroReferral"), "Introduced and referred")
        XCTAssertEqual(BillDisplayFormatting.actionTypeLabel("Calendars"), "Placed on calendar")
        XCTAssertNil(BillDisplayFormatting.actionTypeLabel("NotUsed"))
    }

    /// Congress.gov types "Vetoed by President." President, which reads "Sent to the President": the timeline
    /// labels a veto (31000) or pocket veto (30000) "Veto" by its code (project decision 2026-11-19).
    func testTheTimelineLabelsAVetoLineVeto() {
        func action(_ code: String?, _ text: String?, _ type: String) -> Bill.BillAction {
            Bill.BillAction(actionCode: code, actionDate: "2025-12-29", text: text, type: type, sourceSystem: nil, committees: nil)
        }
        XCTAssertEqual(BillDisplayFormatting.timelineTypeLabel(for: action("31000", "Vetoed by President.", "President")), "Veto")
        XCTAssertEqual(BillDisplayFormatting.timelineTypeLabel(for: action(" 30000 ", "Pocket vetoed by President.", "President")), "Veto")
        XCTAssertEqual(BillDisplayFormatting.timelineText(for: action("31000", nil, "President")), "Veto", "a line without text")
        // Other President lines keep their label; the House's E30000 counts only through its 31000 twin.
        XCTAssertEqual(BillDisplayFormatting.timelineTypeLabel(for: action("28000", "Presented to President.", "President")), "Sent to the President")
        XCTAssertEqual(BillDisplayFormatting.timelineTypeLabel(for: action("E30000", "Vetoed by President.", "President")), "Sent to the President")
        XCTAssertEqual(BillDisplayFormatting.timelineTypeLabel(for: action(nil, "Vetoed by President.", "President")), "Sent to the President", "never by its text")
        XCTAssertEqual(BillDisplayFormatting.timelineTypeLabel(for: action("33000", "Failed of passage in House over veto by the Yeas and Nays.", "Veto")), "Veto")
        XCTAssertEqual(BillDisplayFormatting.actionTypeLabel("President"), "Sent to the President", "the type's label is unchanged")
    }

    /// H.R. 131 and H.R. 504 store a veto's two lines newest first, the House's E30000 before the Library of
    /// Congress's 31000. The timeline lists the 31000 one in the first one's place, so the veto reads "Veto"
    /// (project decision 2026-11-19), as on the website.
    @MainActor
    func testOfAVetosTwoLinesTheCodedOneIsListedInTheHouseLinesPlace() {
        func action(_ code: String, _ date: String, _ text: String, _ type: String) -> Bill.BillAction {
            Bill.BillAction(actionCode: code, actionDate: date, text: text, type: type, sourceSystem: nil, committees: nil)
        }
        // H.R. 131 as stored, newest first.
        let actions = [
            action("33000", "2026-01-08", "Failed of passage in House over veto.", "Veto"),
            action("E30000", "2025-12-29", "Vetoed by President.", "President"),
            action("31000", "2025-12-29", "Vetoed by President.", "President"),
            action("E20000", "2025-12-18", "Presented to President.", "Floor"),
            action("28000", "2025-12-18", "Presented to President.", "President")
        ]

        let timeline = BillDisplayFormatting.timelineActions(actions)

        XCTAssertEqual(
            timeline.compactMap(BillDisplayFormatting.timelineText(for:)),
            ["Presented to President.", "Vetoed by President.", "Failed of passage in House over veto."]
        )
        XCTAssertEqual(timeline.map(BillDisplayFormatting.timelineTypeLabel(for:)), ["Floor action", "Veto", "Veto"])
        XCTAssertEqual(timeline.map(\.actionCode), ["E20000", "31000", "33000"])
        XCTAssertEqual(BillActionsSection.rows(for: actions).map(\.detail), ["Floor action", "Veto", "Veto"], "the bill page's Actions")

        // Listed in reverse, the coded line comes first and keeps its place; the day's other repeat keeps its first line.
        let reversed = BillDisplayFormatting.timelineActions(actions.reversed())
        XCTAssertEqual(reversed.map(BillDisplayFormatting.timelineTypeLabel(for:)), ["Sent to the President", "Veto", "Veto"])
        XCTAssertEqual(reversed.map(\.actionCode), ["28000", "31000", "33000"])
    }

    // MARK: - Congress (REL-46)

    func testTheCongressComesFromTheFieldElseTheGuid() {
        XCTAssertEqual(BillDisplayFormatting.congress(fromGuid: "BILLS-119hr1ih"), 119)
        XCTAssertEqual(BillDisplayFormatting.congress(fromGuid: " BILLS-120sjres7 "), 120)
        XCTAssertNil(BillDisplayFormatting.congress(fromGuid: "BILLS-hr1"))
        XCTAssertNil(BillDisplayFormatting.congress(fromGuid: "not-a-guid"))
        XCTAssertNil(BillDisplayFormatting.congress(fromGuid: nil))

        func bill(congress: String?, guid: String?) -> Bill {
            Bill(title: "A bill", category: "Other", soWhat: "", billStatus: .new, guid: guid, congress: congress, userVoted: false)
        }
        XCTAssertEqual(bill(congress: "118", guid: "BILLS-119hr1").congressNumber, 118, "the field wins")
        XCTAssertEqual(bill(congress: nil, guid: "BILLS-119hr1").congressNumber, 119, "a guid-only bill")
        XCTAssertEqual(bill(congress: " ", guid: "BILLS-119hr1").congressNumber, 119)
        XCTAssertEqual(bill(congress: "119-hr-1", guid: "BILLS-120hr1").congressNumber, 120, "a field that is not a number")
        XCTAssertNil(bill(congress: nil, guid: nil).congressNumber)
        XCTAssertEqual(bill(congress: nil, guid: "BILLS-119sconres32is").billTypeCode, "sconres")
    }

    /// The Congress shows only on a bill of an earlier Congress than the one in office, which turns over at noon
    /// Eastern on January 3, 2027 (17:00 UTC).
    func testTheCongressTagShowsOnlyOnOlderBills() throws {
        XCTAssertEqual(BillDisplayFormatting.olderCongressTag(congress: 119, currentCongress: 120), "119th")
        XCTAssertEqual(BillDisplayFormatting.olderCongressTag(congress: 111, currentCongress: 120), "111th")
        XCTAssertNil(BillDisplayFormatting.olderCongressTag(congress: 120, currentCongress: 120))
        XCTAssertNil(BillDisplayFormatting.olderCongressTag(congress: 121, currentCongress: 120))
        XCTAssertNil(BillDisplayFormatting.olderCongressTag(congress: nil, currentCongress: 120))

        let older = Bill(title: "A bill", category: "Other", soWhat: "", billStatus: .new, guid: "BILLS-119hr1", userVoted: false)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 16, minute: 59)))
        let after = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 17)))
        XCTAssertNil(older.olderCongressTag(at: before))
        XCTAssertEqual(older.olderCongressTag(at: after), "119th")
        XCTAssertNil(older.olderCongressTag(), "the tests' clock is in the 119th Congress")
    }

    func testTheSpokenNumberSaysAnOlderBillsCongress() {
        XCTAssertEqual(SpokenForm.billNumber("H.R. 1", congressTag: "119th"), "House bill 1, 119th Congress")
        XCTAssertEqual(SpokenForm.billNumber("H.R. 1", congressTag: nil), "House bill 1")
        XCTAssertEqual(SpokenForm.billNumber("S.J.Res. 21", congressTag: " "), "Senate joint resolution 21")
        XCTAssertEqual(
            SpokenForm.withCongress("House bill 10 and Senate bill 10", congressTag: "119th"),
            "House bill 10 and Senate bill 10, 119th Congress"
        )
    }

    // MARK: - Companion bills (APPF-23)

    /// Each of the eight bill types, from a plain guid and from a text-version guid.
    func testOfficialNumberFromGuidForEveryBillType() {
        let expected: [(guid: String, number: String)] = [
            ("BILLS-119hr900", "H.R. 900"),
            ("BILLS-119s456", "S. 456"),
            ("BILLS-119hjres131", "H.J.Res. 131"),
            ("BILLS-119sjres91", "S.J.Res. 91"),
            ("BILLS-119hconres82", "H.Con.Res. 82"),
            ("BILLS-119sconres32", "S.Con.Res. 32"),
            ("BILLS-119hres407", "H.Res. 407"),
            ("BILLS-119sres208", "S.Res. 208")
        ]
        for (guid, number) in expected {
            XCTAssertEqual(BillDisplayFormatting.officialBillNumber(billType: nil, billNumber: nil, guid: guid), number, guid)
            XCTAssertEqual(BillDisplayFormatting.officialBillNumber(billType: nil, billNumber: nil, guid: guid + "ih"), number, guid)
            XCTAssertEqual(CompanionGroupIndex.billNumber(forGUID: guid), number, guid)
        }
        // The type and number win over the guid; a guid that is not a bill guid is shown as it is.
        XCTAssertEqual(BillDisplayFormatting.officialBillNumber(billType: "S", billNumber: "0456", guid: "BILLS-119hr900"), "S. 456")
        XCTAssertEqual(CompanionGroupIndex.billNumber(forGUID: " not-a-guid "), "not-a-guid")
    }

    func testCompanionNumbersAndAccessibilityLabels() {
        let bills = BillCompanionGroup(primaryGuid: "BILLS-119hr900", memberGuids: ["BILLS-119hr900", "BILLS-119s456"], relationship: "identical")
        XCTAssertEqual(CompanionGroupIndex.numbersLabel(for: bills), "H.R. 900 · S. 456")
        XCTAssertEqual(CompanionGroupIndex.accessibilityLabel(for: bills), "Bill numbers H.R. 900 and S. 456, identical bills")

        let display = BillCompanionDisplay(group: bills, statusLead: nil)
        XCTAssertEqual(display.numbersLabel, "H.R. 900 · S. 456")
        XCTAssertEqual(display.accessibilityLabel, "Bill numbers H.R. 900 and S. 456, identical bills")
        XCTAssertEqual(display.tag, "Identical bills")

        let resolutions = BillCompanionGroup(
            primaryGuid: "BILLS-119hconres12",
            memberGuids: ["BILLS-119sconres10"],
            relationship: "identical"
        )
        XCTAssertEqual(CompanionGroupIndex.numbersLabel(for: resolutions), "H.Con.Res. 12 · S.Con.Res. 10")
        XCTAssertEqual(
            CompanionGroupIndex.accessibilityLabel(for: resolutions),
            "Bill numbers H.Con.Res. 12 and S.Con.Res. 10, identical bills"
        )

        // A relationship other than "identical" (none today) is not called identical.
        let other = BillCompanionGroup(primaryGuid: "BILLS-119hres5", memberGuids: ["BILLS-119sres7"], relationship: "related")
        XCTAssertEqual(BillCompanionDisplay(group: other, statusLead: nil).tag, "Companion bills")
        XCTAssertEqual(CompanionGroupIndex.accessibilityLabel(for: other), "Bill numbers H.Res. 5 and S.Res. 7, companion bills")
    }

    func testCompanionStatusChipNamesTheLeadWhenItIsNotThePrimary() {
        let senateLeads = CompanionStatusLead(guid: "BILLS-119sjres84", status: .failed, isPrimary: false, billNumber: "S.J.Res. 84")
        XCTAssertEqual(senateLeads.label, "Failed · S.J.Res. 84")
        let houseLeads = CompanionStatusLead(guid: "BILLS-119hjres131", status: .finalized, isPrimary: true, billNumber: "H.J.Res. 131")
        XCTAssertEqual(houseLeads.label, "Became law", "Finalized reads as Became law (REL-44)")
        // Project decision 2026-11-19: a vetoed lead reads "Vetoed"; a law never does.
        let vetoedHouse = CompanionStatusLead(guid: "BILLS-119hr10", status: .failed, vetoed: true, isPrimary: false, billNumber: "H.R. 10")
        XCTAssertEqual(vetoedHouse.label, "Vetoed · H.R. 10")
        let vetoedPrimary = CompanionStatusLead(guid: "BILLS-119hr131", status: .passed, vetoed: true, isPrimary: true, billNumber: "H.R. 131")
        XCTAssertEqual(vetoedPrimary.label, "Vetoed")
        let law = CompanionStatusLead(guid: "BILLS-119hr10", status: .finalized, vetoed: true, isPrimary: false, billNumber: "H.R. 10")
        XCTAssertEqual(law.label, "Became law · H.R. 10")
    }

    func testCompanionCaptionsAndSubtitle() {
        XCTAssertEqual(
            BillDisplayFormatting.companionSubtitle(otherGuids: ["BILLS-119hr900"], isIdentical: true),
            "Identical to H.R. 900"
        )
        XCTAssertEqual(
            BillDisplayFormatting.companionSubtitle(otherGuids: ["BILLS-119s456is"], isIdentical: true),
            "Identical to S. 456"
        )
        XCTAssertNil(BillDisplayFormatting.companionSubtitle(otherGuids: [], isIdentical: true))

        XCTAssertEqual(
            BillDisplayFormatting.companionVoteCaption(memberCount: 2, isIdentical: true),
            "These bills have identical text. Your vote counts once for both."
        )

        XCTAssertEqual(
            BillDisplayFormatting.combinedVotesCaption(companionBillIds: ["BILLS-119hr900", "BILLS-119s456"]),
            "Combined votes on H.R. 900 and S. 456"
        )
        XCTAssertEqual(
            BillDisplayFormatting.combinedVotesCaption(companionBillIds: ["BILLS-119hr1", "BILLS-119s2", "BILLS-119s3"]),
            "Combined votes on H.R. 1, S. 2 and S. 3"
        )
        // Only when the server says the votes were combined.
        XCTAssertNil(BillDisplayFormatting.combinedVotesCaption(companionBillIds: nil))
        XCTAssertNil(BillDisplayFormatting.combinedVotesCaption(companionBillIds: ["BILLS-119hr900"]))
    }

    func testCompanionConflictNote() {
        XCTAssertEqual(
            BillDisplayFormatting.companionConflictNote(
                countedGuid: "BILLS-119hr900", countedVote: .yea,
                otherGuid: "BILLS-119s456", otherVote: .nay
            ),
            "Before these were combined you also voted Nay on S. 456. Your H.R. 900 vote is the one that counts."
        )
        XCTAssertEqual(
            BillDisplayFormatting.companionConflictNote(
                countedGuid: "BILLS-119hr900", countedVote: .nay,
                otherGuid: "BILLS-119s456", otherVote: .abstain
            ),
            "Before these were combined you also abstained on S. 456. Your H.R. 900 vote is the one that counts."
        )
        XCTAssertEqual(
            BillDisplayFormatting.companionConflictNote(
                countedGuid: "BILLS-119hr900", countedVote: .abstain,
                otherGuid: "BILLS-119s456", otherVote: .yea
            ),
            "Before these were combined you also voted Yea on S. 456. Your abstention on H.R. 900 is the one that counts."
        )
    }

    /// Search matches a bill number typed in any of the usual ways.
    func testBillNumberSearchKeys() {
        for query in ["S. 456", "s456", "S 456", "s.456", " S. 0456 "] {
            XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey(query), "s456", query)
        }
        for query in ["hr 900", "H.R. 900", "HR900", "h. r. 900"] {
            XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey(query), "hr900", query)
        }
        XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey("H.J.Res. 131"), "hjres131")
        XCTAssertEqual(BillDisplayFormatting.billNumberQueryKey("s con res 32"), "sconres32")
        for query in ["healthcare", "hr", "900", "x 12", "hr 9a", "s 0"] {
            XCTAssertNil(BillDisplayFormatting.billNumberQueryKey(query), query)
        }

        XCTAssertEqual(BillDisplayFormatting.billNumberSearchKey(billType: "S", billNumber: "456", guid: nil), "s456")
        XCTAssertEqual(BillDisplayFormatting.billNumberSearchKey(billType: nil, billNumber: nil, guid: "BILLS-119hr900ih"), "hr900")
        XCTAssertEqual(BillDisplayFormatting.billNumberSearchKey(billType: "hr", billNumber: "119-hr-900", guid: "BILLS-119hr900"), "hr900")
        XCTAssertNil(BillDisplayFormatting.billNumberSearchKey(billType: nil, billNumber: nil, guid: "not-a-guid"))
    }

    // MARK: - Member party and seat (spec D 2.3.4)

    func testMemberAffiliationUsesThePartyLetterStateAndDistrict() {
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "D", stateCode: "VA", district: nil), "(D-VA)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "R", stateCode: "VA", district: "11"), "(R-VA-11)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "R", stateCode: "va", district: "VA-011"), "(R-VA-11)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "r", stateCode: " VA ", district: "VA11"), "(R-VA-11)")
    }

    func testMemberAffiliationShowsAnAtLargeSeatAsTheState() {
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "R", stateCode: "AK", district: "At-Large"), "(R-AK)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "R", stateCode: "AK", district: "AL"), "(R-AK)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "R", stateCode: "AK", district: "0"), "(R-AK)")
    }

    func testMemberAffiliationReadsTheStateFromTheDistrictWhenItIsMissing() {
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "D", stateCode: nil, district: "CA-12"), "(D-CA-12)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "D", stateCode: "California", district: "CA-12"), "(D-CA-12)")
        // "AL" alone is an at-large seat, not Alabama.
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "I", stateCode: nil, district: "AL"), "(I)")
    }

    func testMemberAffiliationWithPartsMissing() {
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: "I", stateCode: nil, district: nil), "(I)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: nil, stateCode: "VA", district: "2"), "(VA-2)")
        XCTAssertEqual(BillDisplayFormatting.memberAffiliation(partyLetter: " ", stateCode: "VA", district: nil), "(VA)")
        XCTAssertNil(BillDisplayFormatting.memberAffiliation(partyLetter: nil, stateCode: nil, district: nil))
        XCTAssertNil(BillDisplayFormatting.memberAffiliation(partyLetter: nil, stateCode: "Virginia", district: "11"))
    }

    @MainActor
    func testMemberAffiliationNeverUsesTheOldPartyNicknames() {
        for party in PoliticalParty.allCases {
            let label = BillDisplayFormatting.memberAffiliation(partyLetter: party.letter, stateCode: "VA", district: nil) ?? ""
            XCTAssertEqual(label, "(\(party.letter)-VA)")
            for nickname in ["Dem", "GOP", "Ind"] {
                XCTAssertFalse(label.contains(nickname), label)
            }
        }
    }
}
