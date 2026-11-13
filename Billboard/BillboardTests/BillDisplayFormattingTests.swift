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
