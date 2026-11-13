import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// Renders the Profile tab, its sections, the Civic Profile and the Civic Rank sheet (with their loading and
/// error states, UX-39 N11) with fixture data (Civic Record spec 4.60 to 4.71, 10.1), in light and dark, at the default text size and AX3,
/// the header also at AX5 on a 375 pt phone, and attaches each image to the result bundle for review. The
/// settings lists (Settings, App settings, About Billboard, Delete account and data) are system lists, which
/// `ImageRenderer` cannot draw, so they are drawn through UIKit in a window. No network, no credentials, no
/// baselines; pixels are checked where the colour is the point.
///
/// `ImageRenderer` draws SwiftUI views only: switches, menus and text fields are UIKit-backed and show as
/// placeholders.
@MainActor
final class ProfileRenderTests: XCTestCase {
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

        var isDark: Bool { scheme == .dark }
    }

    private static let variants: [Variant] = [
        Variant(scheme: .light, size: .large),
        Variant(scheme: .dark, size: .large),
        Variant(scheme: .light, size: .accessibility3),
        Variant(scheme: .dark, size: .accessibility3)
    ]

    private static let ax5 = Variant(scheme: .light, size: .accessibility5)

    // MARK: - Fixtures

    private func member(_ id: String, _ name: String, chamber: String, state: String, district: Int? = nil, party: String) throws -> CongressMemberManifestItem {
        var fields = [
            #""bioguideId":"\#(id)""#,
            #""name":"\#(name)""#,
            #""chamber":"\#(chamber)""#,
            #""state":"\#(state)""#,
            #""party":"\#(party)""#
        ]
        if let district { fields.append(#""district":\#(district)"#) }
        return try JSONDecoder().decode(CongressMemberManifestItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func followedMembers() throws -> FollowedMembersSummary {
        let manifest = [
            try member("K000384", "Tim Kaine", chamber: "Senate", state: "VA", party: "D"),
            try member("W000805", "Mark R. Warner", chamber: "Senate", state: "VA", party: "D"),
            try member("W000804", "Robert J. Wittman", chamber: "House of Representatives", state: "VA", district: 1, party: "R"),
            try member("S000033", "Bernard Sanders", chamber: "Senate", state: "VT", party: "I"),
            try member("V000081", "Nydia M. Velázquez", chamber: "House of Representatives", state: "NY", district: 7, party: "D")
        ]
        return FollowedMembersSummary.make(subscribedIDs: manifest.map { UUID.deterministic(from: $0.id) }, manifest: manifest)
    }

    private func status(verified: Bool, status: String? = nil, method: String? = nil, limitReason: String? = nil) -> DistrictVerificationStatus {
        DistrictVerificationStatus(
            verified: verified,
            status: status,
            method: method,
            verifiedAt: nil,
            resolved: nil,
            signals: nil,
            repsSignalEligible: nil,
            nextStep: nil,
            limitReason: limitReason
        )
    }

    private static let readyCivicProfile = CivicProfileResponse(
        axes: [
            "individualVsCommunity": 0.65,
            "localVsFederal": 0.55,
            "freeMarketVsRegulated": 0.7,
            "traditionalVsProgressive": 0.6,
            "interventionistVsRestrained": 0.45
        ],
        votesUsed: 47,
        totalVotesWithProfile: 47,
        minVotesRequired: 25,
        isReady: true
    )

    /// 312 Yea or Nay votes on bills with theme scores, of which the server reads the last 100.
    private static let cappedCivicProfile = CivicProfileResponse(
        axes: readyCivicProfile.axes,
        votesUsed: 100,
        totalVotesWithProfile: 312,
        minVotesRequired: 25,
        isReady: true
    )

    private static let lockedCivicProfile = CivicProfileResponse(
        axes: [:],
        votesUsed: 12,
        totalVotesWithProfile: 12,
        minVotesRequired: 25,
        isReady: false
    )

    /// UX-32 (billboard-backend services/src/shared/civicProfileReadiness.ts): 30 votes, but only 2 themes have 8 of
    /// them, so the server asks for 3 more votes (the 3rd theme's shortfall) and says the themes hold the profile.
    private static let themeLockedCivicProfile = CivicProfileResponse(
        axes: [:],
        votesUsed: 30,
        totalVotesWithProfile: 30,
        minVotesRequired: 33,
        isReady: false,
        lockedBy: "themes",
        themesReady: 2,
        minThemesRequired: 3,
        minThemeVotes: 8
    )

    private func score(rank: String, title: String, next: (id: String, title: String)?, recentVoteDays: [VoteDay]? = nil) -> CivicScore {
        CivicScore(
            civicScore: 340,
            totalVotes: 52,
            currentStreak: 4,
            longestStreak: 9,
            lastVotedAt: nil,
            recentVoteDays: recentVoteDays,
            voteScore: 260,
            streakBonus: 30,
            honorBonus: 50,
            coverageAreaCount: 4,
            rank: CivicRank(id: rank, title: title, minScore: 250, approxVotesRequired: 40),
            nextRank: next.map { CivicRank(id: $0.id, title: $0.title, minScore: 500, approxVotesRequired: 80) },
            scoreToNextRank: 160,
            honors: [
                CivicHonor(id: "steady-hand", title: "Steady Hand", description: "", bonusScore: 50, category: "consistency"),
                CivicHonor(id: "broad-view", title: "Broad View", description: "", bonusScore: 50, category: "breadth")
            ]
        )
    }

    private static func thirtyDays(voted: (Int) -> Bool) -> [VoteDay] {
        (1...30).map { VoteDay(date: String(format: "2026-09-%02d", $0), count: voted($0) ? 2 : 0) }
    }

    private func notifications(permission: UNAuthorizationStatus?, settings: DeviceNotificationSettings? = nil, error: String? = nil) -> NotificationsSectionContent {
        NotificationsSectionContent(
            model: NotificationsSectionModel(permission: permission, settings: settings ?? .allEnabled),
            isWeeklyBriefOn: true,
            errorMessage: error,
            onSetMaster: { _ in },
            onSetKind: { _, _ in },
            onSetWeeklyBrief: { _ in },
            onRequestPermission: {},
            onOpenSettings: {}
        )
    }

    // MARK: - Whole page (spec 4.60, frame 15)

    func testProfilePageRendersInEveryVariant() throws {
        let members = try followedMembers()
        for variant in Self.variants {
            let page = VStack(alignment: .leading, spacing: ProfileLayout.sectionGap) {
                // The page title on paper under the compact masthead (Civic Record spec 3.21).
                PageTitle(title: "Profile")
                ProfileHeader(displayName: "Alex Morgan", email: "alex@example.com")
                WhereYouVoteContent(
                    summary: WhereYouVoteSummary.make(state: "VA", district: "11", status: status(verified: true, method: "address_geocode"), isLoading: false),
                    onChange: {}
                )
                FollowedTopicsContent(
                    summary: FollowedTopicsSummary(topics: ["Civil Rights and Liberties", "Healthcare", "Taxation", "Housing", "Energy"], lifeAreas: ["Housing", "Taxes"]),
                    onEdit: {}
                )
                FollowedMembersContent(summary: members, onManage: {})
                notifications(permission: .authorized)
                CivicProfileCard(profile: Self.readyCivicProfile, isLoading: false)
            }
            let image = try render(screen(page), variant: variant)
            attach(image, name: "profile-page-\(variant.name)")
            XCTAssertGreaterThan(image.height, 1200, variant.name)
            // Teal is only Yea: none in the brand's hue anywhere on Profile, and no green (VERIFIED is ink).
            XCTAssertFalse(try contains(image, BillboardPalette.brandTeal.resolved(dark: variant.isDark), tolerance: 0.03), "brand teal \(variant.name)")
            XCTAssertFalse(try contains(image, BillboardPalette.statusPassed.resolved(dark: variant.isDark), tolerance: 0.03), "green \(variant.name)")
        }
    }

    /// The header (spec 4.60): the monogram with the user's initials, the name, the email and the ink gear,
    /// which VoiceOver reads as "Settings". At AX5 on a 375 pt phone the name and email take the width under the
    /// monogram and the gear.
    func testHeaderReadsItsNameAndStacksAtAccessibilitySizes() throws {
        let header = ProfileHeader(displayName: "Alexandria Montgomery-Whitfield", email: "alexandria.montgomery@example.com")
        let defaultImage = try render(screen(header), variant: Self.variants[0])
        let stacked = try render(screen(header), variant: Self.ax5, width: 375)
        attach(defaultImage, name: "profile-header-light-default")
        attach(stacked, name: "profile-header-light-AX5")
        XCTAssertGreaterThan(stacked.height, defaultImage.height * 2, "the header grows and stacks at AX5")

        let host = AccessibilityTreeText.Host(NavigationStack { header }, size: CGSize(width: 390, height: 300))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Settings"), text)
        XCTAssertTrue(text.contains("Alexandria Montgomery-Whitfield"), text)
        XCTAssertEqual(host.identifier(of: "Settings"), "profile.settings")
    }

    /// Settings' header (spec 4.68, 2.5): beside the monogram at the default size; at accessibility sizes the
    /// monogram sits above and the name and email take the width under it, as on Profile, so a one-word name
    /// such as "alex.morgan" does not break in the middle. VoiceOver reads the name and the email as written.
    func testSettingsHeaderStacksAtAccessibilitySizes() throws {
        let header = SettingsHeader(displayName: "alex.morgan", email: "alex.morgan@example.com")
        let paper = BillboardPalette.background.light
        for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
            let variant = Variant(scheme: .light, size: size)
            let image = try render(screen(header), variant: variant, width: 375)
            attach(image, name: "settings-header-\(variant.name)")
            // The monogram's band is the gutter (16 pt) to its own scaled width; the words' band is past it.
            let diameter = UIFontMetrics(forTextStyle: .title3).scaledValue(
                for: MemberMonogram.Size.settings.diameter,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
            )
            let monogramTop = try XCTUnwrap(firstMarkedRow(image, columns: 16..<Int(16 + diameter), paper: paper), variant.name)
            let wordsTop = try XCTUnwrap(firstMarkedRow(image, columns: Int(16 + diameter + 8)..<(image.width - 16), paper: paper), variant.name)
            if size.isAccessibilitySize {
                XCTAssertGreaterThanOrEqual(wordsTop - monogramTop, Int(diameter) - 1, "\(variant.name): the words start under the monogram")
            } else {
                XCTAssertLessThan(wordsTop - monogramTop, Int(diameter) / 2, "\(variant.name): the words sit beside the monogram")
            }
        }

        let host = AccessibilityTreeText.Host(header.accessibilityElement(children: .combine).padding(16), size: CGSize(width: 390, height: 300))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("alex.morgan"), text)
        XCTAssertTrue(text.contains("alex.morgan@example.com"), text)
        XCTAssertFalse(text.contains("\u{200B}"), "VoiceOver reads the email as written: \(text)")
    }

    /// An email address has no place to break a line; a zero-width space before the "@" and before each dot of
    /// the domain lets a long one wrap there rather than between any two letters.
    func testEmailWrapsAtTheAtSignAndTheDomainsDots() {
        let zwsp = "\u{200B}"
        XCTAssertEqual(EmailText.wrappable("alex.morgan@example.com"), "alex.morgan\(zwsp)@example\(zwsp).com")
        XCTAssertEqual(EmailText.wrappable("a@mail.example.co.uk"), "a\(zwsp)@mail\(zwsp).example\(zwsp).co\(zwsp).uk")
        XCTAssertEqual(EmailText.wrappable("no-at-sign"), "no-at-sign")
        XCTAssertEqual(EmailText.wrappable(""), "")
        XCTAssertEqual(EmailText.wrappable("alex.morgan@example.com").replacingOccurrences(of: zwsp, with: ""), "alex.morgan@example.com")
    }

    // MARK: - Where you vote (spec 4.61)

    func testWhereYouVoteStatesRender() throws {
        let states: [(String, WhereYouVoteSummary)] = [
            ("verified", .make(state: "VA", district: "11", status: status(verified: true), isLoading: false)),
            ("chosen", .make(state: "VA", district: "11", status: status(verified: false, status: "self_attested", method: "manual_state_district"), isLoading: false)),
            ("capped", .make(state: "VA", district: "11", status: status(verified: false, method: "address_capped", limitReason: "address_limit"), isLoading: false)),
            ("checking", .make(state: "VA", district: "11", status: nil, isLoading: true)),
            ("no-location", .make(state: "", district: "", status: nil, isLoading: false))
        ]
        for (name, summary) in states {
            for variant in Self.variants {
                let image = try render(screen(WhereYouVoteContent(summary: summary, onChange: {})), variant: variant)
                attach(image, name: "profile-location-\(name)-\(variant.name)")
                XCTAssertGreaterThanOrEqual(image.height, 44 + 32, "\(name) \(variant.name)")
                XCTAssertFalse(try contains(image, BillboardPalette.statusPassed.resolved(dark: variant.isDark), tolerance: 0.03), "\(name) \(variant.name): VERIFIED is ink, not green")
            }
        }
    }

    /// Sections sit on paper under their heads: no card behind them (spec 4.61).
    func testSectionsSitOnPaperWithoutACard() throws {
        let summary = WhereYouVoteSummary.make(state: "VA", district: "11", status: status(verified: true), isLoading: false)
        let topics = FollowedTopicsSummary(topics: ["Healthcare"], lifeAreas: ["Housing"])
        for variant in [Self.variants[0], Self.variants[1]] {
            let sheet = BillboardPalette.cardBackground.resolved(dark: variant.isDark)
            for (name, view) in [
                ("where", AnyView(WhereYouVoteContent(summary: summary, onChange: {}))),
                ("topics", AnyView(FollowedTopicsContent(summary: topics, onEdit: {})))
            ] {
                let image = try render(screen(view), variant: variant)
                // A card would be thousands of sheet pixels; the edges of glyphs give a stray few at most.
                let count = try pixelCount(image, sheet, tolerance: 0.004)
                XCTAssertLessThan(count, 40, "\(name) \(variant.name): \(count) sheet-coloured pixels, a card")
            }
        }
    }

    func testWhereYouVoteReadsTheDistrictInWords() {
        let verified = WhereYouVoteSummary.make(state: "VA", district: "11", status: status(verified: true), isLoading: false)
        XCTAssertEqual(verified.stamp, .verified)
        XCTAssertEqual(verified.accessibilityText, "Virginia's 11th district, Verified")

        let chosen = WhereYouVoteSummary.make(state: "VA", district: "11", status: status(verified: false, status: "self_attested", method: "manual_state_district"), isLoading: false)
        XCTAssertEqual(chosen.stamp, .notVerified)
        XCTAssertEqual(chosen.accessibilityText, "Virginia's 11th district, Not verified, District chosen by you")

        let atLarge = WhereYouVoteSummary.make(state: "WY", district: "At-Large", status: status(verified: true), isLoading: false)
        XCTAssertEqual(atLarge.accessibilityText, "Wyoming's at-large district, Verified")

        let checking = WhereYouVoteSummary.make(state: "VA", district: "11", status: nil, isLoading: true)
        XCTAssertNil(checking.stamp)
        XCTAssertEqual(checking.accessibilityText, "Virginia's 11th district, Checking…")

        XCTAssertEqual(WhereYouVoteSummary.make(state: "", district: "", status: nil, isLoading: false).accessibilityText, WhereYouVoteSummary.missingLocationText)
    }

    // MARK: - Topics and members (spec 4.61)

    func testTopicsRenderEmptyAndMany() throws {
        let many = FollowedTopicsSummary(
            topics: SubscriptionsConfig.subcategoriesSocial + SubscriptionsConfig.subcategoriesCultural,
            lifeAreas: Array(SubscriptionsConfig.allLifeAreas.prefix(4))
        )
        XCTAssertGreaterThan(many.hiddenCount, 0, "the fixture exercises the cap")
        for variant in Self.variants {
            let empty = try render(screen(FollowedTopicsContent(summary: FollowedTopicsSummary(topics: [], lifeAreas: []), onEdit: {})), variant: variant)
            attach(empty, name: "profile-topics-empty-\(variant.name)")

            let image = try render(screen(FollowedTopicsContent(summary: many, onEdit: {})), variant: variant)
            attach(image, name: "profile-topics-many-\(variant.name)")
            XCTAssertGreaterThan(image.height, empty.height, variant.name)
        }
    }

    /// The topic "Housing" and the life area "Housing" sit in different labelled rows and are read with
    /// their kind (spec 4.61); the UI tests find a followed topic by name in the section's label.
    func testTopicsAndLifeAreasAreToldApart() throws {
        let summary = FollowedTopicsSummary(topics: ["Healthcare", "Housing"], lifeAreas: ["Housing"])
        XCTAssertEqual(
            summary.accessibilityText,
            "You follow 2 topics and 1 life area. Topics: Healthcare, Housing. Life areas: Housing."
        )
        XCTAssertEqual(summary.visibleTopics, ["Healthcare", "Housing"])
        XCTAssertEqual(summary.visibleLifeAreas, ["Housing"])

        let host = AccessibilityTreeText.Host(FollowedTopicsContent(summary: summary, onEdit: {}).padding(16), size: CGSize(width: 390, height: 400))
        defer { host.close() }
        XCTAssertEqual(host.identifier(of: summary.accessibilityText), "profile.topics")
        XCTAssertEqual(host.identifier(of: "Edit topics you follow"), "profile.topics.edit")

        for variant in [Self.variants[0], Self.ax5] {
            attach(try render(screen(FollowedTopicsContent(summary: summary, onEdit: {})), variant: variant, width: 375), name: "profile-topics-housing-\(variant.name)")
        }
    }

    func testMoreTextSaysWhatTheCapHid() {
        XCTAssertNil(FollowedTopicsSummary.moreText(shown: 3, total: 3, singular: "topic", plural: "topics"))
        XCTAssertEqual(FollowedTopicsSummary.moreText(shown: 12, total: 15, singular: "topic", plural: "topics"), "and 3 more")
        XCTAssertEqual(FollowedTopicsSummary.moreText(shown: 0, total: 4, singular: "life area", plural: "life areas"), "4 life areas")
        XCTAssertEqual(FollowedTopicsSummary.moreText(shown: 0, total: 1, singular: "life area", plural: "life areas"), "1 life area")
    }

    func testMembersRenderWithAndWithoutMembers() throws {
        let members = try followedMembers()
        for variant in Self.variants {
            let image = try render(screen(FollowedMembersContent(summary: members, onManage: {})), variant: variant)
            attach(image, name: "profile-members-\(variant.name)")
            XCTAssertGreaterThanOrEqual(image.height, 3 * 44 + 44, variant.name)

            let none = FollowedMembersSummary.make(subscribedIDs: [], manifest: [])
            attach(try render(screen(FollowedMembersContent(summary: none, onManage: {})), variant: variant), name: "profile-members-none-\(variant.name)")
        }

        // Roll-sheet rows read the member in words, the party first; the count is in the head.
        let host = AccessibilityTreeText.Host(FollowedMembersContent(summary: members, onManage: {}).padding(16), size: CGSize(width: 390, height: 600))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Members you follow, 5 members"), text)
        XCTAssertTrue(text.contains("Representative Nydia M. Velázquez, Democrat"), text)
        XCTAssertTrue(text.contains("Senator Bernard Sanders, Independent"), text)
        XCTAssertTrue(text.contains("and 2 more"), text)
        XCTAssertEqual(host.identifier(of: "Manage in Congress"), "profile.members.manage")
    }

    // MARK: - Notifications (spec 4.62)

    func testNotificationsRenderForEachPermissionState() throws {
        var masterOff = DeviceNotificationSettings.allEnabled
        masterOff.notificationsEnabled = false
        let states: [(String, NotificationsSectionContent)] = [
            ("allowed", notifications(permission: .authorized)),
            ("denied", notifications(permission: .denied)),
            ("not-asked", notifications(permission: .notDetermined)),
            ("master-off-error", notifications(permission: .authorized, settings: masterOff, error: NotificationSettingsStore.saveFailedMessage))
        ]
        for (name, view) in states {
            for variant in Self.variants {
                let image = try render(screen(view), variant: variant)
                attach(image, name: "profile-notifications-\(name)-\(variant.name)")
                XCTAssertGreaterThanOrEqual(image.height, 7 * 44, "\(name) \(variant.name)")
            }
        }
    }

    // MARK: - Civic Profile (spec 3.27, 4.64)

    func testCivicProfileRenders() throws {
        for variant in Self.variants {
            let view = VStack(spacing: ProfileLayout.sectionGap) {
                CivicProfileCard(profile: Self.readyCivicProfile, isLoading: false)
                CivicProfileCard(profile: Self.lockedCivicProfile, isLoading: false)
            }
            let image = try render(screen(view), variant: variant)
            attach(image, name: "profile-civic-\(variant.name)")
            XCTAssertGreaterThan(image.height, 500, variant.name)
            XCTAssertFalse(try contains(image, BillboardPalette.brandTeal.resolved(dark: variant.isDark), tolerance: 0.03), "brand teal \(variant.name)")
        }
    }

    /// "Based on your last 100 votes" when the server counted only the last 100 of the user's votes (project decision
    /// of 2026-10-29), as VoiceOver reads it too; "Based on 47 votes" while every vote counts.
    func testACappedCivicProfileSaysItIsBasedOnTheLast100Votes() throws {
        for variant in Self.variants {
            let image = try render(screen(CivicProfileCard(profile: Self.cappedCivicProfile, isLoading: false)), variant: variant)
            attach(image, name: "profile-civic-capped-\(variant.name)")
        }
        let capped = AccessibilityTreeText.Host(CivicProfileCard(profile: Self.cappedCivicProfile, isLoading: false).padding(16), size: CGSize(width: 390, height: 700))
        let cappedText = capped.text()
        capped.close()
        XCTAssertTrue(cappedText.contains("Based on your last 100 votes"), cappedText)
        XCTAssertFalse(cappedText.contains("Based on 100 votes"), cappedText)

        let uncapped = AccessibilityTreeText.Host(CivicProfileCard(profile: Self.readyCivicProfile, isLoading: false).padding(16), size: CGSize(width: 390, height: 700))
        let uncappedText = uncapped.text()
        uncapped.close()
        XCTAssertTrue(uncappedText.contains("Based on 47 votes"), uncappedText)
        XCTAssertFalse(uncappedText.contains("your last"), uncappedText)
    }

    /// Before the first read of the Civic Profile ends (UX-39 N11): a loading line, as the member page's card
    /// has, never the locked state's "Vote on 25 more bills" and "0 of 25 votes" from `CivicProfileResponse.empty`.
    func testCivicProfileLoadingIsNotTheLockedState() throws {
        let card = CivicProfileCard(profile: .empty, isLoading: true, phase: .loading)
        for variant in Self.variants + [Self.ax5] {
            let image = try render(screen(card), variant: variant, width: variant.size == .accessibility5 ? 375 : 390)
            attach(image, name: "profile-civic-loading-\(variant.name)")
        }

        let host = AccessibilityTreeText.Host(card.padding(16), size: CGSize(width: 390, height: 400))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(CivicProfileCopy.loading), text)
        XCTAssertEqual(host.identifier(of: CivicProfileCopy.loading), "profile.civicProfile.loading")
        XCTAssertFalse(text.contains("Vote on"), text)
        XCTAssertFalse(text.contains("of 25 votes"), text)
        XCTAssertTrue(text.contains("About the civic profile chart"), "the info button stays: \(text)")
        XCTAssertEqual(host.strings().filter { $0 == "Loading" }, [], "one spinner, the loading line's")
    }

    /// When the first read failed (UX-39 N11): COULDN'T LOAD with R2's message and Try again, which reads the
    /// profile again; never the locked state.
    func testCivicProfileFailureSaysSoWithTryAgain() throws {
        let message = "Can't reach Billboard right now. Check your connection and try again."
        var retries = 0
        let card = CivicProfileCard(profile: .empty, isLoading: false, phase: .failed(message)) { retries += 1 }
        for variant in Self.variants + [Self.ax5] {
            let image = try render(screen(card), variant: variant, width: variant.size == .accessibility5 ? 375 : 390)
            attach(image, name: "profile-civic-failed-\(variant.name)")
            XCTAssertTrue(try contains(image, BillboardPalette.danger.resolved(dark: variant.isDark), tolerance: 0.03), "the COULDN'T LOAD stamp \(variant.name)")
        }

        let host = AccessibilityTreeText.Host(card.padding(16), size: CGSize(width: 390, height: 500))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Couldn't load. \(CivicProfileCopy.failedTitle). \(message)"), text)
        XCTAssertEqual(host.identifier(of: "Try again"), "profile.civicProfile.retry")
        XCTAssertFalse(text.contains("Vote on"), text)
        XCTAssertFalse(text.contains("of 25 votes"), text)
        XCTAssertTrue(host.activate("Try again"))
        XCTAssertEqual(retries, 1)
    }

    /// A refresh over a loaded profile keeps it on screen with the head's spinner, failed or not.
    func testALoadedProfileStaysThroughARefresh() throws {
        let host = AccessibilityTreeText.Host(
            CivicProfileCard(profile: Self.lockedCivicProfile, isLoading: true, phase: .loaded).padding(16),
            size: CGSize(width: 390, height: 400)
        )
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(CivicProfileCopy.unlockPrompt(votesRemaining: 13)), text)
        XCTAssertFalse(text.contains(CivicProfileCopy.loading), text)
        XCTAssertEqual(host.strings().filter { $0 == "Loading" }.count, 1, host.strings().joined(separator: " | "))
    }

    /// The locked Civic Profile (spec 3.27): the sentence, the progress bar in `controlOn` and the figures.
    func testLockedCivicProfileShowsItsProgress() throws {
        XCTAssertEqual(CivicProfileCopy.progress(votesUsed: 12, votesRequired: 25), "12 of 25 votes")
        XCTAssertEqual(CivicProfileCopy.progress(votesUsed: 0, votesRequired: 1), "0 of 1 vote")
        for variant in [Self.variants[0], Self.variants[1]] {
            let image = try render(screen(CivicProfileCard(profile: Self.lockedCivicProfile, isLoading: false)), variant: variant)
            XCTAssertTrue(try contains(image, BillboardPalette.controlOn.resolved(dark: variant.isDark), tolerance: 0.02), "progress \(variant.name)")
        }
        let host = AccessibilityTreeText.Host(CivicProfileCard(profile: Self.lockedCivicProfile, isLoading: false).padding(16), size: CGSize(width: 390, height: 400))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(CivicProfileCopy.unlockPrompt(votesRemaining: 13)), text)
        XCTAssertTrue(text.contains("12 of 25 votes"), text)
        XCTAssertTrue(text.contains("About the civic profile chart"), text)
    }

    /// UX-32 (approved 2026-10-29): while GET /civic-profile says the themes hold the profile, the locked card adds
    /// one caption line under the vote prompt with the server's numbers. VoiceOver reads the prompt and the line as
    /// one element, then the figures: "Vote on 3 more bills to unlock your Civic Profile. It opens once 3 themes
    /// each have 8 of your votes. 2 of 3 so far." | "30 of 33 votes". Rendered light and dark at the default size,
    /// AX3 and AX5 (375 pt).
    func testALockedProfileHeldByItsThemesSaysWhatTheyNeed() throws {
        let card = CivicProfileCard(profile: Self.themeLockedCivicProfile, isLoading: false)
        for variant in Self.variants + [Self.ax5, Variant(scheme: .dark, size: .accessibility5)] {
            let image = try render(screen(card), variant: variant, width: variant.size == .accessibility5 ? 375 : 390)
            attach(image, name: "profile-civic-locked-themes-\(variant.name)")
            XCTAssertTrue(try contains(image, BillboardPalette.controlOn.resolved(dark: variant.isDark), tolerance: 0.02), "progress \(variant.name)")
        }

        let line = "It opens once 3 themes each have 8 of your votes. 2 of 3 so far."
        let host = AccessibilityTreeText.Host(card.padding(16), size: CGSize(width: 390, height: 500))
        defer { host.close() }
        // The progress bar is hidden from VoiceOver; the walk still lists its view, with no label.
        let labels = host.elements().map(\.label).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let prompt = "Vote on 3 more bills to unlock your Civic Profile. \(line)"
        let index = try XCTUnwrap(labels.firstIndex(of: prompt), labels.joined(separator: " | "))
        XCTAssertEqual(labels[index + 1], "30 of 33 votes", labels.joined(separator: " | "))
        XCTAssertEqual(labels.filter { $0.contains("It opens once") }.count, 1, "read once, with the prompt: \(labels)")

        // The vote lock, a server that sends no fields (an older backend), and a value the app does not know: the card
        // as before, its prompt read alone.
        let others: [(String, CivicProfileResponse)] = [
            ("votes", CivicProfileResponse(axes: [:], votesUsed: 12, totalVotesWithProfile: 12, minVotesRequired: 25, isReady: false, lockedBy: "votes", themesReady: 1, minThemesRequired: 3, minThemeVotes: 8)),
            ("no theme fields", Self.lockedCivicProfile),
            ("unknown", CivicProfileResponse(axes: [:], votesUsed: 12, totalVotesWithProfile: 12, minVotesRequired: 25, isReady: false, lockedBy: "districts", themesReady: 1, minThemesRequired: 3, minThemeVotes: 8))
        ]
        for (name, profile) in others {
            let other = AccessibilityTreeText.Host(CivicProfileCard(profile: profile, isLoading: false).padding(16), size: CGSize(width: 390, height: 500))
            let otherLabels = other.elements().map(\.label)
            other.close()
            XCTAssertFalse(otherLabels.contains { $0.contains("It opens once") }, "\(name): \(otherLabels)")
            XCTAssertTrue(otherLabels.contains(CivicProfileCopy.unlockPrompt(votesRemaining: 13)), "\(name): \(otherLabels)")
        }
        let todays = try render(screen(CivicProfileCard(profile: Self.lockedCivicProfile, isLoading: false)), variant: Self.variants[0])
        let held = try render(screen(card), variant: Self.variants[0])
        XCTAssertGreaterThan(held.height, todays.height, "one line more")
    }

    func testChartExplanationRenders() throws {
        for variant in Self.variants {
            let image = try render(screen(CivicProfileInfoOverlay(onClose: {})), variant: variant)
            attach(image, name: "profile-civic-info-\(variant.name)")
        }
    }

    // MARK: - Civic Rank (spec 4.65)

    /// Every rank renders its name in ink: no tier colour fill (green, gold, navy or teal) in either
    /// appearance (spec 4.77: "every rank renders its name; no tier colour").
    func testEveryCivicRankRendersItsNameWithNoTierColour() throws {
        let ranks: [(id: String, title: String, next: (id: String, title: String)?)] = [
            ("citizen", "Citizen", ("voice", "Voice")),
            ("voice", "Voice", ("delegate", "Delegate")),
            ("delegate", "Delegate", ("steward", "Steward")),
            ("steward", "Steward", ("advocate", "Advocate")),
            ("advocate", "Advocate", ("champion", "Champion")),
            ("champion", "Champion", nil)
        ]
        // Navy is checked closely: ink, a shade away from it, is the sheet's text colour.
        let tierTokens: [(String, BillboardColorToken, Double)] = [
            ("statusPassed", BillboardPalette.statusPassed, 0.03),
            ("statusUpdated", BillboardPalette.statusUpdated, 0.03),
            ("navy", BillboardPalette.navy, 0.012),
            ("brandTeal", BillboardPalette.brandTeal, 0.03)
        ]
        for rank in ranks {
            let card = CivicScoreCard(score: score(rank: rank.id, title: rank.title, next: rank.next), isLoading: false)
            for variant in [Self.variants[0], Self.variants[1]] {
                let image = try render(screen(card), variant: variant)
                attach(image, name: "profile-rank-\(rank.id)-\(variant.name)")
                for (name, token, tolerance) in tierTokens {
                    XCTAssertFalse(try contains(image, token.resolved(dark: variant.isDark), tolerance: tolerance), "\(rank.id) \(variant.name): \(name)")
                }
            }
            let host = AccessibilityTreeText.Host(card.padding(16), size: CGSize(width: 390, height: 1100))
            let text = host.text()
            host.close()
            XCTAssertTrue(text.contains("Current rank: \(rank.title)"), text)
            if let next = rank.next {
                XCTAssertTrue(text.contains("90 of 250 points to \(next.title)"), text)
            } else {
                XCTAssertTrue(text.contains(CivicRankSummary.topRankText), text)
            }
            XCTAssertTrue(text.contains("Civic Score: 340"), text)
            XCTAssertTrue(text.contains("Steady Hand"), text)
        }
    }

    /// VoiceOver says "Current rank" once, with the rank's name ("Current rank: Steward"); the docket label
    /// above the name is for the eye only.
    func testCurrentRankIsReadOnceWithTheRankName() throws {
        let card = CivicScoreCard(score: score(rank: "steward", title: "Steward", next: ("advocate", "Advocate")), isLoading: false)
        let host = AccessibilityTreeText.Host(card.padding(16), size: CGSize(width: 390, height: 1100))
        defer { host.close() }
        let strings = host.strings()
        let mentions = strings.filter { $0.localizedCaseInsensitiveContains("current rank") }
        XCTAssertEqual(mentions, ["Current rank: Steward"], strings.joined(separator: " | "))
        XCTAssertEqual(host.identifier(of: "Current rank: Steward"), "civicRank.rank")
    }

    /// The whole sheet once at the default size and at AX3 and AX5.
    func testCivicRankSheetRenders() throws {
        let days = Self.thirtyDays { $0 % 3 != 0 }
        let sheet = CivicRankSheetContent(score: score(rank: "steward", title: "Steward", next: ("advocate", "Advocate"), recentVoteDays: days), isLoading: false)
        for variant in Self.variants + [Self.ax5] {
            let image = try render(screen(sheet), variant: variant, width: variant.size == .accessibility5 ? 375 : 390)
            attach(image, name: "profile-rank-sheet-\(variant.name)")
            XCTAssertFalse(try contains(image, BillboardPalette.statusPassed.resolved(dark: variant.isDark), tolerance: 0.03), variant.name)
        }
    }

    /// UX-31 (project decision of 2026-10-29): the Civic Score never goes down, so the breakdown's streak row, 5 points
    /// a day of the best streak, says "Best streak", as the figures row above it does, and How it works opens with
    /// the approved sentence. VoiceOver reads each ledger row as one element: "Best streak: 9" in the figures,
    /// then "Best streak: +30" under Score breakdown. Rendered light and dark at the default size, AX3 and AX5.
    func testTheRankSheetCountsTheBestStreakAndSaysTheScoreNeverGoesDown() throws {
        XCTAssertEqual(
            CivicRankSheetContent.howItWorks.first,
            "Your Civic Score grows through voting, your best streak, and one-time Honors earned along the way. It never goes down."
        )
        let sheet = CivicRankSheetContent(score: score(rank: "steward", title: "Steward", next: ("advocate", "Advocate")), isLoading: false)
        for variant in Self.variants + [Self.ax5, Variant(scheme: .dark, size: .accessibility5)] {
            let image = try render(screen(sheet), variant: variant, width: variant.size == .accessibility5 ? 375 : 390)
            attach(image, name: "profile-rank-sheet-best-streak-\(variant.name)")
        }

        let host = AccessibilityTreeText.Host(sheet.padding(16), size: CGSize(width: 390, height: 1600))
        defer { host.close() }
        let labels = host.elements().map(\.label)
        let streakRows = labels.filter { label in ["Day streak", "Best streak", "Current streak"].contains { label.hasPrefix("\($0):") } }
        XCTAssertEqual(streakRows, ["Day streak: 4", "Best streak: 9", "Best streak: +30"], labels.joined(separator: " | "))
        let breakdown = try XCTUnwrap(labels.firstIndex(of: "Score breakdown"), labels.joined(separator: " | "))
        XCTAssertEqual(Array(labels[(breakdown + 1)...].prefix(3)), ["Votes: +260", "Best streak: +30", "Honors: +50"])
        XCTAssertFalse(host.text().localizedCaseInsensitiveContains("current streak"), host.text())
        XCTAssertTrue(host.text().contains("It never goes down."), host.text())
    }

    /// Before the score has loaded (UX-39 N11: a new device, offline at launch): a loading line in place of the
    /// rank, the figures and the days, never `CivicScore.empty`'s "Citizen" with a full bar and "Top rank
    /// reached". How it works stays.
    func testCivicRankSheetShowsNoRankBeforeTheScoreLoads() throws {
        let sheet = CivicRankSheetContent(score: .empty, isLoading: true, phase: .loading)
        for variant in Self.variants + [Self.ax5] {
            let image = try render(screen(sheet), variant: variant, width: variant.size == .accessibility5 ? 375 : 390)
            attach(image, name: "profile-rank-sheet-loading-\(variant.name)")
        }

        let host = AccessibilityTreeText.Host(sheet.padding(16), size: CGSize(width: 390, height: 900))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(CivicRankSheetContent.loadingText), text)
        XCTAssertEqual(host.identifier(of: CivicRankSheetContent.loadingText), "civicRank.loading")
        for falseState in ["Citizen", CivicRankSummary.topRankText, "points to", "Current rank", "Civic Score: 0", "Day streak"] {
            XCTAssertFalse(text.contains(falseState), "\(falseState): \(text)")
        }
        XCTAssertTrue(text.contains("How it works"), text)
    }

    /// When the first read failed and nothing is cached (UX-39 N11): COULDN'T LOAD with R2's message and Try
    /// again, which reads the score again.
    func testCivicRankSheetFailureSaysSoWithTryAgain() throws {
        let message = "We couldn't load your Civic Rank right now. Try again in a moment."
        var retries = 0
        let sheet = CivicRankSheetContent(score: .empty, isLoading: false, phase: .failed(message)) { retries += 1 }
        for variant in Self.variants {
            let image = try render(screen(sheet), variant: variant)
            attach(image, name: "profile-rank-sheet-failed-\(variant.name)")
            XCTAssertTrue(try contains(image, BillboardPalette.danger.resolved(dark: variant.isDark), tolerance: 0.03), "the COULDN'T LOAD stamp \(variant.name)")
        }

        let host = AccessibilityTreeText.Host(sheet.padding(16), size: CGSize(width: 390, height: 900))
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains("Couldn't load. \(CivicRankSheetContent.failedTitle). \(message)"), text)
        XCTAssertFalse(text.contains("Citizen"), text)
        XCTAssertFalse(text.contains(CivicRankSummary.topRankText), text)
        XCTAssertEqual(host.identifier(of: "Try again"), "civicRank.retry")
        XCTAssertTrue(host.activate("Try again"))
        XCTAssertEqual(retries, 1)
    }

    /// The sheet watches the store: opened before the score has loaded, it reads the score and shows the rank
    /// when the read ends (UX-39 N11).
    func testCivicRankSheetReadsTheScoreWhenOpenedBeforeItLoaded() throws {
        let suiteName = "ProfileRenderTests.rank.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let service = FakeCivicService()
        service.scoreResult = .success(score(rank: "steward", title: "Steward", next: ("advocate", "Advocate")))
        let store = CivicScoreStore(scope: "rank-sheet", userDefaults: defaults, service: service)
        XCTAssertEqual(store.phase, .loading)

        let host = AccessibilityTreeText.Host(CivicScoreInfoOverlay(store: store), size: CGSize(width: 390, height: 1400), settle: 0.4)
        defer { host.close() }
        XCTAssertEqual(store.phase, .loaded)
        let text = host.text()
        XCTAssertTrue(text.contains("Current rank: Steward"), text)
        XCTAssertFalse(text.contains(CivicRankSheetContent.loadingText), text)
    }

    /// The last 30 days as tally marks (spec 4.65): ink for days with a vote, `rule2` for days without, read
    /// as one sentence that says whether today counts.
    func testLastThirtyDaysAreTallyMarksReadAsOneSentence() throws {
        let days = Self.thirtyDays { $0 % 2 == 0 }
        XCTAssertEqual(VotingStreakView.groups(days).map(\.count), [5, 5, 5, 5, 5, 5])
        XCTAssertEqual(VotingStreakView.accessibilitySummary(days, today: "2026-09-30"), "Voted on 15 of the last 30 days, including today")
        XCTAssertEqual(VotingStreakView.accessibilitySummary(days, today: "2026-09-29"), "Voted on 15 of the last 30 days")

        for variant in [Self.variants[0], Self.variants[1]] {
            let image = try render(screen(VotingStreakView(recentVoteDays: days, today: "2026-09-30")), variant: variant)
            attach(image, name: "profile-rank-days-\(variant.name)")
            XCTAssertTrue(try contains(image, BillboardPalette.primaryText.resolved(dark: variant.isDark), tolerance: 0.02), "voted days in ink \(variant.name)")
            let rule2OnPaper = composite(BillboardPalette.rule2.resolved(dark: variant.isDark), over: BillboardPalette.background.resolved(dark: variant.isDark))
            XCTAssertTrue(try contains(image, rule2OnPaper, tolerance: 0.02), "missed days in rule2 \(variant.name)")
        }

        let host = AccessibilityTreeText.Host(VotingStreakView(recentVoteDays: days, today: "2026-09-30").padding(16), size: CGSize(width: 390, height: 300))
        defer { host.close() }
        XCTAssertEqual(host.identifier(of: "Voted on 15 of the last 30 days, including today"), "civicRank.lastThirtyDays")
    }

    // MARK: - Settings lists (spec 3.25, 4.68 to 4.71)

    /// Settings, App settings, About Billboard and Delete account and data: system lists on paper with their
    /// rows on sheet, in both appearances (dark is night paper and dark sheet, not system black).
    func testSettingsListsSitOnPaperWithRowsOnSheet() throws {
        let auth = AuthManager()
        auth.cancelSignIn()
        let userStore = UserStore(preferencesService: StaticPreferencesService(items: []), congressService: FakeCongressService())
        let info = AboutInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "45",
            AboutInfo.websiteBaseURLKey: "https://billboard-project.com"
        ])
        let screens: [(String, AnyView)] = [
            ("settings", AnyView(NavigationStack { ProfileSettingsMenuView() }.environmentObject(auth).environmentObject(userStore))),
            ("app-settings", AnyView(NavigationStack { AppSettingsView() }.environmentObject(userStore))),
            ("about", AnyView(NavigationStack { AboutView(info: info) })),
            ("delete-account", AnyView(NavigationStack { DeleteAccountDataView() }.environmentObject(auth).environmentObject(userStore)))
        ]
        for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let paper = style == .dark ? BillboardPalette.background.dark : BillboardPalette.background.light
            let sheet = style == .dark ? BillboardPalette.cardBackground.dark : BillboardPalette.cardBackground.light
            for (name, view) in screens {
                let image = try snapshot(view, style: style)
                let attachment = XCTAttachment(image: image)
                attachment.name = "profile-list-\(name)-\(styleName)"
                attachment.lifetime = .keepAlways
                add(attachment)

                // The list's margin, under the bar, is paper all the way down.
                let margin = try SnapshotPixels.column(of: image, x: 6)
                for y in stride(from: 180, to: margin.count - 40, by: 20) {
                    XCTAssertTrue(SnapshotPixels.matches(margin[y], paper, tolerance: 0.02), "\(name) \(styleName): paper at y \(y), got \(margin[y])")
                }
                // The rows are on sheet.
                let middle = try SnapshotPixels.column(of: image, x: Int(image.size.width) / 2)
                XCTAssertTrue(middle.contains { SnapshotPixels.matches($0, sheet, tolerance: 0.01) }, "\(name) \(styleName): rows on sheet")
            }
        }
    }

    /// About Billboard reads the version from the bundle and shows the disclaimer word for word.
    func testAboutShowsTheVersionAndTheDisclaimerWordForWord() throws {
        let info = AboutInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "45",
            AboutInfo.websiteBaseURLKey: "https://billboard-project.com"
        ])
        let host = AccessibilityTreeText.Host(NavigationStack { AboutView(info: info) }, size: CGSize(width: 390, height: 844), settle: 0.3)
        defer { host.close() }
        let text = host.text()
        XCTAssertTrue(text.contains(AboutInfo.disclaimer), text)
        XCTAssertTrue(text.contains("Version 1.2 (45)"), text)
        XCTAssertTrue(text.contains("Roadmap"), text)
        XCTAssertTrue(text.contains("Privacy policy"), text)
        XCTAssertEqual(host.identifier(of: "Version 1.2 (45)"), "about.version")
    }

    // MARK: - Helpers

    private func screen<Content: View>(_ content: Content) -> some View {
        content
            .padding(16)
            .background(BillboardColors.background)
    }

    private func render<Content: View>(_ view: Content, variant: Variant, width: CGFloat = 390) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.dynamicTypeSize, variant.size)
        )
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.cgImage, "render failed for \(variant.name)")
    }

    private func attach(_ image: CGImage, name: String) {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The first row (from the top) with a pixel in `columns` that is not `paper`, more than 4 of 255 off on any
    /// channel (the monogram's `well` fill is 7 off), or nil when the band is all paper.
    private func firstMarkedRow(_ image: CGImage, columns: Range<Int>, paper: BillboardColorToken.RGBA) throws -> Int? {
        let pixels = try rgba(of: image)
        let target = [paper.red, paper.green, paper.blue].map { Int(($0 * 255).rounded()) }
        let lower = max(columns.lowerBound, 0)
        let upper = min(columns.upperBound, image.width)
        guard lower < upper else { return nil }
        for y in 0..<image.height {
            for x in lower..<upper {
                let index = (y * image.width + x) * 4
                if (0..<3).contains(where: { abs(Int(pixels[index + $0]) - target[$0]) > 4 }) {
                    return y
                }
            }
        }
        return nil
    }

    /// Whether any pixel of `image` is within `tolerance` of `color` on every channel.
    private func contains(_ image: CGImage, _ color: BillboardColorToken.RGBA, tolerance: Double) throws -> Bool {
        try pixelCount(image, color, tolerance: tolerance, stopAtFirst: true) > 0
    }

    /// How many opaque pixels of `image` are within `tolerance` of `color` on every channel.
    private func pixelCount(_ image: CGImage, _ color: BillboardColorToken.RGBA, tolerance: Double, stopAtFirst: Bool = false) throws -> Int {
        let pixels = try rgba(of: image)
        let target = (Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded()))
        let limit = Int((tolerance * 255).rounded())
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] == 255 {
            if abs(Int(pixels[index]) - target.0) <= limit,
               abs(Int(pixels[index + 1]) - target.1) <= limit,
               abs(Int(pixels[index + 2]) - target.2) <= limit {
                count += 1
                if stopAtFirst { return count }
            }
        }
        return count
    }

    /// `top` (with its alpha) over the opaque `ground`, as drawn.
    private func composite(_ top: BillboardColorToken.RGBA, over ground: BillboardColorToken.RGBA) -> BillboardColorToken.RGBA {
        let mixed = BillboardColorMath.composite(top.rgb, alpha: top.alpha, over: ground.rgb)
        return BillboardColorToken.RGBA(red: mixed.red, green: mixed.green, blue: mixed.blue, alpha: 1)
    }

    /// The image's pixels as sRGB bytes, row 0 at the top.
    private func rgba(of image: CGImage) throws -> [UInt8] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = image.width
        let height = image.height
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
        XCTAssertTrue(drawn, "bitmap context")
        return bytes
    }

    /// Hosts `view` in its own window with the given appearance and draws the window through UIKit, which draws
    /// system lists (`ImageRenderer` cannot).
    private func snapshot(_ view: AnyView, style: UIUserInterfaceStyle) throws -> UIImage {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the hosted test app has a window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: 844))
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: view.tint(BillboardColors.interactive))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
