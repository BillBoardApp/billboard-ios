import XCTest
@testable import Billboard

/// What happens next (UX-41 concept 1, `AfterVoteSummary`): the latest action, the person's members on this bill's roll
/// calls under their own vote, the chamber lines and the promise. It never says a chamber has no recorded vote unless
/// it knows (a companion's roll call, a member not loaded, an action that mentions a roll call), never prints "Not
/// voting" for a member missing from a roll call, picks the same members as How Congress voted, and is the same after
/// Yea, Nay and Abstain but for the "You" row.
@MainActor
final class BillAfterVoteTests: XCTestCase {
    /// December 15, 2026: the 119th Congress is in office.
    private nonisolated static let before120th = Date(timeIntervalSince1970: 1_797_354_000)
    /// January 10, 2027: the 120th Congress is in office, and 119th bills stay open.
    private nonisolated static let after120th = Date(timeIntervalSince1970: 1_799_600_400)
    private static let locale = Locale(identifier: "en_US")
    private static let newYork = TimeZone(identifier: "America/New_York")!

    // MARK: - Fixtures

    private static func member(_ id: String, _ name: String, _ party: String, _ state: String, _ district: String?, _ position: String) -> Bill.OfficialVoteMember {
        Bill.OfficialVoteMember(bioguideId: id, displayName: name, party: party, state: state, district: district, votePosition: position)
    }

    private static func rollCall(_ members: [Bill.OfficialVoteMember]) -> Bill.OfficialChamberVote {
        let yea = members.filter { CongressMemberVoteRow.position($0.votePosition).choice == .yea }.count
        return Bill.OfficialChamberVote(
            yea: yea, nay: members.count - yea, present: 0, notVoting: 0, totalCounted: members.count,
            actionCode: nil, actionDate: "2026-10-13", resultText: "Passed", memberDataAvailable: true,
            members: members
        )
    }

    private static func action(_ date: String, _ text: String, code: String? = nil, type: String = "Floor") -> Bill.BillAction {
        Bill.BillAction(actionCode: code, actionDate: date, text: text, type: type, sourceSystem: nil, committees: nil)
    }

    private static let introduced = [
        action("2026-10-09", "Referred to the House Committee on Energy and Commerce.", type: "IntroReferral"),
        action("2026-10-09", "Introduced in House.", type: "IntroReferral")
    ]

    private static func bill(
        _ guid: String = "BILLS-119hr1234",
        house: [Bill.OfficialVoteMember]? = nil,
        senate: [Bill.OfficialVoteMember]? = nil,
        actions: [Bill.BillAction]? = nil
    ) -> Bill {
        let votes = house == nil && senate == nil ? nil : Bill.OfficialVotesBreakdown(
            house: house.map(rollCall),
            senate: senate.map(rollCall),
            lastSyncedAt: nil,
            source: nil,
            completeness: nil
        )
        return Bill(
            id: UUID.deterministic(from: guid),
            title: "Clean Energy Reporting Act",
            category: "Energy",
            soWhat: "",
            link: "https://www.govinfo.gov/app/details/\(guid)ih",
            actions: actions ?? introduced,
            billStatus: .new,
            guid: guid,
            userVoted: false,
            officialVotes: votes,
            isProcessedDetailHydrated: true
        )
    }

    private static func manifestMember(_ id: String, _ name: String, chamber: String, state: String, district: Int? = nil, party: String) throws -> CongressMemberManifestItem {
        let district = district.map { #","district":\#($0)"# } ?? ""
        let json = #"{"bioguideId":"\#(id)","name":"\#(name)","chamber":"\#(chamber)","state":"\#(state)","party":"\#(party)"\#(district)}"#
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data(json.utf8))
    }

