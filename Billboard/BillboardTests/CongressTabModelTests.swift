import SwiftUI
import XCTest
@testable import Billboard

/// The Congress tab's logic (spec D 2.5.8): your representatives, members you follow, member
/// search and filters, the "bills this week" counts, the voting seats every count uses, and the
/// counts and topic metrics on the party and chamber screens. No network; the manifest is a small
/// fixture in roster order.
@MainActor
final class CongressTabModelTests: XCTestCase {
    // MARK: - Fixture

    private enum District {
        case none
        case text(String)
        case number(Int)
    }

    private func member(
        _ id: String,
        _ name: String,
        chamber: String,
        state: String,
        district: District = .none,
        party: String
    ) throws -> CongressMemberManifestItem {
        var fields = [
            #""bioguideId":"\#(id)""#,
            #""name":"\#(name)""#,
            #""chamber":"\#(chamber)""#,
            #""state":"\#(state)""#,
            #""party":"\#(party)""#
        ]
        switch district {
        case .none: break
        case .text(let value): fields.append(#""district":"\#(value)""#)
        case .number(let value): fields.append(#""district":\#(value)"#)
        }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data(json.utf8))
    }

    private let senate = "Senate"
    private let house = "House of Representatives"

    /// Virginia's senators and three of its House members, West Virginia's senators, and members
    /// from elsewhere whose names or districts exercise search; sorted the way the store sorts.
    private func fixture() throws -> [CongressMemberManifestItem] {
        CongressMemberManifestItem.rosterSorted([
            try member("K000384", "Tim Kaine", chamber: senate, state: "VA", party: "D"),
            try member("W000805", "Mark R. Warner", chamber: senate, state: "VA", party: "D"),
            try member("W000831", "James R. Walkinshaw", chamber: house, state: "VA", district: .number(11), party: "D"),
            try member("B001292", "Donald S. Beyer, Jr.", chamber: house, state: "VA", district: .text("8"), party: "D"),
            try member("W000804", "Robert J. Wittman", chamber: house, state: "VA", district: .number(1), party: "R"),
            try member("C001047", "Shelley Moore Capito", chamber: senate, state: "WV", party: "R"),
            try member("J000312", "James C. Justice", chamber: senate, state: "WV", party: "R"),
            try member("B001323", "Nicholas J. Begich", chamber: house, state: "AK", party: "R"),
            try member("N000147", "Eleanor Holmes Norton", chamber: house, state: "DC", district: .number(0), party: "D"),
            try member("V000081", "Nydia M. Velázquez", chamber: house, state: "NY", district: .number(7), party: "D"),
            try member("V000130", "Juan Vargas", chamber: house, state: "CA", district: .number(52), party: "D"),
            try member("V000128", "Chris Van Hollen", chamber: senate, state: "MD", party: "D"),
            try member("S000033", "Bernard Sanders", chamber: senate, state: "VT", party: "I")
        ])
    }

    private func ids(_ members: [CongressMemberManifestItem]) -> [String] {
        members.map(\.id)
    }

    // MARK: - Your representatives

    func testRepresentativesAreTheSenatorsThenTheHouseMember() throws {
        let manifest = try fixture()

        let reps = CongressTabModel.representatives(state: "VA", district: "11", in: manifest)

        XCTAssertEqual(ids(reps), ["K000384", "W000805", "W000831"])
    }

    func testRepresentativesAcceptEveryStoredDistrictFormat() throws {
        let manifest = try fixture()
        for district in ["11", "011", "VA-11", "va 11", "11th"] {
            let reps = CongressTabModel.representatives(state: " va ", district: district, in: manifest)
            XCTAssertEqual(ids(reps).last, "W000831", district)
        }
        // District 1 is not district 11 or 10.
        XCTAssertEqual(ids(CongressTabModel.representatives(state: "VA", district: "1", in: manifest)).last, "W000804")
    }

    func testRepresentativesWithoutADistrictMatchAreTheSenatorsOnly() throws {
        let manifest = try fixture()

        XCTAssertEqual(ids(CongressTabModel.representatives(state: "VA", district: "", in: manifest)), ["K000384", "W000805"])
        // A numbered district never falls back to some other House member.
        XCTAssertEqual(ids(CongressTabModel.representatives(state: "VA", district: "12", in: manifest)), ["K000384", "W000805"])
        XCTAssertEqual(CongressTabModel.representatives(state: "", district: "11", in: manifest), [])
    }

    func testAtLargeSeatsMatchAMemberWithoutADistrictNumber() throws {
        let manifest = try fixture()

        // Alaska's member has no district in the manifest; the profile stores at-large as
        // "AT-LARGE" (Census "00" normalizes to it) or "0".
        for district in ["AT-LARGE", "0", "00", "At-Large"] {
            XCTAssertEqual(ids(CongressTabModel.representatives(state: "AK", district: district, in: manifest)), ["B001323"], district)
        }
    }

    func testDCDelegateMatchesTheCensusDelegateCode() throws {
        let manifest = try fixture()

        // Census gives "98" for non-voting delegates; DC has no senators.
        XCTAssertEqual(ids(CongressTabModel.representatives(state: "DC", district: "98", in: manifest)), ["N000147"])
    }

    func testRepresentativesStateCoversLoadingAddressAndNotFound() throws {
        let manifest = try fixture()

        func state(
            loaded: Bool = true,
            _ stateCode: String,
            _ district: String,
            manifest: [CongressMemberManifestItem],
            loading: Bool = false,
            hasLoaded: Bool = true,
            failed: Bool = false
        ) -> CongressRepresentativesState {
            CongressTabModel.representativesState(
                profileLoaded: loaded,
                state: stateCode,
                district: district,
                manifest: manifest,
                manifestIsLoading: loading,
                manifestHasLoaded: hasLoaded,
                manifestFailed: failed
            )
        }

        XCTAssertEqual(state(loaded: false, "", "", manifest: manifest), .loadingProfile)
        XCTAssertEqual(state("", "", manifest: manifest), .needsLocation)
        XCTAssertEqual(state("  ", "11", manifest: manifest), .needsLocation)
        XCTAssertEqual(state("VA", "11", manifest: [], loading: true), .loadingMembers)
        XCTAssertEqual(state("VA", "11", manifest: [], hasLoaded: false), .loadingMembers)
        XCTAssertEqual(state("VA", "11", manifest: [], failed: true), .membersUnavailable)
        XCTAssertEqual(state("VA", "11", manifest: [], hasLoaded: true), .membersUnavailable)
        XCTAssertEqual(state("TX", "7", manifest: manifest), .notFound(region: "TX-7"))
        XCTAssertEqual(state("VA", "11", manifest: manifest), .members(CongressTabModel.representatives(state: "VA", district: "11", in: manifest)))
    }

    // MARK: - Bills this week

    private func manifestItem(_ guid: String, sponsors: [String], cosponsors: [String] = [], updatedAt: String?) -> BillsManifestItem {
        BillsManifestItem(
            guid: guid,
            congress: "119",
            billType: "hr",
            billID: guid,
            updatedAt: updatedAt,
            subCategories: [],
            lifeAreas: [],
            sponsors: sponsors,
            cosponsors: cosponsors,
            title: guid
        )
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-08T12:00:00Z")!

    func testRecentSponsoredBillCountsUseTheBillsWindowAndSponsorsOnly() {
        let items = [
            manifestItem("in-window", sponsors: ["K000384"], updatedAt: "2026-10-07T00:00:00Z"),
            manifestItem("both", sponsors: ["K000384", "W000805"], updatedAt: "2026-10-02T12:00:00.000Z"),
            manifestItem("too-old", sponsors: ["K000384"], updatedAt: "2026-09-20T00:00:00Z"),
            manifestItem("cosponsor-only", sponsors: [], cosponsors: ["K000384"], updatedAt: "2026-10-07T00:00:00Z"),
            manifestItem("no-date", sponsors: ["W000805"], updatedAt: nil),
            manifestItem("bad-date", sponsors: ["W000805"], updatedAt: "yesterday"),
            manifestItem("listed-twice", sponsors: ["K000384", "K000384"], updatedAt: "2026-10-08")
        ]

        let week = CongressTabModel.recentSponsoredBillCounts(
            memberIDs: ["K000384", "W000805", "W000831"],
            manifestItems: items,
            window: .oneWeek,
            now: now
        )
        XCTAssertEqual(week, ["K000384": 3, "W000805": 1, "W000831": 0])

        let fourWeeks = CongressTabModel.recentSponsoredBillCounts(
            memberIDs: ["K000384"],
            manifestItems: items,
            window: .fourWeeks,
            now: now
        )
        XCTAssertEqual(fourWeeks["K000384"], 4, "the older bill is inside four weeks")

        XCTAssertEqual(CongressTabModel.recentSponsoredBillCounts(memberIDs: [], manifestItems: items, window: .oneWeek, now: now), [:])
    }

    func testBillCountTextNamesTheWindow() {
        XCTAssertEqual(CongressTabModel.billCountText(nil, window: .oneWeek), "Updating…")
        XCTAssertEqual(CongressTabModel.billCountText(0, window: .oneWeek), "0 bills this week")
        XCTAssertEqual(CongressTabModel.billCountText(1, window: .oneWeek), "1 bill this week")
        XCTAssertEqual(CongressTabModel.billCountText(3, window: .twoWeeks), "3 bills in the last 2 weeks")
        XCTAssertEqual(CongressTabModel.billCountText(2, window: BillboardHistoryWindow(rawValue: 10)), "2 bills in the last 10 days")
    }

    // MARK: - Members you follow

    func testFollowedMembersJoinTheProfileWithTheManifestInRosterOrder() throws {
        let manifest = try fixture()
        let unknown = UUID()
        let followed = [
            UUID.deterministic(from: "W000805"),
            UUID.deterministic(from: "K000384"),
            UUID.deterministic(from: "K000384"),
            unknown
        ]

        let members = CongressTabModel.followedMembers(followedIDs: followed, in: manifest)

        XCTAssertEqual(ids(members), ["K000384", "W000805"], "roster order, each once")
        XCTAssertEqual(CongressTabModel.unmatchedFollowCount(followedIDs: followed, in: manifest), 1)
        XCTAssertEqual(CongressTabModel.followedMembers(followedIDs: [], in: manifest), [])
        XCTAssertTrue(CongressTabModel.isFollowed(manifest.first { $0.id == "K000384" }!, followedIDs: followed))
        XCTAssertFalse(CongressTabModel.isFollowed(manifest.first { $0.id == "S000033" }!, followedIDs: followed))
    }

    // MARK: - Find a member

    private func search(_ query: String, filter: CongressMemberFilter = .all, userState: String = "") throws -> [String] {
        ids(CongressTabModel.searchResults(in: try fixture(), query: query, filter: filter, userState: userState))
    }

    func testSearchMatchesAnyPartOfTheNameIgnoringCaseAndAccents() throws {
        XCTAssertEqual(try search("kaine"), ["K000384"])
        XCTAssertEqual(try search("  KAINE "), ["K000384"])
        XCTAssertEqual(try search("velazquez"), ["V000081"])
        XCTAssertEqual(try search("Velázquez"), ["V000081"])
        XCTAssertEqual(try search("holmes norton"), ["N000147"])
        XCTAssertEqual(try search("nobody"), [])
    }

    func testStateCodeMatchesListThatStateFirst() throws {
        let results = try search("va")

        // Virginia's five members (roster order), then the names that contain "va".
        XCTAssertEqual(Array(results.prefix(5)), ["B001292", "K000384", "W000831", "W000805", "W000804"])
        XCTAssertEqual(Array(results.dropFirst(5)), ["V000128", "V000130"])
    }

    func testStateNamesMatchFromTheStartOfAWord() throws {
        XCTAssertEqual(Set(try search("virginia")), ["B001292", "K000384", "W000831", "W000805", "W000804", "C001047", "J000312"])
        XCTAssertEqual(try search("west virginia"), ["C001047", "J000312"])
        XCTAssertEqual(try search("alas"), ["B001323"])
        XCTAssertEqual(try search("district of columbia"), ["N000147"])
    }

    func testDistrictsMatchByNumberWithOrWithoutTheState() throws {
        XCTAssertEqual(try search("VA-11"), ["W000831"])
        XCTAssertEqual(try search("va11"), ["W000831"])
        XCTAssertEqual(try search("va 11"), ["W000831"])
        XCTAssertEqual(try search("11th"), ["W000831"])
        XCTAssertEqual(try search("NY-07"), ["V000081"])
        XCTAssertEqual(try search("7"), ["V000081"])
        XCTAssertEqual(try search("ny-11"), [], "VA-11 is not in New York")
    }

    func testFiltersLimitTheChamberOrTheUsersState() throws {
        XCTAssertEqual(try search("", filter: .senate), ["C001047", "J000312", "K000384", "S000033", "V000128", "W000805"])
        XCTAssertEqual(try search("va", filter: .house), ["B001292", "W000831", "W000804", "V000130"])

        // My state: senators, then House members by district number.
        XCTAssertEqual(try search("", filter: .myState, userState: "va"), ["K000384", "W000805", "W000804", "B001292", "W000831"])
        XCTAssertEqual(try search("warner", filter: .myState, userState: "VA"), ["W000805"])
        XCTAssertEqual(try search("", filter: .myState, userState: ""), [], "no state, no list")
    }

    func testInlineResultsAreHiddenUntilTheUserSearchesOrFilters() throws {
        let manifest = try fixture()

        XCTAssertNil(CongressTabModel.inlineResults(in: manifest, query: "", filter: .all, userState: "VA"))
        XCTAssertNil(CongressTabModel.inlineResults(in: manifest, query: "   ", filter: .all, userState: "VA"))
        XCTAssertFalse(CongressTabModel.shouldShowInlineResults(query: " , ", filter: .all))
        XCTAssertTrue(CongressTabModel.shouldShowInlineResults(query: "", filter: .house))

        let house = try XCTUnwrap(CongressTabModel.inlineResults(in: manifest, query: "", filter: .house, userState: ""))
        XCTAssertEqual(house.totalCount, 7)
        XCTAssertFalse(house.isTruncated)
    }

    func testInlineResultsStopAtTheLimitAndReportTheTotal() throws {
        let manifest = try fixture()

        let results = try XCTUnwrap(CongressTabModel.inlineResults(in: manifest, query: "va", filter: .all, userState: "", limit: 2))

        XCTAssertEqual(ids(results.members), ["B001292", "K000384"])
        XCTAssertEqual(results.totalCount, 7)
        XCTAssertTrue(results.isTruncated)
        XCTAssertEqual(CongressTabModel.inlineResultLimit, 20, "spec D 2.5.8: first 20 matches inline")
    }

    func testFilterTitles() {
        XCTAssertEqual(CongressMemberFilter.allCases.map(\.title), ["All", "House", "Senate", "My state"])
    }

    func testStateNamesCoverTheStatesDCAndTerritories() {
        XCTAssertEqual(CongressTabModel.stateName(for: "va"), "Virginia")
        XCTAssertEqual(CongressTabModel.stateName(for: "DC"), "District of Columbia")
        XCTAssertEqual(CongressTabModel.stateName(for: "PR"), "Puerto Rico")
        XCTAssertNil(CongressTabModel.stateName(for: "ZZ"))
    }

    // MARK: - Voting seats (project decision 2026-10-31)

    /// The House members for the five territories, as the live manifest gives them (postal codes) with the
    /// district forms other payloads use. DC's delegate is the fixture's Norton.
    private func territoryDelegates() throws -> [CongressMemberManifestItem] {
        [
            try member("X000001", "Pablo José Hernández", chamber: house, state: "PR", district: .text("98"), party: "D"),
            try member("X000002", "Stacey E. Plaskett", chamber: house, state: "VI", district: .text("At-Large"), party: "D"),
            try member("X000003", "James C. Moylan", chamber: house, state: "GU", district: .number(0), party: "R"),
            try member("X000004", "Aumua Amata Coleman Radewagen", chamber: house, state: "AS", party: "R"),
            try member("X000005", "Kimberlyn King-Hinds", chamber: house, state: "MP", party: "R")
        ]
    }

    private func delegates() throws -> [CongressMemberManifestItem] {
        let norton = try XCTUnwrap(try fixture().first { $0.id == "N000147" })
        return [norton] + (try territoryDelegates())
    }

    /// The live manifest's shape on 2026-10-31: 433 voting House members (the 2020 seat table, two seats
    /// vacant), DC's and the territories' 6 delegates, and 100 senators.
    private func liveSizedManifest() throws -> [CongressMemberManifestItem] {
        var items: [CongressMemberManifestItem] = []
        for place in DistrictPickerModel.states where !place.hasDelegateOnly {
            for seat in 1...place.houseSeats {
                let district: District = place.isAtLarge ? .none : .number(seat)
                let party = seat.isMultiple(of: 2) ? "D" : "R"
                items.append(try member("H-\(place.code)-\(seat)", "House \(place.code) \(seat)", chamber: house, state: place.code, district: district, party: party))
            }
            items.append(try member("S-\(place.code)-1", "Senate \(place.code) 1", chamber: senate, state: place.code, party: "D"))
            items.append(try member("S-\(place.code)-2", "Senate \(place.code) 2", chamber: senate, state: place.code, party: "R"))
        }
        items.removeAll { $0.id == "H-CA-52" || $0.id == "H-TX-18" }
        return items + (try delegates())
    }

    func testDelegatesAreTheHouseMembersForDCAndTheTerritories() throws {
        for delegate in try delegates() {
            XCTAssertTrue(CongressTabModel.isNonVotingDelegate(delegate), delegate.state ?? "no state")
        }
        // The state as a name, or a code in lower case, as other payloads give it.
        XCTAssertTrue(CongressTabModel.isNonVotingDelegate(try member("X000006", "A", chamber: house, state: "Puerto Rico", party: "D")))
        XCTAssertTrue(CongressTabModel.isNonVotingDelegate(try member("X000007", "B", chamber: "House", state: "dc", district: .text("98"), party: "D")))

        let byID = Dictionary(uniqueKeysWithValues: try fixture().map { ($0.id, $0) })
        // Alaska's at-large member has no district in the manifest either, and votes.
        XCTAssertFalse(CongressTabModel.isNonVotingDelegate(try XCTUnwrap(byID["B001323"])), "AK at-large")
        XCTAssertFalse(CongressTabModel.isNonVotingDelegate(try XCTUnwrap(byID["W000831"])), "VA-11")
        XCTAssertFalse(CongressTabModel.isNonVotingDelegate(try XCTUnwrap(byID["K000384"])), "a senator")
        // Only a House seat can be a delegate's, and a row needs a known place.
        XCTAssertFalse(CongressTabModel.isNonVotingDelegate(try member("X000008", "C", chamber: senate, state: "DC", party: "D")))
        XCTAssertFalse(CongressTabModel.isNonVotingDelegate(try member("X000009", "D", chamber: house, state: "", party: "D")))
    }

    func testVotingMembersLeaveOutOnlyTheDelegatesAndKeepTheOrder() throws {
        let manifest = try fixture()

        XCTAssertEqual(ids(CongressTabModel.votingMembers(manifest)), ids(manifest).filter { $0 != "N000147" })
        XCTAssertEqual(CongressTabModel.votingMembers(try delegates()), [])
    }

    /// RC 3's deck read "House 439": the 6 delegates were counted with the 433 voting members.
    func testTheDeckCountsTheVotingSeats() throws {
        let fixtureSeats = CongressTabModel.chamberCounts(in: try fixture())
        XCTAssertEqual(fixtureSeats.house, 6, "7 House rows, Norton left out")
        XCTAssertEqual(fixtureSeats.senate, 6)

        let live = try liveSizedManifest()
        XCTAssertEqual(live.filter { $0.chamberNormalized == CongressChamber.house.rawValue }.count, 439, "the House roll")
        let seats = CongressTabModel.chamberCounts(in: live)
        XCTAssertEqual(seats.house, 433)
        XCTAssertEqual(seats.senate, 100)

        let session = CongressCalendar.Session(congress: 119, session: 2)
        XCTAssertEqual(
            CongressDeck.text(session: session, houseCount: seats.house, senateCount: seats.senate),
            "119th Congress · House 433 · Senate 100"
        )
        XCTAssertEqual(
            CongressDeck.spokenText(session: session, houseCount: seats.house, senateCount: seats.senate),
            "119th Congress. House, 433 members. Senate, 100 members."
        )
    }

    /// The counts leave the delegates out; the lists, the searches, Your representatives and Where you
    /// vote keep them.
    func testDelegatesStayInEveryListSearchAndLookup() throws {
        let manifest = CongressMemberManifestItem.rosterSorted(try fixture() + territoryDelegates())
        let delegateIDs = Set(ids(try delegates()))

        let houseList = CongressTabModel.members(in: manifest, filter: .house, userState: "")
        XCTAssertTrue(delegateIDs.isSubset(of: Set(ids(houseList))))
        XCTAssertEqual(houseList.count, 12)
        XCTAssertEqual(try XCTUnwrap(CongressTabModel.inlineResults(in: manifest, query: "", filter: .house, userState: "")).totalCount, 12)
        XCTAssertEqual(CongressTabModel.members(in: manifest, filter: .all, userState: "").count, manifest.count)

        XCTAssertEqual(ids(CongressTabModel.searchResults(in: manifest, query: "pr", filter: .all, userState: "")), ["X000001"])
        XCTAssertEqual(ids(CongressTabModel.searchResults(in: manifest, query: "puerto rico", filter: .all, userState: "")), ["X000001"])
        XCTAssertEqual(ids(CongressTabModel.searchResults(in: manifest, query: "guam", filter: .house, userState: "")), ["X000003"])
        XCTAssertEqual(ids(CongressTabModel.members(in: manifest, filter: .myState, userState: "GU")), ["X000003"])

        XCTAssertEqual(ids(CongressTabModel.representatives(state: "PR", district: "98", in: manifest)), ["X000001"])
        XCTAssertEqual(ids(CongressTabModel.representatives(state: "DC", district: "98", in: manifest)), ["N000147"])
        XCTAssertEqual(ids(DistrictPickerModel.representatives(in: manifest, state: "PR", district: "At-Large")), ["X000001"])
        XCTAssertEqual(ids(DistrictPickerModel.representatives(in: manifest, state: "AS", district: "At-Large")), ["X000004"])
    }

    // MARK: - Party and chamber metrics

    /// The House page's docket names the delegates its roll lists beside the voting members, with a no-break
    /// space before the dot; the Senate's has no delegates.
    func testTheChamberDocketCountsTheVotingMembersThenTheDelegates() throws {
        let live = try liveSizedManifest()
        let houseRoll = live.filter { $0.chamberNormalized == CongressChamber.house.rawValue }
        let senateRoll = live.filter { $0.chamberNormalized == CongressChamber.senate.rawValue }

        XCTAssertEqual(CongressChamberInfoView.docket(for: houseRoll), "433 members\u{00A0}· 6 delegates")
        XCTAssertEqual(CongressChamberInfoView.docket(for: senateRoll), "100 members")
        XCTAssertFalse(CongressChamberInfoView.docket(for: houseRoll).contains(" ·"), "no breakable space before the dot")

        let byID = Dictionary(uniqueKeysWithValues: try fixture().map { ($0.id, $0) })
        let one = [try XCTUnwrap(byID["W000831"]), try XCTUnwrap(byID["N000147"])]
        XCTAssertEqual(CongressChamberInfoView.docket(for: one), "1 member\u{00A0}· 1 delegate")
        XCTAssertEqual(CongressChamberInfoView.docket(for: Array(houseRoll.prefix(2))), "2 members")
        XCTAssertEqual(CongressChamberInfoView.docket(for: []), "0 members")
    }

    func testChamberCompositionSharesTheVotingSeats() throws {
        let houseRoll = try fixture().filter { $0.chamberNormalized == CongressChamber.house.rawValue }
        // D: Walkinshaw, Beyer, Velázquez, Vargas (Norton is DC's delegate); R: Wittman, Begich.
        let rows = CongressChamberInfoView.compositionRows(for: houseRoll)

        XCTAssertEqual(rows.map(\.label), ["Democratic (D)", "Republican (R)", "Independent (I)"])
        XCTAssertEqual(rows.map(\.value), ["4 · 67%", "2 · 33%", "0 · 0%"])

        let senateRoll = try fixture().filter { $0.chamberNormalized == CongressChamber.senate.rawValue }
        XCTAssertEqual(CongressChamberInfoView.compositionRows(for: senateRoll).map(\.value), ["3 · 50%", "2 · 33%", "1 · 17%"])
        XCTAssertEqual(CongressChamberInfoView.compositionRows(for: try delegates()).map(\.value), ["0 · 0%", "0 · 0%", "0 · 0%"])
    }

    func testPartyCompositionCountsTheVotingSeats() throws {
        let democrats = try fixture().filter { $0.party == "D" }
        // 5 House rows, Norton among them, and 3 senators.
        XCTAssertEqual(democrats.count, 8)

        let rows = PoliticalPartyDetailView.compositionRows(for: democrats)

        XCTAssertEqual(rows.map(\.label), ["Total members", "House of Representatives", "Senate"])
        XCTAssertEqual(rows.map(\.value), ["7", "4 · 57%", "3 · 43%"])
        let republicans = try (fixture() + territoryDelegates()).filter { $0.party == "R" }
        XCTAssertEqual(PoliticalPartyDetailView.compositionRows(for: republicans).map(\.value), ["4", "2 · 50%", "2 · 50%"])
    }

    func testPartiesRowsCountTheVotingSeats() throws {
        let manifest = try fixture() + territoryDelegates()

        let democratic = PoliticalPartiesView.counts(for: .democratic, in: manifest)
        XCTAssertEqual([democratic.total, democratic.house, democratic.senate], [7, 4, 3])
        let republican = PoliticalPartiesView.counts(for: .republican, in: manifest)
        XCTAssertEqual([republican.total, republican.house, republican.senate], [4, 2, 2])
        let independent = PoliticalPartiesView.counts(for: .independent, in: manifest)
        XCTAssertEqual([independent.total, independent.house, independent.senate], [1, 0, 1])
        XCTAssertEqual(
            PoliticalPartyRow.summary(totalCount: democratic.total, houseCount: democratic.house, senateCount: democratic.senate),
            "7 members · 4 House · 3 Senate"
        )
    }

    private func bill(_ guid: String, group: String, topic: String?) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: guid,
            category: group,
            subCategory: topic,
            soWhat: "",
            billStatus: .new,
            guid: guid,
            userVoted: false
        )
    }

