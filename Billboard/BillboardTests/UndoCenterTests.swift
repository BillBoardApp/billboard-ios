import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Billboard

/// `UndoCenter` (spec D 2.1.2): only the latest action is undoable; it commits once on the
/// earliest of its timer (4 s, or 10 s while VoiceOver or Switch Control runs, Civic Record spec 3.19),
/// a newer action, the app entering the background or an explicit `commitPending()`; `undo()` restores
/// it and its commit never runs.
@MainActor
final class UndoCenterTests: XCTestCase {
    /// A scheduler the test fires by hand.
    @MainActor
    private final class ManualScheduler: UndoTimerScheduling {
        final class Entry {
            let seconds: TimeInterval
            let fire: @MainActor @Sendable () -> Void
            var isCancelled = false

            init(seconds: TimeInterval, fire: @escaping @MainActor @Sendable () -> Void) {
                self.seconds = seconds
                self.fire = fire
            }
        }

        private(set) var entries: [Entry] = []

        func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> UndoTimerCancellation {
            let entry = Entry(seconds: seconds, fire: fire)
            entries.append(entry)
            return UndoTimerCancellation { entry.isCancelled = true }
        }

        /// Fires an entry as a real timer would: only if it was not cancelled.
        func fire(_ index: Int) {
            let entry = entries[index]
            guard !entry.isCancelled else { return }
            entry.fire()
        }

        /// Fires an entry even if it was cancelled, as a late timer callback could.
        func fireIgnoringCancellation(_ index: Int) {
            entries[index].fire()
        }
    }

    /// One center wired to a manual timer, a private notification center, a switchable
    /// VoiceOver flag and an announcement recorder.
    @MainActor
    private final class Harness {
        let scheduler = ManualScheduler()
        let notificationCenter = NotificationCenter()
        var voiceOverRunning = false
        var switchControlRunning = false
        var announcements: [String] = []
        var events: [String] = []
        private(set) var center: UndoCenter!

        init() {
            center = UndoCenter(
                scheduler: scheduler,
                notificationCenter: notificationCenter,
                isVoiceOverRunning: { [unowned self] in self.voiceOverRunning },
                isSwitchControlRunning: { [unowned self] in self.switchControlRunning },
                announce: { [unowned self] message in self.announcements.append(message) }
            )
        }

        func action(_ name: String, message: String? = nil) -> UndoAction {
            UndoAction(
                message: message ?? "Skipped \(name)",
                undo: { [unowned self] in self.events.append("undo \(name)") },
                commit: { [unowned self] in self.events.append("commit \(name)") }
            )
        }

        func postBackground() {
            notificationCenter.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        }
    }

    // MARK: - Register

    func testRegisterShowsToastForFourSeconds() throws {
        let h = Harness()
        h.center.register(h.action("H.R. 1234"))

        let toast = try XCTUnwrap(h.center.toast)
        XCTAssertEqual(toast.message, "Skipped H.R. 1234")
        XCTAssertEqual(toast.accessibilityMessage, "Skipped H.R. 1234. Undo available.")
        XCTAssertEqual(toast.duration, 4)
        XCTAssertTrue(h.center.hasPendingAction)
        XCTAssertEqual(h.scheduler.entries.map(\.seconds), [4])
        XCTAssertEqual(h.events, [], "registering runs neither closure")
        XCTAssertEqual(h.announcements, [], "no announcement without VoiceOver")
    }

    func testVoiceOverKeepsToastTenSecondsAndAnnouncesIt() throws {
        let h = Harness()
        h.voiceOverRunning = true
        h.center.register(h.action("H.R. 1234"))

        XCTAssertEqual(try XCTUnwrap(h.center.toast).duration, 10)
        XCTAssertEqual(h.scheduler.entries.map(\.seconds), [10])
        XCTAssertEqual(h.announcements, ["Skipped H.R. 1234. Undo available."])
    }

