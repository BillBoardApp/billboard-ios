import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the Congress tab, its roll sheets in every state, the member page (with a monogram and with a
/// photo), the parties and chamber pages, the directory's sections, the topic-group and life-area bill
/// lists and the Civic Profile chart with fixture data (Civic Record spec 10.1), in light and dark, at the
/// default text size and AX3, the rows also at AX5, and attaches each image to the result bundle for review.
/// No network, no credentials, no baselines; pixels are checked where the colour is the point.
///
/// `ImageRenderer` draws SwiftUI views only: the search field and the segmented filter are UIKit-backed, so
/// the "Find a member" image shows placeholders for those two controls (the results list is rendered on its
/// own as well), and screens are rendered without their scroll views.
@MainActor
final class CongressRenderTests: XCTestCase {
    private struct Variant {
        let scheme: ColorScheme
        let size: DynamicTypeSize

        var name: String {
            let sizeName: String
            switch size {
            case .large: sizeName = "default"
            case .accessibility3: sizeName = "AX3"
            case .accessibility5: sizeName = "AX5"
            default: sizeName = "\(size)"
            }
            return "\(scheme == .dark ? "dark" : "light")-\(sizeName)"
        }
    }

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility3)
    ]

    private static let ax5 = Variant(scheme: .light, size: .accessibility5)

    /// The narrowest phone Billboard supports, for the AX5 rows.
    private static let narrowWidth: CGFloat = 375

    // MARK: - Fixture

    private func member(
        _ id: String,
        _ name: String,
        chamber: String,
        state: String,
        district: Int? = nil,
        party: String
    ) throws -> CongressMemberManifestItem {
        var fields = [
            #""bioguideId":"\#(id)""#,
            #""name":"\#(name)""#,
            #""chamber":"\#(chamber)""#,
            #""state":"\#(state)""#,
            #""party":"\#(party)""#
        ]
        if let district { fields.append(#""district":\#(district)"#) }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data(json.utf8))
    }

    private func virginia() throws -> [CongressMemberManifestItem] {
        [
            try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D"),
            try member("W000805", "Mark R. Warner", chamber: "Senate", state: "VA", party: "D"),
            try member("W000831", "James R. Walkinshaw", chamber: "House of Representatives", state: "VA", district: 11, party: "D")
        ]
    }

    private func mixed() throws -> [CongressMemberManifestItem] {
        [
            try member("W000804", "Robert J. Wittman", chamber: "House of Representatives", state: "VA", district: 1, party: "R"),
            try member("S000033", "Bernard Sanders", chamber: "Senate", state: "VT", party: "I"),
            try member("V000081", "Nydia M. Velázquez", chamber: "House of Representatives", state: "NY", district: 7, party: "D")
        ]
    }

    /// Long names from the 119th Congress, the ones most likely to break inside a word at AX5.
    private func longNames() throws -> [CongressMemberManifestItem] {
        [
            try member("K000391", "Raja Krishnamoorthi", chamber: "House of Representatives", state: "IL", district: 8, party: "D"),
            try member("W000797", "Debbie Wasserman Schultz", chamber: "House of Representatives", state: "FL", district: 25, party: "D"),
            try member("M000312", "Mariannette Miller-Meeks", chamber: "House of Representatives", state: "IA", district: 1, party: "R"),
            try member("B001319", "Rosa L. DeLauro", chamber: "House of Representatives", state: "CT", district: 3, party: "D"),
            try member("W000831", "James R. Walkinshaw", chamber: "House of Representatives", state: "VA", district: 11, party: "D")
        ]
    }

    private func pageMember(party: PoliticalParty = .republican, imageUrl: URL? = nil) -> CongressMember {
        CongressMember(
            id: UUID(),
            name: "Jordan Ellis",
            state: "TX",
            stateCode: "TX",
            chamber: "House",
            imageUrl: imageUrl,
            sponsoredLegislationCount: 14,
            cosponsoredLegislationCount: 41,
            trackedSponsoredCount: 3,
            trackedSupportedCount: 12,
            biography: "Jordan Ellis has represented the 7th district of Texas since 2019. Before Congress, Ellis taught civics at a public high school.",
            party: party,
            district: "7",
            termsServed: 4,
            serviceStartYear: 2019
        )
    }

    private func readyProfile(_ values: [Double]) -> CivicProfileResponse {
        let keys = CivicProfileAxis.allCases.map(\.rawValue)
        return CivicProfileResponse(
            axes: Dictionary(uniqueKeysWithValues: zip(keys, values)),
            votesUsed: 33,
            totalVotesWithProfile: 50,
            sponsoredBillsUsed: 3,
            cosponsoredBillsUsed: 4,
            minVotesRequired: 25,
            isReady: true
        )
    }

    private func lockedProfile() -> CivicProfileResponse {
        CivicProfileResponse(
            axes: [:],
            votesUsed: 9,
            totalVotesWithProfile: 12,
            sponsoredBillsUsed: 4,
            cosponsoredBillsUsed: 7,
            totalEvidenceUsed: 20,
            totalEvidenceWithProfile: 28,
            minEvidenceRequired: 25,
            minVotesRequired: 25,
            isReady: false
        )
    }

    // MARK: - Your representatives (spec 4.55)

    func testRepresentativesRenderInEveryVariant() throws {
        let reps = try virginia()
        for variant in Self.variants + [Self.ax5] {
            let view = YourRepresentativesContent(
                state: .members(reps),
                billCounts: ["K000384": 2, "W000805": 0, "W000831": 1],
                historyWindow: .oneWeek,
                districtCode: "VA-11",
                onAddAddress: {}
            )
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let image = try render(page(view), variant: variant, width: width)
            attach(image, name: "congress-representatives-\(variant.name)")
            XCTAssertGreaterThanOrEqual(image.height, 3 * 44, variant.name)
        }
    }

    /// Every state of the section without members (spec 4.55), each a RecordNotice (the spinner while it
    /// loads), and the members while the bills are still loading (a dash for each figure).
    func testRepresentativesRenderInEveryState() throws {
        let states: [(String, CongressRepresentativesState)] = [
            ("needs-address", .needsLocation),
            ("not-found", .notFound(region: "VA-11")),
            ("loading", .loadingMembers),
            ("unavailable", .membersUnavailable),
            ("members-counting", .members(try virginia()))
        ]
        for (name, state) in states {
            for variant in Self.variants {
                let view = YourRepresentativesContent(
                    state: state,
                    billCounts: nil,
                    historyWindow: .twoWeeks,
                    districtCode: name == "needs-address" ? nil : "VA-11",
                    onAddAddress: {},
                    onRetry: {}
                )
                let image = try render(page(view), variant: variant)
                attach(image, name: "congress-representatives-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 44, "\(name) \(variant.name)")
            }
        }
    }

    /// The not-found notice prints the district as a code and VoiceOver reads it in the one spoken form (project
    /// decision of 2026-10-21), as the section's counter beside it does.
    func testTheNotFoundNoticeReadsTheDistrictInWords() {
        XCTAssertEqual(YourRepresentativesContent.notFoundText(region: "VA-11"), "We couldn't find the members for VA-11. Check your address.")
        let cases: [(region: String, place: String)] = [
            ("VA-11", "Virginia's 11th district"),
            ("AK At-Large", "Alaska's at-large district"),
            ("VA", "Virginia")
        ]
        for (region, place) in cases {
            let spoken = YourRepresentativesContent.notFoundSpokenText(region: region)
            XCTAssertEqual(spoken, "We couldn't find the members for \(place). Check your address.", region)
            let strings = AccessibilityTreeText.strings(of: NavigationStack {
                YourRepresentativesContent(
                    state: .notFound(region: region),
                    billCounts: nil,
                    historyWindow: .oneWeek,
                    districtCode: region,
                    onAddAddress: {}
                )
            })
            let text = strings.joined(separator: " | ")
            XCTAssertTrue(strings.contains("\(StatusStamp.Kind.notFound.spokenWord). \(spoken)"), "\(region): \(text)")
            XCTAssertFalse(text.contains(YourRepresentativesContent.notFoundText(region: region)), "\(region) is not read as a code: \(text)")
        }
    }

    /// The figure column's head follows the Bills tab's window, as each row's words do.
    func testTheFigureColumnHeadFollowsTheBillsWindow() {
        XCTAssertEqual(YourRepresentativesContent.figureColumnHead(.oneWeek), "Bills this week")
        XCTAssertEqual(YourRepresentativesContent.figureColumnHead(.twoWeeks), "Bills in the last 2 weeks")
        XCTAssertEqual(YourRepresentativesContent.districtCode(state: "VA", district: "11"), "VA-11")
        XCTAssertEqual(YourRepresentativesContent.districtCode(state: "VA", district: ""), "VA")
        XCTAssertEqual(YourRepresentativesContent.districtCode(state: "AK", district: "0"), "AK at-large")
        XCTAssertNil(YourRepresentativesContent.districtCode(state: "", district: "11"))
    }

    /// Each representative is one VoiceOver element with R2's label; the section's header reads the
    /// district in words; the column heads are not read (every row says it).
    func testRepresentativesReadAsOneElementPerMember() throws {
        let reps = try virginia()
        let strings = AccessibilityTreeText.strings(of: NavigationStack {
            YourRepresentativesContent(
                state: .members(reps),
                billCounts: ["K000384": 2, "W000805": 0, "W000831": 1],
                historyWindow: .oneWeek,
                districtCode: "VA-11",
                onAddAddress: {}
            )
        })
        XCTAssertTrue(strings.contains("Your representatives, Virginia's 11th district"), strings.joined(separator: " | "))
        XCTAssertTrue(strings.contains("Senator Tim Kaine, Democrat, Virginia, 2 bills this week"), strings.joined(separator: " | "))
        XCTAssertTrue(strings.contains("Representative James R. Walkinshaw, Democrat, Virginia's 11th district, 1 bill this week"), strings.joined(separator: " | "))
        XCTAssertFalse(strings.contains { $0.localizedCaseInsensitiveContains("Bills this week") && !$0.contains(",") }, "the column heads are not read")
    }

    /// A roll sheet is a sheet on paper (spec 3.15, 1.1): the `sheet` fill inside, a 1 pt `rule` at its
    /// edge, and paper right outside it, so no shadow.
    func testRollSheetIsASheetOnPaperWithNoShadow() throws {
        for scheme in [ColorScheme.light, .dark] {
            let look = Variant(scheme: scheme, size: .large)
            let view = RollSheet {
                RollLinkRow(title: "Parties", subtitle: "Members and bills by party")
                HairlineRule()
                RollLinkRow(title: "Senate", subtitle: "100 members")
            }
            .padding(16)
            .background(BillboardColors.background)
            let image = try render(view, variant: look, width: 390, scale: 3)
            let isDark = scheme == .dark
            let midY = image.height / 4
            assertColor(try pixel(of: image, x: 3 * 16 + 30, y: midY), BillboardPalette.cardBackground.resolved(dark: isDark), "sheet inside \(scheme)")
            assertColor(try pixel(of: image, x: 3 * 16 - 3, y: midY), BillboardPalette.background.resolved(dark: isDark), "paper just outside the edge, no shadow \(scheme)")
            assertColor(try pixel(of: image, x: 3 * 16 + 1, y: midY), over(BillboardPalette.separator.resolved(dark: isDark), BillboardPalette.cardBackground.resolved(dark: isDark)), "the rule at the edge \(scheme)", accuracy: 0.06)
        }
    }

    // MARK: - Members you follow, search results, How Congress works (spec 4.56, 4.57, 4.58)

    func testFollowedMembersRenderWithAndWithoutMembers() throws {
        let members = try virginia() + mixed()
        for variant in Self.variants + [Self.ax5] {
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let filled = CongressFollowedMembersSection(members: members, isLoading: false, onUnfollow: { _ in })
            let image = try render(page(filled), variant: variant, width: width)
            attach(image, name: "congress-followed-\(variant.name)")
            XCTAssertGreaterThanOrEqual(image.height, members.count * 44, variant.name)

            let empty = CongressFollowedMembersSection(members: [], isLoading: false, onUnfollow: { _ in })
            attach(try render(page(empty), variant: variant, width: width), name: "congress-followed-empty-\(variant.name)")
        }
        for (name, view) in [
            ("loading", CongressFollowedMembersSection(members: [], isLoading: true, onUnfollow: { _ in })),
            ("unavailable", CongressFollowedMembersSection(members: [], isLoading: false, isUnavailable: true, onUnfollow: { _ in }))
        ] {
            attach(try render(page(view), variant: Self.variants[0]), name: "congress-followed-\(name)-light-default")
        }
    }

    /// Unfollow keeps its own element and says whom it unfollows.
    func testUnfollowIsItsOwnElement() throws {
        let members = try mixed()
        let text = AccessibilityTreeText.text(of: NavigationStack {
            CongressFollowedMembersSection(members: members, isLoading: false, onUnfollow: { _ in })
        })
        XCTAssertTrue(text.contains("Unfollow Bernard Sanders"), text)
        XCTAssertTrue(text.contains("Senator Bernard Sanders, Independent, Vermont"), text)
        XCTAssertTrue(text.contains("Members you follow, 3 members"), text)
    }

    func testSearchResultsRenderWithTheTruncationNote() throws {
        let members = try virginia() + mixed()
        for variant in Self.variants + [Self.ax5] {
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let results = CongressMemberSearchResults(
                query: "va",
                filter: .all,
                results: CongressTabModel.InlineResults(members: members, totalCount: 43),
                followedMemberIDs: ["K000384"],
                hasUserState: true,
                isLoadingMembers: false,
                onAddAddress: {}
            )
            let image = try render(page(results), variant: variant, width: width)
            attach(image, name: "congress-search-results-\(variant.name)")
            XCTAssertGreaterThanOrEqual(image.height, members.count * 44, variant.name)
        }

        let noMatch = CongressMemberSearchResults(
            query: "zzz",
            filter: .all,
            results: CongressTabModel.InlineResults(members: [], totalCount: 0),
            followedMemberIDs: [],
            hasUserState: true,
            isLoadingMembers: false,
            onAddAddress: {}
        )
        attach(try render(page(noMatch), variant: Self.variants[1]), name: "congress-search-no-match-dark-default")

        let myStateWithoutAddress = CongressMemberSearchResults(
            query: "",
            filter: .myState,
            results: CongressTabModel.InlineResults(members: [], totalCount: 0),
            followedMemberIDs: [],
            hasUserState: false,
            isLoadingMembers: false,
            onAddAddress: {}
        )
        attach(try render(page(myStateWithoutAddress), variant: Self.variants[0]), name: "congress-search-my-state-no-address-light-default")
    }

    /// A followed member in search and the directory says "Following" in words, not a purple check.
    func testAFollowedMemberSaysFollowing() throws {
        let kaine = try virginia()[0]
        XCTAssertEqual(
            AccessibilityTreeText.strings(of: CongressMemberRow(manifest: kaine, isSubscribed: true)),
            ["Senator Tim Kaine, Democrat, Virginia, Following"]
        )
        XCTAssertEqual(
            AccessibilityTreeText.strings(of: CongressMemberRow(manifest: kaine)),
            ["Senator Tim Kaine, Democrat, Virginia"]
        )
    }

    func testWholeTabRendersInEveryVariant() throws {
        let reps = try virginia()
        let followed = try mixed()
        let session = CongressCalendar.Session(congress: 119, session: 2)
        for variant in Self.variants {
            let tab = VStack(alignment: .leading, spacing: CongressTabLayout.sectionSpacing) {
                // The page title on paper under the compact masthead (Civic Record spec 3.21).
                PageTitle(title: "Congress", deck: CongressDeck.unbrokenText(session: session, houseCount: 435, senateCount: 100))
                YourRepresentativesContent(
                    state: .members(reps),
                    billCounts: ["K000384": 2],
                    historyWindow: .oneWeek,
                    districtCode: "VA-11",
                    onAddAddress: {}
                )
                CongressFollowedMembersSection(members: followed, isLoading: false, onUnfollow: { _ in })
                CongressMemberSearchSection(
                    searchText: .constant("kaine"),
                    filter: .constant(.all),
                    results: CongressTabModel.InlineResults(members: [reps[0]], totalCount: 1),
                    followedMemberIDs: [],
                    hasUserState: true,
                    isLoadingMembers: false,
                    totalMemberCount: 535,
                    userState: "VA",
                    onAddAddress: {}
                )
                CongressHowItWorksSection(houseCount: 435, senateCount: 100)
            }
            // The search field uses `@FocusState`, which needs a window (`HostedRender`).
            let image = try HostedRender.image(
                tabPage(tab)
                    .frame(width: 390)
                    .environment(\.colorScheme, variant.scheme)
                    .environment(\.dynamicTypeSize, variant.size),
                width: 390,
                height: nil,
                style: variant.scheme == .dark ? .dark : .light
            )
            attach(image, name: "congress-tab-\(variant.name)")
            XCTAssertGreaterThan(image.height, 600, variant.name)
        }
    }

    /// The tab's load error is a RecordNotice with COULDN'T LOAD and Try again.
    func testLoadErrorRenders() throws {
        for variant in [Self.variants[0], Self.variants[1]] {
            let view = CongressLoadErrorCard(message: CongressLoadErrorCard.defaultMessage) {}
            attach(try render(tabPage(view), variant: variant), name: "congress-load-error-\(variant.name)")
        }
        let text = AccessibilityTreeText.text(of: CongressLoadErrorCard(message: CongressLoadErrorCard.defaultMessage) {})
        XCTAssertTrue(text.contains("Couldn't load. Couldn't load members. Check your connection, then try again."), text)
        XCTAssertTrue(text.contains("Try again"), text)
    }

    // MARK: - Member rows (spec 3.15, 7.2)

    func testMemberRowsAndPartyRowsRender() throws {
        let members = try virginia() + mixed()
        for variant in Self.variants + [Self.ax5] {
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let view = VStack(alignment: .leading, spacing: 16) {
                RollSheet {
                    RollRows(members) { _, member in
                        CongressMemberRow(manifest: member, isSubscribed: member.id == "K000384")
                    }
                }
                RollSheet {
                    RollRows(PoliticalParty.allCases) { _, party in
                        PoliticalPartyRow(party: party, totalCount: 47, houseCount: 0, senateCount: 47)
                    }
                }
            }
            let image = try render(tabPage(view), variant: variant, width: width)
            attach(image, name: "congress-rows-\(variant.name)")
            XCTAssertGreaterThan(image.height, 0)
        }
    }

    /// At AX5 a member row stacks, so the name has the row's whole width: no word of a long member name is
    /// wider than that on a 375 pt phone, so names break between words, never inside one (they broke as
    /// "Walkinsh/aw" beside the monogram in R2's row).
    func testLongNamesBreakBetweenWordsAtAX5() throws {
        let sheetWidth = Self.narrowWidth - 2 * CongressTabLayout.gutter
        let textWidth = sheetWidth - RollRowInsets.leading - RollRowInsets.trailing
        let members = try longNames()
        for member in members {
            for name in [member.name, CongressMemberLabel.titledName(member.name, chamber: .house)] {
                for word in name.split(separator: " ").map(String.init) {
                    let width = try naturalWidth(of: Text(word).textRole(.name), size: .accessibility5)
                    XCTAssertLessThanOrEqual(width, textWidth, "\(word) (\(width) pt) fits the \(textWidth) pt name column at AX5")
                }
            }
        }

        // The rows themselves, for review, in each list style.
        let view = VStack(alignment: .leading, spacing: 16) {
            RollSheet {
                RollRows(members) { _, member in
                    CongressRepresentativeRow(member: member, billCount: 2, billCountText: "2 bills this week")
                }
            }
            CongressFollowedMembersSection(members: members, isLoading: false, onUnfollow: { _ in })
        }
        attach(try render(tabPage(view), variant: Self.ax5, width: Self.narrowWidth), name: "congress-long-names-AX5")
    }

    // MARK: - Member page (spec 4.59)

    func testMemberPageRendersInEveryVariant() throws {
        let store = CivicProfileStore(service: FakeCivicService())
        let modes: [(String, CongressMemberCivicProfileCardMode)] = [
            ("ready", .profile(readyProfile([0.7, 0.4, 0.62, 0.56, 0.34, 0.82]))),
            ("locked", .profile(lockedProfile())),
            ("loading", .loading),
            ("unavailable", .unavailable)
        ]
        for (name, mode) in modes {
            let variants = name == "ready" ? Self.variants + [Self.ax5] : [Self.variants[0], Self.variants[3]]
            for variant in variants {
                let view = CongressMemberPageContent(member: pageMember(), civicProfileMode: mode)
                    .background(BillboardColors.document)
                    .environmentObject(store)
                let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
                let image = try render(view, variant: variant, width: width)
                attach(image, name: "member-page-\(name)-\(variant.name)")
                XCTAssertGreaterThan(image.height, 600, "\(name) \(variant.name)")
            }
        }
    }

    /// The member page is a document: white in light, night paper in dark (spec 2.1, 4.59).
    func testMemberPageGroundIsTheDocument() throws {
        let store = CivicProfileStore(service: FakeCivicService())
        for scheme in [ColorScheme.light, .dark] {
            let view = CongressMemberPageContent(member: pageMember(), civicProfileMode: .unavailable)
                .background(BillboardColors.document)
                .environmentObject(store)
            let image = try render(view, variant: Variant(scheme: scheme, size: .large))
            assertColor(try pixel(of: image, x: 4, y: 4), BillboardPalette.document.resolved(dark: scheme == .dark), "document \(scheme)")
        }
    }

    /// The front matter is one header that reads the member as R2 did; the Basics are ledger rows.
    func testMemberPageReadsTheFrontMatterAndLedgers() {
        let store = CivicProfileStore(service: FakeCivicService())
        let text = AccessibilityTreeText.text(
            of: CongressMemberPageContent(member: pageMember(), civicProfileMode: .unavailable).environmentObject(store),
            size: CGSize(width: 390, height: 2400)
        )
        XCTAssertTrue(text.contains("Representative Jordan Ellis, Republican, Texas's 7th district"), text)
        XCTAssertTrue(text.contains("Party: Republican"), text)
        XCTAssertTrue(text.contains("District: 7th"), text)
        XCTAssertTrue(text.contains("Proposed Legislation: 14"), text)
        XCTAssertTrue(text.contains(CongressMemberPageContent.trackedCaption), text)
        XCTAssertTrue(text.contains("Civic Profile"), text)
    }

    /// Billboard tracks only the 119th Congress, so the caption names it as a fixed number.
    func testTrackedCaptionNamesThe119thCongress() {
        XCTAssertEqual(CongressMemberPageContent.trackedCaption, "Counts only 119th Congress bills in Billboard.")
        XCTAssertEqual(CongressMemberPageContent.careerCaption, "Career totals from Congress.gov.")
    }

    func testLockedMemberCivicProfileRenders() throws {
        let store = CivicProfileStore(service: FakeCivicService())
        for variant in Self.variants + [Self.ax5] {
            let card = CongressMemberCivicProfileCard(mode: .profile(lockedProfile()), memberName: "Jordan Ellis")
                .background(BillboardColors.document)
                .environmentObject(store)
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let image = try render(card, variant: variant, width: width)
            attach(image, name: "member-civic-locked-\(variant.name)")
            XCTAssertGreaterThan(image.height, 100, variant.name)
        }
    }

    /// Compare to you: the member solid, you dashed, the legend by line style and the scores by theme.
    func testComparisonRendersInEveryVariant() throws {
        let member = readyProfile([0.7, 0.4, 0.62, 0.56, 0.34, 0.82])
        var userValues = [0.52, 0.61, 0.48, 0.66, 0.44, 0.57]
        userValues[5] = -1
        let user = CivicProfileResponse(
            axes: Dictionary(uniqueKeysWithValues: zip(CivicProfileAxis.allCases.map(\.rawValue).prefix(5), userValues.prefix(5))),
            votesUsed: 47,
            totalVotesWithProfile: 52,
            minVotesRequired: 25,
            isReady: true
        )
        let datasets = CongressMemberCivicProfileCard.comparisonDatasets(member: member, user: user, memberName: "Jordan Ellis")
        for variant in Self.variants + [Self.ax5] {
            let view = VStack(alignment: .leading, spacing: 12) {
                RadarChartView(datasets: datasets)
                RadarLegend(datasets: datasets)
                CivicProfileComparisonSummary(memberProfile: member, userProfile: user)
            }
            .padding(20)
            .background(BillboardColors.document)
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let image = try render(view, variant: variant, width: width)
            attach(image, name: "member-civic-compare-\(variant.name)")
            XCTAssertGreaterThan(image.height, 300, variant.name)
        }
    }

    /// Compare to you when your count is capped (project decision of 2026-10-29): "Your chart is based on your last 100
    /// bill votes.", as Profile says "Based on your last 100 votes"; otherwise "Your chart is based on 47 bill votes."
    /// as before. VoiceOver reads the line as it is drawn. Rendered light and dark at the default size, AX3 and AX5.
    func testCompareToYouSaysWhenYourChartIsCapped() throws {
        let member = readyProfile([0.7, 0.4, 0.62, 0.56, 0.34, 0.82])
        let axes = Dictionary(uniqueKeysWithValues: zip(CivicProfileAxis.allCases.map(\.rawValue), [0.52, 0.61, 0.48, 0.66, 0.44, 0.57]))
        let capped = CivicProfileResponse(axes: axes, votesUsed: 100, totalVotesWithProfile: 312, minVotesRequired: 25, isReady: true)
        let uncapped = CivicProfileResponse(axes: axes, votesUsed: 47, totalVotesWithProfile: 47, minVotesRequired: 25, isReady: true)
        for variant in Self.variants + [Self.ax5, Variant(scheme: .dark, size: .accessibility5)] {
            let view = CongressMemberCivicProfileComparison(memberProfile: member, userProfile: capped, memberName: "Jordan Ellis")
                .padding(20)
                .background(BillboardColors.document)
            let width = variant.size == .accessibility5 ? Self.narrowWidth : 390
            let image = try render(view, variant: variant, width: width)
            attach(image, name: "member-civic-compare-capped-\(variant.name)")
            XCTAssertGreaterThan(image.height, 300, variant.name)
        }

        for (profile, line, isCapped) in [
            (capped, "Your chart is based on your last 100 bill votes.", true),
            (uncapped, "Your chart is based on 47 bill votes.", false)
        ] {
            let host = AccessibilityTreeText.Host(
                CongressMemberCivicProfileComparison(memberProfile: member, userProfile: profile, memberName: "Jordan Ellis").padding(20),
                size: CGSize(width: 390, height: 1400)
            )
            let text = host.text()
            let identifiers = host.identifiers()
            host.close()
            XCTAssertTrue(text.contains(line), text)
            XCTAssertEqual(text.contains("your last"), isCapped, text)
            XCTAssertTrue(identifiers.contains("member.civicProfile.comparison"), "\(identifiers)")
        }
    }

    /// The chart is ink only (spec 3.27): no pixel of the drawing, the grid or the labels has a hue (the six
    /// theme hues and the teal polygon are gone).
    func testRadarChartIsInkOnly() throws {
        let member = readyProfile([0.7, 0.4, 0.62, 0.56, 0.34, 0.82])
        let user = readyProfile([0.52, 0.61, 0.48, 0.66, 0.44, 0.57])
        for scheme in [ColorScheme.light, .dark] {
            for (name, chart) in [
                ("single", AnyView(RadarChartView(profile: member, scoreSubjectLabel: "Member"))),
                ("compare", AnyView(RadarChartView(datasets: CongressMemberCivicProfileCard.comparisonDatasets(member: member, user: user, memberName: "Jordan Ellis"))))
            ] {
                let image = try render(chart.padding(20).background(BillboardColors.document), variant: Variant(scheme: scheme, size: .large), width: 390, scale: 2)
                attach(image, name: "radar-\(name)-\(scheme == .dark ? "dark" : "light")")
                let chroma = try maximumChroma(of: image)
                // Ink is a blue-black (#0E1A2E, 0.13 apart) and its dark value a blue-white; a hue is far more.
                XCTAssertLessThan(chroma, 0.2, "\(name) \(scheme): the most colourful pixel is \(chroma) apart in its channels")
            }
        }
    }

    /// At accessibility sizes the themes leave the chart and are listed under it with their scores, each
    /// one element.
    func testRadarListsItsThemesAtAccessibilitySizes() {
        let profile = readyProfile([0.7, 0.4, 0.62, 0.56, 0.34, 0.82])
        let text = AccessibilityTreeText.text(
            of: RadarChartView(profile: profile, scoreSubjectLabel: "Member").environment(\.dynamicTypeSize, .accessibility3),
            size: CGSize(width: 390, height: 2400)
        )
        for axis in CivicProfileAxis.allCases {
            XCTAssertTrue(text.contains(axis.explanation), "\(axis) in \(text)")
        }
        XCTAssertTrue(text.contains("Member: "), text)
    }

    // MARK: - Parties and chamber pages (spec 4.58)

    /// The House as the live manifest had it on 2026-10-31: 433 voting members (D 215, R 218; two seats
    /// vacant), then DC's and the territories' 6 delegates (D 3, R 3), all on the House page's roll.
    private func liveHouseRoll() throws -> [CongressMemberManifestItem] {
        var roll: [CongressMemberManifestItem] = []
        for index in 0..<433 {
            roll.append(try member("H\(index)", "Member \(index)", chamber: "House of Representatives", state: "VA", district: index % 11 + 1, party: index < 215 ? "D" : "R"))
        }
        for (index, place) in ["DC", "PR", "VI", "GU", "AS", "MP"].enumerated() {
            roll.append(try member("DEL\(index)", "Delegate \(place)", chamber: "House of Representatives", state: place, party: index < 3 ? "D" : "R"))
        }
        return roll
    }

    /// The Senate on 2026-10-31: D 45, R 53, I 2.
    private func liveSenate() throws -> [CongressMemberManifestItem] {
        try (0..<100).map { index in
            try member("S\(index)", "Senator \(index)", chamber: "Senate", state: "VA", party: index < 45 ? "D" : (index < 98 ? "R" : "I"))
        }
    }

    /// The pages count the voting seats (project decision 2026-10-31): the House page's docket names the
    /// delegates its roll lists, and no page has the "Bills sponsored" figure, removed in RC 4.
    func testPartiesAndChamberPagesRender() throws {
        let members = try mixed()
        let houseRoll = try liveHouseRoll()
        let republicans = (houseRoll + (try liveSenate())).filter { $0.party == "R" }
        let partyRows = PoliticalPartyDetailView.compositionRows(for: republicans)
        XCTAssertEqual(partyRows.map(\.value), ["271", "218 · 80%", "53 · 20%"])
        let chamberDocket = CongressChamberInfoView.docket(for: houseRoll)
        let chamberRows = CongressChamberInfoView.compositionRows(for: houseRoll)
        XCTAssertEqual(chamberDocket, "433 members\u{00A0}· 6 delegates")
        XCTAssertEqual(chamberRows.map(\.value), ["215 · 50%", "218 · 50%", "0 · 0%"])
        let rows = [(label: "Civil Rights and Liberties", value: "40%"), (label: "Taxation", value: "20%")]
        for variant in Self.variants {
            let party = VStack(alignment: .leading, spacing: 0) {
                CongressDocumentFrontMatter(title: PoliticalParty.republican.rawValue, party: .republican, docket: "States: AK, AL, TX, VA")
                RecordSection("Composition", showsRule: false) {
                    CongressFigureList(rows: partyRows)
                }
                RecordSection("Bills by topic") {
                    CongressFigureList(rows: rows)
                }
                RecordSection("Bills by topic group") {
                    CongressFigureList(rows: [], emptyText: "No bills yet")
                }
                RecordSection("Members") {
                    RollSheet {
                        RollRows(members) { _, member in
                            CongressMemberRow(manifest: member)
                        }
                    }
                }
            }
            .background(BillboardColors.document)
            let image = try render(party, variant: variant)
            attach(image, name: "congress-party-page-\(variant.name)")
            XCTAssertGreaterThan(image.height, 500, variant.name)

            let chamber = VStack(alignment: .leading, spacing: 0) {
                CongressDocumentFrontMatter(title: CongressChamber.house.displayName, docket: chamberDocket)
                RecordSection("Composition", showsRule: false) {
                    CongressFigureList(rows: chamberRows)
                }
                RecordSection("Bills by topic group") {
                    CongressFigureList(rows: rows)
                }
            }
            .background(BillboardColors.document)
            attach(try render(chamber, variant: variant), name: "congress-chamber-page-\(variant.name)")
        }
    }

    /// The House page's docket, "433 MEMBERS · 6 DELEGATES", breaks only after its dot, so at AX5 on a
    /// 375 pt phone a line never starts with "·" (as the deck and the party rows).
    func testTheHouseDocketNeverStartsALineWithADot() throws {
        let docket = CongressChamberInfoView.docket(for: try liveHouseRoll())
        XCTAssertFalse(docket.contains(" ·"), "no breakable space before the dot")
        let column = Self.narrowWidth - 2 * BillboardStyle.Space.xl
        for run in docket.split(separator: " ").map(String.init) {
            let width = try naturalSize(of: Text(run).textRole(.docket), size: .accessibility5).width
            XCTAssertLessThanOrEqual(width, column, "\(run) (\(width) pt) fits the \(column) pt docket at AX5")
        }
        let page = CongressDocumentFrontMatter(title: CongressChamber.house.displayName, docket: docket)
            .background(BillboardColors.document)
        attach(try render(page, variant: Self.ax5, width: Self.narrowWidth), name: "congress-chamber-docket-AX5")
    }

    // MARK: - Topic groups and life areas (spec 4.27)

    func testTopicGroupListRenders() throws {
        let items = [
            CongressInsightList<EmptyView>.Item(name: "Agriculture and Food", billCount: 12),
            .init(name: "Civil Rights and Liberties", billCount: 1),
            .init(name: "Economy and Finance", billCount: 0)
        ]
        for variant in Self.variants {
            attach(try render(tabPage(CongressInsightList(items: items) { _ in EmptyView() }), variant: variant), name: "congress-topic-groups-\(variant.name)")
        }
        let text = AccessibilityTreeText.text(of: NavigationStack { CongressInsightList(items: items) { _ in EmptyView() } })
        XCTAssertTrue(text.contains("Agriculture and Food, 12 bills"), text)
        XCTAssertTrue(text.contains("Civil Rights and Liberties, 1 bill"), text)
    }

    // MARK: - The member page's error state

    func testMemberLoadErrorRenders() throws {
        for variant in [Self.variants[0], Self.variants[1], Self.variants[2]] {
            let view = VStack(alignment: .leading, spacing: 8) {
                RecordNotice(
                    .couldNotLoad,
                    title: CongressMemberLoadErrorView.title,
                    message: "Check your connection and try again, or use the basic profile.",
                    action: .init(title: "Try again") {}
                )
                MemberBasicProfileButton {}
            }
            .padding(20)
            .background(BillboardColors.document)
            attach(try render(view, variant: variant), name: "member-load-error-\(variant.name)")
        }
    }

    /// "Use basic profile" (under "Couldn't load this member") is an ink text link, readable on the document in
    /// light, dark and both Increase Contrast modes: its label is at least 4.5:1 against the ground. It is
    /// hosted in a window, as the app draws it.
    func testUseBasicProfileLinkIsReadable() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let name = (style == .dark ? "dark" : "light") + (contrast == .high ? "-increase-contrast" : "")
                let image = try hostedImage(MemberBasicProfileButton(action: {}), style: style, contrast: contrast)
                attach(image, name: "member-basic-profile-link-\(name)")
                let (ground, label) = try groundAndLabel(of: image)
                let ratio = BillboardColorMath.contrastRatio(ground, label)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name): label \(label) on \(ground)")
            }
        }
    }

    // MARK: - Review fixes: rows, heads and lines at AX5 (spec 2.5, 7.2)

    /// The party rows stack at accessibility sizes as member rows do: the disc's line holds only the disc
    /// and the chevron, and the name and the counts take the row's whole width, where no party name and
    /// no unbreakable run of the counts is wider than the column on a 375 pt phone. Beside the disc they
    /// broke as "Democra/tic", and a dot started a line.
    func testPartyRowsStackAndBreakBetweenWordsAtAX5() throws {
        let sheetWidth = Self.narrowWidth - 2 * CongressTabLayout.gutter
        let textWidth = sheetWidth - RollRowInsets.leading - RollRowInsets.trailing
        let counts = CongressMemberLabel.docketText(PoliticalPartyRow.summary(totalCount: 271, houseCount: 220, senateCount: 53))
        for party in PoliticalParty.allCases {
            for word in party.rawValue.split(separator: " ").map(String.init) {
                let width = try naturalSize(of: Text(word).textRole(.name), size: .accessibility5).width
                XCTAssertLessThanOrEqual(width, textWidth, "\(word) (\(width) pt) fits the \(textWidth) pt column at AX5")
            }
        }
        // The counts break only after a dot: "271 MEMBERS ·", "220 HOUSE ·", "53 SENATE".
        for run in counts.split(separator: " ").map(String.init) {
            let width = try naturalSize(of: Text(run).textRole(.docket), size: .accessibility5).width
            XCTAssertLessThanOrEqual(width, textWidth, "\(run) (\(width) pt) fits the \(textWidth) pt column at AX5")
        }
        XCTAssertFalse(counts.contains(" ·"), "no breakable space before a dot")

        // The disc's line: nothing drawn between the disc and the chevron.
        let disc = try naturalSize(of: PartyBadge(party: .independent, size: .regular), size: .accessibility5)
        let chevron = try naturalSize(of: RowChevron(), size: .accessibility5)
        let row = PoliticalPartyRow(party: .independent, totalCount: 271, houseCount: 220, senateCount: 53)
            .background(BillboardColors.cardBackground)
        let image = try render(row, variant: Self.ax5, width: sheetWidth, scale: 2)
        attach(image, name: "congress-party-row-light-AX5")
        let pixels = try rgbaPixels(of: image)
        let sheet = BillboardPalette.cardBackground.resolved(dark: false)
        let band = CGRect(
            x: RollRowInsets.leading + disc.width + 4,
            y: RollRowInsets.vertical + 2,
            width: sheetWidth - RollRowInsets.trailing - chevron.width - 4 - (RollRowInsets.leading + disc.width + 4),
            height: disc.height - 4
        )
        let inked = pixels.count(in: band, scale: 2) { abs($0.red - sheet.red) + abs($0.green - sheet.green) + abs($0.blue - sheet.blue) > 0.3 }
        XCTAssertEqual(inked, 0, "the disc's line holds only the disc and the chevron (band \(band))")
    }

    /// "Scores by theme" wraps at AX5 instead of ending in "SCORES BY TH…" (spec 2.5: uppercase roles never
    /// truncate), and the scores under a theme break only after the dot, never before it.
    func testScoresByThemeWrapsAndItsScoreLinesKeepTheirDotsAtAX5() throws {
        let column = Self.narrowWidth - 40
        let natural = try naturalSize(of: Text(CivicProfileScoresHead.title).textRole(.label), size: .accessibility5)
        XCTAssertGreaterThan(natural.width, column, "the head is wider than the column at AX5, so it must wrap")
        let head = try render(CivicProfileScoresHead(columnWidth: 60), variant: Self.ax5, width: column)
        XCTAssertGreaterThanOrEqual(CGFloat(head.height), 2 * natural.height - 1, "two lines, not one truncated line")

        let line = CivicProfileComparisonSummary.accessibilitySizeScores(member: 8, user: nil)
        XCTAssertEqual(line, "Member\u{00A0}8\u{00A0}· You\u{00A0}–")
        for run in CivicProfileComparisonSummary.accessibilitySizeScores(member: 10, user: 10).split(separator: " ").map(String.init) {
            let width = try naturalSize(of: Text(run).textRole(.figure), size: .accessibility5).width
            XCTAssertLessThanOrEqual(width, column, "\(run) (\(width) pt) fits the \(column) pt column at AX5")
        }
    }

    /// The Congress deck breaks only after a dot (or inside "119th Congress"), so at AX5 a line never
    /// starts with "·"; it says what `CongressDeck.text` says.
    func testTheCongressDeckNeverStartsALineWithADot() throws {
        let session = CongressCalendar.Session(congress: 119, session: 2)
        let deck = CongressDeck.unbrokenText(session: session, houseCount: 435, senateCount: 100)
        XCTAssertEqual(deck, "119th Congress\u{00A0}· House\u{00A0}435\u{00A0}· Senate\u{00A0}100")
        XCTAssertEqual(deck.replacingOccurrences(of: "\u{00A0}", with: " "), CongressDeck.text(session: session, houseCount: 435, senateCount: 100))
        XCTAssertEqual(CongressDeck.unbrokenText(session: session, houseCount: 0, senateCount: 0), "119th Congress")
        let column = Self.narrowWidth - 2 * CongressTabLayout.gutter - 8
        for run in deck.split(separator: " ").map(String.init) {
            let width = try naturalSize(of: Text(run).textRole(.docket), size: .accessibility5).width
            XCTAssertLessThanOrEqual(width, column, "\(run) (\(width) pt) fits the \(column) pt deck at AX5")
        }
        attach(try render(tabPage(PageTitle(title: "Congress", deck: deck)), variant: Self.ax5, width: Self.narrowWidth), name: "congress-page-title-AX5")
    }

    /// In Your representatives the figure stands 14 pt from the chevron, as frame 12 spaces them, so the
    /// dash shown while the bills load does not join the chevron into an arrow.
    func testTheFigureStandsApartFromTheChevron() throws {
        XCTAssertEqual(MemberRollRow.figureToChevron, 14)
        let member = try virginia()[0]
        for (name, count) in [("loading", nil), ("two", 2)] as [(String, Int?)] {
            let row = CongressRepresentativeRow(member: member, billCount: count, billCountText: "Updating…")
                .background(BillboardColors.cardBackground)
            let image = try render(row, variant: Self.variants[0], width: 358, scale: 2)
            attach(image, name: "congress-representative-figure-\(name)")
            let pixels = try rgbaPixels(of: image)
            let sheet = BillboardPalette.cardBackground.resolved(dark: false)
            let midY = image.height / 2
            // Columns with ink across the row's middle band, right to left: the chevron, a gap, the figure.
            let inkColumns = (0..<image.width).map { x in
                (midY - 12...midY + 12).contains { y in
                    let p = pixels.at(x, y)
                    return abs(p.red - sheet.red) + abs(p.green - sheet.green) + abs(p.blue - sheet.blue) > 0.3
                }
            }
            var x = image.width - 1
            while x > 0, !inkColumns[x] { x -= 1 }
            while x > 0, inkColumns[x] { x -= 1 }
            let gapEnd = x
            while x > 0, !inkColumns[x] { x -= 1 }
            let gap = CGFloat(gapEnd - x) / 2
            XCTAssertGreaterThanOrEqual(gap, 12, "\(name): \(gap) pt of sheet between the figure and the chevron")
        }
    }

    // MARK: - Review fixes: identifiers and VoiceOver (spec 4.77, 3.27)

    /// Every control on the Congress tab keeps its own id: a section's id is a container's, so it no longer
    /// replaces the ids of the rows and buttons inside it (the UI tests tap congress.nav.house). The
    /// sections' and the load error's ids are kept on their containers.
    func testControlsInsideTheSectionsKeepTheirOwnIdentifiers() throws {
        let members = try virginia()
        let store = CivicProfileStore(service: FakeCivicService())
        let host = AccessibilityTreeText.Host(
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        CongressLoadErrorCard(message: CongressLoadErrorCard.defaultMessage) {}
                        YourRepresentativesContent(state: .members(members), billCounts: ["K000384": 2], historyWindow: .oneWeek, districtCode: "VA-11", onAddAddress: {})
                        CongressFollowedMembersSection(members: members, isLoading: false, onUnfollow: { _ in })
                        CongressMemberSearchSection(
                            searchText: .constant("kaine"),
                            filter: .constant(.all),
                            results: CongressTabModel.InlineResults(members: [members[0]], totalCount: 1),
                            followedMemberIDs: [],
                            hasUserState: true,
                            isLoadingMembers: false,
                            totalMemberCount: 535,
                            userState: "VA",
                            onAddAddress: {}
                        )
                        CongressHowItWorksSection(houseCount: 435, senateCount: 100)
                        CongressMemberCivicProfileCard(mode: .profile(readyProfile([0.7, 0.4, 0.62, 0.56, 0.34, 0.82])), memberName: "Jordan Ellis")
                    }
                    .padding(16)
                }
            }
            .environmentObject(store),
            size: CGSize(width: 390, height: 4000),
            settle: 0.3
        )
        defer { host.close() }
        let expected = [
            "Try again": "congress.loadError.retry",
            "Senator Tim Kaine, Democrat, Virginia, 2 bills this week": "congress.representatives.member.0",
            "Senator Tim Kaine, Democrat, Virginia": "congress.followed.member.0",
            "Unfollow Mark R. Warner": "congress.followed.unfollow.1",
            "See all members": "congress.nav.members",
            "Parties, Members and bills by party": "congress.nav.politicalParties",
            "House of Representatives, 435 members": "congress.nav.house",
            "Senate, 100 members": "congress.nav.senate",
            "Details": "member.civicProfile.details"
        ]
        for (label, id) in expected {
            XCTAssertEqual(host.identifier(of: label), id, label)
        }
        let all = host.identifiers()
        for id in ["congress.search.field", "congress.search.member.0"] {
            XCTAssertTrue(all.contains(id), "\(id) in \(all.sorted())")
        }
        for id in ["congress.loadError", "congress.representatives", "congress.followed", "congress.search", "congress.howItWorks", "member.civicProfile.card"] {
            XCTAssertTrue(all.contains(id), "\(id) is kept on its section, in \(all.sorted())")
        }
    }

    /// The Civic Profile chart's plot is hidden from VoiceOver (spec 3.27), so there is no empty stop
    /// between the theme labels; the info overlay still hides the chart while it is open.
    ///
    /// Your profile is read before the card is hosted, so the card starts no read of its own. A read now
    /// runs in the store's own task (UX-39 N11), so the card shows its comparison loading line for a moment;
    /// UIKit's spinner from that line can stay in the window after it, where the subview walk counts it as an
    /// empty element though VoiceOver, which follows the page's accessibility elements, never reaches it.
    func testTheCivicProfileChartHasNoEmptyVoiceOverStop() throws {
        let store = CivicProfileStore(service: FakeCivicService())
        let read = expectation(description: "your profile is read")
        Task {
            await store.refresh()
            read.fulfill()
        }
        wait(for: [read], timeout: 5)
        XCTAssertTrue(store.hasRefreshedOnce)
        let host = AccessibilityTreeText.Host(
            NavigationStack {
                ScrollView {
                    CongressMemberCivicProfileCard(mode: .profile(readyProfile([0.7, 0.4, 0.62, 0.56, 0.34, 0.82])), memberName: "Jordan Ellis")
                }
            }
            .environmentObject(store),
            size: CGSize(width: 390, height: 2000),
            settle: 0.3
        )
        defer { host.close() }
        let elements = host.elements()
        XCTAssertEqual(elements.filter { $0.label.trimmingCharacters(in: .whitespaces).isEmpty }.count, 0, elements.map(\.label).joined(separator: " | "))
        XCTAssertEqual(elements.filter { $0.label.contains("(1) to ") }.count, CivicProfileAxis.allCases.count, "one element per theme")

        XCTAssertTrue(host.text().contains("Member: 7/10"), host.text())
        XCTAssertTrue(host.activate("About the civic profile chart", settle: 0.5))
        XCTAssertFalse(host.text().contains("Member: "), "the chart is hidden while the info is open: \(host.text())")
    }

    /// The member page's Follow button shows its word in the bar, not only a plus or a check (spec 4.59,
    /// 1.4): the bar drew a `Label` as a 36 pt icon disc. Hosted in a window on the screen, since only a
    /// real navigation bar lays out its items.
    func testTheFollowButtonShowsItsWordInTheBar() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for isFollowing in [false, true] {
            let host = AccessibilityTreeText.Host(
                NavigationStack {
                    Color.clear
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .glassNavigationBar()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                CongressFollowToolbarButton(isFollowing: isFollowing) {}
                            }
                        }
                },
                size: scene.screen.bounds.size,
                settle: 1.0,
                scene: scene
            )
            defer { host.close() }
            let button = try XCTUnwrap(host.elements().first { $0.identifier == "member.subscription" }, "the Follow button")
            XCTAssertEqual(button.label, CongressFollowToolbarButton.accessibilityLabel(isFollowing: isFollowing))
            let wordWidth = try naturalSize(of: Text(CongressFollowToolbarButton.title(isFollowing: isFollowing)), size: .large).width
            XCTAssertGreaterThan(button.frame.width, button.frame.height + wordWidth * 0.8, "isFollowing \(isFollowing): \(button.frame) holds the symbol and the word")
        }
    }

    /// Follow is drawn as the bill page's Watch (`DocumentToolbarLabel`): at accessibility text sizes it keeps
    /// the bar's size (the button offers the Large Content Viewer instead), and its glyphs are ink fixed to the
    /// member page's appearance. The page is pushed from the navy Congress root, so a held swipe back draws the
    /// bar in the root's dark appearance; the dynamic ink then resolved near-white on the pale glass (1.9:1 on
    /// the bill page, slice 4). Drawn here in the dark appearance on pale glass with the light page's ink, the
    /// glyphs keep that ink.
    func testTheFollowButtonKeepsTheBarsSizeAndThePagesInk() throws {
        for isFollowing in [false, true] {
            let button = CongressFollowToolbarButton(isFollowing: isFollowing) {}
            XCTAssertEqual(try naturalSize(of: button, size: .accessibility5), try naturalSize(of: button, size: .large), "isFollowing \(isFollowing): the bar's size at AX5")
        }

        let pageInk = try XCTUnwrap(DocumentToolbarGlyph.color(dark: false, increaseContrast: false, reduceTransparency: false))
        let glass = 0.92
        let image = try render(
            CongressFollowToolbarButton(isFollowing: false, glyphColor: pageInk) {}
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.sRGB, white: glass, opacity: 1)),
            variant: Variant(scheme: .dark, size: .large),
            width: 140,
            scale: 2
        )
        attach(image, name: "follow-in-a-dark-bar-on-pale-glass")
        let pixels = try rgbaPixels(of: image)
        var darkest = (red: 1.0, green: 1.0, blue: 1.0)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let pixel = pixels.at(x, y)
                if pixel.red + pixel.green + pixel.blue < darkest.red + darkest.green + darkest.blue { darkest = pixel }
            }
        }
        let ink = BillboardPalette.interactive.resolved(dark: false)
        XCTAssertEqual(darkest.red, ink.red, accuracy: 0.04, "the glyphs keep the light page's ink: \(darkest)")
        XCTAssertEqual(darkest.green, ink.green, accuracy: 0.04, "\(darkest)")
        XCTAssertEqual(darkest.blue, ink.blue, accuracy: 0.04, "\(darkest)")
    }

    // MARK: - Review fixes: document pages (spec 4.58, 4.59)

    /// A party or chamber page shows its title once: the bar shows no title while the front matter's title is
    /// on screen, and shows it once it has scrolled under the bar. The screen's title stays set all along, for
    /// the back button of a page pushed from here (`DocumentInlineTitle`, as on the bill page).
    func testADocumentPageShowsItsTitleInTheBarOnlyOnScroll() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = AccessibilityTreeText.Host(
            NavigationStack {
                CongressDocumentScroll(title: "House of Representatives", docket: "435 members") {
                    Color.clear.frame(height: 3000)
                }
                .navigationBarTitleDisplayMode(.inline)
            },
            size: scene.screen.bounds.size,
            settle: 1.0,
            scene: scene
        )
        defer { host.close() }
        let navigation = try XCTUnwrap(host.navigationController, "the stack's navigation controller")
        let scrollView = try XCTUnwrap(pageScrollView(in: host.window), "the page's scroll view")
        let title = "House of Representatives"
        func barShowsTitle() -> Bool { host.strings(under: navigation.navigationBar).contains(title) }

        XCTAssertEqual(navigation.topViewController?.navigationItem.title, title, "the screen's title, kept at rest")
        XCTAssertFalse(barShowsTitle(), "at rest the front matter shows the title: \(host.strings(under: navigation.navigationBar))")
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top + 300), animated: false)
        host.run(until: { barShowsTitle() })
        XCTAssertTrue(barShowsTitle(), "under the bar, the bar shows it: \(host.strings(under: navigation.navigationBar))")
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: false)
        host.run(until: { !barShowsTitle() })
        XCTAssertFalse(barShowsTitle(), "back at the top")
        XCTAssertEqual(navigation.topViewController?.navigationItem.title, title, "still the screen's title")
        XCTAssertTrue(DocumentInlineTitle.isPastTitle(contentOffsetY: 10, topInset: 100, titleBottom: 100))
        XCTAssertFalse(DocumentInlineTitle.isPastTitle(contentOffsetY: -100, topInset: 100, titleBottom: 100))
        XCTAssertFalse(DocumentInlineTitle.isPastTitle(contentOffsetY: 10, topInset: 100, titleBottom: 0), "not before the title is measured")
    }

    /// A stack whose path the test holds.
    private final class DocumentPushPath: ObservableObject {
        @Published var pages: [String] = []
    }

    /// A chamber page at the root of a stack whose path the test holds.
    private struct DocumentPushStack: View {
        @ObservedObject var path: DocumentPushPath

        var body: some View {
            NavigationStack(path: $path.pages) {
                CongressDocumentScroll(title: "House of Representatives", docket: "435 members") {
                    Color.clear.frame(height: 3000)
                }
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: String.self) { page in
                    Text(page)
                }
            }
        }
    }

    /// A page pushed from a document page at rest (a member from the chamber's roll, a bill from the member
    /// page) goes back to the page's title, not to "Back": the bar hides the title at rest, the screen keeps
    /// it.
    func testAPagePushedFromADocumentPageAtRestGoesBackToItsTitle() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let path = DocumentPushPath()
        let host = AccessibilityTreeText.Host(DocumentPushStack(path: path), size: scene.screen.bounds.size, settle: 1.0, scene: scene)
        defer { host.close() }
        let navigation = try XCTUnwrap(host.navigationController, "the stack's navigation controller")
        XCTAssertFalse(host.strings(under: navigation.navigationBar).contains("House of Representatives"), "not in the bar at rest")

        path.pages.append("Member page")
        host.run(untilSettled: {
            navigation.viewControllers.count == 2 && navigation.navigationBar.backItem?.title == "House of Representatives"
        })
        XCTAssertEqual(navigation.viewControllers.count, 2, "pushed")
        XCTAssertEqual(navigation.navigationBar.backItem?.title, "House of Representatives", "the back item")
    }

    // MARK: - Review fixes: more screens (spec 10.1)

    /// The member page's front matter with the member's photo inside the engraved ring and the party disc
    /// on a ring of the document, in light and dark. The photo loads from a file, as `AsyncImage` loads the
    /// bioguide photo, so the page is hosted in a window until it arrives.
    func testMemberPageRendersWithAPhoto() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("congress-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photoURL = folder.appendingPathComponent("photo.png")
        let photoColor = UIColor(red: 0.62, green: 0.44, blue: 0.30, alpha: 1)
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 150)).image { context in
            photoColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 150))
        }
        try XCTUnwrap(photo.pngData()).write(to: photoURL)

        for style in [UIUserInterfaceStyle.light, .dark] {
            let name = style == .dark ? "dark" : "light"
            let image = try hostedImage(
                CongressMemberFrontMatter(member: pageMember(party: .democratic, imageUrl: photoURL)),
                style: style,
                contrast: .normal,
                size: CGSize(width: 390, height: 260),
                alignment: .top,
                settle: 1.5
            )
            attach(image, name: "member-front-matter-photo-\(name)")
            // Down the page's centre line, the photo fills most of the 72 pt circle (inside its ring).
            let pixels = try rgbaPixels(of: image)
            let photoRun = pixels.count(in: CGRect(x: CGFloat(image.width) / 6, y: 0, width: 0, height: CGFloat(image.height) / 3), scale: 3) {
                abs($0.red - 0.62) < 0.04 && abs($0.green - 0.44) < 0.04 && abs($0.blue - 0.30) < 0.04
            }
            XCTAssertGreaterThan(photoRun, 3 * 60, "\(name): the photo fills the ring (\(photoRun) px)")
            assertColor(try pixel(of: image, x: 4, y: 4), BillboardPalette.document.resolved(dark: style == .dark), "\(name): on the document")
        }
    }

    /// A topic group's and a life area's bills (spec 4.27): the header with the count, a life area's top
    /// topic groups as index tags, the slips and "Load older bills", in light, dark and AX3.
    func testTopicGroupAndLifeAreaDetailsRenderInEveryVariant() throws {
        let userStore = UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService())
        let bills = [
            stubBill("BILLS-119hr1234", number: "1234", title: "Clean Energy Reporting Act"),
            stubBill("BILLS-119s77", number: "77", status: .passed, title: "Rural Broadband Access Act of 2026, a long title that wraps")
        ]
        for variant in Self.variants {
            let topicGroup = CongressBillListContent(
                title: "Economic Policy",
                bills: bills,
                emptyText: "No bills in this topic group",
                canLoadMore: true,
                isLoadingMore: false,
                onLoadMore: {}
            ) { _ in EmptyView() }
            let topicImage = try render(topicGroup.background(BillboardColors.background).environmentObject(userStore), variant: variant)
            attach(topicImage, name: "congress-topic-group-detail-\(variant.name)")
            XCTAssertGreaterThan(topicImage.height, 2 * 120 + 44, variant.name)

            let lifeArea = CongressBillListContent(
                title: "Health",
                bills: bills,
                topCategories: ["Economic Policy", "Health", "Civil Rights and Liberties"],
                emptyText: "No bills in this life area",
                canLoadMore: false,
                isLoadingMore: false,
                onLoadMore: {}
            ) { _ in EmptyView() }
            attach(try render(lifeArea.background(BillboardColors.background).environmentObject(userStore), variant: variant), name: "congress-life-area-detail-\(variant.name)")

            let empty = CongressBillListContent(
                title: "Health",
                bills: [],
                emptyText: "No bills in this life area",
                canLoadMore: false,
                isLoadingMore: false,
                onLoadMore: {}
            ) { _ in EmptyView() }
            attach(try render(empty.background(BillboardColors.background), variant: variant), name: "congress-life-area-detail-empty-\(variant.name)")
        }
        let text = AccessibilityTreeText.text(of: NavigationStack {
            CongressBillListContent(
                title: "Economic Policy",
                bills: bills,
                emptyText: "",
                canLoadMore: true,
                isLoadingMore: false,
                onLoadMore: {}
            ) { _ in EmptyView() }
            .environmentObject(userStore)
        }, size: CGSize(width: 390, height: 2400))
        XCTAssertTrue(text.contains("2 bills"), text)
        XCTAssertTrue(text.contains("Load older bills"), text)
    }

    /// The Members directory's sections (spec 4.57): a counted header over the roll sheet, NOT FOUND for a
    /// search with no matches, and Your representatives without an address, in light, dark and AX3. The
    /// segmented control and the State menu are UIKit, which `ImageRenderer` cannot draw.
    func testDirectorySectionsRenderInEveryVariant() throws {
        let members = try virginia() + mixed()
        for variant in Self.variants {
            let view = VStack(alignment: .leading, spacing: 16) {
                CongressDirectorySection(title: "All members", count: 535, members: members, emptyText: "", isSubscribed: { $0.id == "K000384" }) { _ in EmptyView() }
                CongressDirectorySection(title: "Senate", count: 100, members: [], emptyText: CongressDirectorySection<EmptyView>.noMatchText, isSubscribed: { _ in false }) { _ in EmptyView() }
                CongressDirectorySection(
                    title: YourRepresentativesContent.title,
                    members: [],
                    emptyText: YourRepresentativesContent.needsLocationText,
                    emptyAction: .init(title: "Add address", accessibilityIdentifier: "congress.directory.addAddress") {},
                    isSubscribed: { _ in false }
                ) { _ in EmptyView() }
            }
            let image = try render(tabPage(view), variant: variant)
            attach(image, name: "congress-directory-\(variant.name)")
            XCTAssertGreaterThan(image.height, members.count * 44 + 200, variant.name)
        }
        let host = AccessibilityTreeText.Host(NavigationStack {
            CongressDirectorySection(title: "All members", count: 535, members: members, emptyText: "", isSubscribed: { _ in false }) { _ in EmptyView() }
        })
        defer { host.close() }
        XCTAssertEqual(host.identifier(of: "Senator Tim Kaine, Democrat, Virginia"), "congress.directory.member.0")
        XCTAssertTrue(host.text().contains("All members, 535 members"), host.text())
    }

    // MARK: - Helpers

    private func stubBill(_ guid: String, number: String, status: BillStatus = .new, title: String) -> Bill {
        Bill(
            id: UUID.deterministic(from: guid),
            title: title,
            category: "Economic Policy",
            subCategory: "Energy",
            summary: "Requires a yearly report on how the program spends its money.",
            soWhat: "",
            storedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 60 * 60)),
            billStatus: status,
            guid: guid,
            congress: "119",
            billType: guid.contains("119s") ? "s" : "hr",
            billID: number,
            userVoted: false,
            isPriority: status == .new
        )
    }

    /// The size a view takes when nothing limits it, at a Dynamic Type size, in points.
    private func naturalSize<Content: View>(of view: Content, size: DynamicTypeSize) throws -> CGSize {
        let renderer = ImageRenderer(content: view.fixedSize().environment(\.dynamicTypeSize, size))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        return CGSize(width: image.width, height: image.height)
    }

    /// An image's pixels as sRGB, read once, for scanning regions.
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        func at(_ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double) {
            let i = (y * width + x) * 4
            return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
        }

        /// The pixels in `rect` (in points at `scale`) for which `test` holds.
        func count(in rect: CGRect, scale: CGFloat, where test: ((red: Double, green: Double, blue: Double)) -> Bool) -> Int {
            let minX = max(0, Int((rect.minX * scale).rounded(.up)))
            let maxX = min(width - 1, Int((rect.maxX * scale).rounded(.down)))
            let minY = max(0, Int((rect.minY * scale).rounded(.up)))
            let maxY = min(height - 1, Int((rect.maxY * scale).rounded(.down)))
            guard minX <= maxX, minY <= maxY else { return 0 }
            var found = 0
            for y in minY...maxY {
                for x in minX...maxX where test(at(x, y)) {
                    found += 1
                }
            }
            return found
        }
    }

    private func rgbaPixels(of image: CGImage) throws -> Pixels {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "could not read the image")
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    /// `view` on the document in a window of the test app's scene (centred unless `alignment` says
    /// otherwise), drawn at 3x, after `settle` seconds.
    private func hostedImage<Content: View>(
        _ view: Content,
        style: UIUserInterfaceStyle,
        contrast: UIAccessibilityContrast,
        size: CGSize = CGSize(width: 320, height: 160),
        alignment: Alignment = .center,
        settle: TimeInterval = 0.3
    ) throws -> CGImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(
            rootView: view
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .background(BillboardColors.document)
        )
        host.traitOverrides.accessibilityContrast = contrast
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(image.cgImage)
    }

    /// The ground (the image's corner) and the label (the pixel that contrasts most with it) of a drawn
    /// text link, read at full resolution.
    private func groundAndLabel(of image: CGImage) throws -> (ground: BillboardColorMath.RGB, label: BillboardColorMath.RGB) {
        let width = image.width
        let height = image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "could not read the image")
        func rgb(_ x: Int, _ y: Int) -> BillboardColorMath.RGB {
            let i = (y * width + x) * 4
            return (red: Double(bytes[i]) / 255, green: Double(bytes[i + 1]) / 255, blue: Double(bytes[i + 2]) / 255)
        }
        let ground = rgb(2, 2)
        var label = ground
        var best = 1.0
        for y in stride(from: 0, to: height, by: 1) {
            for x in stride(from: 0, to: width, by: 1) {
                let candidate = rgb(x, y)
                let ratio = BillboardColorMath.contrastRatio(candidate, ground)
                if ratio > best {
                    best = ratio
                    label = candidate
                }
            }
        }
        XCTAssertGreaterThan(best, 1.5, "the link is drawn")
        return (ground, label)
    }

    /// `top` with its alpha laid over the opaque `bottom`.
    private func over(_ top: BillboardColorToken.RGBA, _ bottom: BillboardColorToken.RGBA) -> BillboardColorToken.RGBA {
        let rgb = BillboardColorMath.composite(top.rgb, alpha: top.alpha, over: bottom.rgb)
        return BillboardColorToken.RGBA(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// The largest spread between a pixel's channels anywhere in `image` (0 for greys).
    private func maximumChroma(of image: CGImage) throws -> Double {
        let width = image.width
        let height = image.height
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        _ = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        var maximum = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 0 {
            let channels = [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
            maximum = max(maximum, (channels.max() ?? 0) - (channels.min() ?? 0))
        }
        return Double(maximum) / 255
    }

    /// The width a view takes when nothing limits it, at a Dynamic Type size, in points.
    private func naturalWidth<Content: View>(of view: Content, size: DynamicTypeSize) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view
                .fixedSize()
                .environment(\.dynamicTypeSize, size)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        return CGFloat(image.width)
    }

    private func assertColor(
        _ sample: (red: Double, green: Double, blue: Double),
        _ expected: BillboardColorToken.RGBA,
        _ message: String,
        accuracy: Double = 0.03
    ) {
        XCTAssertEqual(sample.red, expected.red, accuracy: accuracy, message)
        XCTAssertEqual(sample.green, expected.green, accuracy: accuracy, message)
        XCTAssertEqual(sample.blue, expected.blue, accuracy: accuracy, message)
    }

    /// The view on paper in the tab's 16 pt list gutter.
    private func page<Content: View>(_ content: Content) -> some View {
        tabPage(content)
    }

    private func tabPage<Content: View>(_ content: Content) -> some View {
        content
            .padding(.horizontal, CongressTabLayout.gutter)
            .padding(.vertical, 16)
            .background(BillboardColors.background)
    }

    private func render<Content: View>(_ view: Content, variant: Variant, width: CGFloat = 390, scale: CGFloat = 1) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The sRGB colour of one pixel, `x` and `y` from the top left.
    private func pixel(of image: CGImage, x: Int, y: Int) throws -> (red: Double, green: Double, blue: Double) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(
                image,
                in: CGRect(
                    x: -CGFloat(x),
                    y: -CGFloat(image.height - 1 - y),
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                )
            )
            return true
        }
        XCTAssertTrue(drawn, "bitmap context")
        XCTAssertEqual(bytes[3], 255, "sampled an opaque pixel")
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