    func testBillsByTopicCountTopicsNotLifeAreasAndUseTheNewNames() {
        let bills = [
            bill("a", group: SubscriptionsConfig.categorySocialPolicy, topic: SubscriptionsConfig.legacyTopicSocialJustice),
            bill("b", group: SubscriptionsConfig.categorySocialPolicy, topic: SubscriptionsConfig.subCivilRightsAndLiberties),
            bill("c", group: SubscriptionsConfig.categoryEconomicPolicy, topic: "Taxation"),
            bill("d", group: SubscriptionsConfig.categoryEconomicPolicy, topic: nil)
        ]

        let topics = CongressMetrics.topicRateRows(for: bills)

        XCTAssertEqual(topics.map(\.label), [SubscriptionsConfig.subCivilRightsAndLiberties, "Taxation"])
        XCTAssertEqual(topics.map(\.value), ["50%", "25%"])
        XCTAssertFalse(topics.contains { $0.label == SubscriptionsConfig.legacyTopicSocialJustice })
    }

    func testBillsByTopicGroupBreakTiesByName() {
        let bills = [
            bill("a", group: "Social Policy", topic: nil),
            bill("b", group: "Economic Policy", topic: nil),
            bill("c", group: "Economic Policy", topic: nil),
            bill("d", group: "Social Policy", topic: nil),
            bill("e", group: "Foreign Policy and Defense", topic: nil)
        ]

        let groups = CongressMetrics.categoryRateRows(for: bills, top: 2)

        XCTAssertEqual(groups.map(\.label), ["Economic Policy", "Social Policy"])
        XCTAssertEqual(groups.map(\.value), ["40%", "40%"])
        XCTAssertTrue(CongressMetrics.categoryRateRows(for: []).isEmpty)
        XCTAssertTrue(CongressMetrics.topicRateRows(for: []).isEmpty)
    }

