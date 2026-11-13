import Combine
import SwiftUI
import UIKit

// MARK: - Undo action

/// One undoable change, such as a skip on Bills or a Clear on Updates (spec D 2.1.2).
///
/// The caller applies the local change before registering. `undo` restores exactly what the
/// change removed. `commit` runs deferred side effects only (for example the unwatch of a passed
/// bill) and runs at most once; neither closure runs if the other already ran.
struct UndoAction {
    /// Toast text, such as "Skipped H.R. 1234" or "Cleared 3 bills".
    let message: String
    /// What VoiceOver announces; defaults to "<message>. Undo available."
    let accessibilityMessage: String
    let undo: @MainActor () -> Void
    let commit: @MainActor () -> Void

    init(
        message: String,
        accessibilityMessage: String? = nil,
        undo: @escaping @MainActor () -> Void,
        commit: @escaping @MainActor () -> Void = {}
    ) {
        self.message = message
        self.accessibilityMessage = accessibilityMessage ?? "\(message). Undo available."
        self.undo = undo
        self.commit = commit
    }
}

// MARK: - Timer seam

/// Cancels a scheduled undo timer.
struct UndoTimerCancellation {
    let cancel: () -> Void
}

/// Schedules the commit timer. Tests swap in a manual scheduler.
@MainActor
protocol UndoTimerScheduling {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> UndoTimerCancellation
}

/// The app's scheduler: a main-actor task that sleeps, then fires unless cancelled.
struct TaskUndoTimerScheduler: UndoTimerScheduling {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> UndoTimerCancellation {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
        return UndoTimerCancellation { task.cancel() }
    }
}

// MARK: - Undo center

/// The app-wide undo window (spec D 2.1.2). Only the latest action is undoable.
///
/// A registered action commits on the earliest of: its timer (4 s, or 10 s while VoiceOver or Switch
/// Control runs, Civic Record spec 3.19), a newer `register`, the app entering the background, or an
/// explicit `commitPending()`
/// (the tab shell calls it on a tab switch, and bill detail when it opens with its vote bar, which
/// the toast would cover). `undo()` restores it instead. If the app is killed
/// inside the window, neither runs: the local change stands and deferred side effects are lost.
///
/// `.undoToastHost()` (placed once, in `TabsBar`) shows the toast for the pending action.
@MainActor
final class UndoCenter: ObservableObject {
    static let shared = UndoCenter()

    static let standardDuration: TimeInterval = 4
    /// The window while VoiceOver or Switch Control runs: reaching Undo takes longer with either.
    static let assistiveTechnologyDuration: TimeInterval = 10

    /// What the toast shows for the pending action.
    struct Toast: Identifiable, Equatable {
        let id: UUID
        let message: String
        let accessibilityMessage: String
        let duration: TimeInterval
    }

    /// The pending action's toast, or nil when nothing can be undone.
    @Published private(set) var toast: Toast?

    /// How many actions have been undone. The toast host plays Undo's light haptic on each change
    /// (Civic Record spec 3.19, 5.2: the one press haptic the budget keeps). It is counted here, not in
    /// the toast, because the toast leaves the screen in the same update.
    @Published private(set) var undoCount = 0

    var hasPendingAction: Bool { pendingAction != nil }

    private var pendingAction: UndoAction?
    private var timer: UndoTimerCancellation?
    private let scheduler: any UndoTimerScheduling
    private let isVoiceOverRunning: @MainActor () -> Bool
    private let isSwitchControlRunning: @MainActor () -> Bool
    private let announce: @MainActor (String) -> Void
    private var backgroundSubscription: AnyCancellable?

    /// `scheduler` nil means `TaskUndoTimerScheduler` (a default argument cannot create it: default
    /// arguments are evaluated outside the main actor).
    init(
        scheduler: (any UndoTimerScheduling)? = nil,
        notificationCenter: NotificationCenter = .default,
        isVoiceOverRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning },
        isSwitchControlRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isSwitchControlRunning },
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.scheduler = scheduler ?? TaskUndoTimerScheduler()
        self.isVoiceOverRunning = isVoiceOverRunning
        self.isSwitchControlRunning = isSwitchControlRunning
        self.announce = announce
        backgroundSubscription = notificationCenter
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                // UIKit posts this notification on the main thread.
                MainActor.assumeIsolated {
                    if let center = self {
                        center.commitPending()
                    }
                }
            }
    }

    /// Makes `action` the undoable one, committing any earlier pending action first.
    func register(_ action: UndoAction) {
        // A commit closure could itself register an action; commit that too, so nothing is
        // left neither committed nor undone.
        while let earlier = takePendingAction() {
            earlier.commit()
        }

        let voiceOverRunning = isVoiceOverRunning()
        // Switch Control steps through the screen to reach Undo, as VoiceOver does; only VoiceOver
        // speaks the announcement.
        let extended = voiceOverRunning || isSwitchControlRunning()
        let duration = extended ? Self.assistiveTechnologyDuration : Self.standardDuration
        let newToast = Toast(
            id: UUID(),
            message: action.message,
            accessibilityMessage: action.accessibilityMessage,
            duration: duration
        )
        pendingAction = action
        toast = newToast

        let toastID = newToast.id
        timer = scheduler.schedule(after: duration) { [weak self] in
            guard let self, self.toast?.id == toastID else { return }
            self.commitPending()
        }

        if voiceOverRunning {
            announce(action.accessibilityMessage)
        }
    }

    /// Commits the pending action now, if any.
    func commitPending() {
        guard let action = takePendingAction() else { return }
        action.commit()
    }

    /// Restores the pending action, if any. Its commit never runs.
    func undo() {
        guard let action = takePendingAction() else { return }
        undoCount += 1
        action.undo()
    }

    /// Restores the pending action only if it is still the one `toastID` showed, so a tap on a
    /// toast that is animating out never undoes a newer action.
    func undo(toastID: UUID) {
        guard toast?.id == toastID else { return }
        undo()
    }

    /// Clears the pending state before running a closure, so a closure that registers a new
    /// action (or calls back into the center) sees a consistent state.
    private func takePendingAction() -> UndoAction? {
        guard let action = pendingAction else { return nil }
        pendingAction = nil
        toast = nil
        timer?.cancel()
        timer = nil
        return action
    }
}

