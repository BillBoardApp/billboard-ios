import Foundation

/// The Weekly Brief reads the tabs make (UX-28), apart from `TabsBar` so tests can drive them: the first read, once
/// the profile has loaded with its id, and after it a read on each return to the app. A later change to the profile
/// reads nothing: the server writes each person's brief on Sunday and keeps it as written all week.
///
/// A later read is kept, so the tabs cancel it when they go at sign-out (`cancel`). The store also writes nothing
/// for an account that signed out after it was made, so a read that answers late leaves nothing on the device.
@MainActor
final class WeeklyBriefReads {
    private(set) var hasCompletedFirstRead = false
    /// The read started by `readAgain`, until it finishes.
    private(set) var laterRead: Task<Void, Never>?

    /// The first read, once the profile has loaded (`profileHasLoaded`) with an id. A profile load that leaves no
    /// id leaves it to the next load.
    func firstReadIfReady(store: WeeklyDigestStore, profile: UserProfile, profileHasLoaded: Bool) async {
        guard profileHasLoaded, !hasCompletedFirstRead else { return }
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await store.refresh(profile: profile)
        hasCompletedFirstRead = true
    }

    /// A read on a return to the app: this week's brief if it is not here yet
    /// (`WeeklyDigestStore.refreshOnReturnToApp`). Nothing before the first read, and nothing while one is out.
    func readAgain(store: WeeklyDigestStore, profile: UserProfile) {
        guard hasCompletedFirstRead, laterRead == nil else { return }
        laterRead = Task { [weak self] in
            defer { self?.laterRead = nil }
            await store.refreshOnReturnToApp(profile: profile)
        }
    }

    /// Stops the read that is out, when the tabs go (sign-out or a switch of account).
    func cancel() {
        laterRead?.cancel()
    }
}
