import XCTest
@testable import Billboard

/// The reasons' order (feature review N13, project decision of 2026-10-28): shuffled per person, the same for that
/// person on every launch and device, spread evenly over people, with Need More Information only after an Abstain,
/// and the identifiers sent to the server unchanged.
@MainActor
final class VoteReasonOrderTests: XCTestCase {
    private static let seed = "3f2a9c4e-0b1d-4e8f-9a7c-5d6e1f2a3b4c"

    /// The server's keys (billboard-backend models/feedback.ts FEEDBACK_REASON_KEYS) are what the app sends.
    func testTheReasonIdentifiersAreUnchanged() {
        XCTAssertEqual(VoteReason.allCases.map(\.rawValue), [
            "morals_values", "constitutional_rights", "economic_impact", "taxes_spending", "public_safety", "healthcare",
            "education", "environment", "national_security", "privacy_liberty", "local_community", "trust_sponsor",
            "evidence_data", "need_more_info"
        ])
        XCTAssertEqual(VoteReason.maxSelections, 3)
    }

    /// A Yea or Nay offers every reason but Need More Information, which contradicts it; an Abstain offers only it.
    func testEachVoteOffersItsOwnReasons() {
        XCTAssertEqual(VoteReason.yeaNayReasons, VoteReason.allCases.filter { $0 != .needMoreInfo })
        XCTAssertEqual(VoteReason.yeaNayReasons.count, 13)
        XCTAssertEqual(VoteReason.offered(for: .yea), VoteReason.yeaNayReasons)
        XCTAssertEqual(VoteReason.offered(for: .nay), VoteReason.yeaNayReasons)
        XCTAssertEqual(VoteReason.offered(for: .abstain), [.needMoreInfo])
        for seed in ["a", "b", Self.seed] {
            XCTAssertFalse(VoteReasonOrder.order(for: .yea, seed: seed).contains(.needMoreInfo), seed)
            XCTAssertEqual(VoteReasonOrder.order(for: .abstain, seed: seed), [.needMoreInfo], seed)
        }
    }

    /// The order is written out (FNV-1a, SplitMix64, Fisher-Yates), so an iOS or Swift update never reshuffles a
    /// person's reasons: this pins one person's order.
    func testAPersonsOrderIsPinned() {
        XCTAssertEqual(VoteReasonOrder.order(for: .yea, seed: Self.seed).map(\.rawValue), [
            "taxes_spending", "constitutional_rights", "trust_sponsor", "education", "healthcare", "evidence_data",
            "public_safety", "local_community", "national_security", "economic_impact", "environment", "morals_values",
            "privacy_liberty"
        ])
        XCTAssertEqual(VoteReasonOrder.order(for: .yea, seed: "user-0").prefix(3).map(\.rawValue), [
            "evidence_data", "constitutional_rights", "local_community"
        ])
    }

    /// The same person gets the same order every time, after a Yea and after a Nay; it is a permutation of the
    /// reasons offered.
    func testTheOrderIsStableAndCompleteForAPerson() {
        let yea = VoteReasonOrder.order(for: .yea, seed: Self.seed)
        XCTAssertEqual(VoteReasonOrder.order(for: .yea, seed: Self.seed), yea)
        XCTAssertEqual(VoteReasonOrder.order(for: .nay, seed: Self.seed), yea, "the same order after a Nay")
        XCTAssertEqual(yea.count, VoteReason.yeaNayReasons.count)
        XCTAssertEqual(Set(yea), Set(VoteReason.yeaNayReasons))
        XCTAssertNotEqual(yea, VoteReason.yeaNayReasons, "not the fixed order")
        XCTAssertEqual(VoteReasonOrder.order(of: [], seed: Self.seed), [])
        XCTAssertEqual(VoteReasonOrder.order(of: [.healthcare], seed: Self.seed), [.healthcare])
    }

    /// Over many people each reason is among the first three about equally often (3 in 13), so no reason gains
    /// from its position in Why people voted, and every reason is first for someone.
    func testTheFirstThreeAreSpreadEvenlyOverPeople() {
        let people = 2000
        var leading: [VoteReason: Int] = [:]
        var first: [VoteReason: Int] = [:]
        var orders = Set<[VoteReason]>()
        for index in 0..<people {
            let order = VoteReasonOrder.order(for: .yea, seed: "user-\(index)")
            orders.insert(order)
            for reason in order.prefix(VoteReasonPicker.leadingCount) {
                leading[reason, default: 0] += 1
            }
            first[order[0], default: 0] += 1
        }
        let expected = Double(people * VoteReasonPicker.leadingCount) / Double(VoteReason.yeaNayReasons.count)
        for reason in VoteReason.yeaNayReasons {
            let count = Double(leading[reason] ?? 0)
            XCTAssertEqual(count, expected, accuracy: 100, "\(reason.rawValue) among the first three \(count) times")
            XCTAssertGreaterThan(first[reason] ?? 0, 100, "\(reason.rawValue) first")
        }
        XCTAssertGreaterThan(orders.count, people - 5, "almost every person has an order of their own")
    }

    /// The seed is the account ID when there is one; before that, an ID made once on this device and kept, never
    /// one made per launch.
    func testTheSeedIsTheAccountElseOneKeptOnTheDevice() throws {
        let suite = "VoteReasonOrderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VoteReasonOrder.seed(accountID: "user-123", defaults: defaults), "user-123")
        XCTAssertEqual(VoteReasonOrder.seed(accountID: "  user-123\n", defaults: defaults), "user-123")
        XCTAssertNil(defaults.string(forKey: VoteReasonOrder.deviceSeedKey), "no device seed while the account is known")

        let device = VoteReasonOrder.seed(accountID: "", defaults: defaults)
        XCTAssertFalse(device.isEmpty)
        XCTAssertEqual(defaults.string(forKey: VoteReasonOrder.deviceSeedKey), device, "kept")
        XCTAssertEqual(VoteReasonOrder.seed(accountID: "  ", defaults: defaults), device, "the same on the next launch")
        XCTAssertEqual(VoteReasonOrder.seed(accountID: "user-123", defaults: defaults), "user-123", "the account wins once known")
    }
}
