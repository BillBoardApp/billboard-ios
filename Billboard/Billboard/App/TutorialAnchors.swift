import SwiftUI

private struct TutorialFrameCaptureEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tutorialFrameCaptureEnabled: Bool {
        get { self[TutorialFrameCaptureEnabledKey.self] }
        set { self[TutorialFrameCaptureEnabledKey.self] = newValue }
    }
}

enum TutorialAnchor: Hashable {
    /// The tour (spec D 2.5.5): the first card on the Bills tab.
    case billsFirstCard
    /// The vote bar on bill detail, where the first-vote coach mark points.
    case voteBar
    /// The tab capsule (Civic Record spec 4.9): the tour's card ends 10 pt above its measured top.
    case tabBar
}

extension TutorialAnchor {
    var scrollID: String {
        switch self {
        case .billsFirstCard: return "tutorial.billsFirstCard"
        case .voteBar: return "tutorial.voteBar"
        case .tabBar: return "tutorial.tabBar"
        }
    }

    /// The tab that shows the anchor. All live on Bills: bill detail is pushed from the Bills tab
    /// when the tour opens the first bill, and the tour runs on the Bills root, where the capsule shows.
    var ownerTab: AppState.TabIndex {
        switch self {
        case .billsFirstCard, .voteBar, .tabBar:
            return .home
        }
    }

    /// The space the anchor's frame is measured in. The tab capsule is measured in window coordinates,
    /// which the tour's overlay converts (`ProductTutorialOverlay.bottomInset`), so its frame does not
    /// depend on how the capsule is hosted: in a `safeAreaBar` (slice 5) its frame in the tour's named
    /// space came out 62 pt too high, from the top of the safe area, while views inside the tabs'
    /// navigation stacks resolve that space from the top of the screen (measured on the simulator).
    var coordinateSpace: CoordinateSpace {
        switch self {
        case .billsFirstCard, .voteBar: return .named(ProductTutorialStorage.coordinateSpaceName)
        case .tabBar: return .global
        }
    }
}

struct TutorialAnchorFramePreferenceKey: PreferenceKey {
    static var defaultValue: [TutorialAnchor: CGRect] = [:]

    static func reduce(value: inout [TutorialAnchor: CGRect], nextValue: () -> [TutorialAnchor: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct TutorialAnchorCaptureModifier: ViewModifier {
    let anchor: TutorialAnchor
    @Environment(\.tutorialFrameCaptureEnabled) private var tutorialFrameCaptureEnabled

    func body(content: Content) -> some View {
        content.overlay {
            if tutorialFrameCaptureEnabled {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TutorialAnchorFramePreferenceKey.self,
                        value: [anchor: proxy.frame(in: anchor.coordinateSpace)]
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func tutorialAnchor(_ anchor: TutorialAnchor) -> some View {
        modifier(TutorialAnchorCaptureModifier(anchor: anchor))
    }

    func tutorialTarget(_ anchor: TutorialAnchor) -> some View {
        tutorialAnchor(anchor)
            .id(anchor.scrollID)
    }
}
