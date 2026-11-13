import SwiftUI

/// A labelled text field (Civic Record spec 3.17): the label above it in the `subheadline` role (`ink`), then
/// the field, 50 pt tall, on a `sheet` fill with a 1 pt `controlRule` border (3.22:1 light, 4.51:1 dark) and
/// `Radius.slip` corners, the text in `body` `ink` and the placeholder in `ink3`. The placeholder is an example
/// ("you@example.com", "123 Main St"), never the label again. While the field has focus its border is 2 pt
/// `ink`; with an error it is `danger` and the error line sits under it. Replaces R2's 12 pt
/// `cardBackground` boxes with no border.
///
/// The field takes the screen's focus state, so the border follows the keyboard. Text-input traits
/// (`.keyboardType`, `.textContentType`, `.submitLabel`, `.onSubmit`) set on a `RecordField` reach the field
/// inside. VoiceOver reads the label as the field's name; the label above is hidden from it.
struct RecordField<Focus: Hashable>: View {
    let label: String
    @Binding var text: String
    /// An example of what goes in the field, in `ink3`.
    var prompt: String? = nil
    var isSecure = false
    /// Drawn under the field in `danger` with `exclamationmark.circle`; the border turns `danger` too.
    var errorMessage: String? = nil
    var isDisabled = false
    /// The field's own id (the label above has none).
    var identifier: String? = nil
    /// The error line's id.
    var errorIdentifier: String? = nil
    /// A narrower box than the column (the 96 pt birth year); the label and the error keep the column.
    var fieldWidth: CGFloat? = nil
    let focus: FocusState<Focus?>.Binding
    let focusValue: Focus

    static var focusedBorderWidth: CGFloat { 2 }

    private var isFocused: Bool {
        focus.wrappedValue == focusValue
    }

    private var borderColor: Color {
        if errorMessage?.trimmedNonEmpty != nil { return BillboardColors.danger }
        return isFocused ? BillboardColors.primaryText : BillboardColors.controlRule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .textRole(.subheadline)
                .foregroundStyle(BillboardColors.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)

            input
                .textRole(.body)
                .foregroundStyle(BillboardColors.primaryText)
                .modifier(RecordFieldChrome(borderColor: borderColor, borderWidth: isFocused ? Self.focusedBorderWidth : 1))
                .frame(maxWidth: fieldWidth ?? .infinity, alignment: .leading)
                .focused(focus, equals: focusValue)
                .disabled(isDisabled)
                .accessibilityLabel(label)
                .modifier(OptionalIdentifier(identifier: identifier))

            if let errorMessage = errorMessage?.trimmedNonEmpty {
                RecordErrorText(errorMessage)
                    .modifier(OptionalIdentifier(identifier: errorIdentifier))
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        let promptText = prompt.map { Text($0).foregroundStyle(BillboardColors.dimText) }
        if isSecure {
            SecureField(label, text: $text, prompt: promptText)
        } else {
            TextField(label, text: $text, prompt: promptText)
        }
    }
}

/// The box of a field (spec 3.17), for a text field or a menu: 50 pt tall, 14 pt in from the sides, a `sheet`
/// fill and a border inside the `Radius.slip` edge.
struct RecordFieldChrome: ViewModifier {
    /// The box's height at the default text size; it grows with the text.
    static let height: CGFloat = 50

    var borderColor: Color = BillboardColors.controlRule
    var borderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: BillboardStyle.Radius.slip, style: .continuous)
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
            .background(shape.fill(BillboardColors.cardBackground))
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .contentShape(shape)
    }
}

/// A menu in the box of a field (spec 3.17): the chosen value in `ink`, or "Choose" in `ink3` until one is
/// set, and `chevron.up.chevron.down` in `ink3` at the trailing edge. The system menu lists the options with
/// a check beside the chosen one. Replaces the menu pickers that drew their value in system blue. An
/// optional label sits above the box in the `subheadline` role.
///
/// VoiceOver reads the label and the value ("State, Virginia"), or "Choose" before one is set.
struct RecordMenuField<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    let label: String
    @Binding var selection: Value
    let options: [Option]
    /// Whether the label is drawn above the box (VoiceOver reads it either way).
    var showsLabel = true
    /// The value that means nothing is chosen yet (shown as "Choose" in `ink3`).
    var unsetValue: Value? = nil
    var isDisabled = false
    var identifier: String? = nil

    static var chooseTitle: String { "Choose" }

    @ScaledMetric(relativeTo: .body) private var chevronSize: CGFloat = 13

    private var isSet: Bool {
        guard let unsetValue else { return true }
        return selection != unsetValue
    }

    /// What the box shows: the chosen option's title, or "Choose".
    var valueTitle: String {
        guard isSet, let option = options.first(where: { $0.value == selection }) else { return Self.chooseTitle }
        return option.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsLabel {
                Text(label)
                    .textRole(.subheadline)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }

            Menu {
                Picker(label, selection: $selection) {
                    ForEach(options) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            } label: {
                HStack(spacing: BillboardStyle.Space.s) {
                    Text(valueTitle)
                        .textRole(.body)
                        .foregroundStyle(isSet && !isDisabled ? BillboardColors.primaryText : BillboardColors.dimText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(TextRole.Face.text.font(size: chevronSize, weight: .semibold))
                        .foregroundStyle(BillboardColors.dimText)
                        .accessibilityHidden(true)
                }
                .modifier(RecordFieldChrome())
            }
            .buttonStyle(RowButtonStyle())
            .disabled(isDisabled)
            .accessibilityLabel(label)
            .accessibilityValue(valueTitle)
            .accessibilityInputLabels([label])
            .modifier(OptionalIdentifier(identifier: identifier))
        }
    }
}

/// An error under a field or a form (spec 3.17, 2.10): `exclamationmark.circle` and the words, both in
/// `danger`, in the `caption` role. Never gold, never a triangle. One VoiceOver element: the words.
struct RecordErrorText: View {
    let message: String
    var role: TextRole = .caption

    init(_ message: String, role: TextRole = .caption) {
        self.message = message
        self.role = role
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(TextRole.Face.text.font(size: role.scaledSize(for: dynamicTypeSize), weight: .semibold))
                .accessibilityHidden(true)
            Text(message)
                .textRole(role)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(BillboardColors.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A notice (spec 2.10): `info.circle` and the words in `ink2`, in the `caption` role. For facts that are not
/// errors, such as the address cap.
struct RecordNoticeText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(TextRole.Face.text.font(size: TextRole.caption.scaledSize(for: dynamicTypeSize), weight: .semibold))
                .accessibilityHidden(true)
            Text(message)
                .textRole(.caption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(BillboardColors.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// An accessibility identifier only when there is one, so a view without one keeps any set inside it.
private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct RecordFieldPreview: View {
    enum Field: Hashable { case email, password }
    @State private var email = ""
    @State private var password = ""
    @State private var state = ""
    @FocusState private var focused: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecordField(label: "Email", text: $email, prompt: "you@example.com", focus: $focused, focusValue: .email)
            RecordField(label: "Password", text: $password, prompt: "Your password", isSecure: true, errorMessage: "Incorrect email or password.", focus: $focused, focusValue: .password)
            RecordMenuField(label: "State", selection: $state, options: [.init(value: "VA", title: "Virginia")], unsetValue: "")
        }
        .padding(20)
        .background(BillboardColors.background)
    }
}

#Preview("Fields") {
    RecordFieldPreview()
}
