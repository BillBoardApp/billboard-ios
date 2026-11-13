import Combine
import Foundation

/// SwiftUI-friendly store for the user's Civic Profile (radar chart data).
///
/// Views observe `profile`, `isLoading`, and `phase` (UX-39 N11: `profile` is `.empty`, a locked profile
/// with no votes, until the first read ends, so Profile shows a loading line, not "Vote on 25 more
/// bills"). Call `refresh()` to fetch the latest profile from the server.
@MainActor
final class CivicProfileStore: ObservableObject {
    @Published private(set) var profile: CivicProfileResponse = .empty
    @Published private(set) var isLoading: Bool = false

    /// User-facing error message for the most recent failed fetch (R2's copy, `UserFacingLoadError`).
    @Published var lastError: String?

    /// Tracks whether the store has completed at least one successful refresh.
    @Published private(set) var hasRefreshedOnce: Bool = false

    /// A vote was saved while a read was running, so the store reads once more after it.
    private var readsAgainAfterCurrent = false

    /// What Profile's Civic Profile section may show (UX-39 N11).
    var phase: CivicLoadPhase {
        CivicLoadPhase.of(hasLoaded: hasRefreshedOnce, lastError: lastError)
    }

    private let service: any CivicServicing

    init(service: any CivicServicing = CivicService.Live()) {
        self.service = service
    }

    /// Reads the profile. A call while a read runs joins it, except `afterSavedVote`: a vote saved during
    /// the read may not be in it, so the store reads once more when it ends.
    ///
    /// The read runs in the store's own task: a screen that goes away (a tab switched, which cancels its
    /// task) must not cancel a read that another refresh has joined, or Profile would stay on its loading
    /// line with no read left running (UX-39 N11).
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
            profile = try await service.fetchCivicProfile()
            hasRefreshedOnce = true
        } catch {
            if APIErrorResponse.isCancellation(error) { return }
            lastError = UserFacingLoadError.message(for: error, loading: "your Civic Profile")
            #if DEBUG
            print(">>> [CivicProfileStore] refresh failed: \(error.localizedDescription)")
            #endif
        }
    }
}