    // MARK: - Tab switches

    /// The tab shell builds only the selected tab, so the Congress tab's pushes are values its path
    /// keeps (a member opened from search comes back after a switch to Bills and back), and "See all
    /// members" carries the search as it was.
    func testTheTabsPushesAreValuesItsPathKeeps() throws {
        let kaine = try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D")
        var path = NavigationPath()
        path.append(CongressRoute.member(kaine))
        path.append(CongressRoute.parties)
        path.append(CongressRoute.chamber(.senate))
        XCTAssertEqual(path.count, 3)
        XCTAssertEqual(CongressRoute.member(kaine), .member(kaine))
        XCTAssertNotEqual(CongressRoute.chamber(.house), .chamber(.senate))

        XCTAssertEqual(
            CongressRoute.seeAllMembers(filter: .myState, userState: " va ", searchText: " kaine "),
            .allMembers(filter: .myState, state: "VA", searchText: "kaine")
        )
        XCTAssertEqual(
            CongressRoute.seeAllMembers(filter: .senate, userState: "VA", searchText: ""),
            .allMembers(filter: .senate, state: nil, searchText: "")
        )

        // The search and filter live outside the tab's view.
        var search = CongressSearchState()
        XCTAssertEqual(search, CongressSearchState(text: "", filter: .all))
        search.text = "Kaine"
        search.filter = .senate
        XCTAssertEqual(search, CongressSearchState(text: "Kaine", filter: .senate))
    }
}