    /// The 119th Congress's roster, in roster order: Texas's senators Riley Hart and Avery Stone, TX-7's Jordan Ellis,
    /// TX-8's Morgan Fry; Alaska's, DC's delegate and Puerto Rico's member; an Ohio senator.
    private static func roster119() throws -> [CongressMemberManifestItem] {
        [
            try manifestMember("A000001", "Quinn Alder", chamber: "Senate", state: "AK", party: "R"),
            try manifestMember("A000002", "Drew Birch", chamber: "Senate", state: "AK", party: "R"),
            try manifestMember("A000003", "Sky Cedar", chamber: "House of Representatives", state: "AK", district: 0, party: "R"),
            try manifestMember("E000001", "Jordan Ellis", chamber: "House of Representatives", state: "TX", district: 7, party: "R"),
            try manifestMember("E000002", "Morgan Fry", chamber: "House of Representatives", state: "TX", district: 8, party: "D"),
            try manifestMember("T000011", "Riley Hart", chamber: "Senate", state: "TX", party: "R"),
            try manifestMember("M000020", "Casey Moore", chamber: "Senate", state: "OH", party: "D"),
            try manifestMember("N000001", "Lee Norton", chamber: "House of Representatives", state: "DC", party: "D"),
            try manifestMember("P000001", "Rae Palm", chamber: "House of Representatives", state: "PR", district: 98, party: "R"),
            try manifestMember("T000010", "Avery Stone", chamber: "Senate", state: "TX", party: "R")
        ]
    }

    /// The 120th Congress's roster: Jordan Ellis won Riley Hart's Senate seat, and after redistricting Morgan Fry sits
    /// for TX-7.
    private static func roster120() throws -> [CongressMemberManifestItem] {
        [
            try manifestMember("E000001", "Jordan Ellis", chamber: "Senate", state: "TX", party: "R"),
            try manifestMember("E000002", "Morgan Fry", chamber: "House of Representatives", state: "TX", district: 7, party: "D"),
            try manifestMember("T000010", "Avery Stone", chamber: "Senate", state: "TX", party: "R")
        ]
    }

    private static let houseRows = [
        member("E000001", "Jordan Ellis", "R", "TX", "7", "Yea"),
        member("E000002", "Morgan Fry", "D", "TX", "8", "Nay"),
        member("A000003", "Sky Cedar", "R", "AK", "0", "Nay"),
        member("N000001", "Lee Norton", "D", "DC", nil, "Present"),
        member("P000001", "Rae Palm", "R", "PR", "98", "Yea")
    ]

    private static let senateRows = [
        member("T000010", "Avery Stone", "R", "TX", nil, "Yea"),
        member("T000011", "Riley Hart", "R", "TX", nil, "No"),
        member("A000001", "Quinn Alder", "R", "AK", nil, "Yea"),
        member("A000002", "Drew Birch", "R", "AK", nil, "Not Voting"),
        member("M000020", "Casey Moore", "D", "OH", nil, "Yea")
    ]

    private func summary(
        _ bill: Bill,
        vote: VoteChoice = .yea,
        state: String = "TX",
        district: String = "7",
        manifest: [CongressMemberManifestItem]? = nil,
        representatives: AfterVoteSummary.Representatives? = nil,
        companions: [Bill?] = [],
        block: BillWatchNotificationBlock? = nil,
        isWatching: Bool = false,
        isVoteSaved: Bool = true,
        now: Date = BillAfterVoteTests.before120th
    ) throws -> AfterVoteSummary {
        let known = AfterVoteSummary.Representatives.known(state: state, district: district, manifest: try manifest ?? Self.roster119())
        return AfterVoteSummary(
            bill: bill,
            vote: vote,
            representatives: representatives ?? known,
            companions: companions,
            block: block,
            isWatching: isWatching,
            isVoteSaved: isVoteSaved,
            now: now,
            locale: Self.locale,
            timeZone: Self.newYork
        )
    }

    private func names(_ summary: AfterVoteSummary) -> [String] {
        summary.representatives?.members.map(\.member.displayName) ?? []
    }

    // MARK: - The words