    /// Civic Record spec 3.19, 4.23: Switch Control steps through the screen to reach Undo, so the window
    /// is 10 s with it too. Only VoiceOver speaks, so nothing is announced.
    func testSwitchControlKeepsToastTenSecondsWithoutAnAnnouncement() throws {
        let h = Harness()
        h.switchControlRunning = true
        h.center.register(h.action("H.R. 1234"))

        XCTAssertEqual(try XCTUnwrap(h.center.toast).duration, 10)
        XCTAssertEqual(h.scheduler.entries.map(\.seconds), [10])
        XCTAssertEqual(h.announcements, [], "Switch Control does not speak")

        // The window follows the setting when each action is registered.
        h.switchControlRunning = false
        h.center.register(h.action("S. 456"))
        XCTAssertEqual(try XCTUnwrap(h.center.toast).duration, 4)

        h.voiceOverRunning = true
        h.switchControlRunning = true
        h.center.register(h.action("H.R. 9"))
        XCTAssertEqual(try XCTUnwrap(h.center.toast).duration, 10)
        XCTAssertEqual(h.announcements, ["Skipped H.R. 9. Undo available."])
    }

    func testCustomAccessibilityMessageIsAnnounced() {
        let h = Harness()
        h.voiceOverRunning = true
        h.center.register(UndoAction(
            message: "Cleared 3 bills",
            accessibilityMessage: "Cleared 3 bills from Updates. Undo available.",
            undo: {}
        ))
        XCTAssertEqual(h.announcements, ["Cleared 3 bills from Updates. Undo available."])
        XCTAssertEqual(h.center.toast?.message, "Cleared 3 bills")
    }

    // MARK: - Commit

    func testTimerExpiryCommitsOnce() {
        let h = Harness()
        h.center.register(h.action("A"))

        h.scheduler.fire(0)
        XCTAssertEqual(h.events, ["commit A"])
        XCTAssertNil(h.center.toast)
        XCTAssertFalse(h.center.hasPendingAction)

        h.scheduler.fireIgnoringCancellation(0)
        XCTAssertEqual(h.events, ["commit A"], "a late timer never commits twice")
    }

    func testNewActionCommitsThePreviousOne() {
        let h = Harness()
        h.center.register(h.action("A"))
        h.center.register(h.action("B"))

        XCTAssertEqual(h.events, ["commit A"])
        XCTAssertEqual(h.center.toast?.message, "Skipped B")
        XCTAssertTrue(h.scheduler.entries[0].isCancelled, "the first timer is cancelled")

        h.center.undo()
        XCTAssertEqual(h.events, ["commit A", "undo B"], "only the latest action is undoable")
    }

    func testStaleTimerDoesNotCommitANewerAction() {
        let h = Harness()
        h.center.register(h.action("A"))
        h.center.register(h.action("B"))

        h.scheduler.fireIgnoringCancellation(0)
        XCTAssertEqual(h.events, ["commit A"], "A's timer leaves B pending")
        XCTAssertEqual(h.center.toast?.message, "Skipped B")

        h.scheduler.fire(1)
        XCTAssertEqual(h.events, ["commit A", "commit B"])
    }

    func testEnteringBackgroundCommits() {
        let h = Harness()
        h.center.register(h.action("A"))

        h.postBackground()

        XCTAssertEqual(h.events, ["commit A"])
        XCTAssertNil(h.center.toast)
    }

    func testCommitPendingCommitsNowAndCancelsTheTimer() {
        let h = Harness()
        h.center.register(h.action("A"))

        h.center.commitPending()
        XCTAssertEqual(h.events, ["commit A"])
        XCTAssertTrue(h.scheduler.entries[0].isCancelled)

        h.scheduler.fire(0)
        h.center.commitPending()
        XCTAssertEqual(h.events, ["commit A"])
    }

    func testNothingPendingIsANoOp() {
        let h = Harness()
        h.center.commitPending()
        h.center.undo()
        h.postBackground()
        XCTAssertEqual(h.events, [])
        XCTAssertNil(h.center.toast)
        XCTAssertTrue(h.scheduler.entries.isEmpty)
    }

