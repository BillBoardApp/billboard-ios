import CryptoKit
import Foundation
import XCTest
@testable import Billboard

/// R2's new local keys (spec D 3.2) and the first-run accessors. Every test uses a throwaway
/// `UserDefaults` suite, never the host app's standard defaults.
final class FirstRunStorageTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FirstRunStorageTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    func testKeysMatchTheSpec() {
        XCTAssertEqual(FirstRunStorage.appearanceKey, "BillBoard.appearance.v1")
        XCTAssertEqual(FirstRunStorage.voteCoachMarkPendingKey, "BillBoard.firstRun.voteCoachMarkPending.v1")
        XCTAssertEqual(FirstRunStorage.topicPromptShownKey(userID: "abc-123"), "BillBoard.topicPrompt.shown.v1.abc-123")
        XCTAssertEqual(FirstRunStorage.starterBannerHiddenUntilKey(userID: "abc-123"), "BillBoard.starterBanner.hiddenUntil.v1.abc-123")
        XCTAssertTrue(FirstRunStorage.pendingAdultAnswerKey(email: "a@example.com").hasPrefix("BillBoard.pendingAdultAnswer.v1."))
    }

    func testAdultAnswerKeyHashesTheNormalizedEmailAndNeverStoresItInClear() {
        let key = FirstRunStorage.pendingAdultAnswerKey(email: "  Voter@Example.COM \n")
        XCTAssertFalse(key.lowercased().contains("voter"))
        XCTAssertFalse(key.lowercased().contains("example"))

        let expectedDigest = SHA256.hash(data: Data("voter@example.com".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(key, "BillBoard.pendingAdultAnswer.v1.\(expectedDigest)")
        XCTAssertEqual(FirstRunStorage.pendingAdultAnswerEmailHash("voter@example.com").count, 64)

        // Case and surrounding whitespace do not change the key; a different address does.
        XCTAssertEqual(key, FirstRunStorage.pendingAdultAnswerKey(email: "voter@example.com"))
        XCTAssertNotEqual(key, FirstRunStorage.pendingAdultAnswerKey(email: "other@example.com"))
    }

    func testKnownSHA256Vector() {
        // SHA-256("abc"), FIPS 180-2 appendix B.1.
        XCTAssertEqual(
            FirstRunStorage.pendingAdultAnswerEmailHash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testVoteCoachMarkFlag() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(FirstRunStorage.isVoteCoachMarkPending(defaults: defaults))
        FirstRunStorage.setVoteCoachMarkPending(true, defaults: defaults)
        XCTAssertTrue(FirstRunStorage.isVoteCoachMarkPending(defaults: defaults))
        FirstRunStorage.setVoteCoachMarkPending(false, defaults: defaults)
        XCTAssertFalse(FirstRunStorage.isVoteCoachMarkPending(defaults: defaults))
        XCTAssertNil(defaults.object(forKey: FirstRunStorage.voteCoachMarkPendingKey), "cleared, not stored as false")
    }

    func testTopicPromptIsPerUser() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(FirstRunStorage.topicPromptShown(userID: "user-a", defaults: defaults))
        FirstRunStorage.markTopicPromptShown(userID: "user-a", defaults: defaults)
        XCTAssertTrue(FirstRunStorage.topicPromptShown(userID: "user-a", defaults: defaults))
        XCTAssertFalse(FirstRunStorage.topicPromptShown(userID: "user-b", defaults: defaults))
    }

    func testStarterBannerHidesForSevenDaysPerUser() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(FirstRunStorage.isStarterBannerHidden(userID: "user-a", now: now, defaults: defaults))
        XCTAssertNil(FirstRunStorage.starterBannerHiddenUntil(userID: "user-a", defaults: defaults))

        FirstRunStorage.hideStarterBanner(userID: "user-a", now: now, defaults: defaults)
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        XCTAssertEqual(FirstRunStorage.starterBannerHideDuration, sevenDays)
        XCTAssertEqual(FirstRunStorage.starterBannerHiddenUntil(userID: "user-a", defaults: defaults), now.addingTimeInterval(sevenDays))

        XCTAssertTrue(FirstRunStorage.isStarterBannerHidden(userID: "user-a", now: now.addingTimeInterval(sevenDays - 1), defaults: defaults))
        XCTAssertFalse(FirstRunStorage.isStarterBannerHidden(userID: "user-a", now: now.addingTimeInterval(sevenDays), defaults: defaults))
        XCTAssertFalse(FirstRunStorage.isStarterBannerHidden(userID: "user-b", now: now, defaults: defaults))
    }
}
