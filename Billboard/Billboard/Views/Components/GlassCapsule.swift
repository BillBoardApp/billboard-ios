import SwiftUI

/// How Civic Record's custom glass is drawn under the current settings (spec 2.9). The custom glass
/// views read Reduce Transparency and Increase Contrast themselves and switch explicitly, rather than
/// leaving it to the system's automatic fallback, so render tests can draw every branch.
nonisolated enum GlassChrome {
    enum Treatment: Equatable, Sendable {
        /// Liquid Glass.
        case glass
        /// No glass: an opaque fill with a 1 pt `rule` edge (Reduce Transparency, or
        /// `FeatureFlags.glassChrome` off).
        case solid
        /// No glass: an opaque fill with a 1 pt `controlRule` edge (Increase Contrast).
        case solidHighContrast
    }

    /// Increase Contrast wins over everything; then Reduce Transparency and the kill switch.
    static func treatment(glassChrome: Bool, reduceTransparency: Bool, increaseContrast: Bool) -> Treatment {
        if increaseContrast { return .solidHighContrast }
        if !glassChrome || reduceTransparency { return .solid }
        return .glass
    }
}

/// The floating capsule of the Undo toast, the sync capsule, Jump to top and the tour's swipe hint
/// (Civic Record spec 2.9, 3.19): a Liquid Glass rim, 4 pt wide, around an opaque `sheet` capsule that
/// carries the text. Text never sits on the glass itself: on raw dark glass ink falls to 2.87:1 over a
/// white title, while ink on the sheet is 17.41:1 light and 14.80:1 dark (spec 2.2).
///
/// The fallbacks are drawn here, not left to the system, so render tests can draw them:
/// - Reduce Transparency, or `FeatureFlags.glassChrome` off: the sheet capsule alone, full size, with
///   a 1 pt `rule` edge.
/// - Increase Contrast: the same with a 1 pt `controlRule` edge (at least 3:1), whatever the other
///   settings.
///
/// The glass is plain `.regular` and not `.interactive()`: the controls inside give the feedback. The
/// capsules are stroked with `strokeBorder`, inside their edge; the simulator spike found that
/// `ImageRenderer` draws SwiftUI glass within 2 to 10/255 of the screen, so render tests can sample
/// the inner sheet.
struct GlassCapsule<Content: View>: View {
    enum Size {
        /// 50 pt: the Undo toast.
        case regular
        /// 44 pt: the sync capsule, Jump to top and the swipe hint.
        case compact

        var height: CGFloat {
            switch self {
            case .regular: return 50
            case .compact: return 44
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: return 16
            case .compact: return 14
            }
        }
    }

    /// The width of the glass rim around the inner sheet.
    static var rimWidth: CGFloat { 4 }

    var size: Size = .regular
    /// The outer corner radius in place of the scaled capsule's, for content that runs to several lines
    /// (the Undo toast at the accessibility sizes): a capsule's radius is half its height, so a two-line
    /// capsule's curve would crowd the first and last words. The inner sheet stays concentric.
    var fixedCornerRadius: CGFloat? = nil
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// Scaled with the text, so a one-line capsule stays a capsule at every text size.
    @ScaledMetric private var cornerRadius: CGFloat

    init(size: Size = .regular, fixedCornerRadius: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.size = size
        self.fixedCornerRadius = fixedCornerRadius
        self.content = content()
        _cornerRadius = ScaledMetric(wrappedValue: size.height / 2, relativeTo: .body)
    }

    /// The outer corner radius: the fixed one when set, else the scaled capsule's.
    private var outerRadius: CGFloat {
        fixedCornerRadius ?? cornerRadius
    }

    var treatment: GlassChrome.Treatment {
        GlassChrome.treatment(
            glassChrome: FeatureFlags.glassChrome,
            reduceTransparency: reduceTransparency,
            increaseContrast: contrast == .increased
        )
    }

    /// A capsule at one line of text. The height grows with the text rather than scaling 50 pt.
    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
    }

    var body: some View {
        let outer = outerShape
        switch treatment {
        case .glass:
            // The inner sheet is concentric with the rim.
            sheet(
                minHeight: size.height - 2 * Self.rimWidth,
                shape: RoundedRectangle(cornerRadius: max(0, outerRadius - Self.rimWidth), style: .continuous)
            )
            .padding(Self.rimWidth)
            .glassEffect(.regular, in: outer)
        case .solid:
            sheet(minHeight: size.height, shape: outer)
                .overlay(outer.strokeBorder(BillboardColors.separator, lineWidth: 1))
        case .solidHighContrast:
            sheet(minHeight: size.height, shape: outer)
                .overlay(outer.strokeBorder(BillboardColors.controlRule, lineWidth: 1))
        }
    }

    /// The opaque inner capsule that carries the text.
    private func sheet(minHeight: CGFloat, shape: RoundedRectangle) -> some View {
        content
            .foregroundStyle(BillboardColors.primaryText)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight)
            .background(shape.fill(BillboardColors.cardBackground))
            .accessibilityElement(children: .contain)
    }
}

#Preview("Glass capsules") {
    VStack(spacing: 16) {
        GlassCapsule {
            HStack {
                Text("Skipped H.R. 77").textRole(.body)
                Spacer()
                Button("Undo") {}.buttonStyle(BillboardButtonStyle(kind: .textButton))
            }
        }
        GlassCapsule(size: .compact) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up")
                Text("Jump to top").textRole(.caption).fontWeight(.semibold)
            }
        }
    }
    .padding()
    .background(BillboardColors.background)
}
