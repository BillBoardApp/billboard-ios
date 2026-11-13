import SwiftUI

/// Tells when the app has come back from the background (UX-39 N11). Launch starts active, and a Control
/// Center pull or a system alert takes the scene through inactive only; neither counts as a return.
struct ForegroundReturnDetector: Equatable {
    private(set) var hasBeenInBackground = false

    /// True when `phase` is the scene becoming active after it was in the background.
    mutating func didReturn(to phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            hasBeenInBackground = true
            return false
        case .active:
            defer { hasBeenInBackground = false }
            return hasBeenInBackground
        default:
            return false
        }
    }
}

/// Reads the Civic Score (the masthead chips and the Civic Rank sheet, with the streak) and the Civic
/// Profile again besides launch and a saved vote (UX-39 N11): when the app returns from the background,
/// and when the day turns over in America/New_York while it is open, so a streak broken overnight does not
/// show the next morning. Profile's pull to refresh reads them too. UI-test launches stay off the network,
/// as at launch.
struct CivicStatsRefresh: ViewModifier {
    let scoreStore: CivicScoreStore
    let profileStore: CivicProfileStore

    @Environment(\.scenePhase) private var scenePhase
    @State private var foreground = ForegroundReturnDetector()
    @State private var day = EasternDay.key(for: .now)

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                guard foreground.didReturn(to: phase) else { return }
                day = EasternDay.key(for: .now)
                refresh()
            }
            .task(id: day) {
                // Until the next Eastern midnight; a timer that fires a little early waits again.
                while !Task.isCancelled, EasternDay.key(for: .now) == day {
                    let wait = EasternDay.nextStart(after: .now).timeIntervalSinceNow
                    try? await Task.sleep(for: .seconds(max(wait, 1)))
                }
                guard !Task.isCancelled else { return }
                refresh()
                day = EasternDay.key(for: .now)
            }
    }

    /// Unstructured, so a new `day` (which ends this task) or a return to the app does not cancel a read.
    private func refresh() {
        guard !AppLaunchOptions.shouldStreamlineStartupForUITests else { return }
        Task { await scoreStore.refresh() }
        Task { await profileStore.refresh() }
    }
}

extension View {
    /// Reads the Civic Score and Civic Profile again on a return to the app and on a new Eastern day.
    func refreshesCivicStats(score: CivicScoreStore, profile: CivicProfileStore) -> some View {
        modifier(CivicStatsRefresh(scoreStore: score, profileStore: profile))
    }
}
