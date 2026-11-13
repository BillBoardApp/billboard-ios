import Combine
import Foundation

/// SwiftUI-friendly store for the user's Civic Score.
///
/// Views observe `score`, `isLoading`, and `phase` (UX-39 N11: no rank or figures from `.empty` before the
/// first read ends). Call `refresh()` to fetch the latest score from the server.
@MainActor
final class CivicScoreStore: ObservableObject {
    private enum CacheKeys {
        static let legacyLatestCivicScore = "billboard.civicScore.latest.v2"
    }

    private let scope: String?
    private let userDefaults: UserDefaults
    private let service: any CivicServicing

    @Published private(set) var score: CivicScore = .empty
    @Published private(set) var isLoading: Bool = false

    /// User-facing error message for the most recent failed fetch (R2's copy, `UserFacingLoadError`).
    @Published var lastError: String?

    /// Tracks whether the store holds a real score: one read from the server, or this user's cached one.
    @Published private(set) var hasRefreshedOnce: Bool = false

    /// A vote was saved while a read was running, so the store reads once more after it.
    private var readsAgainAfterCurrent = false

    /// What the chips and the Civic Rank sheet may show (UX-39 N11).
    var phase: CivicLoadPhase {
        CivicLoadPhase.of(hasLoaded: hasRefreshedOnce, lastError: lastError)
    }

    init(
        scope: String? = nil,
        userDefaults: UserDefaults = .standard,
        service: any CivicServicing = CivicService.Live()
    ) {
        self.scope = ScopedStorageKey.normalizedScope(scope)
        self.userDefaults = userDefaults
        self.service = service
        if self.scope != nil {
            Self.clearLegacyCache(userDefaults: userDefaults)
        }
        restoreFromCache()
    }

    /// Reads the score. A call while a read runs joins it, except `afterSavedVote`: a vote saved during the
    /// read may not be in it, so the store reads once more when it ends and the new vote counts.
    ///
    /// The read runs in the store's own task: a caller that goes away (the Civic Rank sheet closed, which
    /// cancels its task) must not cancel a read that another refresh, such as the launch read, has joined,
    /// or the chips would wait on "–" with no read left running (UX-39 N11).
    func refresh(afterSavedVote: Bool = false) async {
        guard !isLoading else {
            if afterSavedVote { readsAgainAfterCurrent = true }
            return
        }
        isLoading = true
        await Task { await readUntilCurrent() }.value
    }

    private func readUntilCurrent() async {
        defer { isLoading = false }

        repeat {
            readsAgainAfterCurrent = false
            lastError = nil
            await read()
        } while readsAgainAfterCurrent
    }

    private func read() async {
        do {
            let latest = try await service.fetchCivicScore()
            score = latest
            cache(latest)
            hasRefreshedOnce = true
        } catch {
            if APIErrorResponse.isCancellation(error) { return }
            lastError = UserFacingLoadError.message(for: error, loading: "your Civic Rank")
            #if DEBUG
            print(">>> [CivicScoreStore] refresh failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func restoreFromCache() {
        guard
            let data = userDefaults.data(forKey: cacheKey),
            let cached = try? JSONDecoder.usingDefaultKeys().decode(CivicScore.self, from: data)
        else {
            return
        }

        score = cached
        hasRefreshedOnce = true
    }

    private func cache(_ latest: CivicScore) {
        guard let data = try? JSONEncoder().encode(latest) else { return }
        userDefaults.set(data, forKey: cacheKey)
    }

    private var cacheKey: String {
        Self.cacheKey(scope: scope)
    }

    private static func cacheKey(scope: String?) -> String {
        ScopedStorageKey.make(base: CacheKeys.legacyLatestCivicScore, scope: scope)
    }

    static func clearCache(scope: String?, userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: cacheKey(scope: scope))
        if ScopedStorageKey.normalizedScope(scope) != nil {
            clearLegacyCache(userDefaults: userDefaults)
        }
    }

    static func clearLegacyCache(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: CacheKeys.legacyLatestCivicScore)
    }
}