    func testTheWords() {
        XCTAssertEqual(AfterVoteCopy.title, "What happens next")
        XCTAssertEqual(AfterVoteCopy.latestActionLabel, "Latest action")
        XCTAssertEqual(AfterVoteCopy.representativesTitle, "Your representatives")
        XCTAssertEqual(AfterVoteCopy.you, "You")
        XCTAssertEqual(VoteChoice.allCases.map(AfterVoteCopy.youAccessibilityLabel), ["You, Yea.", "You, Nay.", "You, Abstain."])
        XCTAssertEqual(AfterVoteCopy.noRecordedVote(in: .house), "The House hasn't held a recorded vote on this bill.")
        XCTAssertEqual(AfterVoteCopy.noRecordedVote(in: .senate), "The Senate hasn't held a recorded vote on this bill.")
        XCTAssertEqual(AfterVoteCopy.noRecordedVoteYet, "Congress hasn't held a recorded vote on this bill yet.")
        XCTAssertEqual(
            AfterVoteCopy.passedWithoutRecordedVote(in: .house),
            "The House passed it without a recorded vote, so there are no member votes."
        )
        XCTAssertEqual(
            AfterVoteCopy.passedWithoutRecordedVote(in: .senate),
            "The Senate passed it without a recorded vote, so there are no member votes."
        )
        XCTAssertEqual(AfterVoteCopy.addAddress, "Add your address in Profile to see how your representatives voted.")
        XCTAssertEqual(AfterVoteCopy.voterPromise, "You'll get notified when Congress acts on it.")
    }

    // MARK: - Latest action

    func testTheLatestActionIsCongresssOwnWordsWithTheShortDate() throws {
        let bill = Self.bill(actions: [Self.action("2026-10-27", "Subcommittee hearings held.", type: "Committee")] + Self.introduced)
        let latest = try XCTUnwrap(try summary(bill).latestAction)
        XCTAssertEqual(latest.text, "Subcommittee hearings held.")
        XCTAssertEqual(latest.date, "Oct 27")
        XCTAssertEqual(latest.accessibilityLabel, "Latest action: Subcommittee hearings held. October 27.")

        let lastYear = Self.bill(actions: [Self.action("2025-12-30", "Introduced in House.", type: "IntroReferral")])
        XCTAssertEqual(try summary(lastYear).latestAction?.date, "Dec 30, 2025", "another year carries its year")

        XCTAssertNil(try summary(Self.bill(actions: [])).latestAction, "no action, no row")
    }

    // MARK: - Chamber lines

    func testNoRollCallSaysCongressHasntHeldOne() throws {
        let result = try summary(Self.bill())
        XCTAssertEqual(result.chamberLines, ["Congress hasn't held a recorded vote on this bill yet."])
        XCTAssertEqual(result.representatives?.you, .yea)
        XCTAssertEqual(names(result), [], "no roll call, no member rows")
    }

    func testAHouseRollCallOnly() throws {
        let result = try summary(Self.bill(house: Self.houseRows))
        XCTAssertEqual(result.chamberLines, ["The Senate hasn't held a recorded vote on this bill."])
        XCTAssertEqual(names(result), ["Jordan Ellis"], "the senators have no roll call to be on")
    }

    func testBothChambersListTheSenatorsInRosterOrderThenTheHouseMember() throws {
        let result = try summary(Self.bill(house: Self.houseRows, senate: Self.senateRows))
        XCTAssertEqual(result.chamberLines, [])
        XCTAssertEqual(names(result), ["Riley Hart", "Avery Stone", "Jordan Ellis"])
        XCTAssertEqual(result.representatives?.members.map(\.position.word), ["Nay", "Yea", "Yea"], "No is Nay")
        XCTAssertEqual(result.representatives?.members.map(\.chamber), [.senate, .senate, .house])
    }