    // MARK: - Undo

    func testUndoRestoresAndTheCommitNeverRuns() {
        let h = Harness()
        h.center.register(h.action("A"))

        h.center.undo()
        XCTAssertEqual(h.events, ["undo A"])
        XCTAssertNil(h.center.toast)
        XCTAssertTrue(h.scheduler.entries[0].isCancelled)

        h.scheduler.fireIgnoringCancellation(0)
        h.postBackground()
        h.center.commitPending()
        h.center.undo()
        XCTAssertEqual(h.events, ["undo A"])
    }

    func testUndoFromAnOlderToastDoesNothing() throws {
        let h = Harness()
        h.center.register(h.action("A"))
        let firstToastID = try XCTUnwrap(h.center.toast?.id)
        h.center.register(h.action("B"))

        h.center.undo(toastID: firstToastID)
        XCTAssertEqual(h.events, ["commit A"], "B is neither undone nor committed")
        XCTAssertEqual(h.center.toast?.message, "Skipped B")

        let secondToastID = try XCTUnwrap(h.center.toast?.id)
        h.center.undo(toastID: secondToastID)
        XCTAssertEqual(h.events, ["commit A", "undo B"])
    }

    /// Undo keeps its light haptic (Civic Record spec 3.19, 5.2): the toast host plays it whenever
    /// `undoCount` changes, so the count moves once per action really undone and never on a commit or a
    /// tap on a toast that is already gone.
    func testUndoCountsOncePerUndoneActionForItsHaptic() throws {
        let h = Harness()
        XCTAssertEqual(h.center.undoCount, 0)

        h.center.register(h.action("A"))
        let firstToastID = try XCTUnwrap(h.center.toast?.id)
        h.center.undo(toastID: firstToastID)
        XCTAssertEqual(h.center.undoCount, 1, "the tap on Undo")

        h.center.undo(toastID: firstToastID)
        h.center.undo()
        XCTAssertEqual(h.center.undoCount, 1, "nothing left to undo: no second haptic")

        h.center.register(h.action("B"))
        h.scheduler.fire(1)
        h.center.register(h.action("C"))
        h.center.commitPending()
        h.postBackground()
        XCTAssertEqual(h.center.undoCount, 1, "commits play no haptic")

        h.center.register(h.action("D"))
        let staleID = try XCTUnwrap(h.center.toast?.id)
        h.center.register(h.action("E"))
        h.center.undo(toastID: staleID)
        XCTAssertEqual(h.center.undoCount, 1, "a toast that has gone undoes nothing and plays nothing")
        h.center.undo(toastID: try XCTUnwrap(h.center.toast?.id))
        XCTAssertEqual(h.center.undoCount, 2)
        XCTAssertEqual(h.events, ["undo A", "commit B", "commit C", "commit D", "undo E"])
    }

    // MARK: - Re-entrancy

    func testActionRegisteredByACommitIsCommittedBeforeTheNewOne() {
        let h = Harness()
        let center = h.center!
        center.register(UndoAction(
            message: "Skipped A",
            undo: { h.events.append("undo A") },
            commit: {
                h.events.append("commit A")
                center.register(UndoAction(
                    message: "Skipped C",
                    undo: { h.events.append("undo C") },
                    commit: { h.events.append("commit C") }
                ))
            }
        ))
        center.register(h.action("B"))

        XCTAssertEqual(h.events, ["commit A", "commit C"], "nothing is left neither committed nor undone")
        XCTAssertEqual(center.toast?.message, "Skipped B")
    }

    func testUndoClosureMayRegisterANewAction() {
        let h = Harness()
        let center = h.center!
        center.register(UndoAction(
            message: "Skipped A",
            undo: {
                h.events.append("undo A")
                center.register(UndoAction(message: "Restored A", undo: {}, commit: { h.events.append("commit restore") }))
            },
            commit: { h.events.append("commit A") }
        ))

        center.undo()
        XCTAssertEqual(center.toast?.message, "Restored A")
        center.commitPending()
        XCTAssertEqual(h.events, ["undo A", "commit restore"])
    }

