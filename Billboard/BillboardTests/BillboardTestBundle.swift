import Foundation
@testable import Billboard

/// The unit-test bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass`): XCTest makes one before any test runs.
/// It pins the clock the past-Congress rules read (`CongressCalendar.clock`, REL-46) to a day in the 119th Congress,
/// so the many tests that build 119th bills keep their stamps, docket lines and Bills list after 2027-01-03, when the
/// 119th Congress ends. The changeover tests pass their own dates.
@objc(BillboardTestBundle)
final class BillboardTestBundle: NSObject {
    /// 2026-11-20T17:00:00Z: the 119th Congress, 2nd session.
    static let pinnedCongressDate = Date(timeIntervalSince1970: 1_795_194_000)

    override init() {
        super.init()
        CongressCalendar.clock = { Self.pinnedCongressDate }
    }
}