    /// A passage with no roll call (a voice vote, unanimous consent) says so per chamber. A passage whose words mention
    /// a roll call that the bill does not carry yet gets no line, never "without a recorded vote".
    func testAVoiceVotePassageSaysThereAreNoMemberVotes() throws {
        let voice = Self.action(
            "2026-10-20",
            "Passed/agreed to in House: On motion to suspend the rules and pass the bill Agreed to by voice vote.",
            code: EndedCongress.housePassageCode
        )
        let byVoice = try summary(Self.bill(actions: [voice] + Self.introduced))
        XCTAssertEqual(byVoice.chamberLines, [
            "The House passed it without a recorded vote, so there are no member votes.",
            "The Senate hasn't held a recorded vote on this bill."
        ])
        XCTAssertEqual(names(byVoice), [])

        let consent = Self.action("2026-10-22", "Passed Senate without amendment by Unanimous Consent.", code: EndedCongress.senatePassageCode)
        let senateByConsent = try summary(Self.bill(house: Self.houseRows, actions: [consent] + Self.introduced))
        XCTAssertEqual(senateByConsent.chamberLines, ["The Senate passed it without a recorded vote, so there are no member votes."])
        XCTAssertEqual(names(senateByConsent), ["Jordan Ellis"])

        let notCaughtUp = Self.action(
            "2026-10-20",
            "Passed/agreed to in House: On passage Passed by the Yeas and Nays: 231 - 196 (Roll no. 123).",
            code: EndedCongress.housePassageCode
        )
        XCTAssertEqual(
            try summary(Self.bill(actions: [notCaughtUp] + Self.introduced)).chamberLines,
            ["The Senate hasn't held a recorded vote on this bill."],
            "the House's roll call is not on the bill yet: no House line"
        )
        let senateRecord = Self.action("2026-10-22", "Passed Senate with an amendment by Yea-Nay Vote. 52 - 47. Record Vote Number: 45.")
        XCTAssertEqual(try summary(Self.bill(house: Self.houseRows, actions: [senateRecord] + Self.introduced)).chamberLines, [])
    }

    /// A House floor action often does not name the House, and the app gets no action's source system: "(Roll no. …)"
    /// is the House's roll call and "Record Vote Number" the Senate's, whatever chamber the words name. Until the roll
    /// call is on the bill, that chamber gets no line.
    func testARollCallInAnActionThatNamesNoChamberGetsNoLine() throws {
        let failedSuspension = Self.action(
            "2026-10-20",
            "On motion to suspend the rules and pass the bill Failed by the Yeas and Nays: (2/3 required): 250 - 170 (Roll no. 150).",
            code: "H37300"
        )
        XCTAssertEqual(
            try summary(Self.bill(actions: [failedSuspension] + Self.introduced)).chamberLines,
            ["The Senate hasn't held a recorded vote on this bill."],
            "the House's roll call is not on the bill yet: no House line"
        )
        let agreeingToTheSenateAmendment = Self.action(
            "2026-10-24",
            "On motion that the House agree to the Senate amendment Agreed to by the Yeas and Nays: 300 - 100 (Roll no. 200)."
        )
        XCTAssertEqual(
            try summary(Self.bill(senate: Self.senateRows, actions: [agreeingToTheSenateAmendment] + Self.introduced)).chamberLines,
            [],
            "a House roll call that names the Senate"
        )
        let cloture = Self.action("2026-10-22", "Cloture motion on the motion to proceed invoked by Yea-Nay Vote. 60 - 38. Record Vote Number: 99.")
        XCTAssertEqual(
            try summary(Self.bill(house: Self.houseRows, actions: [cloture] + Self.introduced)).chamberLines,
            [],
            "the Senate's record vote is not on the bill yet: no Senate line"
        )

        XCTAssertEqual(AfterVoteSummary.recordedVoteChambers(of: failedSuspension), [.house])
        XCTAssertEqual(AfterVoteSummary.recordedVoteChambers(of: agreeingToTheSenateAmendment), [.house])
        XCTAssertEqual(AfterVoteSummary.recordedVoteChambers(of: cloture), [.senate])
        XCTAssertEqual(AfterVoteSummary.recordedVoteChambers(of: Self.action("2026-10-25", "Motion to reconsider laid on the table Agreed to without objection.")), [])
        XCTAssertEqual(
            AfterVoteSummary.recordedVoteChambers(of: Self.action("2026-10-25", "House and Senate conferees agreed by recorded vote.")),
            [.house, .senate],
            "a recorded vote that names both chambers counts for both"
        )
    }

    /// A bill that reached the President passed both chambers, as `EndedCongress.actionsShowPassage` reads it.
    func testABillThatReachedThePresidentPassedBothChambers() throws {
        let presented = Self.action("2026-11-02", "Presented to President.", type: "President")
        XCTAssertEqual(try summary(Self.bill(house: Self.houseRows, actions: [presented] + Self.introduced)).chamberLines, [
            "The Senate passed it without a recorded vote, so there are no member votes."
        ])
    }

