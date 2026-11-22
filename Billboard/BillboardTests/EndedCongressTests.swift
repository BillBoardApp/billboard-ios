import SwiftUI
import XCTest
@testable import Billboard

/// REL-46 (D16): a bill whose Congress ended. From noon Eastern on January 3 of the odd year after its two years
/// (17:00 UTC), a bill that did not become law gets the note under its titles; a New or Updated one is stamped "Ended
/// with the 119th Congress" in `ink3` and leaves the Bills list. A Passed bill, or one whose actions show a passage,
/// waits until February 1. The rule and the words are the shared-bill page's (backend website/app.js, `endedNote`);
/// these cases are the page's faked-date checks (scripts/ci/test-website-app.mjs). Ended bills stay votable.
@MainActor
final class EndedCongressTests: XCTestCase {
    private static let billNote =
        "The 119th Congress ended on January 3, 2027. This bill did not become law. To move forward it would have to be introduced again."
    private static let resolutionNote =
        "The 119th Congress ended on January 3, 2027. This resolution was not agreed to. To move forward it would have to be introduced again."
    private static let jointResolutionNote = billNote.replacingOccurrences(of: "This bill", with: "This joint resolution")
    private static let amendmentNote =
        "The 119th Congress ended on January 3, 2027. This proposed amendment did not pass Congress. To move forward it would have to be introduced again."

