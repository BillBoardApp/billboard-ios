import SwiftUI

/// The product tour's content (spec D 2.5.5): three steps on the Bills tab that end in a vote.
/// `ProductTutorialPresenter` runs the tour and `ProductTutorialOverlay` draws it.
///
/// Every step spotlights the first card on Bills (`TutorialAnchor.billsFirstCard`, attached by the
/// Bills list). The last step's button ends the tour and opens that card; with an empty list it
/// reads "Got it" instead.
enum ProductTutorial {
    struct Step: Identifiable, Equatable {
        enum PrimaryAction: Equatable {
            /// Goes to the next step.
            case next
            /// Ends the tour and opens the spotlighted card ("Open this bill"), or only ends it when
            /// the list is empty ("Got it").
            case openFirstBill
        }

        let id: Int
        /// The view the step spotlights.
        let anchor: TutorialAnchor
        /// The step's title carries the step: the card draws no symbol (Civic Record spec 4.17).
        let title: String
        let summary: String
        /// Draws the swipe hint under the spotlighted slip (`TutorialSwipeHint`; still with Reduce Motion).
        let showsSwipeHint: Bool
        let primaryAction: PrimaryAction
    }

    static let steps: [Step] = [
        Step(
            id: 0,
            anchor: .billsFirstCard,
            title: "Bills in Congress",
            summary: "Each card is a real bill, with a plain-English summary written with AI from the official text. Tap a card to read it.",
            showsSwipeHint: false,
            primaryAction: .next
        ),
        Step(
            id: 1,
            anchor: .billsFirstCard,
            title: "Skip what you don't care about",
            summary: "Swipe left to skip a bill. Skipping is never a vote, and you can undo it.",
            showsSwipeHint: true,
            primaryAction: .next
        ),
        Step(
            id: 2,
            anchor: .billsFirstCard,
            title: "Cast your first vote",
            summary: "Open a bill and choose Yea (for), Nay (against) or Abstain. Results appear after you vote.",
            showsSwipeHint: false,
            primaryAction: .openFirstBill
        )
    ]

    /// What one step shows, given whether the Bills list has a card to open.
    struct Presentation: Equatable {
        let title: String
        let summary: String
        let primaryTitle: String
        /// "Back" from the second step on; nil on the first.
        let backTitle: String?
        /// "Step 2 of 3", what VoiceOver reads for the progress.
        let progressLabel: String
        /// "2 of 3", the progress figure in the docket face (capitals by style).
        let progressFigure: String
    }

    static let skipTitle = "Skip tour"
    static let headerTitle = "Tour"

    static func presentation(for step: Step, index: Int, totalSteps: Int = steps.count, hasFirstCard: Bool) -> Presentation {
        let isEmptyListVoteStep = step.primaryAction == .openFirstBill && !hasFirstCard
        let primaryTitle: String
        switch step.primaryAction {
        case .next:
            primaryTitle = "Next"
        case .openFirstBill:
            primaryTitle = hasFirstCard ? "Open this bill" : "Got it"
        }
        return Presentation(
            title: isEmptyListVoteStep ? "Open any bill to vote" : step.title,
            summary: isEmptyListVoteStep
                ? "When bills show up on your Bills tab, open one and choose Yea (for), Nay (against) or Abstain. Results appear after you vote."
                : step.summary,
            primaryTitle: primaryTitle,
            backTitle: index > 0 ? "Back" : nil,
            progressLabel: "Step \(index + 1) of \(totalSteps)",
            progressFigure: "\(index + 1) of \(totalSteps)"
        )
    }

    /// The rectangles to spotlight for a step, in the tour's coordinate space: the step's anchor
    /// when it is on screen, else none (the card then sits over the dimmed Bills tab).
    static func highlightRects(for step: Step, anchorFrames: [TutorialAnchor: CGRect]) -> [CGRect] {
        guard let frame = anchorFrames[step.anchor], !frame.isEmpty, !frame.isNull else { return [] }
        return [frame]
    }
}

/// When the tour starts and what finishing it stores. Pure, for `ProductTutorialTests`.
enum ProductTutorialPolicy {
    /// The tour starts when setup or App Settings asked for it and the tabs are on screen and usable
    /// (not under "Where do you vote?", a gate or the loading screen).
    static func shouldBegin(isShowing: Bool, pendingAutoShow: Bool, replayRequested: Bool, canPresent: Bool) -> Bool {
        !isShowing && canPresent && (pendingAutoShow || replayRequested)
    }

    /// The completed version stored when the tour ends ("Skip tour", "Open this bill" or "Got it").
    static func completedVersion(previous: Int) -> Int {
        max(previous, ProductTutorialStorage.currentVersion)
    }
}
