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
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BillBoard", category: "weeklyDigest")

    /// A brief app 1.2 built on the device and saved (`.localFallback`). It is never shown, since it can name a
    /// member by an id (REL-46 A4); only its week and read state are used, so the server's brief for that week
    /// stays read if it was opened (`normalizeReadState`). It goes once the server answers for this week.
    private var savedOnDeviceBrief: WeeklyDigest?

    /// How many times each account's saved brief was cleared in this run of the app (`clearCache`: sign-out and
    /// account deletion, `UserLocalDataPurge`), how many times every account's was (`clearAllCaches`: a sign-out that
    /// does not know the account), and both counts when this store was made.
    private static var clearCounts: [String: Int] = [:]
    private static var clearAllCount = 0
    private let clearCountAtInit: Int
    private let clearAllCountAtInit: Int

    /// - Parameter now: the clock, which tests set.
    init(
        scope: String,
        defaults: UserDefaults = .standard,
        digestService: any WeeklyDigestServicing = WeeklyDigestService.Live(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.clearAllCountAtInit = Self.clearAllCount
        self.scope = scope
        self.defaults = defaults
        self.digestService = digestService
        self.now = now
        self.clearCountAtInit = Self.clearCounts[scope, default: 0]
        self.settings = Self.loadSettings(scope: scope, defaults: defaults) ?? .default
        self.encoder.dateEncodingStrategy = .iso8601
        let saved = Self.loadDigest(scope: scope, defaults: defaults)
        if saved?.source == .localFallback {
            self.savedOnDeviceBrief = saved
        } else {
            self.digest = saved
        }
    }

    /// What the brief adds to the Updates badge at `now` (feature review N5; UX-28, a project decision of
    /// 2026-11-23): 1 for this week's brief (`latestPublishedWindow(relativeTo: now)`) not yet opened, from its
    /// release on Sunday at 10 AM until Tuesday 00:00, New York time; else 0, and 0 while Weekly Brief in Updates is
    /// off (`isEnabled`). Updates still shows an unopened brief as its UNREAD front page all week; only the badge
    /// stops on Tuesday.
    static func unreadDigestCount(digest: WeeklyDigest?, isEnabled: Bool, now: Date) -> Int {
        guard isEnabled, let digest, !digest.isRead else { return 0 }
        let window = latestPublishedWindow(relativeTo: now)
        guard isSameRelease(digest.id, window.id), now < badgeEnd(forReleaseAt: window.releaseAt) else { return 0 }
        return 1
    }

    /// Tuesday 00:00 in New York time after the Sunday release at `releaseAt`: two calendar days after the release
    /// day starts, so a clock change that weekend moves it with the clocks.
    private static func badgeEnd(forReleaseAt releaseAt: Date) -> Date {
        let calendar = WeeklyDigestSchedule.calendar
        let releaseDay = calendar.startOfDay(for: releaseAt)
        return calendar.date(byAdding: .day, value: 2, to: releaseDay) ?? releaseDay.addingTimeInterval(2 * 24 * 60 * 60)
    }

    /// The next time after `now` that the brief's badge can change while the app stays open (UX-28), when the tabs
    /// read and count it again: Sunday 10:30 AM, New York time, when this week's brief is stored
    /// (`briefStoringGrace`), and Tuesday 00:00, when the badge stops counting it (`unreadDigestCount`).
    static func nextBadgeCheck(after now: Date) -> Date {
        let releaseAt = latestPublishedWindow(relativeTo: now).releaseAt
        let stored = releaseAt.addingTimeInterval(briefStoringGrace)
        if now < stored { return stored }
        let end = badgeEnd(forReleaseAt: releaseAt)
        if now < end { return end }
        let nextRelease = WeeklyDigestSchedule.calendar.date(byAdding: .day, value: 7, to: releaseAt)
            ?? releaseAt.addingTimeInterval(7 * 24 * 60 * 60)
        return nextRelease.addingTimeInterval(briefStoringGrace)
    }

    /// The release (a window id) whose last finished refresh found no brief: the server answered with none for
    /// this person. Cleared when a brief arrives.
    @Published private(set) var noBriefReleaseID: String?

    /// True once a refresh for this week's release finished with no brief and no error. Updates says how to get a
    /// brief only then: never while one is still loading, which it may be for someone who follows nothing
    /// (`followsSomething`).
    var foundNoBriefThisWeek: Bool {
        guard let noBriefReleaseID else { return false }
        return Self.isSameRelease(noBriefReleaseID, Self.latestPublishedWindow(relativeTo: now()).id)
    }

    /// How long after the Sunday 10 AM ET release an empty answer (204) may mean only that this person's brief is
    /// not stored yet. The server's GenerateWeeklyDigests starts at 10:00 and hands the briefs to its workers, which
    /// store them in time for the first Sunday push run at 10:30 (billboard-backend
    /// `infra/lib/config/weekly-digest-constants.ts`). A worker that fails is tried again 12 minutes later, up to
    /// three times in all, so a brief can still be stored after 10:30: a return to the app on Sunday asks again
    /// (`refreshOnReturnToApp`), and so does each Updates visit.
    nonisolated static let briefStoringGrace: TimeInterval = 30 * 60

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
        return !Self.matches(digest, window: Self.latestPublishedWindow(relativeTo: now()))
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
    /// brief this week clears the one on screen and remembers that (`noBriefReleaseID`), except in the first half
    /// hour after the release (`briefStoringGrace`). A failed read keeps the brief on screen and says so
    /// (`errorMessage`; views check `isShowingStaleDigest`). A brief for another week changes nothing, and the next
    /// refresh asks again.
    func refresh(profile: UserProfile, forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        guard settings.isEnabled else { return }
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // This week's brief is already here: kept from the last refresh, or saved on the device (`isServersBrief`).
        let targetWindow = Self.latestPublishedWindow(relativeTo: now())
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

        // The account signed out while the read was out: its brief must not come back after sign-out cleared it.
        guard isAccountStillHere else {
            logger.notice("A Weekly Brief read answered after sign-out; nothing is kept")
            return
        }

        guard let remote else {
            // An empty answer (204) on Sunday before 10:30 AM ET may only mean the server has not stored this
            // person's brief yet. Like another week's brief, it changes nothing, and the next refresh asks again.
            if now() < targetWindow.releaseAt.addingTimeInterval(Self.briefStoringGrace) {
                logger.notice("No Weekly Brief yet in the half hour after its release; the brief on screen is kept")
                return
            }
            // Otherwise the server has no brief for this person this week.
            digest = nil
            savedOnDeviceBrief = nil
            noBriefReleaseID = targetWindow.id
            clearPersistedDigest()
            return
        }

        // Another week's brief is neither this week's nor a sign that there is none. The server answers for the
        // week its own clock is in, so this comes from a phone whose clock is ahead of or behind the server's near
        // a release. What is on screen and on the device stays as it is, and the next refresh asks again.
        guard remote.publishedAt <= now(), Self.matches(remote, window: targetWindow) else {
            logger.notice("The server's Weekly Brief is not this week's; the brief on screen is kept")
            return
        }

        let normalized = normalizeReadState(for: remote)
        digest = normalized
        savedOnDeviceBrief = nil
        noBriefReleaseID = nil
        persistDigest(normalized)
    }

    /// A return to the app (UX-28): reads this week's brief if it is not here yet, for example after the app was
    /// last open before Sunday 10 AM ET, so the Sunday and Monday badge can count it. It asks the server nothing
    /// when this week's brief is here (`refresh`'s early returns), or once this week's check found none, except on
    /// the release day itself: a worker the server tries again can store a brief after 10:30 AM
    /// (`briefStoringGrace`).
    func refreshOnReturnToApp(profile: UserProfile) async {
        guard !foundNoBriefThisWeek || isReleaseDay else { return }
        await refresh(profile: profile)
    }

    /// Whether it is Sunday, New York time, after this week's release.
    private var isReleaseDay: Bool {
        let now = now()
        return WeeklyDigestSchedule.calendar.isDate(now, inSameDayAs: Self.latestPublishedWindow(relativeTo: now).releaseAt)
    }

    /// Whether `digest` is the server's brief for `window`'s week. Weeks are compared by release time, since the
    /// server's id and the app's are written differently (`isSameRelease`). A brief app 1.2 built on the device
    /// (`.localFallback`) is not the server's, so a refresh asks the server for it.
    private static func isServersBrief(_ digest: WeeklyDigest, for window: DigestPublicationWindow) -> Bool {
        digest.source != .localFallback && isSameRelease(digest.id, window.id)
    }

    /// The new brief keeps the read state of the one on screen for the same week, or of app 1.2's on-device brief
    /// for that week (`savedOnDeviceBrief`): a brief opened in 1.2 stays read when the server's arrives.
    private func normalizeReadState(for newDigest: WeeklyDigest) -> WeeklyDigest {
        guard let existing = digest ?? savedOnDeviceBrief, Self.isSameRelease(existing.id, newDigest.id) else { return newDigest }
        var merged = newDigest
        merged.isRead = existing.isRead
        return merged
    }

    /// False once this store's account was signed out or deleted (`clearCache`, `clearAllCaches`) after the store was
    /// made. A store then writes nothing on the device for it: a brief read that answers after sign-out, from the tabs or
    /// from Updates and Profile, must not put the signed-out account's brief back (its sections reflect what the person
    /// follows). A later sign-in to the same account makes a new store, which saves as usual.
    private var isAccountStillHere: Bool {
        Self.clearCounts[scope, default: 0] == clearCountAtInit && Self.clearAllCount == clearAllCountAtInit
    }

    private func persistDigest(_ digest: WeeklyDigest) {
        guard isAccountStillHere, let data = try? encoder.encode(digest) else { return }
        defaults.set(data, forKey: Self.digestKey(scope: scope))
    }

    private func persistSettings() {
        guard isAccountStillHere, let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey(scope: scope))
    }

    private func clearPersistedDigest() {
        guard isAccountStillHere else { return }
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

    /// Clears an account's saved brief and settings, at sign-out and account deletion (`UserLocalDataPurge`). A store
    /// made before this writes nothing more for the account (`isAccountStillHere`).
    static func clearCache(scope: String?, defaults: UserDefaults = .standard) {
        guard let scope = scope.trimmedNonEmpty else { return }
        clearCounts[scope, default: 0] += 1
        defaults.removeObject(forKey: digestKey(scope: scope))
        defaults.removeObject(forKey: settingsKey(scope: scope))
        defaults.removeObject(forKey: lastNotifiedDigestKey(scope: scope))
    }

    /// `clearCache` for every account (each key above starts with "BillBoard.weeklyDigest.v1."), at a sign-out that
    /// does not know the account (`UserLocalDataPurge`). No store made before this writes anything more.
    static func clearAllCaches(defaults: UserDefaults = .standard) {
        clearAllCount += 1
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("BillBoard.weeklyDigest.v1.") {
            defaults.removeObject(forKey: key)
        }
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