    /// A simple resolution goes through its own chamber only.
    func testASimpleResolutionHasOneChamber() throws {
        XCTAssertEqual(try summary(Self.bill("BILLS-119hres50")).chamberLines, ["The House hasn't held a recorded vote on this bill."])
        XCTAssertEqual(try summary(Self.bill("BILLS-119sres12")).chamberLines, ["The Senate hasn't held a recorded vote on this bill."])
        XCTAssertEqual(try summary(Self.bill("BILLS-119hconres3")).chamberLines, ["Congress hasn't held a recorded vote on this bill yet."])
    }

    // MARK: - Members

    /// A member who did not vote reads "Not voting"; one missing from the roll call (sworn in later) has no row.
    func testAMemberWhoDidNotVoteAndOneMissingFromTheList() throws {
        let house = [Self.member("E000001", "Jordan Ellis", "R", "TX", "7", "Not Voting")]
        let senate = [Self.member("T000010", "Avery Stone", "R", "TX", nil, "Nay")]
        let result = try summary(Self.bill(house: house, senate: senate))
        XCTAssertEqual(names(result), ["Avery Stone", "Jordan Ellis"], "Riley Hart is not on the Senate's list")
        XCTAssertEqual(result.representatives?.members.map(\.position.word), ["Nay", "Not voting"])
        XCTAssertNil(result.representatives?.members.last?.position.choice, "Not voting is a plain word")

        let noMembers = Bill.OfficialChamberVote(
            yea: 231, nay: 196, present: 0, notVoting: 0, totalCounted: 427,
            actionCode: nil, actionDate: "2026-10-12", resultText: "Passed", memberDataAvailable: false, members: []
        )
        var countsOnly = Self.bill()
        countsOnly.officialVotes = Bill.OfficialVotesBreakdown(house: noMembers, senate: nil, lastSyncedAt: nil, source: nil, completeness: "none")
        let waiting = try summary(countsOnly)
        XCTAssertEqual(names(waiting), [], "no member rows yet: never a false Not voting")
        XCTAssertEqual(waiting.chamberLines, ["The Senate hasn't held a recorded vote on this bill."], "the House voted")
    }

    /// An at-large seat, DC's delegate and a territory's member, picked as the Congress tab picks them.
    func testAnAtLargeSeatDCsDelegateAndATerritoryMember() throws {
        let bill = Self.bill(house: Self.houseRows, senate: Self.senateRows)
        let alaska = try summary(bill, state: "AK", district: "At-Large")
        XCTAssertEqual(names(alaska), ["Quinn Alder", "Drew Birch", "Sky Cedar"])
        XCTAssertEqual(alaska.representatives?.members.map(\.position.word), ["Yea", "Not voting", "Nay"])
        let dc = try summary(bill, state: "DC", district: "At-Large")
        XCTAssertEqual(names(dc), ["Lee Norton"], "no senators")
        XCTAssertEqual(dc.representatives?.members.first?.position.word, "Present")
        XCTAssertEqual(names(try summary(bill, state: "PR", district: "At-Large")), ["Rae Palm"], "a territory's member")
    }

    func testNoAddressAsksForOne() throws {
        let bill = Self.bill(house: Self.houseRows, senate: Self.senateRows)
        for result in [try summary(bill, representatives: .noAddress), try summary(bill, state: " ", district: "")] {
            let part = try XCTUnwrap(result.representatives)
            XCTAssertTrue(part.asksForAddress)
            XCTAssertEqual(part.you, .yea)
            XCTAssertEqual(part.members, [])
        }
        XCTAssertFalse(try summary(bill).representatives?.asksForAddress ?? true)
    }

    /// While the profile or the members manifest has not loaded, Your representatives is left out: never a false "no
    /// vote" for members not known yet. The chamber lines stand.
    func testNothingAboutMembersWhileTheManifestHasNotLoaded() throws {
        for result in [try summary(Self.bill(house: Self.houseRows), representatives: .notLoaded), try summary(Self.bill(house: Self.houseRows), manifest: [])] {
            XCTAssertNil(result.representatives)
            XCTAssertEqual(result.chamberLines, ["The Senate hasn't held a recorded vote on this bill."])
        }
    }