// MARK: - Toast view

/// "Skipped H.R. 1234 · Undo" in a `GlassCapsule` (Civic Record spec 3.19, 4.23): the text and an ink
/// Undo sit on the capsule's opaque inner sheet, never on the glass, with a 1 pt rule instead of the glass
/// rim under Reduce Transparency (`controlRule` with Increase Contrast). The message wraps at any text
/// size; at the accessibility sizes Undo moves under it, and the toast becomes a card with the slip's
/// 16 pt corners (12 pt for the inner sheet): a two-line pill's curve came within 3 pt of the first
/// word and of Undo.
struct UndoToast: View {
    let message: String
    var focusUndoOnAppear: Bool = false
    let onUndo: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))

        GlassCapsule(fixedCornerRadius: dynamicTypeSize.isAccessibilitySize ? BillboardStyle.Radius.slip : nil) {
            layout {
                Text(message)
                    .textRole(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Undo", action: onUndo)
                // An ink text button, semibold. Its 44 pt target fits inside the 50 pt capsule.
                .buttonStyle(BillboardButtonStyle(kind: .textButton))
                .accessibilityIdentifier("undo.toast.undo")
                .accessibilitySortPriority(1)
                .modifier(UndoFocusOnAppear(isEnabled: focusUndoOnAppear))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo.toast")
    }
}

/// Moves VoiceOver focus to the Undo button shortly after it appears, when enabled.
///
/// The focus binding is attached only when enabled: `ImageRenderer` drops a view that carries
/// `.accessibilityFocused`, so an unconditional binding left the button out of the toast's
/// layout and out of its render-test images.
private struct UndoFocusOnAppear: ViewModifier {
    let isEnabled: Bool

    @AccessibilityFocusState private var focused: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityFocused($focused)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        focused = true
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Host

/// Shows the pending undo toast at the bottom of the modified view: 16 pt from the sides, `bottomPadding`
/// above the bottom of its safe area. Slides in from the bottom in 0.25 s (with Reduce Motion it fades).
struct UndoToastHostModifier: ViewModifier {
    @ObservedObject var center: UndoCenter
    var bottomPadding: CGFloat
    var focusUndoWhenVoiceOverRuns: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                ZStack {
                    if let toast = center.toast {
                        UndoToast(
                            message: toast.message,
                            focusUndoOnAppear: focusUndoWhenVoiceOverRuns && voiceOverEnabled,
                            onUndo: { center.undo(toastID: toast.id) }
                        )
                        .id(toast.id)
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottomPadding)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(
                    reduceMotion ? Animation.easeOut(duration: 0.15) : Animation.easeOut(duration: 0.25),
                    value: center.toast?.id
                )
            }
            // Undo's light impact (spec 3.19, 5.2), on the host because the toast is gone by then.
            .sensoryFeedback(.impact(weight: .light), trigger: center.undoCount)
    }
}

extension View {
    /// Hosts the undo toast. Place it once, on the content above the tab capsule (`TabCapsuleHost`).
    ///
    /// The toast is announced while VoiceOver runs and its Undo button is first in reading order.
    /// `focusUndoWhenVoiceOverRuns` also moves VoiceOver focus to Undo when the toast appears. The
    /// tab shell turns it on (`TabsBar.focusesUndoWhenVoiceOverRuns`, spec D 2.1.2: Undo gets focus
    /// priority): the toast is laid over the tab's content, after all of it in reading order, so
    /// without the focus move Undo is out of reach inside its window.
    /// `center` nil means `UndoCenter.shared`.
    func undoToastHost(
        center: UndoCenter? = nil,
        bottomPadding: CGFloat = 12,
        focusUndoWhenVoiceOverRuns: Bool = false
    ) -> some View {
        modifier(UndoToastHostModifier(
            center: center ?? .shared,
            bottomPadding: bottomPadding,
            focusUndoWhenVoiceOverRuns: focusUndoWhenVoiceOverRuns
        ))
    }
}
