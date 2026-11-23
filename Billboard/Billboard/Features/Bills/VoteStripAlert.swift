import SwiftUI

private nonisolated struct VoteStripAlertKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    /// Runs each time bill detail's vote strip comes up with the error haptic and VoiceOver's focus (spec 3.10.2): a
    /// refusal, or a vote whose write has just failed on the page (UX-49). A strip shown because the page opened on a
    /// vote not saved yet (APPF-30 step 2) is quiet and never runs it. Tests put a recorder here.
    var voteStripAlert: @MainActor @Sendable () -> Void {
        get { self[VoteStripAlertKey.self] }
        set { self[VoteStripAlertKey.self] = newValue }
    }
}