    // MARK: - Companion groups

    /// A companion group whose Senate roll call is on the S. bill: the senators' votes come from it and no Senate line
    /// shows. While the S. bill is not loaded the Senate gets no line and no rows.
    func testACompanionGroupsSenateRollCallOnTheSBill() throws {
        let house = Self.bill(house: Self.houseRows)
        let senateBill = Self.bill("BILLS-119s456", senate: Self.senateRows)
        let loaded = try summary(house, companions: [senateBill])
        XCTAssertEqual(loaded.chamberLines, [])
        XCTAssertEqual(names(loaded), ["Riley Hart", "Avery Stone", "Jordan Ellis"])

        let notLoaded = try summary(house, companions: [nil])
        XCTAssertEqual(notLoaded.chamberLines, [], "never a false Senate line")
        XCTAssertEqual(names(notLoaded), ["Jordan Ellis"])

        let noSenateVote = try summary(house, companions: [Self.bill("BILLS-119s456")])
        XCTAssertEqual(noSenateVote.chamberLines, ["The Senate hasn't held a recorded vote on this bill."], "both members read")

        let neither = try summary(Self.bill(), companions: [nil])
        XCTAssertEqual(neither.chamberLines, [], "no line for either chamber while a member is not loaded")
    }

    // MARK: - Ended Congress

    /// A 119th bill after January 3, 2027 (still votable, D66): no promise and no "yet" line, the per-chamber lines
    /// stay, and members by How Congress voted's seat rule.
    func testAnEndedCongressBillDropsThePromiseAndTheYetLine() throws {
        let noVotes = try summary(Self.bill(), now: Self.after120th)
        XCTAssertEqual(noVotes.chamberLines, [
            "The House hasn't held a recorded vote on this bill.",
            "The Senate hasn't held a recorded vote on this bill."
        ])
        XCTAssertNil(noVotes.promise)
        XCTAssertNotNil(try summary(Self.bill(), now: Self.before120th).promise)

        // Jordan Ellis is a senator now (his House row is not his seat), and Morgan Fry voted for TX-8.
        let house = [Self.member("E000001", "Jordan Ellis", "R", "TX", "7", "Yea"), Self.member("E000002", "Morgan Fry", "D", "TX", "8", "Nay")]
        let senate = [Self.member("T000010", "Avery Stone", "R", "TX", nil, "Yea")]
        let after = try summary(Self.bill(house: house, senate: senate), manifest: try Self.roster120(), now: Self.after120th)
        XCTAssertEqual(names(after), ["Avery Stone"])
    }

    /// The seat rule, the promise and the "yet" line read one test for an ended Congress, How Congress voted's
    /// (`YourMembersOnRollCalls`), also on the morning of January 3 and without an address.
    func testOneRuleSaysTheCongressHasEnded() throws {
        let times: [(String, Date)] = [
            ("December 15, 2026", Self.before120th),
            ("January 2, 2027, evening", Date(timeIntervalSince1970: 1_798_930_800)),
            ("January 3, 2027, 6 am", Date(timeIntervalSince1970: 1_798_974_000)),
            ("January 3, 2027, 1 pm", Date(timeIntervalSince1970: 1_798_999_200)),
            ("January 10, 2027", Self.after120th)
        ]
        for (name, now) in times {
            let ended = YourMembersOnRollCalls(state: "TX", district: "7", manifest: try Self.roster119(), billCongress: 119, now: now)
                .isFromEndedCongress
            let known: [AfterVoteSummary.Representatives?] = [nil, .noAddress, .notLoaded]
            for representatives in known {
                let result = try summary(Self.bill(), representatives: representatives, now: now)
                XCTAssertEqual(result.promise == nil, ended, "\(name), \(String(describing: representatives)): the promise")
                XCTAssertEqual(
                    result.chamberLines.contains("Congress hasn't held a recorded vote on this bill yet."),
                    !ended,
                    "\(name), \(String(describing: representatives)): the yet line"
                )
            }
        }
    }

    // MARK: - The promise

