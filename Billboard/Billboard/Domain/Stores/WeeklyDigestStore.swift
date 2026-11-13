import Combine
import Foundation
import UserNotifications
import os

@MainActor
final class WeeklyDigestStore: ObservableObject {
    @Published private(set) var digest: WeeklyDigest?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var settings: WeeklyDigestSettings
    @Published var errorMessage: String?

    private let scope: String
    private let defaults: UserDefaults
    private let services: LocalWeeklyDigestBuilder.Services
    private let digestService: any WeeklyDigestServicing
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BillBoard", category: "weeklyDigest")

    init(
        scope: String,
        defaults: UserDefaults = .standard,
        digestService: any WeeklyDigestServicing = WeeklyDigestService.Live(),
        billsService: any BillsServicing = BillsService.Live(),
        votesService: any BillVotesServicing = BillVotesService.Live(),
        congressService: any CongressServicing = CongressService.Live()
    ) {
        self.scope = scope
        self.defaults = defaults
        self.digestService = digestService
        self.services = LocalWeeklyDigestBuilder.Services(
            bills: billsService,
            votes: votesService,
            congress: congressService
        )
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

    /// The release (a window id) whose last finished refresh found no brief: the server had none for this
    /// person and the on-device builder found nothing either. Cleared when a brief arrives.
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

    func refresh(profile: UserProfile, forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        guard settings.isEnabled else { return }
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // This week's brief is already here: kept from the last refresh, or saved on the device. Compared by
        // release time, since the server's id and the app's are written differently (`isSameRelease`).
        let targetWindow = Self.latestPublishedWindow(relativeTo: Date())
        if !forceRefresh, let digest, Self.isSameRelease(digest.id, targetWindow.id) {
            errorMessage = nil
            await maybeScheduleLocalNotification(for: digest)
            return
        }

        if !forceRefresh, let cached = Self.loadDigest(scope: scope, defaults: defaults), Self.isSameRelease(cached.id, targetWindow.id) {
            digest = cached
            errorMessage = nil
            await maybeScheduleLocalNotification(for: cached)
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // A missing or unreachable published digest is not fatal: fall back to building
            // one on the device. If that also fails, the error below is shown to the user.
            let remote: WeeklyDigest?
            do {
                remote = try await digestService.fetchLatest()
            } catch {
                if APIErrorResponse.isCancellation(error) { throw CancellationError() }
                remote = nil
                logger.warning("Published weekly digest unavailable, building locally: \(String(describing: error), privacy: .public)")
            }

            if let remote,
               remote.publishedAt <= Date(),
               Self.matches(remote, window: targetWindow) {
                let normalized = normalizeReadState(for: remote)
                digest = normalized
                noBriefReleaseID = nil
                persistDigest(normalized)
                await maybeScheduleLocalNotification(for: normalized)
                return
            }

            if let local = try await LocalWeeklyDigestBuilder.build(
                profile: profile,
                window: targetWindow,
                services: services
            ) {
                let normalized = normalizeReadState(for: local)
                digest = normalized
                noBriefReleaseID = nil
                persistDigest(normalized)
                await maybeScheduleLocalNotification(for: normalized)
            } else {
                digest = nil
                noBriefReleaseID = targetWindow.id
                clearPersistedDigest()
            }
        } catch {
            if APIErrorResponse.isCancellation(error) { return }
            // The previous digest (if any) stays on screen; views check `isShowingStaleDigest`
            // so an earlier week's brief is not presented as current.
            errorMessage = UserFacingLoadError.message(for: error, loading: "this week's brief")
            logger.error("Weekly digest refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The new brief keeps the read state of the one on screen for the same week, whichever wrote it: a brief
    /// opened as the on-device version stays read when the server's arrives.
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

    private static func lastNotifiedDigestKey(scope: String) -> String {
        "BillBoard.weeklyDigest.v1.lastNotified.\(scope)"
    }

    static func clearCache(scope: String?, defaults: UserDefaults = .standard) {
        guard let scope = scope.trimmedNonEmpty else { return }
        defaults.removeObject(forKey: digestKey(scope: scope))
        defaults.removeObject(forKey: settingsKey(scope: scope))
        defaults.removeObject(forKey: lastNotifiedDigestKey(scope: scope))
    }

    nonisolated static func shouldScheduleNotification(
        for digest: WeeklyDigest,
        digestNotificationsEnabled: Bool,
        appNotificationsEnabled: Bool,
        lastNotifiedDigestID: String?
    ) -> Bool {
        guard digestNotificationsEnabled else { return false }
        guard appNotificationsEnabled else { return false }
        guard !digest.isRead else { return false }
        guard let lastNotifiedDigestID else { return true }
        return !isSameRelease(lastNotifiedDigestID, digest.id)
    }

    /// Whether two brief ids are the same week's. The server's id is its Sunday 10 AM ET release time from
    /// `toISOString()` ("2026-10-25T14:00:00.000Z"); the app writes the same time in New York time for its
    /// window and the on-device brief ("2026-10-25T10:00:00-04:00"). Compared as text they never matched, so
    /// the app downloaded the server's brief again on every Updates visit (feature review N2). Ids that are not
    /// dates are compared as text.
    nonisolated static func isSameRelease(_ id: String, _ otherID: String) -> Bool {
        if id == otherID { return true }
        guard let release = FlexibleISO8601.parse(id), let otherRelease = FlexibleISO8601.parse(otherID) else { return false }
        return abs(release.timeIntervalSince(otherRelease)) < 1
    }

    nonisolated static func notificationBody(for digest: WeeklyDigest) -> String {
        let cleanedSummary = digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedSummary.isEmpty {
            return String(cleanedSummary.prefix(160))
        }
        return "\(digest.totalItemCount) updates from \(WeeklyDigestDateFormatter.rangeString(start: digest.weekStart, end: digest.weekEnd))."
    }

    nonisolated static func notificationUserInfo(for digest: WeeklyDigest) -> [AnyHashable: Any] {
        [
            "domain": "weekly_digest",
            "notificationType": "digest",
            "digestId": digest.id
        ]
    }

    private func maybeScheduleLocalNotification(for digest: WeeklyDigest) async {
        let appNotificationsEnabled = defaults.object(forKey: AppNotificationStorage.notificationsEnabledKey) as? Bool ?? true
        let lastNotifiedDigestID = defaults.string(forKey: Self.lastNotifiedDigestKey(scope: scope))
        guard Self.shouldScheduleNotification(
            for: digest,
            digestNotificationsEnabled: settings.isEnabled,
            appNotificationsEnabled: appNotificationsEnabled,
            lastNotifiedDigestID: lastNotifiedDigestID
        ) else {
            return
        }

        let authorizationStatus = await Self.notificationAuthorizationStatus()
        guard Self.isAuthorizedForLocalNotifications(authorizationStatus) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your Weekly Brief is ready"
        content.subtitle = digest.title
        content.body = Self.notificationBody(for: digest)
        content.sound = .default
        content.threadIdentifier = "weekly-digest"
        content.categoryIdentifier = "weekly-digest"
        content.userInfo = Self.notificationUserInfo(for: digest)

        let request = UNNotificationRequest(
            identifier: "weekly-digest.\(scope).\(digest.id)",
            content: content,
            trigger: nil
        )

        do {
            try await Self.addNotificationRequest(request)
            defaults.set(digest.id, forKey: Self.lastNotifiedDigestKey(scope: scope))
            logger.info("Scheduled local weekly digest notification for digestId=\(digest.id, privacy: .public)")
        } catch {
            logger.error("Failed to schedule local weekly digest notification: \(String(describing: error), privacy: .public)")
        }
    }

    private static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private static func isAuthorizedForLocalNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func addNotificationRequest(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
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

private enum LocalWeeklyDigestBuilder {
    /// The API services the on-device fallback reads.
    struct Services {
        let bills: any BillsServicing
        let votes: any BillVotesServicing
        let congress: any CongressServicing
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BillBoard", category: "weeklyDigest")

    private struct Candidate {
        let manifest: BillsManifestItem
        let watched: Bool
        let topicMatches: [String]
        let lifeAreaMatches: [String]
        let matchingMemberIDs: [String]
        let baseScore: Int
        /// The guids whose votes count for this candidate: its own, or every member of its companion
        /// group (APPF-23).
        var voteGuids: [String]
    }

    private struct RankedCandidate {
        let manifest: BillsManifestItem
        let bill: Bill
        let watched: Bool
        let userPreviouslyVoted: Bool
        let topicMatches: [String]
        let lifeAreaMatches: [String]
        let matchingMemberIDs: [String]
        let score: Int
    }

    private struct MemberActivity {
        let id: String
        let name: String
        let billCount: Int
        let topCandidate: RankedCandidate
    }

    /// What the user follows, normalized once for matching manifest items.
    private struct Interests {
        let allowedContentTypes: Set<BillContentTypePreference>
        let followedMemberIDs: Set<UUID>
        let watchedGuids: Set<String>
        let subscribedTopics: Set<String>
        let subscribedLifeAreas: Set<String>

        init(profile: UserProfile) {
            allowedContentTypes = profile.effectiveSelectedBillContentTypes
            followedMemberIDs = Set(profile.subscribedMemberIDs)
            watchedGuids = Set(profile.watchedBillGUIDs)
            subscribedTopics = Set(profile.subscribedSubCategories.map(LocalWeeklyDigestBuilder.normalize))
            subscribedLifeAreas = Set(profile.subscribedLifeAreas.map(LocalWeeklyDigestBuilder.normalize))
        }
    }

    /// The items of the four brief sections. A bill appears in at most one bill section.
    private struct SectionItems {
        let needsAttention: [WeeklyDigestItem]
        let movedThisWeek: [WeeklyDigestItem]
        let representatives: [WeeklyDigestItem]
        let worthQuickLook: [WeeklyDigestItem]
    }

    static func build(profile: UserProfile, window: DigestPublicationWindow, services: Services) async throws -> WeeklyDigest? {
        let interests = Interests(profile: profile)
        let memberNameByID = try await memberNames(followedMemberIDs: interests.followedMemberIDs, congress: services.congress)

        // One item per bill: legacy text-version duplicates merged (`deduplicateManifest`), then each
        // companion group (APPF-23) collapsed to the member that moved most recently.
        let manifestItems = BillsStore.deduplicateManifest(try await services.bills.getBillsManifest(updatedAfter: window.start))
        let companions = CompanionGroupIndex(groups: services.bills.cachedCompanionGroups() ?? [])
        let candidates = collapsedByCompanionGroup(
            manifestItems.compactMap { makeCandidate(from: $0, window: window, interests: interests) },
            companions: companions
        )
        .sorted(by: ranksBefore)

        guard !candidates.isEmpty else { return nil }

        let shortlisted = Array(candidates.prefix(60))
        let voteStates = (try? await services.votes.fetchFeedback(billIds: uniqueGuids(shortlisted.flatMap(\.voteGuids)))) ?? [:]
        // This vote fetch and the bill fetches below swallow their failures; a cancelled refresh must not
        // build (and persist) a brief from what they did not load (APPF-22).
        try Task.checkCancellation()

        let rescored = shortlisted
            .map { rescore($0, voteState: groupVoteState($0, voteStates: voteStates)) }
            .sorted(by: ranksBefore)

        let topCandidates = Array(rescored.prefix(10))
        let hydrated = await hydrate(topCandidates, using: services.bills)
        try Task.checkCancellation()

        let ranked: [RankedCandidate] = topCandidates.map { candidate in
            let guid = candidate.manifest.guid
            let bill = hydrated[guid] ?? placeholderBill(from: candidate.manifest)
            // A group counts as voted when any member is.
            let userPreviouslyVoted: Bool
            if case .voted = groupVoteState(candidate, voteStates: voteStates) {
                userPreviouslyVoted = true
            } else {
                userPreviouslyVoted = false
            }

            return RankedCandidate(
                manifest: candidate.manifest,
                bill: bill,
                watched: candidate.watched,
                userPreviouslyVoted: userPreviouslyVoted,
                topicMatches: candidate.topicMatches,
                lifeAreaMatches: candidate.lifeAreaMatches,
                matchingMemberIDs: candidate.matchingMemberIDs,
                score: candidate.baseScore
            )
        }

        guard !ranked.isEmpty else { return nil }

        let items = sectionItems(from: ranked, window: window, memberNameByID: memberNameByID)
        return makeDigest(from: items, window: window)
    }

    /// Member names keyed by upper-cased bioguide ID, from the cached or fetched members manifest.
    private static func memberNames(
        followedMemberIDs: Set<UUID>,
        congress: any CongressServicing
    ) async throws -> [String: String] {
        var congressManifest = congress.cachedCongressMembersManifest()
        if congressManifest == nil {
            do {
                congressManifest = try await congress.getCongressMembersManifest()
            } catch {
                if APIErrorResponse.isCancellation(error) { throw CancellationError() }
                // Member names are required to describe followed representatives; without
                // them the brief would show raw IDs, so surface the failure instead.
                guard followedMemberIDs.isEmpty else { throw error }
                logger.warning("Congress members manifest unavailable for weekly digest: \(String(describing: error), privacy: .public)")
            }
        }

        var memberNameByID: [String: String] = [:]
        for member in congressManifest ?? [] {
            let key = member.id.uppercased()
            if memberNameByID[key] == nil || !member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                memberNameByID[key] = member.name
            }
        }
        return memberNameByID
    }

    /// A manifest item updated during the window that matches something the user follows, or nil.
    private static func makeCandidate(
        from item: BillsManifestItem,
        window: DigestPublicationWindow,
        interests: Interests
    ) -> Candidate? {
        guard BillContentTypePreference.allows(rawBillType: item.billType, allowed: interests.allowedContentTypes) else {
            return nil
        }

        guard let updatedAt = FlexibleISO8601.parse(item.updatedAt),
              updatedAt >= window.start,
              updatedAt < WeeklyDigestSchedule.calendar.date(byAdding: .day, value: 1, to: window.end) ?? window.end else {
            return nil
        }

        let watched = interests.watchedGuids.contains(item.guid)
        let topicMatches = item.subCategories.filter { interests.subscribedTopics.contains(normalize($0)) }
        let lifeAreaMatches = item.lifeAreas.filter { interests.subscribedLifeAreas.contains(normalize($0)) }

        let matchingMembers = Array(
            Set(item.sponsors + item.cosponsors)
                .filter { interests.followedMemberIDs.contains(UUID.deterministic(from: $0)) }
                .map { $0.uppercased() }
        ).sorted()

        guard watched || !topicMatches.isEmpty || !lifeAreaMatches.isEmpty || !matchingMembers.isEmpty else {
            return nil
        }

        var score = 0
        if watched { score += 120 }
        if !matchingMembers.isEmpty { score += 85 + (matchingMembers.count * 10) }
        if !topicMatches.isEmpty { score += 55 + (topicMatches.count * 5) }
        if !lifeAreaMatches.isEmpty { score += 35 + (lifeAreaMatches.count * 4) }
        score += statusScore(for: BillStatus(rawValue: item.billStatus ?? "") ?? .new)

        return Candidate(
            manifest: item,
            watched: watched,
            topicMatches: topicMatches,
            lifeAreaMatches: lifeAreaMatches,
            matchingMemberIDs: matchingMembers,
            baseScore: score,
            voteGuids: [item.guid]
        )
    }

    /// One candidate per companion group (APPF-23): the member that moved most recently in the
    /// window (ties to the primary), watched when any member is, with the members' matches combined,
    /// the highest member score and every member's guid for the vote lookup. Ungrouped candidates
    /// pass through; with no groups the input is returned as it is.
    private static func collapsedByCompanionGroup(_ candidates: [Candidate], companions: CompanionGroupIndex) -> [Candidate] {
        guard !companions.isEmpty else { return candidates }
        var order: [String] = []
        var byKey: [String: [Candidate]] = [:]
        for candidate in candidates {
            let key = companions.group(forGUID: candidate.manifest.guid)?.primaryGuid ?? "bill|\(candidate.manifest.guid)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(candidate)
        }

        return order.compactMap { key -> Candidate? in
            guard let members = byKey[key], let first = members.first else { return nil }
            guard let group = companions.group(forGUID: first.manifest.guid) else { return first }
            let chosen = members.max { lhs, rhs in
                let left = FlexibleISO8601.parse(lhs.manifest.updatedAt) ?? .distantPast
                let right = FlexibleISO8601.parse(rhs.manifest.updatedAt) ?? .distantPast
                if left != right { return left < right }
                // Equal dates: the primary wins (it sorts as the larger element).
                return companions.isPrimary(guid: rhs.manifest.guid) && !companions.isPrimary(guid: lhs.manifest.guid)
            } ?? first
            return Candidate(
                manifest: chosen.manifest,
                watched: members.contains(where: \.watched),
                topicMatches: uniqueGuids(members.flatMap(\.topicMatches)),
                lifeAreaMatches: uniqueGuids(members.flatMap(\.lifeAreaMatches)),
                matchingMemberIDs: uniqueGuids(members.flatMap(\.matchingMemberIDs)).sorted(),
                baseScore: members.map(\.baseScore).max() ?? chosen.baseScore,
                voteGuids: uniqueGuids(group.memberGuids + members.map(\.manifest.guid))
            )
        }
    }

    /// The candidate's vote state: the first of its vote guids with a vote, else its own guid's state.
    private static func groupVoteState(
        _ candidate: Candidate,
        voteStates: [String: BillVotesService.RemoteVoteState]
    ) -> BillVotesService.RemoteVoteState? {
        for guid in candidate.voteGuids {
            if case .voted = voteStates[guid] { return voteStates[guid] }
        }
        return voteStates[candidate.manifest.guid]
    }

    /// `values` without repeats, in order.
    private static func uniqueGuids(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// A decided bill ranks first: one that became law (Finalized, REL-44) like a passed or failed one.
    private static func statusScore(for status: BillStatus) -> Int {
        switch status {
        case .passed, .finalized, .failed:
            return 70
        case .updated:
            return 35
        case .new:
            return 20
        }
    }

    /// Raises a candidate the user already voted on, most of all when the bill has changed since.
    private static func rescore(_ candidate: Candidate, voteState: BillVotesService.RemoteVoteState?) -> Candidate {
        guard case .voted = voteState else { return candidate }
        let status = BillStatus(rawValue: candidate.manifest.billStatus ?? "") ?? .new
        let bonus: Int
        switch status {
        case .updated:
            bonus = 110
        case .passed, .finalized, .failed:
            bonus = 55
        case .new:
            bonus = 24
        }

        return Candidate(
            manifest: candidate.manifest,
            watched: candidate.watched,
            topicMatches: candidate.topicMatches,
            lifeAreaMatches: candidate.lifeAreaMatches,
            matchingMemberIDs: candidate.matchingMemberIDs,
            baseScore: candidate.baseScore + bonus,
            voteGuids: candidate.voteGuids
        )
    }

    /// Higher score first; ties by title.
    private static func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.baseScore == rhs.baseScore {
            return lhs.manifest.title.localizedCaseInsensitiveCompare(rhs.manifest.title) == .orderedAscending
        }
        return lhs.baseScore > rhs.baseScore
    }

    private static func sectionItems(
        from ranked: [RankedCandidate],
        window: DigestPublicationWindow,
        memberNameByID: [String: String]
    ) -> SectionItems {
        var consumed = Set<String>()

        let needsAttention = ranked
            .filter { rankedItem in
                let state = rankedItem.bill.billStatus
                // Decided: Passed, Became law (Finalized) or Failed.
                return rankedItem.watched || (rankedItem.userPreviouslyVoted && state == .updated) || state.isDecided
            }
            .prefix(3)
            .map {
                consumed.insert($0.bill.guid ?? $0.manifest.guid)
                return makeBillItem(from: $0, window: window, memberNameByID: memberNameByID, accent: .attention)
            }

        let movedThisWeek = ranked
            .filter { !(consumed.contains($0.bill.guid ?? $0.manifest.guid)) }
            .prefix(3)
            .map {
                consumed.insert($0.bill.guid ?? $0.manifest.guid)
                return makeBillItem(from: $0, window: window, memberNameByID: memberNameByID, accent: .movement)
            }

        let representativeRows = buildMemberActivityRows(from: ranked, memberNameByID: memberNameByID)
            .prefix(3)
            .map { activity in
                WeeklyDigestItem(
                    id: "member|\(activity.id)|\(activity.topCandidate.manifest.guid)",
                    kind: .member,
                    title: activity.name,
                    eyebrow: activity.billCount == 1 ? "1 relevant bill this week" : "\(activity.billCount) relevant bills this week",
                    summary: activity.billCount == 1
                        ? "Backed a bill on topics you follow."
                        : "Backed \(activity.billCount) bills on topics you follow.",
                    detail: "Top bill: \(activity.topCandidate.bill.title)",
                    reason: "Member you follow",
                    accent: .representative,
                    billState: nil,
                    billGuid: activity.topCandidate.bill.guid ?? activity.topCandidate.manifest.guid,
                    primaryMemberBioguideID: activity.id
                )
            }

        let worthQuickLook = ranked
            .filter { candidate in
                let guid = candidate.bill.guid ?? candidate.manifest.guid
                guard !consumed.contains(guid) else { return false }
                return !candidate.watched && !candidate.userPreviouslyVoted && candidate.bill.billStatus == .new
            }
            .prefix(2)
            .map {
                consumed.insert($0.bill.guid ?? $0.manifest.guid)
                return makeBillItem(from: $0, window: window, memberNameByID: memberNameByID, accent: .discovery)
            }

        return SectionItems(
            needsAttention: needsAttention,
            movedThisWeek: movedThisWeek,
            representatives: representativeRows,
            worthQuickLook: worthQuickLook
        )
    }

    private static func makeDigest(from items: SectionItems, window: DigestPublicationWindow) -> WeeklyDigest? {
        let needsAttention = items.needsAttention
        let movedThisWeek = items.movedThisWeek
        let representativeRows = items.representatives
        let worthQuickLook = items.worthQuickLook

        let sections = [
            WeeklyDigestSection(
                kind: .needsAttention,
                title: "Needs Your Attention",
                subtitle: needsAttention.isEmpty ? nil : "The biggest changes from the week.",
                items: Array(needsAttention)
            ),
            WeeklyDigestSection(
                kind: .movedThisWeek,
                title: "What Moved This Week",
                subtitle: movedThisWeek.isEmpty ? nil : "Changes on topics you follow.",
                items: Array(movedThisWeek)
            ),
            WeeklyDigestSection(
                kind: .representatives,
                title: "Members You Follow This Week",
                subtitle: representativeRows.isEmpty ? nil : "Who backed bills on topics you follow.",
                items: Array(representativeRows)
            ),
            WeeklyDigestSection(
                kind: .worthQuickLook,
                title: "Worth A Quick Look",
                subtitle: worthQuickLook.isEmpty ? nil : "A couple of strong matches you may have missed.",
                items: Array(worthQuickLook)
            )
        ]
        .filter { !$0.items.isEmpty }

        guard !sections.isEmpty else { return nil }

        let attentionCount = needsAttention.count
        let representativesCount = representativeRows.count
        let quickLookCount = worthQuickLook.count

        let summary = makeSummary(
            attentionCount: attentionCount,
            representativesCount: representativesCount,
            quickLookCount: quickLookCount,
            movedCount: movedThisWeek.count
        )

        let stats = [
            WeeklyDigestStat(
                id: "attention",
                label: "Need attention",
                value: "\(attentionCount)",
                accent: .attention
            ),
            WeeklyDigestStat(
                id: "representatives",
                label: "Members active",
                value: "\(representativesCount)",
                accent: .representative
            ),
            WeeklyDigestStat(
                id: "quicklook",
                label: "Worth a look",
                value: "\(quickLookCount)",
                accent: .discovery
            )
        ]

        return WeeklyDigest(
            id: window.id,
            title: WeeklyDigestDateFormatter.title(weekStart: window.start, weekEnd: window.end),
            summary: summary,
            weekStart: window.start,
            weekEnd: window.end,
            publishedAt: window.releaseAt,
            source: .localFallback,
            isRead: false,
            stats: stats,
            sections: sections
        )
    }

    private static func hydrate(_ candidates: [Candidate], using bills: any BillsServicing) async -> [String: Bill] {
        await withTaskGroup(of: (String, Bill)?.self, returning: [String: Bill].self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        let processed = try await bills.getProcessedBill(
                            guid: candidate.manifest.guid,
                            congress: candidate.manifest.congress,
                            billType: candidate.manifest.billType,
                            billID: candidate.manifest.billID
                        )
                        return (candidate.manifest.guid, processed)
                    } catch {
                        return nil
                    }
                }
            }

            var results: [String: Bill] = [:]
            for await item in group {
                if let item {
                    results[item.0] = item.1
                }
            }
            return results
        }
    }

    private static func buildMemberActivityRows(
        from ranked: [RankedCandidate],
        memberNameByID: [String: String]
    ) -> [MemberActivity] {
        var grouped: [String: [RankedCandidate]] = [:]
        for candidate in ranked {
            for memberID in candidate.matchingMemberIDs {
                grouped[memberID, default: []].append(candidate)
            }
        }

        return grouped.compactMap { key, candidates in
            guard let top = candidates.sorted(by: { $0.score > $1.score }).first else { return nil }
            let name = memberNameByID[key] ?? key
            return MemberActivity(
                id: key,
                name: name,
                billCount: Set(candidates.map { $0.bill.guid ?? $0.manifest.guid }).count,
                topCandidate: top
            )
        }
        .sorted { lhs, rhs in
            if lhs.billCount == rhs.billCount {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.billCount > rhs.billCount
        }
    }

    private static func makeBillItem(
        from candidate: RankedCandidate,
        window: DigestPublicationWindow,
        memberNameByID: [String: String],
        accent: WeeklyDigestItem.Accent
    ) -> WeeklyDigestItem {
        let bill = candidate.bill
        let guid = bill.guid ?? candidate.manifest.guid
        let updatedAt = FlexibleISO8601.parse(bill.storedAt) ?? FlexibleISO8601.parse(candidate.manifest.updatedAt)
        let eyebrow = [
            statusLabel(for: bill.billStatus),
            updatedAt.map { WeeklyDigestDateFormatter.shortDate($0) }
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let summary = firstNonEmpty(
            bill.summary,
            bill.billBreakdown?.what,
            candidate.manifest.title
        ) ?? candidate.manifest.title

        let detail = firstNonEmpty(
            bill.soWhat,
            mostRelevantActionText(in: bill, during: window),
            defaultChangeLine(for: bill.billStatus)
        )

        let reason: String? = {
            if candidate.watched { return "You're watching this" }
            if candidate.userPreviouslyVoted && bill.billStatus == .updated { return "You voted on this before" }
            if let memberID = candidate.matchingMemberIDs.first, let name = memberNameByID[memberID] {
                return "Backed by \(name)"
            }
            if let topic = candidate.topicMatches.first { return "Matches your topic: \(topic)" }
            if let lifeArea = candidate.lifeAreaMatches.first { return "Matches your life area: \(lifeArea)" }
            switch bill.billStatus {
            case .passed: return "Passed this week"
            case .finalized: return "Became law this week"
            case .failed: return "Failed this week"
            case .new, .updated: return nil
            }
        }()

        return WeeklyDigestItem(
            id: "bill|\(guid)",
            kind: .bill,
            title: bill.title,
            eyebrow: eyebrow.isEmpty ? nil : eyebrow,
            summary: summary,
            detail: detail,
            reason: reason,
            accent: accent,
            billState: digestState(for: bill.billStatus),
            billGuid: guid,
            primaryMemberBioguideID: candidate.matchingMemberIDs.first
        )
    }

    private static func digestState(for status: BillStatus) -> WeeklyDigestItem.BillState {
        switch status {
        case .new:
            return .new
        case .updated:
            return .updated
        case .passed:
            return .passed
        case .failed:
            return .failed
        case .finalized:
            return .finalized
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func defaultChangeLine(for status: BillStatus) -> String {
        switch status {
        case .new:
            return "New this week."
        case .updated:
            return "Updated this week."
        case .passed:
            return "Passed this week."
        case .failed:
            return "Failed this week."
        case .finalized:
            return "Became law this week."
        }
    }

    private static func mostRelevantActionText(in bill: Bill, during window: DigestPublicationWindow) -> String? {
        let dayAfterWeekEnd = WeeklyDigestSchedule.calendar.date(byAdding: .day, value: 1, to: window.end) ?? window.end
        let filtered = bill.actions
            .filter { action in
                guard let date = FlexibleISO8601.parse(action.actionDate) else { return false }
                return date >= window.start && date < dayAfterWeekEnd
            }
            .sorted { lhs, rhs in
                let left = FlexibleISO8601.parse(lhs.actionDate) ?? .distantPast
                let right = FlexibleISO8601.parse(rhs.actionDate) ?? .distantPast
                return left > right
            }

        return filtered
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    /// The eyebrow's status word: "Became law" for Finalized.
    private static func statusLabel(for status: BillStatus) -> String {
        status.displayLabel
    }

    private static func makeSummary(
        attentionCount: Int,
        representativesCount: Int,
        quickLookCount: Int,
        movedCount: Int
    ) -> String {
        var clauses: [String] = []

        if attentionCount > 0 {
            clauses.append(attentionCount == 1 ? "One bill needs your attention" : "\(attentionCount) bills need your attention")
        }

        if representativesCount > 0 {
            clauses.append(representativesCount == 1 ? "one member you follow took action" : "\(representativesCount) members you follow took action")
        }

        if quickLookCount > 0 {
            clauses.append(quickLookCount == 1 ? "one more bill is worth a look" : "\(quickLookCount) more bills are worth a look")
        }

        if clauses.isEmpty {
            return movedCount == 1 ? "One change on topics you follow." : "\(movedCount) changes on topics you follow."
        }

        if clauses.count == 1 {
            return clauses[0] + "."
        }

        if clauses.count == 2 {
            return "\(clauses[0]), and \(clauses[1])."
        }

        return "\(clauses[0]), \(clauses[1]), and \(clauses[2])."
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func placeholderBill(from item: BillsManifestItem) -> Bill {
        let id = UUID.deterministic(from: item.guid)
        let subCategory = item.subCategories.first
        let mappedCategory = SubscriptionsConfig.subcategoryGroups
            .first(where: { group in
                guard let subCategory else { return false }
                return group.value.contains(subCategory)
            })?.key

        return Bill(
            id: id,
            title: item.title,
            category: mappedCategory ?? (subCategory ?? "Other"),
            subCategory: subCategory,
            summary: "",
            soWhat: "",
            storedAt: item.updatedAt,
            actions: [],
            committees: [],
            lifeAreas: item.lifeAreas,
            billStatus: BillStatus(rawValue: item.billStatus ?? "") ?? .new,
            guid: item.guid,
            congress: item.congress,
            billType: item.billType,
            billID: item.billID,
            sponsorMemberID: item.sponsors.first.map { UUID.deterministic(from: $0) },
            userVoted: false,
            userWatched: false,
            isProcessedDetailHydrated: false
        )
    }
}
