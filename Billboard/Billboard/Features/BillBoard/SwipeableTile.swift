import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

private let billboardQueueDismissAnimation = Animation.spring(response: 0.32, dampingFraction: 0.88)

/// The queue dismiss animation, without the spring when Reduce Motion is on.
func billboardQueueSettleAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeInOut(duration: 0.2) : billboardQueueDismissAnimation
}

/// A card that follows a left drag and, past 80 pt, runs `onSwipeLeft` (Skip on the Bills list,
/// spec D 2.1.1); a tap opens it unless a drag just happened. The reveal behind the card says what
/// the swipe does, in neutral colours: a skip is never a vote (Civic Record spec 3.28). Crossing the
/// 80 pt threshold, either way, plays a selection haptic, as Mail does; letting go plays none (spec
/// 5.2). While a finger rests on the card, its slip shows pressed (`billSlipIsPressed`, spec 3.4).
struct SwipeableTile<Label: View>: View {
    let accessibilityIdentifier: String?
    let onTap: (() -> Void)?
    /// Name of the VoiceOver action that does the same as swiping left.
    let swipeLeftAccessibilityName: String
    let onSwipeLeft: (() -> Void)?
    let label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    /// The drag is past the skip threshold (for the haptic as it is crossed).
    @State private var isPastThreshold = false
    @State private var isPressed = false

    /// How far left a card must be dragged to skip it.
    static var skipThreshold: CGFloat { 80 }

    private var settleAnimation: Animation {
        billboardQueueSettleAnimation(reduceMotion: reduceMotion)
    }

    private var swipeProgress: CGFloat {
        min(max(-offset / 96, 0), 1)
    }

