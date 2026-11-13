import SwiftUI

/// The info button at the head of a Civic Profile section (Civic Record spec 4.59, 4.64): `info.circle` in
/// ink, 44 pt to tap, no fill.
struct CivicProfileInfoButton: View {
    @Binding var isShowingInfo: Bool

    @ScaledMetric(relativeTo: .callout) private var glyphSize: CGFloat = 18

    var body: some View {
        Button {
            isShowingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(TextRole.Face.text.font(size: glyphSize, weight: .semibold))
                .foregroundStyle(BillboardColors.interactive)
                .billboardMinimumHitTarget()
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel("About the civic profile chart")
    }
}

/// The chart explanation (spec D 2.4.2: "theme" and "data", never "axis" or "signal").
enum CivicProfileInfoCopy {
    static let title = "How to read this chart"
    static let body = "Each spoke is one theme, scored from 1 to 10. A point farther from the center means a higher score on that theme, and the label at the end of each spoke shows the exact score. Themes without enough data are marked Not enough data."
    /// Under both theme charts, yours on Profile and a member's (UX-37, feature review N3): each bill's theme
    /// scores were set by the AI summarizer, and the chart puts ideology-like labels on named members.
    static let aiNote = "Theme scores come from AI ratings of each bill."
}

/// "Theme scores come from AI ratings of each bill." under a Civic Profile chart (UX-37): one `caption` line in
/// `ink2`, read as one element.
struct CivicProfileAINote: View {
    static let identifier = "civicProfile.aiNote"

    var body: some View {
        Text(CivicProfileInfoCopy.aiNote)
            .textRole(.caption)
            .foregroundStyle(BillboardColors.secondaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(Self.identifier)
    }
}

/// How to read the Civic Profile chart, drawn in place of the chart (spec 3.27): a slip (`sheet`, a 1 pt rule,
/// `Radius.slip`, no shadow) with the title in the `name` role, the explanation in `body` `ink2`, one caption
/// line per theme, and a close button (`xmark` in ink, 44 pt) at the top trailing corner.
struct CivicProfileInfoOverlay: View {
    let onClose: () -> Void

    private let axes = CivicProfileAxis.allCases

    @ScaledMetric(relativeTo: .callout) private var closeSize: CGFloat = 15

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        VStack(alignment: .leading, spacing: BillboardStyle.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: BillboardStyle.Space.s) {
                Text(CivicProfileInfoCopy.title)
                    .textRole(.name)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(TextRole.Face.text.font(size: closeSize, weight: .semibold))
                        .foregroundStyle(BillboardColors.interactive)
                        .billboardMinimumHitTarget()
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityLabel("Close chart explanation")
                .accessibilityInputLabels(["Close"])
            }

            Text(CivicProfileInfoCopy.body)
                .textRole(.body)
                .foregroundStyle(BillboardColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                ForEach(axes, id: \.self) { axis in
                    Text(axis.explanation)
                        .textRole(.caption)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(BillboardStyle.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(BillboardColors.cardBackground))
        .overlay(shape.strokeBorder(BillboardColors.separator, lineWidth: 1))
    }
}