    private static func at(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static let midDecember = at("2026-12-18T12:00:00Z")
    private static let beforeNoon = at("2027-01-03T16:59:59Z")
    private static let noon = at("2027-01-03T17:00:00Z")
    /// 23:59:59 Eastern on January 31.
    private static let januaryThirtyFirstLate = at("2027-02-01T04:59:59Z")
    /// Midnight Eastern on February 1.
    private static let februaryFirst = at("2027-02-01T05:00:00Z")

    private func action(_ code: String?, _ text: String, type: String) -> Bill.BillAction {
        Bill.BillAction(actionCode: code, actionDate: "2026-12-20", text: text, type: type, sourceSystem: nil, committees: nil)
    }

    private lazy var signed = action(nil, "Signed by President.", type: "President")
    private lazy var law = action("36000", "Became Public Law No: 119-300.", type: "BecameLaw")
    private lazy var housePassage = action("8000", "On passage Passed by the Yeas and Nays: 231 - 196.", type: "Floor")
    private lazy var senatePassage = action("17000", "Passed/agreed to in Senate.", type: "Floor")
    private lazy var presented = action(nil, "Presented to President.", type: "President")

    /// A bill of the 119th Congress with only a guid ("BILLS-119hr12"), as a manifest row gives it.
    private func bill(
        _ type: String,
        _ status: BillStatus,
        congress: Int = 119,
        number: Int = 12,
        vetoed: Bool? = nil,
        actions: [Bill.BillAction] = [],
        title: String = "A bill",
        officialTitle: String? = nil
    ) -> Bill {
        let guid = "BILLS-\(congress)\(type)\(number)"
        return Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            officialTitle: officialTitle,
            category: "Other",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 60)),
            actions: actions,
            billStatus: status,
            vetoed: vetoed,
            guid: guid,
            userVoted: false,
            isPriority: true
        )
    }

    // MARK: - The note (the shared-bill page's checks)

    func testNoNoteBeforeTheCongressEnds() {
        for status in [BillStatus.new, .updated, .failed, .passed] {
            XCTAssertNil(bill("hr", status).endedNote(at: Self.midDecember), "\(status)")
            XCTAssertNil(bill("hr", status).endedNote(at: Self.beforeNoon), "\(status)")
        }
    }

    func testNewUpdatedAndFailedBillsGetTheNoteFromNoonEasternOnJanuaryThird() {
        for status in [BillStatus.new, .updated, .failed] {
            XCTAssertEqual(bill("hr", status).endedNote(at: Self.noon), Self.billNote, "\(status)")
            XCTAssertEqual(bill("s", status).endedNote(at: Self.februaryFirst), Self.billNote, "\(status)")
        }
    }

    func testPassedBillsWaitUntilFebruaryFirstMidnightEastern() {
        XCTAssertNil(bill("hr", .passed).endedNote(at: Self.noon))
        XCTAssertNil(bill("hr", .passed).endedNote(at: Self.januaryThirtyFirstLate))
        XCTAssertEqual(bill("hr", .passed).endedNote(at: Self.februaryFirst), Self.billNote)
        XCTAssertEqual(EndedCongress.passedHoldTime(ofCongress: 119), Self.februaryFirst)
    }

    func testABillThatBecameLawNeverGetsTheNote() {
        XCTAssertNil(bill("hr", .finalized).endedNote(at: Self.februaryFirst))
        XCTAssertNil(bill("hr", .passed, actions: [signed]).endedNote(at: Self.februaryFirst))
        XCTAssertNil(bill("hr", .updated, actions: [law]).endedNote(at: Self.noon))
        XCTAssertNil(bill("hr", .new, actions: [action("36000", "", type: "Floor")]).endedNote(at: Self.noon), "the law code alone")
        XCTAssertNil(bill("hr", .new, actions: [action(nil, "Became Private Law No: 119-2.", type: "Floor")]).endedNote(at: Self.noon))
    }

    func testABillWhoseActionsShowAPassageWaitsLikeAPassedBill() {
        XCTAssertNil(bill("hr", .updated, actions: [senatePassage]).endedNote(at: Self.noon))
        XCTAssertNil(bill("hr", .failed, actions: [senatePassage]).endedNote(at: Self.januaryThirtyFirstLate))
        XCTAssertEqual(bill("hr", .failed, actions: [senatePassage]).endedNote(at: Self.februaryFirst), Self.billNote)
        XCTAssertNil(bill("s", .new, actions: [presented]).endedNote(at: Self.noon))
    }

    func testSimpleAndConcurrentResolutionsSayNotAgreedToAndNothingOnceAgreedTo() {
        for type in ["hres", "sres", "hconres", "sconres"] {
            XCTAssertEqual(bill(type, .new).endedNote(at: Self.noon), Self.resolutionNote, type)
            XCTAssertEqual(bill(type, .failed).endedNote(at: Self.noon), Self.resolutionNote, type)
            XCTAssertNil(bill(type, .passed).endedNote(at: Self.noon), type)
            XCTAssertNil(bill(type, .passed).endedNote(at: Self.februaryFirst), type)
            XCTAssertNil(bill(type, .new).endedNote(at: Self.beforeNoon), type)
            XCTAssertNil(bill(type, .updated, actions: [housePassage]).endedNote(at: Self.februaryFirst), "\(type): agreed to by its actions")
        }
    }

    func testJointResolutionsFollowTheBillRuleInTheirOwnWords() {
        XCTAssertEqual(bill("hjres", .new).endedNote(at: Self.noon), Self.jointResolutionNote)
        XCTAssertNil(bill("sjres", .passed).endedNote(at: Self.noon))
        XCTAssertEqual(bill("sjres", .passed).endedNote(at: Self.februaryFirst), Self.jointResolutionNote)
    }

    func testAProposedConstitutionalAmendmentNeverDidNotBecomeLaw() {
        func amendment(_ status: BillStatus) -> Bill {
            bill("hjres", status, officialTitle: "Proposing an amendment to the Constitution of the United States relative to the length of terms.")
        }
        XCTAssertEqual(amendment(.new).endedNote(at: Self.noon), Self.amendmentNote)
        XCTAssertEqual(amendment(.failed).endedNote(at: Self.februaryFirst), Self.amendmentNote)
        XCTAssertNil(amendment(.passed).endedNote(at: Self.noon))
        XCTAssertNil(amendment(.passed).endedNote(at: Self.februaryFirst))
        XCTAssertNil(bill("sjres", .passed, title: "Proposing an amendment to the Constitution").endedNote(at: Self.februaryFirst), "the headline names it")
    }

    func testTheWordsComeFromTheCongressSoLaterCongressesWorkToo() {
        let later = bill("s", .new, congress: 120, number: 4)
        XCTAssertNil(later.endedNote(at: Self.at("2027-06-01T12:00:00Z")))
        XCTAssertNil(later.endedNote(at: Self.at("2029-01-03T16:59:59Z")))
        XCTAssertEqual(
            later.endedNote(at: Self.at("2029-01-03T17:00:00Z")),
            "The 120th Congress ended on January 3, 2029. This bill did not become law. To move forward it would have to be introduced again."
        )
        XCTAssertEqual(
            bill("hr", .new, congress: 121, number: 1).endedNote(at: Self.at("2031-01-03T17:00:00Z")),
            "The 121st Congress ended on January 3, 2031. This bill did not become law. To move forward it would have to be introduced again."
        )
    }

    func testNoNoteWhenTheTypeOrTheCongressIsUnknown() {
        let noGuid = Bill(title: "A bill", category: "Other", soWhat: "", billStatus: .new, userVoted: false)
        XCTAssertNil(noGuid.endedNote(at: Self.februaryFirst))
        XCTAssertNil(bill("hr", .new, congress: 73).endedNote(at: Self.februaryFirst), "before the 74th, a Congress ended on March 4")
        let notABillGuid = Bill(title: "A bill", category: "Other", soWhat: "", billStatus: .new, guid: "BILLS-119xyz12", userVoted: false)
        XCTAssertNil(notABillGuid.endedNote(at: Self.februaryFirst))
    }

    /// The Congress comes from the bill's field when it has one, else from its guid.
    func testAGuidOnlyBillAndAFieldOnlyBillBothCount() {
        XCTAssertEqual(bill("hr", .new).endedCongress(at: Self.noon), 119, "guid only")
        let fields = Bill(
            title: "A bill", category: "Other", soWhat: "", billStatus: .new, congress: "119", billType: "hr", billID: "12", userVoted: false
        )
        XCTAssertEqual(fields.endedCongress(at: Self.noon), 119, "fields only")
    }

    func testAVetoedBillGetsTheNoteAsAPassedOneDoesButKeepsItsStamp() {
        let vetoed = bill("hr", .failed, vetoed: true, actions: [
            action("33000", "Failed of passage in House over veto.", type: "Veto"),
            action("E30000", "Vetoed by President.", type: "President"),
            action("31000", "Vetoed by President.", type: "President")
        ])
        XCTAssertNil(vetoed.endedNote(at: Self.noon))
        XCTAssertEqual(vetoed.endedNote(at: Self.februaryFirst), Self.billNote)
        XCTAssertNil(vetoed.endedCongress(at: Self.februaryFirst), "VETOED stands over the ended stamp")
        XCTAssertEqual(vetoed.outcomeLabel(at: Self.februaryFirst), "Vetoed")
    }

    // MARK: - The stamp

    /// Only a New or Updated bill is stamped; Became law, Vetoed, Passed and Failed are outcomes and stand over it.
    func testOnlyABillWithNoOutcomeIsStampedEnded() {
        XCTAssertEqual(bill("hr", .new).endedCongress(at: Self.noon), 119)
        XCTAssertEqual(bill("hr", .updated).endedCongress(at: Self.noon), 119)
        XCTAssertNil(bill("hr", .new).endedCongress(at: Self.beforeNoon))
        for status in [BillStatus.passed, .failed, .finalized] {
            XCTAssertNil(bill("hr", status).endedCongress(at: Self.februaryFirst), "\(status)")
        }
        XCTAssertNil(bill("hr", .updated, vetoed: true).endedCongress(at: Self.februaryFirst), "vetoed")
        // Updated with a passage in its actions: no note before February 1, so no stamp.
        XCTAssertNil(bill("hr", .updated, actions: [housePassage]).endedCongress(at: Self.noon))
        XCTAssertEqual(bill("hr", .updated, actions: [housePassage]).endedCongress(at: Self.februaryFirst), 119)
        // An agreed-to resolution is finished, not ended.
        XCTAssertNil(bill("hres", .updated, actions: [housePassage]).endedCongress(at: Self.februaryFirst))

        XCTAssertEqual(bill("hr", .updated).outcomeLabel(at: Self.noon), "Ended with the 119th Congress")
        XCTAssertEqual(bill("hr", .updated).outcomeLabel(at: Self.beforeNoon), "Updated")
        XCTAssertEqual(bill("hr", .failed).outcomeLabel(at: Self.noon), "Failed")
    }

    func testTheStampIsLongInInk3SingleRuledAndReadTheSame() {
        let kind = StatusStamp.Kind(status: .updated, endedCongress: 119)
        XCTAssertEqual(kind, .ended(congress: 119))
        XCTAssertEqual(kind.word, "Ended with the 119th Congress")
        XCTAssertEqual(kind.spokenWord, "Ended with the 119th Congress")
        XCTAssertEqual(kind.paletteToken, BillboardPalette.dimText)
        XCTAssertFalse(kind.isDoubleRuled)
        XCTAssertEqual(StatusStamp.Kind.ended(congress: 121).word, "Ended with the 121st Congress")
        // Outcomes stand over it.
        XCTAssertEqual(StatusStamp.Kind(status: .passed, endedCongress: 119), .passed)
        XCTAssertEqual(StatusStamp.Kind(status: .failed, endedCongress: 119), .failed)
        XCTAssertEqual(StatusStamp.Kind(status: .finalized, endedCongress: 119), .becameLaw)
        XCTAssertEqual(StatusStamp.Kind(status: .new, vetoed: true, endedCongress: 119), .vetoed)
        // A group whose lead has no outcome is plainly ended; a lead with an outcome keeps its number.
        XCTAssertEqual(StatusStamp.Kind.docket(status: .updated, endedCongress: 119, companionLead: "S. 12"), .ended(congress: 119))
        XCTAssertEqual(
            StatusStamp.Kind.docket(status: .passed, endedCongress: nil, companionLead: "S. 12"),
            .companionLead(number: "S. 12", status: .passed)
        )
    }

    func testSlipsDocketLinesAndUpdatesRowsReadTheStamp() {
        let profile = UserProfile.placeholder()
        let ended = bill("hr", .updated)
        let slip = BillSlipContent(bill: ended, profile: profile, now: Self.noon)
        XCTAssertEqual(slip.stamp, .ended(congress: 119))
        XCTAssertTrue(slip.accessibilityLabel().contains("Ended with the 119th Congress."), slip.accessibilityLabel())
        XCTAssertEqual(BillSlipContent(bill: ended, profile: profile, now: Self.beforeNoon).stamp, .updated)

        XCTAssertEqual(
            DocketLine(number: "H.R. 12", status: .updated, endedCongress: 119).accessibilityText,
            "House bill 12. Ended with the 119th Congress."
        )
        XCTAssertEqual(
            DocketLine(numbers: ["H.R. 12", "S. 12"], chamber: nil, status: .new, endedCongress: 119, companionLead: "S. 12").accessibilityText,
            "House bill 12 and Senate bill 12. Ended with the 119th Congress."
        )
        XCTAssertEqual(DocketLine(number: "H.R. 12", status: .failed, endedCongress: 119).accessibilityText, "House bill 12. Failed.")

        XCTAssertTrue(UpdatesOutcomeRow(bill: bill("hr", .failed), now: Self.noon).accessibilityText.contains("House bill 12. Failed."))
        let page = BillFrontMatter.Content(bill: ended, now: Self.noon)
        XCTAssertEqual(page.endedCongress, 119)
        XCTAssertEqual(page.endedNote, Self.billNote)
    }

    func testTheWeeklyBriefStampsAnEndedItemAndKeepsItsDate() {
        func item(_ state: WeeklyDigestItem.BillState, eyebrow: String, vetoed: Bool? = nil) -> WeeklyDigestItem {
            WeeklyDigestItem(
                id: "bill|BILLS-119hr12", kind: .bill, title: "A bill", eyebrow: eyebrow, summary: "A summary.",
                detail: nil, reason: nil, accent: .attention, billState: state, vetoed: vetoed, billGuid: "BILLS-119hr12",
                primaryMemberBioguideID: nil
            )
        }
        let updated = item(.updated, eyebrow: "Ended with the 119th Congress Jan 8")
        XCTAssertEqual(updated.endedCongress(at: Self.noon), 119)
        XCTAssertNil(updated.endedCongress(at: Self.beforeNoon))
        XCTAssertNil(item(.passed, eyebrow: "Passed Jan 8").endedCongress(at: Self.februaryFirst))
        XCTAssertNil(item(.updated, eyebrow: "Updated Jan 8", vetoed: true).endedCongress(at: Self.noon))
        XCTAssertEqual(updated.dateEyebrow, "Jan 8", "the stamp says it; the eyebrow keeps the date")
        XCTAssertTrue(
            WeeklyBriefItemView(item: updated, now: Self.noon).accessibilityText.contains("House bill 12. Ended with the 119th Congress."),
            WeeklyBriefItemView(item: updated, now: Self.noon).accessibilityText
        )
    }

    /// A group's status lead carries the ended Congress; a lead with no loaded bill is read from its guid.
    func testACompanionGroupLedByAnEndedMemberIsEnded() {
        let house = "BILLS-119hr12"
        let senate = "BILLS-119s12"
        let group = BillCompanionGroup(primaryGuid: house, memberGuids: [house, senate], relationship: "identical")
        let index = CompanionGroupIndex(groups: [group])

        let lead = index.statusLead(for: group, memberBills: [bill("hr", .new), bill("s", .updated)], now: Self.noon)
        XCTAssertEqual(lead.guid, senate)
        XCTAssertEqual(lead.endedCongress, 119)
        XCTAssertEqual(lead.label, "Ended with the 119th Congress", "the whole group ended: no member named")
        let slip = BillSlipContent(
            bill: bill("hr", .new), profile: .placeholder(), companion: BillCompanionDisplay(group: group, statusLead: lead), now: Self.noon
        )
        XCTAssertEqual(slip.stamp, .ended(congress: 119))

        XCTAssertEqual(index.statusLead(for: group, memberBills: [], now: Self.noon).endedCongress, 119, "nothing loaded")
        XCTAssertNil(index.statusLead(for: group, memberBills: [bill("hr", .new)], now: Self.beforeNoon).endedCongress)

        // A partner that passed leads with its outcome, and the group's slip names it.
        let passedLead = index.statusLead(for: group, memberBills: [bill("hr", .new), bill("s", .passed)], now: Self.februaryFirst)
        XCTAssertNil(passedLead.endedCongress)
        let passedSlip = BillSlipContent(
            bill: bill("hr", .new), profile: .placeholder(), companion: BillCompanionDisplay(group: group, statusLead: passedLead),
            now: Self.februaryFirst
        )
        XCTAssertEqual(passedSlip.stamp, .companionLead(number: "S. 12", status: .passed), "the lead's outcome, not the bill's own end")
    }

    // MARK: - The bill page's note and one-chamber line

    func testTheBillPageShowsTheNoteWithHowFarAPassedBillGot() {
        let houseOnly = bill("hr", .passed, actions: [housePassage])
        XCTAssertNil(houseOnly.oneChamberLine(at: Self.januaryThirtyFirstLate))
        XCTAssertEqual(houseOnly.oneChamberLine(at: Self.februaryFirst), "Passed the House only.")
        XCTAssertEqual(bill("s", .failed, actions: [senatePassage]).oneChamberLine(at: Self.februaryFirst), "Passed the Senate only.")
        XCTAssertNil(bill("hr", .passed, actions: [housePassage, senatePassage]).oneChamberLine(at: Self.februaryFirst), "both chambers")
        XCTAssertNil(bill("hr", .passed, actions: [housePassage, presented]).oneChamberLine(at: Self.februaryFirst), "sent to the President")
        XCTAssertNil(bill("hr", .passed).oneChamberLine(at: Self.februaryFirst), "a manifest row has no actions to read")
        XCTAssertNil(bill("hres", .passed, actions: [housePassage]).oneChamberLine(at: Self.februaryFirst), "an agreed-to resolution has no note")

        let page = BillFrontMatter.Content(bill: houseOnly, now: Self.februaryFirst)
        XCTAssertEqual(page.endedLines, ["Passed the House only.", Self.billNote])
        XCTAssertEqual(page.endedCongress, nil, "PASSED stands")
        XCTAssertTrue(BillFrontMatter.Content(bill: houseOnly, now: Self.noon).endedLines.isEmpty)

        let text = AccessibilityTreeText.text(of: BillFrontMatter(page))
        XCTAssertTrue(text.contains("Passed the House only. \(Self.billNote)"), text)
        let host = AccessibilityTreeText.Host(BillFrontMatter(page))
        defer { host.close() }
        XCTAssertEqual(host.label(ofIdentifier: BillFrontMatter.endedNoteIdentifier), "Passed the House only. \(Self.billNote)", "one element")
    }

    /// The note and the long stamp at AX5: they wrap, never truncate, and the page grows.
    func testTheEndedFrontMatterGrowsAtAccessibilitySizes() throws {
        let ended = BillFrontMatter(BillFrontMatter.Content(bill: bill("hr", .updated, title: "Clean Energy Reporting Act"), now: Self.noon))
        let plain = BillFrontMatter(BillFrontMatter.Content(bill: bill("hr", .updated, title: "Clean Energy Reporting Act"), now: Self.beforeNoon))
        let large = try XCTUnwrap(renderHeight(ended, size: .large))
        XCTAssertGreaterThan(large, try XCTUnwrap(renderHeight(plain, size: .large)), "the note takes room")
        XCTAssertGreaterThan(try XCTUnwrap(renderHeight(ended, size: .accessibility5)), large)

        let stampLarge = try XCTUnwrap(renderHeight(StatusStamp(.ended(congress: 119)), size: .large, width: 375))
        let stampAX5 = try XCTUnwrap(renderHeight(StatusStamp(.ended(congress: 119)), size: .accessibility5, width: 375))
        let oneLineAX5 = try XCTUnwrap(renderHeight(StatusStamp(.new), size: .accessibility5, width: 375))
        XCTAssertEqual(stampLarge, 20, "one line at the default size")
        XCTAssertGreaterThan(stampAX5, oneLineAX5 * 3 / 2, "the long stamp wraps at AX5 rather than truncating")
    }

    private func renderHeight<Content: View>(_ view: Content, size: DynamicTypeSize, width: CGFloat = 390) throws -> Int? {
        let renderer = ImageRenderer(content: view.background(BillboardColors.document).environment(\.dynamicTypeSize, size))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.cgImage?.height
    }

    // MARK: - Off the Bills list, and no widening past the Congress's start

    func testTheBillsListLeavesAnEarlierCongressesBillsOut() {
        let old = bill("hr", .new, congress: 119, number: 1)
        let oldUpdated = bill("hr", .updated, congress: 119, number: 2)
        let current = bill("hr", .new, congress: 120, number: 3)
        let bills = [old, oldUpdated, current]
        let noVotes: (String) -> VoteState = { _ in .unknown }

        func pending(_ congress: Int, companions: CompanionGroupIndex = .empty) -> [String] {
            BillboardQueueDerivation.snapshot(
                bills: bills,
                dismissedBillIDs: [],
                userProfile: .placeholder(),
                historyWindow: .oneWeek,
                voteIndex: UpdatesDerivation.voteIdentityIndex(for: bills, voteLookup: noVotes, companions: companions),
                voteLookup: noVotes,
                starterFeedEnabled: false,
                currentCongress: congress
            ).pendingBills.compactMap(\.guid)
        }
        XCTAssertEqual(pending(119), ["BILLS-119hr1", "BILLS-119hr2", "BILLS-120hr3"], "before the changeover")
        XCTAssertEqual(pending(120), ["BILLS-120hr3"], "ungrouped")

        // Grouped: an ended group is closed; a group of the Congress in office stays.
        let oldGroup = BillCompanionGroup(primaryGuid: "BILLS-119hr1", memberGuids: ["BILLS-119hr1", "BILLS-119hr2"], relationship: "identical")
        XCTAssertEqual(pending(120, companions: CompanionGroupIndex(groups: [oldGroup])), ["BILLS-120hr3"], "grouped")
        XCTAssertEqual(pending(119, companions: CompanionGroupIndex(groups: [oldGroup])), ["BILLS-119hr1", "BILLS-120hr3"])
    }

    func testWideningStopsOnceTheWindowReachesTheCongresssStart() {
        let januaryTenth = Self.at("2027-01-10T18:00:00Z")
        XCTAssertTrue(BillboardHistoryWindow.oneWeek.canExpandFurther(now: januaryTenth), "a week back is still in the 120th")
        XCTAssertFalse(BillboardHistoryWindow.twoWeeks.canExpandFurther(now: januaryTenth), "two weeks back reaches the 119th")
        XCTAssertFalse(BillboardHistoryWindow.oneWeek.canExpandFurther(now: Self.at("2027-01-05T12:00:00Z")))

        let lateInTheCongress = Self.at("2026-11-20T12:00:00Z")
        XCTAssertTrue(BillboardHistoryWindow(rawValue: 357).canExpandFurther(now: lateInTheCongress))
        XCTAssertFalse(BillboardHistoryWindow.maxExpanded.canExpandFurther(now: lateInTheCongress), "a year at most, as before")

        XCTAssertEqual(
            BillBoardCaughtUpState(windowTitle: "1 week", canExpand: false).message,
            "No bills left to vote on from the last 1 week.",
            "no 'Pull down' once the window stops"
        )
    }
}