    init(
        accessibilityIdentifier: String? = nil,
        onTap: (() -> Void)? = nil,
        swipeLeftAccessibilityName: String = "Skip",
        onSwipeLeft: (() -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onTap = onTap
        self.swipeLeftAccessibilityName = swipeLeftAccessibilityName
        self.onSwipeLeft = onSwipeLeft
        self.label = label
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            if onSwipeLeft != nil {
                swipeActionReveal
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            label()
                .environment(\.billSlipIsPressed, isPressed && offset == 0)
                .contentShape(Rectangle())
                .offset(x: offset)
                // Direction-locked horizontal pan, attached via overlay so it can actually
                // receive touches; vertical drags stay with the ScrollView.
                .overlay(
                    HorizontalPanCaptureView(
                        onChanged: { translation in
                            // Only track left drags.
                            guard translation.width < 0 else { return }
                            offset = translation.width
                            isDragging = true
                            let isPast = translation.width < -Self.skipThreshold
                            if isPast != isPastThreshold {
                                isPastThreshold = isPast
                                HapticFeedback.selection()
                            }
                        },
                        onEnded: { translation in
                            let x = translation.width
                            isPastThreshold = false
                            if x < -Self.skipThreshold {
                                withAnimation(settleAnimation) {
                                    offset = -120
                                    onSwipeLeft?()
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    withAnimation(settleAnimation) { offset = 0 }
                                }
                            } else {
                                withAnimation(settleAnimation) { offset = 0 }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isDragging = false
                            }
                        },
                        onPressChanged: { pressed in
                            isPressed = pressed
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isDragging {
                onTap?()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            // The swipe is a custom pan gesture VoiceOver cannot perform; offer it as an action.
            if let onSwipeLeft {
                Button(swipeLeftAccessibilityName) {
                    withAnimation(settleAnimation) { onSwipeLeft() }
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private var swipeActionReveal: some View {
        SwipeActionReveal(title: swipeLeftAccessibilityName, progress: swipeProgress)
    }
}

/// What shows behind a slip as it is swiped left (Civic Record spec 3.28): a `well` sheet with the
/// slip's own shape (radius 16), and the action's name ("Skip") after `forward.fill` in `ink2` at the
/// trailing edge. Neutral colours: a skip is never a vote. It shows once the slip starts to move
/// (`progress` above 0), so no well rim shows round the slip's corners at rest.
struct SwipeActionReveal: View {
    let title: String
    let progress: CGFloat

    @ScaledMetric(relativeTo: .subheadline) private var glyphSize: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "forward.fill")
                .font(TextRole.Face.text.font(size: glyphSize, weight: .semibold))
            Text(title)
                .textRole(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .foregroundStyle(BillboardColors.secondaryText)
        .padding(.trailing, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .background(BillboardColors.secondaryBackground, in: shape)
        .opacity(progress > 0 ? 1 : 0)
    }
}

private struct HorizontalPanCaptureView: UIViewRepresentable {
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize) -> Void
    /// A finger rests on the card (true), or has lifted, moved or been taken by a scroll (false).
    var onPressChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded, onPressChanged: onPressChanged)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear

        let recognizer = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)

        let coordinator = context.coordinator
        let press = PressObserver { pressed in coordinator.onPressChanged(pressed) }
        press.delegate = coordinator
        view.addGestureRecognizer(press)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.onPressChanged = onPressChanged
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize) -> Void
        var onPressChanged: (Bool) -> Void

        private enum LockDirection {
            case horizontal
            case vertical
        }

        /// Horizontal travel required before the card starts to follow the finger.
        private static let horizontalEngageDistance: CGFloat = 20
        /// A drag only counts as a swipe while it stays within 30 degrees of horizontal.
        private static let maxSwipeSlope: CGFloat = tan(30 * .pi / 180)

        private var lockDirection: LockDirection?

        init(
            onChanged: @escaping (CGSize) -> Void,
            onEnded: @escaping (CGSize) -> Void,
            onPressChanged: @escaping (Bool) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
            self.onPressChanged = onPressChanged
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Always begin; we direction-lock once translation is clear.
            if gestureRecognizer is UIPanGestureRecognizer {
                lockDirection = nil
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let size = CGSize(width: translation.x, height: translation.y)

            // Decide the direction once the finger has moved far enough on either axis.
            // Only a clearly horizontal drag (20 pt within a 30 degree cone) becomes a swipe,
            // so slightly diagonal page scrolls stay with the ScrollView.
            if lockDirection == nil {
                let dx = abs(size.width)
                let dy = abs(size.height)
                let engageDistance = Self.horizontalEngageDistance

                if dx >= engageDistance || dy >= engageDistance {
                    let isWithinSwipeCone = dy <= dx * Self.maxSwipeSlope
                    lockDirection = (dx >= engageDistance && isWithinSwipeCone) ? .horizontal : .vertical
                }
            }

            switch recognizer.state {
            case .began, .changed:
                if lockDirection == .horizontal {
                    onChanged(size)
                }
            case .ended, .cancelled, .failed:
                if lockDirection == .horizontal {
                    onEnded(size)
                }
                lockDirection = nil
            default:
                break
            }
        }
    }
}

/// Watches a finger on the card without ever taking the touch: it reports a press once the finger has
/// rested 80 ms (so a scroll that starts at once shows no press, as UIKit's own lists delay their
/// highlight), and the end of it when the finger lifts, moves more than 10 pt or is taken by a scroll.
/// It never recognizes, so it cannot block the tap, the swipe or the scroll.
private final class PressObserver: UIGestureRecognizer {
    private let onPressChanged: (Bool) -> Void
    private var start: CGPoint?
    private var pressTask: DispatchWorkItem?
    private var isPressed = false

    private static let delay: TimeInterval = 0.08
    private static let slop: CGFloat = 10

    init(onPressChanged: @escaping (Bool) -> Void) {
        self.onPressChanged = onPressChanged
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, start == nil, let view else {
            finish()
            return
        }
        start = touches.first?.location(in: view)
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.start != nil else { return }
            self.setPressed(true)
        }
        pressTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: task)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let view, let point = touches.first?.location(in: view) else { return }
        if hypot(point.x - start.x, point.y - start.y) > Self.slop {
            finish()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish()
    }

    /// Ends the press at once (UIKit may call `reset()` only when the finger lifts) and fails, so the
    /// observer gets no more touches.
    private func finish() {
        pressTask?.cancel()
        pressTask = nil
        setPressed(false)
        state = .failed
    }

    override func reset() {
        super.reset()
        pressTask?.cancel()
        pressTask = nil
        start = nil
        setPressed(false)
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        onPressChanged(pressed)
    }
}
