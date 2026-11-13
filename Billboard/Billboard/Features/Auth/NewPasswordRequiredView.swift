import SwiftUI

struct NewPasswordRequiredView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var newPassword: String
    @State private var confirmNewPassword: String
    @FocusState private var focusedField: Field?

    /// Starts the form with these values (render tests); the app opens it empty.
    init(newPassword: String = "", confirmNewPassword: String = "") {
        _newPassword = State(initialValue: newPassword)
        _confirmNewPassword = State(initialValue: confirmNewPassword)
    }

    private enum Field: Hashable {
        case newPassword
        case confirmNewPassword
    }

    private var usernameLabel: String {
        if case .newPasswordRequired(let username) = auth.status, !username.isEmpty {
            return username
        }
        return auth.username ?? ""
    }

    private var updatePasswordButton: FormButtonState {
        NewPasswordForm.updatePasswordButton(newPassword: newPassword, confirmPassword: confirmNewPassword, isBusy: auth.isBusy)
    }

    private var showsPasswordMismatch: Bool {
        !confirmNewPassword.isEmpty && newPassword != confirmNewPassword
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BillboardStyle.Space.l) {
                Text("Set a new password")
                    .textRole(.title)
                    .foregroundStyle(BillboardColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if !usernameLabel.isEmpty {
                    Text("Email: \(usernameLabel)")
                        .textRole(.body)
                        .foregroundStyle(BillboardColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: BillboardStyle.Space.s) {
                    RecordField(
                        label: "New password",
                        text: $newPassword,
                        prompt: "At least 8 characters",
                        isSecure: true,
                        focus: $focusedField,
                        focusValue: .newPassword
                    )
                    .textContentType(.newPassword)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .confirmNewPassword }

                    PasswordRequirementsHint(password: newPassword)
                }

                RecordField(
                    label: "Confirm new password",
                    text: $confirmNewPassword,
                    prompt: "Type it again",
                    isSecure: true,
                    errorMessage: showsPasswordMismatch ? PasswordMismatchHint.message : nil,
                    focus: $focusedField,
                    focusValue: .confirmNewPassword
                )
                .textContentType(.newPassword)
                .submitLabel(.go)
                .onSubmit {
                    focusedField = nil
                    guard updatePasswordButton.isEnabled else { return }
                    Task { await auth.confirmNewPassword(newPassword) }
                }

                if case .error(let message) = auth.status {
                    RecordErrorText(message)
                }

                BBActionButton(
                    title: "Update password",
                    action: { Task { await auth.confirmNewPassword(newPassword) } },
                    loadingTitle: "Updating…",
                    state: updatePasswordButton
                )

                Button("Back to sign in") {
                    auth.cancelSignIn()
                }
                .buttonStyle(BillboardButtonStyle(kind: .textLink))
                .frame(maxWidth: .infinity)
            }
            // The 20 pt gutter of the screens before the tabs (spec 4.10).
            .padding(.horizontal, BillboardStyle.Space.xl)
            .padding(.vertical, BillboardStyle.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .billboardBackground()
        .preTabBar()
    }
}

/// When "Set a new password"'s Update password is enabled, and what its hint line says while it is not
/// (spec 3.16). Pure, for tests: the button is enabled exactly when there is no hint and nothing is in
/// progress (`FormButtonState`). Forgot password's "Enter code" says the same once its code is in.
enum NewPasswordForm {
    static let missingPassword = "Add a new password to continue."
    /// "Confirm new password" is the field's label.
    static let missingConfirmation = "Confirm your new password to continue."

    /// What a disabled Update password says is missing; nil when the new password meets the requirements
    /// and matches its confirmation.
    static func hint(newPassword: String, confirmPassword: String) -> String? {
        switch NewPasswordHints.need(password: newPassword, confirmation: confirmPassword) {
        case nil: return nil
        case .password: return missingPassword
        case .requirements: return NewPasswordHints.unmetRequirements
        case .confirmation: return missingConfirmation
        case .match: return NewPasswordHints.mismatch
        }
    }

    static func updatePasswordButton(newPassword: String, confirmPassword: String, isBusy: Bool) -> FormButtonState {
        FormButtonState(missing: hint(newPassword: newPassword, confirmPassword: confirmPassword), isBusy: isBusy)
    }
}
