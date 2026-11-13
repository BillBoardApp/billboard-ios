import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// INT-11: a bill card shows no vote counts, neither on screen nor to VoiceOver, even when the bills
/// manifest it came from still carries a high `voteCount` (old snapshots and caches do). The "10+ votes"
/// badge (spec D 2.4.1) is gone for everyone: other users' votes show only in a bill's Results, after
/// the user votes or abstains on it.
@MainActor
final class BillCardVoteCountTests: XCTestCase {
    private static let single = "BILLS-119hr1234"
    private static let house = "BILLS-119hr900"
    private static let senate = "BILLS-119s456"
    private static let updatedAt = Date().addingTimeInterval(-3 * 60 * 60)

    /// A manifest as an old server or cache sends it: every bill with a count far over the badge's 10.
    /// With `withCounts` false, the same manifest without the field (as the server sends it since INT-11).
    private static func manifestBills(withCounts: Bool = true) throws -> [Bill] {
        let updatedAt = ISO8601DateFormatter().string(from: Self.updatedAt)
        func item(_ guid: String, type: String, number: String, votes: Int, title: String) -> String {
            let count = withCounts ? #""voteCount":\#(votes),"# : ""
            return #"{"guid":"\#(guid)","congress":"119","billType":"\#(type)","billID":"\#(number)","updatedAt":"\#(updatedAt)","#
                + #""subCategories":["Energy"],"lifeAreas":[],"sponsors":[],"cosponsors":[],"# + count
                + #""isPriority":true,"priorityRank":1,"title":"\#(title)","billStatus":"New"}"#
        }
        let json = #"{"generatedAt":"\#(updatedAt)","count":3,"bills":["#
            + item(single, type: "hr", number: "1234", votes: 240, title: "Clean Energy Reporting Act") + ","
            + item(house, type: "hr", number: "900", votes: 160, title: "Grid Repair Act") + ","
            + item(senate, type: "s", number: "456", votes: 75, title: "Grid Repair Act")
            + "]}"
        let manifest = try JSONDecoder().decode(BillsManifest.self, from: Data(json.utf8))
        return manifest.bills.map(BillsStore.placeholderBill(from:))
    }

    private var userStore: UserStore {
        UserStore(preferencesService: FakePreferencesService(), congressService: FakeCongressService())
    }

    private var group: BillCompanionGroup {
        BillCompanionGroup(primaryGuid: Self.house, memberGuids: [Self.house, Self.senate], relationship: "identical")
    }

    /// The cards a list shows: one bill, and a companion pair as one card on its primary.
    private func cards(_ bills: [Bill]) throws -> some View {
        let single = try XCTUnwrap(bills.first { $0.guid == Self.single })
        let primary = try XCTUnwrap(bills.first { $0.guid == Self.house })
        let pair = BillCompanionDisplay(group: group, statusLead: nil)
        return VStack(spacing: 16) {
            BillCard(bill: single)
            BillCard(bill: primary)
                .environment(\.billCardCompanions, [primary.id: pair])
        }
        .padding(20)
        .background(BillboardColors.background)
        .environmentObject(userStore)
    }

    func testCardsReadNoVoteCountToVoiceOverOrOnScreen() throws {
        let text = AccessibilityTreeText.text(of: try cards(try Self.manifestBills()))

        // The walk found the cards (so an empty tree cannot pass).
        XCTAssertTrue(text.contains("Clean Energy Reporting Act"), text)
        // The companion slip reads its numbers in the spoken form (Civic Record spec 1.7, 3.4).
        XCTAssertTrue(text.contains("House bill 900 and Senate bill 456."), text)
        XCTAssertTrue(text.contains("Identical bills."), text)
        XCTAssertTrue(text.contains("In the news"), text)

        XCTAssertNil(text.range(of: #"\bvotes?\b"#, options: [.regularExpression, .caseInsensitive]), text)
        for leaked in ["240", "160", "75", "10+", "50+", "150+", "flame"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(leaked), "\(leaked) in: \(text)")
        }
    }

    func testCardsFromAHighCountManifestDrawTheSameAsCardsWithNoCount() throws {
        let withCounts = try Self.manifestBills()
        let withoutCounts = try Self.manifestBills(withCounts: false)
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(try cards(withCounts), scheme: scheme)
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "bill-cards-no-vote-count-\(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(image.height, 2 * 80, "two cards")

            // Nothing on a card depends on the count.
            let plain = try render(try cards(withoutCounts), scheme: scheme)
            XCTAssertEqual(image.width, plain.width, "\(scheme)")
            XCTAssertEqual(image.height, plain.height, "\(scheme)")
            XCTAssertEqual(image.dataProvider?.data as Data?, plain.dataProvider?.data as Data?, "the same pixels (\(scheme))")
        }
    }

    private func render<Content: View>(_ view: Content, scheme: ColorScheme) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: 390).environment(\.colorScheme, scheme))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        return try XCTUnwrap(renderer.cgImage)
    }
}
