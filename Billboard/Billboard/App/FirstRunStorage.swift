import CryptoKit
import Foundation

/// Local keys added in R2 (spec D 3.2) and small typed accessors for the first-run ones. Nothing is
/// migrated: every key is new. Per-user keys take the signed-in user's ID (the Cognito sub).
///
/// Keys owned elsewhere: the tutorial version and auto-show flag stay in `ProductTutorialStorage`,
/// App Attest state lives in the Keychain (C3), and skips reuse the read-state key.
nonisolated enum FirstRunStorage {
    // MARK: Keys

    /// App Settings > Appearance (`AppearancePreference` raw value).
    static let appearanceKey = "BillBoard.appearance.v1"

    /// True after the tour's "Open this bill" until a vote is saved or the user taps Not now.
    static let voteCoachMarkPendingKey = "BillBoard.firstRun.voteCoachMarkPending.v1"

    /// Prefix of the sign-up age answer kept until the server confirms it; the suffix is
    /// `pendingAdultAnswerEmailHash(_:)`, so no email is stored in clear.
    static let pendingAdultAnswerKeyPrefix = "BillBoard.pendingAdultAnswer.v1."

    /// Prefix of the per-user flag set once the first-vote topic prompt was shown.
    static let topicPromptShownKeyPrefix = "BillBoard.topicPrompt.shown.v1."

    /// Prefix of the per-user date until which the starter-feed banner stays hidden.
    static let starterBannerHiddenUntilKeyPrefix = "BillBoard.starterBanner.hiddenUntil.v1."

    /// How long the starter-feed banner's close button hides it.
    static let starterBannerHideDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Lowercase hex SHA-256 of the trimmed, lowercased email.
    static func pendingAdultAnswerEmailHash(_ email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func pendingAdultAnswerKey(email: String) -> String {
        pendingAdultAnswerKeyPrefix + pendingAdultAnswerEmailHash(email)
    }

    static func topicPromptShownKey(userID: String) -> String {
        topicPromptShownKeyPrefix + userID
    }

    static func starterBannerHiddenUntilKey(userID: String) -> String {
        starterBannerHiddenUntilKeyPrefix + userID
    }

    // MARK: Vote coach mark

    /// `UserDefaults.standard` shorthand for the coach-mark flag.
    static var voteCoachMarkPending: Bool {
        get { isVoteCoachMarkPending() }
        set { setVoteCoachMarkPending(newValue) }
    }

    static func isVoteCoachMarkPending(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: voteCoachMarkPendingKey)
    }

    static func setVoteCoachMarkPending(_ pending: Bool, defaults: UserDefaults = .standard) {
        if pending {
            defaults.set(true, forKey: voteCoachMarkPendingKey)
        } else {
            defaults.removeObject(forKey: voteCoachMarkPendingKey)
        }
    }

    // MARK: First-vote topic prompt

    static func topicPromptShown(userID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: topicPromptShownKey(userID: userID))
    }

    static func markTopicPromptShown(userID: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: topicPromptShownKey(userID: userID))
    }

    // MARK: Starter-feed banner

    static func starterBannerHiddenUntil(userID: String, defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: starterBannerHiddenUntilKey(userID: userID)) as? Date
    }

    /// True while a close tap within the last `starterBannerHideDuration` hides the banner.
    static func isStarterBannerHidden(userID: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let until = starterBannerHiddenUntil(userID: userID, defaults: defaults) else { return false }
        return now < until
    }

    /// Hides the banner for `starterBannerHideDuration` from `now`.
    static func hideStarterBanner(userID: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.addingTimeInterval(starterBannerHideDuration), forKey: starterBannerHiddenUntilKey(userID: userID))
    }
}
