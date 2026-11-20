import SwiftUI
import UIKit

/// Says a line to VoiceOver as a queued announcement, so it waits for the speech in progress instead of cutting
/// it off (spec 3.10.3): a button that changes its label ("Signing in…" back to "Sign in") is still being read
/// when the line comes.
enum VoiceOverAnnouncement {
    /// `text` marked to wait its turn.
    static func queued(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
    }

    /// Posts `text` for VoiceOver as a queued announcement.
    static func postQueued(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: queued(text))
    }
}

private nonisolated struct AnnounceToVoiceOverKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (String) -> Void = { VoiceOverAnnouncement.postQueued($0) }
}

extension EnvironmentValues {
    /// How a form's line is said to VoiceOver (`announcesToVoiceOver(_:)`): a queued announcement. Tests put a
    /// recorder here.
    var announceToVoiceOver: @MainActor @Sendable (String) -> Void {
        get { self[AnnounceToVoiceOverKey.self] }
        set { self[AnnounceToVoiceOverKey.self] = newValue }
    }
}

extension View {
    /// Says `line`, a form's error or status line, to VoiceOver when it appears and whenever its words change
    /// (UX-45). VoiceOver's focus stays on the button that was tapped, so a line that appears silently is never
    /// heard. Nil says nothing; a line that goes and comes back is said again. Showing the screen again (a page
    /// popped back to) does not repeat a line already said.
    ///
    /// Put it on the error line itself (`RecordErrorText`'s `announces`), or on a view that is always there when
    /// the line may be out of view, as in a list, which makes its rows only as they scroll in. A field's own hint
    /// ("Passwords don't match.") stays quiet: VoiceOver reads it with the field.
    func announcesToVoiceOver(_ line: String?) -> some View {
        modifier(VoiceOverLineAnnouncement(line: line))
    }
}

private struct VoiceOverLineAnnouncement: ViewModifier {
    let line: String?

    @Environment(\.announceToVoiceOver) private var announceToVoiceOver
    /// The line last said, so appearing again does not repeat it.
    @State private var saidLine: String?

    func body(content: Content) -> some View {
        content
            .onAppear { say(line) }
            .onChange(of: line) { _, newLine in say(newLine) }
    }

    private func say(_ line: String?) {
        guard let line else {
            saidLine = nil
            return
        }
        guard line != saidLine else { return }
        saidLine = line
        announceToVoiceOver(line)
    }
}
