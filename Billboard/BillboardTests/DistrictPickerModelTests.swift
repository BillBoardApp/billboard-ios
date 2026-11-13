import XCTest
@testable import Billboard

/// "Where do you vote?" data (spec D 2.5.3): the 50 states, DC and the five territories with a delegate
/// (UX-39), each state's districts (from the members manifest, kept complete by the 2020 seat table), the
/// members who represent a district, and the form's button rules. No network.
@MainActor
final class DistrictPickerModelTests: XCTestCase {
    // MARK: - States

    /// The project pulled the territories into 1.2 on 2026-10-28 (UX-39): this test pinned "50 states and DC, no
    /// territories" until then.
    func testStatesAreTheFiftyStatesDCAndTheTerritoriesByName() {
        let states = DistrictPickerModel.states
        XCTAssertEqual(states.count, 56)
        XCTAssertEqual(Set(states.map(\.code)).count, 56, "codes are unique")
        XCTAssertTrue(states.contains { $0.code == "DC" && $0.name == "District of Columbia" })
        XCTAssertEqual(states.map(\.name), states.map(\.name).sorted(), "the picker lists states by name")
        XCTAssertEqual(states.first?.code, "AL")
        XCTAssertEqual(states.last?.code, "WY")
        let territories = ["PR": "Puerto Rico", "GU": "Guam", "VI": "U.S. Virgin Islands", "AS": "American Samoa", "MP": "Northern Mariana Islands"]
        for (code, name) in territories {
            XCTAssertEqual(DistrictPickerModel.state(forCode: code)?.name, name, code)
            XCTAssertEqual(USStateNames.name(forPostalCode: code), name, "\(code): the same name VoiceOver reads for the delegate's seat")
        }
    }

    func testSeatTableIsThe2020ApportionmentPlusTheDelegates() {
        let voting = DistrictPickerModel.states.filter { !$0.hasDelegateOnly }
        XCTAssertEqual(voting.count, 50)
        XCTAssertEqual(voting.reduce(0) { $0 + $1.houseSeats }, 435)
        XCTAssertEqual(DistrictPickerModel.state(forCode: "CA")?.houseSeats, 52)
        XCTAssertEqual(DistrictPickerModel.state(forCode: "TX")?.houseSeats, 38)
        XCTAssertEqual(DistrictPickerModel.state(forCode: "VA")?.houseSeats, 11)
        XCTAssertEqual(DistrictPickerModel.state(forCode: "MT")?.houseSeats, 2)
        let delegates = Set(DistrictPickerModel.states.filter(\.hasDelegateOnly).map(\.code))
        XCTAssertEqual(delegates, ["DC", "PR", "GU", "VI", "AS", "MP"])
        let atLarge = Set(DistrictPickerModel.states.filter(\.isAtLarge).map(\.code))
        XCTAssertEqual(atLarge, ["AK", "DE", "DC", "ND", "SD", "VT", "WY", "PR", "GU", "VI", "AS", "MP"])
    }

    func testStateCodeAcceptsCodesAndNamesInAnyCase() {
        XCTAssertEqual(DistrictPickerModel.stateCode(from: "va"), "VA")
        XCTAssertEqual(DistrictPickerModel.stateCode(from: " Virginia "), "VA")
        XCTAssertEqual(DistrictPickerModel.stateCode(from: "District of Columbia"), "DC")
        XCTAssertEqual(DistrictPickerModel.stateCode(from: "Washington DC"), "DC")
        XCTAssertEqual(DistrictPickerModel.stateCode(from: "PR"), "PR")
        XCTAssertEqual(DistrictPickerModel.stateCode(from: "puerto rico"), "PR")
        XCTAssertEqual(DistrictPickerModel.stateCode(from: "Virgin Islands"), "VI")
        XCTAssertEqual(DistrictPickerModel.stateCode(from: "U.S. Virgin Islands"), "VI")
        XCTAssertNil(DistrictPickerModel.stateCode(from: ""))
        XCTAssertNil(DistrictPickerModel.stateCode(from: "Narnia"))
    }

    // MARK: - Districts