    // MARK: - Where the toast goes

    /// The toast sits at the bottom edge where bill detail pins its vote bar, so opening a bill ends the
    /// undo window: the toast never covers Yea, Nay and Abstain, and a tap on Abstain never lands on
    /// Undo. Every bill page has the bar, a passed bill's too (Civic Record project decision 1).
    func testOpeningABillEndsTheUndoWindow() {
        let h = Harness()
        let center = h.center!

        center.register(h.action("B"))
        BillDetail.endUndoWindow(center: center)
        XCTAssertNil(center.toast)
        XCTAssertFalse(center.hasPendingAction)
        XCTAssertEqual(h.events, ["commit B"], "the skip stands and its deferred side effects run")

        BillDetail.endUndoWindow(center: center)
        XCTAssertEqual(h.events, ["commit B"], "nothing pending is a no-op")
    }

    /// Spec D 2.1.2: Undo gets focus priority while VoiceOver runs. The tab shell's host moves focus
    /// to Undo, and the focus binding keeps the Undo button in the live toast (`ImageRenderer` drops
    /// a view that carries it, which is why the render tests draw the toast without it).
    func testTheTabShellMovesVoiceOverFocusToUndo() {
        XCTAssertTrue(TabsBar.focusesUndoWhenVoiceOverRuns)

        func fittingSize(focusUndo: Bool) -> CGSize {
            let controller = UIHostingController(rootView: UndoToast(message: "Skipped H.R. 1234", focusUndoOnAppear: focusUndo, onUndo: {}))
            return controller.sizeThatFits(in: CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        }
        let plain = fittingSize(focusUndo: false)
        XCTAssertGreaterThanOrEqual(plain.height, 50, "the 50 pt glass capsule, which holds Undo's 44 pt target")
        XCTAssertEqual(fittingSize(focusUndo: true), plain, "the Undo button is still laid out")
    }

    // MARK: - Defaults and the real timer

    func testSharedInstanceAndDurations() {
        XCTAssertTrue(UndoCenter.shared === UndoCenter.shared)
        XCTAssertEqual(UndoCenter.standardDuration, 4)
        XCTAssertEqual(UndoCenter.assistiveTechnologyDuration, 10)
        XCTAssertEqual(UndoAction(message: "Cleared 3 bills", undo: {}).accessibilityMessage, "Cleared 3 bills. Undo available.")
    }

    func testTaskSchedulerFiresAfterTheDelay() async {
        let fired = expectation(description: "fired")
        let cancellation = TaskUndoTimerScheduler().schedule(after: 0.05) {
            fired.fulfill()
        }
        await fulfillment(of: [fired], timeout: 2)
        cancellation.cancel()
    }

    func testTaskSchedulerDoesNotFireOnceCancelled() async {
        let fired = expectation(description: "fired")
        fired.isInverted = true
        let cancellation = TaskUndoTimerScheduler().schedule(after: 0.05) {
            fired.fulfill()
        }
        cancellation.cancel()
        await fulfillment(of: [fired], timeout: 0.3)
    }

    func testRealTimerCommitsAfterTheWindow() async {
        let committed = expectation(description: "committed")
        let center = UndoCenter(
            scheduler: ShortScheduler(),
            notificationCenter: NotificationCenter(),
            isVoiceOverRunning: { false },
            isSwitchControlRunning: { false },
            announce: { _ in }
        )
        center.register(UndoAction(message: "Skipped A", undo: {}, commit: { committed.fulfill() }))
        XCTAssertNotNil(center.toast)
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertNil(center.toast)
    }

    /// The real task scheduler with the delay cut to 1%, to run the timer path end to end.
    @MainActor
    private struct ShortScheduler: UndoTimerScheduling {
        func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> UndoTimerCancellation {
            TaskUndoTimerScheduler().schedule(after: seconds / 100, fire)
        }
    }
}
