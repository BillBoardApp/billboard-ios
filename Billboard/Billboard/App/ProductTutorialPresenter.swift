import SwiftUI

/// Runs the product tour over `TabsBar` (spec D 2.5.5). It starts the tour when setup or App
/// Settings asks for it and the tabs are usable, keeps it on the Bills tab, collects the frame of
/// the first Bills card and draws `ProductTutorialOverlay`.
///
/// The tour is complete (version stored) at "Skip tour", at "Open this bill" (which also opens the
/// card and asks bill detail for its vote-bar coach mark) and at "Got it".
struct ProductTutorialPresenter: ViewModifier {
    @ObservedObject var appState: AppState
    /// Owned by `TabsBar`, which holds deep links back while the tour is on screen.
    @Binding var isShowing: Bool
    /// True while the tabs are on screen and usable; a requested tour waits for it.
    let canPresent: Bool
    /// Pops anything pushed on the tabs' navigation stacks.
    let popToRoot: () -> Void
    /// Opens the first card on Bills the way a tap does. Returns false when there is none.
    let openFirstBill: () -> Bool

    @AppStorage(ProductTutorialStorage.pendingAutoShowKey) private var pendingAutoShowTutorial = false
    @AppStorage(ProductTutorialStorage.replayRequestedKey) private var replayTutorialRequested = false
    @AppStorage(ProductTutorialStorage.completedVersionKey) private var completedTutorialVersion = 0
    @State private var tutorialStepIndex = 0
    @State private var tutorialAnchorFrames: [TutorialAnchor: CGRect] = [:]
    private static let tutorialCoordinateSpaceName = ProductTutorialStorage.coordinateSpaceName

    private var tutorialSteps: [ProductTutorial.Step] {
        ProductTutorial.steps
    }

    private var shouldCaptureTutorialFrames: Bool {
        isShowing
            || pendingAutoShowTutorial
            || replayTutorialRequested
            || appState.pendingTutorialAnchor != nil
    }

    private var currentTutorialStep: ProductTutorial.Step? {
        guard tutorialSteps.indices.contains(tutorialStepIndex) else { return nil }
        return tutorialSteps[tutorialStepIndex]
    }

    /// The Bills list shows a card the tour can spotlight and open.
    private var hasFirstCard: Bool {
        guard let frame = tutorialAnchorFrames[.billsFirstCard] else { return false }
        return !frame.isEmpty && !frame.isNull
    }

#if DEBUG
    private func debugTutorialLaunchAuthorized() -> Bool {
        ProcessInfo.processInfo.arguments.contains("-bbEnableTutorialDebugStart")
    }

    private func debugTutorialStartStepOverride() -> Int? {
        let args = ProcessInfo.processInfo.arguments
        guard debugTutorialLaunchAuthorized() else { return nil }
        guard let flagIndex = args.firstIndex(of: "-bbTutorialStartStep") else { return nil }
        let valueIndex = flagIndex + 1
        guard args.indices.contains(valueIndex), let value = Int(args[valueIndex]) else { return nil }
        guard tutorialSteps.indices.contains(value) else { return nil }
        return value
    }

    private func clearStaleTutorialDebugPreferenceIfNeeded() {
        guard !debugTutorialLaunchAuthorized() else { return }
        UserDefaults.standard.removeObject(forKey: ProductTutorialStorage.debugStartStepKey)
    }
#endif

    private func maybePresentTutorialIfNeeded() {
        guard !isShowing else { return }
#if DEBUG
        clearStaleTutorialDebugPreferenceIfNeeded()
        if canPresent, debugTutorialStartStepOverride() != nil {
            beginTutorial()
            return
        }
#endif
        guard ProductTutorialPolicy.shouldBegin(
            isShowing: isShowing,
            pendingAutoShow: pendingAutoShowTutorial,
            replayRequested: replayTutorialRequested,
            canPresent: canPresent
        ) else { return }
        beginTutorial()
    }

    private func beginTutorial() {
        // The tour spotlights the first card on the Bills tab's root screen; pop anything pushed on
        // top (a bill opened from a link, or Settings when the tour is replayed from there).
        popToRoot()
#if DEBUG
        tutorialStepIndex = debugTutorialStartStepOverride() ?? 0
#else
        tutorialStepIndex = 0
#endif
        appState.selectedTab = TabsBar.Tab.home.rawValue
        isShowing = true
        // Scroll the Bills list to its first card once it is showing.
        DispatchQueue.main.async {
            self.appState.pendingTutorialAnchor = .billsFirstCard
        }
    }

    private func handlePrimary() {
        guard let step = currentTutorialStep else {
            finishTutorial()
            return
        }

        switch step.primaryAction {
        case .next:
            if tutorialStepIndex < tutorialSteps.count - 1 {
                tutorialStepIndex += 1
            } else {
                finishTutorial()
            }
        case .openFirstBill:
            let shouldOpen = hasFirstCard
            finishTutorial()
            guard shouldOpen, openFirstBill() else { return }
            if FeatureFlags.voteBarCoachMark {
                FirstRunStorage.voteCoachMarkPending = true
            }
        }
    }

    private func goBackTutorial() {
        guard tutorialStepIndex > 0 else { return }
        tutorialStepIndex -= 1
    }

    private func finishTutorial() {
        isShowing = false
        pendingAutoShowTutorial = false
        replayTutorialRequested = false
        completedTutorialVersion = ProductTutorialPolicy.completedVersion(previous: completedTutorialVersion)
        if appState.pendingTutorialAnchor == .billsFirstCard {
            appState.pendingTutorialAnchor = nil
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                maybePresentTutorialIfNeeded()
            }
            .onChange(of: replayTutorialRequested) { _, requested in
                guard requested else { return }
                maybePresentTutorialIfNeeded()
            }
            .onChange(of: pendingAutoShowTutorial) { _, pending in
                guard pending else { return }
                maybePresentTutorialIfNeeded()
            }
            .onChange(of: canPresent) { _, canPresent in
                guard canPresent else { return }
                maybePresentTutorialIfNeeded()
            }
            .coordinateSpace(name: Self.tutorialCoordinateSpaceName)
            .environment(\.tutorialFrameCaptureEnabled, shouldCaptureTutorialFrames)
            .onPreferenceChange(TutorialAnchorFramePreferenceKey.self) { frames in
                guard tutorialAnchorFrames != frames else { return }
                tutorialAnchorFrames = frames
            }
            .overlay {
                if isShowing, let step = currentTutorialStep {
                    ProductTutorialOverlay(
                        step: step,
                        stepIndex: tutorialStepIndex,
                        totalSteps: tutorialSteps.count,
                        highlightRects: ProductTutorial.highlightRects(for: step, anchorFrames: tutorialAnchorFrames),
                        hasFirstCard: hasFirstCard,
                        tabBarFrame: tutorialAnchorFrames[.tabBar],
                        onBack: goBackTutorial,
                        onPrimary: handlePrimary,
                        onSkip: finishTutorial
                    )
                    .transition(.opacity)
                    .zIndex(1000)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isShowing)
    }
}
