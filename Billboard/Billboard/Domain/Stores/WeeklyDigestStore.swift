import Combine
import Foundation
import os

/// The Weekly Brief on Updates: the server's brief only (UX-28, a project decision of 2026-11-23). The app builds
/// no brief on the device and posts no notification of its own; the server sends the Sunday push.
@MainActor
final class WeeklyDigestStore: ObservableObject {
    @Published private(set) var digest: WeeklyDigest?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var settings: WeeklyDigestSettings
    @Published var errorMessage: String?

    private let scope: String
    private let defaults: UserDefaults
    private let digestService: any WeeklyDigestServicing
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BillBoard", category: "weeklyDigest")

    init(
        scope: String,
        defaults: UserDefaults = .standard,
        digestService: any WeeklyDigestServicing = WeeklyDigestService.Live()
    ) {
        self.scope = scope
        self.defaults = defaults
        self.digestService = digestService
        self.settings = Self.loadSettings(scope: scope, defaults: defaults) ?? .default
        self.encoder.dateEncodingStrategy = .iso8601
        self.digest = Self.loadDigest(scope: scope, defaults: defaults)
    }

    /// 1 while Updates shows the brief as its UNREAD front page (the brief is on and not yet opened), else 0:
    /// the Updates badge counts it like a row (feature review N5).
    var unreadDigestCount: Int {
        guard settings.isEnabled, let digest, !digest.isRead else { return 0 }
        return 1
    }

    /// The release (a window id) whose last finished refresh found no brief: the server answered with none for
    /// this person. Cleared when a brief arrives.
    @Published private(set) var noBriefReleaseID: String?

    /// True once a refresh for this week's release finished with no brief and no error. Updates says how to get a
    /// brief only then: never while one is still loading, which it may be for someone who follows nothing
    /// (`followsSomething`).
    var foundNoBriefThisWeek: Bool {
        guard let noBriefReleaseID else { return false }
        return Self.isSameRelease(noBriefReleaseID, Self.latestPublishedWindow(relativeTo: Date()).id)
    }

