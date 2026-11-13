import SwiftUI

/// A transient error banner that slides in under the top bar and closes itself (Civic Record spec
/// 3.19): an opaque `sheet` with a 1.5 pt `danger` rule and `Radius.slip` corners, no shadow; the
/// error mark `exclamationmark.circle` in `danger`, the message in the `body` role in `ink`, and a
/// close button ("Close error") with a 44 pt target. It announces "Error: …". Used only for errors that are not
/// about the vote (a refused vote shows in the vote panel).
///
/// Usage:
/// ```
/// .overlay(alignment: .top) {
///     BBErrorBanner(message: $errorMessage)
/// }
/// ```
struct BBErrorBanner: View {
    @Binding var message: String?

    /// How long the banner stays visible before closing itself (seconds).
    var displayDuration: TimeInterval = 4.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let text = message {
            ErrorBannerCard(message: text, onClose: dismiss)
                .padding(.horizontal, BillboardStyle.Space.l)
                .padding(.top, BillboardStyle.Space.s)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .onAppear {
                    AccessibilityNotification.Announcement("Error: \(text)").post()
                    DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
                        dismiss()
                    }
                }
        }
    }

    private func dismiss() {
        withAnimation(.easeIn(duration: 0.2)) {
            message = nil
        }
    }
}

/// The banner itself, without its timer and transition.
struct ErrorBannerCard: View {
    let message: String
    let onClose: () -> Void

    static let ruleWidth: CGFloat = 1.5

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 17
    @ScaledMetric(relativeTo: .callout) private var closeIconSize: CGFloat = 14

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The mark and the close button on one line, the message under them at full width, so
                // long words are not broken at the largest sizes.
                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    HStack(alignment: .center) {
                        errorMark
                        Spacer(minLength: 10)
                        closeButton
                    }
                    messageText
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    errorMark
                    messageText
                    closeButton
                }
            }
        }
        .padding(.horizontal, BillboardStyle.Space.l)
        .padding(.vertical, BillboardStyle.Space.m)
        .background(shape.fill(BillboardColors.cardBackground))
        .overlay(shape.strokeBorder(BillboardColors.danger, lineWidth: Self.ruleWidth))
    }

    private var errorMark: some View {
        Image(systemName: "exclamationmark.circle")
            .font(TextRole.Face.text.font(size: iconSize, weight: .semibold))
            .foregroundStyle(BillboardColors.danger)
            .accessibilityLabel("Error")
    }

    private var messageText: some View {
        Text(message)
            .textRole(.body)
            .foregroundStyle(BillboardColors.primaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(TextRole.Face.text.font(size: closeIconSize, weight: .bold))
                .foregroundStyle(BillboardColors.interactive)
                .billboardMinimumHitTarget()
        }
        .buttonStyle(RowButtonStyle())
        // The xmark means Close (spec 2.10); "dismiss" is not a Billboard word (Appendix A).
        .accessibilityLabel("Close error")
        .accessibilityInputLabels(["Close", "Close error"])
    }
}