    func testDistrictNormalization() {
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("11", state: "VA"), "11")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("VA-11", state: "VA"), "11")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("011", state: "VA"), "11")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("10", state: "VA"), "10")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("At-Large", state: "AK"), "At-Large")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("AL", state: "AK"), "At-Large")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("0", state: "WY"), "At-Large")
        // The Census code of a delegate's district ("98"): the at-large seat, in DC and the territories only.
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("PR-98", state: "PR"), "At-Large")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("98", state: "DC"), "At-Large")
        XCTAssertEqual(DistrictPickerModel.normalizedDistrict("98", state: "CA"), "98")
        XCTAssertNil(DistrictPickerModel.normalizedDistrict("", state: "VA"))
        XCTAssertNil(DistrictPickerModel.normalizedDistrict("north", state: "VA"))
    }

    func testOneSeatStatesDCAndTheTerritoriesOfferOnlyAtLarge() {
        for code in ["AK", "DE", "DC", "ND", "SD", "VT", "WY", "PR", "GU", "VI", "AS", "MP"] {
            let choices = DistrictPickerModel.districtChoices(for: code, manifest: [])
            XCTAssertEqual(choices, [DistrictChoice(value: "At-Large", label: "At-large")], code)
        }
        // A manifest that numbers the single seat does not add a second choice.
        let wyoming = [member("H1", chamber: "House of Representatives", state: "WY", district: "1")]
        XCTAssertEqual(DistrictPickerModel.districtChoices(for: "WY", manifest: wyoming).map(\.value), ["At-Large"])
    }

    func testMultiSeatStatesListEveryDistrictInNumericOrder() {
        let choices = DistrictPickerModel.districtChoices(for: "VA", manifest: [])
        XCTAssertEqual(choices.map(\.value), (1...11).map(String.init))
        XCTAssertEqual(choices.first?.label, "District 1")
        XCTAssertEqual(choices.last?.label, "District 11")
        XCTAssertEqual(choices[9].value, "10", "numeric, not string, order (10 after 9)")
    }

    func testManifestDistrictsAreMergedAndAVacantSeatStays() {
        // Districts 3 and 11 only in the manifest; district 5 vacant (no member) still listed.
        let manifest = [
            member("H11", chamber: "House", state: "VA", district: "11"),
            member("H3", chamber: "House", state: "va", district: "VA-03"),
            member("S1", chamber: "Senate", state: "VA", district: nil)
        ]
        let values = DistrictPickerModel.districtChoices(for: "VA", manifest: manifest).map(\.value)
        XCTAssertEqual(values, (1...11).map(String.init))
        XCTAssertTrue(values.contains("5"))
    }

    func testUnknownStateUsesTheManifestOnly() {
        XCTAssertEqual(DistrictPickerModel.districtChoices(for: "", manifest: []), [])
        let manifest = [
            member("PR1", chamber: "House", state: "ZZ", district: "2"),
            member("PR2", chamber: "House", state: "ZZ", district: "1")
        ]
        XCTAssertEqual(DistrictPickerModel.districtChoices(for: "ZZ", manifest: manifest).map(\.value), ["1", "2"])
    }

    // MARK: - Representatives

    func testRepresentativesAreTheSenatorsByNameThenTheHouseMember() {
        let manifest = [
            member("H11", name: "Jane Doe", chamber: "House", state: "VA", district: "11", party: "Democratic"),
            member("H10", name: "John Roe", chamber: "House", state: "VA", district: "10", party: "Republican"),
            member("S2", name: "Tim Kaine", chamber: "Senate", state: "VA", district: nil, party: "Democratic"),
            member("S1", name: "Mark Warner", chamber: "Senate", state: "VA", district: nil, party: "Democratic"),
            member("S3", name: "Other Senator", chamber: "Senate", state: "MD", district: nil, party: "Democratic")
        ]
        let reps = DistrictPickerModel.representatives(in: manifest, state: "va", district: "VA-11")
        XCTAssertEqual(reps.map(\.id), ["S2", "S1", "H11"], "senators by last name (Kaine, Warner), then the district's member")
    }

    func testAtLargeStateFallsBackToItsOnlyHouseMember() {
        let manifest = [
            member("WY0", chamber: "House", state: "WY", district: "1"),
            member("WYS", chamber: "Senate", state: "WY", district: nil)
        ]
        XCTAssertEqual(DistrictPickerModel.representatives(in: manifest, state: "WY", district: "At-Large").map(\.id), ["WYS", "WY0"])
    }

    func testDCHasItsDelegateOnly() {
        let manifest = [member("DC0", name: "Eleanor Holmes Norton", chamber: "House", state: "DC", district: "0", party: "Democratic")]
        let reps = DistrictPickerModel.representatives(in: manifest, state: "DC", district: "At-Large")
        XCTAssertEqual(reps.map(\.id), ["DC0"])
    }

    /// Each territory's one representative is its delegate (Puerto Rico's Resident Commissioner), however the
    /// manifest writes the seat (none, "0", "00", "98"), for a chosen district and a found address ("PR-98").
    func testATerritoryHasItsDelegateOnly() {
        let manifest = [
            member("PR0", chamber: "House of Representatives", state: "PR", district: nil, party: "Democratic"),
            member("GU0", chamber: "House of Representatives", state: "GU", district: "0", party: "Republican"),
            member("VI0", chamber: "House of Representatives", state: "VI", district: "00", party: "Democratic"),
            member("AS0", chamber: "House of Representatives", state: "AS", district: "98", party: "Republican"),
            member("MP0", chamber: "House of Representatives", state: "MP", district: nil, party: "Republican"),
            member("S1", chamber: "Senate", state: "VA", district: nil)
        ]
        for code in ["PR", "GU", "VI", "AS", "MP"] {
            XCTAssertEqual(DistrictPickerModel.representatives(in: manifest, state: code, district: "At-Large").map(\.id), ["\(code)0"], code)
            XCTAssertEqual(DistrictPickerModel.representatives(in: manifest, state: code, district: "\(code)-98").map(\.id), ["\(code)0"], "\(code) found by address")
        }
    }

    func testNoHouseMatchLeavesTheSenatorsOnly() {
        let manifest = [
            member("S1", chamber: "Senate", state: "VA", district: nil),
            member("H10", chamber: "House", state: "VA", district: "10")
        ]
        XCTAssertEqual(DistrictPickerModel.representatives(in: manifest, state: "VA", district: "5").map(\.id), ["S1"])
        XCTAssertEqual(DistrictPickerModel.representatives(in: manifest, state: "", district: "5"), [])
    }

    // MARK: - Labels

    func testSuccessHeadlines() {
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "VA", district: "11"), "You're in VA-11.")
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "VA", district: "2"), "You're in VA-2.")
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "AK", district: "At-Large"), "You're in Alaska's at-large district.")
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "DC", district: "At-Large"), "You're in the District of Columbia.")
        XCTAssertEqual(DistrictPickerModel.locationLabel(state: "wy", district: "AL"), "WY at-large")
    }

    /// A territory reads as DC does: its name, with "the" where English puts it.
    func testTerritoryHeadlinesAndLabels() {
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "PR", district: "At-Large"), "You're in Puerto Rico.")
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "GU", district: "At-Large"), "You're in Guam.")
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "VI", district: "At-Large"), "You're in the U.S. Virgin Islands.")
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "AS", district: "At-Large"), "You're in American Samoa.")
        XCTAssertEqual(DistrictPickerModel.successHeadline(state: "MP", district: "98"), "You're in the Northern Mariana Islands.")
        XCTAssertEqual(DistrictPickerModel.locationLabel(state: "PR", district: "98"), "PR at-large", "the Census code reads as the at-large seat")
        XCTAssertEqual(DistrictPickerModel.locationLabel(state: "DC", district: "98"), "DC at-large")
        XCTAssertEqual(SpokenForm.district(DistrictPickerModel.locationLabel(state: "VI", district: "At-Large")), "U.S. Virgin Islands' at-large district")
        XCTAssertEqual(LocationSavedPanel.spokenHeadline(state: "PR", district: "At-Large"), "You're in Puerto Rico.")
    }

    /// Choosing a territory's district works like DC's: the state picks its only choice, and Continue is enabled.
    func testATerritoryCanBeChosen() {
        var form = LocationForm()
        form.state = "PR"
        let choices = DistrictPickerModel.districtChoices(for: "PR", manifest: [])
        form.reconcileDistrict(with: choices)
        XCTAssertEqual(form.district, "At-Large")
        XCTAssertTrue(form.canChooseDistrict(choices: choices))
        XCTAssertNil(form.chooseDistrictHint(choices: choices))
        XCTAssertEqual(try? DistrictVerificationService.normalizeDistrictForAPI(form.district, state: "PR"), "AL", "the server's manual selection takes AL")
    }

    // MARK: - Form

    /// Legal-facing copy, shown under the address fields in setup and in Profile > Where you vote.
    func testAddressPrivacyNoteIsTheApprovedWording() {
        XCTAssertEqual(
            LocationEditorView.privacyNote,
            "We send your address to the U.S. Census Bureau to find your district. We don't keep your street address on our servers; your iPhone remembers it so you can change it later. We keep only a scrambled code of it so one address can't verify unlimited accounts."
        )
    }

    func testFindMyDistrictNeedsStreetCityStateAndAValidZip() {
        var form = LocationForm(line1: "1 Main St", city: "Arlington", state: "VA", zip: "22201")
        XCTAssertTrue(form.canFindDistrict)

        form.zip = "22201-1234"
        XCTAssertTrue(form.canFindDistrict, "ZIP+4")
        form.zip = "2220"
        XCTAssertFalse(form.canFindDistrict)
        form.zip = "22201"

        form.state = ""
        XCTAssertFalse(form.canFindDistrict)
        form.state = "ZZ"
        XCTAssertFalse(form.canFindDistrict, "not a state, DC or a territory")
        // A territory's address goes to the geocoder too (UX-39; until 2026-10-28 PR was refused here).
        form.state = "PR"
        XCTAssertTrue(form.canFindDistrict)
        form.state = "VA"

        form.line1 = "   "
        XCTAssertFalse(form.canFindDistrict)
        form.line1 = "1 Main St"
        form.city = ""
        XCTAssertFalse(form.canFindDistrict)
        form.city = "Arlington"
        form.line2 = ""
        XCTAssertTrue(form.canFindDistrict, "the unit is optional")
    }

    func testChooseYourDistrictNeedsOneOfTheStatesDistricts() {
        var form = LocationForm(state: "VA")
        let choices = DistrictPickerModel.districtChoices(for: "VA", manifest: [])
        XCTAssertFalse(form.canChooseDistrict(choices: choices))
        form.district = "11"
        XCTAssertTrue(form.canChooseDistrict(choices: choices))
        form.district = "12"
        XCTAssertFalse(form.canChooseDistrict(choices: choices), "Virginia has 11 districts")
    }

    func testChangingStateKeepsOrClearsTheDistrict() {
        var form = LocationForm(state: "MD", district: "7")
        form.reconcileDistrict(with: DistrictPickerModel.districtChoices(for: "MD", manifest: []))
        XCTAssertEqual(form.district, "7", "still one of the state's districts")

        form.state = "MT"
        form.reconcileDistrict(with: DistrictPickerModel.districtChoices(for: "MT", manifest: []))
        XCTAssertEqual(form.district, "", "Montana has two districts")

        form.state = "AK"
        form.reconcileDistrict(with: DistrictPickerModel.districtChoices(for: "AK", manifest: []))
        XCTAssertEqual(form.district, "At-Large", "a one-district state selects its only choice")
    }

    // MARK: - Helpers

    private func member(
        _ id: String,
        name: String = "A Member",
        chamber: String,
        state: String,
        district: String?,
        party: String? = "Democratic"
    ) -> CongressMemberManifestItem {
        CongressMemberManifestItem(dto: UserAPIContractsV1.CongressMemberManifestItem(
            bioguideId: id,
            name: name,
            chamber: chamber,
            state: state,
            party: party ?? "",
            district: district,
            depictionImageUrl: nil,
            updatedAt: nil,
            currentCongressBillsSupportedCount: nil,
            trackedSponsoredCount: nil,
            trackedSupportedCount: nil
        ))
    }
}