    /// Whether the person follows topics, life areas or members, or watches bills, the things a brief is mostly
    /// built from (feature review N2). Updates says how to get a brief ("Follow topics or members to get a Weekly
    /// Brief.") only to someone who follows none of them, once a refresh found none (`foundNoBriefThisWeek`).
    ///
    /// Follows that are not known yet count as following: a profile that has not loaded (no id), and one whose
    /// follows did not load (`followsAreKnown` false: a first launch whose preferences request failed leaves the
    /// account's id with no follows, though the person may follow topics).
    nonisolated static func followsSomething(_ profile: UserProfile, followsAreKnown: Bool) -> Bool {
        guard followsAreKnown else { return true }
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let follows = [profile.subscribedSubCategories, profile.subscribedLifeAreas, profile.watchedBillGUIDs]
            .contains { values in values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        return follows || !profile.subscribedMemberIDs.isEmpty
    }

    /// Whether Updates shows "Building your Weekly Brief" while the brief loads: the person follows something a
    /// brief is built from (`followsSomething`), or has voted. The server's brief (billboard-backend
    /// `shared/weeklyDigestBuilder.ts`, its "voted_updated" bucket) also lists a bill the person voted on (Yea, Nay
    /// or Abstain, never a 1.0 or 1.1 dismissal) that was updated that week, with no follows needed, so someone who
    /// follows nothing but has voted gets a brief in a week a bill they voted on moves. Someone who follows nothing
    /// and never voted sees nothing while it loads.
    ///
    /// Votes not known yet (`hasVoted` nil: the Civic Score has not loaded) count as voted, as follows that are not
    /// known count as following.
    nonisolated static func isBriefExpected(for profile: UserProfile, followsAreKnown: Bool, hasVoted: Bool?) -> Bool {
        followsSomething(profile, followsAreKnown: followsAreKnown) || hasVoted != false
    }

    /// True when the digest on screen is from an earlier week than the latest published one
    /// (for example because this week's brief failed to load).
    var isShowingStaleDigest: Bool {
        guard let digest else { return false }
        return !Self.matches(digest, window: Self.latestPublishedWindow(relativeTo: Date()))
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        persistSettings()
    }

    func markCurrentDigestRead() {
        guard var digest, !digest.isRead else { return }
        digest.isRead = true
        self.digest = digest
        persistDigest(digest)
    }

    /// Reads this week's brief from the server, unless it is already here. A refresh that finds the server has no
    /// brief this week clears the one on screen and remembers that (`noBriefReleaseID`). A failed read keeps the
    /// brief on screen and says so (`errorMessage`; views check `isShowingStaleDigest`). A brief for another week
    /// changes nothing, and the next refresh asks again.
    func refresh(profile: UserProfile, forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        guard settings.isEnabled else { return }
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // This week's brief is already here: kept from the last refresh, or saved on the device (`isServersBrief`).
        let targetWindow = Self.latestPublishedWindow(relativeTo: Date())
        if !forceRefresh, let digest, Self.isServersBrief(digest, for: targetWindow) {
            errorMessage = nil
            return
        }

        if !forceRefresh, let cached = Self.loadDigest(scope: scope, defaults: defaults), Self.isServersBrief(cached, for: targetWindow) {
            digest = cached
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let remote: WeeklyDigest?
        do {
            remote = try await digestService.fetchLatest()
        } catch {
            if APIErrorResponse.isCancellation(error) { return }
            // The previous digest (if any) stays on screen; views check `isShowingStaleDigest`
            // so an earlier week's brief is not presented as current.
            errorMessage = UserFacingLoadError.message(for: error, loading: "this week's brief")
            logger.error("Weekly digest refresh failed: \(String(describing: error), privacy: .public)")
            return
        }

        guard let remote else {
            // An empty answer (204): the server has no brief for this person this week.
            digest = nil
            noBriefReleaseID = targetWindow.id
            clearPersistedDigest()
            return
        }

        // Another week's brief is neither this week's nor a sign that there is none: for example last week's, read
        // on Sunday morning before this week's is stored. What is on screen and on the device stays as it is, and
        // the next refresh asks again.
        guard remote.publishedAt <= Date(), Self.matches(remote, window: targetWindow) else {
            logger.notice("The server's Weekly Brief is not this week's; the brief on screen is kept")
            return
        }

        let normalized = normalizeReadState(for: remote)
        digest = normalized
        noBriefReleaseID = nil
        persistDigest(normalized)
    }

    /// Whether `digest` is the server's brief for `window`'s week. Weeks are compared by release time, since the
    /// server's id and the app's are written differently (`isSameRelease`). A brief app 1.2 built on the device
    /// (`.localFallback`) is not the server's, so a refresh asks the server for it.
    private static func isServersBrief(_ digest: WeeklyDigest, for window: DigestPublicationWindow) -> Bool {
        digest.source != .localFallback && isSameRelease(digest.id, window.id)
    }

    /// The new brief keeps the read state of the one on screen for the same week, whichever wrote it: a brief
    /// opened as app 1.2's on-device version stays read when the server's arrives.
    private func normalizeReadState(for newDigest: WeeklyDigest) -> WeeklyDigest {
        guard let existing = digest, Self.isSameRelease(existing.id, newDigest.id) else { return newDigest }
        var merged = newDigest
        merged.isRead = existing.isRead
        return merged
    }

    private func persistDigest(_ digest: WeeklyDigest) {
        guard let data = try? encoder.encode(digest) else { return }
        defaults.set(data, forKey: Self.digestKey(scope: scope))
    }

    private func persistSettings() {
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey(scope: scope))
    }

    private func clearPersistedDigest() {
        defaults.removeObject(forKey: Self.digestKey(scope: scope))
    }

    private static func loadDigest(scope: String, defaults: UserDefaults) -> WeeklyDigest? {
        guard let data = defaults.data(forKey: digestKey(scope: scope)) else { return nil }
        return try? JSONDecoder.usingDefaultKeys(dates: .iso8601).decode(WeeklyDigest.self, from: data)
    }

    private static func loadSettings(scope: String, defaults: UserDefaults) -> WeeklyDigestSettings? {
        guard let data = defaults.data(forKey: settingsKey(scope: scope)) else { return nil }
        return try? JSONDecoder.usingDefaultKeys().decode(WeeklyDigestSettings.self, from: data)
    }

    private static func digestKey(scope: String) -> String {
        "BillBoard.weeklyDigest.v1.digest.\(scope)"
    }

    private static func settingsKey(scope: String) -> String {
        "BillBoard.weeklyDigest.v1.settings.\(scope)"
    }

    /// Where app 1.2 noted the last brief it posted its own notification for. 1.3 posts none; the key is still
    /// removed with the cache.
    private static func lastNotifiedDigestKey(scope: String) -> String {
        "BillBoard.weeklyDigest.v1.lastNotified.\(scope)"
    }

    static func clearCache(scope: String?, defaults: UserDefaults = .standard) {
        guard let scope = scope.trimmedNonEmpty else { return }
        defaults.removeObject(forKey: digestKey(scope: scope))
        defaults.removeObject(forKey: settingsKey(scope: scope))
        defaults.removeObject(forKey: lastNotifiedDigestKey(scope: scope))
    }

    /// Whether two brief ids are the same week's. The server's id is its Sunday 10 AM ET release time from
    /// `toISOString()` ("2026-10-25T14:00:00.000Z"); the app writes the same time in New York time for its
    /// window, as app 1.2 did for its on-device brief ("2026-10-25T10:00:00-04:00"). Compared as text they never matched, so
    /// the app downloaded the server's brief again on every Updates visit (feature review N2). Ids that are not
    /// dates are compared as text.
    nonisolated static func isSameRelease(_ id: String, _ otherID: String) -> Bool {
        if id == otherID { return true }
        guard let release = FlexibleISO8601.parse(id), let otherRelease = FlexibleISO8601.parse(otherID) else { return false }
        return abs(release.timeIntervalSince(otherRelease)) < 1
    }

    static func latestPublishedWindow(relativeTo date: Date) -> DigestPublicationWindow {
        let calendar = WeeklyDigestSchedule.calendar
        let startOfToday = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let currentSundayStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: startOfToday) ?? startOfToday
        let currentSundayRelease = calendar.date(
            bySettingHour: WeeklyDigestSchedule.releaseHour,
            minute: WeeklyDigestSchedule.releaseMinute,
            second: 0,
            of: currentSundayStart
        ) ?? currentSundayStart

        let releaseAt: Date
        if date >= currentSundayRelease {
            releaseAt = currentSundayRelease
        } else {
            releaseAt = calendar.date(byAdding: .day, value: -7, to: currentSundayRelease) ?? currentSundayRelease
        }

        let releaseDayStart = calendar.startOfDay(for: releaseAt)
        let contentEnd = calendar.date(byAdding: .day, value: -1, to: releaseDayStart) ?? releaseDayStart
        let contentStart = calendar.date(byAdding: .day, value: -6, to: contentEnd) ?? contentEnd

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = WeeklyDigestSchedule.timeZone

        return DigestPublicationWindow(
            id: formatter.string(from: releaseAt),
            start: contentStart,
            end: contentEnd,
            releaseAt: releaseAt
        )
    }

    private static func matches(_ digest: WeeklyDigest, window: DigestPublicationWindow) -> Bool {
        let calendar = WeeklyDigestSchedule.calendar
        return calendar.isDate(digest.weekStart, inSameDayAs: window.start)
            && calendar.isDate(digest.weekEnd, inSameDayAs: window.end)
    }
}

struct DigestPublicationWindow: Equatable {
    let id: String
    let start: Date
    let end: Date
    let releaseAt: Date
}