    func testThePromiseForEachBlockHiddenWhenWatchedAndWhileUnsaved() throws {
        let bill = Self.bill(house: Self.houseRows)
        let cases: [(BillWatchNotificationBlock?, String)] = [
            (nil, "You'll get notified when Congress acts on it."),
            (.permissionOff, "Notifications are off in iOS Settings. Turn them on there to get notified when Congress acts on it."),
            (.permissionNotAsked, "Billboard needs your permission before it can send notifications. Turn them on in Profile."),
            (.notificationsOff, "Notifications are off in Profile. Turn them on there to get notified when Congress acts on it."),
            (.actionsInCongressOff, "Actions in Congress notifications are off in Profile. Turn them on there to get notified when Congress acts on it.")
        ]
        for (block, words) in cases {
            XCTAssertEqual(try summary(bill, block: block).promise, words, "\(String(describing: block))")
            XCTAssertNil(try summary(bill, block: block, isWatching: true).promise, "watched: the Watch row says it")
            XCTAssertNil(try summary(bill, block: block, isVoteSaved: false).promise, "not saved yet (APPF-30)")
        }
    }

    // MARK: - Neutrality and VoiceOver

    /// The block is the same after Yea, Nay and Abstain; only the "You" row follows the vote.
    func testTheSameBlockAfterYeaNayAndAbstain() throws {
        let bill = Self.bill(house: Self.houseRows, senate: Self.senateRows)
        let results = try VoteChoice.allCases.map { try summary(bill, vote: $0) }
        XCTAssertEqual(results.map { $0.representatives?.you }, [.yea, .nay, .abstain])
        for result in results.dropFirst() {
            XCTAssertEqual(result.latestAction, results[0].latestAction)
            XCTAssertEqual(result.chamberLines, results[0].chamberLines)
            XCTAssertEqual(result.promise, results[0].promise)
            XCTAssertEqual(result.representatives?.members, results[0].representatives?.members)
            XCTAssertEqual(result.representatives?.asksForAddress, results[0].representatives?.asksForAddress)
        }
    }

    /// Members are read in the one spoken form with no "your senator" or "your representative": the subhead says whose
    /// they are.
    func testMemberLinesCarryNoYourRoleWords() throws {
        let result = try summary(Self.bill(house: Self.houseRows, senate: Self.senateRows))
        let labels = try XCTUnwrap(result.representatives?.members.map(\.accessibilityLabel))
        XCTAssertEqual(labels, [
            "Senator Riley Hart, Republican, Texas, Nay",
            "Senator Avery Stone, Republican, Texas, Yea",
            "Representative Jordan Ellis, Republican, Texas's 7th district, Yea"
        ])
        for label in labels {
            XCTAssertFalse(label.contains("your senator") || label.contains("your representative"), label)
        }
        XCTAssertEqual(result.representatives?.members.map(\.affiliation), ["R · Senate · TX", "R · Senate · TX", "R · House · TX-7"])
    }

    /// How Congress voted's tags and the block pick the same members, from `YourMemberRole` and
    /// `CongressTabModel.representatives`, for a numbered district, an at-large seat, DC and a territory, during the
    /// bill's Congress and after it.
    func testHowCongressVotedAndTheBlockPickTheSameRepresentatives() throws {
        let seats: [(String, String)] = [("TX", "7"), ("TX", "8"), ("AK", "At-Large"), ("DC", "At-Large"), ("PR", "98"), ("OH", "")]
        let bill = Self.bill(house: Self.houseRows, senate: Self.senateRows)
        for (manifest, now) in [(try Self.roster119(), Self.before120th), (try Self.roster120(), Self.after120th)] {
            for (state, district) in seats {
                let yours = YourMembersOnRollCalls(state: state, district: district, manifest: manifest, billCongress: 119, now: now)
                let tagged = Set(yours.roles(of: Self.houseRows, in: .house).keys).union(yours.roles(of: Self.senateRows, in: .senate).keys)
                let picked = Set(try summary(bill, state: state, district: district, manifest: manifest, now: now).representatives?.members.map(\.id) ?? [])
                XCTAssertEqual(picked, tagged, "\(state)-\(district) at \(now)")
            }
        }
    }
}
