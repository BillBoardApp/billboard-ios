import SwiftUI

/// A Civic Record button with a title (spec 3.16): by default the primary `ink` capsule with its label
/// in `onFill`, 50 pt tall and full width; pass `kind` for the other kinds. While loading it shows a
/// spinner and the loading title ("Signing in…") on its enabled chrome, and takes no taps: callers also
/// pass `isEnabled: false` while busy, and the disabled `well` look would hide an `onFill` spinner
/// (about 1.2:1). A disabled button with a `disabledHint` says what is missing on a `caption` line under
/// it, which VoiceOver reads as the button's hint; a loading button is not missing anything.
struct BBActionButton: View {
    let title: String
    let action: () -> Void

    var loadingTitle: String? = nil
    var isEnabled: Bool = true
    var isLoading: Bool = false
    var kind: BillboardButtonKind = .primary
    /// Shown under a disabled button: what is missing ("Add your street address, city, state and ZIP
    /// to continue.").
    var disabledHint: String? = nil
    var expandToMaxWidth: Bool? = nil
    /// A taller floor than the kind's height.
    var minHeight: CGFloat? = nil
    /// Extra room either side of the label beyond the kind's own.
    var horizontalPadding: CGFloat = 0
    /// The label's size as a multiple of the `button` role's; 1 except for a label kept whole at AX5 with Bold Text
    /// (`TextRole.boldTextAX5Scale`).
    var labelScale: CGFloat = 1

    private var labelText: String {
        guard isLoading, let loadingTitle else { return title }
        return loadingTitle
    }

    private var hint: String? {
        guard !isEnabled, !isLoading, let disabledHint, !disabledHint.isEmpty else { return nil }
        return disabledHint
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isLoading {
                        // The loading title says it; VoiceOver does not also read "In progress".
                        ProgressView()
                            .tint(kind.progressTint)
                            .accessibilityHidden(true)
                    }
                    if labelScale == 1 {
                        Text(labelText)
                    } else {
                        Text(labelText)
                            .textRole(.button, scale: labelScale)
                    }
                }
            }
            .buttonStyle(
                BillboardButtonStyle(
                    kind: kind,
                    fullWidth: expandToMaxWidth,
                    minHeight: minHeight,
                    extraHorizontalPadding: horizontalPadding,
                    drawsAsEnabled: isLoading
                )
            )
            .disabled(!isEnabled || isLoading)
            .modifier(OptionalAccessibilityHint(hint: hint))

            if let hint {
                Text(hint)
                    .textRole(.caption)
                    .foregroundStyle(BillboardColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The hint only when there is one, so a call site's own `.accessibilityHint` is not replaced.
    private struct OptionalAccessibilityHint: ViewModifier {
        let hint: String?

        func body(content: Content) -> some View {
            if let hint {
                content.accessibilityHint(hint)
            } else {
                content
            }
        }
    }
}

/// A button that stays disabled until its form is filled in (spec 3.16): what is still missing, said on the
/// line under it, and whether something is in progress. It is enabled exactly when nothing is missing and
/// nothing is in progress, so a form's button and its line come from this one value and cannot disagree.
struct FormButtonState: Equatable {
    /// What a disabled button says is missing ("Add your email to continue."); nil when nothing is.
    let missing: String?
    /// The form is being sent: the button shows its loading title and takes no taps.
    let isBusy: Bool

    var isEnabled: Bool {
        missing == nil && !isBusy
    }
}

extension BBActionButton {
    /// A form's primary button whose enabled state, loading state and hint line all come from `state`.
    init(title: String, action: @escaping () -> Void, loadingTitle: String, state: FormButtonState) {
        self.init(
            title: title,
            action: action,
            loadingTitle: loadingTitle,
            isEnabled: state.isEnabled,
            isLoading: state.isBusy,
            disabledHint: state.missing
        )
    }
}
